#Requires -Version 5.1
<#
.SYNOPSIS
    M10 IP冲突检测与修复模块
.DESCRIPTION
    检测局域网内的 IP 地址冲突，包括：
    1. ARP 表 IP-MAC 冲突检测（Get-NetNeighbor 优先，arp -a 文本解析降级）
    2. 系统事件日志冲突事件检测（EventID 4199，24小时内）
    3. Gratuitous ARP 探测（纯 PS 5.1 零依赖环境不可用，标记为 NOT_AVAILABLE）

    修复通过 netsh + ipconfig 清理 ARP 缓存并续租 IP 地址。
.NOTES
    文件名: M10_IPConflict.ps1
    导出函数: Invoke-M10_Diagnose, Invoke-M10_Repair
    依赖: Logger.ps1 (Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent)
          Utils.ps1  (Test-RemoteSession)
    兼容: Windows PowerShell 5.1，零第三方依赖
#>

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    使用 Get-NetNeighbor 获取 ARP 表条目
.DESCRIPTION
    调用 Get-NetNeighbor -AddressFamily IPv4 获取所有 IPv4 邻居条目。
    返回 PSCustomObject 列表，包含 IPAddress 和 LinkLayerAddress 属性。
    若 cmdlet 不可用则返回 $null。
#>
function Get-ArpEntriesViaNetNeighbor {
    [CmdletBinding()]
    param()

    try {
        $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.State -ne 'Unreachable' -and $_.State -ne 'Permanent' }
        # Permanent 状态通常是静态 ARP 条目或本地接口，不参与冲突检测

        $entries = @()
        foreach ($n in $neighbors) {
            $mac = $n.LinkLayerAddress
            # 过滤无效 MAC（全零、空、广播地址）
            if ([string]::IsNullOrWhiteSpace($mac) -or
                $mac -eq '00-00-00-00-00-00' -or
                $mac -eq 'FF-FF-FF-FF-FF-FF') {
                continue
            }
            $entries += [PSCustomObject]@{
                IPAddress  = $n.IPAddress
                MACAddress = $mac.ToUpper()
            }
        }

        return $entries
    }
    catch {
        # Get-NetNeighbor 不可用，返回 $null 以触发降级
        return $null
    }
}

<#
.SYNOPSIS
    通过解析 arp -a 文本输出获取 ARP 表条目（降级方案）
.DESCRIPTION
    解析 arp -a 命令的文本输出。
    兼容中文和英文 Windows 的输出格式。
    格式示例（中文）：
        接口: 192.168.1.100 --- 0x5
          Internet 地址         物理地址              类型
          192.168.1.1           aa-bb-cc-dd-ee-ff     动态
    格式示例（英文）：
        Interface: 192.168.1.100 --- 0x5
          Internet Address      Physical Address      Type
          192.168.1.1           aa-bb-cc-dd-ee-ff     dynamic
#>
function Get-ArpEntriesViaArpA {
    [CmdletBinding()]
    param()

    try {
        $arpOutput = & arp -a 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $arpOutput) {
            return @()
        }
    }
    catch {
        return @()
    }

    $entries = @()

    foreach ($line in $arpOutput) {
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            $line = $line.ToString()
        }

        # 跳过空行和接口头行
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # 跳过接口定义行（中文 "接口:" 或英文 "Interface:"）
        if ($line -match '(接口|Interface):') { continue }
        # 跳过多播/广播地址行（它们属于接口信息行的一部分）
        if ($line -match '^\s*(224\.|239\.|255\.)') { continue }
        # 跳过列标题行
        if ($line -match '(Internet|互联|地址|Address|Physical|物理地址|Type|类型)') { continue }

        # 尝试匹配 IP + MAC 的数据行
        # MAC 格式：XX-XX-XX-XX-XX-XX（Windows arp -a 始终使用短横线）
        if ($line -match '^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-fA-F]{2}[-][0-9a-fA-F]{2}[-][0-9a-fA-F]{2}[-][0-9a-fA-F]{2}[-][0-9a-fA-F]{2}[-][0-9a-fA-F]{2})') {
            $ip  = $Matches[1]
            $mac = $Matches[2].ToUpper()

            # 过滤无效 MAC
            if ($mac -eq '00-00-00-00-00-00' -or $mac -eq 'FF-FF-FF-FF-FF-FF') {
                continue
            }

            # 跳过组播地址范围 224.0.0.0 - 239.255.255.255
            $firstOctet = [int]($ip.Split('.')[0])
            if ($firstOctet -ge 224 -and $firstOctet -le 239) { continue }

            $entries += [PSCustomObject]@{
                IPAddress  = $ip
                MACAddress = $mac
            }
        }
    }

    return $entries
}

