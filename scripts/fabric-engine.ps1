[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Setup", "Watchdog", "Teardown")]
    [string]$Phase
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$FabricRoot = "C:\ProgramData\RDPFabric"

$DeadlineFile = Join-Path `
    $FabricRoot `
    "deadline.txt"

$InfoFile = Join-Path `
    $FabricRoot `
    "node-info.txt"

$TailscalePath =
    "C:\Program Files\Tailscale\tailscale.exe"


# ==============================================================
# HELPERS
# ==============================================================

function Write-FabricLog {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host `
        "[$(Get-Date -Format 'HH:mm:ss')] $Message" `
        -ForegroundColor $Color
}


function Test-Administrator {

    $identity =
        [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal =
        New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


function Get-Runtime {

    $runtime = 60

    if ($env:RUNTIME_MINUTES) {

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
# POWER / PERFORMANCE
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

    try {

        powercfg `
            -duplicatescheme `
            "e9a42b02-d5df-448d-aa00-03f14749eb61" `
            2>$null |
            Out-Null

    }
    catch {
    }

    $schemes =
        powercfg /list 2>$null

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
                "Ultimate Performance enabled." `
                Green

            return
        }
    }

    Write-FabricLog `
        "Using current power plan." `
        Yellow
}


# ==============================================================
# NETWORK OPTIMIZATION
# ==============================================================

function Configure-Network {

    Write-FabricLog `
        "Optimizing supported Windows network settings..." `
        Cyan

    # Stable TCP autotuning.
    netsh interface tcp set global `
        autotuninglevel=normal |
        Out-Null

    # RSS improves packet processing where supported.
    try {

        Set-NetOffloadGlobalSetting `
            -ReceiveSideScaling Enabled `
            -ErrorAction SilentlyContinue

    }
    catch {
    }

    # Keep RSC enabled/managed by Windows.
    try {

        Set-NetOffloadGlobalSetting `
            -ReceiveSegmentCoalescing Enabled `
            -ErrorAction SilentlyContinue

    }
    catch {
    }

    # Refresh DNS cache.
    Clear-DnsClientCache `
        -ErrorAction SilentlyContinue

    Write-FabricLog `
        "Network optimization complete." `
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
        "RDP configured." `
        Green
}


# ==============================================================
# RDP USER
# ==============================================================

function Configure-RDPUser {

    if ([string]::IsNullOrWhiteSpace(
        $env:RDP_PASSWORD
    )) {
        throw "RDP_PASSWORD secret is missing."
    }

    Write-FabricLog `
        "Configuring RDP account..." `
        Cyan

    $securePassword =
        ConvertTo-SecureString `
            $env:RDP_PASSWORD `
            -AsPlainText `
            -Force

    $user =
        Get-LocalUser `
            -Name $env:RDP_USER `
            -ErrorAction SilentlyContinue

    if (-not $user) {

        New-LocalUser `
            -Name $env:RDP_USER `
            -Password $securePassword `
            -Description "RDP Fabric User" `
            -AccountNeverExpires `
            -PasswordNeverExpires |
            Out-Null

    }
    else {

        Set-LocalUser `
            -Name $env:RDP_USER `
            -Password $securePassword
    }

    Add-LocalGroupMember `
        -Group "Administrators" `
        -Member $env:RDP_USER `
        -ErrorAction SilentlyContinue

    Add-LocalGroupMember `
        -Group "Remote Desktop Users" `
        -Member $env:RDP_USER `
        -ErrorAction SilentlyContinue

    Write-FabricLog `
        "RDP account ready." `
        Green
}


# ==============================================================
# TAILSCALE INSTALLATION
# ==============================================================

function Install-Tailscale {

    Write-FabricLog `
        "Checking Tailscale..." `
        Cyan

    if (Test-Path $TailscalePath) {

        Write-FabricLog `
            "Tailscale already installed." `
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
        throw "Tailscale download failed."
    }

    if ((Get-Item $installer).Length -lt 1MB) {

        Remove-Item `
            $installer `
            -Force `
            -ErrorAction SilentlyContinue

        throw "Invalid Tailscale installer."
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

    if ($process.ExitCode -notin @(0,3010)) {
        throw "Tailscale installation failed: $($process.ExitCode)"
    }

    if (-not (Test-Path $TailscalePath)) {
        throw "Tailscale executable not found."
    }

    Write-FabricLog `
        "Tailscale installed." `
        Green
}


# ==============================================================
# TAILSCALE CONNECT
# ==============================================================

function Connect-Tailscale {

    if ([string]::IsNullOrWhiteSpace(
        $env:TAILSCALE_AUTH_KEY
    )) {
        throw "TAILSCALE_AUTH_KEY secret is missing."
    }

    $hostname =
        "fabric-node-$($env:RUN_ID)-$($env:MATRIX_ID)"

    Write-FabricLog `
        "Joining Tailscale as $hostname..." `
        Cyan

    & $TailscalePath up `
        "--authkey=$($env:TAILSCALE_AUTH_KEY)" `
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
        throw "Tailscale IPv4 address unavailable."
    }

    Write-FabricLog `
        "Tailscale IP: $ip" `
        Green

    return $ip
}


# ==============================================================
# SESSION INFORMATION
# ==============================================================

function Save-SessionInfo {

    param(
        [datetime]$Deadline
    )

    Ensure-FabricDirectory

    $Deadline.ToString("o") |
        Set-Content `
            -Path $DeadlineFile `
            -Encoding ASCII `
            -Force

    @"
RDP Fabric
====================

Node: $env:MATRIX_ID
Run:  $env:RUN_ID
User: $env:RDP_USER

Runtime: $(Get-Runtime) minutes

Deadline:
$($Deadline.ToString("o"))

Transport:
Tailscale

Created:
$(Get-Date -Format "o")
"@ |
        Set-Content `
            -Path $InfoFile `
            -Encoding UTF8 `
            -Force
}


# ==============================================================
# HEALTH CHECKS
# ==============================================================

function Test-Tailscale {

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

        return (
            $status.BackendState -eq "Running"
        )
    }
    catch {
        return $false
    }
}


function Test-RDP {

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


function Test-Internet {

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

function Start-Watchdog {

    $runtime =
        Get-Runtime

    $deadline =
        (Get-Date).AddMinutes($runtime)

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

        # ------------------------------------------------------
        # TAILSCALE
        # ------------------------------------------------------

        $tsOk =
            Test-Tailscale

        if (-not $tsOk) {

            Write-FabricLog `
                "Tailscale unhealthy; attempting recovery..." `
                Yellow

            try {

                Connect-Tailscale |
                    Out-Null

            }
            catch {
            }
        }

        # ------------------------------------------------------
        # RDP
        # ------------------------------------------------------

        $rdpOk =
            Test-RDP

        if (-not $rdpOk) {

            Write-FabricLog `
                "RDP listener unhealthy; restarting service..." `
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
            Test-Internet

        Write-FabricLog `
            "Heartbeat | TS=$tsOk | RDP=$rdpOk | NET=$internetOk | $minutes min remaining" `
            Cyan

        Start-Sleep -Seconds 60
    }

    Write-FabricLog `
        "Runtime reached. Watchdog finished." `
        Green
}


# ==============================================================
# TEARDOWN
# ==============================================================

function Teardown {

    $ErrorActionPreference = "Continue"

    Write-FabricLog `
        "Starting teardown..." `
        Yellow

    if (Test-Path $TailscalePath) {

        Write-FabricLog `
            "Logging out of Tailscale..." `
            Cyan

        & $TailscalePath logout 2>$null |
            Out-Null
    }

    if (Test-Path $FabricRoot) {

        Remove-Item `
            -Path $FabricRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-FabricLog `
        "Teardown complete." `
        Green
}


# ==============================================================
# MAIN
# ==============================================================

if (-not (Test-Administrator)) {
    throw "fabric-engine.ps1 requires Administrator privileges."
}

switch ($Phase) {

    "Setup" {

        Write-FabricLog `
            "========================================" `
            Cyan

        Write-FabricLog `
            " RDP FABRIC SETUP" `
            Cyan

        Write-FabricLog `
            "========================================" `
            Cyan

        $runtime =
            Get-Runtime

        $deadline =
            (Get-Date).AddMinutes($runtime)

        Save-SessionInfo `
            -Deadline $deadline

        Configure-Power

        Configure-Network

        Configure-RDPUser

        Configure-RDP

        Install-Tailscale

        $ip =
            Connect-Tailscale

        Write-Host ""
        Write-Host "========================================"
        Write-Host " RDP FABRIC READY"
        Write-Host "========================================"
        Write-Host "Node:     $env:MATRIX_ID"
        Write-Host "RDP User: $env:RDP_USER"
        Write-Host "TS IP:    $ip"
        Write-Host "Runtime:  $runtime minutes"
        Write-Host "Deadline: $($deadline.ToString('HH:mm:ss'))"
        Write-Host "========================================"
        Write-Host ""
    }

    "Watchdog" {

        Start-Watchdog
    }

    "Teardown" {

        Teardown
    }
}
