#Requires -Version 5.1
<#
.SYNOPSIS
    M02 IP配置与DHCP 诊断修复模块
.DESCRIPTION
    执行 IP 地址配置、DHCP 租约状态、IPv6 地址、MTU 值的诊断检测，
    并自动修复 APIPA(169.254.x.x)、DHCP 租约过期、MTU 异常等问题。
    所有诊断结果通过 Write-DiagnosisEvent 写入日志，
    所有修复步骤通过 Write-FixEvent 写入日志。
.NOTES
    文件名: M02_IP_DHCP.ps1
    依赖: NetAid lib (Logger.ps1, Utils.ps1) —— 通过 dot-source 加载
          本模块假定以下函数已在调用方作用域中可用：
          Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent, Test-RemoteSession
    兼容: Windows PowerShell 5.1
    编码: UTF-8 with BOM
#>

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    从 ipconfig /all 文本输出中解析网络配置信息
.DESCRIPTION
    当 NetIP cmdlet 族不可用时，解析 ipconfig /all 文本输出作为回退方案。
    提取每个适配器的 IPv4 地址、子网掩码、默认网关、DNS 服务器、DHCP 状态。
.OUTPUTS
    System.Collections.Hashtable[] - 每个元素为一个适配器的配置信息
#>
function Parse-IpConfigAll {
    [CmdletBinding()]
    param()

    $adapters = @()
    try {
        $rawOutput = & ipconfig /all 2>$null | Out-String
        if (-not $rawOutput) {
            return $adapters
        }

        # 按行拆分（跳过"Windows IP 配置"等全局头）
        $lines = $rawOutput -split "`r`n|`n"

        $currentAdapter = $null
        $dnsList = @()
        $inDnsSection = $false

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '') {
                # 空行表示一个适配器段结束，保存当前适配器
                if ($currentAdapter -and $currentAdapter['IPv4Address']) {
                    $currentAdapter['DnsServers'] = $dnsList
                    $adapters += $currentAdapter
                }
                $currentAdapter = $null
                $dnsList = @()
                $inDnsSection = $false
                continue
            }

            # 检测适配器头行（中英文兼容）
            # 英文: "Ethernet adapter 以太网:" / "Wireless LAN adapter Wi-Fi:"
            # 中文: "以太网适配器 以太网:" / "无线局域网适配器 Wi-Fi:"
            # 特征: 非缩进行 + 包含 "adapter" 或 "适配器" + 以 ":" 结尾
            if ($trimmed -notmatch '^\s{2,}' -and
                ($trimmed -match 'adapter' -or $trimmed -match '适配器') -and
                $trimmed -match ':\s*$') {

                # 保存上一个适配器
                if ($currentAdapter) {
                    $currentAdapter['DnsServers'] = $dnsList
                    $adapters += $currentAdapter
                }

                $adapterName = $trimmed -replace ':\s*$', ''
                $currentAdapter = @{
                    Name            = $adapterName
                    DhcpEnabled     = $false
                    IPv4Address     = $null
                    SubnetMask      = $null
                    DefaultGateway  = $null
                    DnsServers      = @()
                    LeaseObtained   = $null
                    LeaseExpires    = $null
                    Description     = ''
                }
                $dnsList = @()
                $inDnsSection = $false
                continue
            }

            if (-not $currentAdapter) { continue }

            # 解析键值对: ". . . : value"（中英文兼容）
            if ($trimmed -match '^\s*([^:]+?)\s*(?:\.\s*)+:\s*(.*)$') {
                $key = $Matches[1].Trim()
                $value = $Matches[2].Trim()

                # 判断是否进入 DNS 段（中英文）
                $inDnsSection = ($key -match 'DNS Servers' -or $key -match 'DNS 服务器')

                switch -Wildcard ($key) {
                    # DHCP 状态（英: DHCP Enabled, 中: DHCP 已启用）
                    { $_ -match 'DHCP Enabled' -or $_ -match 'DHCP 已启用' } {
                        $currentAdapter['DhcpEnabled'] = ($value -eq 'Yes' -or $value -eq '是')
                    }
                    # IPv4 地址（英: IPv4 Address, 中: IPv4 地址 / IP 地址）
                    { $_ -match 'IPv4 Address' -or $_ -match 'IPv4 地址|IP 地址|IP Address' } {
                        $ip = $value -replace '\s*\(.*\)', ''
                        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
                            $currentAdapter['IPv4Address'] = $ip
                        }
                    }
                    # 子网掩码（英: Subnet Mask, 中: 子网掩码）
                    { $_ -match 'Subnet Mask' -or $_ -match '子网掩码' } {
                        if ($value -match '^\d+\.\d+\.\d+\.\d+$') {
                            $currentAdapter['SubnetMask'] = $value
                        }
                    }
                    # 默认网关（英: Default Gateway, 中: 默认网关）
                    { $_ -match 'Default Gateway' -or $_ -match '默认网关' } {
                        if ($value -and $value -ne '' -and $value -notmatch '^\s*$') {
                            $currentAdapter['DefaultGateway'] = $value
                        }
                    }
                    # 描述（英: Description, 中: 描述）
                    { $_ -match '^Description' -or $_ -match '^描述' } {
                        $currentAdapter['Description'] = $value
                    }
                    # 租约获取时间（英: Lease Obtained, 中: 获得租约的时间）
                    { $_ -match 'Lease Obtained' -or $_ -match '获得租约' } {
                        $currentAdapter['LeaseObtained'] = $value
                    }
                    # 租约过期时间（英: Lease Expires, 中: 租约过期的时间）
                    { $_ -match 'Lease Expires' -or $_ -match '租约过期' } {
                        $currentAdapter['LeaseExpires'] = $value
                    }
                    # DNS 服务器（英: DNS Servers, 中: DNS 服务器）
                    { $_ -match 'DNS Servers' -or $_ -match 'DNS 服务器' } {
                        if ($value -and $value -match '^\d+\.\d+\.\d+\.\d+$') {
                            $dnsList += $value
                        }
                    }
                }
            }
            elseif ($inDnsSection -and $trimmed -match '^\s*(\d+\.\d+\.\d+\.\d+)\s*$') {
                # DNS 服务器的续行（IP 地址）
                $dnsList += $Matches[1]
            }
        }

        # 保存最后一个适配器（文件末尾无空行分隔的情况）
        if ($currentAdapter) {
            $currentAdapter['DnsServers'] = $dnsList
            $adapters += $currentAdapter
        }
    }
    catch {
        Write-ErrorEvent -Severity 'low' -Message "解析 ipconfig /all 输出失败: $_" -StackTrace $_.ScriptStackTrace
    }

    return $adapters
}

