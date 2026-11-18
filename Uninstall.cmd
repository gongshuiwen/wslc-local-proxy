@echo off
setlocal
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-WslcProxy.ps1" %*
set "wslc_uninstall_exit=%errorlevel%"
pause
exit /b %wslc_uninstall_exit%
