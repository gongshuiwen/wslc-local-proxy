@echo off
setlocal
set "PSModulePath="
set "wslc_setup_host=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "wslc_setup_host=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%wslc_setup_host%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WslcProxy.ps1" %*
set "wslc_install_exit=%errorlevel%"
pause
exit /b %wslc_install_exit%
