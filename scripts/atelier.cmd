@echo off
setlocal
:launch
echo.
echo Atelier PXE - ouverture de l'assistant...
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Atelier\Launch.ps1
if errorlevel 1 echo L'assistant a echoue. Le journal de demarrage est disponible avec le choix 5.
:menu
echo.
echo Atelier PXE - menu de reprise
echo 1 - Relancer l'assistant
echo 2 - Clavier francais AZERTY, puis relancer
echo 3 - Clavier suisse romand, puis relancer
echo 4 - Clavier anglais US, puis relancer
echo 5 - Voir le journal et la configuration reseau
echo 0 - Revenir au terminal
rem Read-Host uses the PowerShell already required by the wizard; choice.exe
rem is not assumed to be present in a minimal WinPE image.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command "$selection = Read-Host 'Votre choix'; switch -Exact ($selection) { '1' { exit 1 } '2' { exit 2 } '3' { exit 3 } '4' { exit 4 } '5' { exit 5 } '0' { exit 6 } default { exit 0 } }"
if errorlevel 7 goto shell
if errorlevel 6 goto shell
if errorlevel 5 goto diagnostics
if errorlevel 4 goto keyboard_us
if errorlevel 3 goto keyboard_ch
if errorlevel 2 goto keyboard_fr
if errorlevel 1 goto launch
goto menu
:keyboard_fr
set "ATELIER_WINPE_KEYBOARD=040c:0000040c"
goto launch
:keyboard_ch
set "ATELIER_WINPE_KEYBOARD=100c:0000100c"
goto launch
:keyboard_us
set "ATELIER_WINPE_KEYBOARD=0409:00000409"
goto launch
:diagnostics
if exist X:\Atelier\Logs\startup.log type X:\Atelier\Logs\startup.log
ipconfig
goto menu
:shell
echo Pour rouvrir le menu et l'assistant, tapez simplement : atelier
endlocal
exit /b 0
