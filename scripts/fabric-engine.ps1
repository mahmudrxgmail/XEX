param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Setup", "Watchdog", "Teardown")]
    [string]$Phase
)

$FABRIC_ROOT = "C:\ProgramData\RDPFabric"

# =======================================================================
# PHASE 1: SETUP, TUNING, AND WORKSTATION INITIALIZATION
# =======================================================================
if ($Phase -eq "Setup") {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Write-Host "INITIALIZING TAILSCALE RDP FABRIC..." -ForegroundColor Cyan

    # 1. Runtime & Deadline Calculations
    $runtime = [int]$env:RUNTIME_MINUTES
    if ($env:QUICK_TEST -eq "true") { $runtime = 5 }
    if ($runtime -gt 345) { $runtime = 345 }
    if ($runtime -lt 1) { $runtime = 1 }

    New-Item -ItemType Directory -Path $FABRIC_ROOT -Force | Out-Null
    $deadline = (Get-Date).AddMinutes($runtime)
    $deadline.ToString('o') | Set-Content -Path (Join-Path $FABRIC_ROOT 'deadline.txt') -Encoding ASCII -Force
    Write-Host "Session budget: $runtime min (ends $($deadline.ToString('HH:mm:ss')))" -ForegroundColor Cyan

    # 2. Background Tailscale Download
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
    Write-Host "Tailscale MSI downloading in background..." -ForegroundColor DarkCyan

    # 3. Power & Performance Scheme
    powercfg /change standby-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /hibernate off
    powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
    $ultimate = (powercfg /list | Select-String "Ultimate Performance") -replace '.*GUID:\s*([a-f0-9-]+).*','$1'
    if ($ultimate) { powercfg -setactive $ultimate } else { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }

    # 4. System & Error Reporting Tuning
    $werKey = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"
    if (-not (Test-Path $werKey)) { New-Item -Path $werKey -Force | Out-Null }
    Set-ItemProperty -Path $werKey -Name "Disabled" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $werKey -Name "DontShowUI" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $werKey -Name "LoggingDisabled" -Value 1 -Type DWord -Force

    $fthKey = "HKLM:\SOFTWARE\Microsoft\FTH"
    if (-not (Test-Path $fthKey)) { New-Item -Path $fthKey -Force | Out-Null }
    Set-ItemProperty -Path $fthKey -Name "Enabled" -Value 0 -Type DWord -Force
    & rundll32.exe fthk.dll,FthSysprepSpecialize 2>$null

    $appCompat = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat"
    if (-not (Test-Path $appCompat)) { New-Item -Path $appCompat -Force | Out-Null }
    Set-ItemProperty -Path $appCompat -Name "DisablePCA" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $appCompat -Name "DisableEngine" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $appCompat -Name "DisableUACDetection" -Value 1 -Type DWord -Force

    $winNTKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
    Set-ItemProperty -Path $winNTKey -Name "GDIProcessHandleQuota" -Value 65536 -Type DWord -Force
    Set-ItemProperty -Path $winNTKey -Name "USERProcessHandleQuota" -Value 65536 -Type DWord -Force

    $sessionMgr = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    Set-ItemProperty -Path $sessionMgr -Name "HeapDeCommitFreeBlockThreshold" -Value 262144 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $sessionMgr -Name "HeapDeCommitTotalFreeThreshold" -Value 65536 -Type DWord -Force -ErrorAction SilentlyContinue

    fsutil behavior set disablelastaccess 1 | Out-Null
    fsutil behavior set disable8dot3 1 | Out-Null

    # 5. Network Stack Configuration
    $tlsProtocols = @(
        "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client",
        "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"
    )
    foreach ($path in $tlsProtocols) {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "DisabledByDefault" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $path -Name "Enabled" -Value 1 -Type DWord -Force
    }

    netsh winhttp reset proxy | Out-Null

    $dnsParam = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters"
    if (-not (Test-Path $dnsParam)) { New-Item -Path $dnsParam -Force | Out-Null }
    Set-ItemProperty -Path $dnsParam -Name "MaxCacheTtl" -Value 86400 -Type DWord -Force
    Set-ItemProperty -Path $dnsParam -Name "MaxNegativeCacheTtl" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $dnsParam -Name "CacheHashTableBucketSize" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $dnsParam -Name "CacheHashTableSize" -Value 384 -Type DWord -Force

    Set-NetOffloadGlobalSetting -ReceiveSideScaling Enabled -ReceiveSegmentCoalescing Disabled -TaskOffload Enabled -ErrorAction SilentlyContinue
    netsh int tcp set global autotuninglevel=high | Out-Null
    netsh int tcp set global ecncapability=disabled | Out-Null
    netsh int tcp set global timestamps=disabled | Out-Null
    try { Set-NetTCPSetting -SettingName InternetCustom -CongestionProvider CUBIC -ErrorAction SilentlyContinue } catch {}

    $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    Set-ItemProperty -Path $tcpParams -Name "MaxUserPort" -Value 65534 -Type DWord -Force
    Set-ItemProperty -Path $tcpParams -Name "TcpTimedWaitDelay" -Value 30 -Type DWord -Force
    Set-ItemProperty -Path $tcpParams -Name "EnablePMTUDiscovery" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tcpParams -Name "EnablePMTUBHDetect" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tcpParams -Name "DefaultTTL" -Value 64 -Type DWord -Force
    netsh int ipv4 set dynamicport tcp start=1025 num=64511 | Out-Null
    netsh int ipv4 set dynamicport udp start=1025 num=64511 | Out-Null

    Get-WmiObject -Class Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true } | ForEach-Object {
        $_.SetTcpipNetbios(2) | Out-Null
    }

    netsh interface teredo set state disabled | Out-Null
    netsh interface 6to4 set state disabled | Out-Null
    netsh interface isatap set state disabled | Out-Null

    Get-NetAdapter | ForEach-Object {
        Disable-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue
    }

    $interfaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    foreach ($iface in $interfaces) {
        Set-ItemProperty -Path $iface.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $iface.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    foreach ($svc in 'WSearch','DiagTrack','DoSvc','Spooler','SysMain','PcaSvc','WerSvc') {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }

    # 6. RDP & Display Pipeline Configuration
    $tsPolicies = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    if (-not (Test-Path $tsPolicies)) { New-Item -Path $tsPolicies -Force | Out-Null }
    Set-ItemProperty -Path $tsPolicies -Name "fEnableH264" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fEnableH264444" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "RemoteDesktopProfile" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fNoRemoteDesktopWallpaper" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fClientDisableUDP" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "MaxIdleTime" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "MaxDisconnectionTime" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "KeepAliveEnable" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "KeepAliveInterval" -Value 1 -Type DWord -Force

    Set-ItemProperty -Path $tsPolicies -Name "fDisableCpm" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fDisableCdm" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fDisableLPT" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $tsPolicies -Name "fDisableAudioCapture" -Value 1 -Type DWord -Force

    $dwm = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
    Set-ItemProperty -Path $dwm -Name "DWMFRAMEINTERVAL" -Value 15 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $dwm -Name "OverlayTestMode" -Value 5 -Type DWord -Force -ErrorAction SilentlyContinue
    $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    Set-ItemProperty -Path $mmProfile -Name "NetworkThrottlingIndex" -Value 0xFFFFFFFF -Type DWord -Force
    Set-ItemProperty -Path $mmProfile -Name "SystemResponsiveness" -Value 0 -Type DWord -Force

    # 7. User Account & Security Settings
    $uacPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-ItemProperty -Path $uacPath -Name "EnableLUA" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $uacPath -Name "ConsentPromptBehaviorAdmin" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $uacPath -Name "PromptOnSecureDesktop" -Value 0 -Type DWord -Force

    $smartScreenPolicies = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
    )
    foreach ($p in $smartScreenPolicies) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name "SmartScreenEnabled" -Value "Off" -Type String -Force

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -ErrorAction SilentlyContinue

    # 8. User Provisioning & Permissions
    if (-not $env:RDP_PASS) { Write-Error "CRITICAL: RDP_PASSWORD secret is missing."; exit 1 }
    $secPass = ConvertTo-SecureString $env:RDP_PASS -AsPlainText -Force
    New-LocalUser -Name $env:RDP_USER -Password $secPass -Description "Fabric Admin User" -AccountNeverExpires -ErrorAction SilentlyContinue | Out-Null
    Add-LocalGroupMember -Group "Administrators" -Member $env:RDP_USER -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member $env:RDP_USER -ErrorAction SilentlyContinue

    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Force
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "Tailscale-In-UDP" -Direction Inbound -Protocol UDP -LocalPort 41641 -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # Per-User Registry Tweaks at Logon
    $hkcuTweaks = @'
    $ErrorActionPreference = 'SilentlyContinue'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'MenuShowDelay' -Value '0'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'DragFullWindows' -Value '0'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Value ''
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAnimations' -Value 0 -Type DWord
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -Type DWord
'@
    $hkcuPath = Join-Path $FABRIC_ROOT "UserTweaks.ps1"
    Set-Content -Path $hkcuPath -Value $hkcuTweaks -Encoding UTF8
    $taskUser = "$env:COMPUTERNAME\$env:RDP_USER"
    $tweakAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$hkcuPath`""
    $tweakTrigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $tweakTrigger.Delay = "PT3S"
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName "RDPFabric-UserTweaks" -Action $tweakAction -Trigger $tweakTrigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null

    # 9. Install Tailscale & Authenticate Node
    $dlJob | Wait-Job -Timeout 120 | Out-Null
    Receive-Job $dlJob | Out-Null
    Remove-Job $dlJob -Force
    Start-Process msiexec.exe -ArgumentList "/i", $installer, "/quiet", "/norestart" -Wait
    if (Test-Path $installer) { Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue }

    $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
    if (-not (Test-Path $tsPath)) { Write-Error "Tailscale installation failed."; exit 1 }

    $hostname = "fabric-node-${env:RUN_ID}-${env:MATRIX_ID}"
    & $tsPath up --authkey="$env:TS_AUTHKEY" --hostname="$hostname" --accept-routes=false --unattended

    $ip = ""; $timeout = 30
    while (-not ($ip -match "^\d{1,3}(\.\d{1,3}){3}$") -and $timeout -gt 0) {
        Start-Sleep -Seconds 1
        $ip = (& $tsPath ip -4 | Out-String).Trim()
        $timeout--
    }
    if (-not $ip) { Write-Error "Failed to acquire Tailscale IP."; exit 1 }

    $tsAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Tailscale" -or $_.Name -match "Tailscale" } | Select-Object -First 1
    if ($tsAdapter) { netsh interface ipv4 set subinterface "$($tsAdapter.Name)" mtu=1280 store=persistent | Out-Null }
    $tsStatus = (& $tsPath status 2>$null | Out-String)
    $isDirect = ($tsStatus -notmatch 'relay')

    # 10. Floating Desktop Timer Overlay
    $timerPath = Join-Path $FABRIC_ROOT "FabricTimer.ps1"
    $timerLauncher = Join-Path $FABRIC_ROOT "FabricTimer.vbs"

    $timerScript = @'
    $ErrorActionPreference = 'SilentlyContinue'
    while (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 1 }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:mutex = New-Object System.Threading.Mutex($false, 'Local\RDPFabricTimerOverlay')
    if (-not $script:mutex.WaitOne(0)) { return }

    $script:deadlineFile = 'C:\ProgramData\RDPFabric\deadline.txt'
    $script:deadline = (Get-Date).AddMinutes(345)
    if (Test-Path $script:deadlineFile) {
        $raw = (Get-Content -Path $script:deadlineFile -Raw)
        if ($raw) {
            try {
                $script:deadline = [datetime]::Parse($raw.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            } catch {}
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Fabric Timer'
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
        $remaining = $script:deadline - (Get-Date)
        $total = [math]::Floor($remaining.TotalSeconds)
        if ($total -le 0) { $label.Text = '00:00:00'; return }
        $h = [math]::Floor($total / 3600); $m = [math]::Floor(($total % 3600) / 60); $s = $total % 60
        $label.Text = ('{0:00}:{1:00}:{2:00}' -f $h, $m, $s)
    })
    $timer.Start()

    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::Run($form)
'@
    Set-Content -Path $timerPath -Value $timerScript -Encoding UTF8
    $vbs = "Set sh = CreateObject(`"WScript.Shell`")`nsh.Run `"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"`"$timerPath`"`"`, 0, False"
    Set-Content -Path $timerLauncher -Value $vbs -Encoding ASCII

    $timerAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$timerLauncher`""
    $timerTrigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $timerTrigger.Delay = "PT5S"
    $timerSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName "RDPFabric-Timer" -Action $timerAction -Trigger $timerTrigger -Principal $taskPrincipal -Settings $timerSettings -Force | Out-Null

    # 11. Dispatch Telemetry Notification
    if ($env:TG_TOKEN -and $env:TG_CHAT) {
        $link = if ($isDirect) { "direct" } else { "relay" }
        $msg = "Fabric Node Online`n`nHost: $hostname`nIP: $ip`nPath: $link`nUser: $env:RDP_USER`nDuration: $runtime min"
        $uri = "https://api.telegram.org/bot$($env:TG_TOKEN)/sendMessage"
        Invoke-RestMethod -Uri $uri -Method Post -Body @{chat_id=$env:TG_CHAT; text=$msg} -ErrorAction SilentlyContinue | Out-Null
    } else {
        Write-Host "=========================================="
        Write-Host " CONNECT VIA RDP"
        Write-Host " IP:   $ip"
        Write-Host " USER: $env:RDP_USER"
        Write-Host "=========================================="
    }
    Write-Host "OS Layer Configured. Ignition Complete." -ForegroundColor Green
}

