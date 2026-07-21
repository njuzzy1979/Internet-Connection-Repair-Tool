<#
.SYNOPSIS
    M03 DNS 解析诊断与修复模块
.DESCRIPTION
    DNS 域名解析功能检测与自动修复。
    检测项：IPv4/IPv6 域名解析、Ping 辅助验证、DNS 服务器可达性、DNS Client 服务状态。
    修复项：DNS 缓存刷新、服务重启、DNS 服务器重置、可选公共 DNS 设置。
.NOTES
    文件名: M03_DNS.ps1
    依赖: 零第三方依赖，lib 函数（Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent）
    兼容: Windows PowerShell 5.1
    API约束: PS 5.1 的 Resolve-DnsName 不支持 -DnsOnly 和 -QuickTimeout，
             使用 Start-Job + Wait-Job -Timeout 实现超时控制
#>

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# ============================================================
# 模块级常量
# ============================================================

# IPv4 测试域名列表
$Script:M03_IPv4_Domains = @(
    'www.baidu.com',
    'cloudflare-dns.com',
    'dns.google',
    'www.apple.com',
    'dns.msftncsi.com'
)

# IPv6 测试域名列表（仅当 IPv6 启用时测试）
$Script:M03_IPv6_Domains = @(
    'ipv6.baidu.com',
    'ipv6.google.com'
)

# Ping 测试目标 IP
$Script:M03_PingTargets = @('223.5.5.5', '8.8.8.8', '114.114.114.114')

# 单个 DNS 解析 Job 超时（秒）
$Script:M03_DnsJobTimeoutSec = 1

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    安全调用 lib 日志函数（兼容 Job 内执行场景）
.DESCRIPTION
    在 dot-source 直接调用时，Write-* 函数可用，直接写入日志。
    在 Start-Job 子进程中执行时，这些函数不可用，静默跳过（日志事件通过返回值收集）。
#>
function Invoke-SafeLog {
    param(
        [string]$FunctionName,
        [hashtable]$Arguments
    )

    try {
        if (Get-Command -Name $FunctionName -ErrorAction SilentlyContinue) {
            & $FunctionName @Arguments
        }
    }
    catch {
        # Job 子进程中函数不可用时静默跳过，不影响诊断流程
    }
}

<#
.SYNOPSIS
    使用 Start-Job + Wait-Job 超时控制执行单个域名的 DNS 解析
.DESCRIPTION
    先用 [System.Net.Dns]::GetHostEntry（纯 .NET，更快），失败后回退到 Resolve-DnsName。
    通过 Start-Job 隔离执行，Wait-Job -Timeout 控制最大等待时间，防止卡死。
.PARAMETER Domain
    要解析的域名
.PARAMETER RecordType
    DNS 记录类型：'A' (IPv4) 或 'AAAA' (IPv6)
.OUTPUTS
    Hashtable: @{Success=$true/$false; IPs=@(...); Method='DotNet'|'PS5'; Error=$null|'...'}
