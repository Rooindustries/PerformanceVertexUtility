param([string]$HarnessPath = (Join-Path $PSScriptRoot '..\..\LeanClientOptimizer.ps1'))
$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-legacy-smoke-' + [guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    . $HarnessPath -Action ListModules -DataRoot $tempRoot | Out-Null
    # Only operating-system reads are replaced; the real Invoke-SmokeTest decides which checks apply.
    $script:bluetooth = @()
    $script:apps = @()
    $script:services = @{ WlanSvc = 'Running'; bthserv = 'Running'; WinDefend = 'Running'; BFE = 'Running'; mpssvc = 'Running'; WpnService = 'Running'; Dnscache = 'Running' }
    $script:processes = @()
    $script:lookups = 0
    $script:dnsServers = @('192.0.2.53')
    function Get-NetConnectionProfile { @([pscustomobject]@{ Name = 'Fixture network' }) }
    function Resolve-DnsName { $script:lookups++; @([pscustomobject]@{ Name = 'www.microsoft.com' }) }
    function Test-Connection { $script:lookups++; $true }
    function Invoke-WebRequest { $script:lookups++ }
    function Get-DnsClientServerAddress { @([pscustomobject]@{ InterfaceAlias = 'Fixture'; ServerAddresses = $script:dnsServers }) }
    function Get-PnpDevice { if ($script:bluetooth -eq 'unavailable') { throw [Management.Automation.CommandNotFoundException]::new('Get-PnpDevice') }; @($script:bluetooth) }
    function Get-Service { param([string]$Name) if ($script:services.ContainsKey($Name)) { [pscustomobject]@{ Name = $Name; Status = $script:services[$Name]; StartType = 'Automatic' } } }
    function Get-ItemProperty { @($script:apps | ForEach-Object { [pscustomobject]@{ DisplayName = $_ } }) }
    function Get-Process { param([string]$Name) @($script:processes | Where-Object { $_ -eq $Name }) }
    function Get-ChildItem { @([pscustomobject]@{ Name = '1.0.0.0' }) }
    function Names($Result) { @($Result.results | ForEach-Object { $_.name }) }

    $healthy = Invoke-SmokeTest
    Assert ($healthy.pass -and (Names $healthy) -notcontains 'service:Tailscale' -and (Names $healthy) -notcontains 'process:Wispr Flow') 'A healthy PC without Tailscale or Wispr Flow passes the smoke test'
    Assert ((Names $healthy) -notcontains 'service:bthserv') 'A PC without a Bluetooth adapter skips the Bluetooth service check'
    Assert ($script:lookups -eq 0 -and @($healthy.results | Where-Object { $_.name -eq 'dns-client' -and $_.pass }).Count -eq 1) 'The smoke test checks DNS locally without any network lookup'
    $script:dnsServers = @()
    $noServers = Invoke-SmokeTest
    $script:dnsServers = @('192.0.2.53')
    $script:services.Dnscache = 'Stopped'
    $noClient = Invoke-SmokeTest
    $script:services.Dnscache = 'Running'
    Assert ($script:lookups -eq 0 -and -not $noServers.pass -and -not $noClient.pass -and @(@($noServers.results) + @($noClient.results) | Where-Object { $_.name -eq 'dns-client' -and -not $_.pass }).Count -eq 2) 'The local DNS check fails without a DNS server or a running DNS Client service'

    $script:bluetooth = @([pscustomobject]@{ Status = 'Error' })
    $script:services.bthserv = 'Stopped'
    $broken = Invoke-SmokeTest
    Assert (-not $broken.pass -and @($broken.results | Where-Object { $_.name -eq 'service:bthserv' -and -not $_.pass }).Count -eq 1) 'A present Bluetooth adapter in an error state still gets its stopped service reported'

    $script:bluetooth = 'unavailable'
    $unknown = Invoke-SmokeTest
    Assert ((Names $unknown) -contains 'service:bthserv') 'When device discovery is unavailable the Bluetooth service is still checked'

    $script:bluetooth = @()
    $script:services.bthserv = 'Running'
    $script:apps = @('Tailscale', 'Wispr Flow 1.2')
    $installed = Invoke-SmokeTest
    Assert (@($installed.results | Where-Object { $_.name -eq 'service:Tailscale' -and -not $_.pass -and $_.detail -eq 'Service missing' }).Count -eq 1) 'Installed Tailscale without its service fails the smoke test'
    Assert (@($installed.results | Where-Object { $_.name -eq 'process:Wispr Flow' -and -not $_.pass }).Count -eq 1) 'Installed Wispr Flow that is not running fails the smoke test'

    $script:services.Tailscale = 'Running'
    $script:processes = @('Wispr Flow')
    $running = Invoke-SmokeTest
    Assert ($running.pass) 'Installed and running Tailscale and Wispr Flow pass the smoke test'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Assert (-not (Test-Path -LiteralPath $tempRoot)) 'Smoke test fixture leaves no files behind'