# =======================================================================
# PHASE 2: WATCHDOG AND HEARTBEAT
# =======================================================================
if ($Phase -eq "Watchdog") {
    $runtime = [int]$env:RUNTIME_MINUTES
    if ($env:QUICK_TEST -eq "true") { $runtime = 5 }
    $start = Get-Date
    $tsPath = "C:\Program Files\Tailscale\tailscale.exe"

    Write-Host "Holding session for $runtime minutes with 60s heartbeats..." -ForegroundColor Cyan

    while ((New-TimeSpan -Start $start -End (Get-Date)).TotalMinutes -lt $runtime) {
        Start-Sleep -Seconds 60
        $remaining = [math]::Max(0, [math]::Round($runtime - (New-TimeSpan -Start $start -End (Get-Date)).TotalMinutes, 1))

        # Check Tailscale Service
        $tsOk = $false
        $svc = Get-Service -Name "IPNService" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Write-Host "Tailscale IPNService stopped — restarting..." -ForegroundColor Yellow
            Start-Service -Name "IPNService" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        if (Test-Path $tsPath) {
            $backend = (& $tsPath status --json 2>$null | ConvertFrom-Json).BackendState
            $tsOk = ($backend -eq 'Running')
            if (-not $tsOk) {
                Write-Host "Tailscale backend '$backend' — re-upping..." -ForegroundColor Yellow
                $hostname = "fabric-node-${env:RUN_ID}-${env:MATRIX_ID}"
                & $tsPath up --authkey="$env:TS_AUTHKEY" --hostname="$hostname" --accept-routes=false --unattended 2>$null | Out-Null
            }
        }

        # Check RDP Listener
        $rdpOk = [bool](Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
        if (-not $rdpOk) {
            Write-Host "RDP listener down — restarting TermService..." -ForegroundColor Yellow
            Restart-Service TermService -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Heartbeat: Active | TS:$($tsOk ? 'ok' : 'recovering') RDP:$($rdpOk ? 'ok' : 'recovering') | $remaining min left"
    }

    # Recursive Cycle Dispatch
    $cycles = [int]$env:CYCLES
    if ($cycles -gt 0) {
        $next = $cycles - 1
        Write-Host "Initiating Cycle Handoff (Remaining: $next)..." -ForegroundColor Yellow
        $dispatched = $false
        for ($attempt = 1; $attempt -le 3 -and -not $dispatched; $attempt++) {
            gh workflow run "$env:WORKFLOW_REF" `
                -f instance_count="1" `
                -f runtime_minutes="$env:RUNTIME_MINUTES" `
                -f quick_test="$env:QUICK_TEST" `
                -f cycles="$next"

            if ($LASTEXITCODE -eq 0) {
                $dispatched = $true
                Write-Host "Handoff successfully dispatched (attempt $attempt)." -ForegroundColor Green
            } else {
                Write-Host "Handoff attempt $attempt failed — retrying in 15s..." -ForegroundColor Yellow
                Start-Sleep -Seconds 15
            }
        }
        if (-not $dispatched) { Write-Error "Handoff failed after 3 attempts." }
    } else {
        Write-Host "No cycles remaining. Shutting down gracefully."
    }
}

# =======================================================================
# PHASE 3: TEARDOWN
# =======================================================================
if ($Phase -eq "Teardown") {
    $ErrorActionPreference = 'SilentlyContinue'
    Write-Host "Executing teardown..."

    $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path $tsPath) {
        Write-Host "Logging out of Tailnet..."
        & $tsPath logout 2>$null | Out-Null
    }

    foreach ($t in 'RDPFabric-Timer','RDPFabric-UserTweaks') {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'powershell','wscript' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 3

    if (Test-Path $FABRIC_ROOT) {
        Remove-Item -Path $FABRIC_ROOT -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Teardown complete."
}
