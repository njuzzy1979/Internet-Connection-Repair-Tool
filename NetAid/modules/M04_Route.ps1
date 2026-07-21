#Requires -Version 5.1
<#
.SYNOPSIS
    NetAid M04 - 路由表诊断与修复模块
.DESCRIPTION
    检测默认路由存在性（IPv4/IPv6）、网关ARP可达性、黑洞路由、
    路由Metric冲突、PMTU探测。支持自动修复路由问题。
    风险等级：L2（低-中），修复可能短暂中断网络连接。
.NOTES
    文件名: M04_Route.ps1
    依赖: 零第三方依赖，需 NetTCPIP 模块（PS 5.1 内置）
    兼容: Windows PowerShell 5.1
    编码: UTF-8 with BOM
    日志: 调用 Write-DiagnosisEvent / Write-FixEvent / Write-ErrorEvent
#>

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    根据 InterfaceIndex 判断网卡类型（有线/无线）
.DESCRIPTION
    通过 Get-NetAdapter 的 NdisPhysicalMedium 或 InterfaceDescription 判断。
    无线特征：Native 802.11、Wireless LAN、Wireless WAN、"Wireless"/"Wi-Fi" 字样。
.OUTPUTS
    System.String - "Wired" 或 "Wireless" 或 "Unknown"
#>
function Get-InterfaceType {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$InterfaceIndex
    )

    try {
        $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop

        # 优先使用 NdisPhysicalMedium 精确判断
        $medium = $adapter.NdisPhysicalMedium
        if ($medium) {
            switch -Wildcard ($medium.ToString()) {
                'Native 802.11'   { return 'Wireless' }
                'Wireless LAN'    { return 'Wireless' }
                'Wireless WAN'    { return 'Wireless' }
                'Native 802.15.1' { return 'Wireless' }   # 蓝牙 PAN
                default           { return 'Wired' }
            }
        }

        # 回退：从接口描述文字判断
        $desc = $adapter.InterfaceDescription
        if ($desc -match 'Wireless|Wi[- ]?Fi|802\.11|Bluetooth') {
            return 'Wireless'
        }

        return 'Wired'
    }
    catch {
        return 'Unknown'
    }
}

<#
.SYNOPSIS
    对单个网关执行 ARP 可达性检测
.DESCRIPTION
    使用 Get-NetNeighbor 检查指定 IP 的 ARP 状态。
    返回包含 IP、State、MAC、Reachable 等信息的哈希表。
#>
function Test-GatewayArp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GatewayIP
    )

    $result = @{
        Gateway   = $GatewayIP
        State     = 'Unknown'
        MacAddress = ''
        Reachable = $false
    }

    try {
        $neighbor = Get-NetNeighbor -IPAddress $GatewayIP -ErrorAction SilentlyContinue |
                    Where-Object { $_.State -ne $null } |
                    Select-Object -First 1

        if ($neighbor) {
            $result.State = $neighbor.State.ToString()
            $result.MacAddress = if ($neighbor.LinkLayerAddress) { $neighbor.LinkLayerAddress } else { '' }

            # 仅 Reachable 和 Permanent 视为可达
            if ($neighbor.State -eq 'Reachable' -or $neighbor.State -eq 'Permanent') {
                $result.Reachable = $true
            }
        }
        else {
            $result.State = 'NotFound'
        }
    }
    catch {
        $result.State = "Error: $($_.Exception.Message)"
    }

    return $result
}

<#
.SYNOPSIS
    安全获取默认路由（IPv4 和 IPv6），带异常保护
