<#
.SYNOPSIS
    NetAid M01 网络适配器诊断与修复模块
.DESCRIPTION
    提供 Invoke-M01_Diagnose（适配器全面诊断）和 Invoke-M01_Repair（适配器问题修复）。
    诊断覆盖：适配器枚举、异常状态检测、驱动日期检查、PnP 设备状态、
    系统事件、WLAN 服务、Wi-Fi 信号强度、飞行模式、NCSI 网络探针。
    修复支持：驱动重置、PnP 设备重启、WLAN 服务启动、飞行模式提示。
.NOTES
    文件名: M01_Adapter.ps1
    依赖: Utils.ps1 (Test-DigitalSignature, Get-NetAdapterFallback)
          Logger.ps1 (Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent)
    兼容: Windows PowerShell 5.1
    风险等级: 诊断 L3 / 修复 L4a
#>

# ============================================================
# Invoke-M01_Diagnose - 网络适配器诊断
# ============================================================

<#
.SYNOPSIS
    执行网络适配器全面诊断
.DESCRIPTION
    检测项包括：
    1. 适配器枚举 (Get-NetAdapter / Get-NetAdapterFallback)
    2. 适配器异常状态检测 (Disabled / Not Present)
    3. 驱动日期过旧检查 (< 2018年标记WARN)
    4. PnP 设备错误状态检查
    5. 系统事件日志检查 (Event ID 10400)
    6. WLAN 服务状态检查
    7. Wi-Fi 信号强度检测 (netsh wlan show interfaces)
    8. 飞行模式检测 (注册表 RadioManagement)
    9. NCSI 网络探针检测 (注册表 + Test-Connection)
.PARAMETER Context
    上下文数据哈希表（初始为空，供未来扩展）
.OUTPUTS
    Hashtable - 包含 Diagnosis 和 LogEvents 两个键
    Diagnosis 包含: Adapters, ActiveAdapterCount, DriverIssues,
    WlanSvcRunning, WiFiSignalQuality, AirplaneMode, NcsiProbeFailed,
    PnPErrorDevices, Verdict
.EXAMPLE
    $result = Invoke-M01_Diagnose -Context @{}
    $result.Diagnosis.Verdict  # PASS / WARN / FAIL / UNKNOWN
