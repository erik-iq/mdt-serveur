#requires -Version 5.1
param([string]$DataPath='C:\ProgramData\AtelierPXE')
$ErrorActionPreference='Stop'
$mutex=New-Object Threading.Mutex($false,'Local\AtelierPXE-Tools')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); return }
try {
    $statePath=Join-Path $DataPath 'maintenance.json'
    if (-not (Test-Path $statePath)) { return }
    $state=Get-Content $statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($state.status -notin @('completed','needs_attention')) { return }
    $path=Join-Path $DataPath 'ready-tools.json'
    if (Test-Path $path) {
        foreach ($tool in @(Get-Content $path -Encoding UTF8 -Raw | ConvertFrom-Json)) {
            $marker=Join-Path $DataPath ('tool-opened-' + $tool.sha256)
            if (Test-Path $marker) { continue }
            $root=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'AtelierPXE\Tools')).TrimEnd('\') + '\'
            $exe=[IO.Path]::GetFullPath($tool.path)
            if (-not $exe.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($exe) -ine 'HPImageAssistant.exe') { throw 'Outil HP hors du dossier approuve.' }
            if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $tool.sha256 -or (Get-AuthenticodeSignature $exe).Status -ne 'Valid') { throw 'Integrite de HP Image Assistant non verifiee.' }
            Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) | Out-Null
            Set-Content -LiteralPath $marker -Value ([DateTime]::UtcNow.ToString('o')) -Encoding ASCII
        }
    }
    Unregister-ScheduledTask -TaskName 'AtelierPXE-Tools' -Confirm:$false -ErrorAction SilentlyContinue
} catch {
    Add-Content -LiteralPath (Join-Path $DataPath 'first-logon.log') -Value 'Ouverture automatique HP Image Assistant impossible : utiliser le raccourci du bureau.' -Encoding UTF8
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