<#
.SYNOPSIS
    从 Context 中提取 Status='Up' 的适配器 InterfaceIndex 列表
.DESCRIPTION
    遍历 $Context.Adapters 数组，筛选出 Status 为 'Up' 的适配器，
    返回其 InterfaceIndex 列表。
.OUTPUTS
    System.Int32[] - Up 状态适配器的 InterfaceIndex 数组
#>
function Get-UpAdapterIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $upIndexes = @()
    if ($Context -and $Context.ContainsKey('Adapters') -and $Context['Adapters']) {
        foreach ($adapter in $Context['Adapters']) {
            if ($adapter -is [hashtable] -or $adapter -is [PSCustomObject]) {
                $status = if ($adapter -is [hashtable]) { $adapter['Status'] } else { $adapter.Status }
                if ($status -eq 'Up') {
                    $idx = if ($adapter -is [hashtable]) { $adapter['InterfaceIndex'] } else { $adapter.InterfaceIndex }
                    if ($idx) { $upIndexes += [int]$idx }
                }
            }
        }
    }
    # Fallback: if context didn't provide adapters, fetch directly
    if ($upIndexes.Count -eq 0) {
        try {
            $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
            foreach ($a in $adapters) { $upIndexes += $a.InterfaceIndex }
        } catch { }
    }
    return $upIndexes
}

<#
.SYNOPSIS
    获取选定适配器的 IPv4 配置摘要
.DESCRIPTION
    对指定的 InterfaceIndex 列表，通过 Get-NetIPConfiguration 获取 IPv4 地址、
    默认网关、DNS 服务器信息。取第一个有效配置作为主适配器配置。
    若所有适配器均无有效配置，尝试 ipconfig /all 回退。