<#
.SYNOPSIS
    根据 ARP 条目列表检测 IP-MAC 冲突
.DESCRIPTION
    按 IP 地址分组 ARP 条目，检测同一 IP 是否存在多个不同 MAC 地址。
    仅检查本机 IP 列表中的 IP（从 Context.IPv4 获取）。
    组播/广播地址已被上游过滤，此处不做额外过滤。
.PARAMETER ArpEntries
    ARP 条目列表，每项含 IPAddress 和 MACAddress
.PARAMETER LocalIPs
    本机 IP 地址字符串数组
#>
function Find-ArpConflicts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ArpEntries,

        [Parameter(Mandatory = $false)]
        [string[]]$LocalIPs = @()
    )

    $conflicts = @()

    # 按 IP 地址分组
    $grouped = $ArpEntries | Group-Object -Property IPAddress

    foreach ($group in $grouped) {
        $ip = $group.Name

        # 仅检查本机 IP
        if ($LocalIPs -notcontains $ip) { continue }

        # 收集该 IP 的所有唯一 MAC 地址
        $macSet = @{}
        foreach ($entry in $group.Group) {
            $mac = $entry.MACAddress
            if (-not $macSet.ContainsKey($mac)) {
                $macSet[$mac] = $true
            }
        }

        $uniqueMacs = @($macSet.Keys)

        # 同一 IP 存在多个不同 MAC → 冲突
        if ($uniqueMacs.Count -gt 1) {
            $conflicts += @{
                IP   = $ip
                Macs = $uniqueMacs
            }
        }
    }

    return $conflicts
}

<#
.SYNOPSIS
    通过系统事件日志检测 IP 地址冲突事件
.DESCRIPTION
    查询 System 日志中 EventID 4199（Windows IP 地址冲突检测事件），
    时间范围为过去 24 小时。
    若 Get-WinEvent 无权限或查询失败，返回 -1 表示不可用。
#>
function Get-IPConflictEventCount {
    [CmdletBinding()]
    param()

    try {
        $startTime = (Get-Date).AddHours(-24)
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 4199
            StartTime = $startTime
        } -MaxEvents 10 -ErrorAction Stop

        return @($events).Count
    }
    catch {
        # 无权限或查询失败，返回 -1 表示不可用
        return -1
    }
}

<#
.SYNOPSIS
    从诊断上下文提取本机 IPv4 地址列表
.DESCRIPTION
    支持多种 Context 格式：
    - Context.IPv4 为对象数组（每项含 Address 属性）
    - Context.IPv4 为字符串数组
    - Context 直接含 Address 或 IPAddress 键
#>
function Get-LocalIPList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $ips = @()

    if ($Context.ContainsKey('IPv4') -and $Context.IPv4) {
        foreach ($item in $Context.IPv4) {
            if ($item -is [string]) {
                $ips += $item
            }
            elseif ($item -is [hashtable] -and $item.ContainsKey('Address')) {
                $ips += $item.Address
            }
            elseif ($item -is [PSCustomObject] -and (Get-Member -InputObject $item -Name 'Address' -MemberType Properties)) {
                $ips += $item.Address
            }
            elseif ($item -is [PSCustomObject] -and (Get-Member -InputObject $item -Name 'IPAddress' -MemberType Properties)) {
                $ips += $item.IPAddress
            }
        }
    }

    # 如果 Context.IPv4 中未提取到，尝试 Context 根级别的 Address
    if (@($ips).Count -eq 0) {
        if ($Context.ContainsKey('Address')) {
            $ips += $Context.Address
        }
        elseif ($Context.ContainsKey('IPAddress')) {
            $ips += $Context.IPAddress
        }
    }

    # 去重并排除回环地址
    $ips = $ips | Select-Object -Unique | Where-Object { $_ -ne '127.0.0.1' -and $_ -notlike '169.254.*' }

    return @($ips)
}

