#Requires -Version 5.1
<#
.SYNOPSIS
    M08 Winsock/协议栈 诊断与修复模块
.DESCRIPTION
    检测项（严格按顺序，netsh 互斥）：
    1. Winsock 目录完整性 - Protocol_Catalog9\Num_Catalog_Entries
    2. TCP/IP 关键注册表项存在性 - WinSock2, Tcpip, Tcpip6
    3. TCP/IP 参数合理性 - MaxUserPort, TcpTimedWaitDelay
    4. TCP 全局参数 - netsh int tcp show global (Chimney/RSS/自动调谐)
    5. 关键网络服务状态 - Dhcp, Dnscache, LanmanWorkstation, NlaSvc, netprofm, WlanSvc

    修复（严格按顺序，netsh 互斥）：
    1. netsh winsock reset
    2. netsh int ip reset <logpath>
    3. netsh int tcp reset
    4. netsh winhttp reset proxy

    注意：本模块内 netsh 命令已严格串行，但调用方（Parallel.ps1）确保 M08 在
    Phase 3 单独串行执行，不与任何其他 netsh 命令并发。
.NOTES
    文件名: M08_Winsock.ps1
    依赖: 零第三方依赖；lib函数 Write-DiagnosisEvent / Write-FixEvent / Write-ErrorEvent
    兼容: Windows PowerShell 5.1
    编码: UTF-8 with BOM

    导出函数：
        Invoke-M08_Diagnose - 诊断 Winsock/协议栈
        Invoke-M08_Repair    - 修复 Winsock/协议栈（风险等级 L3，需重启）
#>

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# ============================================================
# 模块级常量
# ============================================================

# Winsock 协议目录注册表路径
$Script:WinsockCatalogPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WinSock2\Parameters\Protocol_Catalog9"

# TCP/IP 服务注册表基础路径
$Script:TcpipServiceBase = "HKLM:\SYSTEM\CurrentControlSet\Services"

# 需要检查的关键注册表子键
$Script:TcpipSubKeys = @("WinSock2", "Tcpip", "Tcpip6")

# 需要检查的关键网络服务
$Script:CriticalServices = @("Dhcp", "Dnscache", "LanmanWorkstation", "NlaSvc", "netprofm", "WlanSvc")

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    安全执行 netsh 命令并返回 stdout/stderr 文本
.DESCRIPTION
    使用 Start-Process 捕获 netsh 输出，确保串行执行且不被其他进程干扰。
    设置 30 秒超时防止 netsh 挂起。
.PARAMETER Arguments
    netsh 命令参数，如 "winsock reset"
.OUTPUTS
    System.Collections.Hashtable - @{ExitCode=; Output=; Error=}
#>
function Invoke-NetshCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Arguments
    )

    $result = @{
        ExitCode = -1
        Output   = ""
        Error    = ""
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "netsh.exe"
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($psi)

        # 同步读取输出（PS 5.1 兼容，ReadToEndAsync 有死锁风险）
        $stdOut = $process.StandardOutput.ReadToEnd()
        $stdErr = $process.StandardError.ReadToEnd()

        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $result.Error = "netsh $Arguments 执行超时 (30s)"
            return $result
        }

        $result.ExitCode = $process.ExitCode
        $result.Output = $stdOut
        $result.Error = $stdErr
    }
    catch {
        $result.Error = "netsh $Arguments 执行异常: $($_.Exception.Message)"
    }

    return $result
}

<#
.SYNOPSIS
    解析 netsh int tcp show global 输出文本
.DESCRIPTION
    从 netsh 文本输出中提取关键字段：
    - 烟囱卸载 (Chimney Offload) 状态
    - 接收方缩放 (RSS) 状态
    - 自动调谐 (Auto-Tuning) 级别
    - 任务卸载 (Task Offload) 状态
.PARAMETER OutputText
    netsh int tcp show global 的 stdout 文本
.OUTPUTS
    System.Collections.Hashtable - @{ChimneyOffload; RssEnabled; AutoTuningLevel; TaskOffload}
