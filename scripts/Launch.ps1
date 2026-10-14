# Run inside the separate WinPE boot image, after wpeinit.
$ErrorActionPreference = 'Stop'
$config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$rootCertificate = Join-Path $PSScriptRoot 'trusted-root.cer'
if (Test-Path $rootCertificate) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { $store.Add((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($rootCertificate))) } finally { $store.Close() }
}
Write-Host 'Atelier PXE — déploiement Windows autorisé depuis la console' -ForegroundColor Cyan
$id = Read-Host 'Identifiant du déploiement'
$secret = Read-Host 'Jeton du déploiement' -AsSecureString
$credential = New-Object PSCredential('deployment', $secret)
$image = Read-Host 'Chemin du WIM accessible (ex. \\SERVEUR\DeploymentShare$\Operating Systems\Windows11\install.wim)'
Write-Host 'Si le partage exige une authentification, connectez-le auparavant avec net use, sans enregistrer de mot de passe dans WinPE.'
try {
    $params = @{ServerUrl=$config.server_url; DeploymentId=$id; Token=$credential.GetNetworkCredential().Password; ImagePath=$image}
    if ($config.allow_http_for_lab) { $params.AllowHttpForLab = $true }
    & (Join-Path $PSScriptRoot 'Deploy.ps1') @params
} finally { $params = $null; $credential = $null; $secret = $null }
