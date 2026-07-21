#Requires -Version 5.1
<#
.SYNOPSIS
    M07_ThirdParty.ps1 - 第三方软件/安全软件残留检测与修复模块
.DESCRIPTION
    检测并清理已卸载安全软件（360、火绒、腾讯管家、金山毒霸等）残留的
    驱动注册表项、Winsock LSP 注入、WFP 过滤器、虚拟网卡适配器。

    子检测：
    A - 注册表驱动残留扫描（匹配 KnownResidueDrivers 黑名单）
    B - Winsock LSP 目录完整性检查
    C - WFP 过滤器残留检测（独立超时 Job，15秒）
    D - TAP/Wintun/蓝牙PAN 虚拟适配器残留检测

    综合风险矩阵：
    - Start=0/1/2 + 文件存在 + 网络过滤类 → 高危 FAIL
    - Start=0/1/2 + 文件不存在 → 中危 WARN
    - WFP 第三方过滤器 > 50 → 中危 WARN
    - LSP 条目 > 200 → 中危 WARN
    - Start=3 + 文件不存在 → 低危
    - Start=4 → 信息（忽略）
.NOTES
    依赖: Utils.ps1 (变量: $Script:KnownResidueDrivers, $Script:SuspiciousWfpProviders)
           Logger.ps1 (函数: Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent)
    兼容: Windows PowerShell 5.1, 零第三方依赖
    编码: UTF-8 with BOM
#>

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# ============================================================
# 内部辅助：安全调用 lib 日志函数（兼容 Start-Job 子进程环境）
# 在 Start-Job 子进程中 Logger.ps1 未被 dot-source，Write-* 函数不可用，
# 此时静默失败，实际日志由 Parallel.ps1 从 $logEvents 写入。
# ============================================================
function _SafeWriteLog {
    param(
        [ValidateSet('Diagnosis', 'FixStep', 'FixEnd', 'Error')]
        [string]$LogType,
        [hashtable]$Params
    )
    try {
        switch ($LogType) {
            'Diagnosis' {
                Write-DiagnosisEvent -Module $Params.Module -Verdict $Params.Verdict `
                    -ElapsedMs $Params.ElapsedMs -ExtraFields $Params.ExtraFields
            }
            'FixStep' {
                Write-FixEvent -Module $Params.Module -EventSubType 'step' `
                    -Step $Params.Step -ExitCode $Params.ExitCode
            }
            'FixEnd' {
                Write-FixEvent -Module $Params.Module -EventSubType 'end' `
                    -Verdict $Params.Verdict -RebootRequired $Params.RebootRequired
            }
            'Error' {
                Write-ErrorEvent -Severity $Params.Severity -Message $Params.Message `
                    -StackTrace $Params.StackTrace
            }
        }
    }
    catch {
        # Start-Job 子进程中 Logger 函数不可用，静默失败；
        # 事件已同步写入 $logEvents，由 Parallel.ps1 的 Collect-JobResults 统一写入日志文件。
    }
}

<#
.SYNOPSIS
    内部辅助：将 lib 函数调用打包为安全的无异常版本
.DESCRIPTION
    当在 Start-Job 子进程中运行时，Utils.ps1 的函数可能不可用。
    使用此包装器确保调用不会因函数缺失而中断。
#>
function _SafeCall {
    param(
        [string]$FunctionName,
        [hashtable]$Params
    )
    try {
        switch ($FunctionName) {
            'Expand-EnvironmentPath' {
                return Expand-EnvironmentPath -RawPath $Params.RawPath
            }
            'Test-DigitalSignature' {
                return Test-DigitalSignature -FilePath $Params.FilePath
            }
            'Backup-RegistryKey' {
                return Backup-RegistryKey -KeyPath $Params.KeyPath
            }
        }
    }
    catch {
        # 函数不可用时回退到内联实现或返回安全默认值
        switch ($FunctionName) {
            'Expand-EnvironmentPath' {
                try { return [Environment]::ExpandEnvironmentVariables($Params.RawPath) }
                catch { return $Params.RawPath }
            }
            'Test-DigitalSignature' {
                try {
                    if (-not (Test-Path $Params.FilePath)) { return "NotFound" }
                    $sig = Get-AuthenticodeSignature -FilePath $Params.FilePath -ErrorAction SilentlyContinue
                    if ($null -eq $sig -or $sig.Status -eq "NotSigned") { return "Unsigned" }
                    if ($sig.Status -eq "Valid" -or $sig.Status -eq "UnknownError") {
                        $subj = $sig.SignerCertificate.Subject
                        if ($subj -match "Microsoft Windows" -or $subj -match "Microsoft Corporation") { return "Microsoft" }
                        if ($subj -match 'CN=([^,]+)') { return $Matches[1] }
                        return $subj
                    }
                    return "Unsigned"
                }
                catch { return "Error" }
            }
            'Backup-RegistryKey' {
                try {
                    $backupDir = Join-Path $PSScriptRoot ".." ".." "backups"
                    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
                    $sanitized = $Params.KeyPath -replace '[\\:<>"/|?*]', '_' -replace '\s+', '_'
                    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
                    $fp = Join-Path $backupDir "reg_${sanitized}_${ts}.reg"
                    $res = & reg export $Params.KeyPath $fp /y 2>&1
                    if ($LASTEXITCODE -ne 0) { return $null }
                    return $fp
                }
                catch { return $null }
            }
        }
    }
}

