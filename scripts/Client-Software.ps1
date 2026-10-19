# Functions only; install applications in the interactive Windows session, never in WinPE.
function Get-AtelierClientWinGet {
    $command=Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($package in @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)) {
        $path=Join-Path $package.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    return $null
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
    $results=New-Object 'Collections.Generic.List[object]'
    $statePath=Join-Path $DataPath 'winget-client-state.json'
    $saved=@{}
    if (Test-Path $statePath) {
        $entries=Get-Content $statePath -Encoding UTF8 -Raw | ConvertFrom-Json
        foreach ($entry in $entries) { if ($entry.status -eq 'completed') { $saved[$entry.id]=$entry } }
    }
    $logs=Join-Path $DataPath 'software-logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    try {
        $winget=Get-AtelierClientWinGet
        if (-not $winget) {
            & $OnProgress 10 'Preparation de WinGet dans Windows...'
            try { & (Join-Path $DataPath 'Install-WinGet.ps1') | Out-Null }
            catch { if (-not (Get-AtelierClientWinGet)) { throw } }
            $winget=Get-AtelierClientWinGet
        }
        if (-not $winget) { throw 'WinGet indisponible apres sa preparation dans cette session Windows.' }
    } catch {
        foreach ($key in $Packages) {
            $source=$sources | Where-Object { $_.key -eq $key } | Select-Object -First 1
            $results.Add(@{id=$key;name=[string]$source.name;version='';status='failed';exit_code=-1;reason=('Preparation WinGet : ' + $_.Exception.Message)})
        }
        return $results.ToArray()
    }
    $index=0
    foreach ($key in @($Packages | Select-Object -Unique)) {
        $source=$sources | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if (-not $source) { throw ('Logiciel non autorise : ' + $key) }
        $index++
        if ($saved.ContainsKey($key)) {
            if ($key -ne 'hpia') { $results.Add($saved[$key]);continue }
            try {
                $tool=Get-AtelierInstalledHpia
                $entry=@{id='hpia';name='HP Image Assistant';version='';status='completed';exit_code=0;reason='Installation HP existante verifiee';tool=$tool}
                $results.Add($entry);continue
            } catch { $saved.Remove($key) }
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
            $entry=@{id=$key;name=[string]$source.name;version='';status='completed';exit_code=$code;reason='Installation silencieuse WinGet sur Windows'}
            if ($key -eq 'hpia') { $entry.tool=Get-AtelierInstalledHpia }
            $saved[$key]=$entry;$results.Add($entry)
            Write-AtelierVerifiedUtf8File -Path $statePath -Content (ConvertTo-Json -InputObject @($saved.Values) -Depth 6) -NoBackup | Out-Null
        } catch {
            $message=$_.Exception.Message
            Add-Content -LiteralPath $log -Value $message -Encoding UTF8
            $results.Add(@{id=$key;name=[string]$source.name;version='';status='failed';exit_code=$(if($null -eq $code){-1}else{$code});reason=$message})
        }
    }
    return $results.ToArray()
}