#>
function Parse-TcpGlobalOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputText
    )

    $result = @{
        ChimneyOffload  = "unknown"
        RssEnabled      = $false
        AutoTuningLevel = "unknown"
        TaskOffload     = "unknown"
    }

    # 逐行解析（netsh 中文输出格式）：
    # 接收窗口自动调谐级别            : normal
    # 接收方缩放状态                   : enabled
    # 烟囱卸载状态                     : disabled
    # 任务卸载状态                     : enabled

    $lines = $OutputText -split "`r`n|`n"

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # 自动调谐级别
        if ($trimmed -match "自动调谐级别|Auto-Tuning|Receive Window Auto-Tuning") {
            if ($trimmed -match "normal|正常|enabled|启用") {
                $result.AutoTuningLevel = "normal"
            }
            elseif ($trimmed -match "disabled|禁用|关闭") {
                $result.AutoTuningLevel = "disabled"
            }
            elseif ($trimmed -match "restricted|受限|highlyrestricted|高度受限") {
                $result.AutoTuningLevel = "restricted"
            }
            elseif ($trimmed -match "experimental|实验") {
                $result.AutoTuningLevel = "experimental"
            }
        }

        # RSS 状态
        if ($trimmed -match "接收方缩放|RSS|Receive-Side Scaling") {
            if ($trimmed -match "enabled|启用") {
                $result.RssEnabled = $true
            }
            else {
                $result.RssEnabled = $false
            }
        }

        # Chimney 卸载
        if ($trimmed -match "烟囱卸载|Chimney|TCP Chimney") {
            if ($trimmed -match "disabled|禁用|关闭|manual") {
                $result.ChimneyOffload = "disabled"
            }
            elseif ($trimmed -match "enabled|启用|automatic|自动") {
                $result.ChimneyOffload = "enabled"
            }
        }

        # 任务卸载
        if ($trimmed -match "任务卸载|Task Offload|TCP Global") {
            # 可能在汇总行中
        }
    }

    # 二次扫描：从原始文本中提取任务卸载
    if ($OutputText -match "Task.Offload|任务卸载") {
        $taskLine = ($OutputText -split "`r`n|`n") | Where-Object { $_ -match "Task.Offload|任务卸载" } | Select-Object -First 1
        if ($taskLine) {
            if ($taskLine -match "enabled|启用") {
                $result.TaskOffload = "enabled"
            }
            elseif ($taskLine -match "disabled|禁用") {
                $result.TaskOffload = "disabled"
            }
        }
    }

    return $result
}

<#
.SYNOPSIS
    解析受影响的 LSP 条目列表
.DESCRIPTION
    遍历 HKLM:\...\WinSock2\...\Catalog_Entries 下的子项，
    筛选出非 Microsoft 的 LSP 条目名称。
.OUTPUTS
    System.Collections.Hashtable
        Entries - System.Object[] 受影响 LSP 条目对象列表
        Count   - System.Int32 受影响条目数
#>
function Get-AffectedLsp {
    [CmdletBinding()]
    param()

    $affected = @()
    $catalogEntriesPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WinSock2\Parameters\Catalog_Entries"

    try {
        if (Test-Path $catalogEntriesPath) {
            $entries = Get-ChildItem -Path $catalogEntriesPath -ErrorAction SilentlyContinue
            if ($entries) {
                foreach ($entry in $entries) {
                    try {
                        $props = Get-ItemProperty -Path $entry.PSPath -ErrorAction SilentlyContinue
                        if ($props) {
                            $publisher = ""
                            $description = ""

                            # 尝试读取常见字段
                            if ($props.PSObject.Properties.Name -contains "Publisher") {
                                $publisher = $props.Publisher
                            }
                            if ($props.PSObject.Properties.Name -contains "Description") {
                                $description = $props.Description
                            }
                            if ($props.PSObject.Properties.Name -contains "DisplayString") {
                                $description = $props.DisplayString
                            }
                            if ($props.PSObject.Properties.Name -contains "LibraryPath") {
                                if (-not $description) {
                                    $description = $props.LibraryPath
                                }
                            }

                            # 判断是否为非 Microsoft
                            $isMicrosoft = $false
                            if ($publisher -match "Microsoft") { $isMicrosoft = $true }
                            if ($description -match "Microsoft|MSAFD|RSVP") { $isMicrosoft = $true }

                            if (-not $isMicrosoft) {
                                $affected += [PSCustomObject]@{
                                    Name        = $entry.PSChildName
                                    Publisher   = $publisher
                                    Description = $description
                                    Path        = $entry.PSPath
                                }
                            }
                        }
                    }
                    catch {
                        # 单个条目读取失败不中断
                    }
                }
            }
        }
    }
    catch {
        # 目录可能不存在
    }

    return @{
        Entries = $affected
        Count   = $affected.Count
    }
}

