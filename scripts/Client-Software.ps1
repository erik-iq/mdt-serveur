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
    if (@($Arguments | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' }).Count) { throw 'Argument WinGet non autorisé.' }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable;$info.Arguments=$Arguments -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            # Do not launch another installer on top of an unknown running installation.
            throw 'Installateur encore actif après 45 minutes : contrôler son processus avant de relancer.'
        }
        [IO.File]::AppendAllText($LogPath,($output.Result + [Environment]::NewLine + $errors.Result),[Text.Encoding]::UTF8)
        return $process.ExitCode
    } finally { $process.Dispose() }
}
function Install-AtelierClientSoftware {
    param([string]$DataPath,[string[]]$Packages,[scriptblock]$OnProgress)
    if (-not $Packages.Count) { return }
    $sources=Get-Content (Join-Path $DataPath 'software-sources.json') -Raw | ConvertFrom-Json
    $results=New-Object 'Collections.Generic.List[object]'
    $statePath=Join-Path $DataPath 'winget-client-state.json'
    $saved=@{}
    if (Test-Path $statePath) {
        $entries=Get-Content $statePath -Raw | ConvertFrom-Json
        foreach ($entry in $entries) { if ($entry.status -eq 'completed') { $saved[$entry.id]=$entry } }
    }
    $logs=Join-Path $DataPath 'software-logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    try {
        $winget=Get-AtelierClientWinGet
        if (-not $winget) {
            & $OnProgress 10 'Préparation de WinGet dans Windows...'
            try { & (Join-Path $DataPath 'Install-WinGet.ps1') | Out-Null }
            catch { if (-not (Get-AtelierClientWinGet)) { throw } }
            $winget=Get-AtelierClientWinGet
        }
        if (-not $winget) { throw 'WinGet indisponible après sa préparation dans cette session Windows.' }
    } catch {
        foreach ($key in $Packages) {
            $source=$sources | Where-Object { $_.key -eq $key } | Select-Object -First 1
            $results.Add(@{id=$key;name=[string]$source.name;version='';status='failed';exit_code=-1;reason=('Préparation WinGet : ' + $_.Exception.Message)})
        }
        return $results.ToArray()
    }
    $index=0
    foreach ($key in @($Packages | Select-Object -Unique)) {
        $source=$sources | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if (-not $source) { throw ('Logiciel non autorisé : ' + $key) }
        $index++
        if ($saved.ContainsKey($key)) { $results.Add($saved[$key]);continue }
        & $OnProgress (10+[int](45*($index-1)/$Packages.Count)) ('Téléchargement et installation silencieuse : ' + $source.name)
        $log=Join-Path $logs ($key + '.log')
        $code=$null
        try {
            # Arguments come exclusively from the shipped catalogue; no command is accepted from the web.
            $arguments=@('install','--id',$source.winget_id,'--exact','--source','winget','--silent','--scope','machine','--architecture',$source.architecture,'--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
            $code=Invoke-AtelierClientInstall -Executable $winget -Arguments $arguments -LogPath $log
            if ($null -eq $code -or $code -notin @(0,3010,1641)) { throw ('WinGet : code ' + $code + '. Voir ' + $log) }
            $entry=@{id=$key;name=[string]$source.name;version='';status='completed';exit_code=$code;reason='Installation silencieuse WinGet sur Windows'}
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
