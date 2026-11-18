@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WslcProxy.ps1" %*
set "wslc_install_exit=%errorlevel%"
pause
exit /b %wslc_install_exit%
