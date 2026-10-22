@echo off
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-WindowsUpdate.ps1"
if errorlevel 1 echo Échec ou diagnostic incomplet. Consulter les rapports WindowsUpdate dans le dossier IQ_.
pause
