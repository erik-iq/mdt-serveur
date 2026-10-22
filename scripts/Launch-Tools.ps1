#requires -Version 5.1
param([string]$DataPath='C:\ProgramData\AtelierPXE')
# Transport UTF-8 pour Python, les journaux et les fichiers texte générés.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
foreach ($atelierTextCommand in @('Get-Content','Set-Content','Add-Content','Out-File','Export-Csv')) {
    $PSDefaultParameterValues[$atelierTextCommand+':Encoding'] = 'utf8'
}

# Entrée compatible avec une ancienne tâche : HPIA s’exécute dans Maintenance, sans interface.
Unregister-ScheduledTask -TaskName 'AtelierPXE-Tools' -Confirm:$false -ErrorAction SilentlyContinue
