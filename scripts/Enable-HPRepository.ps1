#requires -Version 5.1
#requires -RunAsAdministrator
param([string]$InstallPath,[switch]$CmslInstallOnly)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if ($CmslInstallOnly) {
    # A fresh process is required after updating PowerShellGet/PackageManagement.
    # The original Windows PowerShell 5.1 session can keep the old DLLs loaded.
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
if (-not (Test-Path (Join-Path $directory 'worker-key'))) { throw 'Mettre la console a jour avant de configurer CMSL.' }
# Install the HP library once on the acquisition machine, never on deployed PCs.
$cmslReady=$false;$stage='recherche de CMSL'
try {
    $moduleRoot=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')).TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    if (-not (Get-Module -ListAvailable HPCMSL | Where-Object { $_.Version -ge [version]'1.9.0' -and $_.ModuleBase.StartsWith($moduleRoot,[StringComparison]::OrdinalIgnoreCase) })) {
        Write-Host 'Installation de la bibliotheque officielle HP CMSL sur le serveur...'
        $stage='installation du fournisseur NuGet'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force -Confirm:$false | Out-Null
        $stage='mise a niveau de PowerShellGet'
        $installer=Get-Command Install-Module -ErrorAction Stop
        if (-not $installer.Parameters.ContainsKey('AcceptLicense') -or $installer.Module.Version -lt [version]'2.2.5') {
            Write-Host 'Mise a niveau de PowerShellGet vers 2.2.5 pour Windows PowerShell 5.1...'
            # Do not pass AcceptLicense to the old command: that caused IQ-4.9
            # setup to fail before HP's module could be downloaded.
            Install-Module -Name PowerShellGet -RequiredVersion '2.2.5' -Repository PSGallery -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
        }
        $stage='installation de HPCMSL dans une nouvelle session PowerShell'
        $powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','RemoteSigned','-File',$PSCommandPath,'-CmslInstallOnly')
        # Keep stdout/stderr for a useful setup.log, including failures from the
        # fresh session. Native stderr must not bypass the exit-code check in 5.1.
        $oldPreference=$ErrorActionPreference
        try { $ErrorActionPreference='Continue';$output=@(& $powerShell @arguments 2>&1);$nativeCode=$LASTEXITCODE }
        finally { $ErrorActionPreference=$oldPreference }
        if ($nativeCode -ne 0) { throw ('Installation HPCMSL interrompue (code '+$nativeCode+'). '+(($output | ForEach-Object { [string]$_ }) -join ' ')) }
    }
    $stage='chargement de HPCMSL'
    Import-Module HPCMSL -MinimumVersion '1.9.0' -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'HP-Repository.ps1')
    $stage='verification des commandes de depot'
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
    if ($cmslReady) { Write-Host 'CMSL charge et commandes verifiees. Agent deja actif ; les demandes pourront alimenter le depot.' }
    else { Write-Warning 'Agent deja actif mais CMSL indisponible : le depot reste en attente.' }
    return
}
$action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "'+(Join-Path $InstallPath 'scripts\HP-RepositoryWorker.ps1')+'" -InstallPath "'+$InstallPath+'"') -WorkingDirectory $InstallPath
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName 'AtelierPXE-HpRepository' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Description 'Alimente le depot local de SoftPaq HP avec CMSL sans installer de pilote sur le serveur.' -Force | Out-Null
Start-ScheduledTask -TaskName 'AtelierPXE-HpRepository'
if ($cmslReady) { Write-Host 'CMSL charge et commandes verifiees. Agent demarre ; les demandes pourront alimenter le depot de .250.' }
else { Write-Warning 'Agent enregistre mais CMSL indisponible : le depot reste en attente. Consulter setup.log.' }
