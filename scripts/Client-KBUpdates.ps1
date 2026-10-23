
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Installation des MSU depuis .250, sans recherche Windows Update ni modification du WIM.
function Get-AtelierKbContext {
    $version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build=[int]$version.CurrentBuild
    $architecture=switch ($env:PROCESSOR_ARCHITECTURE) {'AMD64' {'x64'};'ARM64' {'arm64'};default {throw 'Architecture Windows non prise en charge pour les KB.'}}
    $net=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
    $dotnet=if ($net -and [int]$net.Release -ge 533320) {'4.8.1'} elseif ($net -and [int]$net.Release -ge 528040) {'4.8'} else {'none'}
    if ($version.DisplayVersion -notmatch '^\d{2}H[12]$' -or $build -lt 19041) { throw 'Version Windows exacte indisponible pour sélectionner les KB.' }
    return @{family=$(if ($build -ge 22000) {'11'}else{'10'});release=[string]$version.DisplayVersion;architecture=$architecture;dotnet=$dotnet;build=$build}
}
function Get-AtelierKbBoot {
    $boot=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15).LastBootUpTime
    if (-not $boot) { throw 'Démarrage Windows inconnu, reprise des KB refusée.' }
    return ([datetime]$boot).ToUniversalTime().ToString('o')
}
function Get-AtelierKbBuild {
    $version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    return [version]('10.0.'+[string]$version.CurrentBuild+'.'+[string]$version.UBR)
}
function Save-AtelierKbState {
    param([string]$Path,[hashtable]$State)
    $State.timestamp=[DateTime]::UtcNow.ToString('o')
    Write-AtelierVerifiedUtf8File -Path $Path -Content ($State|ConvertTo-Json -Depth 18) -NoBackup | Out-Null
}
function Get-AtelierKbFile {
    param($Config,$File,[string]$Destination,[scriptblock]$OnProgress)
    $expected='/api/windows/'+[string]$Config.id+'/kb/'
    if ([string]$File.url -notmatch ('^'+[regex]::Escape($expected)+'[a-f0-9-]{36}/files/[a-f0-9]{64}$') -or
        [string]$File.sha256 -notmatch '^[a-f0-9]{64}$' -or [string]$File.filename -notmatch '^[A-Za-z0-9_.-]+\.msu$') { throw 'Manifeste KB invalide.' }
    if ((Test-Path -LiteralPath $Destination) -and (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ieq $File.sha256) { return }
    $partial=$Destination+'.partial'
    $web=New-Object Net.WebClient
    $web.Headers['Authorization']='Bearer '+$Config.token
    try {
        $task=$web.DownloadFileTaskAsync([uri]($Config.server_url+[string]$File.url),$partial)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while (-not $task.IsCompleted) {
            if ($clock.Elapsed.TotalMinutes -ge 30) { $web.CancelAsync();throw 'Copie de la KB depuis .250 interrompue après 30 minutes.' }
            $bytes=if(Test-Path -LiteralPath $partial){(Get-Item -LiteralPath $partial).Length}else{0}
            & $OnProgress ('Copie depuis .250 : '+$File.filename+' ('+[math]::Round($bytes/1MB)+' Mo).') | Out-Null
            Start-Sleep -Seconds 5
        }
        $task.GetAwaiter().GetResult() | Out-Null
        if ((Get-Item -LiteralPath $partial).Length -ne [long]$File.size -or
            (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $File.sha256) { throw 'Empreinte de la KB reçue différente du cache serveur.' }
        Move-Item -LiteralPath $partial -Destination $Destination -Force
    } finally { $web.Dispose();Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
}
function Invoke-AtelierKbInstall {
    param([string]$Directory,[string]$LogPath,[scriptblock]$OnProgress,[hashtable]$State,[string]$StatePath)
    # Cibler le MSU demandé ; DISM découvre ses checkpoints voisins sans réappliquer tout le dossier.
    $target=@(Get-ChildItem -LiteralPath $Directory -Filter '*.msu' -File | Where-Object {$_.Name -match ('(?i)\b'+[regex]::Escape([string]$State.active_kb)+'[-_]')})
    if ($target.Count -ne 1) { $State.status='needs_attention';throw 'MSU cible absent ou ambigu dans le dossier des correctifs.' }
    $consolePath=[IO.Path]::Combine([IO.Path]::GetDirectoryName($LogPath),([IO.Path]::GetFileNameWithoutExtension($LogPath)+'-console.log'))
    $State.log_path=$LogPath;$State.console_path=$consolePath;$State.target_msu=$target[0].Name
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:SystemRoot 'System32\dism.exe'
    $info.Arguments='/Online /English /Add-Package /PackagePath:"'+$target[0].FullName+'" /Quiet /NoRestart /LogPath:"'+$LogPath+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $State.process_id=$process.Id
        Save-AtelierKbState $StatePath $State
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(5000)) {
            & $OnProgress ('Installation de '+$State.active_kb+' dans Windows : '+[int]$watch.Elapsed.TotalSeconds+' s.') | Out-Null
            if ($watch.Elapsed.TotalHours -ge 2) { throw 'Installation KB encore active après deux heures ; aucune autre installation ni aucun redémarrage lancé.' }
        }
        $output=$stdout.GetAwaiter().GetResult()+"`r`n"+$stderr.GetAwaiter().GetResult()
        if ($output.Trim()) { Write-AtelierVerifiedUtf8File -Path $consolePath -Content $output -NoBackup | Out-Null }
        return [int]$process.ExitCode
    } finally { $process.Dispose() }
}
function Get-AtelierKbFailureDetails {
    param([int]$Code,[string]$LogPath)
    $detail=''
    foreach ($path in @($LogPath,([IO.Path]::Combine([IO.Path]::GetDirectoryName($LogPath),([IO.Path]::GetFileNameWithoutExtension($LogPath)+'-console.log'))))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $lines=@(Get-Content -LiteralPath $path -Tail 80 -Encoding UTF8)
        $matches=[regex]::Matches(($lines -join ' '),'(?i)0x[89a-f][0-9a-f]{7}')
        if ($matches.Count) { $detail+=' HRESULT relevés : '+((@($matches | ForEach-Object {$_.Value.ToUpperInvariant()} | Select-Object -Unique)) -join ', ')+'.' }
    }
    if ($Code -eq 552) { $detail+=" Windows signale des informations de contrôle d’accès insuffisantes ; le journal DISM doit identifier le paquet et le chemin concernés." }
    $detail=$detail.Replace([char]0x2013,'-').Replace([char]0x2014,'-')
    if ($detail.Length -gt 900) { $detail=$detail.Substring(0,900) }
    return $detail
}

function Set-AtelierKb552Verification {
    param([hashtable]$State,[string]$DataPath)
    foreach ($entry in @($State.entries)) {
        if ($entry.status -ne 'failed' -or $entry.exit_code -ne 552 -or $entry.kind -ne 'os' -or
            $entry.kb -ne $State.active_kb -or $entry.kb -notmatch '^KB[0-9]{6,9}$' -or
            $entry.target_build -notmatch '^\d{5}\.\d+$' -or $entry.verification_failed) { continue }
        $log=Join-Path $DataPath ('kb-'+$entry.kb+'.log')
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { continue }
        $tail=(Get-Content -LiteralPath $log -Tail 100 -Encoding UTF8) -join "`n"
        $session=$tail.LastIndexOf('<----- Starting Dism.exe session ----->',[StringComparison]::Ordinal)
        if ($session -ge 0) { $tail=$tail.Substring($session) }
        # Ce journal autorise une vérification après redémarrage, jamais une réussite immédiate.
        if ($tail -notmatch 'Install exited\. Error:\[0x0\]' -or
            $tail -notmatch 'Repair needed: \[FALSE\]' -or
            $tail -notmatch 'ExecuteCmdLine\(hr:0x80070228\)' -or
            $tail -notmatch 'Image session has been closed\. Reboot required=yes\.') { continue }
        $entry.status='verification_pending'
        $entry | Add-Member NoteProperty diagnostic 'DISM a signalé une installation et un redémarrage requis avant le code 552. Confirmation du build après redémarrage obligatoire.' -Force
        $State.status='reboot_pending';$State.reboot_required=$true
        $State.message='Code DISM 552 conservé. Redémarrage nécessaire pour vérifier la KB réellement appliquée avant de continuer.'
        return $true
    }
    return $false
}

function Invoke-AtelierCachedWindowsUpdates {
    param([string]$DataPath,[scriptblock]$OnProgress={param($Message)},[ValidateRange(1,600)][int]$ServerWaitSeconds=180)
    $path=Join-Path $DataPath 'windows-kb-result.json'
    $state=@{status='running';message='Préparation des correctifs depuis .250.';reboot_required=$false;entries=@();active_kb='';process_id=$null;boot_id='';timestamp='';source='server_250'}
    try {
        $context=Get-AtelierKbContext
        $boot=Get-AtelierKbBoot
        if (Test-Path -LiteralPath $path) {
            $saved=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in $saved.PSObject.Properties) { $state[$property.Name]=$property.Value }
            if ($state.context.build -ne $context.build -or $state.context.release -ne $context.release -or $state.context.architecture -ne $context.architecture) { throw 'Le contexte Windows a changé depuis le début des KB.' }
            [void](Set-AtelierKb552Verification -State $state -DataPath $DataPath)
            $sameBoot=$state.boot_id -and ([datetime]$state.boot_id).ToUniversalTime() -eq ([datetime]$boot).ToUniversalTime()
            if ($sameBoot -and $state.status -eq 'running' -and @($state.entries|Where-Object {$_.status -eq 'installed'}).Count) {
                $state.status='reboot_pending';$state.reboot_required=$true
                Save-AtelierKbState $path $state
            }
            if ($sameBoot -and $state.status -eq 'reboot_pending') { Save-AtelierKbState $path $state;return [pscustomobject]$state }
            if ($state.status -eq 'installing') {
                if ($sameBoot) { throw 'Une installation KB est interrompue ou encore active ; aucun second DISM lancé.' }
                throw 'Installation KB interrompue par un redémarrage non confirmé. Consulter le journal DISM.'
            }
            if (-not $sameBoot -and @($state.entries|Where-Object {$_.status -in @('installed','verification_pending')}).Count) {
                $packages=@(Get-WindowsPackage -Online -ErrorAction Stop)
                foreach ($entry in @($state.entries)) {
                    if ($entry.status -notin @('installed','verification_pending')) { continue }
                    if ($entry.kind -eq 'os' -and $entry.target_build -and (Get-AtelierKbBuild) -lt [version]('10.0.'+$entry.target_build)) { $entry | Add-Member NoteProperty verification_failed $true -Force;throw ('Le build Windows attendu après '+$entry.kb+" n’est pas confirmé. Code natif conservé : "+$entry.exit_code+'.') }
                    foreach ($name in @($entry.package_names)) {
                        if (-not @($packages|Where-Object {$_.PackageName -eq $name -and [string]$_.PackageState -in @('Installed','Superseded')}).Count) { throw ('Paquet Windows non finalisé après redémarrage : '+$name) }
                    }
                    $entry.status='completed'
                    $entry | Add-Member NoteProperty verified_after_boot $boot -Force
                }
                $state.reboot_required=$false
            }
            if ($state.status -in @('completed','needs_attention')) { Save-AtelierKbState $path $state;return [pscustomobject]$state }
        }
        $state.context=$context;$state.boot_id=$boot;$state.status='running';$state.reboot_required=$false
        $config=Get-Content (Join-Path $DataPath 'reporting.json') -Raw -Encoding UTF8|ConvertFrom-Json
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $base=$config.server_url+'/api/windows/'+$config.id+'/kb'
        $headers=@{Authorization=('Bearer '+$config.token)}
        $manifest=if ($state.manifest -and $state.manifest.status -eq 'ready') { $state.manifest } else { Invoke-RestMethod -Uri $base -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($context|ConvertTo-Json))) -TimeoutSec 30 }
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while ($manifest.status -in @('queued','running')) {
            & $OnProgress ('Serveur .250 : '+$manifest.message) | Out-Null
            if ($watch.Elapsed.TotalSeconds -ge $ServerWaitSeconds) {
                $state.status='retry_pending';$state.message='Téléchargement des KB en cours sur .250. La préparation reprendra automatiquement.'
                Save-AtelierKbState $path $state;return [pscustomobject]$state
            }
            Start-Sleep -Seconds 5
            $manifest=Invoke-RestMethod -Uri ($base+'/'+$manifest.id) -Headers $headers -TimeoutSec 30
        }
        if ([string]$manifest.id -notmatch '^[a-f0-9-]{36}$') { throw 'Identifiant de cache KB invalide.' }
        if ($manifest.status -ne 'ready') { throw ('Dépôt KB non prêt : '+$manifest.message) }
        if ($manifest.context.family -ne $context.family -or $manifest.context.build -ne $context.build -or $manifest.context.release -ne $context.release -or $manifest.context.architecture -ne $context.architecture -or $manifest.context.dotnet -ne $context.dotnet) { throw 'Correctifs incompatibles avec le contexte Windows réel.' }
        $state.snapshot_id=$manifest.id;$state.manifest=$manifest
        $installed=0
        $hotfixes=@(Get-HotFix -ErrorAction Stop | ForEach-Object {$_.HotFixID})
        foreach ($group in @($manifest.groups)) {
            if ($group.kb -notmatch '^KB[0-9]{6,9}$' -or $group.kind -notin @('os','net')) { throw 'Identifiant de correctif invalide.' }
            $done=@($state.entries|Where-Object {$_.kb -eq $group.kb -and $_.status -in @('completed','installed','up_to_date')})
            if ($done.Count) { continue }
            $already=$group.kb -in $hotfixes -or ($group.kind -eq 'os' -and $group.target_build -and (Get-AtelierKbBuild) -ge [version]('10.0.'+$group.target_build))
            $entry=[pscustomobject]@{kb=[string]$group.kb;kind=[string]$group.kind;target_build=[string]$group.target_build;title=[string]$group.title;status='running';exit_code=$null;package_names=@()}
            $state.entries=@($state.entries)+@($entry)
            if ($already) { $entry.status='up_to_date';continue }
            $directory=Join-Path $DataPath ('Windows-KB\'+[string]$manifest.id+'\'+$group.kb)
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            foreach ($file in @($group.files)) {
                if ([string]$file.filename -notmatch '^[A-Za-z0-9_.-]+\.msu$') { throw 'Nom de fichier KB refusé.' }
                Get-AtelierKbFile -Config $config -File $file -Destination (Join-Path $directory $file.filename) -OnProgress $OnProgress
            }
            if (-not @($group.files).Count) { throw 'Aucun fichier MSU pour le correctif.' }
            $before=@(Get-WindowsPackage -Online -ErrorAction Stop|ForEach-Object {$_.PackageName})
            $state.active_kb=$group.kb;$state.status='installing'
            Save-AtelierKbState $path $state
            $code=Invoke-AtelierKbInstall -Directory $directory -LogPath (Join-Path $DataPath ('kb-'+$group.kb+'.log')) -OnProgress $OnProgress -State $state -StatePath $path
            $entry.exit_code=$code
            $state.process_id=$null
            if ($code -notin @(0,3010)) { $entry.status='failed';$state.status='needs_attention' }
            if ($code -notin @(0,3010)) {
                $log=Join-Path $DataPath ('kb-'+$group.kb+'.log')
                $detail=Get-AtelierKbFailureDetails -Code $code -LogPath $log
                $entry | Add-Member NoteProperty diagnostic $detail -Force
                if (Set-AtelierKb552Verification -State $state -DataPath $DataPath) {
                    Save-AtelierKbState $path $state;return [pscustomobject]$state
                }
                throw ('Installation de '+$group.kb+' en échec (code '+$code+').'+$detail+' Voir '+$log)
            }
            $packages=@(Get-WindowsPackage -Online -ErrorAction Stop)
            $entry.package_names=@($packages|Where-Object {$_.PackageName -notin $before}|ForEach-Object {$_.PackageName})
            $entry.status='installed';$installed++;$state.status='running';$state.process_id=$null
            Save-AtelierKbState $path $state
            if ($code -eq 3010) { break }
        }
        if ($installed) {
            $state.status='reboot_pending';$state.reboot_required=$true;$state.message='Correctifs Windows installés depuis .250. Redémarrage et reprise automatiques nécessaires.'
        } else {
            $state.status='completed';$state.message='Correctifs Windows vérifiés. Préparation depuis le cache .250 terminée.'
        }
        Save-AtelierKbState $path $state
    } catch {
        # Un code perdu ou un installateur encore actif ne devient jamais une réussite.
        if ($state.status -ne 'installing') { $state.status='needs_attention' }
        $state.message=$_.Exception.Message
        Save-AtelierKbState $path $state
    }
    return [pscustomobject]$state
}
