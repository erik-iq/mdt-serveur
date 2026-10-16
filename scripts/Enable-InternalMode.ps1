#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\AtelierPXE\console',
    [ValidateSet('characters','digits')][string]$HostnameSuffixMode='digits'
)
$ErrorActionPreference = 'Stop'
function Get-AtelierActiveDeploymentCount {
    param([Parameter(Mandatory)][string]$Runtime, [Parameter(Mandatory)][string]$Database)
    # Windows PowerShell 5.1 strips embedded quotes in native -c arguments.
    # Feed Python on stdin instead, keeping SQL out of the native command line.
    $activeCheck = @'
import sqlite3, sys
from pathlib import Path
uri = Path(sys.argv[1]).resolve().as_uri() + "?mode=ro"
with sqlite3.connect(uri, uri=True) as connection:
    print(connection.execute("SELECT COUNT(*) FROM deployments WHERE status=?", ("running",)).fetchone()[0])
'@
    $checkOutput = @($activeCheck | & $Runtime - $Database)
    if ($LASTEXITCODE -ne 0) { throw 'Controle des deploiements impossible : Python ou SQLite a echoue.' }
    $count = 0
    if ($checkOutput.Count -ne 1 -or -not [int]::TryParse(([string]$checkOutput[0]).Trim(),[ref]$count) -or $count -lt 0) {
        throw 'Controle des deploiements impossible : resultat Python invalide.'
    }
    return $count
}
Add-Type -AssemblyName System.Security
$configPath = Join-Path $InstallPath 'data-runtime.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (([Uri]$config.base_url).Scheme -ne 'https') { throw 'Le mode interne exige une origine HTTPS.' }
$artifacts = [IO.Path]::GetFullPath((Join-Path $config.data_dir 'artifacts')).TrimEnd('\')
$share = Get-SmbShare -Name 'AtelierImages' -ErrorAction Stop
if ([IO.Path]::GetFullPath($share.Path).TrimEnd('\') -ne $artifacts) { throw 'Le partage AtelierImages ne correspond pas au dossier des fichiers.' }
$runtime = Join-Path $InstallPath '.venv\Scripts\python.exe'
$active = Get-AtelierActiveDeploymentCount -Runtime $runtime -Database (Join-Path $config.data_dir 'deployment.sqlite3')
if ($active -gt 0) { throw 'Terminez les deploiements en cours avant cette operation.' }
$account = 'AtelierPXERead'
$secretPath = Join-Path $config.data_dir 'internal-share.json'
$user = Get-LocalUser -Name $account -ErrorAction SilentlyContinue
if ($user -and -not (Test-Path $secretPath)) { throw 'Le compte AtelierPXERead existe sans configuration geree. Aucun mot de passe modifie.' }
$identity = "$env:COMPUTERNAME\$account"
if (Test-Path $secretPath) {
    $saved = Get-Content -LiteralPath $secretPath -Raw | ConvertFrom-Json
    if ($saved.username -ne $identity) { throw 'Le compte du secret ne correspond pas au serveur.' }
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($saved.password_dpapi),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { $password = [Text.Encoding]::UTF8.GetString($bytes) } finally { [Array]::Clear($bytes,0,$bytes.Length) }
} else {
    $random = New-Object byte[] 48
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($random); $password = [Convert]::ToBase64String($random) + 'aA1!' } finally { $generator.Dispose() }
    $encrypted = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($password),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    # Create with private ACL before writing any encrypted credential.
    New-Item -ItemType File -Path $secretPath -ErrorAction Stop | Out-Null
    & icacls.exe $secretPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' '*S-1-5-19:R' | Out-Null
    if ($LASTEXITCODE -ne 0) { Remove-Item $secretPath; throw 'Protection du secret impossible.' }
    @{username=$identity;password_dpapi=[Convert]::ToBase64String($encrypted)} | ConvertTo-Json | Set-Content -LiteralPath $secretPath -Encoding UTF8
}
$secure = ConvertTo-SecureString $password -AsPlainText -Force
try {
    if (-not $user) { New-LocalUser -Name $account -Password $secure -PasswordNeverExpires -UserMayNotChangePassword -Description 'Lecture Atelier PXE geree par le serveur' | Out-Null }
    Enable-LocalUser -Name $account
} finally { $secure.Dispose(); $password=$null }
Grant-SmbShareAccess -Name 'AtelierImages' -AccountName $identity -AccessRight Read -Force | Out-Null
Set-SmbShare -Name 'AtelierImages' -EncryptData $true -Force
& icacls.exe $artifacts /grant "${identity}:(OI)(CI)RX" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Permissions de lecture NTFS impossibles.' }
$backup = $configPath + '.before-internal-' + [guid]::NewGuid().ToString('N')
Copy-Item -LiteralPath $configPath -Destination $backup
$config | Add-Member -NotePropertyName hostname_prefix -NotePropertyValue 'LE-T15-' -Force
$config | Add-Member -NotePropertyName hostname_suffix_mode -NotePropertyValue $HostnameSuffixMode -Force
$config | Add-Member -NotePropertyName internal_mode -NotePropertyValue $true -Force
$config | Add-Member -NotePropertyName automatic_windows -NotePropertyValue $true -Force
$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
Stop-ScheduledTask -TaskName 'AtelierPXE-Console'
$deadline = (Get-Date).AddSeconds(20)
while ((Get-ScheduledTask -TaskName 'AtelierPXE-Console').State -eq 'Running') {
    if ((Get-Date) -gt $deadline) { throw 'La console ne s arrete pas. Configuration sauvegardee.' }
    Start-Sleep -Milliseconds 250
}
Start-ScheduledTask -TaskName 'AtelierPXE-Console'
$deadline = (Get-Date).AddSeconds(25)
do {
    try { $options = Invoke-RestMethod ($config.base_url.TrimEnd('/') + '/api/session') -TimeoutSec 2 } catch { $options=$null }
    if ($options.internal_mode -and $options.automatic_windows) {
        Write-Host 'Mode interne actif : console sans jeton, PXE sans code ni saisie SMB.' -ForegroundColor Green
        Write-Host 'Nouvelles installations : Administrateur sans mot de passe, configuration automatique et mises a jour.'
        Write-Host 'Reconstruisez maintenant une nouvelle image WinPE INTERNE-1.'
        return
    }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
throw "Le mode interne ne repond pas. Configuration precedente : $backup"