# ============================================================
# 公共导出函数
# ============================================================

<#
.SYNOPSIS
    执行 M10 IP 冲突诊断
.DESCRIPTION
    检测局域网内的 IP 地址冲突：
    1. ARP 表 IP-MAC 冲突检测
    2. 系统事件日志（EventID 4199）24小时内冲突事件
    3. Gratuitous ARP 探测（标记为 NOT_AVAILABLE）
.PARAMETER Context
    诊断上下文哈希表，需包含 M02 输出的本机 IP 列表（IPv4.Address 或 IPv4 字符串数组）
.OUTPUTS
    System.Collections.Hashtable - 诊断结果结构：
    @{
        ArpConflicts       = @(@{IP; Macs = @()})  # IP-MAC 冲突列表
        ConflictEvents_24h = <int>                   # 24h 内 EventID 4199 事件数（-1 表示不可用）
        GarptDetected      = "NOT_AVAILABLE"         # Gratuitous ARP 探测状态
        Verdict            = "PASS"|"FAIL"|"WARN"|"UNKNOWN"
    }
.EXAMPLE
    $result = Invoke-M10_Diagnose -Context @{ IPv4 = @(@{Address="192.168.1.100"}) }
#>
function Invoke-M10_Diagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $localIPs = Get-LocalIPList -Context $Context
    } catch {
        $localIPs = @()
    }

    # ============================================================
    # 检查项1：ARP 表 IP-MAC 冲突检测
    # ============================================================
    $arpEntries = Get-ArpEntriesViaNetNeighbor

    if ($null -eq $arpEntries) {
        # Get-NetNeighbor 不可用，降级为 arp -a 文本解析
        $arpEntries = Get-ArpEntriesViaArpA
        $arpMethod  = 'arp -a (fallback)'
    }
    else {
        $arpMethod = 'Get-NetNeighbor'
    }

    if ($null -eq $localIPs) { $localIPs = @() }
    $arpConflicts = Find-ArpConflicts -ArpEntries $arpEntries -LocalIPs $localIPs

    # ============================================================
    # 检查项2：系统事件日志冲突事件检测（EventID 4199）
    # ============================================================
    $conflictEvents = Get-IPConflictEventCount
    $eventLogAvailable = ($conflictEvents -ge 0)

    # ============================================================
    # 检查项3：Gratuitous ARP 探测
    # 纯 PS 5.1 零依赖环境下不可实现（需 raw socket 发送 ARP 包）
    # ============================================================
    $garptDetected = 'NOT_AVAILABLE'

    # ============================================================
    # 综合判定
    # ============================================================
    $verdict = 'PASS'

    if ($arpConflicts.Count -gt 0) {
        # ARP 表中存在 IP-MAC 不唯一 → 明确冲突
        $verdict = 'FAIL'
    }
    elseif ($eventLogAvailable -and $conflictEvents -gt 0) {
        # 事件日志中有 24h 内的冲突记录
        $verdict = 'FAIL'
    }
    elseif (-not $eventLogAvailable -and $arpConflicts.Count -eq 0) {
        # 事件日志不可用，但 ARP 检测干净 → 警告（检测不完整）
        $verdict = 'WARN'
    }

    # 如果本机 IP 列表为空，标记为 UNKNOWN
    if ($localIPs.Count -eq 0) {
        $verdict = 'UNKNOWN'
    }

    $stopwatch.Stop()
    $elapsedMs = $stopwatch.ElapsedMilliseconds

    # ============================================================
    # 构建返回结果
    # ============================================================
    $diagnosis = @{
        ArpConflicts       = $arpConflicts
        ConflictEvents_24h = $conflictEvents
        GarptDetected      = $garptDetected
        Verdict            = $verdict
    }

    # 扩展字段（供调试和日志使用）
    $diagnosis['LocalIPs']         = $localIPs
    $diagnosis['ArpMethod']        = $arpMethod
    $diagnosis['EventLogAvail']    = $eventLogAvailable
    $diagnosis['ArpEntriesCount']  = $arpEntries.Count
    $diagnosis['Module']           = 'M10'

    # ============================================================
    # 构造日志事件列表
    # ============================================================
    $logEvents = @()

    # 诊断事件
    $diagEvent = @{
        event      = 'check.end'
        module     = 'M10'
        verdict    = $verdict
        elapsed_ms = $elapsedMs
    }
    # 附加诊断摘要信息
    $diagEvent['arp_conflicts']        = $arpConflicts.Count
    $diagEvent['conflict_events_24h']  = $conflictEvents
    $diagEvent['garpt_detected']       = $garptDetected
    $diagEvent['arp_method']           = $arpMethod
    $diagEvent['local_ip_count']       = $localIPs.Count

    $logEvents += $diagEvent

    # 如有冲突，记录冲突详情
    if ($arpConflicts.Count -gt 0) {
        foreach ($conflict in $arpConflicts) {
            $logEvents += @{
                event     = 'check.end'
                module    = 'M10'
                sub_check = 'arp_conflict'
                ip        = $conflict.IP
                macs      = ($conflict.Macs -join ', ')
            }
        }
    }

    # 返回结果与日志列表（供父进程统一写入日志文件）

    # 直接调用 Write-DiagnosisEvent（dot-source 场景直接写日志；Start-Job 场景因 Logger 未加载而静默跳过）
    try {
        $extraFields = @{
            arp_conflicts       = $arpConflicts.Count
            conflict_events_24h = $conflictEvents
            garpt_detected      = $garptDetected
            arp_method          = $arpMethod
            local_ip_count      = $localIPs.Count
        }
        Write-DiagnosisEvent -Module 'M10' -Verdict $verdict -ElapsedMs $elapsedMs -ExtraFields $extraFields
    }
    catch {
        # Logger.ps1 未加载（如 Start-Job 子进程），依赖返回的 LogEvents 由主线程统一写入
    }

    return @{
        Diagnosis = $diagnosis
        LogEvents = $logEvents
    }
}