#>
function Resolve-DnsWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter(Mandatory = $false)]
        [ValidateSet('A', 'AAAA')]
        [string]$RecordType = 'A'
    )

    # 记录开始时间
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $job = Start-Job -ArgumentList $Domain, $RecordType -ScriptBlock {
            param($d, $type)

            # 方法1: 纯 .NET DNS 解析（不依赖 PowerShell cmdlet，通常更快）
            try {
                $result = [System.Net.Dns]::GetHostEntry($d)
                $ips = @($result.AddressList | ForEach-Object { $_.IPAddressToString })
                if ($ips.Count -gt 0) {
                    return @{Success = $true; IPs = $ips; Method = 'DotNet' }
                }
                throw 'No IP addresses returned'
            }
            catch {
                # 方法2: 回退到 Resolve-DnsName（PS 5.1 原生 cmdlet，不支持 -DnsOnly / -QuickTimeout）
                try {
                    $r = Resolve-DnsName -Name $d -Type $type -ErrorAction Stop
                    if ($r) {
                        $ipList = @($r | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress } | Select-Object -Unique)
                        if ($ipList.Count -gt 0) {
                            return @{Success = $true; IPs = $ipList; Method = 'PS5' }
                        }
                    }
                    throw 'No IP addresses resolved'
                }
                catch {
                    return @{Success = $false; IPs = @(); Method = 'None'; Error = $_.Exception.Message }
                }
            }
        }

        # 等待 Job 完成，超时则强制终止
        $null = Wait-Job -Job $job -Timeout $Script:M03_DnsJobTimeoutSec

        if ($job.State -eq 'Completed') {
            $result = Receive-Job -Job $job
            if ($result -is [hashtable]) {
                $sw.Stop()
                $result['ResolutionTime_ms'] = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                return $result
            }
            else {
                $sw.Stop()
                return @{
                    Success          = $false
                    IPs              = @()
                    Method           = 'None'
                    Error            = "Job 返回类型无效: $($result.GetType().Name)"
                    ResolutionTime_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                }
            }
        }
        else {
            # 超时：强制终止 Job
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            $sw.Stop()
            return @{
                Success          = $false
                IPs              = @()
                Method           = 'None'
                Error            = "DNS 解析超时 (${Script:M03_DnsJobTimeoutSec}s)"
                ResolutionTime_ms = $Script:M03_DnsJobTimeoutSec * 1000
            }
        }
    }
    catch {
        $sw.Stop()
        return @{
            Success          = $false
            IPs              = @()
            Method           = 'None'
            Error            = "DNS 解析异常: $($_.Exception.Message)"
            ResolutionTime_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        }
    }
    finally {
        # 清理 Job 资源
        if ($job) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    综合判定 DNS 诊断结果
.DESCRIPTION
    根据 IPv4/IPv6 解析结果、Ping 结果、DNS 服务器可达性、服务状态，
    综合计算 OverallVerdict。
#>
function Get-DnsOverallVerdict {
    param(
        [array]$DnsTestsA,
        [array]$DnsTestsAAAA,
        [array]$PingTests,
        [array]$DnsServersReachable,
        [string]$DnsClientServiceStatus
    )

    $aSuccess   = @($DnsTestsA | Where-Object { $_.Resolved }).Count
    $aTotal     = $DnsTestsA.Count
    $aAllPass   = ($aSuccess -eq $aTotal)
    $aAllFail   = ($aSuccess -eq 0)

    $aaaaSuccess = 0
    $aaaaTotal   = $DnsTestsAAAA.Count
    if ($aaaaTotal -gt 0) {
        $aaaaSuccess = @($DnsTestsAAAA | Where-Object { $_.Resolved }).Count
    }

    $pingSuccess = @($PingTests | Where-Object { $_.Success }).Count
    $pingAllFail = ($pingSuccess -eq 0)

    $dnsReachable = @($DnsServersReachable | Where-Object { $_ }).Count
    $dnsAllUnreachable = (@($DnsServersReachable).Count -gt 0) -and ($dnsReachable -eq 0)

    $serviceOk = ($DnsClientServiceStatus -eq 'Running')

    # 判定逻辑
    if ($aAllPass) {
        if ($aaaaTotal -gt 0 -and $aaaaSuccess -eq 0) {
            # IPv4 全部正常但 IPv6 全部失败 → 降级（IPv6 可能未配置或不支持）
            return 'DEGRADED'
        }
        return 'PASS'
    }

    if ($aAllFail) {
        if ($pingAllFail) {
            # DNS 全部失败 + Ping 全部失败 → 网络不可达
            return 'FAIL'
        }
        # DNS 全部失败但 Ping 成功 → DNS 专用故障
        if (-not $serviceOk) {
            return 'FAIL'
        }
        if ($dnsAllUnreachable) {
            return 'FAIL'
        }
        return 'FAIL'
    }

    # 部分成功部分失败 → 降级
    return 'DEGRADED'
}

<#
.SYNOPSIS
    检测是否为 APIPA 地址（169.254.x.x）
#>
function Test-IsApipaAddress {
    param([string]$IPAddress)
    return $IPAddress -like '169.254.*'
}

# ============================================================
# 公共导出函数：Invoke-M03_Diagnose
# ============================================================

<#
.SYNOPSIS
    执行 M03 DNS 解析诊断
.DESCRIPTION
    检测 DNS 域名解析功能（IPv4 + IPv6）、Ping 辅助验证、
    DNS 服务器配置及可达性、DNS Client 服务状态。
    使用 Start-Job + Wait-Job 超时控制，兼容 PS 5.1。
.PARAMETER Context
    上下文哈希表，包含 M02 诊断数据：
    - DnsServers: DNS 服务器 IP 列表
    - IPv6_Enabled: 是否启用 IPv6（$true/$false）
.OUTPUTS
    Hashtable: @{Diagnosis=@{...}; LogEvents=@(...)}
#>
function Invoke-M03_Diagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Context = @{}
    )

    $logEvents = @()
    $moduleStartTime = Get-Date

    # ----------------------------------------------------------
    # 1. 从上下文提取信息
    # ----------------------------------------------------------
    $dnsServers  = @()
    $ipv6Enabled = $false

    if ($Context.ContainsKey('DnsServers') -and $Context['DnsServers'] -is [array]) {
        $dnsServers = $Context['DnsServers']
    }
    if ($Context.ContainsKey('IPv6_Enabled')) {
        $ipv6Enabled = [bool]$Context['IPv6_Enabled']
    }

    # ----------------------------------------------------------
    # 2. DNS 域名解析测试（主检测，Start-Job 超时控制）
    # ----------------------------------------------------------

    # --- IPv4 解析测试 ---
    $dnsTestsA = @()
    foreach ($domain in $Script:M03_IPv4_Domains) {
        $result = Resolve-DnsWithTimeout -Domain $domain -RecordType 'A'

        $testEntry = @{
            Target          = $domain
            Resolved        = $result.Success
            ResolutionTime_ms = $result.ResolutionTime_ms
            Method          = $result.Method
        }

        # 记录解析到的 IP（方便排查）
        if ($result.Success -and $result.IPs) {
            $testEntry['IPs'] = $result.IPs
        }
        if (-not $result.Success -and $result.Error) {
            $testEntry['Error'] = $result.Error
        }

        $dnsTestsA += $testEntry
    }

    # --- IPv6 解析测试（仅 IPv6 启用时） ---
    $dnsTestsAAAA = @()
    if ($ipv6Enabled) {
        foreach ($domain in $Script:M03_IPv6_Domains) {
            $result = Resolve-DnsWithTimeout -Domain $domain -RecordType 'AAAA'

            $testEntry = @{
                Target          = $domain
                Resolved        = $result.Success
                ResolutionTime_ms = $result.ResolutionTime_ms
            }

            if ($result.Success -and $result.IPs) {
                $testEntry['IPs'] = $result.IPs
            }
            if (-not $result.Success -and $result.Error) {
                $testEntry['Error'] = $result.Error
            }

            $dnsTestsAAAA += $testEntry
        }
    }

    # ----------------------------------------------------------
    # 3. Ping ICMP 辅助验证
    # ----------------------------------------------------------
    $pingTests = @()
    foreach ($target in $Script:M03_PingTargets) {
        $pingSuccess = $false
        try {
            $pingSuccess = Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction SilentlyContinue
        }
        catch {
            # ICMP 可能被防火墙阻止，Ping 失败不直接判定为 DNS 故障
        }

        $pingTests += @{
            Target  = $target
            Success = [bool]$pingSuccess
        }
    }

    # ----------------------------------------------------------
    # 4. DNS 服务器配置检测
    # ----------------------------------------------------------
    $collectedDnsServers = @()
    $dnsServersReachable = @()

    try {
        # 获取 IPv4 DNS 服务器地址
        $dnsClientConfig = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($dnsClientConfig) {
            foreach ($entry in $dnsClientConfig) {
                foreach ($addr in $entry.ServerAddresses) {
                    if ($addr -and $addr -ne '127.0.0.1') {
                        $collectedDnsServers += $addr
                    }
                }
            }
        }
    }
    catch {
        # Get-DnsClientServerAddress 可能不可用（极旧系统），忽略
    }

    # 如果上下文提供了 DNS 服务器列表，合并去重
    foreach ($srv in $dnsServers) {
        if ($srv -notin $collectedDnsServers) {
            $collectedDnsServers += $srv
        }
    }

    # 如果仍未获取到任何 DNS 服务器，尝试通过 ipconfig 解析
    if ($collectedDnsServers.Count -eq 0) {
        try {
            $ipconfigOutput = & ipconfig /all 2>$null | Out-String
            $dnsMatches = [regex]::Matches($ipconfigOutput, 'DNS\s*Servers[^\d]*(\d+\.\d+\.\d+\.\d+)')
            foreach ($match in $dnsMatches) {
                $addr = $match.Groups[1].Value
                if ($addr -notin $collectedDnsServers) {
                    $collectedDnsServers += $addr
                }
            }
        }
        catch { }
    }

    # 对每个 DNS 服务器做可达性测试
    foreach ($dnsIp in $collectedDnsServers) {
        $reachable = $false
        try {
            $reachable = Test-Connection -ComputerName $dnsIp -Count 1 -Quiet -ErrorAction SilentlyContinue
        }
        catch { }
        $dnsServersReachable += [bool]$reachable
    }

    # ----------------------------------------------------------
    # 5. DNS Client 服务状态检测
    # ----------------------------------------------------------
    $dnsServiceStatus = 'Unknown'
    try {
        $dnsService = Get-Service -Name 'Dnscache' -ErrorAction SilentlyContinue
        if ($dnsService) {
            $dnsServiceStatus = $dnsService.Status.ToString()
        }
        else {
            $dnsServiceStatus = 'NotFound'
        }
    }
    catch {
        $dnsServiceStatus = 'Error'
    }

    # ----------------------------------------------------------
    # 6. 综合判定
    # ----------------------------------------------------------
    $overallVerdict = Get-DnsOverallVerdict `
        -DnsTestsA $dnsTestsA `
        -DnsTestsAAAA $dnsTestsAAAA `
        -PingTests $pingTests `
        -DnsServersReachable $dnsServersReachable `
        -DnsClientServiceStatus $dnsServiceStatus

    # 检测 APIPA 地址 → 可能为 DHCP 根因
    $hasApipa = @($collectedDnsServers | Where-Object { Test-IsApipaAddress -IPAddress $_ }).Count -gt 0

    # ----------------------------------------------------------
    # 7. 构建诊断结果
    # ----------------------------------------------------------
    $diagnosis = @{
        DnsTests_A           = $dnsTestsA
        DnsTests_AAAA        = $dnsTestsAAAA
        PingTests            = $pingTests
        DnsServers           = $collectedDnsServers
        DnsServersReachable  = $dnsServersReachable
        DnsServiceStatus     = $dnsServiceStatus
        IPv6_Enabled         = $ipv6Enabled
        OverallVerdict       = $overallVerdict
        Verdict              = $overallVerdict
    }

    # 附加标记：APIPA / DHCP 根因
    if ($hasApipa) {
        $diagnosis['APIPA_Detected'] = $true
        $diagnosis['RootCauseHint'] = 'DHCP_ROOT_CAUSE'
    }

    if ($overallVerdict -eq 'FAIL') {
        $aAllFail = @($dnsTestsA | Where-Object { $_.Resolved }).Count -eq 0
        $pingAllFail = @($pingTests | Where-Object { $_.Success }).Count -eq 0
        if ($aAllFail -and -not $pingAllFail) {
            $diagnosis['RootCauseHint'] = 'DNS_ONLY_FAILURE'
        }
        if ($aAllFail -and $pingAllFail) {
            $diagnosis['RootCauseHint'] = 'NETWORK_UNREACHABLE'
        }
    }

    # ----------------------------------------------------------
    # 8. 记录日志事件
    # ----------------------------------------------------------
    $totalDurationMs = [math]::Round(((Get-Date) - $moduleStartTime).TotalMilliseconds, 0)

    $logEvent = @{
        event         = 'check.end'
        module        = 'M03'
        verdict       = $overallVerdict
        elapsed_ms    = $totalDurationMs
        dns_a_pass    = @($dnsTestsA | Where-Object { $_.Resolved }).Count
        dns_a_total   = $dnsTestsA.Count
        ping_pass     = @($pingTests | Where-Object { $_.Success }).Count
        dns_service   = $dnsServiceStatus
    }
    if ($dnsTestsAAAA.Count -gt 0) {
        $logEvent['dns_aaaa_pass']  = @($dnsTestsAAAA | Where-Object { $_.Resolved }).Count
        $logEvent['dns_aaaa_total'] = $dnsTestsAAAA.Count
    }
    $logEvents += $logEvent

    # 调用 lib 日志函数（dot-source 直接调用时写入日志，Job 内执行时静默跳过）
    Invoke-SafeLog -FunctionName 'Write-DiagnosisEvent' -Arguments @{
        Module      = 'M03'
        Verdict     = $overallVerdict
        ElapsedMs   = $totalDurationMs
        ExtraFields = @{
            dns_a_pass    = @($dnsTestsA | Where-Object { $_.Resolved }).Count
            dns_a_total   = $dnsTestsA.Count
            ping_pass     = @($pingTests | Where-Object { $_.Success }).Count
            dns_service   = $dnsServiceStatus
        }
    }

    return @{
        Diagnosis = $diagnosis
        LogEvents = $logEvents
    }
}

# ============================================================
# 公共导出函数：Invoke-M03_Repair
# ============================================================

<#
.SYNOPSIS
    执行 M03 DNS 解析修复
.DESCRIPTION
    修复步骤（L2 低风险）：
    1. ipconfig /flushdns
    2. Clear-DnsClientCache
    3. Restart-Service Dnscache
    4. 若 DNS 服务器配置异常：ResetServerAddresses
    5. 可选：设置公共 DNS（需用户确认）
    6. 验证：重新执行 DNS 解析测试
.PARAMETER Diagnosis
    Invoke-M03_Diagnose 返回的诊断结果哈希表
.OUTPUTS
    Hashtable: @{Repair=@{Verdict='success'|'failed'|'skipped'; RebootRequired=$false; Steps=@(...)}; LogEvents=@(...)}
#>
function Invoke-M03_Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Diagnosis = @{}
    )

    $logEvents = @()
    $repairSteps = @()
    $repairStartTime = Get-Date
    $allStepsOk = $true

    # ----------------------------------------------------------
    # 步骤 1: ipconfig /flushdns
    # ----------------------------------------------------------
    $stepResult = @{ Step = 'ipconfig_flushdns'; Success = $false; Detail = '' }
    try {
        $output = & ipconfig /flushdns 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $output -match 'Successfully') {
            $stepResult.Success = $true
            $stepResult.Detail  = 'DNS 解析缓存已刷新'
        }
        else {
            $stepResult.Success = $true  # flushdns 很少真正失败
            $stepResult.Detail  = "flushdns 已完成（输出: $($output.Trim())）"
        }
    }
    catch {
        $stepResult.Detail = "ipconfig /flushdns 失败: $($_.Exception.Message)"
        $allStepsOk = $false
    }
    $repairSteps += $stepResult

    Invoke-SafeLog -FunctionName 'Write-FixEvent' -Arguments @{
        Module        = 'M03'
        EventSubType  = 'step'
        Step          = 'ipconfig_flushdns'
        ExitCode      = if ($stepResult.Success) { 0 } else { 1 }
    }

    $logEvents += @{
        event     = 'fix.step'
        module    = 'M03'
        step      = 'ipconfig_flushdns'
        success   = $stepResult.Success
        detail    = $stepResult.Detail
    }

    # ----------------------------------------------------------
    # 步骤 2: Clear-DnsClientCache
    # ----------------------------------------------------------
    $stepResult = @{ Step = 'Clear-DnsClientCache'; Success = $false; Detail = '' }
    try {
        Clear-DnsClientCache -ErrorAction Stop
        $stepResult.Success = $true
        $stepResult.Detail  = 'DNS 客户端缓存已清除'
    }
    catch {
        # Clear-DnsClientCache 在某些环境下可能失败（如服务未运行）
        $stepResult.Detail = "Clear-DnsClientCache 失败: $($_.Exception.Message)"
        $allStepsOk = $false
    }
    $repairSteps += $stepResult

    Invoke-SafeLog -FunctionName 'Write-FixEvent' -Arguments @{
        Module        = 'M03'
        EventSubType  = 'step'
        Step          = 'Clear-DnsClientCache'
        ExitCode      = if ($stepResult.Success) { 0 } else { 1 }
    }

    $logEvents += @{
        event     = 'fix.step'
        module    = 'M03'
        step      = 'Clear-DnsClientCache'
        success   = $stepResult.Success
        detail    = $stepResult.Detail
    }

    # ----------------------------------------------------------
    # 步骤 3: Restart-Service Dnscache
    # ----------------------------------------------------------
    $stepResult = @{ Step = 'Restart-Dnscache'; Success = $false; Detail = '' }
    try {
        $dnsService = Get-Service -Name 'Dnscache' -ErrorAction SilentlyContinue
        if ($dnsService) {
            if ($dnsService.Status -eq 'Running') {
                Restart-Service -Name 'Dnscache' -Force -ErrorAction Stop
                $stepResult.Success = $true
                $stepResult.Detail  = 'DNS Client 服务已重启'
            }
            else {
                Start-Service -Name 'Dnscache' -ErrorAction Stop
                $stepResult.Success = $true
                $stepResult.Detail  = 'DNS Client 服务已启动'
            }
        }
        else {
            $stepResult.Detail = 'DNS Client 服务未找到'
            $allStepsOk = $false
        }
    }
    catch {
        $stepResult.Detail = "重启 DNS Client 服务失败: $($_.Exception.Message)"
        $allStepsOk = $false
    }
    $repairSteps += $stepResult

    Invoke-SafeLog -FunctionName 'Write-FixEvent' -Arguments @{
        Module        = 'M03'
        EventSubType  = 'step'
        Step          = 'Restart-Dnscache'
        ExitCode      = if ($stepResult.Success) { 0 } else { 1 }
    }

    $logEvents += @{
        event     = 'fix.step'
        module    = 'M03'
        step      = 'Restart-Dnscache'
        success   = $stepResult.Success
        detail    = $stepResult.Detail
    }

    # ----------------------------------------------------------
    # 步骤 4: DNS 服务器配置修复（若诊断到异常）
    # ----------------------------------------------------------
    $dnsServersAbnormal = $false

    # 检查诊断结果中是否有 DNS 服务器异常标记
    if ($Diagnosis.ContainsKey('DnsServersReachable')) {
        $reachable = $Diagnosis['DnsServersReachable']
        if ($reachable -is [array] -and $reachable.Count -gt 0) {
            $allUnreachable = @($reachable | Where-Object { $_ }).Count -eq 0
            if ($allUnreachable) {
                $dnsServersAbnormal = $true
            }
        }
    }

    if ($Diagnosis.ContainsKey('Verdict') -and $Diagnosis['Verdict'] -eq 'FAIL') {
        $dnsServersAbnormal = $true
    }

    if ($dnsServersAbnormal) {
        $stepResult = @{ Step = 'Reset-DnsServerAddresses'; Success = $false; Detail = '' }
        try {
            # 获取所有启用的网络适配器接口索引
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            if (-not $adapters) {
                # 回退：获取所有物理适配器
                $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
            }

            if ($adapters) {
                $resetCount = 0
                foreach ($adapter in $adapters) {
                    try {
                        Set-DnsClientServerAddress `
                            -InterfaceIndex $adapter.InterfaceIndex `
                            -ResetServerAddresses `
                            -ErrorAction Stop
                        $resetCount++
                    }
                    catch {
                        # 单个适配器重置失败不中断，继续处理其他适配器
                    }
                }

                if ($resetCount -gt 0) {
                    $stepResult.Success = $true
                    $stepResult.Detail  = "已重置 $resetCount 个网络适配器的 DNS 服务器配置"
                }
                else {
                    $stepResult.Detail = '未能重置任何适配器的 DNS 服务器配置'
                    $allStepsOk = $false
                }
            }
            else {
                $stepResult.Detail = '未找到可用的网络适配器'
                $allStepsOk = $false
            }
        }
        catch {
            $stepResult.Detail = "重置 DNS 服务器配置失败: $($_.Exception.Message)"
            $allStepsOk = $false
        }
        $repairSteps += $stepResult

        Invoke-SafeLog -FunctionName 'Write-FixEvent' -Arguments @{
            Module        = 'M03'
            EventSubType  = 'step'
            Step          = 'Reset-DnsServerAddresses'
            ExitCode      = if ($stepResult.Success) { 0 } else { 1 }
        }

        $logEvents += @{
            event     = 'fix.step'
            module    = 'M03'
            step      = 'Reset-DnsServerAddresses'
            success   = $stepResult.Success
            detail    = $stepResult.Detail
        }
    }
    else {
        $repairSteps += @{
            Step    = 'Reset-DnsServerAddresses'
            Success = $null
            Detail  = '已跳过（DNS 服务器配置正常）'
            Skipped = $true
        }
    }

    # ----------------------------------------------------------
    # 步骤 5: 可选 - 设置公共 DNS（标记为需用户确认）
    # ----------------------------------------------------------
    $stepResult = @{
        Step             = 'Set-PublicDNS'
        Success          = $null
        Detail           = '可选操作：设置公共 DNS (114.114.114.114 / 223.5.5.5)，需用户手动确认后执行。未自动执行。'
        RequiresApproval = $true
        Skipped          = $true
    }
    $repairSteps += $stepResult

    # ----------------------------------------------------------
    # 步骤 6: 验证 - 重新运行 DNS 解析测试
    # ----------------------------------------------------------
    $stepResult = @{ Step = 'Verify-DnsResolution'; Success = $false; Detail = '' }
    $verifyPass = $false
    try {
        # 只验证核心域名（减少等待时间）
        $verifyDomains = @('www.baidu.com', 'dns.google')
        $verifyResults = @()
        foreach ($domain in $verifyDomains) {
            $result = Resolve-DnsWithTimeout -Domain $domain -RecordType 'A'
            $verifyResults += $result
        }

        $verifyPassCount = @($verifyResults | Where-Object { $_.Success }).Count
        $verifyTotal     = $verifyResults.Count

        if ($verifyPassCount -eq $verifyTotal) {
            $stepResult.Success = $true
            $stepResult.Detail  = '验证通过：所有测试域名解析成功'
            $verifyPass = $true
        }
        elseif ($verifyPassCount -gt 0) {
            $stepResult.Success = $true
            $stepResult.Detail  = "验证部分通过：${verifyPassCount}/${verifyTotal} 个域名解析成功"
            $verifyPass = $true
        }
        else {
            $stepResult.Success = $false
            $stepResult.Detail  = '验证失败：所有测试域名仍无法解析'
            $allStepsOk = $false
        }
    }
    catch {
        $stepResult.Detail = "验证步骤异常: $($_.Exception.Message)"
        $allStepsOk = $false
    }
    $repairSteps += $stepResult

    Invoke-SafeLog -FunctionName 'Write-FixEvent' -Arguments @{
        Module        = 'M03'
        EventSubType  = 'step'
        Step          = 'Verify-DnsResolution'
        ExitCode      = if ($stepResult.Success) { 0 } else { 1 }
    }

    $logEvents += @{
        event     = 'fix.step'
        module    = 'M03'
        step      = 'Verify-DnsResolution'
        success   = $stepResult.Success
        detail    = $stepResult.Detail
    }

    # ----------------------------------------------------------
    # 7. 确定修复最终判定
    # ----------------------------------------------------------
    # 统计实际执行的步骤（排除跳过的）
    $executedSteps = $repairSteps | Where-Object { -not $_.Skipped }
    $failedSteps   = $executedSteps | Where-Object { $_.Success -eq $false }

    if ($repairSteps.Count -eq 0) {
        $finalVerdict = 'skipped'
    }
    elseif ($failedSteps.Count -gt 0) {
        $finalVerdict = 'failed'
    }
    elseif ($verifyPass -or $allStepsOk) {
        $finalVerdict = 'success'
    }
    else {
        $finalVerdict = 'failed'
    }

    # ----------------------------------------------------------
    # 8. 构建修复结果
    # ----------------------------------------------------------
    $totalDurationMs = [math]::Round(((Get-Date) - $repairStartTime).TotalMilliseconds, 0)

    $repair = @{
        Verdict        = $finalVerdict
        RebootRequired = $false
        Steps          = $repairSteps
        TotalSteps     = $repairSteps.Count
        FailedSteps    = $failedSteps.Count
        Duration_ms    = $totalDurationMs
    }

    # 日志：fix.end
    Invoke-SafeLog -FunctionName 'Write-FixEvent' -Arguments @{
        Module          = 'M03'
        EventSubType    = 'end'
        Verdict         = $finalVerdict
        RebootRequired  = $false
    }

    $logEvents += @{
        event           = 'fix.end'
        module          = 'M03'
        verdict         = $finalVerdict
        reboot_required = $false
        total_steps     = $repairSteps.Count
        failed_steps    = $failedSteps.Count
        duration_ms     = $totalDurationMs
    }

    return @{
        Repair    = $repair
        LogEvents = $logEvents
    }
}

# ============================================================
# 模块结束
# 本文件通过 dot-source (. .\modules\M03_DNS.ps1) 加载时，
# Invoke-M03_Diagnose 和 Invoke-M03_Repair 自动在当前作用域中可用。
# ============================================================
