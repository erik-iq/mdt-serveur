@echo off
set "ATELIER_HPIA_SCRIPT=%~dp0Test-HPIA.ps1"
powershell.exe -NoLogo -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File '+[char]34+$env:ATELIER_HPIA_SCRIPT+[char]34)"