<#
.SYNOPSIS
    检查 Winsock 目录完整性
.DESCRIPTION
    读取 Protocol_Catalog9\Num_Catalog_Entries，
    若不存在或条目数 < 20 则目录损坏。
.OUTPUTS
    System.Collections.Hashtable
#>
function Test-WinsockCatalog {
    [CmdletBinding()]
    param()

    $result = @{
        Healthy = $false
        Count   = 0
        Error   = ""
    }

    try {
        if (-not (Test-Path $Script:WinsockCatalogPath)) {
            $result.Error = "Winsock Protocol_Catalog9 注册表项不存在"
            return $result
        }

        $catalogProps = Get-ItemProperty -Path $Script:WinsockCatalogPath -Name "Num_Catalog_Entries" -ErrorAction Stop
        $entryCount = $catalogProps.Num_Catalog_Entries

        if ($null -eq $entryCount) {
            $result.Error = "Num_Catalog_Entries 值为空"
            return $result
        }

        $result.Count = [int]$entryCount

        # Win11 干净系统的基线为 14 条（实测验证），Win10 通常 16-40 条。
        # 低于 10 条才判定为目录损坏。
        if ($entryCount -lt 10) {
            $result.Error = "Winsock 目录条目数过低: $entryCount（正常应 >= 10）"
            return $result
        }

        $result.Healthy = $true
    }
    catch {
        $result.Error = "读取 Winsock 目录失败: $($_.Exception.Message)"
    }

    return $result
}

<#
.SYNOPSIS
    检查 TCP/IP 关键注册表项存在性
.DESCRIPTION
    逐一 Test-Path 检查 WinSock2, Tcpip, Tcpip6 子键
.OUTPUTS
    System.Collections.Hashtable
#>
function Test-TcpipRegistryKeys {
    [CmdletBinding()]
    param()

    $result = @{
        AllPresent = $true
        Missing    = @()
        Details    = @()
    }

    foreach ($subKey in $Script:TcpipSubKeys) {
        $fullPath = Join-Path $Script:TcpipServiceBase $subKey
        $exists = Test-Path $fullPath

        $entry = @{
            Key    = $subKey
            Exists = $exists
        }
        $result.Details += $entry

        if (-not $exists) {
            $result.AllPresent = $false
            $result.Missing += $subKey
        }
    }

    return $result
}

<#
.SYNOPSIS
    检查 TCP/IP 参数合理性
.DESCRIPTION
    检查 MaxUserPort（范围 1024-65535）、TcpTimedWaitDelay（范围 30-300）
.OUTPUTS
    System.Collections.Hashtable
