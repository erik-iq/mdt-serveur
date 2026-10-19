# Functions only; install applications in the interactive Windows session, never in WinPE.
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
    param([string]$Key)
    if ($Key -eq 'hpia') {
        try { return @{version='';tool=(Get-AtelierInstalledHpia)} } catch { return $null }
    }
    # A successful launcher or an old checkpoint is not proof of installation.
    $rules=@{
        vlc=@{name='^VLC( media player)?$';publisher='VideoLAN';files=@('vlc.exe')}
        reader=@{name='^Adobe (Acrobat|Reader)';publisher='Adobe';files=@('AcroRd32.exe','Acrobat.exe','Reader\AcroRd32.exe','Acrobat\Acrobat.exe')}
        chrome=@{name='^Google Chrome$';publisher='Google';files=@('chrome.exe','Application\chrome.exe')}
        anydesk=@{name='^AnyDesk';publisher='AnyDesk|philandro';files=@('AnyDesk.exe')}
        lenovo_system_update=@{name='^(Lenovo )?System Update';publisher='Lenovo';files=@('tvsu.exe')}
    }
    $rule=$rules[$Key]
    if (-not $rule) { return $null }
    $roots=@($env:ProgramFiles,${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    $relative=@{
        vlc=@('VideoLAN\VLC\vlc.exe')
        reader=@('Adobe\Acrobat DC\Acrobat\Acrobat.exe','Adobe\Acrobat Reader DC\Reader\AcroRd32.exe')
        chrome=@('Google\Chrome\Application\chrome.exe')
        anydesk=@('AnyDesk\AnyDesk.exe')
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
        throw 'Argument WinGet non autorise.'
    }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable;$info.Arguments=$encoded -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            # Do not launch another installer on top of an unknown running installation.
            throw 'Installateur encore actif apres 45 minutes : controler son processus avant de relancer.'
        }
        [IO.File]::AppendAllText($LogPath,($output.Result + [Environment]::NewLine + $errors.Result),[Text.Encoding]::UTF8)
        return $process.ExitCode
    } finally { $process.Dispose() }
}
function Get-AtelierInstalledHpia {
    $path=Join-Path $env:ProgramFiles 'AtelierPXE\Tools\HPImageAssistant\HPImageAssistant.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'WinGet termine mais HPImageAssistant.exe est absent du dossier attendu. Consulter software-logs\hpia.log.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(HP Inc\.|Hewlett-Packard)') { throw 'Signature de l executable HP Image Assistant invalide.' }
    return @{name='HP Image Assistant';path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function Install-AtelierClientSoftware {
    param([string]$DataPath,[string[]]$Packages,[scriptblock]$OnProgress)
    if (-not $Packages.Count) { return }
    $sources=@(Get-Content (Join-Path $DataPath 'software-sources.json') -Encoding UTF8 -Raw | ConvertFrom-Json)
    # Client-only HP package; independent of the old server/bundle catalogue.
    $sources+=@([pscustomobject]@{key='hpia';name='HP Image Assistant';winget_id='HP.ImageAssistant';architecture='x64'})
    $sources+=@([pscustomobject]@{key='lenovo_system_update';name='Lenovo System Update';winget_id='Lenovo.SystemUpdate';architecture='x86'})
    $results=New-Object 'Collections.Generic.List[object]'
    $statePath=Join-Path $DataPath 'winget-client-state.json'
    $saved=@{}
    # Rebuild this state from live checks; old or damaged checkpoints are not inputs.
    $logs=Join-Path $DataPath 'software-logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    try {
        $winget=Get-AtelierClientWinGet
        if (-not $winget) {
            & $OnProgress 10 'Preparation de WinGet dans Windows...'
            try { & (Join-Path $DataPath 'Install-WinGet.ps1') *>&1 | Out-String | Add-Content -LiteralPath (Join-Path $logs 'winget-preparation.log') -Encoding UTF8 }
            catch { if (-not (Get-AtelierClientWinGet)) { throw } }
            $winget=Get-AtelierClientWinGet
        }
        if (-not $winget) { throw 'WinGet indisponible apres sa preparation dans cette session Windows.' }
    } catch {
        $failure=$_.Exception.Message
        Add-Content -LiteralPath (Join-Path $logs 'winget-preparation.log') -Value $failure -Encoding UTF8
        foreach ($key in $Packages) {
            $source=$sources | Where-Object { $_.key -eq $key } | Select-Object -First 1
            $results.Add(@{id=$key;name=[string]$source.name;version='';status='failed';exit_code=-1;reason=('Preparation WinGet : ' + $failure)})
        }
        Write-AtelierVerifiedUtf8File -Path $statePath -Content (ConvertTo-Json -InputObject @($results.ToArray()) -Depth 8) -NoBackup | Out-Null
        return $results.ToArray()
    }
    $index=0
    foreach ($key in @($Packages | Select-Object -Unique)) {
        $source=$sources | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if (-not $source) { throw ('Logiciel non autorise : ' + $key) }
        $index++
        $installed=Get-AtelierInstalledClientSoftware $key
        if ($installed) {
            $entry=@{id=$key;name=[string]$source.name;version=$installed.version;status='completed';exit_code=0;reason='Presence actuelle verifiee dans Windows'}
            if ($installed.tool) { $entry.tool=$installed.tool } else { $entry.verification=$installed.verification }
            $saved[$key]=$entry
            Write-AtelierVerifiedUtf8File -Path $statePath -Content (ConvertTo-Json -InputObject @($saved.Values) -Depth 8) -NoBackup | Out-Null
            $results.Add($entry);continue
        }
        & $OnProgress (10+[int](45*($index-1)/$Packages.Count)) ('Telechargement et installation silencieuse : ' + $source.name)
        $log=Join-Path $logs ($key + '.log')
        $code=$null
        try {
            # Arguments come exclusively from the shipped catalogue; no command is accepted from the web.
            $arguments=@('install','--id',$source.winget_id,'--exact','--source','winget','--silent','--architecture',$source.architecture,'--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
            if ($key -eq 'hpia') {
                # The official manifest supports --location and extracts HPIA.
                # It declares no scope: do not force a machine-scope match.
                $location=Join-Path $env:ProgramFiles 'AtelierPXE\Tools\HPImageAssistant'
                New-Item -ItemType Directory -Path $location -Force | Out-Null
                & icacls.exe $location /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Impossible de proteger le dossier HP Image Assistant.' }
                $arguments+=@('--location',$location)
            } else { $arguments+=@('--scope','machine') }
            $code=Invoke-AtelierClientInstall -Executable $winget -Arguments $arguments -LogPath $log
            if ($null -eq $code -or $code -notin @(0,3010,1641)) { throw ('WinGet : code ' + $code + '. Voir ' + $log) }
            $installed=Get-AtelierInstalledClientSoftware $key
            if (-not $installed) { throw ('WinGet termine mais installation non verifiee : '+$source.name+'. Registre / executable absent. Voir '+$log) }
            $entry=@{id=$key;name=[string]$source.name;version=$installed.version;status='completed';exit_code=$code;reason='Installation silencieuse WinGet verifiee dans Windows'}
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
