# A bounded retry for the injected I219 driver, only on matching PCI hardware.
function Test-AtelierI219Hardware {
    try {
        return @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction Stop | Where-Object { $_.PSChildName -match '^VEN_8086&DEV_(15D7|15D8)(?:&|$)' }).Count -gt 0
    } catch { return $false }
}
function Test-AtelierWinPEIPv4 {
    try {
        foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up -or $adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            foreach ($address in $adapter.GetIPProperties().UnicastAddresses) {
                if ($address.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $address.Address.ToString() -notmatch '^(0\.|127\.|169\.254\.)') { return $true }
            }
        }
    } catch { }
    return $false
}
function Get-AtelierWinPERoot {
    return [IO.Path]::GetPathRoot($env:SystemRoot)
}
function Invoke-AtelierWinPENetworkCommand {
    param([string]$FilePath,[string]$Arguments)
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$FilePath;$start.Arguments=$Arguments
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        if (-not $process.Start()) { throw 'Commande reseau WinPE non lancee.' }
        if (-not $process.WaitForExit(15000)) { $process.Kill();[void]$process.WaitForExit(3000);throw 'Commande reseau WinPE trop longue.' }
        return $process.ExitCode
    } finally { $process.Dispose() }
}
function Initialize-AtelierI219Network {
    param($Config,[string]$LogPath)
    if (-not $Config.i219_recovery -or (Test-AtelierWinPEIPv4) -or -not (Test-AtelierI219Hardware)) { return }
    $result=@{stage='i219_retry';utc=[DateTime]::UtcNow.ToString('o');drvload=$null;initialize=$null}
    try {
        $relative=[string]$Config.i219_recovery.inf
        if ($relative -notmatch '^Windows[\\/]System32[\\/]DriverStore[\\/]FileRepository[\\/]e1d[^\\/]*\.inf_amd64_[a-fA-F0-9]+[\\/]e1d(?:6[0-9]x64)?\.inf$') { throw 'Chemin du pilote I219 refuse.' }
        $inf=Join-Path (Get-AtelierWinPERoot) $relative
        if (-not (Test-Path $inf -PathType Leaf) -or (Get-FileHash -LiteralPath $inf -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Config.i219_recovery.sha256) { throw 'Pilote I219 injecte absent ou modifie.' }
        Write-Host 'Initialisation du port Ethernet Intel I219 integre...'
        $result.drvload=Invoke-AtelierWinPENetworkCommand -FilePath (Join-Path $env:SystemRoot 'System32\drvload.exe') -Arguments ('"'+$inf+'"')
        if ($result.drvload -eq 0) { $result.initialize=Invoke-AtelierWinPENetworkCommand -FilePath (Join-Path $env:SystemRoot 'System32\wpeutil.exe') -Arguments 'InitializeNetwork /NoWaitForNetwork' }
        if ($result.drvload -ne 0 -or $result.initialize -ne 0) { $result.stage='i219_retry_failed' }
    } catch { $result.stage='i219_retry_failed';Write-Warning 'Le port Ethernet integre reste a verifier ; le dock peut etre utilise.' }
    if ($LogPath) {
        try { New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force | Out-Null;$result | ConvertTo-Json | Set-Content -LiteralPath $LogPath -Encoding UTF8 } catch { }
    }
}