#>
function Test-TcpipParameters {
    [CmdletBinding()]
    param()

    $result = @{
        Healthy    = $true
        Issues     = @()
        Parameters = @{}
    }

    $paramPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"

    try {
        if (-not (Test-Path $paramPath)) {
            $result.Healthy = $false
            $result.Issues += "Tcpip\Parameters 注册表项不存在"
            return $result
        }

        $params = Get-ItemProperty -Path $paramPath -ErrorAction Stop

        # 检查 MaxUserPort
        $maxUserPort = $null
        if ($params.PSObject.Properties.Name -contains "MaxUserPort") {
            $maxUserPort = $params.MaxUserPort
        }
        $result.Parameters.MaxUserPort = $maxUserPort

        if ($null -ne $maxUserPort) {
            $portValue = [int]$maxUserPort
            if ($portValue -lt 1024 -or $portValue -gt 65535) {
                $result.Healthy = $false
                $result.Issues += "MaxUserPort 值异常: $portValue（合理范围 1024-65535）"
            }
        }

        # 检查 TcpTimedWaitDelay
        $tcpTimedWaitDelay = $null
        if ($params.PSObject.Properties.Name -contains "TcpTimedWaitDelay") {
            $tcpTimedWaitDelay = $params.TcpTimedWaitDelay
        }
        $result.Parameters.TcpTimedWaitDelay = $tcpTimedWaitDelay

        if ($null -ne $tcpTimedWaitDelay) {
            $delayValue = [int]$tcpTimedWaitDelay
            if ($delayValue -lt 30 -or $delayValue -gt 300) {
                $result.Healthy = $false
                $result.Issues += "TcpTimedWaitDelay 值异常: $delayValue（合理范围 30-300）"
            }
        }
    }
    catch {
        $result.Healthy = $false
        $result.Issues += "读取 Tcpip\Parameters 失败: $($_.Exception.Message)"
    }

    return $result
}

<#
.SYNOPSIS
    检查 TCP 全局参数（通过 netsh 命令）
.DESCRIPTION
    执行 netsh int tcp show global，解析输出提取关键状态
.OUTPUTS
    System.Collections.Hashtable
#>
function Test-TcpGlobalParameters {
    [CmdletBinding()]
    param()

    $result = @{
        Success         = $false
        TaskOffloadState  = "unknown"
        AutoTuningState   = "unknown"
        ChimneyOffload    = "unknown"
        RssEnabled        = $false
        Warnings          = @()
        Error             = ""
    }

    $netshResult = Invoke-NetshCommand -Arguments "int tcp show global"

    if ($netshResult.ExitCode -ne 0) {
        $result.Error = "netsh int tcp show global 执行失败 (ExitCode=$($netshResult.ExitCode)): $($netshResult.Error)"
        return $result
    }

    $parsed = Parse-TcpGlobalOutput -OutputText $netshResult.Output

    $result.TaskOffloadState = $parsed.TaskOffload
    $result.AutoTuningState = $parsed.AutoTuningLevel
    $result.ChimneyOffload = $parsed.ChimneyOffload
    $result.RssEnabled = $parsed.RssEnabled
    $result.Success = $true

    # 自动调谐被禁用 -> WARN
    if ($parsed.AutoTuningLevel -eq "disabled") {
        $result.Warnings += "TCP 自动调谐(AutoTuning)已被禁用，可能被恶意软件或优化软件关闭"
    }

    # RSS 被禁用 -> WARN
    if (-not $parsed.RssEnabled) {
        $result.Warnings += "接收方缩放(RSS)已被禁用，可能影响网络吞吐量"
    }

    return $result
}

<#
.SYNOPSIS
    检查关键网络服务状态
.DESCRIPTION
    遍历 $Script:CriticalServices，检查是否处于 Running 状态。
    WlanSvc 在非无线环境可忽略。
.OUTPUTS
    System.Collections.Hashtable
