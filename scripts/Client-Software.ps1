
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
# Fonctions seules. Installer les logiciels dans la session Windows interactive, jamais dans WinPE.
function Get-AtelierClientWinGet {
    $candidates=@()
    $command=Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates+=@($command.Source) }
    foreach ($package in @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)) {
        $path=Join-Path $package.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) { $candidates+=@($path) }
    }
    foreach ($path in @($candidates | Select-Object -Unique)) {
        try {
            $version=@(& $path --version 2>&1) -join ' '
            if ($LASTEXITCODE -eq 0 -and $version -match '^v?\d+\.\d+') { return $path }
        } catch { }
    }
    return $null
}
function Get-AtelierInstalledClientSoftware {
    param([string]$Key,[string]$DiagnosticLog)
    if ($Key -eq 'anydesk') { return Get-AtelierInstalledAnyDesk -DiagnosticLog $DiagnosticLog }
    if ($Key -eq 'hpia') {
        try { $tool=Get-AtelierInstalledHpia;return @{version=[string]$tool.version;tool=$tool} } catch { return $null }
    }
    # Un lanceur réussi ou un ancien checkpoint ne prouve pas une installation.
    $rules=@{
        vlc=@{name='^VLC( media player)?$';publisher='VideoLAN';files=@('vlc.exe')}
        reader=@{name='^Adobe (Acrobat|Reader)';publisher='Adobe';files=@('AcroRd32.exe','Acrobat.exe','Reader\AcroRd32.exe','Acrobat\Acrobat.exe')}
        chrome=@{name='^Google Chrome$';publisher='Google';files=@('chrome.exe','Application\chrome.exe')}
        lenovo_system_update=@{name='^(Lenovo )?System Update';publisher='Lenovo';files=@('tvsu.exe')}
    }
    $rule=$rules[$Key]
    if (-not $rule) { return $null }
    $roots=@($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique
    $relative=@{
        vlc=@('VideoLAN\VLC\vlc.exe')
        reader=@('Adobe\Acrobat DC\Acrobat\Acrobat.exe','Adobe\Acrobat Reader DC\Reader\AcroRd32.exe')
        chrome=@('Google\Chrome\Application\chrome.exe')
        lenovo_system_update=@('Lenovo\System Update\tvsu.exe')
    }
    $registry=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($entry in @(Get-ItemProperty -Path $registry -ErrorAction SilentlyContinue)) {
        if ($entry.DisplayName -notmatch $rule.name -or $entry.Publisher -notmatch $rule.publisher) { continue }
        $candidates=@()
        foreach ($root in $roots) { foreach ($file in $relative[$Key]) { $candidates+=@(Join-Path $root $file) } }
        if ($entry.InstallLocation) { foreach ($file in $rule.files) { $candidates+=@(Join-Path $entry.InstallLocation $file) } }
        $icon=([string]$entry.DisplayIcon -replace ',\s*-?\d+\s*$','').Trim().Trim('"')
        if ($icon -and [IO.Path]::GetFileName($icon) -in @($rule.files | ForEach-Object { [IO.Path]::GetFileName($_) })) { $candidates+=@($icon) }
        foreach ($path in @($candidates | Select-Object -Unique)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                return @{version=[string]$entry.DisplayVersion;verification=@{method='registry_and_executable';display_name=[string]$entry.DisplayName;path=$path;timestamp=[DateTime]::UtcNow.ToString('o')}}
            }
        }
    }
    return $null
}
function Get-AtelierExecutableCommandPath {
    param([string]$CommandLine)
    $value=[Environment]::ExpandEnvironmentVariables($CommandLine).Trim()
    if ($value -match '^"([^"]+\.exe)"(?:\s|,|$)') { return $Matches[1] }
    if ($value -match '^(.+?\.exe)(?:\s|,|$)') { return $Matches[1] }
    return ''
}
function Get-AtelierInstalledAnyDesk {
    param([string]$DiagnosticLog)
    # Certaines installations officielles omettent Publisher/InstallLocation. Exiger
    # un binaire AnyDesk signé et une inscription machine ou un service correspondant.
    $registry=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $entries=@(Get-ItemProperty -Path $registry -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^AnyDesk\b' })
    $service=$null
    try { $service=Get-CimInstance Win32_Service -Filter "Name='AnyDesk'" -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 1 } catch { }
    $servicePath=Get-AtelierExecutableCommandPath ([string]$service.PathName)
    $candidates=@()
    foreach ($root in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique) { $candidates+=@(Join-Path $root 'AnyDesk\AnyDesk.exe') }
    foreach ($entry in $entries) {
        $location=[Environment]::ExpandEnvironmentVariables([string]$entry.InstallLocation).Trim().Trim('"')
        if ($location) { $candidates+=@($(if ($location -match '\.exe$') { $location } else { Join-Path $location 'AnyDesk.exe' })) }
        $candidates+=@(Get-AtelierExecutableCommandPath ([string]$entry.DisplayIcon))
        $candidates+=@(Get-AtelierExecutableCommandPath ([string]$entry.UninstallString))
    }
    if ($servicePath) { $candidates+=@($servicePath) }
    if ($DiagnosticLog) { Add-Content -LiteralPath $DiagnosticLog -Value ('Contrôle AnyDesk : entrées de désinstallation='+$entries.Count+' ; service avec chemin='+[bool]$servicePath) -Encoding UTF8 }
    foreach ($path in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if ([IO.Path]::GetFileName($path) -ine 'AnyDesk.exe' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $signature=Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
            if ($DiagnosticLog) { Add-Content -LiteralPath $DiagnosticLog -Value ('Exécutable AnyDesk='+$path+' ; signature='+$signature.Status+' ; éditeur='+$signature.SignerCertificate.Subject) -Encoding UTF8 }
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)(?:CN|O)=(?:AnyDesk Software GmbH|philandro Software GmbH)(?:,|$)') { continue }
            $serviceMatches=$servicePath -and [IO.Path]::GetFullPath($path).Equals([IO.Path]::GetFullPath($servicePath),[StringComparison]::OrdinalIgnoreCase)
            if (-not $entries.Count -and -not $serviceMatches) { continue }
            $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion
            if (-not $version -and $entries.Count) { $version=[string]$entries[0].DisplayVersion }
            return @{version=[string]$version;verification=@{method=$(if ($serviceMatches) { 'signed_executable_and_service' } else { 'signed_executable_and_registry' });display_name='AnyDesk';path=$path;publisher=[string]$signature.SignerCertificate.Subject;timestamp=[DateTime]::UtcNow.ToString('o')}}
        } catch { }
    }
    return $null
}
function Get-AtelierSoftwareSummary {
    param([string[]]$Packages,[object[]]$Results)
    $missing=@()
    foreach ($key in @($Packages | Select-Object -Unique)) {
        $entry=@($Results | Where-Object { $_.id -eq $key -and $_.status -eq 'completed' -and ($_.verification -or $_.tool) })
        if ($entry.Count -ne 1) { $missing+=@($key) }
    }
    return @{status=$(if ($missing.Count) { 'needs_attention' } else { 'completed' });missing=$missing;selected=@($Packages);verified=(@($Packages).Count-$missing.Count)}
}
function Invoke-AtelierClientInstall {
    param([string]$Executable,[string[]]$Arguments,[string]$LogPath,[int]$TimeoutMilliseconds=2700000)
    $encoded=New-Object 'Collections.Generic.List[string]'
    for ($i=0;$i -lt $Arguments.Count;$i++) {
        $argument=$Arguments[$i]
        if ($argument -match '^[A-Za-z0-9._-]+$') { $encoded.Add($argument);continue }
        $hpLocation=if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'AtelierPXE\Tools\HPImageAssistant' } else { '' }
        if ($i -gt 0 -and $Arguments[$i-1] -eq '--location' -and $hpLocation -and $argument -eq $hpLocation -and $argument -notmatch '["\r\n]') {
            $encoded.Add('"'+$argument+'"');continue
        }
        $hpOverride='/s /e /f "'+$hpLocation+'"'
        if ($i -gt 0 -and $Arguments[$i-1] -eq '--override' -and $hpLocation -notmatch '["\r\n]' -and $argument -eq $hpOverride -and
            $Arguments[0] -eq 'install' -and @($Arguments | Where-Object { $_ -eq 'HP.ImageAssistant' }).Count -eq 1) {
            # Échapper les guillemets internes pour le parseur argv natif de Windows.
            # Seule cette commande d’extraction HP fixe peut remplacer les options du manifeste.
            $encoded.Add('"'+($argument -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"');continue
        }
        throw 'Argument WinGet non autorisé.'
    }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable;$info.Arguments=$encoded -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            # Ne pas ajouter un installateur concurrent à une installation active dont le résultat est inconnu.
            throw 'Installateur encore actif après 45 minutes : contrôler son processus avant de relancer.'
        }
        [IO.File]::AppendAllText($LogPath,($output.Result + [Environment]::NewLine + $errors.Result),[Text.Encoding]::UTF8)
        return $process.ExitCode
    } finally { $process.Dispose() }
}
function Get-AtelierInstalledHpia {
    $path=Join-Path $env:ProgramFiles 'AtelierPXE\Tools\HPImageAssistant\HPImageAssistant.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'WinGet terminé mais HPImageAssistant.exe est absent du dossier attendu. Consulter software-logs\hpia.log.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(HP Inc\.|Hewlett-Packard)') { throw 'Signature de l''exécutable HP Image Assistant invalide.' }
    return @{name='HP Image Assistant';path=$path;version=[string][Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function New-AtelierHpiaLauncher {
    param([string]$ToolsPath)
    Get-AtelierInstalledHpia | Out-Null
    $directory=Join-Path $ToolsPath 'Constructeur'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    # Commande fixe, sans identifiants de rapport ni dépendance au dossier ProgramData temporaire.
    # L’ouverture manuelle de HPIA demande une élévation.
    $launcher=@'
@echo off
powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath (Join-Path $env:ProgramFiles 'AtelierPXE\Tools\HPImageAssistant\HPImageAssistant.exe') -Verb RunAs"
'@
    [IO.File]::WriteAllText((Join-Path $directory 'HP-ImageAssistant.cmd'),$launcher,[Text.Encoding]::ASCII)
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Test-HPIA.ps1')) {
        foreach ($name in @('Test-HPIA.ps1','Tester-HPIA.cmd','HP-ImageAssistant.ps1','Unattend.ps1')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $directory $name) -Force
        }
    }
}
function Install-AtelierClientSoftware {
    param([string]$DataPath,[string[]]$Packages,[scriptblock]$OnProgress)
    if (-not $Packages.Count) { return }
    # Affecter directement le tableau JSON racine. Sous PowerShell 5.1, @(...)
    # l’encapsule en un élément ; l’énumération des membres mélange ensuite les identifiants des paquets.
    $sources=Get-Content (Join-Path $DataPath 'software-sources.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    # Paquet HP du poste, indépendant de l’ancien catalogue serveur ou bundle.
    $sources+=@([pscustomobject]@{key='hpia';name='HP Image Assistant';winget_id='HP.ImageAssistant';architecture='x64'})
    $sources+=@([pscustomobject]@{key='lenovo_system_update';name='Lenovo System Update';winget_id='Lenovo.SystemUpdate';architecture='x86'})
    $results=New-Object 'Collections.Generic.List[object]'
    $statePath=Join-Path $DataPath 'winget-client-state.json'
    $saved=@{}
    # Recréer cet état par des contrôles réels, sans anciens checkpoints ni checkpoints endommagés.
    $logs=Join-Path $DataPath 'software-logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    try {
        $winget=Get-AtelierClientWinGet
        if (-not $winget) {
            & $OnProgress 10 'Préparation de WinGet dans Windows...'
            try { & (Join-Path $DataPath 'Install-WinGet.ps1') *>&1 | Out-String | Add-Content -LiteralPath (Join-Path $logs 'winget-preparation.log') -Encoding UTF8 }
            catch { if (-not (Get-AtelierClientWinGet)) { throw } }
            $winget=Get-AtelierClientWinGet
        }
        if (-not $winget) { throw 'WinGet indisponible après sa préparation dans cette session Windows.' }
    } catch {
        $failure=$_.Exception.Message
        Add-Content -LiteralPath (Join-Path $logs 'winget-preparation.log') -Value $failure -Encoding UTF8
        foreach ($key in $Packages) {
            $source=$sources | Where-Object { $_.key -eq $key } | Select-Object -First 1
            $results.Add(@{id=$key;name=[string]$source.name;version='';status='failed';exit_code=-1;reason=('Préparation WinGet : ' + $failure)})
        }
        Write-AtelierVerifiedUtf8File -Path $statePath -Content (ConvertTo-Json -InputObject @($results.ToArray()) -Depth 8) -NoBackup | Out-Null
        return $results.ToArray()
    }
    $index=0
    foreach ($key in @($Packages | Select-Object -Unique)) {
        $source=$sources | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if (-not $source) { throw ('Logiciel non autorisé : ' + $key) }
        $index++
        $installed=Get-AtelierInstalledClientSoftware $key
        if ($installed) {
            $entry=@{id=$key;name=[string]$source.name;version=$installed.version;status='completed';exit_code=0;reason='Présence actuelle vérifiée dans Windows'}
            if ($installed.tool) { $entry.tool=$installed.tool } else { $entry.verification=$installed.verification }
            $saved[$key]=$entry
            Write-AtelierVerifiedUtf8File -Path $statePath -Content (ConvertTo-Json -InputObject @($saved.Values) -Depth 8) -NoBackup | Out-Null
            $results.Add($entry);continue
        }
        & $OnProgress (10+[int](45*($index-1)/$Packages.Count)) ('Téléchargement et installation silencieuse : ' + $source.name)
        $log=Join-Path $logs ($key + '.log')
        $code=$null
        try {
            # Les arguments viennent uniquement du catalogue livré ; aucune commande ne vient du site.
            $arguments=@('install','--id',$source.winget_id,'--exact','--source','winget','--silent','--architecture',$source.architecture,'--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
            if ($key -eq 'hpia') {
                # Le manifeste 5.3.6 contient /f C:\SWSetup\HPImageAssistant dans
                # Silent. --location ajoute un deuxième /f. Remplacer toutes les options
                # pour que l’extraction n’utilise qu’une seule destination déterministe.
                $location=Join-Path $env:ProgramFiles 'AtelierPXE\Tools\HPImageAssistant'
                New-Item -ItemType Directory -Path $location -Force | Out-Null
                & icacls.exe $location /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Impossible de protéger le dossier HP Image Assistant.' }
                $arguments+=@('--location',$location,'--override',('/s /e /f "'+$location+'"'))
            } else { $arguments+=@('--scope','machine') }
            $code=Invoke-AtelierClientInstall -Executable $winget -Arguments $arguments -LogPath $log
            # Un lanceur peut finir avant que l’inscription devienne visible. Attendre
            # brièvement, sans installateur concurrent ni longue analyse.
            $installed=$null
            for ($attempt=0;$attempt -lt 4;$attempt++) {
                if ($attempt) { Start-Sleep -Milliseconds 500 }
                $installed=Get-AtelierInstalledClientSoftware $key -DiagnosticLog $log
                if ($installed) { break }
            }
            Add-Content -LiteralPath $log -Value ('Contrôle final : WinGet='+$code+' ; présence vérifiée='+[bool]$installed) -Encoding UTF8
            if (-not $installed) {
                if ($key -eq 'hpia') { Get-AtelierInstalledHpia | Out-Null }
                throw ('Installation non vérifiée : '+$source.name+' ; WinGet='+$code+'. Exécutable, signature ou enregistrement Windows non confirmé. Voir '+$log)
            }
            $reason=if ($key -eq 'hpia') { 'Outil HP extrait et signature vérifiée ; le résultat des SoftPaq est indiqué séparément' } else { 'Installation silencieuse WinGet vérifiée dans Windows' }
            if ($code -notin @(0,3010,1641)) { $reason+=' ; présence confirmée malgré le code WinGet '+$code }
            $entry=@{id=$key;name=[string]$source.name;version=$installed.version;status='completed';exit_code=$code;reason=$reason}
            if ($installed.tool) { $entry.tool=$installed.tool } else { $entry.verification=$installed.verification }
            $saved[$key]=$entry;$results.Add($entry)
            Write-AtelierVerifiedUtf8File -Path $statePath -Content (ConvertTo-Json -InputObject @($saved.Values) -Depth 6) -NoBackup | Out-Null
        } catch {
            $message=$_.Exception.Message
            Add-Content -LiteralPath $log -Value $message -Encoding UTF8
            $entry=@{id=$key;name=[string]$source.name;version='';status='failed';exit_code=$(if($null -eq $code){-1}else{$code});reason=$message}
            $saved[$key]=$entry;$results.Add($entry)
            Write-AtelierVerifiedUtf8File -Path $statePath -Content (ConvertTo-Json -InputObject @($saved.Values) -Depth 8) -NoBackup | Out-Null
        }
    }
    return $results.ToArray()
}
