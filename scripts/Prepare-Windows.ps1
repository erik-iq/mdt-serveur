
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}
#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$power = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
New-Item -Path $power -Force | Out-Null
New-ItemProperty -Path $power -Name HiberbootEnabled -Value 0 -PropertyType DWord -Force | Out-Null
if ((Get-ItemProperty -Path $power -Name HiberbootEnabled).HiberbootEnabled -ne 0) { throw 'Désactivation du démarrage rapide Windows non vérifiée.' }
$dataPath = Join-Path $env:ProgramData 'AtelierPXE'
$payload = Get-Content (Join-Path $dataPath 'personalization.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-Item -Path $policies -Force | Out-Null
# Ignorer l’animation de première connexion ; Windows termine toujours sa configuration requise.
New-ItemProperty $policies -Name EnableFirstLogonAnimation -Value 0 -PropertyType DWord -Force | Out-Null
if (-not $payload.settings.unattended) { return }
# Le SID 500 existe dans toutes les langues ; ne pas créer son nom réservé.
$administrator = @(Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' })
if ($administrator.Count -ne 1) { throw 'Compte administrateur intégre introuvable.' }
$collision = Get-LocalUser -Name 'Administrateur' -ErrorAction SilentlyContinue
if ($collision -and $collision.SID -ne $administrator[0].SID) { throw 'Le nom Administrateur appartient déjà à un autre compte.' }
if ($administrator[0].Name -ne 'Administrateur') { Rename-LocalUser -SID $administrator[0].SID -NewName 'Administrateur' }
$empty = New-Object Security.SecureString
try { Set-LocalUser -SID $administrator[0].SID -Password $empty -PasswordNeverExpires $true }
finally { $empty.Dispose() }
Enable-LocalUser -SID $administrator[0].SID
if (-not (Get-LocalUser -SID $administrator[0].SID).Enabled) { throw 'Activation du compte administrateur intégre non vérifiée.' }
# Conserver UAC et l’approbation administrateur, compatibles avec les applications Store.
$policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty $policies -Name EnableLUA -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty $policies -Name FilterAdministratorToken -Value 1 -PropertyType DWord -Force | Out-Null
# Conserver le refus Windows des connexions distantes avec mot de passe vide.
New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LimitBlankPasswordUse -Value 1 -PropertyType DWord -Force | Out-Null
