# Client cache transport. No CMSL module or SMB password is installed on the PC.
function Receive-AtelierHpArchive {
    param($Config,$Snapshot,[string]$Path,[scriptblock]$OnProgress)
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $identifier=[guid]::Parse([string]$Config.id).ToString()
    $snapshotId=[guid]::Parse([string]$Snapshot.id).ToString()
    $expected='/api/windows/'+$identifier+'/hp-repository/'+$snapshotId+'.zip'
    if ($Snapshot.url -ne $expected -or [string]$Snapshot.sha256 -notmatch '^[a-f0-9]{64}$' -or [long]$Snapshot.size -le 0 -or [long]$Snapshot.size -gt 20GB) { throw 'Description du depot HP invalide.' }
    $origin=[uri]$Config.server_url
    if ($origin.Scheme -ne 'https' -or $origin.UserInfo -or $origin.AbsolutePath -ne '/' -or $origin.Query -or $origin.Fragment) { throw 'Origine HTTPS HP invalide.' }
    if ((Test-Path $Path -PathType Leaf) -and (Get-Item $Path).Length -eq [long]$Snapshot.size -and (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Snapshot.sha256) { return }
    $partial=$Path+'.partial';$response=$null;$input=$null;$output=$null
    $request=[Net.HttpWebRequest]::Create($origin.GetLeftPart([UriPartial]::Authority)+$expected)
    $request.Headers['Authorization']='Bearer '+$Config.token
    $request.AllowAutoRedirect=$false;$request.Timeout=30000;$request.ReadWriteTimeout=30000
    $clock=[Diagnostics.Stopwatch]::StartNew();$notified=-5
    try {
        $pending=$request.GetResponseAsync()
        while (-not $pending.Wait(500)) {
            if ($clock.Elapsed.TotalSeconds -gt 30) { throw 'Connexion au depot HP trop longue.' }
        }
        $response=$pending.Result
        if ($response.ContentLength -gt 0 -and $response.ContentLength -ne [long]$Snapshot.size) { throw 'Taille HTTP du depot HP differente.' }
        $input=$response.GetResponseStream();$output=[IO.File]::Open($partial,[IO.FileMode]::Create)
        $buffer=New-Object byte[] (1MB);$received=0L
        while ($true) {
            $reading=$input.ReadAsync($buffer,0,$buffer.Length)
            $idle=[Diagnostics.Stopwatch]::StartNew()
            while (-not $reading.Wait(500)) {
                if ($idle.Elapsed.TotalSeconds -ge 30) { throw 'Copie du depot HP sans donnees depuis trente secondes.' }
                if ($clock.Elapsed.TotalSeconds -ge 900) { throw 'Copie du depot HP interrompue apres quinze minutes.' }
            }
            $count=$reading.Result
            if (-not $count) { break }
            $received+=$count
            if ($received -gt [long]$Snapshot.size) { throw 'Depot HP plus volumineux que prevu.' }
            $output.Write($buffer,0,$count)
            if ($clock.Elapsed.TotalSeconds-$notified -ge 5) {
                & $OnProgress ('Copie des pilotes depuis .250 : '+[math]::Round($received/1MB)+' / '+[math]::Round([long]$Snapshot.size/1MB)+' Mo.') | Out-Null
                $notified=$clock.Elapsed.TotalSeconds
            }
            if ($clock.Elapsed.TotalSeconds -ge 900) { throw 'Copie du depot HP interrompue apres quinze minutes.' }
        }
        $output.Dispose();$output=$null
        if ((Get-Item $partial).Length -ne [long]$Snapshot.size -or (Get-FileHash $partial -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Snapshot.sha256) { throw 'Integrite du depot HP refusee.' }
        Move-Item -LiteralPath $partial -Destination $Path -Force
    } finally {
        $request.Abort()
        if ($input) { $input.Dispose() };if ($output) { $output.Dispose() };if ($response) { $response.Dispose() }
        if (Test-Path $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}
function Expand-AtelierHpArchive {
    param([string]$Path,[string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $Destination) { Assert-AtelierHpTree $Destination;Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $root=[IO.Path]::GetFullPath($Destination).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($zip.Entries.Count -gt 5000 -or ($zip.Entries | Measure-Object Length -Sum).Sum -gt 20GB) { throw 'Depot HP hors limites.' }
        $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            if (-not (Test-AtelierHpRepositoryFile $entry.FullName) -or -not $names.Add($entry.FullName) -or (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960) { throw 'Chemin refuse dans le depot HP.' }
            $target=[IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin HP hors du cache prive.' }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
        }
    } finally { $zip.Dispose() }
}
function Get-AtelierHpRepository {
    param([string]$DataPath,[string[]]$RequiredSoftpaqs,[scriptblock]$OnProgress,[ValidateRange(0,120)][int]$WaitSeconds=90,[switch]$PrepareOnly)
    $result=@{status='online';message='Utilisation directe des serveurs HP.';path='';snapshot_id=''}
    try {
        . (Join-Path $DataPath 'HP-Repository.ps1')
        Assert-AtelierHpTree $DataPath
        $config=Get-Content (Join-Path $DataPath 'reporting.json') -Encoding UTF8 -Raw | ConvertFrom-Json
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $origin=[uri]$config.server_url
        if ($origin.Scheme -ne 'https' -or $origin.UserInfo -or $origin.Query -or $origin.Fragment -or $origin.AbsolutePath -ne '/') { throw 'Adresse du depot HP invalide.' }
        $platform=([string](Get-CimInstance Win32_BaseBoard -OperationTimeoutSec 15 | Select-Object -First 1).Product).Trim().ToUpperInvariant()
        if ($platform -notmatch '^[A-F0-9]{4}$') { throw 'Identifiant de plateforme HP non reconnu ; pas de depot associe.' }
        $windows=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $version=[string]$windows.DisplayVersion
        if (-not $version) { $version=[string]$windows.ReleaseId }
        if ($version -notmatch '^([12][0-9]H[12]|1809|1903|1909|2004|2009)$') { throw 'Version Windows non reconnue par le depot CMSL.' }
        $operating=if ([int]$windows.CurrentBuildNumber -ge 22000) { 'win11' } else { 'win10' }
        $result.platform=$platform;$result.os=$operating;$result.os_version=$version
        $required=@($RequiredSoftpaqs | Where-Object { $_ -match '^SP[0-9]{4,8}$' } | Select-Object -Unique)
        $body=@{platform=$platform;os=$operating;os_version=$version;required_softpaqs=$required} | ConvertTo-Json -Depth 4
        $uri=$config.server_url+'/api/windows/'+[guid]::Parse([string]$config.id).ToString()+'/hp-repository'
        $clock=[Diagnostics.Stopwatch]::StartNew()
        do {
            $response=Invoke-RestMethod -Uri $uri -Method Post -Headers @{Authorization=('Bearer '+$config.token)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15
            $result.request_status=[string]$response.status
            if ($PrepareOnly) {
                $result.status='not_needed';$result.message='Aucune mise a jour HP recommandee ; depot serveur entretenu en arriere-plan, sans copie sur ce poste.'
                $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $DataPath 'hp-repository-state.json') -Encoding UTF8
                & $OnProgress $result.message | Out-Null
                return [pscustomobject]$result
            }
            if ($response.status -eq 'ready' -and $response.snapshot) {
                if ($response.platform -ne $platform -or $response.os -ne $operating -or $response.os_version -ne $version) { throw 'Depot HP associe a une autre plateforme ou version Windows.' }
                break
            }
            & $OnProgress ('Depot HP '+$platform+' : '+$response.message+'. Attente courte avant utilisation directe de HP.') | Out-Null
            if ($response.status -in @('failed','unavailable')) {
                $reason=[string]$response.message
                if (-not $reason) { $reason='Synchronisation serveur non disponible.' }
                throw ('Depot HP serveur : '+$reason.Substring(0,[math]::Min(700,$reason.Length))+' Utilisation directe des serveurs HP.')
            }
            if ($response.PSObject.Properties['worker_available'] -and -not $response.worker_available) { throw 'Agent CMSL indisponible ; demande conservee sur .250 et utilisation directe de HP.' }
            if ($clock.Elapsed.TotalSeconds -ge $WaitSeconds) { throw 'Depot non pret ; synchronisation conservee sur .250 et installation directe depuis HP.' }
            Start-Sleep -Milliseconds 5000
        } while ($true)
        $path=Join-Path $DataPath 'hp-repository.zip'
        $destination=Join-Path $DataPath 'HP-RepositoryCache'
        # Allow space for the archive and its extracted copy before downloading.
        $drive=(Get-Item $DataPath).PSDrive
        if ($drive.Free -and $drive.Free -lt (2*[long]$response.snapshot.size+2GB)) { throw 'Espace insuffisant pour le depot HP local ; utilisation directe de HP.' }
        Receive-AtelierHpArchive -Config $config -Snapshot $response.snapshot -Path $path -OnProgress $OnProgress
        Expand-AtelierHpArchive -Path $path -Destination $destination
        $result.status='offline';$result.path=$destination;$result.snapshot_id=[string]$response.snapshot.id
        $result.message='Depot CMSL de .250 copie et verifie ; analyse du poste avant installation des seuls SoftPaq necessaires.'
    } catch { $result.message=$_.Exception.Message }
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $DataPath 'hp-repository-state.json') -Encoding UTF8
    & $OnProgress $result.message | Out-Null
    return [pscustomobject]$result
}