# ============================================================
# 内部辅助：判断驱动是否为网络过滤类
# 根据黑名单中的中文描述关键词匹配
# ============================================================
function _IsNetworkFilterDriver {
    param(
        [string]$DriverName,
        [string]$Description
    )

    # 检查驱动文件名中的网络关键词
    $nameLower = $DriverName.ToLower()
    $nameNetworkPatterns = @('wfp', 'ndis', 'fw', 'net', 'tap', 'tun', 'vpn', 'pcap', 'npf', 'filter')
    foreach ($pattern in $nameNetworkPatterns) {
        if ($nameLower -match $pattern) { return $true }
    }

    # 检查中文描述中的网络关键词
    $networkKeywords = @(
        '网络', 'WFP', 'NDIS', '防火墙', '数据包', 'TAP', 'VPN',
        '虚拟网卡', 'TUN', 'WireGuard', 'Npcap', 'WinPcap',
        '过滤', '流量', '代理', 'ARP'
    )
    foreach ($kw in $networkKeywords) {
        if ($Description -match $kw) { return $true }
    }

    return $false
}

<#
.SYNOPSIS
    执行 M07 模块诊断：扫描第三方安全软件残留
.DESCRIPTION
    并行执行四个子检测（A-注册表驱动扫描, B-Winsock LSP, C-WFP过滤器, D-虚拟适配器），
    根据综合风险矩阵输出最终判定。
.PARAMETER Context
    上下文哈希表（初始为空，保留供后续扩展）
.OUTPUTS
    System.Collections.Hashtable - 包含 Diagnosis 和 LogEvents 键
.EXAMPLE
    $result = Invoke-M07_Diagnose -Context @{}
    $result.Diagnosis.Verdict  # PASS / WARN / FAIL / UNKNOWN
