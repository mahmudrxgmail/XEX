param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Setup", "Watchdog", "Teardown")]
    [string]$Phase
)

$ErrorActionPreference = 'Continue'
$FABRIC_ROOT = "C:\ProgramData\RDPFabric"

# ═══════════════════════════════════════════════════════════════════════
# PHASE 1: SYSTEM SETUP & IGNITION
# ═══════════════════════════════════════════════════════════════════════
if ($Phase -eq "Setup") {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Write-Host "INITIALIZING TAILSCALE FABRIC..." -ForegroundColor Cyan

    # Runtime Calculation
    $runtime = [int]$env:RUNTIME_MINUTES
    if ($env:QUICK_TEST -eq "true") { $runtime = 5 }
    if ($runtime -gt 345) { $runtime = 345 }
    if ($runtime -lt 1) { $runtime = 1 }

    New-Item -ItemType Directory -Path $FABRIC_ROOT -Force | Out-Null
    $deadline = (Get-Date).AddMinutes($runtime)
    $deadline.ToString('o') | Set-Content -Path (Join-Path $FABRIC_ROOT 'deadline.txt') -Encoding ASCII -Force
    Write-Host "Session budget: $runtime min (ends $($deadline.ToString('HH:mm:ss')))" -ForegroundColor Cyan

    # Parallel Tailscale Download
    $installer = "$env:TEMP\tailscale.msi"
    $dlJob = Start-Job -ScriptBlock {
        param($dst)
        $url = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"
        for ($i = 0; $i -lt 5; $i++) {
            & curl.exe -sS -L --retry 3 -o $dst $url
            if ($LASTEXITCODE -eq 0 -and (Test-Path $dst) -and (Get-Item $dst).Length -gt 1MB) { return 0 }
            Start-Sleep -Seconds 5
        }
        return 1
    } -ArgumentList $installer

    # Power & Performance
    powercfg /change standby-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /hibernate off
    powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
    $ultimate = (powercfg /list | Select-String "Ultimate Performance") -replace '.*GUID:\s*([a-f0-9-]+).*','$1'
    if ($ultimate) { powercfg -setactive $ultimate } else { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }

    # Silverbullet Tool Hardening
    $werKey = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"
    if (-not (Test-Path $werKey)) { New-Item -Path $werKey -Force | Out-Null }
    Set-ItemProperty -Path $werKey -Name "Disabled" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $werKey -Name "DontShowUI" -Value 1 -Type DWord -Force

    $fthKey = "HKLM:\SOFTWARE\Microsoft\FTH"
    if (-not (Test-Path $fthKey)) { New-Item -Path $fthKey -Force | Out-Null }
    Set-ItemProperty -Path $fthKey -Name "Enabled" -Value 0 -Type DWord -Force

    $appCompat = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat"
    if (-not (Test-Path $appCompat)) { New-Item -Path $appCompat -Force | Out-Null }
    Set-ItemProperty -Path $appCompat -Name "DisablePCA" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $appCompat -Name "DisableEngine" -Value 1 -Type DWord -Force

    # Memory & Quotas
    $winNTKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
    Set-ItemProperty -Path $winNTKey -Name "GDIProcessHandleQuota" -Value 65536 -Type DWord -Force
    Set-ItemProperty -Path $winNTKey -Name "USERProcessHandleQuota" -Value 65536 -Type DWord -Force
    
    $sessionMgr = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    Set-ItemProperty -Path $sessionMgr -Name "HeapDeCommitFreeBlockThreshold" -Value 262144 -Type DWord -Force -ErrorAction SilentlyContinue

    # Network Stack & Offload
    netsh winhttp reset proxy | Out-Null
    Set-NetOffloadGlobalSetting -ReceiveSideScaling Enabled -ReceiveSegmentCoalescing Disabled -TaskOffload Enabled -ErrorAction SilentlyContinue
    netsh int tcp set global autotuninglevel=high | Out-Null
    netsh int ipv4 set dynamicport tcp start=1025 num=64511 | Out-Null
    netsh int ipv4 set dynamicport udp start=1025 num=64511 | Out-Null

    # Nagle Demolition
    $interfaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    foreach ($iface in $interfaces) {
        Set-ItemProperty -Path $iface.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $iface.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    # Bloat Services
    foreach ($svc in 'WSearch','DiagTrack','DoSvc','Spooler','SysMain','PcaSvc','WerSvc') {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }

    # Terminal Services & Performance
    $TimerCode = 'using System; using System.Runtime.InteropServices; public class TimerRes { [DllImport("ntdll.dll", SetLastError = true)] public static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution); }'
    Add-Type -TypeDefinition $TimerCode -ErrorAction SilentlyContinue
    [TimerRes]::NtSetTimerResolution(5000, $true, [ref]0) | Out-Null

    $tsPolicies = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    if (-not (Test-Path $tsPolicies)) { New-Item -Path $tsPolicies -Force | Out-Null }
    Set-ItemProperty -Path $tsPolicies -Name "fEnableH264" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fEnableH264444" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fNoRemoteDesktopWallpaper" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "MaxIdleTime" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "KeepAliveEnable" -Value 1 -Type DWord -Force

    # DWM 60fps
    $dwm = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
    Set-ItemProperty -Path $dwm -Name "DWMFRAMEINTERVAL" -Value 15 -Type DWord -Force -ErrorAction SilentlyContinue

    # User Account Setup
    if (-not $env:RDP_PASS) { Write-Error "CRITICAL: RDP_PASSWORD secret is missing."; exit 1 }
    $secPass = ConvertTo-SecureString $env:RDP_PASS -AsPlainText -Force
    New-LocalUser -Name $env:RDP_USER -Password $secPass -Description "Fabric User" -AccountNeverExpires -ErrorAction SilentlyContinue | Out-Null
    Add-LocalGroupMember -Group "Administrators" -Member $env:RDP_USER -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member $env:RDP_USER -ErrorAction SilentlyContinue

    # Enable RDP Listener
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Force
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "Tailscale-In-UDP" -Direction Inbound -Protocol UDP -LocalPort 41641 -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # Install Tailscale
    $dlJob | Wait-Job -Timeout 120 | Out-Null
    Receive-Job $dlJob | Out-Null
    Remove-Job $dlJob -Force
    Start-Process msiexec.exe -ArgumentList "/i", $installer, "/quiet", "/norestart" -Wait
    if (Test-Path $installer) { Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue }

    $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
    $hostname = "fabric-node-${env:RUN_ID}-${env:MATRIX_ID}"
    & $tsPath up --authkey="$env:TS_AUTHKEY" --hostname="$hostname" --accept-routes=false --unattended

    $ip = ""; $timeout = 30
    while (-not ($ip -match "^\d{1,3}(\.\d{1,3}){3}$") -and $timeout -gt 0) {
        Start-Sleep -Seconds 1
        $ip = (& $tsPath ip -4 | Out-String).Trim()
        $timeout--
    }
    if (-not $ip) { Write-Error "Failed to acquire Tailscale IP."; exit 1 }

    # Floating Overlay Setup
    $timerPath = Join-Path $FABRIC_ROOT "FabricTimer.ps1"
    $timerLauncher = Join-Path $FABRIC_ROOT "FabricTimer.vbs"

    $timerScript = @'
    $ErrorActionPreference = 'SilentlyContinue'
    while (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 1 }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:deadlineFile = 'C:\ProgramData\RDPFabric\deadline.txt'
    $script:deadline = (Get-Date).AddMinutes(345)
    if (Test-Path $script:deadlineFile) {
        try { $script:deadline = [datetime]::Parse((Get-Content -Path $script:deadlineFile -Raw).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
    }

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(10, 10)
    $form.ClientSize = New-Object System.Drawing.Size(96, 26)
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(15, 15, 18)
    $form.Opacity = 0.85

    $label = New-Object System.Windows.Forms.Label
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $label.Font = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(0, 230, 140)
    $label.Text = '--:--:--'
    $form.Controls.Add($label)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $total = [math]::Floor(($script:deadline - (Get-Date)).TotalSeconds)
        if ($total -le 0) { $label.Text = '00:00:00'; $label.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80); return }
        $label.Text = ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($total / 3600), [math]::Floor(($total % 3600) / 60), ($total % 60))
        if ($total -le 300) { $label.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80) }
        elseif ($total -le 900) { $label.ForeColor = [System.Drawing.Color]::FromArgb(255, 176, 32) }
        if (-not $form.TopMost) { $form.TopMost = $true }
    })
    $timer.Start()
    [System.Windows.Forms.Application]::Run($form)
