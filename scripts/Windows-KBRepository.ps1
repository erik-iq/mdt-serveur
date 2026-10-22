#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallPath,[ValidateSet('Enable','Refresh')][string]$Mode='Enable',[switch]$RunNow)
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Console-Installation.ps1')
$InstallPath=Resolve-AtelierConsoleInstallation $InstallPath
$config=Get-Content (Join-Path $InstallPath 'data-runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Mode -eq 'Refresh') {
    $headers=@{}
    if (-not $config.internal_mode) { $headers.Authorization='Bearer '+(Get-Content (Join-Path $config.data_dir 'admin-token') -Raw -Encoding UTF8).Trim() }
    # La veille des versions reste indépendante des contextes KB déjà connus.
    try {
        Invoke-RestMethod -Uri ('http://127.0.0.1:'+$config.port+'/api/maintenance/windows/releases/refresh') -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body '{}' -TimeoutSec 30 | Out-Null
        Write-Host 'Vérification des nouvelles versions Windows demandée auprès de Microsoft.'
    } catch { Write-Warning ('Veille des versions Windows non lancée : '+$_.Exception.Message) }
    try {
        $result=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$config.port+'/api/maintenance/windows/kb/refresh') -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body '{}' -TimeoutSec 30
        Write-Host ('Recherche et téléchargement des KB demandés pour '+@($result.jobs).Count+' contexte(s) Windows.')
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 409) { Write-Host 'Aucune version connue pour le moment. Le premier poste transmettra son contexte exact.';return }
        throw
    }
    return
}
$old=Get-ScheduledTask -TaskName 'AtelierPXE-WindowsImageMaintenance' -ErrorAction SilentlyContinue
if ($old) {
    if ($old.State -eq 'Running') { throw 'Annuler la préparation WIM active avec Stop-WindowsImageMaintenance.ps1 avant ce changement de méthode.' }
    Disable-ScheduledTask -TaskName 'AtelierPXE-WindowsImageMaintenance' | Out-Null
}
$powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script=Join-Path $InstallPath 'scripts\Windows-KBRepository.ps1'
$action=New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "'+$script+'" -InstallPath "'+$InstallPath+'" -Mode Refresh')
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'AtelierPXE-WindowsKBRepository' -Action $action -Trigger (New-ScheduledTaskTrigger -Daily -At '02:00') -Principal $principal -Settings $settings -Force | Out-Null
if ($RunNow) { Start-ScheduledTask -TaskName 'AtelierPXE-WindowsKBRepository' }
Write-Host 'Cache KB configuré : téléchargement sur .250 chaque jour à 02:00, installation pendant la préparation Windows des postes.' -ForegroundColor Green
