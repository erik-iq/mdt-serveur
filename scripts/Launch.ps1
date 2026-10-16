# Run inside the separate WinPE boot image, after wpeinit.
param([switch]$TextMode)
$ErrorActionPreference = 'Stop'
$bootLog = Join-Path $PSScriptRoot 'Logs\startup.log'
. (Join-Path $PSScriptRoot 'WinPE-Session.ps1')
Write-AtelierBootEvent -Path $bootLog -Stage Starting
try {
    $config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    if (-not $config.server_url) { throw 'Adresse du serveur absente de config.json.' }
    Write-Host ('Atelier PXE | ' + $config.boot_release + ' | ' + $config.server_url) -ForegroundColor Cyan
    Write-AtelierBootEvent -Path $bootLog -Stage ConfigurationReady
    $layout = if ($env:ATELIER_WINPE_KEYBOARD) { $env:ATELIER_WINPE_KEYBOARD } elseif ($config.winpe_keyboard_layout) { $config.winpe_keyboard_layout } else { '040c:0000040c' }
    try {
        Set-AtelierOperatorKeyboard -Layout $layout
        Write-AtelierBootEvent -Path $bootLog -Stage KeyboardReady
    } catch {
        # Leave the keyboard selector accessible if the requested layout is missing.
        Write-AtelierBootEvent -Path $bootLog -Stage KeyboardFailed -Failure $_
        Write-Warning $_.Exception.Message
    }
    $rootCertificate = Join-Path $PSScriptRoot 'trusted-root.cer'
    if (Test-Path $rootCertificate) {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        try { $store.Add((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($rootCertificate))) } finally { $store.Close() }
    }
    Write-AtelierBootEvent -Path $bootLog -Stage CertificateReady
    if (-not $TextMode) {
        Write-AtelierBootEvent -Path $bootLog -Stage OpeningWizard
        & (Join-Path $PSScriptRoot 'Wizard.ps1') -Config $config
        Write-AtelierBootEvent -Path $bootLog -Stage Closed
        return
    }
    Write-Host 'Atelier PXE - deploiement Windows autorise depuis la console' -ForegroundColor Cyan
    $id = Read-Host 'Identifiant du deploiement'
    $secret = Read-Host 'Jeton du deploiement' -AsSecureString
    $credential = New-Object PSCredential('deployment', $secret)
    $image = Read-Host 'Chemin du WIM accessible (ex. \\SERVEUR\DeploymentShare$\Operating Systems\Windows11\install.wim)'
    Write-Host 'Si le partage exige une authentification, connectez-le auparavant avec net use, sans enregistrer de mot de passe dans WinPE.'
    try {
        $params = @{ServerUrl=$config.server_url; DeploymentId=$id; Token=$credential.GetNetworkCredential().Password; ImagePath=$image}
        if ($config.allow_http_for_lab) { $params.AllowHttpForLab = $true }
        & (Join-Path $PSScriptRoot 'Deploy.ps1') @params
    } finally { $params = $null; $credential = $null; $secret = $null }
    Write-AtelierBootEvent -Path $bootLog -Stage Closed
} catch {
    Write-AtelierBootEvent -Path $bootLog -Stage Failed -Failure $_
    Write-Host 'Echec du lancement de l assistant.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ('Emplacement : ' + [IO.Path]::GetFileName($_.InvocationInfo.ScriptName) + ':' + $_.InvocationInfo.ScriptLineNumber)
    Write-Host ('Journal de demarrage : ' + $bootLog)
    Write-Host 'Le menu atelier permet de relancer dans un nouveau processus.'
    exit 1
}