#>
function Invoke-M07_Diagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Context = @{}
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $logEvents = @()
    $moduleName = "M07"

    # ---- 初始化输出结构 ----
    $activeDrivers        = @()
    $ghostDrivers         = @()
    $wfpForeignFilters    = @()
    $virtualAdapters      = @()
    $bluetoothPanAdapters = @()
    $lspCount             = 0
    $lspCorrupted         = $false
    $wfpTimeout           = $false

    # ---- 安全回退：若全局变量未加载则初始化为空 ----
    $knownDrivers = if ($Script:KnownResidueDrivers -is [hashtable]) {
        $Script:KnownResidueDrivers
    } else {
        @{}
    }
    $suspiciousProviders = if ($Script:SuspiciousWfpProviders -is [array]) {
        $Script:SuspiciousWfpProviders
    } else {
        @()
    }

    # ============================================================
    # 子检测 C — WFP 过滤器（先启动独立 Job，后续等待结果）
    # ============================================================
    $wfpJob = $null
    try {
        $wfpJob = Start-Job -Name "M07_WFP" -ScriptBlock {
            $output = netsh wfp show filters 2>&1 | Out-String
            return $output
        } -ErrorAction SilentlyContinue
    }
    catch {
        # Start-Job 失败不阻塞，WFP 检测标记为超时
        $wfpTimeout = $true
    }

    # ============================================================
    # 子检测 A — 注册表驱动残留扫描
    # ============================================================
    try {
        $servicesPath = "HKLM:\SYSTEM\CurrentControlSet\Services"
        if (Test-Path $servicesPath) {
            $allServices = Get-ChildItem $servicesPath -ErrorAction SilentlyContinue

            foreach ($svc in $allServices) {
                $svcName = $svc.PSChildName
                # 仅检查黑名单中的驱动名
                if (-not $knownDrivers.ContainsKey($svcName)) { continue }

                $description = $knownDrivers[$svcName]

                # 采集注册表属性
                $displayName = ""
                $imagePath   = ""
                $startType   = -1
                $svcType     = 0

                try {
                    $props = Get-ItemProperty -Path $svc.PSPath -ErrorAction SilentlyContinue
                    if ($props) {
                        $displayName = if ($props.DisplayName) { $props.DisplayName } else { "" }
                        $imagePath   = if ($props.ImagePath)  { $props.ImagePath }  else { "" }
                        $startType   = if ($props.Start -ne $null)      { [int]$props.Start }      else { -1 }
                        $svcType     = if ($props.Type -ne $null)       { [int]$props.Type }       else { 0 }
                    }
                }
                catch {
                    # 属性读取失败，跳过该项
                    continue
                }

                # 展开环境变量路径并检查文件存在性
                $expandedPath = ""
                $fileExists   = $false
                if ($imagePath) {
                    $expandedPath = _SafeCall -FunctionName 'Expand-EnvironmentPath' -Params @{ RawPath = $imagePath }
                    $fileExists   = Test-Path $expandedPath
                }

                # 检查数字签名
                $digSig = "Unknown"
                if ($fileExists -and $expandedPath) {
                    $digSig = _SafeCall -FunctionName 'Test-DigitalSignature' -Params @{ FilePath = $expandedPath }
                }
                elseif ($imagePath) {
                    # 文件不存在，尝试对原始路径检查签名
                    $digSig = _SafeCall -FunctionName 'Test-DigitalSignature' -Params @{ FilePath = $imagePath }
                }

                # 安全检查：若数字签名为 Microsoft → 跳过不标记
                if ($digSig -eq "Microsoft") {
                    continue
                }

                # 判断是否为网络过滤类
                $isNetworkFilter = _IsNetworkFilterDriver -DriverName $svcName -Description $description

                # 按 Start 值分类
                $startName = switch ($startType) {
                    0 { "Boot(0)" }
                    1 { "System(1)" }
                    2 { "Auto(2)" }
                    3 { "Manual(3)" }
                    4 { "Disabled(4)" }
                    default { "Unknown($startType)" }
                }

                # 分类存放
                if ($startType -ge 0 -and $startType -le 2) {
                    # Boot/System/Auto 启动类型
                    if ($fileExists) {
                        # 活跃残留 — 高危
                        $activeDrivers += @{
                            Name             = $svcName
                            Vendor           = $description
                            DisplayName      = $displayName
                            StartType        = $startName
                            StartValue       = $startType
                            ServiceType      = $svcType
                            ImagePath        = $imagePath
                            ExpandedPath     = $expandedPath
                            FileExists       = $true
                            DigitalSignature = $digSig
                            IsNetworkFilter  = $isNetworkFilter
                        }
                    }
                    else {
                        # 幽灵残留 — 中危（文件已删除但注册表仍在）
                        $ghostDrivers += @{
                            Name             = $svcName
                            Vendor           = $description
                            DisplayName      = $displayName
                            StartType        = $startName
                            StartValue       = $startType
                            ServiceType      = $svcType
                            ImagePath        = $imagePath
                            ExpandedPath     = $expandedPath
                            FileExists       = $false
                            DigitalSignature = $digSig
                            IsNetworkFilter  = $isNetworkFilter
                        }
                    }
                }
                elseif ($startType -eq 3) {
                    # 手动启动 — 低危（潜在风险）
                    $ghostDrivers += @{
                        Name             = $svcName
                        Vendor           = $description
                        DisplayName      = $displayName
                        StartType        = $startName
                        StartValue       = $startType
                        ServiceType      = $svcType
                        ImagePath        = $imagePath
                        ExpandedPath     = $expandedPath
                        FileExists       = $fileExists
                        DigitalSignature = $digSig
                        IsNetworkFilter  = $isNetworkFilter
                    }
                }
                # Start=4 已禁用 → 忽略，不记录
            }
        }
    }
    catch {
        $errorMsg = "子检测A(注册表驱动扫描)异常: $($_.Exception.Message)"
        _SafeWriteLog -LogType 'Error' -Params @{
            Severity   = "medium"
            Message    = $errorMsg
            StackTrace = $_.ScriptStackTrace
        }
        $logEvents += @{
            event    = 'error'
            severity = 'medium'
            message  = $errorMsg
            module   = $moduleName
            phase    = 'diagnosis'
        }
    }

    # ============================================================
    # 子检测 B — Winsock LSP 目录完整性检查
    # ============================================================
    try {
        $lspPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WinSock2\Parameters\Protocol_Catalog9\Catalog_Entries"

        if (Test-Path $lspPath) {
            # 统计子键数量
            $entries = @(Get-ChildItem $lspPath -ErrorAction SilentlyContinue)
            $lspCount = $entries.Count

            # 条目数检查：< 20 表示 LSP 目录严重损坏
            if ($lspCount -lt 20) {
                $lspCorrupted = $true
            }

            # 遍历条目解析 PackedCatalogItem 中的 DLL 路径
            # PackedCatalogItem 是 REG_BINARY，DLL 路径以 Unicode 字符串嵌入
            foreach ($entry in $entries) {
                try {
                    $itemProps = Get-ItemProperty -Path $entry.PSPath -ErrorAction SilentlyContinue
                    if (-not $itemProps -or -not $itemProps.PackedCatalogItem) { continue }

                    $binaryData = $itemProps.PackedCatalogItem
                    # 将二进制数据转为 Unicode 字符串，提取可能的 DLL 路径
                    $unicodeStr = [System.Text.Encoding]::Unicode.GetString($binaryData)
                    # 匹配 .dll 或 .sys 文件路径
                    $dllMatches = [regex]::Matches($unicodeStr, '[\w\\\.\-]+\.(dll|sys|DLL|SYS)')

                    foreach ($match in $dllMatches) {
                        $dllPath = $match.Value
                        $expandedDll = _SafeCall -FunctionName 'Expand-EnvironmentPath' -Params @{ RawPath = $dllPath }
                        if (-not (Test-Path $expandedDll)) {
                            # DLL 文件缺失，可能为残留 LSP
                            $lspCorrupted = $true
                        }
                    }
                }
                catch {
                    # 单条目解析失败，继续下一个
                    continue
                }
            }
        }
        else {
            # 注册表路径不存在 → LSP 目录可能未初始化
            $lspCount = 0
        }
    }
    catch {
        $errorMsg = "子检测B(LSP目录)异常: $($_.Exception.Message)"
        _SafeWriteLog -LogType 'Error' -Params @{
            Severity   = "medium"
            Message    = $errorMsg
            StackTrace = $_.ScriptStackTrace
        }
        $logEvents += @{
            event    = 'error'
            severity = 'medium'
            message  = $errorMsg
            module   = $moduleName
            phase    = 'diagnosis'
        }
    }

    # ============================================================
    # 子检测 C — WFP 过滤器结果收集
    # ============================================================
    if ($wfpJob -ne $null) {
        try {
            $null = Wait-Job -Job $wfpJob -Timeout 15 -ErrorAction SilentlyContinue

            if ($wfpJob.State -eq 'Completed') {
                $wfpOutput = Receive-Job -Job $wfpJob -ErrorAction SilentlyContinue

                if ($wfpOutput) {
                    $wfpLines = $wfpOutput -split "`r`n|`n"
                    $filterCount = 0

                    foreach ($line in $wfpLines) {
                        # 统计过滤规则总数（以固定格式行计数）
                        if ($line -match '^\s*Filter\s*ID\s*:' -or $line -match '^\s*Filter\s+Name\s*:') {
                            $filterCount++
                        }

                        # 匹配可疑 WFP Provider
                        foreach ($suspicious in $suspiciousProviders) {
                            if ($line -match [regex]::Escape($suspicious)) {
                                $wfpForeignFilters += $suspicious
                            }
                        }
                    }

                    # 去重
                    $wfpForeignFilters = @($wfpForeignFilters | Select-Object -Unique)

                    # 过滤数过多 → 警告
                    if ($filterCount -gt 800) {
                        if ($wfpForeignFilters.Count -eq 0) {
                            $wfpForeignFilters += "系统WFP过滤器数量异常(>$filterCount)"
                        }
                    }
                }
            }
            else {
                # WFP netsh 命令超时
                $wfpTimeout = $true
                Stop-Job -Job $wfpJob -ErrorAction SilentlyContinue
            }
        }
        catch {
            $wfpTimeout = $true
        }
        finally {
            Remove-Job -Job $wfpJob -Force -ErrorAction SilentlyContinue
        }
    }

    # ============================================================
    # 子检测 D — TAP/Wintun/蓝牙PAN 虚拟适配器残留
    # ============================================================
    try {
        $allAdapters = Get-NetAdapter -ErrorAction SilentlyContinue

        if ($allAdapters) {
            foreach ($adapter in $allAdapters) {
                $desc   = $adapter.InterfaceDescription
                $name   = $adapter.Name
                $status = $adapter.Status

                # TAP/Wintun/VPN/Virtual 虚拟适配器
                if ($desc -match 'TAP|Wintun|VPN|Virtual|PANGP') {
                    $adapterEntry = @{
                        Name   = $name
                        Type   = $desc
                        Status = $status
                    }
                    $adapterEntry['IsResidue'] = ($status -eq 'Disconnected' -or $status -eq 'Disabled')
                    $virtualAdapters += $adapterEntry
                }

                # 蓝牙 PAN 适配器
                if ($desc -match 'Bluetooth Device \(Personal Area Network\)' -or
                    $desc -match '蓝牙.*个人区域网|Bluetooth.*PAN') {
                    $panEntry = @{
                        Name   = $name
                        Type   = $desc
                        Status = $status
                    }
                    $panEntry['IsResidue'] = ($status -eq 'Disconnected' -or $status -eq 'Disabled')
                    $bluetoothPanAdapters += $panEntry
                }
            }
        }
    }
    catch {
        # Get-NetAdapter 可能不可用，不阻塞
        $errorMsg = "子检测D(虚拟适配器)异常: $($_.Exception.Message)"
        _SafeWriteLog -LogType 'Error' -Params @{
            Severity   = "low"
            Message    = $errorMsg
            StackTrace = $_.ScriptStackTrace
        }
        $logEvents += @{
            event    = 'error'
            severity = 'low'
            message  = $errorMsg
            module   = $moduleName
            phase    = 'diagnosis'
        }
    }

    # ============================================================
    # 综合风险矩阵 → 最终 Verdict
    # ============================================================
    $verdict = "PASS"

    # 高危判定：Start=0/1/2 + 文件存在 + 网络过滤类 → FAIL
    $highRiskDrivers = $activeDrivers | Where-Object { $_.IsNetworkFilter -eq $true }
    if (@($highRiskDrivers).Count -gt 0) {
        $verdict = "FAIL"
    }

    # 活跃非网络过滤类残留 → 中危 WARN
    $nonNetworkActive = $activeDrivers | Where-Object { $_.IsNetworkFilter -ne $true }
    if ($verdict -ne "FAIL" -and $nonNetworkActive.Count -gt 0) {
        $verdict = "WARN"
    }

    # 幽灵残留 (Start 0/1/2 + 文件不存在) → 中危 WARN
    if ($ghostDrivers.Count -gt 0 -and $verdict -ne "FAIL") {
        $verdict = "WARN"
    }

    # WFP 第三方过滤器 > 50 → 中危 WARN
    if ($wfpForeignFilters.Count -gt 50 -and $verdict -ne "FAIL") {
        $verdict = "WARN"
    }

    # LSP 条目 > 200 → 中危 WARN
    if ($lspCount -gt 200 -and $verdict -ne "FAIL") {
        $verdict = "WARN"
    }

    # LSP 目录损坏 (条目 < 20) → 中危 WARN
    if ($lspCorrupted -and $verdict -ne "FAIL") {
        $verdict = "WARN"
    }

    # WFP 超时 → WARN
    if ($wfpTimeout -and $verdict -ne "FAIL") {
        $verdict = "WARN"
    }

    # 虚拟适配器残留（Disconnected状态）→ 低危 WARN
    $disconnectedVAdapters = $virtualAdapters | Where-Object { $_.IsResidue -eq $true }
    $disconnectedPan      = $bluetoothPanAdapters | Where-Object { $_.IsResidue -eq $true }
    if (($disconnectedVAdapters.Count -gt 0 -or $disconnectedPan.Count -gt 0) -and $verdict -eq "PASS") {
        $verdict = "WARN"
    }

    $sw.Stop()
    $elapsedMs = $sw.ElapsedMilliseconds

    # ---- 构建诊断结果 ----
    $diagnosis = @{
        ActiveDrivers        = $activeDrivers
        GhostDrivers         = $ghostDrivers
        LSP_Count            = $lspCount
        LSP_Corrupted        = $lspCorrupted
        WFP_ForeignFilters   = $wfpForeignFilters
        WFP_Timeout          = $wfpTimeout
        VirtualAdapters      = $virtualAdapters
        BluetoothPanAdapters = $bluetoothPanAdapters
        Verdict              = $verdict
    }

    # ---- 写入诊断日志（Start-Job 中不可用时由 LogEvents 兜底） ----
    $extraFields = @{
        active_drivers_count   = $activeDrivers.Count
        ghost_drivers_count    = $ghostDrivers.Count
        lsp_count              = $lspCount
        lsp_corrupted          = $lspCorrupted
        wfp_foreign_count      = $wfpForeignFilters.Count
        wfp_timeout            = $wfpTimeout
        virtual_adapters_count = $virtualAdapters.Count
        bluetooth_pan_count    = $bluetoothPanAdapters.Count
    }
    _SafeWriteLog -LogType 'Diagnosis' -Params @{
        Module      = $moduleName
        Verdict     = $verdict
        ElapsedMs   = $elapsedMs
        ExtraFields = $extraFields
    }

    # ---- 构建日志事件列表（供 Parallel.ps1 的 Collect-JobResults 在 Start-Job 中写入） ----
    $logEvents += @{
        event      = 'check.end'
        module     = $moduleName
        verdict    = $verdict
        elapsed_ms = $elapsedMs
        extra      = $extraFields
    }

    # ---- 返回结果 ----
    return @{
        Diagnosis = $diagnosis
        LogEvents = $logEvents
    }
}