#>
function Invoke-M01_Diagnose {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{}
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $logEvents = @()
    $driverIssues = @()
    $pnPErrorDevices = @()
    $warnReasons = @()
    $failReasons = @()

    # ---- 初始化诊断结构 ----
    $diagnosis = @{
        Adapters             = @()
        ActiveAdapterCount   = 0
        DriverIssues         = @()
        PnPErrorDevices      = @()
        WlanSvcRunning       = $false
        WiFiSignalQuality    = $null
        AirplaneMode         = $false
        NcsiProbeFailed      = $false
        Verdict              = "UNKNOWN"
    }

    # ============================================================
    # 1. 枚举适配器
    # ============================================================
    $adapters = @()
    $useFallback = $false
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Select-Object Name, InterfaceIndex, Status, LinkSpeed, InterfaceDescription, DriverDate, DriverVersion, MediaType)
        if ($adapters.Count -eq 0) {
            # Get-NetAdapter 成功但无适配器返回，尝试回退方案
            Write-Verbose "Get-NetAdapter 未返回任何适配器，尝试回退方案"
            $adapters = @(Get-NetAdapterFallback)
            $useFallback = $true
        }
    } catch {
        Write-Verbose "Get-NetAdapter 失败，降级使用 Get-NetAdapterFallback: $_"
        try {
            $adapters = @(Get-NetAdapterFallback)
            $useFallback = $true
        } catch {
            Write-Verbose "Get-NetAdapterFallback 也失败: $_"
            $adapters = @()
            $useFallback = $true
        }
    }

    # 通过属性检测适配器是否为无线网卡
    function Test-IsWirelessAdapter {
        param($Adapter)
        $wirelessKeywords = @('wireless', 'wi-fi', 'wifi', 'wlan', '802.11', 'bluetooth device')
        $desc = ''
        $name = ''
        $mediaType = ''
        try { $desc = $Adapter.InterfaceDescription } catch { }
        try { $name = $Adapter.Name } catch { }
        try { $mediaType = $Adapter.MediaType } catch { }
        $combined = "$desc $name $mediaType"
        foreach ($kw in $wirelessKeywords) {
            if ($combined -match $kw) { return $true }
        }
        return $false
    }

    # ---- 构建适配器列表 ----
    $adapterList = @()
    $hasWirelessAdapter = $false
    $activeAdapters = 0
    $statusIssues = @()

    foreach ($adapter in $adapters) {
        # 安全提取属性（Get-NetAdapterFallback 返回的属性名可能与 Get-NetAdapter 不同）
        $adapterName = try { $adapter.Name } catch { "Unknown" }
        $ifIndex = try { $adapter.InterfaceIndex } catch { 0 }
        $status = try { $adapter.Status } catch { "Unknown" }
        # LinkSpeed: 优先 LinkSpeed（Get-NetAdapter），其次 Speed（Fallback）
        $linkSpeed = try {
            if ($adapter.PSObject.Properties['LinkSpeed'] -ne $null) { $adapter.LinkSpeed }
            elseif ($adapter.PSObject.Properties['Speed'] -ne $null) { $adapter.Speed }
            else { $null }
        } catch { $null }
        # DriverDate / DriverVersion: 仅 Get-NetAdapter 提供
        $driverDate = try {
            if ($adapter.PSObject.Properties['DriverDate'] -ne $null) { $adapter.DriverDate }
            else { $null }
        } catch { $null }
        $driverVersion = try {
            if ($adapter.PSObject.Properties['DriverVersion'] -ne $null) { $adapter.DriverVersion }
            else { $null }
        } catch { $null }
        $interfaceDesc = try { $adapter.InterfaceDescription } catch { "Unknown" }

        # 检测无线适配器
        $isWireless = Test-IsWirelessAdapter -Adapter $adapter
        if ($isWireless) { $hasWirelessAdapter = $true }

        # 判断是否为活跃适配器（排除 Not Present 和 Disabled）
        $isActive = ($status -ne 'Not Present' -and $status -ne 'Disabled')
        if ($isActive) { $activeAdapters++ }

        $adapterInfo = @{
            Name                 = $adapterName
            ifIndex              = $ifIndex
            Status               = $status
            LinkSpeed            = $linkSpeed
            DriverDate           = if ($driverDate) { try { ([DateTime]$driverDate).ToString('yyyy-MM-dd') } catch { "$driverDate" } } else { $null }
            DriverVersion        = $driverVersion
            InterfaceDescription = $interfaceDesc
            IsWireless           = $isWireless
        }
        $adapterList += $adapterInfo

        # ============================================================
        # 2. 异常状态检测
        # ============================================================
        switch ($status) {
            'Disabled' {
                $failReasons += "适配器 [$adapterName] 状态为 Disabled（已禁用）"
                $statusIssues += @{Adapter=$adapterName; Status=$status; Severity='FAIL'}
            }
            'Not Present' {
                $failReasons += "适配器 [$adapterName] 状态为 Not Present（硬件不存在）"
                $statusIssues += @{Adapter=$adapterName; Status=$status; Severity='FAIL'}
            }
            'Disconnected' {
                # 仅记录，不标记为故障（可能是网线未插）
                $statusIssues += @{Adapter=$adapterName; Status=$status; Severity='INFO'}
            }
        }

        # ============================================================
        # 3. 驱动日期检查（仅当 Get-NetAdapter 返回驱动日期时）
        # ============================================================
        if ($driverDate -and $isActive) {
            $driverYearThreshold = 2018
            if ($driverDate.Year -lt $driverYearThreshold) {
                $driverIssue = "适配器 [$adapterName] 驱动日期过旧 ($(try { ([DateTime]$driverDate).ToString('yyyy-MM-dd') } catch { "$driverDate" })，早于${driverYearThreshold}年)"
                $driverIssues += $driverIssue
                $warnReasons += $driverIssue
            }
        }
    }

    $diagnosis.Adapters = $adapterList
    $diagnosis.ActiveAdapterCount = $activeAdapters

    # ============================================================
    # 4. PnP 设备错误状态检查
    # ============================================================
    try {
        $pnpDevices = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue
        if ($pnpDevices) {
            $errorDevices = $pnpDevices | Where-Object { $_.Status -ne 'OK' }
            foreach ($dev in $errorDevices) {
                $devName = try { $dev.FriendlyName } catch { $dev.Name }
                if (-not $devName) { $devName = $dev.InstanceId }
                $devStatus = $dev.Status
                $devProblem = try { $dev.ProblemCode } catch { $null }

                if ($devStatus -eq 'Error') {
                    $failReasons += "PnP 设备 [$devName] 状态为 Error (ProblemCode: $devProblem)"
                    $pnPErrorDevices += @{
                        InstanceId  = $dev.InstanceId
                        Name        = $devName
                        Status      = $devStatus
                        ProblemCode = $devProblem
                    }
                } elseif ($devStatus -eq 'Unknown') {
                    $warnReasons += "PnP 设备 [$devName] 状态为 Unknown"
                }
            }
        }
    } catch {
        Write-Verbose "Get-PnpDevice 失败 (可能需要管理员权限): $_"
    }
    $diagnosis.PnPErrorDevices = $pnPErrorDevices

    # ============================================================
    # 5. 系统事件日志检查 (NDIS 事件 ID 10400)
    # ============================================================
    $ndisEvents = @()
    try {
        $eventFilter = @{
            LogName   = 'System'
            Id        = 10400
            StartTime = (Get-Date).AddHours(-24)
        }
        $ndisEvents = @(Get-WinEvent -FilterHashtable $eventFilter -MaxEvents 50 -ErrorAction SilentlyContinue)
        if ($ndisEvents.Count -gt 0) {
            $warnReasons += "过去24小时内发现 $($ndisEvents.Count) 条 NDIS 网络事件 (ID 10400)"
        }
    } catch {
        Write-Verbose "Get-WinEvent 查询系统事件失败: $_"
    }

    # ============================================================
    # 6. WLAN 服务状态检查
    # ============================================================
    $wlanSvcRunning = $false
    try {
        $wlanSvc = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue
        if ($wlanSvc) {
            $wlanSvcRunning = ($wlanSvc.Status -eq 'Running')
        }
    } catch {
        Write-Verbose "Get-Service WlanSvc 失败: $_"
    }
    $diagnosis.WlanSvcRunning = $wlanSvcRunning

    # 若存在无线适配器但 WLAN 服务未运行 → 警告
    if ($hasWirelessAdapter -and -not $wlanSvcRunning) {
        $warnReasons += "检测到无线网卡但 WLAN AutoConfig 服务未运行"
    }

    # ============================================================
    # 7. Wi-Fi 信号强度检测
    # ============================================================
    $wifiSignalQuality = $null
    $wifiSSID = $null
    $wifiBand = $null

    # 仅当存在无线适配器、状态为 Up 且 WLAN 服务运行时检测
    $wirelessUpAdapter = $adapterList | Where-Object { $_.IsWireless -and $_.Status -eq 'Up' } | Select-Object -First 1

    if ($wirelessUpAdapter -and $wlanSvcRunning) {
        try {
            # 注意：不在 PS 5.1 中对原生命令使用 2>&1（会将 stderr 行包装为 ErrorRecord）
            $wlanOutput = netsh wlan show interfaces
            $outputText = if ($wlanOutput -is [array]) { $wlanOutput -join "`n" } else { "$wlanOutput" }

            # 解析 Signal 值（格式: "    Signal                 : 85%"）
            if ($outputText -match 'Signal\s*:\s*(\d+)%') {
                $wifiSignalQuality = [int]$Matches[1]
            }
            # 解析 SSID（格式: "    SSID                   : MyWiFi"）
            if ($outputText -match 'SSID\s*:\s*(.+)') {
                $wifiSSID = $Matches[1].Trim()
            }
            # 解析 Radio type / Band（格式: "    Radio type             : 802.11ax"）
            if ($outputText -match 'Radio type\s*:\s*(.+)') {
                $wifiBand = $Matches[1].Trim()
            }

            # 信号低于 30% → 警告
            if ($wifiSignalQuality -ne $null -and $wifiSignalQuality -lt 30) {
                $warnReasons += "Wi-Fi 信号弱: $wifiSignalQuality% (SSID: $wifiSSID)"
            }
        } catch {
            Write-Verbose "netsh wlan show interfaces 执行失败: $_"
        }
    }
    $diagnosis.WiFiSignalQuality = $wifiSignalQuality

    # ============================================================
    # 8. 飞行模式检测
    # ============================================================
    $airplaneMode = $false
    try {
        $radioMgmtPath = "HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement"
        if (Test-Path $radioMgmtPath) {
            # 检查子项中是否有 EnableRadio=0
            $subItems = Get-ChildItem -Path $radioMgmtPath -ErrorAction SilentlyContinue
            foreach ($subItem in $subItems) {
                try {
                    $props = Get-ItemProperty -Path $subItem.PSPath -ErrorAction SilentlyContinue
                    if ($props -and $props.PSObject.Properties['EnableRadio'] -ne $null) {
                        if ($props.EnableRadio -eq 0) {
                            $airplaneMode = $true
                            Write-Verbose "检测到飞行模式: $($subItem.PSChildName) EnableRadio=0"
                        }
                    }
                } catch {
                    # 子项读取失败，忽略
                }
            }

            # 也检查 Misc 子键的 SystemRadioState
            $miscPath = Join-Path $radioMgmtPath "Misc"
            if (Test-Path $miscPath) {
                try {
                    $miscProps = Get-ItemProperty -Path $miscPath -ErrorAction SilentlyContinue
                    if ($miscProps -and $miscProps.PSObject.Properties['ImplicitDisableIdex'] -ne $null) {
                        # ImplicitDisableIdex 非零表示某些无线电被隐式禁用
                        if ($miscProps.ImplicitDisableIdex -ne 0) {
                            $airplaneMode = $true
                            Write-Verbose "检测到隐式无线电禁用: ImplicitDisableIdex=$($miscProps.ImplicitDisableIdex)"
                        }
                    }
                } catch { }
            }
        }
    } catch {
        Write-Verbose "飞行模式注册表检测失败: $_"
    }
    $diagnosis.AirplaneMode = $airplaneMode

    if ($airplaneMode) {
        $warnReasons += "系统启用了飞行模式或无线电被禁用"
    }

    # ============================================================
    # 9. NCSI 网络探针检测
    # ============================================================
    $ncsiProbeFailed = $false
    $activeProbingEnabled = $true

    # 检查注册表中的 EnableActiveProbing
    try {
        $ncsiPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet"
        if (Test-Path $ncsiPath) {
            $ncsiProps = Get-ItemProperty -Path $ncsiPath -ErrorAction SilentlyContinue
            if ($ncsiProps -and $ncsiProps.PSObject.Properties['EnableActiveProbing'] -ne $null) {
                $activeProbingEnabled = ($ncsiProps.EnableActiveProbing -ne 0)
            }
        }
    } catch {
        Write-Verbose "NCSI 注册表读取失败: $_"
    }

    # 执行连通性测试
    if ($activeProbingEnabled -and $activeAdapters -gt 0) {
        try {
            $ncsiResult = Test-Connection -ComputerName "dns.msftncsi.com" -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($ncsiResult -eq $false) {
                $ncsiProbeFailed = $true
                $warnReasons += "NCSI 网络探针失败: 无法连接到 dns.msftncsi.com"
            }
        } catch {
            # Test-Connection 失败说明网络不通
            $ncsiProbeFailed = $true
            $warnReasons += "NCSI 网络探针失败: Test-Connection 执行异常"
        }
    } elseif ($activeAdapters -eq 0) {
        # 无活跃适配器，NCSI 自然不通
        $ncsiProbeFailed = $true
    }
    $diagnosis.NcsiProbeFailed = $ncsiProbeFailed

    # ============================================================
    # 判定 Verdict
    # ============================================================
    $diagnosis.DriverIssues = $driverIssues

    if ($failReasons.Count -gt 0) {
        $verdict = "FAIL"
    } elseif ($warnReasons.Count -gt 0) {
        $verdict = "WARN"
    } elseif ($activeAdapters -eq 0) {
        # 无活跃适配器但也没有显式故障原因 → 可能是未检测到网卡
        $verdict = "WARN"
        $warnReasons += "未检测到活跃的网络适配器"
    } else {
        $verdict = "PASS"
    }
    $diagnosis.Verdict = $verdict

    $stopwatch.Stop()
    $elapsedMs = [int]$stopwatch.ElapsedMilliseconds

    # ============================================================
    # 构建日志事件 (LogEvents)
    # ============================================================

    # 主诊断事件 (check.end)
    $mainEvent = @{
        event                = 'check.end'
        module               = 'M01'
        verdict              = $verdict
        elapsed_ms           = $elapsedMs
        active_adapters      = $activeAdapters
        total_adapters       = $adapterList.Count
        driver_issues        = $driverIssues
        driver_issue_count   = $driverIssues.Count
        pnp_error_count      = $pnPErrorDevices.Count
        wlan_svc_running     = $wlanSvcRunning
        wifi_signal_quality  = $wifiSignalQuality
        airplane_mode        = $airplaneMode
        ncsi_probe_failed    = $ncsiProbeFailed
        ndis_event_count_24h = $ndisEvents.Count
        use_fallback         = $useFallback
        fail_reasons         = $failReasons
        warn_reasons         = $warnReasons
    }
    $logEvents += $mainEvent

    # 尝试通过 Logger 库直接写入（dot-source 环境下可用）
    try {
        Write-DiagnosisEvent -Module "M01" -Verdict $verdict -ElapsedMs $elapsedMs -ExtraFields @{
            active_adapters    = $activeAdapters
            total_adapters     = $adapterList.Count
            driver_issues      = ($driverIssues -join '; ')
            pnp_error_count    = $pnPErrorDevices.Count
            wlan_svc_running   = $wlanSvcRunning
            wifi_signal_quality = $wifiSignalQuality
            airplane_mode      = $airplaneMode
            ncsi_probe_failed  = $ncsiProbeFailed
        }
    } catch {
        # Logger 库未加载（如在 Start-Job 子进程中），忽略异常
    }

    # 如果有驱动问题，记录详细警告事件
    foreach ($issue in $driverIssues) {
        $warnEvent = @{
            event    = 'check.warn'
            module   = 'M01'
            message  = $issue
            category = 'driver'
        }
        $logEvents += $warnEvent
    }

    # 如果有 PnP 错误设备，记录详细事件
    foreach ($dev in $pnPErrorDevices) {
        $pnpEvent = @{
            event       = 'check.fail'
            module      = 'M01'
            message     = "PnP设备错误: $($dev.Name) (ProblemCode: $($dev.ProblemCode))"
            instance_id = $dev.InstanceId
            category    = 'pnp'
        }
        $logEvents += $pnpEvent
    }

    # 如果检测到飞行模式，记录事件
    if ($airplaneMode) {
        $logEvents += @{
            event    = 'check.warn'
            module   = 'M01'
            message  = '系统启用了飞行模式'
            category = 'airplane_mode'
        }
    }

    # 返回完整结果
    return @{
        Diagnosis = $diagnosis
        LogEvents = $logEvents
    }
}

