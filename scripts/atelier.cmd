@echo off
chcp 65001 >nul
setlocal
set "ATELIER_WINPE_KEYBOARD=100c:0000100c"
:launch
echo.
echo Atelier PXE - ouverture de l'assistant...
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Atelier\Launch.ps1
if errorlevel 1 echo L'assistant a échoué. Le journal de démarrage est disponible avec le choix 2.
:menu
echo.
echo Atelier PXE - menu de reprise
echo 1 - Relancer l'assistant
echo 2 - Voir le journal et la configuration réseau
echo 0 - Revenir au terminal
rem Read-Host uses the PowerShell already required by the wizard; choice.exe
rem is not assumed to be présent in a minimal WinPE image.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command "$selection = Read-Host 'Votre choix'; switch -Exact ($selection) { '1' { exit 1 } '2' { exit 2 } '0' { exit 3 } default { exit 0 } }"
if errorlevel 3 goto shell
if errorlevel 2 goto diagnostics
if errorlevel 1 goto launch
goto menu
:diagnostics
if exist X:\Atelier\Logs\startup.log type X:\Atelier\Logs\startup.log
ipconfig
goto menu
:shell
echo Pour rouvrir le menu et l'assistant, tapez simplement : atelier
endlocal
exit /b 0