<#
.SYNOPSIS
    执行 M10 IP 冲突修复
.DESCRIPTION
    修复步骤：
    1. netsh interface ip delete arpcache — 清理 ARP 缓存
    2. ipconfig /release → ipconfig /renew — 续租 IP（远程会话跳过 release）
    3. 验证 — 重新运行 M10 诊断子集确认无冲突
    4. 失败回退 — 提示用户检查局域网内是否有静态 IP 冲突设备

    风险等级：L2（低风险，可能导致短暂网络中断）
.PARAMETER Diagnosis
    M10 诊断结果哈希表（由 Invoke-M10_Diagnose 返回的 Diagnosis 部分）
.OUTPUTS
    System.Collections.Hashtable - 修复结果：
    @{
        Repair    = @{
            Verdict        = "success"|"failed"|"skipped"
            RebootRequired = $false
            Steps          = @(...)
        }
        LogEvents = @(...)
    }
.EXAMPLE
    $repairResult = Invoke-M10_Repair -Diagnosis $diagResult.Diagnosis
#>
function Invoke-M10_Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Diagnosis
    )

    $logEvents = @()
    $steps     = @()
    $verdict   = 'success'
    $rebootReq = $false

    # 检查是否为远程会话（远程会话跳过 ipconfig /release）
    $isRemote = $false
    try {
        $isRemote = Test-RemoteSession
    }
    catch {
        # Test-RemoteSession 不可用（Utils.ps1 未加载）→ 尝试简易检测
        if ($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:REMOTEHOST) {
            $isRemote = $true
        }
    }

    # ============================================================
    # 步骤1：清理 ARP 缓存
    # netsh interface ip delete arpcache 比 arp -d * 更可靠
    # ============================================================
    $stepName1 = 'netsh interface ip delete arpcache'
    try {
        $result = & netsh interface ip delete arpcache 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $steps += @{
            Step      = $stepName1
            ExitCode  = $exitCode
            Success   = ($exitCode -eq 0)
            Output    = $result.Trim()
        }

        $logEvents += @{
            event     = 'fix.step'
            module    = 'M10'
            step      = $stepName1
            exit_code = $exitCode
        }

        # 直接调用 Write-FixEvent（dot-source 场景）
        try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName1 -ExitCode $exitCode } catch {}

        if ($exitCode -ne 0) {
            try { Write-ErrorEvent -Severity 'low' -Message "M10 修复步骤1失败: $stepName1 (exit=$exitCode)" -StackTrace $result.Trim() } catch {}
        }
    }
    catch {
        $steps += @{
            Step      = $stepName1
            ExitCode  = -1
            Success   = $false
            Output    = $_.ToString()
        }

        $logEvents += @{
            event     = 'fix.step'
            module    = 'M10'
            step      = $stepName1
            exit_code = -1
        }

        try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName1 -ExitCode -1 } catch {}
        try { Write-ErrorEvent -Severity 'medium' -Message "M10 修复步骤1异常: $stepName1 - $_" -StackTrace $_.ScriptStackTrace } catch {}
    }

    # ============================================================
    # 步骤2：DHCP 续租（远程会话跳过 release）
    # ============================================================

    if (-not $isRemote) {
        # 2a: ipconfig /release
        $stepName2a = 'ipconfig /release'
        try {
            $result = & ipconfig /release 2>&1 | Out-String
            $exitCode = $LASTEXITCODE

            $steps += @{
                Step      = $stepName2a
                ExitCode  = $exitCode
                Success   = ($exitCode -eq 0)
                Output    = $result.Trim()
            }

            $logEvents += @{
                event     = 'fix.step'
                module    = 'M10'
                step      = $stepName2a
                exit_code = $exitCode
            }

            try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName2a -ExitCode $exitCode } catch {}

            # release 失败不致命（某些适配器可能不支持释放）
        }
        catch {
            $steps += @{
                Step      = $stepName2a
                ExitCode  = -1
                Success   = $false
                Output    = $_.ToString()
            }

            $logEvents += @{
                event     = 'fix.step'
                module    = 'M10'
                step      = $stepName2a
                exit_code = -1
            }

            try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName2a -ExitCode -1 } catch {}
            try { Write-ErrorEvent -Severity 'low' -Message "M10 修复步骤2a异常: $stepName2a - $_" -StackTrace $_.ScriptStackTrace } catch {}
        }
    }
    else {
        # 远程会话，跳过 release
        $stepName2a = 'ipconfig /release (已跳过：远程会话)'
        $steps += @{
            Step      = $stepName2a
            ExitCode  = 0
            Success   = $true
            Output    = '远程会话自动跳过 ipconfig /release，避免断开当前连接'
        }

        $logEvents += @{
            event     = 'fix.step'
            module    = 'M10'
            step      = $stepName2a
            exit_code = 0
        }

        try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName2a -ExitCode 0 } catch {}
    }

    # 2b: ipconfig /renew（所有场景都执行）
    $stepName2b = 'ipconfig /renew'
    try {
        $result = & ipconfig /renew 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $steps += @{
            Step      = $stepName2b
            ExitCode  = $exitCode
            Success   = ($exitCode -eq 0)
            Output    = $result.Trim()
        }

        $logEvents += @{
            event     = 'fix.step'
            module    = 'M10'
            step      = $stepName2b
            exit_code = $exitCode
        }

        try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName2b -ExitCode $exitCode } catch {}

        if ($exitCode -ne 0) {
            try { Write-ErrorEvent -Severity 'medium' -Message "M10 修复步骤2b失败: $stepName2b (exit=$exitCode)" -StackTrace $result.Trim() } catch {}
        }
    }
    catch {
        $steps += @{
            Step      = $stepName2b
            ExitCode  = -1
            Success   = $false
            Output    = $_.ToString()
        }

        $logEvents += @{
            event     = 'fix.step'
            module    = 'M10'
            step      = $stepName2b
            exit_code = -1
        }

        try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName2b -ExitCode -1 } catch {}
        try { Write-ErrorEvent -Severity 'medium' -Message "M10 修复步骤2b异常: $stepName2b - $_" -StackTrace $_.ScriptStackTrace } catch {}
    }

    # ============================================================
    # 步骤3：验证 — 重新运行 ARP 冲突检测
    # ============================================================
    $stepName3 = '验证：ARP 冲突复检'

    # 提取本机 IP 列表（从 Diagnosis 中获取）
    $localIPs = @()
    if ($Diagnosis.ContainsKey('LocalIPs')) {
        $localIPs = $Diagnosis['LocalIPs']
    }

    # 重新检测 ARP 表
    $arpEntries = Get-ArpEntriesViaNetNeighbor
    if ($null -eq $arpEntries) {
        $arpEntries = Get-ArpEntriesViaArpA
    }

    $postConflicts = Find-ArpConflicts -ArpEntries $arpEntries -LocalIPs $localIPs

    $verificationPassed = ($postConflicts.Count -eq 0)

    $steps += @{
        Step      = $stepName3
        ExitCode  = 0
        Success   = $verificationPassed
        Output    = if ($verificationPassed) {
            'ARP 表中未检测到 IP-MAC 冲突，修复生效'
        } else {
            "仍存在 $($postConflicts.Count) 个 IP-MAC 冲突：$($postConflicts | ForEach-Object { "$($_.IP) -> $($_.Macs -join ',')" } | Out-String)"
        }
    }

    $logEvents += @{
        event     = 'fix.step'
        module    = 'M10'
        step      = $stepName3
        exit_code = if ($verificationPassed) { 0 } else { 1 }
    }

    try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName3 -ExitCode (if ($verificationPassed) { 0 } else { 1 }) } catch {}

    # ============================================================
    # 步骤4：失败回退提示
    # ============================================================
    if (-not $verificationPassed) {
        $stepName4 = '提示：检查局域网静态IP冲突设备'
        $steps += @{
            Step      = $stepName4
            ExitCode  = 0
            Success   = $true
            Output    = 'ARP 冲突仍然存在，请检查局域网内是否有设备配置了与本机相同的静态 IP 地址，或联系网络管理员。'
        }

        $logEvents += @{
            event     = 'fix.step'
            module    = 'M10'
            step      = $stepName4
            exit_code = 0
        }

        try { Write-FixEvent -Module 'M10' -EventSubType 'step' -Step $stepName4 -ExitCode 0 } catch {}
    }

    # ============================================================
    # 综合判定
    # ============================================================
    if ($postConflicts.Count -eq 0) {
        $verdict = 'success'
    }
    else {
        # 有残留冲突
        $verdict = 'failed'
    }

    # 如果所有修复步骤都失败了（例如非管理员运行）
    $allStepsFailed = @($steps | Where-Object { $_.Success -eq $true }).Count -eq 0
    if ($allStepsFailed) {
        $verdict = 'failed'
    }

    # ============================================================
    # 最终修复事件
    # ============================================================
    $logEvents += @{
        event           = 'fix.end'
        module          = 'M10'
        verdict         = $verdict
        reboot_required = $rebootReq
    }

    # 直接调用 Write-FixEvent end（dot-source 场景直接写日志）
    try { Write-FixEvent -Module 'M10' -EventSubType 'end' -Verdict $verdict -RebootRequired $rebootReq } catch {}

    # ============================================================
    # 返回结果
    # ============================================================
    return @{
        Repair    = @{
            Verdict        = $verdict
            RebootRequired = $rebootReq
            Steps          = $steps
        }
        LogEvents = $logEvents
    }
}

# ============================================================
# 模块导出说明
# ============================================================
# 本文件通过 dot-source 加载（. .\modules\M10_IPConflict.ps1），
# 所有函数自动导入调用方作用域。
# 导出函数：
#   Invoke-M10_Diagnose  - IP 冲突诊断
#   Invoke-M10_Repair    - IP 冲突修复（ARP清理 + DHCP续租）
