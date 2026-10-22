@echo off
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-WindowsUpdateInstallation.ps1" -VerifyPrevious
if errorlevel 1 echo La vérification a échoué. Consulter les rapports IQ.
pause