<#
.SYNOPSIS
    执行 M07 模块修复：清理第三方安全软件残留
.DESCRIPTION
    根据诊断结果执行分级修复：
    1. 活跃残留（Start≠4, 签名非Microsoft）→ 禁用驱动（Start=4）
    2. 幽灵残留（文件不存在, 签名非Microsoft）→ 删除注册表Service键
    3. LSP 损坏 → 记录触发 netsh winsock reset（实际执行交由 M08）
    4. WFP 过滤器 → 记录触发 netsh advfirewall reset
.PARAMETER Diagnosis
    诊断结果哈希表（来自 Invoke-M07_Diagnose 的 Diagnosis 字段）
.OUTPUTS
    System.Collections.Hashtable - 包含 Repair 和 LogEvents 键
.EXAMPLE
    $result = Invoke-M07_Diagnose
    $repair = Invoke-M07_Repair -Diagnosis $result.Diagnosis
#>
function Invoke-M07_Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Diagnosis
    )

    $logEvents   = @()
    $moduleName  = "M07"
    $repairSteps = @()
    $allSuccess  = $true
    $rebootRequired = $false

    # ---- 安全回退：确保全局变量已加载 ----
    if (-not ($Script:KnownResidueDrivers -is [hashtable])) {
        # Start-Job 子进程可能没有该变量，继续使用诊断数据
    }

    # ---- 提取诊断数据 ----
    $activeDrivers   = if ($Diagnosis.ContainsKey('ActiveDrivers'))  { $Diagnosis['ActiveDrivers'] }  else { @() }
    $ghostDrivers    = if ($Diagnosis.ContainsKey('GhostDrivers'))   { $Diagnosis['GhostDrivers'] }   else { @() }
    $lspCorrupted    = if ($Diagnosis.ContainsKey('LSP_Corrupted'))  { $Diagnosis['LSP_Corrupted'] }  else { $false }
    $lspCount        = if ($Diagnosis.ContainsKey('LSP_Count'))      { $Diagnosis['LSP_Count'] }      else { 0 }
    $wfpForeign      = if ($Diagnosis.ContainsKey('WFP_ForeignFilters')) { $Diagnosis['WFP_ForeignFilters'] } else { @() }
    $wfpTimeout      = if ($Diagnosis.ContainsKey('WFP_Timeout'))    { $Diagnosis['WFP_Timeout'] }    else { $false }
    $virtualAdapters = if ($Diagnosis.ContainsKey('VirtualAdapters')) { $Diagnosis['VirtualAdapters'] } else { @() }

    # ============================================================
    # 步骤1 — 活跃残留：禁用驱动（Set Start=4）
    # ============================================================
    foreach ($driver in $activeDrivers) {
        $drvName      = $driver['Name']
        $vendor       = $driver['Vendor']
        $startValue   = $driver['StartValue']
        $fileExists   = $driver['FileExists']
        $expandedPath = if ($driver.ContainsKey('ExpandedPath')) { $driver['ExpandedPath'] } else { "" }
        $imagePath    = if ($driver.ContainsKey('ImagePath'))    { $driver['ImagePath'] }    else { "" }

        # 跳过已禁用的驱动
        if ($startValue -eq 4) {
            $repairSteps += "跳过 [${drvName}]：驱动已禁用 (Start=4)"
            continue
        }

        # 安全检查：二次数字签名验证
        $sigCheck = "Unknown"
        if ($fileExists -and $expandedPath) {
            $sigCheck = _SafeCall -FunctionName 'Test-DigitalSignature' -Params @{ FilePath = $expandedPath }
        }
        elseif ($imagePath) {
            $sigCheck = _SafeCall -FunctionName 'Test-DigitalSignature' -Params @{ FilePath = $imagePath }
        }

        if ($sigCheck -eq "Microsoft" -or $sigCheck -match "Microsoft") {
            $repairSteps += "跳过 [${drvName}]：数字签名为 Microsoft，不执行修改"
            _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "跳过 ${drvName} (Microsoft签名)"; ExitCode = 0 }
            continue
        }

        # 强制备份注册表键
        $svcKeyPath = "HKLM\SYSTEM\CurrentControlSet\Services\${drvName}"
        $backupFile = _SafeCall -FunctionName 'Backup-RegistryKey' -Params @{ KeyPath = $svcKeyPath }
        if (-not $backupFile) {
            $repairSteps += "失败 [${drvName}]：注册表备份失败，跳过修改"
            _SafeWriteLog -LogType 'Error' -Params @{
                Severity = "high"; Message = "驱动 [${drvName}] 注册表备份失败，已跳过修改"; StackTrace = ""
            }
            _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "备份失败 ${drvName}"; ExitCode = 1 }
            $allSuccess = $false
            continue
        }

        # 执行禁用：Set Start=4
        try {
            $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\${drvName}"
            if (Test-Path $svcRegPath) {
                Set-ItemProperty -Path $svcRegPath -Name "Start" -Value 4 -Type DWord -ErrorAction Stop
                $repairSteps += "已禁用 [${drvName}] ($vendor)：Start=4（重启后生效）"
                _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "禁用驱动 ${drvName} (${vendor})"; ExitCode = 0 }
                $rebootRequired = $true
            }
            else {
                $repairSteps += "跳过 [${drvName}]：注册表键不存在（可能已被清理）"
                _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "键不存在 ${drvName}"; ExitCode = 0 }
            }
        }
        catch {
            $repairSteps += "失败 [${drvName}]：Set-ItemProperty 异常 - $($_.Exception.Message)"
            _SafeWriteLog -LogType 'Error' -Params @{
                Severity = "high"; Message = "禁用驱动 [${drvName}] 失败: $($_.Exception.Message)"; StackTrace = $_.ScriptStackTrace
            }
            _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "禁用失败 ${drvName}"; ExitCode = 1 }
            $allSuccess = $false
        }
    }

    # ============================================================
    # 步骤2 — 幽灵残留：删除注册表 Service 键
    # ============================================================
    foreach ($driver in $ghostDrivers) {
        $drvName    = $driver['Name']
        $vendor     = $driver['Vendor']
        $fileExists = $driver['FileExists']
        $imagePath  = if ($driver.ContainsKey('ImagePath'))  { $driver['ImagePath'] }  else { "" }

        # 仅处理文件不存在的幽灵残留
        if ($fileExists -eq $true) {
            $repairSteps += "跳过 [${drvName}]：文件仍存在，不删除（请先禁用后观察）"
            continue
        }

        # 安全检查：二次数字签名验证
        $sigCheck = if ($driver.ContainsKey('DigitalSignature')) { $driver['DigitalSignature'] } else { "Unknown" }
        if ($imagePath) {
            $sigCheck = _SafeCall -FunctionName 'Test-DigitalSignature' -Params @{ FilePath = $imagePath }
        }

        if ($sigCheck -eq "Microsoft" -or $sigCheck -match "Microsoft") {
            $repairSteps += "跳过 [${drvName}]：数字签名为 Microsoft，不删除注册表项"
            _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "跳过 ${drvName} (Microsoft签名)"; ExitCode = 0 }
            continue
        }

        # 强制备份注册表键
        $svcKeyPath = "HKLM\SYSTEM\CurrentControlSet\Services\${drvName}"
        $backupFile = _SafeCall -FunctionName 'Backup-RegistryKey' -Params @{ KeyPath = $svcKeyPath }
        if (-not $backupFile) {
            $repairSteps += "失败 [${drvName}]：注册表备份失败，跳过删除"
            _SafeWriteLog -LogType 'Error' -Params @{
                Severity = "high"; Message = "幽灵驱动 [${drvName}] 注册表备份失败，已跳过删除"; StackTrace = ""
            }
            _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "备份失败 ${drvName}"; ExitCode = 1 }
            $allSuccess = $false
            continue
        }

        # 执行删除
        try {
            $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\${drvName}"
            if (Test-Path $svcRegPath) {
                Remove-Item -Path $svcRegPath -Recurse -Force -ErrorAction Stop
                $repairSteps += "已删除 [${drvName}] ($vendor) 注册表键"
                _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "删除注册表键 ${drvName} (${vendor})"; ExitCode = 0 }
                $rebootRequired = $true
            }
            else {
                $repairSteps += "跳过 [${drvName}]：注册表键不存在（可能已被清理）"
                _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "键不存在 ${drvName}"; ExitCode = 0 }
            }
        }
        catch {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $repairSteps += "失败 [${drvName}]：Remove-Item 异常。回退: reg import `"backups\reg_${drvName}_${timestamp}.reg`""
            _SafeWriteLog -LogType 'Error' -Params @{
                Severity = "high"; Message = "删除幽灵驱动注册表键 [${drvName}] 失败: $($_.Exception.Message)"; StackTrace = $_.ScriptStackTrace
            }
            _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "删除失败 ${drvName}"; ExitCode = 1 }
            $allSuccess = $false
        }
    }

    # ============================================================
    # 步骤3 — LSP 损坏：记录触发 netsh winsock reset（实际执行交由 M08）
    # ============================================================
    if ($lspCorrupted -or $lspCount -gt 200 -or $lspCount -lt 20) {
        $lspStepMsg = "LSP 目录异常（条目数=${lspCount}，损坏=${lspCorrupted}）。建议执行: netsh winsock reset（由 M08 模块处理）"
        $repairSteps += $lspStepMsg
        _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "LSP异常记录"; ExitCode = 0 }
        $rebootRequired = $true
    }

    # ============================================================
    # 步骤4 — WFP 过滤器：记录不自动修复（需手动执行 netsh advfirewall reset）
    # ============================================================
    if ($wfpForeign.Count -gt 0) {
        $wfpNames = ($wfpForeign | Select-Object -First 10) -join ', '
        if ($wfpForeign.Count -gt 10) { $wfpNames += " ...（共 $($wfpForeign.Count) 项）" }
        $wfpStepMsg = "WFP 第三方过滤器残留 ($($wfpForeign.Count) 项): ${wfpNames}。建议执行: netsh advfirewall reset（请注意此操作将重置所有防火墙规则）"
        $repairSteps += $wfpStepMsg
        _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "WFP残留记录"; ExitCode = 0 }
    }

    if ($wfpTimeout) {
        $repairSteps += "WFP 过滤器检测超时，无法自动清理。请手动运行: netsh wfp show filters 检查"
        _SafeWriteLog -LogType 'FixStep' -Params @{ Module = $moduleName; Step = "WFP超时记录"; ExitCode = 0 }
    }

    # ============================================================
    # 步骤5 — 验证修复结果
    # ============================================================
    $verifyErrors = @()
    foreach ($driver in $activeDrivers) {
        $drvName = $driver['Name']
        $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\${drvName}"
        try {
            if (Test-Path $svcRegPath) {
                $props = Get-ItemProperty -Path $svcRegPath -ErrorAction SilentlyContinue
                if ($props -and $props.Start -ne $null -and [int]$props.Start -ne 4) {
                    $verifyErrors += "验证失败 [${drvName}]：Start 未变为 4（当前=$($props.Start)）"
                }
            }
        }
        catch {
            $verifyErrors += "验证异常 [${drvName}]：$($_.Exception.Message)"
        }
    }

    foreach ($driver in $ghostDrivers) {
        $drvName = $driver['Name']
        $fileExists = $driver['FileExists']
        # 仅验证文件不存在的幽灵残留（已执行删除的）
        if ($fileExists -eq $true) { continue }
        $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\${drvName}"
        if (Test-Path $svcRegPath) {
            $verifyErrors += "验证失败 [${drvName}]：注册表键仍存在"
        }
    }

    if ($verifyErrors.Count -gt 0) {
        foreach ($err in $verifyErrors) {
            $repairSteps += $err
        }
    }
    else {
        $repairSteps += "验证完成：所有修改已生效"
    }

    # ============================================================
    # 最终判定
    # ============================================================
    $repairVerdict = if ($allSuccess) { "success" } else { "failed" }

    # 若无任何修复操作 → skipped
    $hasAnyRepairAction = ($repairSteps | Where-Object {
        $_ -notmatch '^跳过' -and $_ -notmatch '^验证' -and $_ -notmatch '^LSP 目录异常' -and $_ -notmatch '^WFP'
    }).Count -gt 0
    if (-not $hasAnyRepairAction -and $allSuccess) {
        $repairVerdict = "skipped"
    }

    # ---- 写入修复日志（Start-Job 中不可用时由 LogEvents 兜底） ----
    _SafeWriteLog -LogType 'FixEnd' -Params @{
        Module         = $moduleName
        Verdict        = $repairVerdict
        RebootRequired = $rebootRequired
    }

    # ---- 构建日志事件列表（供 Parallel.ps1 的 Collect-JobResults 在 Start-Job 中写入） ----
    $logEvents += @{
        event           = 'fix.end'
        module          = $moduleName
        verdict         = $repairVerdict
        reboot_required = $rebootRequired
        steps_count     = $repairSteps.Count
    }

    # ---- 返回结果 ----
    return @{
        Repair = @{
            Verdict        = $repairVerdict
            RebootRequired = $rebootRequired
            Steps          = $repairSteps
        }
        LogEvents = $logEvents
    }
}