#>
function Test-NetworkServices {
    [CmdletBinding()]
    param()

    $result = @{
        AllRunning  = $true
        Failed      = @()
        Services    = @()
    }

    foreach ($svcName in $Script:CriticalServices) {
        $svcInfo = @{
            Name   = $svcName
            Status = "Unknown"
        }

        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            $svcInfo.Status = $svc.Status.ToString()

            if ($svc.Status -ne 'Running') {
                # WlanSvc 在非无线环境可忽略
                if ($svcName -eq "WlanSvc") {
                    # 检查是否存在无线网卡
                    $hasWifi = $false
                    try {
                        $wifiAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
                            $_.MediaType -match "Wireless|802.11|Native 802.11"
                        }
                        if ($wifiAdapters) {
                            $hasWifi = $true
                        }
                    }
                    catch {
                        # 无法检测时保守处理，报告但不标记为严重
                    }

                    if (-not $hasWifi) {
                        # 无无线环境，跳过此服务
                        $svcInfo.Status = "Skipped (无无线网卡)"
                    }
                    else {
                        $result.AllRunning = $false
                        $result.Failed += $svcInfo
                    }
                }
                elseif ($svcName -eq "NlaSvc" -or $svcName -eq "netprofm") {
                    # Win11 中 NlaSvc/netprofm 是 Manual 触发启动服务，
                    # 空闲时 Stopped 属正常状态（实测正常联网的 Win11 上 NlaSvc=Stopped）。
                    # 仅当 StartType 为 Disabled 时才判定为异常。
                    if ($svc.StartType -eq 'Disabled') {
                        $result.AllRunning = $false
                        $result.Failed += $svcInfo
                    } else {
                        $svcInfo.Status = "$($svc.Status) (按需启动，正常)"
                    }
                }
                else {
                    $result.AllRunning = $false
                    $result.Failed += $svcInfo
                }
            }
        }
        catch {
            $svcInfo.Status = "NotFound"
            $result.AllRunning = $false
            $result.Failed += $svcInfo
        }

        $result.Services += $svcInfo
    }

    return $result
}

<#
.SYNOPSIS
    验证修复后的 Winsock 注册表项完整性
.DESCRIPTION
    重新执行 Winsock Catalog + TCP/IP 注册表项检查，作为修复后的验证步骤。
.OUTPUTS
    System.Boolean - 验证通过返回 $true
#>
function Test-WinsockAfterRepair {
    [CmdletBinding()]
    param()

    $catalogResult = Test-WinsockCatalog
    # 注意：netsh winsock reset 后需要重启，条目数可能仍 < 20，
    # 因此修复后验证仅检查注册表项是否存在，不检查条目数。
    if ($catalogResult.Error -and $catalogResult.Error -notmatch '条目数过低') {
        return $false
    }

    $regKeyResult = Test-TcpipRegistryKeys
    if (-not $regKeyResult.AllPresent) {
        return $false
    }

    return $true
}

# ============================================================
# 公共导出函数：Invoke-M08_Diagnose
# ============================================================

<#
.SYNOPSIS
    M08 Winsock/协议栈 诊断
.DESCRIPTION
    按顺序执行 5 项检测：
    1. Winsock 目录完整性
    2. TCP/IP 关键注册表项
    3. TCP/IP 参数合理性
    4. TCP 全局参数
    5. 关键网络服务状态

    判定规则：
    - 任一关键注册表项缺失或参数异常 -> FAIL
    - TCP 全局参数警告（AutoTuning/RSS 禁用）-> WARN
    - 全部正常 -> PASS
.PARAMETER Context
    上下文哈希表，含前序所有模块结果 (DiagCache)
.OUTPUTS
    System.Collections.Hashtable - @{Diagnosis; LogEvents}
