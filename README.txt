WSLC Local Proxy

See README.md for the complete Chinese usage guide, configuration precedence,
architecture, limitations, build/test instructions, and uninstall procedure.

Build:        .\Build.ps1
Automatic:    .\Install-WslcProxy.ps1 -Auto
Manual:       .\Install-WslcProxy.ps1 -ProxyUrl http://127.0.0.1:7890
Show config:  Get-WslcProxyConfig
Set proxy:    Set-WslcProxy -ProxyUrl http://127.0.0.1:7890
Return auto:  Set-WslcProxy -Auto
Uninstall:    .\Uninstall-WslcProxy.ps1