#>
function Get-DefaultRoutes {
    param(
        [bool]$IncludeIPv6 = $true
    )

    $v4Routes = @()
    $v6Routes = @()

    try {
        $v4Routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    }
    catch {
        # 忽略错误，v4Routes 保持为空
    }

    if ($IncludeIPv6) {
        try {
            $v6Routes = @(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
        }
        catch {
            # 忽略错误
        }
    }

    return @{
        v4 = $v4Routes
        v6 = $v6Routes
    }
}

<#
.SYNOPSIS
    安全获取活动路由总数
#>
function Get-ActiveRouteCount {
    try {
        $allRoutes = @(Get-NetRoute -ErrorAction SilentlyContinue)
        return $allRoutes.Count
    }
    catch {
        return 0
    }
}

# ============================================================
# 公共函数：Invoke-M04_Diagnose
# ============================================================

<#
.SYNOPSIS
    执行 M04 路由表诊断
.DESCRIPTION
    检测项包括：
    1. IPv4/IPv6 默认路由存在性
    2. 网关 ARP 可达性 + 多网关排序
    3. 路由 Metric 冲突检测
    4. 黑洞路由检测
    5. 默认路由关联接口状态
    6. PMTU 探测（向网关发送 DF 大包）
.PARAMETER Context
    上下文哈希表，可含 M02 提供的 DefaultGateways（IP列表）、IPv6_Enabled
.OUTPUTS
    Hashtable @{ Diagnosis = @{...}; LogEvents = @(...) }
#>
function Invoke-M04_Diagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Context = @{}
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $logEvents = @()

    # ---- 初始化诊断结果字段 ----
    $diag = @{
        DefaultGatewayExists_v4      = $false
        DefaultGatewayExists_v6      = $false
        GatewayReachable             = $false
        GatewayMacResolved           = $false
        GatewayReachabilityRanking   = @()
        BlackholeRoutes              = @()
        ActiveRoutes                 = 0
        MetricConflicts              = $false
        PmtuProbeResult              = $null
        Verdict                      = 'UNKNOWN'
    }

    # 从 Context 提取辅助信息
    $ipv6Enabled = $false
    if ($Context.ContainsKey('IPv6_Enabled')) {
        $ipv6Enabled = [bool]$Context['IPv6_Enabled']
    }

    try {
        # ============================================================
        # 检测项 1：默认路由存在性
        # ============================================================
        $defaultRoutes = Get-DefaultRoutes -IncludeIPv6 $ipv6Enabled

        $diag.DefaultGatewayExists_v4 = ($defaultRoutes.v4.Count -gt 0)
        if (-not $diag.DefaultGatewayExists_v4) {
            $logEvents += @{
                event   = 'check.item'
                module  = 'M04'
                item    = 'DefaultGatewayExists_v4'
                verdict = 'FAIL'
                detail  = '未找到 IPv4 默认路由 (0.0.0.0/0)，这是严重故障'
            }
        }

        if ($ipv6Enabled) {
            $diag.DefaultGatewayExists_v6 = ($defaultRoutes.v6.Count -gt 0)
            if (-not $diag.DefaultGatewayExists_v6) {
                $logEvents += @{
                    event   = 'check.item'
                    module  = 'M04'
                    item    = 'DefaultGatewayExists_v6'
                    verdict = 'WARN'
                    detail  = 'IPv6 已启用但未找到 IPv6 默认路由 (::/0)'
                }
            }
        }

        # ============================================================
        # 检测项 2：网关可达性（ARP层）+ 多网关排序
        # ============================================================
        # 从所有默认路由中提取唯一的 NextHop 列表
        $allDefaultRoutes = $defaultRoutes.v4 + $defaultRoutes.v6
        $uniqueGateways = @{}
        $gatewayRouteMap = @{}  # Gateway -> 关联的路由对象（用于获取 InterfaceIndex）

        foreach ($route in $allDefaultRoutes) {
            $nh = $route.NextHop.ToString()
            if ($nh -and $nh -ne '0.0.0.0' -and $nh -ne '::' -and -not $uniqueGateways.ContainsKey($nh)) {
                $uniqueGateways[$nh] = $true
                $gatewayRouteMap[$nh] = $route
            }
        }

        $gatewayRankings = @()
        foreach ($gw in $uniqueGateways.Keys) {
            $arpResult = Test-GatewayArp -GatewayIP $gw

            # 获取该网关关联的接口类型
            $ifType = 'Unknown'
            try {
                $route = $gatewayRouteMap[$gw]
                if ($route -and $route.InterfaceIndex) {
                    $ifType = Get-InterfaceType -InterfaceIndex $route.InterfaceIndex
                }
            }
            catch {
                $ifType = 'Unknown'
            }

            $ranking = @{
                Gateway       = $gw
                Reachable     = $arpResult.Reachable
                InterfaceType = $ifType
                MacAddress    = $arpResult.MacAddress
                ArpState      = $arpResult.State
            }
            $gatewayRankings += $ranking
        }

        # 按可达性排序：可达+有线 > 可达+无线 > 不可达
        $gatewayRankings = $gatewayRankings | Sort-Object -Property {
            $reachScore = if ($_.Reachable) { 0 } else { 2 }
            $typeScore  = if ($_.InterfaceType -eq 'Wired') { 0 } else { 1 }
            ($reachScore * 10 + $typeScore)
        }

        $diag.GatewayReachabilityRanking = @($gatewayRankings)

        # 判断整体网关可达性和 MAC 解析状态
        $anyReachable = @($gatewayRankings | Where-Object { $_.Reachable }).Count -gt 0
        $anyMacResolved = @($gatewayRankings | Where-Object { $_.MacAddress -and $_.MacAddress.Length -gt 0 }).Count -gt 0
        $diag.GatewayReachable = $anyReachable
        $diag.GatewayMacResolved = $anyMacResolved

        if (-not $anyReachable -and $uniqueGateways.Count -gt 0) {
            $logEvents += @{
                event   = 'check.item'
                module  = 'M04'
                item    = 'GatewayReachable'
                verdict = 'FAIL'
                detail  = "所有网关 ($($uniqueGateways.Keys -join ', ')) ARP 不可达"
            }
        }

        # ============================================================
        # 检测项 3：路由 Metric 异常（Metric 冲突检测）
        # ============================================================
        # 检查是否有两个 Up 接口同时有默认路由且 Metric 相同
        $v4DefaultRoutes = $defaultRoutes.v4
        $metricMap = @{}

        foreach ($route in $v4DefaultRoutes) {
            try {
                $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
                if ($adapter -and $adapter.Status -eq 'Up') {
                    $metricKey = "$($route.RouteMetric)"
                    if (-not $metricMap.ContainsKey($metricKey)) {
                        $metricMap[$metricKey] = @()
                    }
                    $metricMap[$metricKey] += @{
                        InterfaceIndex = $route.InterfaceIndex
                        InterfaceAlias = $route.InterfaceAlias
                        Metric         = $route.RouteMetric
                    }
                }
            }
            catch {
                # 忽略单个接口检查错误
            }
        }

        foreach ($key in $metricMap.Keys) {
            if ($metricMap[$key].Count -gt 1) {
                $diag.MetricConflicts = $true
                $conflictIfaces = ($metricMap[$key] | ForEach-Object { "$($_.InterfaceAlias)($($_.InterfaceIndex))" }) -join ', '
                $logEvents += @{
                    event   = 'check.item'
                    module  = 'M04'
                    item    = 'MetricConflicts'
                    verdict = 'WARN'
                    detail  = "Metric 冲突 (值=$key)：$conflictIfaces"
                }
                break
            }
        }

        # ============================================================
        # 检测项 4：黑洞路由检测
        # ============================================================
        try {
            $blackholeRoutes = Get-NetRoute -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                               Where-Object {
                                   $_.NextHop -eq '0.0.0.0' -and
                                   $_.DestinationPrefix -ne '0.0.0.0/0'
                               }

            if ($blackholeRoutes) {
                foreach ($br in $blackholeRoutes) {
                    $diag.BlackholeRoutes += @{
                        DestinationPrefix = $br.DestinationPrefix
                        InterfaceAlias    = $br.InterfaceAlias
                        InterfaceIndex    = $br.InterfaceIndex
                        RouteMetric       = $br.RouteMetric
                    }
                }

                $logEvents += @{
                    event   = 'check.item'
                    module  = 'M04'
                    item    = 'BlackholeRoutes'
                    verdict = 'WARN'
                    detail  = "发现 $($diag.BlackholeRoutes.Count) 条黑洞路由"
                }
            }
        }
        catch {
            # 黑洞路由检测非致命错误
        }

        # ============================================================
        # 检测项 5：活动路由总数
        # ============================================================
        $diag.ActiveRoutes = Get-ActiveRouteCount

        # ============================================================
        # 检测项 6：默认路由关联接口状态
        # ============================================================
        $disconnectedIfaces = @()
        foreach ($route in $v4DefaultRoutes) {
            try {
                $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
                if ($adapter -and $adapter.Status -ne 'Up') {
                    $disconnectedIfaces += "$($route.InterfaceAlias)($($route.InterfaceIndex)): $($adapter.Status)"
                }
            }
            catch {
                $disconnectedIfaces += "$($route.InterfaceAlias)($($route.InterfaceIndex)): 无法查询状态"
            }
        }

        if ($disconnectedIfaces.Count -gt 0) {
            $logEvents += @{
                event   = 'check.item'
                module  = 'M04'
                item    = 'DefaultRouteInterfaceStatus'
                verdict = 'WARN'
                detail  = "以下默认路由接口状态异常: $($disconnectedIfaces -join '; ')"
            }
        }

        # ============================================================
        # 检测项 7：PMTU 探测
        # ============================================================
        # PS 5.1 不支持 Test-Connection -MtuSize，使用 ping -f -l 回退方案
        if ($anyReachable) {
            $targetGateway = ($gatewayRankings | Where-Object { $_.Reachable } | Select-Object -First 1).Gateway
            if ($targetGateway) {
                try {
                    # 1500 字节 MTU 探测：1472 字节数据 + 28 字节 ICMP/IP 头 = 1500
                    $packetSize = 1472
                    $pingResult = & ping.exe -n 1 -f -l $packetSize $targetGateway 2>&1
                    $mtuSuccess = ($LASTEXITCODE -eq 0)

                    $diag.PmtuProbeResult = @{
                        MtuSize = 1500
                        Success = $mtuSuccess
                        Gateway = $targetGateway
                    }

                    if (-not $mtuSuccess) {
                        # MTU 过大，尝试 1400 字节
                        $packetSize1400 = 1372
                        $pingResult1400 = & ping.exe -n 1 -f -l $packetSize1400 $targetGateway 2>&1
                        $mtuSuccess1400 = ($LASTEXITCODE -eq 0)

                        if ($mtuSuccess1400) {
                            $diag.PmtuProbeResult = @{
                                MtuSize = 1400
                                Success = $true
                                Gateway = $targetGateway
                            }
                        }

                        $logEvents += @{
                            event   = 'check.item'
                            module  = 'M04'
                            item    = 'PmtuProbe'
                            verdict = if ($mtuSuccess1400) { 'WARN' } else { 'FAIL' }
                            detail  = "PMTU 探测：1500 失败，1400 $(if ($mtuSuccess1400) { '成功' } else { '失败' })"
                        }
                    }
                }
                catch {
                    $diag.PmtuProbeResult = $null
                }
            }
        }

        # ============================================================
        # 综合判定 Verdict
        # ============================================================
        if (-not $diag.DefaultGatewayExists_v4) {
            $diag.Verdict = 'FAIL'
        }
        elseif ($diag.GatewayReachabilityRanking.Count -gt 0 -and -not $diag.GatewayReachable) {
            $diag.Verdict = 'FAIL'
        }
        elseif ($diag.MetricConflicts -or $diag.BlackholeRoutes.Count -gt 0) {
            $diag.Verdict = 'WARN'
        }
        elseif ($ipv6Enabled -and -not $diag.DefaultGatewayExists_v6) {
            $diag.Verdict = 'WARN'
        }
        elseif ($diag.PmtuProbeResult -and -not $diag.PmtuProbeResult.Success) {
            $diag.Verdict = 'WARN'
        }
        else {
            $diag.Verdict = 'PASS'
        }
    }
    catch {
        # 整体异常捕获 —— 整个诊断模块失败
        $diag.Verdict = 'FAIL'
        $diag['Error'] = $_.Exception.Message

        try {
            Write-ErrorEvent -Severity 'high' `
                             -Message "M04 诊断异常: $($_.Exception.Message)" `
                             -StackTrace $_.ScriptStackTrace
        }
        catch {
            # 日志函数不可用，忽略
        }
    }

    $sw.Stop()
    $elapsedMs = $sw.ElapsedMilliseconds

    # ---- 写入诊断结束事件 ----
    try {
        $extraFields = @{
            default_gateway_v4   = $diag.DefaultGatewayExists_v4
            default_gateway_v6   = $diag.DefaultGatewayExists_v6
            gateway_reachable    = $diag.GatewayReachable
            metric_conflicts     = $diag.MetricConflicts
            blackhole_count      = $diag.BlackholeRoutes.Count
            active_routes        = $diag.ActiveRoutes
            gateway_count        = $diag.GatewayReachabilityRanking.Count
        }
        Write-DiagnosisEvent -Module 'M04' `
                             -Verdict $diag.Verdict `
                             -ElapsedMs $elapsedMs `
                             -ExtraFields $extraFields
    }
    catch {
        # 日志写入失败不应影响诊断结果
    }

    return @{
        Diagnosis = $diag
        LogEvents = $logEvents
    }
}

# ============================================================
# 公共函数：Invoke-M04_Repair
# ============================================================

<#
.SYNOPSIS
    执行 M04 路由表修复
.DESCRIPTION
    修复步骤：
    1. 删除指向 Disconnected 接口的持久路由
    2. 删除黑洞路由
    3. 若默认路由缺失，添加默认路由
    4. 若有 Metric 冲突，调整 Metric 值
    5. 验证修复结果（重检默认路由存在性和 ARP 可达性）
.PARAMETER Diagnosis
    M04 的诊断结果哈希表（Invoke-M04_Diagnose 的返回值）
.OUTPUTS
    Hashtable @{ Repair = @{...}; LogEvents = @(...) }
#>
function Invoke-M04_Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Diagnosis
    )

    $logEvents = @()
    $steps = @()
    $repairVerdict = 'success'
    $rebootRequired = $false

    try {
        # ============================================================
        # 步骤 1：删除指向 Disconnected 接口的持久路由
        # ============================================================
        $stepName = '删除已断开接口的持久路由'
        try {
            $persistentRoutes = @(Get-NetRoute -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
            $removedCount = 0

            foreach ($route in $persistentRoutes) {
                try {
                    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
                    if ($adapter -and $adapter.Status -ne 'Up') {
                        Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop
                        $removedCount++

                        Write-FixEvent -Module 'M04' `
                                       -EventSubType 'step' `
                                       -Step "删除持久路由: $($route.DestinationPrefix) -> $($route.NextHop) (接口 $($route.InterfaceAlias) 已断开)" `
                                       -ExitCode 0
                    }
                    elseif (-not $adapter) {
                        # 接口不存在，删除路由
                        Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop
                        $removedCount++

                        Write-FixEvent -Module 'M04' `
                                       -EventSubType 'step' `
                                       -Step "删除残留持久路由: $($route.DestinationPrefix) (接口索引 $($route.InterfaceIndex) 不存在)" `
                                       -ExitCode 0
                    }
                }
                catch {
                    Write-FixEvent -Module 'M04' `
                                   -EventSubType 'step' `
                                   -Step "删除持久路由失败: $($route.DestinationPrefix)" `
                                   -ExitCode 1
                }
            }

            $steps += @{
                Step   = $stepName
                Action = "Remove-NetRoute (PersistentStore)"
                Result = 'success'
                Detail = "删除了 $removedCount 条持久路由"
            }
        }
        catch {
            $steps += @{
                Step   = $stepName
                Action = "Remove-NetRoute (PersistentStore)"
                Result = 'failed'
                Detail = $_.Exception.Message
            }
        }

        # ============================================================
        # 步骤 2：删除黑洞路由
        # ============================================================
        $stepName = '删除黑洞路由'
        try {
            $blackholeRemoved = 0

            if ($Diagnosis.ContainsKey('BlackholeRoutes') -and $Diagnosis.BlackholeRoutes.Count -gt 0) {
                foreach ($br in $Diagnosis.BlackholeRoutes) {
                    try {
                        $routeToRemove = Get-NetRoute -DestinationPrefix $br.DestinationPrefix `
                                                      -InterfaceIndex $br.InterfaceIndex `
                                                      -ErrorAction SilentlyContinue
                        if ($routeToRemove) {
                            Remove-NetRoute -InputObject $routeToRemove -Confirm:$false -ErrorAction Stop
                            $blackholeRemoved++

                            Write-FixEvent -Module 'M04' `
                                           -EventSubType 'step' `
                                           -Step "删除黑洞路由: $($br.DestinationPrefix) (接口 $($br.InterfaceAlias))" `
                                           -ExitCode 0
                        }
                    }
                    catch {
                        Write-FixEvent -Module 'M04' `
                                       -EventSubType 'step' `
                                       -Step "删除黑洞路由失败: $($br.DestinationPrefix)" `
                                       -ExitCode 1
                    }
                }
            }

            $steps += @{
                Step   = $stepName
                Action = "Remove-NetRoute (Blackhole)"
                Result = 'success'
                Detail = "删除了 $blackholeRemoved 条黑洞路由"
            }
        }
        catch {
            $steps += @{
                Step   = $stepName
                Action = "Remove-NetRoute (Blackhole)"
                Result = 'failed'
                Detail = $_.Exception.Message
            }
        }

        # ============================================================
        # 步骤 3：添加缺失的默认路由
        # ============================================================
        $stepName = '添加默认路由（若缺失）'
        try {
            $currentV4Defaults = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)

            if ($currentV4Defaults.Count -eq 0) {
                # 选择最优网关：有线 + Up 接口 + 非 VPN
                $allAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
                $bestGateway = $null
                $bestInterfaceIndex = $null
                $bestMetric = [int]::MaxValue

                foreach ($adapter in $allAdapters) {
                    # 跳过 VPN / 虚拟适配器（除非 M06 明确标记为活跃 VPN）
                    $desc = $adapter.InterfaceDescription
                    if ($desc -match 'TAP|Wintun|WireGuard|VPN|Virtual|Loopback') {
                        continue
                    }

                    # 获取该接口的网关信息
                    try {
                        $adapterIPInfo = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                                                          -AddressFamily IPv4 `
                                                          -ErrorAction SilentlyContinue |
                                         Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -ne '127.0.0.1' } |
                                         Select-Object -First 1

                        if ($adapterIPInfo) {
                            $netPrefix = $adapterIPInfo.IPv4Address.ToString()
                            # 从接口 IP 推导网关（通常网关是网段第一个或最后一个地址）
                            $prefixLength = $adapterIPInfo.PrefixLength
                            # 更可靠的方式：直接使用 Get-NetRoute 查找该接口的默认网关候选
                            $ifType = Get-InterfaceType -InterfaceIndex $adapter.InterfaceIndex
                            $typeScore = if ($ifType -eq 'Wired') { 0 } else { 1 }

                            if ($typeScore -lt 2 -and $adapter.ifIndex -gt 0) {
                                # 有线优先，无线其次
                                $currentScore = (if ($bestGateway) { (if ($ifType -eq 'Wired') { 0 } else { 1 }) } else { 2 })
                                if ($typeScore -le $currentScore) {
                                    # 尝试从 DHCP 获取网关
                                    try {
                                        $dhcpGateway = Get-NetIPConfiguration -InterfaceIndex $adapter.InterfaceIndex `
                                                         -ErrorAction SilentlyContinue |
                                                         Select-Object -ExpandProperty IPv4DefaultGateway |
                                                         Select-Object -First 1
                                        if ($dhcpGateway -and $dhcpGateway.NextHop) {
                                            $bestGateway = $dhcpGateway.NextHop.ToString()
                                            $bestInterfaceIndex = $adapter.InterfaceIndex
                                            $bestMetric = 0  # 将在 New-NetRoute 时自动分配
                                            break
                                        }
                                    }
                                    catch {
                                        # DHCP 查询失败，继续尝试
                                    }

                                    # 回退方案：从接口 IP 推导网关
                                    if (-not $bestGateway -and $adapterIPInfo) {
                                        $ipParts = $adapterIPInfo.IPv4Address.ToString().Split('.')
                                        # 假设网关为 .1（常见配置）
                                        $candidateGw = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2]).1"
                                        $bestGateway = $candidateGw
                                        $bestInterfaceIndex = $adapter.InterfaceIndex
                                        $bestMetric = if ($ifType -eq 'Wired') { 0 } else { 10 }
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        continue
                    }
                }

                if ($bestGateway -and $bestInterfaceIndex) {
                    try {
                        New-NetRoute -DestinationPrefix '0.0.0.0/0' `
                                     -NextHop $bestGateway `
                                     -InterfaceIndex $bestInterfaceIndex `
                                     -RouteMetric 0 `
                                     -ErrorAction Stop

                        $steps += @{
                            Step   = $stepName
                            Action = "New-NetRoute 0.0.0.0/0 -> $bestGateway (Idx=$bestInterfaceIndex)"
                            Result = 'success'
                            Detail = "已添加默认路由，下一跳：$bestGateway"
                        }

                        Write-FixEvent -Module 'M04' `
                                       -EventSubType 'step' `
                                       -Step "添加默认路由: 0.0.0.0/0 -> $bestGateway (接口索引 $bestInterfaceIndex)" `
                                       -ExitCode 0
                    }
                    catch {
                        $steps += @{
                            Step   = $stepName
                            Action = "New-NetRoute 0.0.0.0/0"
                            Result = 'failed'
                            Detail = $_.Exception.Message
                        }

                        Write-FixEvent -Module 'M04' `
                                       -EventSubType 'step' `
                                       -Step "添加默认路由失败: $($_.Exception.Message)" `
                                       -ExitCode 1
                    }
                }
                else {
                    $steps += @{
                        Step   = $stepName
                        Action = "New-NetRoute 0.0.0.0/0"
                        Result = 'skipped'
                        Detail = '未找到可用的网关地址，无法添加默认路由'
                    }
                }
            }
            else {
                $steps += @{
                    Step   = $stepName
                    Action = "New-NetRoute"
                    Result = 'skipped'
                    Detail = '默认路由已存在，无需添加'
                }
            }
        }
        catch {
            $steps += @{
                Step   = $stepName
                Action = "New-NetRoute"
                Result = 'failed'
                Detail = $_.Exception.Message
            }
        }

        # ============================================================
        # 步骤 4：修复 Metric 冲突
        # ============================================================
        $stepName = '修复路由 Metric 冲突'
        try {
            $metricFixed = $false

            if ($Diagnosis.ContainsKey('MetricConflicts') -and $Diagnosis.MetricConflicts) {
                $v4Defaults = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
                $metricGroups = @{}

                foreach ($route in $v4Defaults) {
                    try {
                        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
                        if ($adapter -and $adapter.Status -eq 'Up') {
                            $mKey = "$($route.RouteMetric)"
                            if (-not $metricGroups.ContainsKey($mKey)) {
                                $metricGroups[$mKey] = @()
                            }
                            $metricGroups[$mKey] += $route
                        }
                    }
                    catch { }
                }

                foreach ($key in $metricGroups.Keys) {
                    $group = $metricGroups[$key]
                    if ($group.Count -gt 1) {
                        # 保留 metric 最低的，其余递增
                        # 实际上是完全相同的 metric 冲突，给后续的递增 metric
                        for ($i = 1; $i -lt $group.Count; $i++) {
                            $newMetric = [int]$key + ($i * 10)
                            try {
                                Set-NetRoute -InputObject $group[$i] `
                                             -RouteMetric $newMetric `
                                             -ErrorAction Stop
                                $metricFixed = $true

                                Write-FixEvent -Module 'M04' `
                                               -EventSubType 'step' `
                                               -Step "调整路由 Metric: $($group[$i].InterfaceAlias) $key -> $newMetric" `
                                               -ExitCode 0
                            }
                            catch {
                                Write-FixEvent -Module 'M04' `
                                               -EventSubType 'step' `
                                               -Step "调整路由 Metric 失败: $($group[$i].InterfaceAlias)" `
                                               -ExitCode 1
                            }
                        }
                    }
                }
            }

            $steps += @{
                Step   = $stepName
                Action = "Set-NetRoute (Metric)"
                Result = if ($metricFixed) { 'success' } else { 'skipped' }
                Detail = if ($metricFixed) { '已调整冲突的 Metric 值' } else { '无 Metric 冲突或无需修复' }
            }
        }
        catch {
            $steps += @{
                Step   = $stepName
                Action = "Set-NetRoute (Metric)"
                Result = 'failed'
                Detail = $_.Exception.Message
            }
        }

        # ============================================================
        # 步骤 5：验证修复结果
        # ============================================================
        $stepName = '验证修复结果'
        try {
            # 重新检查默认路由存在性
            $verifyV4Routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
            $v4Exists = ($verifyV4Routes.Count -gt 0)

            # 重新检查网关 ARP 可达性
            $anyReachable = $false
            foreach ($route in $verifyV4Routes) {
                try {
                    $nh = $route.NextHop.ToString()
                    if ($nh -and $nh -ne '0.0.0.0') {
                        $neighbor = Get-NetNeighbor -IPAddress $nh -ErrorAction SilentlyContinue |
                                    Select-Object -First 1
                        if ($neighbor -and ($neighbor.State -eq 'Reachable' -or $neighbor.State -eq 'Permanent')) {
                            $anyReachable = $true
                            break
                        }
                    }
                }
                catch { }
            }

            if ($v4Exists -and $anyReachable) {
                $steps += @{
                    Step   = $stepName
                    Action = 'Verify (DefaultRoute + ARP)'
                    Result = 'success'
                    Detail = '默认路由存在且网关 ARP 可达'
                }
            }
            elseif ($v4Exists) {
                # 路由存在但 ARP 不可达 —— 可能需要时间，不算完全失败
                $steps += @{
                    Step   = $stepName
                    Action = 'Verify (DefaultRoute + ARP)'
                    Result = 'success'
                    Detail = '默认路由已恢复，网关 ARP 尚未确认（可能需等待 ARP 学习）'
                }
            }
            else {
                $steps += @{
                    Step   = $stepName
                    Action = 'Verify (DefaultRoute + ARP)'
                    Result = 'failed'
                    Detail = '修复后仍无默认路由'
                }
                $repairVerdict = 'failed'
            }
        }
        catch {
            $steps += @{
                Step   = $stepName
                Action = 'Verify'
                Result = 'failed'
                Detail = $_.Exception.Message
            }
            $repairVerdict = 'failed'
        }
    }
    catch {
        # 整体异常捕获
        $repairVerdict = 'failed'
        $steps += @{
            Step   = '全局异常'
            Action = 'Catch'
            Result = 'failed'
            Detail = $_.Exception.Message
        }

        try {
            Write-ErrorEvent -Severity 'high' `
                             -Message "M04 修复异常: $($_.Exception.Message)" `
                             -StackTrace $_.ScriptStackTrace
        }
        catch { }
    }

    # ---- 写入修复结束事件 ----
    try {
        Write-FixEvent -Module 'M04' `
                       -EventSubType 'end' `
                       -Verdict $repairVerdict `
                       -RebootRequired $rebootRequired
    }
    catch { }

    return @{
        Repair = @{
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
# 本文件通过 dot-source 加载，所有函数自动在当前作用域中可用。
# 公共导出函数：
#   Invoke-M04_Diagnose  - 路由表诊断
#   Invoke-M04_Repair    - 路由表修复