# ============================================================
# Invoke-M01_Repair - 网络适配器修复
# ============================================================

<#
.SYNOPSIS
    根据诊断结果执行网络适配器修复
.DESCRIPTION
    修复步骤：
    1. 驱动异常适配器重置 (Restart-PnpDevice / Disable→Enable NetAdapter)
    2. PnP 设备错误重置
    3. WLAN AutoConfig 服务启动
    4. 飞行模式提示（需用户手动操作）
    5. 修复后验证
.PARAMETER Diagnosis
    诊断结果哈希表（由 Invoke-M01_Diagnose 返回的 Diagnosis 键）
.OUTPUTS
    Hashtable - 包含 Repair 和 LogEvents 两个键
    Repair 包含: Verdict, RebootRequired, Steps
.EXAMPLE
    $fixResult = Invoke-M01_Repair -Diagnosis $diagResult.Diagnosis
    $fixResult.Repair.Verdict  # success / failed / skipped
#>
function Invoke-M01_Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Diagnosis
    )

    $logEvents = @()
    $steps = @()
    $rebootRequired = $false
    $allSuccess = $true

    # ---- 检查是否有问题需要修复 ----
    $hasDriverIssues = ($Diagnosis.DriverIssues -and $Diagnosis.DriverIssues.Count -gt 0)
    $hasPnPErrors = ($Diagnosis.PnPErrorDevices -and $Diagnosis.PnPErrorDevices.Count -gt 0)
    $wlanSvcNeedsStart = ($Diagnosis.ContainsKey('WlanSvcRunning') -and -not $Diagnosis.WlanSvcRunning)
    $needsAirplaneDisable = ($Diagnosis.ContainsKey('AirplaneMode') -and $Diagnosis.AirplaneMode)

    if (-not ($hasDriverIssues -or $hasPnPErrors -or $wlanSvcNeedsStart -or $needsAirplaneDisable)) {
        # 没有问题需要修复
        $steps += @{ Step = "跳过修复"; Result = "skipped"; Detail = "诊断未发现需要修复的问题" }
        $logEvents += @{
            event   = 'fix.end'
            module  = 'M01'
            verdict = 'skipped'
            reboot_required = $false
        }
        try { Write-FixEvent -Module "M01" -EventSubType "end" -Verdict "skipped" -RebootRequired $false } catch { }
        return @{
            Repair    = @{ Verdict = "skipped"; RebootRequired = $false; Steps = $steps }
            LogEvents = $logEvents
        }
    }

    # ============================================================
    # 步骤 1：修复驱动异常的适配器
    # ============================================================
    if ($hasDriverIssues) {
        Write-Verbose "开始修复驱动异常适配器..."
        $problemAdapters = $Diagnosis.Adapters | Where-Object {
            $_.Status -in @('Disabled', 'Error') -and $_.ifIndex -gt 0
        }

        foreach ($adapter in $problemAdapters) {
            $adapterName = $adapter.Name
            $ifIndex = $adapter.ifIndex

            # 先尝试 Restart-PnpDevice（针对已知的 InstanceId）
            $pnPDevice = $Diagnosis.PnPErrorDevices | Where-Object { $_.Name -match [regex]::Escape($adapterName) } | Select-Object -First 1

            if ($pnPDevice) {
                try {
                    Write-Verbose "尝试 Restart-PnpDevice: $($pnPDevice.InstanceId)"
                    $null = Restart-PnpDevice -InstanceId $pnPDevice.InstanceId -ErrorAction Stop
                    $steps += @{ Step = "重置PnP设备"; Result = "success"; Detail = "成功重启 PnP 设备: $adapterName (InstanceId: $($pnPDevice.InstanceId))" }
                    $logEvents += @{ event = 'fix.step'; module = 'M01'; step = "Restart-PnpDevice: $adapterName"; result = 'success' }
                    try { Write-FixEvent -Module "M01" -EventSubType "step" -Step "Restart-PnpDevice: $adapterName" -ExitCode 0 } catch { }
                    continue
                } catch {
                    Write-Verbose "Restart-PnpDevice 失败，尝试 Disable/Enable NetAdapter: $_"
                }
            }

            # 回退方案：Disable-NetAdapter → Enable-NetAdapter
            try {
                if ($ifIndex -gt 0) {
                    Write-Verbose "尝试禁用适配器: $adapterName (ifIndex=$ifIndex)"
                    $null = Disable-NetAdapter -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction Stop
                    Start-Sleep -Milliseconds 500
                    Write-Verbose "尝试启用适配器: $adapterName (ifIndex=$ifIndex)"
                    $null = Enable-NetAdapter -InterfaceIndex $ifIndex -ErrorAction Stop
                    $steps += @{ Step = "重置网卡"; Result = "success"; Detail = "成功重置适配器: $adapterName (ifIndex=$ifIndex)" }
                    $logEvents += @{ event = 'fix.step'; module = 'M01'; step = "Disable/Enable: $adapterName"; result = 'success' }
                    try { Write-FixEvent -Module "M01" -EventSubType "step" -Step "Disable/Enable: $adapterName" -ExitCode 0 } catch { }
                }
            } catch {
                $allSuccess = $false
                $steps += @{ Step = "重置网卡"; Result = "failed"; Detail = "无法重置适配器 $adapterName : $_" }
                $logEvents += @{ event = 'fix.step'; module = 'M01'; step = "Disable/Enable: $adapterName"; result = 'failed'; error = $_.ToString() }
                try { Write-FixEvent -Module "M01" -EventSubType "step" -Step "Disable/Enable(失败): $adapterName" -ExitCode 1 } catch { }
                try { Write-ErrorEvent -Severity "medium" -Message "适配器重置失败: $adapterName" -StackTrace $_.ToString() } catch { }
            }
        }
    }

    # ============================================================
    # 步骤 2：修复 PnP 设备 Error 状态
    # ============================================================
    if ($hasPnPErrors) {
        Write-Verbose "开始修复 PnP 设备错误..."
        foreach ($dev in $Diagnosis.PnPErrorDevices) {
            $instanceId = $dev.InstanceId
            $devName = $dev.Name

            try {
                Write-Verbose "尝试 Restart-PnpDevice: $instanceId"
                $null = Restart-PnpDevice -InstanceId $instanceId -ErrorAction Stop
                $steps += @{ Step = "重启PnP设备"; Result = "success"; Detail = "成功重启 PnP 设备: $devName" }
                $logEvents += @{ event = 'fix.step'; module = 'M01'; step = "Restart-PnpDevice: $devName"; result = 'success' }
                try { Write-FixEvent -Module "M01" -EventSubType "step" -Step "Restart-PnpDevice: $devName" -ExitCode 0 } catch { }
            } catch {
                $allSuccess = $false
                $steps += @{ Step = "重启PnP设备"; Result = "failed"; Detail = "无法重启 PnP 设备 $devName : $_" }
                $logEvents += @{ event = 'fix.step'; module = 'M01'; step = "Restart-PnpDevice: $devName"; result = 'failed'; error = $_.ToString() }
                try { Write-FixEvent -Module "M01" -EventSubType "step" -Step "Restart-PnpDevice(失败): $devName" -ExitCode 1 } catch { }
                try { Write-ErrorEvent -Severity "medium" -Message "PnP设备重启失败: $devName" -StackTrace $_.ToString() } catch { }
            }
        }
    }

    # ============================================================
    # 步骤 3：启动 WlanSvc 服务
    # ============================================================
    if ($wlanSvcNeedsStart) {
        Write-Verbose "尝试启动 WlanSvc 服务..."
        try {
            Start-Service -Name 'WlanSvc' -ErrorAction Stop
            $steps += @{ Step = "启动WLAN服务"; Result = "success"; Detail = "WLAN AutoConfig 服务已启动" }
            $logEvents += @{ event = 'fix.step'; module = 'M01'; step = "Start-Service WlanSvc"; result = 'success' }
            try { Write-FixEvent -Module "M01" -EventSubType "step" -Step "Start-Service WlanSvc" -ExitCode 0 } catch { }
        } catch {
            $allSuccess = $false
            $steps += @{ Step = "启动WLAN服务"; Result = "failed"; Detail = "无法启动 WlanSvc: $_" }
            $logEvents += @{ event = 'fix.step'; module = 'M01'; step = "Start-Service WlanSvc"; result = 'failed'; error = $_.ToString() }
            try { Write-FixEvent -Module "M01" -EventSubType "step" -Step "Start-Service WlanSvc(失败)" -ExitCode 1 } catch { }
            try { Write-ErrorEvent -Severity "medium" -Message "WLAN服务启动失败" -StackTrace $_.ToString() } catch { }
        }
    }

    # ============================================================
    # 步骤 4：飞行模式提示（需用户手动操作）
    # ============================================================
    if ($needsAirplaneDisable) {
        $steps += @{
            Step   = "关闭飞行模式"
            Result = "skipped"
            Detail = "飞行模式需手动关闭。请打开 Windows 设置 > 网络和 Internet > 飞行模式，关闭飞行模式开关；或在任务栏通知区域点击网络图标关闭飞行模式。"
        }
        $logEvents += @{
            event   = 'fix.step'
            module  = 'M01'
            step    = '飞行模式需手动关闭'
            result  = 'skipped'
            message = '检测到飞行模式或无线电被禁用，需用户手动操作'
        }
        try { Write-FixEvent -Module "M01" -EventSubType "step" -Step "飞行模式-需手动关闭" -ExitCode 0 } catch { }
        $rebootRequired = $false  # 飞行模式不需要重启
    }

    # ============================================================
    # 步骤 5：修复后验证（重新运行诊断子集）
    # ============================================================
    Write-Verbose "执行修复后验证..."
    $verifyResult = @{ Status = "ok"; Issues = @() }

    # 验证适配器状态
    try {
        $postAdapters = @(Get-NetAdapter -ErrorAction Stop)
        $errorsRemaining = $postAdapters | Where-Object { $_.Status -eq 'Disabled' -or $_.Status -eq 'Not Present' }
        if ($errorsRemaining.Count -gt 0) {
            $verifyResult.Status = "issues_remain"
            $verifyResult.Issues += "仍有 $($errorsRemaining.Count) 个适配器处于异常状态"
        }
    } catch {
        Write-Verbose "修复后适配器验证失败: $_"
        $verifyResult.Status = "verify_failed"
        $verifyResult.Issues += "适配器状态验证执行失败"
    }

    # 验证 WLAN 服务
    if ($wlanSvcNeedsStart) {
        try {
            $wlanSvc = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue
            if ($wlanSvc -and $wlanSvc.Status -ne 'Running') {
                $verifyResult.Status = "issues_remain"
                $verifyResult.Issues += "WLAN 服务仍未运行"
            }
        } catch { }
    }

    $steps += @{ Step = "修复后验证"; Result = $verifyResult.Status; Detail = ($verifyResult.Issues -join '; ') }

    # ============================================================
    # 确定修复最终判定
    # ============================================================
    if ($allSuccess) {
        $repairVerdict = "success"
    } else {
        $hasAnySuccess = @($steps | Where-Object { $_.Result -eq 'success' }).Count -gt 0
        $repairVerdict = if ($hasAnySuccess) { "success" } else { "failed" }
        if (-not $hasAnySuccess) { $repairVerdict = "failed" }
    }

    # 修复后日志事件
    $logEvents += @{
        event           = 'fix.end'
        module          = 'M01'
        verdict         = $repairVerdict
        reboot_required = $rebootRequired
        steps_count     = $steps.Count
        steps           = $steps
    }
    try {
        Write-FixEvent -Module "M01" -EventSubType "end" -Verdict $repairVerdict -RebootRequired $rebootRequired
    } catch { }

    return @{
        Repair    = @{
            Verdict        = $repairVerdict
            RebootRequired = $rebootRequired
            Steps          = $steps
        }
        LogEvents = $logEvents
    }
}

# ============================================================
# 模块导出说明
# ============================================================
# 本模块通过 dot-source 加载时，Invoke-M01_Diagnose 和 Invoke-M01_Repair
# 自动在当前作用域中可用，无需显式导出。
# 依赖的 lib 函数（Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent,
# Test-DigitalSignature, Get-NetAdapterFallback）由主脚本预先 dot-source 提供。