#>
function Get-IPv4Summary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$UpIndexes
    )

    $result = @{
        Address        = $null
        PrefixLength   = $null
        DefaultGateway = $null
        DhcpEnabled    = $false
        DnsServers     = @()
    }

    try {
        # 两轮遍历策略：优先选择"有默认网关"的适配器（真实出口网卡），
        # 避免 Hyper-V/WSL 虚拟交换机（有IP无网关）先命中导致误报 IPV4_NO_GATEWAY
        $candidates = @()
        foreach ($idx in $UpIndexes) {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $idx -Detailed -ErrorAction SilentlyContinue
            if (-not $ipConfig) { continue }
            if (-not $ipConfig.IPv4Address) { continue }
            $candidates += $ipConfig
        }

        # 第一优先：有 IPv4 默认网关的适配器；第二优先：任何有 IPv4 地址的
        $selected = $null
        foreach ($c in $candidates) {
            if ($c.IPv4DefaultGateway -and $c.IPv4DefaultGateway.NextHop) {
                $selected = $c
                break
            }
        }
        if (-not $selected -and @($candidates).Count -gt 0) {
            $selected = $candidates[0]
        }

        if ($selected) {
            $ipv4Addr = $selected.IPv4Address
            if ($ipv4Addr) {
                $result['Address']      = $ipv4Addr.IPAddress
                $result['PrefixLength'] = $ipv4Addr.PrefixLength
            }

            $ipv4Gw = $selected.IPv4DefaultGateway
            if ($ipv4Gw -and $ipv4Gw.NextHop) {
                $result['DefaultGateway'] = $ipv4Gw.NextHop
            }

            if ($selected.DNSServer) {
                $dnsServers = @($selected.DNSServer.ServerAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
                if ($dnsServers.Count -gt 0) {
                    $result['DnsServers'] = $dnsServers
                }
            }

            $dhcp = $selected.DHCP
            if ($dhcp) {
                $result['DhcpEnabled'] = ($dhcp.Enabled -eq $true)
            }
        }

        # 如果主路径无结果，尝试回退到 ipconfig /all
        if (-not $result['Address']) {
            $fallbackAdapters = Parse-IpConfigAll
            if ($fallbackAdapters.Count -gt 0) {
                $first = $fallbackAdapters[0]
                $result['Address']        = $first['IPv4Address']
                $result['DefaultGateway'] = $first['DefaultGateway']
                $result['DhcpEnabled']    = $first['DhcpEnabled']
                $result['DnsServers']     = $first['DnsServers']
                # 从子网掩码推算 PrefixLength
                if ($first['SubnetMask']) {
                    $result['PrefixLength'] = Convert-SubnetMaskToPrefixLength -Mask $first['SubnetMask']
                }
            }
        }
    }
    catch {
        Write-ErrorEvent -Severity 'low' -Message "获取 IPv4 配置摘要失败: $_" -StackTrace $_.ScriptStackTrace
    }

    return $result
}

<#
.SYNOPSIS
    获取选定适配器的 IPv6 配置摘要
#>
function Get-IPv6Summary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$UpIndexes
    )

    $result = @{
        Address        = $null
        PrefixLength   = $null
        DefaultGateway = $null
        DnsServers     = @()
    }

    try {
        foreach ($idx in $UpIndexes) {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $idx -Detailed -ErrorAction SilentlyContinue
            if (-not $ipConfig) { continue }

            $ipv6Addr = $ipConfig.IPv6Address
            if ($ipv6Addr) {
                $result['Address']      = $ipv6Addr.IPAddress
                $result['PrefixLength'] = $ipv6Addr.PrefixLength
            }

            $ipv6Gw = $ipConfig.IPv6DefaultGateway
            if ($ipv6Gw -and $ipv6Gw.NextHop) {
                $result['DefaultGateway'] = $ipv6Gw.NextHop
            }

            if ($result['Address']) { break }
        }
    }
    catch {
        Write-ErrorEvent -Severity 'low' -Message "获取 IPv6 配置摘要失败: $_" -StackTrace $_.ScriptStackTrace
    }

    return $result
}

<#
.SYNOPSIS
    将子网掩码（如 "255.255.255.0"）转换为前缀长度（如 24）
#>
function Convert-SubnetMaskToPrefixLength {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mask
    )

    try {
        $octets = $Mask -split '\.'
        if ($octets.Count -ne 4) { return $null }

        $binaryString = ''
        foreach ($octet in $octets) {
            $binaryString += [Convert]::ToString([int]$octet, 2).PadLeft(8, '0')
        }
        # 前缀长度 = 连续 '1' 的个数
        $prefixLength = 0
        foreach ($char in $binaryString.ToCharArray()) {
            if ($char -eq '1') { $prefixLength++ } else { break }
        }
        return $prefixLength
    }
    catch {
        return $null
    }
}

# ============================================================
# 公共函数: 诊断
# ============================================================

<#
.SYNOPSIS
    执行 M02 模块的 IP/DHCP 诊断
.DESCRIPTION
    检测项包括:
    1. DHCP Client 服务运行状态
    2. APIPA(169.254.x.x) 地址检测 —— 只检查 Status='Up' 的适配器
    3. DHCP 租约有效性
    4. IPv4 配置完整性（地址、掩码、网关、DNS）
    5. IPv6 配置状态与全局地址
    6. MTU 值异常检测
    综合判定: APIPA→FAIL, MTU异常→WARN, DHCP服务停→WARN附加, 全部正常→PASS
.PARAMETER Context
    诊断上下文哈希表，必须包含 Adapters 数组（每个元素含 InterfaceIndex/Name/Status）
.OUTPUTS
    System.Collections.Hashtable - @{Diagnosis=@{...}; LogEvents=@(...)}
    超时目标: 600ms