'@
    Set-Content -Path $timerPath -Value $timerScript -Encoding UTF8

    $vbs = "Set sh = CreateObject(`"WScript.Shell`")`nsh.Run `"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"`"$timerPath`"`"`, 0, False"
    Set-Content -Path $timerLauncher -Value $vbs -Encoding ASCII

    $taskAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$timerLauncher`""
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$env:RDP_USER"
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:RDP_USER" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "RDPFabric-Timer" -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Force | Out-Null

    # Telegram Notification
    if ($env:TG_TOKEN -and $env:TG_CHAT) {
        $msg = "Fabric Node Online`n`nHost: $hostname`nIP: $ip`nUser: $env:RDP_USER`nDuration: $runtime min"
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($env:TG_TOKEN)/sendMessage" -Method Post -Body @{chat_id=$env:TG_CHAT; text=$msg} -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "Fabric Node Online: IP = $ip" -ForegroundColor Green
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 2: WATCHDOG & HANDOFF
# ═══════════════════════════════════════════════════════════════════════
if ($Phase -eq "Watchdog") {
    $runtime = [int]$env:RUNTIME_MINUTES
    if ($env:QUICK_TEST -eq "true") { $runtime = 5 }
    $start = Get-Date

    Write-Host "Holding session for $runtime minutes..." -ForegroundColor Cyan

    while ((New-TimeSpan -Start $start -End (Get-Date)).TotalMinutes -lt $runtime) {
        Start-Sleep -Seconds 60
        $remaining = [math]::Max(0, [math]::Round($runtime - (New-TimeSpan -Start $start -End (Get-Date)).TotalMinutes, 1))

        # Check Tailscale
        $svc = Get-Service -Name "IPNService" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Start-Service -Name "IPNService" -ErrorAction SilentlyContinue
        }

        # Check RDP
        $rdpOk = [bool](Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
        if (-not $rdpOk) {
            Restart-Service TermService -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Heartbeat: Active | $remaining min left"
    }

    # Workflow Cycle Handoff
    $cycles = [int]$env:CYCLES
    if ($cycles -gt 0) {
        $next = $cycles - 1
        Write-Host "Initiating Cycle Handoff ($next left)..." -ForegroundColor Yellow
        gh workflow run "$env:WORKFLOW_REF" `
            -f instance_count="1" `
            -f runtime_minutes="$env:RUNTIME_MINUTES" `
            -f quick_test="$env:QUICK_TEST" `
            -f cycles="$next"
    }
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 3: TEARDOWN
# ═══════════════════════════════════════════════════════════════════════
if ($Phase -eq "Teardown") {
    Write-Host "Executing teardown..."
    $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path $tsPath) { & $tsPath logout 2>$null | Out-Null }
    Unregister-ScheduledTask -TaskName "RDPFabric-Timer" -Confirm:$false -ErrorAction SilentlyContinue
    Get-Process -Name 'chrome','powershell','wscript' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path $FABRIC_ROOT) { Remove-Item -Path $FABRIC_ROOT -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "Teardown complete."
}
