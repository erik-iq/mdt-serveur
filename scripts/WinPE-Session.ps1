# Shared WinPE startup helpers. Never record error messages, invocation text or
# session objects: these can contain a boot code, agent token or SMB password.
function Write-AtelierBootEvent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('Starting','ConfigurationReady','CertificateReady','KeyboardReady','KeyboardFailed','OpeningWizard','Closed','Failed')]
        [string]$Stage,
        [System.Management.Automation.ErrorRecord]$Failure
    )
    $entry = [ordered]@{utc=[DateTime]::UtcNow.ToString('o'); stage=$Stage}
    if ($Failure) {
        $entry.type = $Failure.Exception.GetType().FullName
        $entry.script = [IO.Path]::GetFileName($Failure.InvocationInfo.ScriptName)
        $entry.line = $Failure.InvocationInfo.ScriptLineNumber
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $Path -Encoding UTF8
    } catch { Write-Warning 'Impossible de creer le journal de demarrage WinPE.' }
}

function Set-AtelierOperatorKeyboard {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('100c:0000100c')]
        [string]$Layout
    )
    & wpeutil.exe SetKeyboardLayout $Layout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "WinPE ne peut pas activer le clavier $Layout (code $LASTEXITCODE)." }
    # wpeutil sets the WinPE default. Select the layout on this UI thread too,
    # using the same fixed French Swiss layout as the offline boot image.
    Add-Type -AssemblyName System.Windows.Forms
    $cultureId = [Convert]::ToInt32($Layout.Substring(0,4),16)
    $language = [Windows.Forms.InputLanguage]::FromCulture([Globalization.CultureInfo]::GetCultureInfo($cultureId))
    if (-not $language -or $language.Culture.LCID -ne $cultureId) {
        throw "Le clavier francais suisse $Layout est indisponible. Reconstruire WinPE et consulter le journal de demarrage."
    }
    [Windows.Forms.InputLanguage]::CurrentInputLanguage = $language
}