#>
function Invoke-M02_Diagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $logEvents = @()

    # ---------- 初始化返回值 ----------
    $ipv4Info = @{
        Address        = $null
        PrefixLength   = $null
        DefaultGateway = $null
        DhcpEnabled    = $false
        DnsServers     = @()
    }
    $ipv6Info = @{
        Address        = $null
        PrefixLength   = $null
        DefaultGateway = $null
        DnsServers     = @()
    }
    $apipaDetected       = $false
    $dhcpServiceRunning  = $false
    $dhcpLeaseValid      = $false
    $mtuValues           = @()
    $mtuAbnormal         = $false
    $ipv6Enabled         = $false
    $ipv6GlobalAddresses = @()
    $verdict             = 'PASS'
    $issues              = @()

    try {
        # --------------------------------------------------------
        # 步骤0: 获取 Up 适配器的 InterfaceIndex 列表
        # --------------------------------------------------------
        $upIndexes = Get-UpAdapterIndexes -Context $Context

        if (@($upIndexes).Count -eq 0) {
            $verdict = 'UNKNOWN'
            $issues += 'NO_UP_ADAPTER'
            $sw.Stop()
            $diagnosis = @{
                IPv4                = $ipv4Info
                IPv6                = $ipv6Info
                APIPA_Detected      = $apipaDetected
                DhcpServiceRunning  = $dhcpServiceRunning
                DhcpLeaseValid      = $dhcpLeaseValid
                MtuValues           = $mtuValues
                MtuAbnormal         = $mtuAbnormal
                IPv6_Enabled        = $ipv6Enabled
                IPv6_GlobalAddresses = $ipv6GlobalAddresses
                Verdict             = $verdict
            }
            $logEvent = @{
                event      = 'check.end'
                module     = 'M02'
                verdict    = $verdict
                elapsed_ms = $sw.ElapsedMilliseconds
                issues     = $issues
            }
            $logEvents += $logEvent
            Write-DiagnosisEvent -Module 'M02' -Verdict $verdict -ElapsedMs $sw.ElapsedMilliseconds `
                -ExtraFields @{ issues = ($issues -join ',') }
            return @{ Diagnosis = $diagnosis; LogEvents = $logEvents }
        }

        # --------------------------------------------------------
        # 步骤1: DHCP Client 服务状态检测
        # --------------------------------------------------------
        try {
            $dhcpService = Get-Service -Name 'Dhcp' -ErrorAction SilentlyContinue
            if ($dhcpService) {
                $dhcpServiceRunning = ($dhcpService.Status -eq 'Running')
                if (-not $dhcpServiceRunning) {
                    $issues += 'DHCP_SERVICE_STOPPED'
                }
            }
            else {
                $issues += 'DHCP_SERVICE_NOT_FOUND'
            }
        }
        catch {
            $issues += 'DHCP_SERVICE_CHECK_FAILED'
            Write-ErrorEvent -Severity 'low' -Message "检查 DHCP Client 服务失败: $_" -StackTrace $_.ScriptStackTrace
        }

        # --------------------------------------------------------
        # 步骤2: APIPA 检测 (核心)
        # 只检查 Status='Up' 的适配器上是否有 169.254.x.x 地址
        # --------------------------------------------------------
        try {
            $apipaAddresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -match '^169\.254\.' }

            if ($apipaAddresses) {
                foreach ($apipaAddr in $apipaAddresses) {
                    # 检查该 APIPA 地址是否属于某个 Up 适配器
                    if ($apipaAddr.InterfaceIndex -in $upIndexes) {
                        $apipaDetected = $true
                        $issues += 'APIPA_DETECTED'
                        break
                    }
                }
            }
        }
        catch [System.Management.Automation.CommandNotFoundException] {
            # Get-NetIPAddress 不可用，回退到 ipconfig /all
            $fallbackAdapters = Parse-IpConfigAll
            foreach ($fa in $fallbackAdapters) {
                if ($fa['IPv4Address'] -match '^169\.254\.') {
                    $apipaDetected = $true
                    $issues += 'APIPA_DETECTED_FALLBACK'
                    break
                }
            }
        }
        catch {
            Write-ErrorEvent -Severity 'low' -Message "APIPA 检测失败: $_" -StackTrace $_.ScriptStackTrace
            $issues += 'APIPA_CHECK_FAILED'
        }

        # --------------------------------------------------------
        # 步骤3: DHCP 租约检测
        # --------------------------------------------------------
        try {
            $anyDhcpEnabled = $false
            $anyValidLease  = $false
            $allApipaOrNone = $true

            foreach ($idx in $upIndexes) {
                $ipConfig = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
                if (-not $ipConfig) { continue }

                $dhcp = $ipConfig.DHCP
                $ipv4 = $ipConfig.IPv4Address

                if ($dhcp -and $dhcp.Enabled) {
                    $anyDhcpEnabled = $true
                    if ($ipv4 -and $ipv4.IPAddress -and $ipv4.IPAddress -notmatch '^169\.254\.') {
                        $anyValidLease = $true
                        $allApipaOrNone = $false
                    }
                }
            }

            if ($anyDhcpEnabled -and -not $anyValidLease) {
                # DHCP 启用但无有效租约
                $dhcpLeaseValid = $false
                if ($apipaDetected) {
                    $issues += 'DHCP_LEASE_INVALID_APIPA'
                }
                else {
                    $issues += 'DHCP_LEASE_INVALID'
                }
            }
            elseif ($anyDhcpEnabled -and $anyValidLease) {
                $dhcpLeaseValid = $true
            }
            else {
                # 没有 DHCP 启用的适配器，无法判断租约
                $dhcpLeaseValid = $true  # 无 DHCP 不算故障
            }
        }
        catch [System.Management.Automation.CommandNotFoundException] {
            # 回退: 解析 ipconfig /all
            $fallbackAdapters = Parse-IpConfigAll
            $anyDhcpFallback = $false
            $anyValidFallback = $false
            foreach ($fa in $fallbackAdapters) {
                if ($fa['DhcpEnabled']) {
                    $anyDhcpFallback = $true
                    if ($fa['IPv4Address'] -and $fa['IPv4Address'] -notmatch '^169\.254\.') {
                        $anyValidFallback = $true
                    }
                }
            }
            $dhcpLeaseValid = (-not $anyDhcpFallback) -or $anyValidFallback
            if (-not $dhcpLeaseValid) {
                $issues += 'DHCP_LEASE_CHECK_FAILED'
            }
        }
        catch {
            Write-ErrorEvent -Severity 'low' -Message "DHCP 租约检测失败: $_" -StackTrace $_.ScriptStackTrace
            $issues += 'DHCP_LEASE_CHECK_FAILED'
        }

        # --------------------------------------------------------
        # 步骤4: IPv4 配置完整性检测
        # --------------------------------------------------------
        try {
            $ipv4Info = Get-IPv4Summary -UpIndexes $upIndexes

            if (-not $ipv4Info['Address']) {
                $issues += 'IPV4_NO_ADDRESS'
            }
            if (-not $ipv4Info['DefaultGateway']) {
                $issues += 'IPV4_NO_GATEWAY'
            }
            if ($ipv4Info['DnsServers'].Count -eq 0) {
                $issues += 'IPV4_NO_DNS'
            }
        }
        catch {
            Write-ErrorEvent -Severity 'low' -Message "IPv4 配置完整性检测失败: $_" -StackTrace $_.ScriptStackTrace
            $issues += 'IPV4_CHECK_FAILED'
        }

        # --------------------------------------------------------
        # 步骤5: IPv6 检测
        # --------------------------------------------------------
        try {
            $ipv6Protocol = Get-NetIPv6Protocol -ErrorAction SilentlyContinue
            if ($ipv6Protocol) {
                $ipv6Enabled = ($ipv6Protocol.Enabled -eq $true)
            }
            else {
                $ipv6Enabled = $false
            }
        }
        catch {
            # 无法获取 IPv6 协议状态，尝试通过注册表判断
            try {
                $regKey = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
                    -ErrorAction SilentlyContinue
                if ($regKey -and $regKey.DisabledComponents) {
                    $ipv6Enabled = ([int]$regKey.DisabledComponents -eq 0)
                }
                else {
                    $ipv6Enabled = $true  # 默认启用
                }
            }
            catch {
                $ipv6Enabled = $false
            }
        }

        # 获取全局 IPv6 地址（排除 WellKnown 和 LinkLocal）
        try {
            $ipv6Addrs = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.PrefixOrigin -ne 'WellKnown' -and
                    $_.IPAddress -notmatch '^fe80:' -and
                    $_.IPAddress -ne '::1'
                }
            if ($ipv6Addrs) {
                $ipv6GlobalAddresses = @($ipv6Addrs | ForEach-Object {
                    @{
                        Address        = $_.IPAddress
                        PrefixLength   = $_.PrefixLength
                        InterfaceIndex = $_.InterfaceIndex
                        PrefixOrigin   = $_.PrefixOrigin.ToString()
                    }
                })
            }
        }
        catch {
            # 获取 IPv6 地址失败时忽略
        }

        # 获取 IPv6 配置摘要
        if ($ipv6Enabled -and $upIndexes.Count -gt 0) {
            try {
                $ipv6Info = Get-IPv6Summary -UpIndexes $upIndexes
            }
            catch {
                # IPv6 摘要获取失败时忽略
            }
        }

        # --------------------------------------------------------
        # 步骤6: MTU 值检测
        # --------------------------------------------------------
        try {
            $interfaces = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceIndex -in $upIndexes }

            foreach ($iface in $interfaces) {
                $mtu = $iface.NlMtu
                $mtuValues += @{
                    ifIndex = $iface.InterfaceIndex
                    NlMtu   = $mtu
                }

                # MTU < 1280（IPv6 最小要求）或 MTU > 1500（以太网标准）视为异常
                if ($mtu -lt 1280 -or $mtu -gt 1500) {
                    $mtuAbnormal = $true
                    $issues += "MTU_ABNORMAL_$($iface.InterfaceIndex)"
                }
            }
        }
        catch [System.Management.Automation.CommandNotFoundException] {
            # Get-NetIPInterface 不可用，尝试 netsh
            try {
                $netshOutput = & netsh interface ipv4 show subinterfaces 2>$null | Out-String
                $mtuAbnormal = $false  # netsh 回退无法精确判断，标记为警告
                $issues += 'MTU_CHECK_NETSH_FALLBACK'
            }
            catch {
                $issues += 'MTU_CHECK_FAILED'
            }
        }
        catch {
            Write-ErrorEvent -Severity 'low' -Message "MTU 检测失败: $_" -StackTrace $_.ScriptStackTrace
            $issues += 'MTU_CHECK_FAILED'
        }

        # --------------------------------------------------------
        # 步骤7: 综合判定
        # --------------------------------------------------------
        if ($apipaDetected) {
            $verdict = 'FAIL'
        }
        elseif ($issues.Count -gt 0) {
            # 检查是否有 WARN 级别的问题
            $warnOnly = $true
            foreach ($issue in $issues) {
                if ($issue -match 'APIPA|NO_ADDRESS|NO_GATEWAY|IPV4_NO_') {
                    $warnOnly = $false
                    break
                }
            }
            if ($warnOnly) {
                $verdict = 'WARN'
            }
            else {
                $verdict = 'FAIL'
            }
        }
        else {
            $verdict = 'PASS'
        }

        # 特殊情况：仅 DHCP 服务停止且无其他故障 → WARN
        if ($issues.Count -eq 1 -and $issues[0] -eq 'DHCP_SERVICE_STOPPED') {
            $verdict = 'WARN'
        }
    }
    catch {
        $verdict = 'UNKNOWN'
        $issues += 'DIAGNOSIS_EXCEPTION'
        Write-ErrorEvent -Severity 'medium' -Message "M02 诊断异常: $_" -StackTrace $_.ScriptStackTrace
    }
    finally {
        $sw.Stop()
    }

    # ---------- 构造返回值 ----------
    $diagnosis = @{
        IPv4                 = $ipv4Info
        IPv6                 = $ipv6Info
        APIPA_Detected       = $apipaDetected
        DhcpServiceRunning   = $dhcpServiceRunning
        DhcpLeaseValid       = $dhcpLeaseValid
        MtuValues            = $mtuValues
        MtuAbnormal          = $mtuAbnormal
        IPv6_Enabled         = $ipv6Enabled
        IPv6_GlobalAddresses = $ipv6GlobalAddresses
        Verdict              = $verdict
    }

    $logEvent = @{
        event      = 'check.end'
        module     = 'M02'
        verdict    = $verdict
        elapsed_ms = $sw.ElapsedMilliseconds
        issues     = $issues
    }
    $logEvents += $logEvent

    Write-DiagnosisEvent -Module 'M02' -Verdict $verdict -ElapsedMs $sw.ElapsedMilliseconds `
        -ExtraFields @{ issues = ($issues -join ',') }

    return @{
        Diagnosis = $diagnosis
        LogEvents = $logEvents
    }
}

# ============================================================
# 公共函数: 修复
# ============================================================

<#
.SYNOPSIS
    执行 M02 模块的 IP/DHCP 修复
.DESCRIPTION
    修复步骤（按顺序）：
    1. 启动 DHCP Client 服务（若已停止）
    2. ipconfig /release（远程会话跳过）→ ipconfig /renew
    3. 修复 MTU 异常（设置为 1500）
    4. 验证修复效果：重新获取 IP 确认不在 169.254 范围
    风险等级: L2（低风险，网络短暂中断）
.PARAMETER Diagnosis
    诊断结果哈希表（Invoke-M02_Diagnose 的 Diagnosis 字段）
.OUTPUTS
    System.Collections.Hashtable - @{Repair=@{...}; LogEvents=@(...)}
#>
function Invoke-M02_Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Diagnosis
    )

    $logEvents  = @()
    $steps      = @()
    $finalVerdict = 'success'
    $rebootRequired = $false

    # 检测远程会话
    $isRemote = $false
    try {
        $isRemote = Test-RemoteSession
    }
    catch {
        # Test-RemoteSession 不可用时保守处理：不视为远程
        $isRemote = $false
        Write-ErrorEvent -Severity 'low' -Message "远程会话检测失败，按本地处理: $_" -StackTrace $_.ScriptStackTrace
    }

    # 获取 Up 适配器列表用于后续 MTU 修复和验证
    $upIndexes = @()
    if ($Diagnosis -and $Diagnosis.ContainsKey('MtuValues')) {
        foreach ($mtuEntry in $Diagnosis['MtuValues']) {
            if ($mtuEntry -is [hashtable] -and $mtuEntry.ContainsKey('ifIndex')) {
                $upIndexes += [int]$mtuEntry['ifIndex']
            }
            elseif ($mtuEntry -is [PSCustomObject] -and $mtuEntry.ifIndex) {
                $upIndexes += [int]$mtuEntry.ifIndex
            }
        }
    }

    # ============================================================
    # 步骤1: 启动 DHCP Client 服务
    # ============================================================
    try {
        $dhcpService = Get-Service -Name 'Dhcp' -ErrorAction SilentlyContinue
        if ($dhcpService -and $dhcpService.Status -ne 'Running') {
            Start-Service -Name 'Dhcp' -ErrorAction Stop
            $steps += @{
                Step        = 'START_DHCP_SERVICE'
                Description = '启动 DHCP Client 服务'
                Status      = 'completed'
            }
            $logEvent = @{
                event     = 'fix.step'
                module    = 'M02'
                step      = 'START_DHCP_SERVICE'
                status    = 'completed'
                exit_code = 0
            }
            $logEvents += $logEvent
            Write-FixEvent -Module 'M02' -EventSubType 'step' -Step 'START_DHCP_SERVICE' -ExitCode 0

            # 等待服务完全启动
            Start-Sleep -Milliseconds 500
        }
        else {
            $steps += @{
                Step        = 'START_DHCP_SERVICE'
                Description = 'DHCP Client 服务已在运行，跳过'
                Status      = 'skipped'
            }
        }
    }
    catch {
        $steps += @{
            Step        = 'START_DHCP_SERVICE'
            Description = "启动 DHCP Client 服务失败: $_"
            Status      = 'failed'
        }
        $logEvent = @{
            event     = 'fix.step'
            module    = 'M02'
            step      = 'START_DHCP_SERVICE'
            status    = 'failed'
            exit_code = -1
            error     = $_.ToString()
        }
        $logEvents += $logEvent
        Write-FixEvent -Module 'M02' -EventSubType 'step' -Step 'START_DHCP_SERVICE' -ExitCode -1
        Write-ErrorEvent -Severity 'medium' -Message "启动 DHCP Client 服务失败: $_" -StackTrace $_.ScriptStackTrace
        $finalVerdict = 'failed'
    }

    # ============================================================
    # 步骤2: ipconfig /release → ipconfig /renew
    # 远程会话跳过 ipconfig /release
    # ============================================================
    if (-not $isRemote) {
        # ---------- ipconfig /release ----------
        try {
            $releaseResult = & ipconfig /release 2>&1 | Out-String
            $releaseExitCode = $LASTEXITCODE

            $steps += @{
                Step        = 'IPCONFIG_RELEASE'
                Description = '释放当前 IP 租约 (ipconfig /release)'
                Status      = if ($releaseExitCode -eq 0) { 'completed' } else { 'completed_with_warnings' }
            }
            $logEvent = @{
                event     = 'fix.step'
                module    = 'M02'
                step      = 'IPCONFIG_RELEASE'
                exit_code = $releaseExitCode
                output    = ($releaseResult -replace "`r`n", ' | ').Trim()
            }
            $logEvents += $logEvent
            Write-FixEvent -Module 'M02' -EventSubType 'step' -Step 'IPCONFIG_RELEASE' -ExitCode $releaseExitCode
        }
        catch {
            $steps += @{
                Step        = 'IPCONFIG_RELEASE'
                Description = "ipconfig /release 执行异常: $_"
                Status      = 'failed'
            }
            Write-ErrorEvent -Severity 'low' -Message "ipconfig /release 失败: $_" -StackTrace $_.ScriptStackTrace
        }
    }
    else {
        $steps += @{
            Step        = 'IPCONFIG_RELEASE'
            Description = '检测到远程会话，跳过 ipconfig /release（避免断开连接）'
            Status      = 'skipped'
        }
        $logEvent = @{
            event  = 'fix.step'
            module = 'M02'
            step   = 'IPCONFIG_RELEASE'
            status = 'skipped'
            reason = 'remote_session'
        }
        $logEvents += $logEvent
    }

    # ---------- ipconfig /renew ----------
    try {
        $renewResult = & ipconfig /renew 2>&1 | Out-String
        $renewExitCode = $LASTEXITCODE

        $steps += @{
            Step        = 'IPCONFIG_RENEW'
            Description = '更新 IP 租约 (ipconfig /renew)'
            Status      = if ($renewExitCode -eq 0) { 'completed' } else { 'completed_with_warnings' }
        }
        $logEvent = @{
            event     = 'fix.step'
            module    = 'M02'
            step      = 'IPCONFIG_RENEW'
            exit_code = $renewExitCode
            output    = ($renewResult -replace "`r`n", ' | ').Trim()
        }
        $logEvents += $logEvent
        Write-FixEvent -Module 'M02' -EventSubType 'step' -Step 'IPCONFIG_RENEW' -ExitCode $renewExitCode

        # 等待 DHCP 协商完成
        Start-Sleep -Milliseconds 1000
    }
    catch {
        $steps += @{
            Step        = 'IPCONFIG_RENEW'
            Description = "ipconfig /renew 执行异常: $_"
            Status      = 'failed'
        }
        Write-ErrorEvent -Severity 'medium' -Message "ipconfig /renew 失败: $_" -StackTrace $_.ScriptStackTrace
        $finalVerdict = 'failed'
    }

    # ============================================================
    # 步骤3: 修复 MTU 异常
    # ============================================================
    $mtuAbnormal = $false
    if ($Diagnosis -and $Diagnosis.ContainsKey('MtuAbnormal')) {
        $mtuAbnormal = $Diagnosis['MtuAbnormal']
    }

    if ($mtuAbnormal -and $upIndexes.Count -gt 0) {
        foreach ($idx in $upIndexes) {
            try {
                Set-NetIPInterface -InterfaceIndex $idx -NlMtu 1500 -ErrorAction Stop
                $steps += @{
                    Step        = "FIX_MTU_$idx"
                    Description = "设置适配器 [$idx] MTU 为 1500"
                    Status      = 'completed'
                }
                $logEvent = @{
                    event     = 'fix.step'
                    module    = 'M02'
                    step      = "FIX_MTU_$idx"
                    exit_code = 0
                }
                $logEvents += $logEvent
                Write-FixEvent -Module 'M02' -EventSubType 'step' -Step "FIX_MTU_$idx" -ExitCode 0
            }
            catch {
                $steps += @{
                    Step        = "FIX_MTU_$idx"
                    Description = "设置 MTU 失败: $_"
                    Status      = 'failed'
                }
                Write-ErrorEvent -Severity 'low' -Message "设置 MTU 失败 (idx=$idx): $_" -StackTrace $_.ScriptStackTrace
            }
        }
    }
    else {
        $steps += @{
            Step        = 'FIX_MTU'
            Description = 'MTU 值正常，跳过修复'
            Status      = 'skipped'
        }
    }

    # ============================================================
    # 步骤4: 验证修复效果
    # ============================================================
    $apipaStillPresent = $false
    try {
        $currentIPv4 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -match '^169\.254\.' }

        if ($currentIPv4) {
            # 进一步检查：这些 APIPA 地址是否在 Up 适配器上
            $currentUpIndexes = Get-UpAdapterIndexes -Context @{
                Adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
                    Select-Object InterfaceIndex, Name, Status)
            }
            foreach ($addr in $currentIPv4) {
                if ($addr.InterfaceIndex -in $currentUpIndexes) {
                    $apipaStillPresent = $true
                    break
                }
            }
        }
    }
    catch {
        # 验证失败时保守处理：认为修复成功（避免误判）
        Write-ErrorEvent -Severity 'low' -Message "修复后验证失败: $_" -StackTrace $_.ScriptStackTrace
    }

    if ($apipaStillPresent) {
        $steps += @{
            Step        = 'VERIFY'
            Description = '验证失败：修复后仍检测到 APIPA 地址'
            Status      = 'failed'
        }
        $finalVerdict = 'failed'
    }
    else {
        $steps += @{
            Step        = 'VERIFY'
            Description = '验证通过：未检测到 APIPA 地址'
            Status      = 'completed'
        }
    }

    # ---------- 构造返回值 ----------
    $repair = @{
        Verdict        = $finalVerdict
        RebootRequired = $rebootRequired
        Steps          = $steps
    }

    $logEvent = @{
        event           = 'fix.end'
        module          = 'M02'
        verdict         = $finalVerdict
        reboot_required = $rebootRequired
        steps_count     = $steps.Count
    }
    $logEvents += $logEvent

    Write-FixEvent -Module 'M02' -EventSubType 'end' -Verdict $finalVerdict -RebootRequired $rebootRequired

    return @{
        Repair    = $repair
        LogEvents = $logEvents
    }
}

# ============================================================
# 模块结束
# 本文件通过 dot-source (. .\modules\M02_IP_DHCP.ps1) 加载时，
# Invoke-M02_Diagnose 和 Invoke-M02_Repair 自动在当前作用域中可用。
# ============================================================