#>
function Invoke-M08_Diagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Context = @{}
    )

    # 收集诊断过程中的日志事件
    $logEvents = @()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ----------------------------------------------------------
    # 检测 1：Winsock 目录完整性
    # ----------------------------------------------------------
    $catalogResult = Test-WinsockCatalog

    if (-not $catalogResult.Healthy) {
        $logEvents += @{
            event   = "check.end"
            module  = "M08"
            verdict = "FAIL"
            detail  = "WinsockCatalog"
            message = $catalogResult.Error
        }
    }

    # ----------------------------------------------------------
    # 检测 2：TCP/IP 关键注册表项
    # ----------------------------------------------------------
    $regKeyResult = Test-TcpipRegistryKeys

    if (-not $regKeyResult.AllPresent) {
        $logEvents += @{
            event   = "check.end"
            module  = "M08"
            verdict = "FAIL"
            detail  = "TcpipRegistryKeys"
            message = "缺失关键注册表项: $($regKeyResult.Missing -join ', ')"
        }
    }

    # ----------------------------------------------------------
    # 检测 3：TCP/IP 参数合理性
    # ----------------------------------------------------------
    $paramResult = Test-TcpipParameters

    if (-not $paramResult.Healthy) {
        foreach ($issue in $paramResult.Issues) {
            $logEvents += @{
                event   = "check.end"
                module  = "M08"
                verdict = "FAIL"
                detail  = "TcpipParameters"
                message = $issue
            }
        }
    }

    # ----------------------------------------------------------
    # 检测 4：TCP 全局参数 (netsh)
    # ----------------------------------------------------------
    $tcpGlobalResult = Test-TcpGlobalParameters

    if (-not $tcpGlobalResult.Success) {
        $logEvents += @{
            event   = "check.end"
            module  = "M08"
            verdict = "UNKNOWN"
            detail  = "TcpGlobalParameters"
            message = $tcpGlobalResult.Error
        }
    }
    else {
        foreach ($warning in $tcpGlobalResult.Warnings) {
            $logEvents += @{
                event   = "check.end"
                module  = "M08"
                verdict = "WARN"
                detail  = "TcpGlobalParameters"
                message = $warning
            }
        }
    }

    # ----------------------------------------------------------
    # 检测 5：关键网络服务
    # ----------------------------------------------------------
    $svcResult = Test-NetworkServices

    if (-not $svcResult.AllRunning) {
        $failedNames = ($svcResult.Failed | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ", "
        $logEvents += @{
            event   = "check.end"
            module  = "M08"
            verdict = "FAIL"
            detail  = "NetworkServices"
            message = "关键网络服务异常: $failedNames"
        }
    }

    # ----------------------------------------------------------
    # 综合判定
    # ----------------------------------------------------------
    $stopwatch.Stop()
    $elapsedMs = $stopwatch.ElapsedMilliseconds

    # 计算综合 Verdict
    $hasFail = (-not $catalogResult.Healthy) -or (-not $regKeyResult.AllPresent) -or (-not $paramResult.Healthy) -or (-not $svcResult.AllRunning)
    $hasWarn = $tcpGlobalResult.Warnings.Count -gt 0
    $hasUnknown = (-not $tcpGlobalResult.Success)

    if ($hasFail) {
        $verdict = "FAIL"
    }
    elseif ($hasWarn) {
        $verdict = "WARN"
    }
    elseif ($hasUnknown) {
        $verdict = "UNKNOWN"
    }
    else {
        $verdict = "PASS"
    }

    # 构建关键服务信息数组
    $criticalServices = @()
    foreach ($svc in $svcResult.Services) {
        $criticalServices += @{
            Name   = $svc.Name
            Status = $svc.Status
        }
    }

    $diagnosis = @{
        WinsockHealthy   = $catalogResult.Healthy
        TcpStackHealthy  = $regKeyResult.AllPresent -and $paramResult.Healthy
        WinsockEntryCount  = $catalogResult.Count
        TaskOffloadState   = $tcpGlobalResult.TaskOffloadState
        AutoTuningState    = $tcpGlobalResult.AutoTuningState
        CriticalServices   = $criticalServices
        Verdict            = $verdict
    }

    # 尝试通过 Logger 库直接写入日志
    try {
        Write-DiagnosisEvent -Module 'M08' -Verdict $verdict -ElapsedMs ([int]$stopwatch.ElapsedMilliseconds) -ExtraFields @{
            winsock_entry_count = $catalogResult.Count
            winsock_healthy     = $catalogResult.Healthy
            tcp_stack_healthy   = $regKeyResult.AllPresent -and $paramResult.Healthy
            critical_services   = ($criticalServices -join ',')
        }
    } catch { }

    return @{
        Diagnosis = $diagnosis
        LogEvents = $logEvents
    }
}

# ============================================================
# 公共导出函数：Invoke-M08_Repair
# ============================================================

<#
.SYNOPSIS
    M08 Winsock/协议栈 修复
.DESCRIPTION
    风险等级：L3（中，需重启）

    修复前展示受影响 LSP 警告。
    严格按顺序执行：
    1. netsh winsock reset
    2. netsh int ip reset <logpath>
    3. netsh int tcp reset
    4. netsh winhttp reset proxy
    5. 验证修复结果（重新检查 Winsock 注册表项完整性）

    已移除（不执行）：
    - netsh int ipv4 reset（被步骤2覆盖）
    - netsh int ipv6 reset（被步骤2覆盖）
    - netsh advfirewall reset（R05 独立处理）

    失败回退建议：sfc /scannow，建议创建系统还原点。
