@echo off
setlocal
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WslcProxy.ps1" %*
set "wslc_install_exit=%errorlevel%"
pause
exit /b %wslc_install_exit%
