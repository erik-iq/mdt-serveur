#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$InstallPath,[switch]$CmslInstallOnly)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if ($CmslInstallOnly) {
    # Un nouveau processus est nécessaire après la mise à jour de PowerShellGet/PackageManagement.
    # La session PowerShell 5.1 initiale peut garder les anciennes DLL chargées.
    try {
        Import-Module PowerShellGet -MinimumVersion '2.2.5' -Force -ErrorAction Stop
        $installer=Get-Command Install-Module -ErrorAction Stop
        if (-not $installer.Parameters.ContainsKey('AcceptLicense')) { throw 'PowerShellGet charge ne prend pas en charge AcceptLicense.' }
        Install-Module -Name HPCMSL -RequiredVersion '1.9.0' -Repository PSGallery -Scope AllUsers -AcceptLicense -Force -AllowClobber -Confirm:$false -ErrorAction Stop
        exit 0
    } catch {
        [Console]::Error.WriteLine(('Installation HPCMSL : '+$_.Exception.Message))
        exit 1
    }
}
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$directory=Join-Path $config.data_dir 'hp-repository'
if (-not (Test-Path (Join-Path $directory 'worker-key'))) { throw 'Mettre la console à jour avant de configurer CMSL.' }
# Installer la bibliothèque HP une fois sur le serveur d’acquisition, jamais sur les PC déployés.
$cmslReady=$false;$stage='recherche de CMSL'
try {
    $moduleRoot=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    if (-not (Get-Module -ListAvailable HPCMSL | Where-Object { $_.Version -ge [version]'1.9.0' -and $_.ModuleBase.StartsWith($moduleRoot,[StringComparison]::OrdinalIgnoreCase) })) {
        Write-Host 'Installation de la bibliothèque officielle HP CMSL sur le serveur...'
        $stage='installation du fournisseur NuGet'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force -Confirm:$false | Out-Null
        $stage='mise à niveau de PowerShellGet'
        $installer=Get-Command Install-Module -ErrorAction Stop
        if (-not $installer.Parameters.ContainsKey('AcceptLicense') -or $installer.Module.Version -lt [version]'2.2.5') {
            Write-Host 'Mise à niveau de PowerShellGet vers 2.2.5 pour Windows PowerShell 5.1...'
            # Ne pas transmettre AcceptLicense à l’ancienne commande : cela faisait échouer
            # l’installation IQ-4.9 avant le téléchargement du module HP.
            Install-Module -Name PowerShellGet -RequiredVersion '2.2.5' -Repository PSGallery -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
        }
        $stage='installation de HPCMSL dans une nouvelle session PowerShell'
        $powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','RemoteSigned','-File',$PSCommandPath,'-CmslInstallOnly')
        # Conserver stdout/stderr dans setup.log, y compris les erreurs de la nouvelle session.
        # Sous PowerShell 5.1, une sortie stderr native ne doit pas contourner le contrôle du code de retour.
        $oldPreference=$ErrorActionPreference
        try { $ErrorActionPreference='Continue';$output=@(& $powerShell @arguments 2>&1);$nativeCode=$LASTEXITCODE }
        finally { $ErrorActionPreference=$oldPreference }
        if ($nativeCode -ne 0) { throw ('Installation HPCMSL interrompue (code '+$nativeCode+'). '+(($output | ForEach-Object { [string]$_ }) -join ' ')) }
    }
    $stage='chargement de HPCMSL'
    Import-Module HPCMSL -MinimumVersion '1.9.0' -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'HP-Repository.ps1')
    $stage='vérification des commandes de dépôt'
    foreach ($name in @('Initialize-HPRepository','Set-HPRepositoryConfiguration','Add-HPRepositoryFilter','Invoke-HPRepositorySync','Invoke-HPRepositoryCleanup')) { Get-AtelierHpCmslCommand $name | Out-Null }
    $cmslReady=$true
} catch {
    $message=$_.Exception.Message
    $journal=Join-Path $directory 'setup.log'
    Add-Content -LiteralPath $journal -Value ([DateTime]::UtcNow.ToString('o')+' / '+$stage+' / '+$message) -Encoding UTF8
    Write-Warning ('CMSL indisponible pendant '+$stage+' : '+$message+' Journal : '+$journal+'. HPIA pourra utiliser Internet.')
}
$task=Get-ScheduledTask -TaskName 'AtelierPXE-HpRepository' -ErrorAction SilentlyContinue
if ($task -and $task.State -eq 'Running') {
    if ($cmslReady) { Write-Host 'CMSL charge et commandes vérifiées. Agent déjà actif ; les demandes pourront alimenter le dépôt.' }
    else { Write-Warning 'Agent déjà actif mais CMSL indisponible : le dépôt reste en attente.' }
    return
}
$action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "'+(Join-Path $InstallPath 'scripts\HP-RepositoryWorker.ps1')+'" -InstallPath "'+$InstallPath+'"') -WorkingDirectory $InstallPath
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName 'AtelierPXE-HpRepository' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Description 'Alimente le dépôt local de SoftPaq HP avec CMSL sans installer de pilote sur le serveur.' -Force | Out-Null
Start-ScheduledTask -TaskName 'AtelierPXE-HpRepository'
if ($cmslReady) { Write-Host 'CMSL charge et commandes vérifiées. Agent démarre ; les demandes pourront alimenter le dépôt de .250.' }
else { Write-Warning 'Agent enregistre mais CMSL indisponible : le dépôt reste en attente. Consulter setup.log.' }