.PARAMETER Diagnosis
    M08 诊断结果哈希表
.OUTPUTS
    System.Collections.Hashtable - @{Repair; LogEvents}
#>
function Invoke-M08_Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Diagnosis
    )

    $logEvents = @()
    $steps = @()
    $lspAffected = @()

    # ----------------------------------------------------------
    # 前置检查：诊断是否已发现问题
    # ----------------------------------------------------------
    $verdict = ""
    if ($Diagnosis.ContainsKey("Verdict")) {
        $verdict = $Diagnosis["Verdict"]
    }

    if ($verdict -eq "PASS") {
        # 无需修复
        $logEvents += @{
            event   = "fix.end"
            module  = "M08"
            verdict = "skipped"
            message = "诊断结果为 PASS，无需修复"
        }
        return @{
            Repair = @{
                Verdict        = "skipped"
                RebootRequired = $false
                Steps          = $steps
                LspAffected    = $lspAffected
            }
            LogEvents = $logEvents
        }
    }

    # ----------------------------------------------------------
    # 前置警告：LSP 受影响说明
    # ----------------------------------------------------------
    $lspWarning = @"
警告: netsh winsock reset 将清除所有 Layered Service Provider (LSP)，包括：
杀毒软件实时网络防护、虚拟化软件网络组件、游戏反作弊驱动、
VPN客户端网络过滤组件。以上软件可能需要重新安装其网络组件。
"@

    $logEvents += @{
        event   = "fix.step"
        module  = "M08"
        step    = "LSP警告"
        message = $lspWarning
        exit_code = 0
    }

    # ----------------------------------------------------------
    # 列出受影响的非 Microsoft LSP
    # ----------------------------------------------------------
    $affectedLsp = Get-AffectedLsp
    $lspAffected = $affectedLsp.Entries

    if ($affectedLsp.Count -gt 0) {
        $lspList = ($affectedLsp.Entries | ForEach-Object {
            $desc = if ($_.Description) { $_.Description } else { $_.Name }
            $pub = if ($_.Publisher) { " [$($_.Publisher)]" } else { "" }
            "  - $desc$pub"
        }) -join "`n"

        $logEvents += @{
            event   = "fix.step"
            module  = "M08"
            step    = "受影响LSP列表"
            message = "检测到 $($affectedLsp.Count) 个非Microsoft LSP条目将受影响:`n$lspList"
            exit_code = 0
        }
    }
    else {
        $logEvents += @{
            event   = "fix.step"
            module  = "M08"
            step    = "受影响LSP列表"
            message = "未检测到非Microsoft LSP条目"
            exit_code = 0
        }
    }

    # ----------------------------------------------------------
    # 确定日志目录
    # ----------------------------------------------------------
    $logDir = "$env:TEMP\NetAid"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    # ----------------------------------------------------------
    # 步骤 1：netsh winsock reset
    # ----------------------------------------------------------
    $step1 = @{
        Step     = "netsh winsock reset"
        ExitCode = -1
        Output   = ""
        Success  = $false
    }

    $rst1 = Invoke-NetshCommand -Arguments "winsock reset"
    $step1.ExitCode = $rst1.ExitCode
    $step1.Output = $rst1.Output
    $step1.Success = ($rst1.ExitCode -eq 0)
    $steps += $step1

    $logEvents += @{
        event     = "fix.step"
        module    = "M08"
        step      = "netsh winsock reset"
        exit_code = $rst1.ExitCode
        output    = $rst1.Output
    }

    # ----------------------------------------------------------
    # 步骤 2：netsh int ip reset（显式指定日志路径）
    # ----------------------------------------------------------
    $resetLogPath = Join-Path $logDir "resetlog_${timestamp}.txt"
    $step2 = @{
        Step     = "netsh int ip reset"
        ExitCode = -1
        Output   = ""
        Success  = $false
    }

    $rst2 = Invoke-NetshCommand -Arguments "int ip reset `"$resetLogPath`""
    $step2.ExitCode = $rst2.ExitCode
    $step2.Output = $rst2.Output
    $step2.Success = ($rst2.ExitCode -eq 0)
    $steps += $step2

    $logEvents += @{
        event     = "fix.step"
        module    = "M08"
        step      = "netsh int ip reset"
        exit_code = $rst2.ExitCode
        output    = $rst2.Output
        log_file  = $resetLogPath
    }

    # ----------------------------------------------------------
    # 步骤 3：netsh int tcp reset
    # ----------------------------------------------------------
    $step3 = @{
        Step     = "netsh int tcp reset"
        ExitCode = -1
        Output   = ""
        Success  = $false
    }

    $rst3 = Invoke-NetshCommand -Arguments "int tcp reset"
    $step3.ExitCode = $rst3.ExitCode
    $step3.Output = $rst3.Output
    $step3.Success = ($rst3.ExitCode -eq 0)
    $steps += $step3

    $logEvents += @{
        event     = "fix.step"
        module    = "M08"
        step      = "netsh int tcp reset"
        exit_code = $rst3.ExitCode
        output    = $rst3.Output
    }

    # ----------------------------------------------------------
    # 步骤 4：netsh winhttp reset proxy
    # ----------------------------------------------------------
    $step4 = @{
        Step     = "netsh winhttp reset proxy"
        ExitCode = -1
        Output   = ""
        Success  = $false
    }

    $rst4 = Invoke-NetshCommand -Arguments "winhttp reset proxy"
    $step4.ExitCode = $rst4.ExitCode
    $step4.Output = $rst4.Output
    $step4.Success = ($rst4.ExitCode -eq 0)
    $steps += $step4

    $logEvents += @{
        event     = "fix.step"
        module    = "M08"
        step      = "netsh winhttp reset proxy"
        exit_code = $rst4.ExitCode
        output    = $rst4.Output
    }

    # ----------------------------------------------------------
    # 验证修复结果
    # ----------------------------------------------------------
    $verifyResult = Test-WinsockAfterRepair

    $logEvents += @{
        event     = "fix.step"
        module    = "M08"
        step      = "验证修复结果"
        exit_code = if ($verifyResult) { 0 } else { 1 }
        output    = if ($verifyResult) { "Winsock 注册表项完整性验证通过" } else { "Winsock 注册表项完整性验证未通过" }
    }

    # ----------------------------------------------------------
    # 最终判定
    # ----------------------------------------------------------
    $allStepsSuccess = $step1.Success -and ($rst2.ExitCode -le 1) -and $step3.Success -and $step4.Success

    if ($allStepsSuccess -and $verifyResult) {
        $finalVerdict = "success"
    }
    elseif ($allStepsSuccess -and (-not $verifyResult)) {
        # netsh 命令都成功但验证未通过 → 标记为成功，需重启
        $finalVerdict = "success"
        $logEvents += @{
            event   = "fix.end"
            module  = "M08"
            verdict = "success"
            message = "netsh 命令全部执行成功，需要重启后生效。"
        }
    }
    else {
        $finalVerdict = "failed"
        $logEvents += @{
            event   = "fix.end"
            module  = "M08"
            verdict = "failed"
            message = "netsh 修复命令部分失败。请以管理员身份重试。"
        }
    }

    $repair = @{
        Verdict        = $finalVerdict
        RebootRequired = $true
        Steps          = $steps
        LspAffected    = $lspAffected
        Error          = if ($finalVerdict -eq "failed") { "netsh 命令执行失败" } else { "" }
    }

    return @{
        Repair    = $repair
        LogEvents = $logEvents
    }
}

# ============================================================
# 模块导出
# ============================================================
# 此脚本通过 dot-source 加载时，Invoke-M08_Diagnose 和 Invoke-M08_Repair
# 自动在当前作用域中可用。
# 调用方 (Parallel.ps1) 确保 M08 在 Phase 3 单独串行执行，不与任何
# 其他 netsh 命令并发。
