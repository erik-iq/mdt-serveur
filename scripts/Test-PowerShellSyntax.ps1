param([string]$ScriptsPath = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$count = 0
foreach ($file in Get-ChildItem $ScriptsPath -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) {
        $parseErrors | ForEach-Object { Write-Error "$($file.Name):$($_.Extent.StartLineNumber) $($_.Message)" -ErrorAction Continue }
        exit 1
    }
    $count++
}
Write-Host "PowerShell syntax verified: $count files. Windows operations were not executed."
