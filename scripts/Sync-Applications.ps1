#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath,[string[]]$Packages=@('vlc','reader','chrome','anydesk'),[hashtable]$ApplicationBindings=@{},[string]$SourcesPath=(Join-Path $PSScriptRoot 'software-sources.json'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
. (Join-Path $PSScriptRoot 'Software-Sync.ps1')
. (Join-Path $PSScriptRoot 'Unattend.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Raw | ConvertFrom-Json
$winget=Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) { throw 'WinGet absent. Executer scripts\Install-WinGet.ps1 une fois, puis rouvrir PowerShell.' }
$sources=@(Get-Content -LiteralPath $SourcesPath -Raw | ConvertFrom-Json)
foreach ($key in $Packages) { if (@($sources | Where-Object { $_.key -eq $key }).Count -ne 1) { throw ('Source inconnue ou dupliquee : ' + $key) } }
$headers=@{}
if (-not $config.internal_mode) { $headers.Authorization='Bearer ' + (Get-Content (Join-Path $config.data_dir 'admin-token') -Raw).Trim() }
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
function Invoke-SoftwareApi([string]$Path,[string]$Method='GET',$Body=$null) {
    $parameters=@{Uri=($config.base_url + '/api' + $Path);Method=$Method;Headers=$headers;TimeoutSec=60}
    if ($null -ne $Body) { $parameters.ContentType='application/json; charset=utf-8';$parameters.Body=[Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8)) }
    return Invoke-RestMethod @parameters
}
$mutex=New-Object Threading.Mutex($false,'Global\AtelierPXE-SoftwareSync')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); throw 'Une synchronisation logicielle est deja active.' }
try {
    $state=Invoke-SoftwareApi '/state'
    if (@($state.deployments | Where-Object { $_.status -in @('queued','running') }).Count) { throw 'Terminer ou annuler les autorisations WinPE actives avant la synchronisation.' }
    $directory=Join-Path $config.data_dir 'software-sync'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $bindings=@{};$bindingPath=Join-Path $directory 'bindings.json'
    if (Test-Path $bindingPath) { (Get-Content $bindingPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $bindings[$_.Name]=[string]$_.Value } }
    foreach ($entry in $ApplicationBindings.GetEnumerator()) { $bindings[$entry.Key]=$entry.Value }
    $results=@()
    foreach ($key in $Packages) {
        $source=$sources | Where-Object { $_.key -eq $key }
        $staging=Join-Path $directory ([guid]::NewGuid().ToString('N'))
        try {
            $state=Invoke-SoftwareApi '/state'
            $existing=Find-AtelierSoftwareBinding $state $source $bindings[$key]
            New-Item -ItemType Directory -Path $staging | Out-Null
            $arguments=@('download','--id',$source.winget_id,'--exact','--source','winget','--architecture',$source.architecture,'--installer-type',$source.installer_type,'--scope','machine','--download-directory',$staging,'--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
            Write-Host ('Recherche et telechargement de ' + $source.name + '...')
            & $winget.Source @arguments
            if ($LASTEXITCODE -ne 0) { throw ('WinGet download en echec (code ' + $LASTEXITCODE + '). Ancienne version conservee.') }
            $download=Get-AtelierDownloadedInstaller $staging $source
            $safeVersion=$download.version -replace '[^A-Za-z0-9._-]', '_'
            $filename=$key + '-' + $safeVersion + '-' + $download.sha256.Substring(0,16) + $source.extension
            $target=Join-Path (Join-Path $config.data_dir 'artifacts') $filename
            if (Test-Path -LiteralPath $target) {
                if ((Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $download.sha256) { throw 'Un fichier existant different occupe le nom de destination.' }
            } else { Move-Item -LiteralPath $download.path -Destination $target }
            $asset=@($state.assets | Where-Object { $_.filename -eq $filename }) | Select-Object -First 1
            if (-not $asset) { $asset=Invoke-SoftwareApi '/assets' 'POST' @{filename=$filename;kind='application'} }
            $name=if ($existing) { $existing.name } else { $source.name }
            $body=@{name=$name;version=$download.version;asset_id=$asset.id;arguments=$source.arguments;entry_point='';install_mode='install';manufacturer='all'}
            if ($existing -and $existing.version -eq $download.version -and $existing.asset_id -eq $asset.id -and $existing.arguments -eq $source.arguments) {
                $application=$existing;$status='unchanged'
            } elseif ($existing) { $application=Invoke-SoftwareApi ('/applications/' + $existing.id) 'PUT' $body;$status='updated' }
            else { $application=Invoke-SoftwareApi '/applications' 'POST' $body;$status='created' }
            $bindings[$key]=$application.id
            Write-AtelierVerifiedUtf8File -Path $bindingPath -Content ($bindings | ConvertTo-Json) -NoBackup | Out-Null
            $results += @{package=$key;winget_id=$source.winget_id;version=$download.version;status=$status;sha256=$download.sha256;source_url=$download.url;application_id=$application.id}
            Write-Host ($source.name + ' ' + $download.version + ' : ' + $status) -ForegroundColor Green
        } catch { $results += @{package=$key;status='failed';message=$_.Exception.Message};Write-Warning ($source.name + ' : ' + $_.Exception.Message) }
        finally { if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
    }
    Write-AtelierVerifiedUtf8File -Path (Join-Path $directory 'last-sync.json') -Content (@{date=[DateTime]::UtcNow.ToString('o');applications=$results} | ConvertTo-Json -Depth 8) -NoBackup | Out-Null
    if (@($results | Where-Object { $_.status -eq 'failed' }).Count) { throw 'Synchronisation partielle : consulter software-sync\last-sync.json. Les logiciels en echec conservent leur ancienne entree.' }
    Write-Host 'Logiciels synchronises. Les bundles existants gardent leurs references. Creer de nouvelles autorisations ; aucune reconstruction WinPE necessaire pour les seules versions logicielles.'
} finally { $mutex.ReleaseMutex();$mutex.Dispose();$headers.Clear() }
