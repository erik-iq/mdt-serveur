#requires -Version 5.1
param([string]$DataPath='C:\ProgramData\AtelierPXE')
# Compatibility entry for an old task: HPIA now runs in Maintenance, never as a GUI.
Unregister-ScheduledTask -TaskName 'AtelierPXE-Tools' -Confirm:$false -ErrorAction SilentlyContinue
