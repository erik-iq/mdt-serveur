#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$power = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
New-Item -Path $power -Force | Out-Null
New-ItemProperty -Path $power -Name HiberbootEnabled -Value 0 -PropertyType DWord -Force | Out-Null
if ((Get-ItemProperty -Path $power -Name HiberbootEnabled).HiberbootEnabled -ne 0) { throw 'Desactivation du demarrage rapide Windows non verifiee.' }
$dataPath = Join-Path $env:ProgramData 'AtelierPXE'
$payload = Get-Content (Join-Path $dataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-Item -Path $policies -Force | Out-Null
# Skip the native first-sign-in animation; Windows still completes required setup.
New-ItemProperty $policies -Name EnableFirstLogonAnimation -Value 0 -PropertyType DWord -Force | Out-Null
if (-not $payload.settings.unattended) { return }
# SID 500 exists on every Windows language; do not attempt to create its reserved name.
$administrator = @(Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' })
if ($administrator.Count -ne 1) { throw 'Compte administrateur integre introuvable.' }
$collision = Get-LocalUser -Name 'Administrateur' -ErrorAction SilentlyContinue
if ($collision -and $collision.SID -ne $administrator[0].SID) { throw 'Le nom Administrateur appartient deja a un autre compte.' }
if ($administrator[0].Name -ne 'Administrateur') { Rename-LocalUser -SID $administrator[0].SID -NewName 'Administrateur' }
$empty = New-Object Security.SecureString
try { Set-LocalUser -SID $administrator[0].SID -Password $empty -PasswordNeverExpires $true }
finally { $empty.Dispose() }
Enable-LocalUser -SID $administrator[0].SID
# Keep UAC and administrator approval mode, including compatibility with Store apps.
$policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty $policies -Name EnableLUA -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty $policies -Name FilterAdministratorToken -Value 1 -PropertyType DWord -Force | Out-Null
# Keep Windows' default refusal of remote blank-password logons.
New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LimitBlankPasswordUse -Value 1 -PropertyType DWord -Force | Out-Null
