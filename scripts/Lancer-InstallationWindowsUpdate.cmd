@echo off
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-WindowsUpdateInstallation.ps1"
if errorlevel 1 echo Le lancement du test a échoué. Consulter le message et les rapports IQ.
pause
