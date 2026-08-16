# fabric-engine.ps1

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Setup", "Watchdog", "Teardown")]
    [string]$Phase
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$FabricRoot = "C:\ProgramData\RDPFabric"
$DeadlineFile = Join-Path $FabricRoot "deadline.txt"
$TailscalePath = "C:\Program Files\Tailscale\tailscale.exe"

function Write-FabricLog {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Get-RuntimeMinutes {
    $runtime = 60

    if ($env:RUNTIME_MINUTES) {
        $parsed = 0

        if ([int]::TryParse($env:RUNTIME_MINUTES, [ref]$parsed)) {
            $runtime = $parsed
        }
    }

    if ($env:QUICK_TEST -eq "true") {
        $runtime = 5
    }

    if ($runtime -lt 1) {
        $runtime = 1
    }

    if ($runtime -gt 345) {
        $runtime = 345
    }

    return $runtime
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Configure-Power {
    Write-FabricLog "Configuring power settings..." Cyan

    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change monitor-timeout-ac 0 | Out-Null

    # Prefer Ultimate Performance when available.
    $ultimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"

    try {
        powercfg -duplicatescheme $ultimateGuid 2>$null | Out-Null
    }
    catch {
        # Scheme may already exist.
    }

    $schemes = powercfg /list 2>$null

    $match = $schemes |
        Select-String "Ultimate Performance" |
        Select-Object -First 1

    if ($match) {
        $guid = [regex]::Match(
            $match.ToString(),
            "[a-fA-F0-9-]{36}"
        ).Value

        if ($guid) {
            powercfg -setactive $guid | Out-Null
            Write-FabricLog "Ultimate Performance enabled." Green
            return
        }
    }

    Write-FabricLog "Using current Windows power scheme." Yellow
}

function Configure-Network {
    Write-FabricLog "Applying conservative network optimizations..." Cyan

    # Keep Windows TCP autotuning enabled.
    netsh interface tcp set global `
        autotuninglevel=normal | Out-Null

    # RSS improves network processing on supported adapters.
    try {
        Set-NetOffloadGlobalSetting `
            -ReceiveSideScaling Enabled `
            -ErrorAction SilentlyContinue
    }
    catch {
    }

    # Do not force undocumented registry/network values.
    # Windows will retain its supported defaults.

    Clear-DnsClientCache -ErrorAction SilentlyContinue

    Write-FabricLog "Network configuration completed." Green
}

function Configure-RDP {
    Write-FabricLog "Configuring RDP..." Cyan

    $terminalServer =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"

    Set-ItemProperty `
        -Path $terminalServer `
        -Name "fDenyTSConnections" `
        -Value 0 `
        -Type DWord

    $rdpTcp =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"

    if (Test-Path $rdpTcp) {
        Set-ItemProperty `
            -Path $rdpTcp `
            -Name "UserAuthentication" `
            -Value 1 `
            -Type DWord
    }

    Enable-NetFirewallRule `
        -DisplayGroup "Remote Desktop" `
        -ErrorAction SilentlyContinue

    Set-Service `
        -Name "TermService" `
        -StartupType Automatic

    Start-Service `
        -Name "TermService" `
        -ErrorAction SilentlyContinue

    Write-FabricLog "RDP configured." Green
}

function Configure-User {
    Write-FabricLog "Configuring RDP user..." Cyan

    if (-not $env:RDP_PASS) {
        throw "RDP_PASSWORD secret is missing."
    }

    $securePassword = ConvertTo-SecureString `
        $env:RDP_PASS `
        -AsPlainText `
        -Force

    $existing =
        Get-LocalUser `
            -Name $env:RDP_USER `
            -ErrorAction SilentlyContinue

    if (-not $existing) {

        New-LocalUser `
            -Name $env:RDP_USER `
            -Password $securePassword `
            -Description "RDP Fabric User" `
            -AccountNeverExpires `
            -PasswordNeverExpires `
            -ErrorAction Stop | Out-Null

        Write-FabricLog "Created user $env:RDP_USER." Green
    }
    else {

        Set-LocalUser `
            -Name $env:RDP_USER `
            -Password $securePassword `
            -ErrorAction SilentlyContinue

        Write-FabricLog "Updated user password." Green
    }

    Add-LocalGroupMember `
        -Group "Administrators" `
        -Member $env:RDP_USER `
        -ErrorAction SilentlyContinue

    Add-LocalGroupMember `
        -Group "Remote Desktop Users" `
        -Member $env:RDP_USER `
        -ErrorAction SilentlyContinue
}

function Install-Tailscale {
    Write-FabricLog "Installing Tailscale..." Cyan

    if (Test-Path $TailscalePath) {
        Write-FabricLog "Tailscale already installed." Green
        return
    }

    $installer = Join-Path $env:TEMP "tailscale-setup.msi"

    $url =
        "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"

    Write-FabricLog "Downloading Tailscale..."

    Invoke-WebRequest `
        -Uri $url `
        -OutFile $installer `
        -UseBasicParsing

    if (-not (Test-Path $installer)) {
        throw "Tailscale installer download failed."
    }

    $size = (Get-Item $installer).Length

    if ($size -lt 1MB) {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        throw "Downloaded Tailscale installer appears invalid."
    }

    Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList @(
            "/i",
            "`"$installer`"",
            "/quiet",
            "/norestart"
        ) `
        -Wait `
        -NoNewWindow

    Remove-Item `
        $installer `
        -Force `
        -ErrorAction SilentlyContinue

    if (-not (Test-Path $TailscalePath)) {
        throw "Tailscale installation failed."
    }

    Write-FabricLog "Tailscale installed." Green
}

function Connect-Tailscale {
    Write-FabricLog "Connecting to Tailscale..." Cyan

    if (-not $env:TS_AUTHKEY) {
        throw "TAILSCALE_AUTH_KEY secret is missing."
    }

    $hostname =
        "fabric-node-$($env:RUN_ID)-$($env:MATRIX_ID)"

    & $TailscalePath up `
        "--authkey=$($env:TS_AUTHKEY)" `
        "--hostname=$hostname" `
        "--accept-routes=false" `
        "--unattended"

    if ($LASTEXITCODE -ne 0) {
        throw "Tailscale connection failed."
    }

    $ip = $null

    for ($i = 0; $i -lt 30; $i++) {

        Start-Sleep -Seconds 1

        $ip =
            (& $TailscalePath ip -4 2>$null |
            Out-String).Trim()

        if ($ip -match "^\d{1,3}(\.\d{1,3}){3}$") {
            break
        }
    }

    if (-not $ip) {
        throw "Could not obtain Tailscale IPv4 address."
    }

    Write-FabricLog "Tailscale IPv4: $ip" Green

    $status =
        (& $TailscalePath status 2>$null |
        Out-String).Trim()

    if ($status) {
        Write-Host ""
        Write-Host $status
        Write-Host ""
    }

    return $ip
}

function Configure-LocalFirewall {
    Write-FabricLog "Configuring local firewall..." Cyan

    Enable-NetFirewallRule `
        -DisplayGroup "Remote Desktop" `
        -ErrorAction SilentlyContinue

    # Tailscale normally handles its own connectivity.
    # No broad inbound Internet rule is created here.

    Write-FabricLog "Firewall configuration completed." Green
}

function Create-SessionFiles {
    param(
        [datetime]$Deadline
    )

    New-Item `
        -ItemType Directory `
        -Path $FabricRoot `
        -Force |
        Out-Null

    $Deadline.ToString("o") |
        Set-Content `
            -Path $DeadlineFile `
            -Encoding ASCII `
            -Force

    $info = @"
RDP Fabric
==========

Node: $env:MATRIX_ID
Run ID: $env:RUN_ID
User: $env:RDP_USER
Deadline: $($Deadline.ToString("o"))

Tailscale is used as the private network transport.
"@

    $info |
        Set-Content `
            -Path (Join-Path $FabricRoot "node-info.txt") `
            -Encoding UTF8 `
            -Force
}

function Get-TailscaleHealth {
    if (-not (Test-Path $TailscalePath)) {
        return $false
    }

    try {

        $json =
            & $TailscalePath status --json 2>$null

        if (-not $json) {
            return $false
        }

        $status =
            $json | ConvertFrom-Json

        return ($status.BackendState -eq "Running")
    }
    catch {
        return $false
    }
}

function Get-RdpHealth {
    try {

        $service =
            Get-Service `
                -Name "TermService" `
                -ErrorAction SilentlyContinue

        if (-not $service) {
            return $false
        }

        if ($service.Status -ne "Running") {
            return $false
        }

        $listener =
            Get-NetTCPConnection `
                -LocalPort 3389 `
                -State Listen `
                -ErrorAction SilentlyContinue

        return [bool]$listener
    }
    catch {
        return $false
    }
}

function Start-Watchdog {
    $runtime = Get-RuntimeMinutes

    $start = Get-Date
    $deadline = $start.AddMinutes($runtime)

    if (Test-Path $DeadlineFile) {

        try {
            $saved =
                Get-Content `
                    $DeadlineFile `
                    -Raw

            if ($saved) {
                $deadline =
                    [datetime]::Parse(
                        $saved.Trim(),
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    )
            }
        }
        catch {
            Write-FabricLog `
                "Could not read saved deadline; using current runtime." `
                Yellow
        }
    }

    Write-FabricLog `
        "Watchdog active until $($deadline.ToString('HH:mm:ss'))." `
        Cyan

    while ($true) {

        $remaining =
            $deadline - (Get-Date)

        if ($remaining.TotalSeconds -le 0) {
            break
        }

        $minutes =
            [math]::Floor(
                $remaining.TotalSeconds / 60
            )

        $tsOk = Get-TailscaleHealth
        $rdpOk = Get-RdpHealth

        if (-not $tsOk) {

            Write-FabricLog `
                "Tailscale health check failed; attempting recovery..." `
                Yellow

            try {

                $hostname =
                    "fabric-node-$($env:RUN_ID)-$($env:MATRIX_ID)"

                & $TailscalePath up `
                    "--authkey=$($env:TS_AUTHKEY)" `
                    "--hostname=$hostname" `
                    "--accept-routes=false" `
                    "--unattended" `
                    2>$null |
                    Out-Null
            }
            catch {
            }
        }

        if (-not $rdpOk) {

            Write-FabricLog `
                "RDP health check failed; restarting TermService..." `
                Yellow

            try {
                Restart-Service `
                    -Name "TermService" `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
            catch {
            }
        }

        Write-FabricLog `
            "Heartbeat | Tailscale=$tsOk | RDP=$rdpOk | $minutes min remaining" `
            Cyan

        Start-Sleep -Seconds 60
    }

    Write-FabricLog `
        "Session duration reached. Watchdog stopping." `
        Green
}

function Remove-FabricTasks {
    $tasks = @(
        "RDPFabric-UserTweaks",
        "RDPFabric-ChromeBootstrap",
        "RDPFabric-Timer"
    )

    foreach ($task in $tasks) {

        Unregister-ScheduledTask `
            -TaskName $task `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
}

function Disconnect-Tailscale {
    if (Test-Path $TailscalePath) {

        Write-FabricLog `
            "Disconnecting Tailscale..." `
            Cyan

        & $TailscalePath logout `
            2>$null |
            Out-Null
    }
}

function Remove-FabricData {
    if (Test-Path $FabricRoot) {

        Remove-Item `
            -Path $FabricRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ==============================================================
# MAIN
# ==============================================================

if (-not (Test-Administrator)) {
    throw "fabric-engine.ps1 must run with Administrator privileges."
}

switch ($Phase) {

    "Setup" {

        Write-FabricLog `
            "============================================" `
            Cyan

        Write-FabricLog `
            " RDP FABRIC SETUP" `
            Cyan

        Write-FabricLog `
            "============================================" `
            Cyan

        $runtime = Get-RuntimeMinutes

        $deadline =
            (Get-Date).AddMinutes($runtime)

        Write-FabricLog `
            "Runtime: $runtime minutes" `
            Cyan

        Create-SessionFiles `
            -Deadline $deadline

        Configure-Power

        Configure-Network

        Configure-LocalFirewall

        Configure-User

        Configure-RDP

        Install-Tailscale

        $tailscaleIP =
            Connect-Tailscale

        Write-FabricLog `
            "============================================" `
            Green

        Write-FabricLog `
            " RDP FABRIC READY" `
            Green

        Write-FabricLog `
            "============================================" `
            Green

        Write-Host ""
        Write-Host "RDP USER : $env:RDP_USER"
        Write-Host "TAILSCALE: $tailscaleIP"
        Write-Host "RUNTIME  : $runtime minutes"
        Write-Host "DEADLINE : $($deadline.ToString('HH:mm:ss'))"
        Write-Host ""
    }

    "Watchdog" {

        Write-FabricLog `
            "Starting session watchdog..." `
            Cyan

        Start-Watchdog
    }

    "Teardown" {

        $ErrorActionPreference = "Continue"

        Write-FabricLog `
            "============================================" `
            Yellow

        Write-FabricLog `
            " RDP FABRIC TEARDOWN" `
            Yellow

        Write-FabricLog `
            "============================================" `
            Yellow

        Remove-FabricTasks

        Disconnect-Tailscale

        Remove-FabricData

        Write-FabricLog `
            "Teardown completed." `
            Green
    }
}
```
