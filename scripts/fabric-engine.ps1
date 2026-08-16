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
$NodeInfoFile = Join-Path $FabricRoot "node-info.txt"

$TailscalePath =
    "C:\Program Files\Tailscale\tailscale.exe"

# ==============================================================
# HELPERS
# ==============================================================

function Write-FabricLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host `
        "[$(Get-Date -Format 'HH:mm:ss')] $Message" `
        -ForegroundColor $Color
}

function Test-Admin {
    $identity =
        [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal =
        New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Get-SessionRuntime {
    $runtime = 60

    if (-not [string]::IsNullOrWhiteSpace(
        $env:RUNTIME_MINUTES
    )) {

        $parsed = 0

        if ([int]::TryParse(
            $env:RUNTIME_MINUTES,
            [ref]$parsed
        )) {
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

function Ensure-FabricDirectory {
    if (-not (Test-Path $FabricRoot)) {
        New-Item `
            -Path $FabricRoot `
            -ItemType Directory `
            -Force |
            Out-Null
    }
}

# ==============================================================
# POWER
# ==============================================================

function Configure-Power {
    Write-FabricLog `
        "Configuring power management..." `
        Cyan

    powercfg /change standby-timeout-ac 0 |
        Out-Null

    powercfg /change monitor-timeout-ac 0 |
        Out-Null

    powercfg /hibernate off |
        Out-Null

    # Prefer Ultimate Performance where Windows provides it.
    try {
        powercfg `
            -duplicatescheme `
            "e9a42b02-d5df-448d-aa00-03f14749eb61" `
            2>$null |
            Out-Null
    }
    catch {
    }

    $schemes = powercfg /list 2>$null

    $match =
        $schemes |
        Select-String "Ultimate Performance" |
        Select-Object -First 1

    if ($match) {

        $guid =
            [regex]::Match(
                $match.ToString(),
                "[a-fA-F0-9-]{36}"
            ).Value

        if ($guid) {
            powercfg -setactive $guid |
                Out-Null

            Write-FabricLog `
                "Ultimate Performance selected." `
                Green

            return
        }
    }

    Write-FabricLog `
        "Ultimate Performance unavailable; keeping current scheme." `
        Yellow
}

# ==============================================================
# NETWORK
# ==============================================================

function Configure-Network {
    Write-FabricLog `
        "Configuring supported network settings..." `
        Cyan

    # Keep Windows autotuning at its supported normal level.
    netsh interface tcp set global `
        autotuninglevel=normal |
        Out-Null

    # RSS can improve packet processing on supported adapters.
    try {
        Set-NetOffloadGlobalSetting `
            -ReceiveSideScaling Enabled `
            -ErrorAction SilentlyContinue
    }
    catch {
    }

    # Refresh local DNS cache.
    Clear-DnsClientCache `
        -ErrorAction SilentlyContinue

    Write-FabricLog `
        "Network configuration complete." `
        Green
}

# ==============================================================
# RDP
# ==============================================================

function Configure-RDP {
    Write-FabricLog `
        "Configuring Remote Desktop..." `
        Cyan

    $terminalServer =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"

    Set-ItemProperty `
        -Path $terminalServer `
        -Name "fDenyTSConnections" `
        -Value 0 `
        -Type DWord `
        -Force

    $rdpTcp =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"

    if (Test-Path $rdpTcp) {

        Set-ItemProperty `
            -Path $rdpTcp `
            -Name "UserAuthentication" `
            -Value 1 `
            -Type DWord `
            -Force
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

    Write-FabricLog `
        "RDP configuration complete." `
        Green
}

# ==============================================================
# USER
# ==============================================================

function Configure-RDPUser {
    Write-FabricLog `
        "Configuring RDP user..." `
        Cyan

    if ([string]::IsNullOrWhiteSpace($env:RDP_PASS)) {
        throw "RDP_PASSWORD secret is missing."
    }

    $password =
        ConvertTo-SecureString `
            $env:RDP_PASS `
            -AsPlainText `
            -Force

    $user =
        Get-LocalUser `
            -Name $env:RDP_USER `
            -ErrorAction SilentlyContinue

    if (-not $user) {

        New-LocalUser `
            -Name $env:RDP_USER `
            -Password $password `
            -Description "RDP Fabric User" `
            -AccountNeverExpires `
            -PasswordNeverExpires `
            -ErrorAction Stop |
            Out-Null

        Write-FabricLog `
            "Created $env:RDP_USER." `
            Green
    }
    else {

        Set-LocalUser `
            -Name $env:RDP_USER `
            -Password $password `
            -ErrorAction SilentlyContinue

        Write-FabricLog `
            "Updated password for $env:RDP_USER." `
            Green
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

# ==============================================================
# TAILSCALE INSTALL
# ==============================================================

function Install-Tailscale {
    Write-FabricLog `
        "Checking Tailscale installation..." `
        Cyan

    if (Test-Path $TailscalePath) {

        Write-FabricLog `
            "Tailscale is already installed." `
            Green

        return
    }

    $installer =
        Join-Path `
            $env:TEMP `
            "tailscale-setup.msi"

    $url =
        "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"

    Write-FabricLog `
        "Downloading Tailscale..." `
        Cyan

    Invoke-WebRequest `
        -Uri $url `
        -OutFile $installer `
        -UseBasicParsing

    if (-not (Test-Path $installer)) {
        throw "Tailscale installer was not downloaded."
    }

    $size =
        (Get-Item $installer).Length

    if ($size -lt 1MB) {

        Remove-Item `
            $installer `
            -Force `
            -ErrorAction SilentlyContinue

        throw "Tailscale installer appears invalid."
    }

    $process =
        Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList @(
                "/i",
                "`"$installer`"",
                "/quiet",
                "/norestart"
            ) `
            -Wait `
            -PassThru `
            -NoNewWindow

    Remove-Item `
        $installer `
        -Force `
        -ErrorAction SilentlyContinue

    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Tailscale MSI failed with exit code $($process.ExitCode)."
    }

    if (-not (Test-Path $TailscalePath)) {
        throw "Tailscale executable was not found after installation."
    }

    Write-FabricLog `
        "Tailscale installation complete." `
        Green
}

# ==============================================================
# TAILSCALE CONNECTION
# ==============================================================

function Connect-Tailscale {
    Write-FabricLog `
        "Connecting to Tailscale..." `
        Cyan

    if ([string]::IsNullOrWhiteSpace($env:TS_AUTHKEY)) {
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

    for ($attempt = 1; $attempt -le 30; $attempt++) {

        Start-Sleep -Seconds 1

        $ip =
            (& $TailscalePath ip -4 2>$null |
            Out-String).Trim()

        if ($ip -match "^\d{1,3}(\.\d{1,3}){3}$") {
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw "Tailscale IPv4 address was not obtained."
    }

    Write-FabricLog `
        "Tailscale IPv4: $ip" `
        Green

    Write-Host ""
    Write-Host "--- Tailscale Status ---"

    & $TailscalePath status

    return $ip
}

# ==============================================================
# FILES
# ==============================================================

function Create-SessionInfo {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Deadline
    )

    Ensure-FabricDirectory

    $Deadline.ToString("o") |
        Set-Content `
            -Path $DeadlineFile `
            -Encoding ASCII `
            -Force

    $info = @"
RDP Fabric
==============================

Node ID:
$env:MATRIX_ID

GitHub Run:
$env:RUN_ID

RDP User:
$env:RDP_USER

Runtime:
$(Get-SessionRuntime) minutes

Deadline:
$($Deadline.ToString("o"))

Transport:
Tailscale

Created:
$(Get-Date -Format "o")
"@

    $info |
        Set-Content `
            -Path $NodeInfoFile `
            -Encoding UTF8 `
            -Force
}

# ==============================================================
# HEALTH
# ==============================================================

function Test-TailscaleHealth {

    if (-not (Test-Path $TailscalePath)) {
        return $false
    }

    try {

        $json =
            & $TailscalePath status --json 2>$null

        if ([string]::IsNullOrWhiteSpace($json)) {
            return $false
        }

        $status =
            $json | ConvertFrom-Json

        return (
            $status.BackendState -eq "Running"
        )
    }
    catch {
        return $false
    }
}

function Test-RDPHealth {

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

function Test-InternetHealth {

    try {

        $test =
            Test-NetConnection `
                -ComputerName "1.1.1.1" `
                -Port 443 `
                -WarningAction SilentlyContinue

        return [bool]$test.TcpTestSucceeded
    }
    catch {
        return $false
    }
}

# ==============================================================
# WATCHDOG
# ==============================================================

function Start-SessionWatchdog {

    $runtime =
        Get-SessionRuntime

    $deadline =
        (Get-Date).AddMinutes($runtime)

    if (Test-Path $DeadlineFile) {

        try {

            $saved =
                Get-Content `
                    -Path $DeadlineFile `
                    -Raw

            if (-not [string]::IsNullOrWhiteSpace($saved)) {

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
                "Could not read saved deadline." `
                Yellow
        }
    }

    Write-FabricLog `
        "Watchdog running until $($deadline.ToString('HH:mm:ss'))." `
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

        # ------------------------------------------------------
        # TAILSCALE
        # ------------------------------------------------------

        $tsOk =
            Test-TailscaleHealth

        if (-not $tsOk) {

            Write-FabricLog `
                "Tailscale health check failed. Recovering..." `
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

        # ------------------------------------------------------
        # RDP
        # ------------------------------------------------------

        $rdpOk =
            Test-RDPHealth

        if (-not $rdpOk) {

            Write-FabricLog `
                "RDP health check failed. Restarting TermService..." `
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

        # ------------------------------------------------------
        # INTERNET
        # ------------------------------------------------------

        $internetOk =
            Test-InternetHealth

        # ------------------------------------------------------
        # HEARTBEAT
        # ------------------------------------------------------

        Write-FabricLog `
            "Heartbeat | TS=$tsOk | RDP=$rdpOk | NET=$internetOk | $minutes min remaining" `
            Cyan

        Start-Sleep -Seconds 60
    }

    Write-FabricLog `
        "Session deadline reached." `
        Green
}

# ==============================================================
# TEARDOWN
# ==============================================================

function Remove-FabricData {

    if (Test-Path $FabricRoot) {

        Remove-Item `
            -Path $FabricRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Disconnect-Tailscale {

    if (Test-Path $TailscalePath) {

        Write-FabricLog `
            "Logging out of Tailscale..." `
            Cyan

        & $TailscalePath logout `
            2>$null |
            Out-Null
    }
}

# ==============================================================
# MAIN
# ==============================================================

if (-not (Test-Admin)) {
    throw "This script requires Administrator privileges."
}

switch ($Phase) {

    # ==========================================================
    # SETUP
    # ==========================================================

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

        $runtime =
            Get-SessionRuntime

        $deadline =
            (Get-Date).AddMinutes($runtime)

        Write-FabricLog `
            "Runtime: $runtime minutes" `
            Cyan

        Create-SessionInfo `
            -Deadline $deadline

        Configure-Power

        Configure-Network

        Configure-RDPUser

        Configure-RDP

        Install-Tailscale

        $ip =
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
        Write-Host "TS IP    : $ip"
        Write-Host "RUNTIME  : $runtime minutes"
        Write-Host "DEADLINE : $($deadline.ToString('HH:mm:ss'))"
        Write-Host ""
    }

    # ==========================================================
    # WATCHDOG
    # ==========================================================

    "Watchdog" {

        Write-FabricLog `
            "Starting session watchdog..." `
            Cyan

        Start-SessionWatchdog
    }

    # ==========================================================
    # TEARDOWN
    # ==========================================================

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

        Disconnect-Tailscale

        Remove-FabricData

        Write-FabricLog `
            "Teardown complete." `
            Green
    }
}
```
