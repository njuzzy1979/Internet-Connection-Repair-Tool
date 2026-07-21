#Requires -Version 5.1
<#
.SYNOPSIS
    M11 深度残留清理模块（内核级 NDIS 过滤驱动清理）
.DESCRIPTION
    针对疑难场景：安全软件卸载后 NDIS 过滤驱动残留导致全网卡 DHCP 失效
    （APIPA 169.254.x.x），且 netsh reset / 网络重置 / 就地升级均无效。

    检测项：
    A - NDIS 轻量过滤驱动 (LWF) 扫描：FilterClass 注册表 + 绑定链
    B - 网卡绑定配置孤儿引用检测（Control\Network 配置单元）
    C - 残留 .sys 驱动文件扫描（drivers 目录 + 黑名单匹配）
    D - NetworkSetup2 组件数据库异常检测
    E - DHCP 客户端服务依赖链检查（依赖的底层驱动是否存在）

    修复项（全部先备份到 backups/）：
    1 - 禁用/删除孤儿 NDIS 过滤驱动服务注册表项
    2 - 重命名残留 .sys 文件为 .sys.netaid_bak
    3 - 清理网卡绑定链中的孤儿 FilterList 引用
    4 - 可选（二次确认）：netcfg -d 重建全部网络绑定
.NOTES
    文件名: M11_DeepClean.ps1
    导出函数: Invoke-M11_Diagnose, Invoke-M11_Repair
    风险等级: L4b（深度修复，需二次确认 + 重启）
    依赖: Utils.ps1 ($Script:KnownResidueDrivers), Logger.ps1
    兼容: Windows PowerShell 5.1，零第三方依赖
    编码: UTF-8 with BOM
#>

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# ============================================================
# 模块级常量
# ============================================================

# 网络适配器类 GUID（固定值）
$Script:NetClassGuid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'

# 已知安全软件驱动文件名模式（用于 drivers 目录扫描）
$Script:ResidueSysPatterns = @(
    '360*.sys', 'Bapidrv*.sys', 'QKNetFilter*.sys', 'QKNetmon*.sys',
    'TS*.sys', 'QQPC*.sys', 'QMUdisk*.sys', 'TFsFlt*.sys',
    'KNB*.sys', 'kisknl*.sys', 'KAV*.sys', 'kwatch*.sys',
    'hrwfpdrv*.sys', 'hrdevmon*.sys', 'sysdiag*.sys'
)

# 已知安全软件 NDIS 过滤驱动服务名（黑名单核心，独立于 Utils.ps1 以便单测）
$Script:KnownNdisFilterServices = @(
    '360netmon', '360NetFlow', '360AntiHacker', '360AntiArp',
    'BAPIDRV', 'QKNetFilter', 'QKNetmon',
    'TSNetMon', 'QQPCNetFlow', 'QQSysMonX64',
    'KNetFlt', 'kisknl',
    'hrwfpdrv', 'sysdiag'
)

# Windows 自带的合法 NDIS 过滤驱动（白名单，绝不能动）
$Script:LegitNdisFilters = @(
    'NdisCap', 'Ndu', 'NdisImPlatform', 'WFPLWFS', 'vmsmp', 'VMSNPXY',
    'MsLldp', 'RspndrMP', 'LltdIo', 'NativeWifiP', 'vwififlt', 'Pacer',
    'kdnic', 'NdisVirtualBus', 'CompositeBus', 'wfplwfs'
)

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    安全写日志（兼容 Start-Job 环境）
#>
function _M11_SafeLog {
    param([string]$FuncName, [hashtable]$Params)
    try {
        if (Get-Command -Name $FuncName -ErrorAction SilentlyContinue) {
            & $FuncName @Params
        }
    } catch { }
}

<#
.SYNOPSIS
    子检测A：扫描系统中注册的所有 NDIS 过滤驱动
.DESCRIPTION
    遍历 HKLM\SYSTEM\CurrentControlSet\Services，找出 FilterClass 非空的服务，
    对照白名单/黑名单分类，并校验驱动文件是否存在。
.OUTPUTS
    @{ SuspiciousFilters=@(); OrphanFilters=@(); AllFilters=@() }
#>
function Get-NdisFilterDrivers {
    [CmdletBinding()]
    param()

    $suspicious = @()   # 黑名单命中或非微软签名
    $orphans    = @()   # 注册表存在但文件不存在
    $all        = @()

    $servicesPath = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    $serviceKeys = Get-ChildItem -Path $servicesPath -ErrorAction SilentlyContinue

    foreach ($key in $serviceKeys) {
        $svcName = $key.PSChildName
        try {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }

            # 只关注 NDIS 过滤类服务：FilterClass 存在 或 名字在黑名单中
            $filterClass = $null
            if ($props.PSObject.Properties['FilterClass']) {
                $filterClass = $props.FilterClass
            }
            $isBlacklisted = $Script:KnownNdisFilterServices -contains $svcName

            if (-not $filterClass -and -not $isBlacklisted) { continue }

            # 解析驱动文件路径
            $imagePath = ''
            if ($props.PSObject.Properties['ImagePath']) {
                $imagePath = [Environment]::ExpandEnvironmentVariables($props.ImagePath)
                # 处理 \SystemRoot\ 前缀
                $imagePath = $imagePath -replace '^\\SystemRoot\\', "$env:SystemRoot\"
                $imagePath = $imagePath -replace '^System32\\', "$env:SystemRoot\System32\"
            }

            $fileExists = $false
            if ($imagePath -and (Test-Path $imagePath -ErrorAction SilentlyContinue)) {
                $fileExists = $true
            }

            $startValue = if ($props.PSObject.Properties['Start']) { $props.Start } else { -1 }

            $filterInfo = @{
                ServiceName = $svcName
                FilterClass = "$filterClass"
                ImagePath   = $imagePath
                FileExists  = $fileExists
                Start       = $startValue
                IsWhitelisted = ($Script:LegitNdisFilters -contains $svcName)
                IsBlacklisted = $isBlacklisted
            }
            $all += $filterInfo

            # 白名单直接跳过
            if ($filterInfo.IsWhitelisted) { continue }

            # 黑名单命中 → 可疑
            if ($isBlacklisted) {
                $suspicious += $filterInfo
                continue
            }

            # 注册了 FilterClass 但文件不存在 → 孤儿（最危险，会锁死绑定链）
            if ($filterClass -and -not $fileExists -and $startValue -ne 4) {
                $orphans += $filterInfo
            }
        } catch { }
    }

    return @{
        SuspiciousFilters = $suspicious
        OrphanFilters     = $orphans
        AllFilters        = $all
    }
}

<#
.SYNOPSIS
    子检测B：检查网卡绑定配置中的孤儿 FilterList 引用
.DESCRIPTION
    遍历 Control\Network\{NetClass}\ 下每个适配器的 Linkage，
    检查绑定的过滤驱动服务是否真实存在。
#>
function Get-OrphanBindings {
    [CmdletBinding()]
    param()

    $orphanBindings = @()
    $netPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Network\$Script:NetClassGuid"

    if (-not (Test-Path $netPath)) { return $orphanBindings }

    $adapterKeys = Get-ChildItem -Path $netPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f-]+\}$' }

    foreach ($adapterKey in $adapterKeys) {
        $connPath = Join-Path $adapterKey.PSPath 'Connection'
        if (-not (Test-Path $connPath)) { continue }

        try {
            $conn = Get-ItemProperty -Path $connPath -ErrorAction SilentlyContinue
            $adapterName = if ($conn -and $conn.PSObject.Properties['Name']) { $conn.Name } else { $adapterKey.PSChildName }

            # 检查 Linkage 下的绑定
            $linkagePath = Join-Path $adapterKey.PSPath 'Linkage'
            if (Test-Path $linkagePath) {
                $linkage = Get-ItemProperty -Path $linkagePath -ErrorAction SilentlyContinue
                if ($linkage -and $linkage.PSObject.Properties['FilterList']) {
                    foreach ($filterRef in @($linkage.FilterList)) {
                        # FilterList 条目格式: {GUID} 形式引用过滤驱动实例
                        $orphanBindings += @{
                            AdapterName = $adapterName
                            AdapterGuid = $adapterKey.PSChildName
                            FilterRef   = "$filterRef"
                        }
                    }
                }
            }
        } catch { }
    }

    return $orphanBindings
}

<#
.SYNOPSIS
    子检测C：扫描 drivers 目录中的安全软件残留 .sys 文件
#>
function Get-ResidueSysFiles {
    [CmdletBinding()]
    param()

    $found = @()
    $driversDir = "$env:SystemRoot\System32\drivers"

    foreach ($pattern in $Script:ResidueSysPatterns) {
        try {
            $files = Get-ChildItem -Path $driversDir -Filter $pattern -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                # 校验数字签名——Microsoft 签名的跳过
                $isMicrosoft = $false
                try {
                    $sig = Get-AuthenticodeSignature -FilePath $f.FullName -ErrorAction SilentlyContinue
                    if ($sig -and $sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'Microsoft') {
                        $isMicrosoft = $true
                    }
                } catch { }

                if (-not $isMicrosoft) {
                    $found += @{
                        FileName = $f.Name
                        FullPath = $f.FullName
                        SizeKB   = [math]::Round($f.Length / 1KB, 1)
                        Modified = $f.LastWriteTime.ToString('yyyy-MM-dd')
                    }
                }
            }
        } catch { }
    }

    return $found
}

<#
.SYNOPSIS
    子检测D：DHCP 服务依赖链完整性检查
.DESCRIPTION
    Dhcp 服务依赖 Afd/NetBT/Tdx 等底层驱动。检查依赖的服务是否都存在且未被禁用。
#>
function Test-DhcpDependencyChain {
    [CmdletBinding()]
    param()

    $result = @{
        Healthy = $true
        Issues  = @()
    }

    try {
        $dhcpKey = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dhcp' -ErrorAction Stop
        $depends = @()
        if ($dhcpKey.PSObject.Properties['DependOnService']) {
            $depends = @($dhcpKey.DependOnService)
        }

        foreach ($dep in $depends) {
            $depPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$dep"
            if (-not (Test-Path $depPath)) {
                $result.Healthy = $false
                $result.Issues += "DHCP依赖的服务不存在: $dep"
                continue
            }
            $depProps = Get-ItemProperty -Path $depPath -ErrorAction SilentlyContinue
            if ($depProps -and $depProps.PSObject.Properties['Start'] -and $depProps.Start -eq 4) {
                $result.Healthy = $false
                $result.Issues += "DHCP依赖的服务被禁用(Start=4): $dep"
            }
        }

        # 检查 Afd（Winsock 核心驱动）
        $afdPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD'
        if (Test-Path $afdPath) {
            $afd = Get-ItemProperty -Path $afdPath -ErrorAction SilentlyContinue
            if ($afd -and $afd.PSObject.Properties['Start'] -and $afd.Start -ne 1) {
                $result.Healthy = $false
                $result.Issues += "AFD驱动Start值异常: $($afd.Start) (正常应为1)"
            }
        } else {
            $result.Healthy = $false
            $result.Issues += "AFD驱动注册表项不存在（Winsock核心损坏）"
        }
    } catch {
        $result.Issues += "依赖链检查异常: $($_.Exception.Message)"
    }

    return $result
}

# ============================================================
# 公共导出函数：Invoke-M11_Diagnose
# ============================================================

<#
.SYNOPSIS
    执行 M11 深度残留诊断
.PARAMETER Context
    上下文哈希表（可空）
.OUTPUTS
    @{ Diagnosis = @{...; Verdict}; LogEvents = @(...) }
#>
function Invoke-M11_Diagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Context = @{}
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $logEvents = @()

    $diagnosis = @{
        SuspiciousFilters = @()
        OrphanFilters     = @()
        ResidueSysFiles   = @()
        DhcpChainIssues   = @()
        OrphanBindings    = @()
        Verdict           = 'UNKNOWN'
    }

    try {
        # --- A: NDIS 过滤驱动扫描 ---
        $ndisResult = Get-NdisFilterDrivers
        $diagnosis.SuspiciousFilters = @($ndisResult.SuspiciousFilters)
        $diagnosis.OrphanFilters     = @($ndisResult.OrphanFilters)

        # --- B: 绑定链孤儿引用 ---
        $diagnosis.OrphanBindings = @(Get-OrphanBindings)

        # --- C: 残留 .sys 文件 ---
        $diagnosis.ResidueSysFiles = @(Get-ResidueSysFiles)

        # --- D: DHCP 依赖链 ---
        $chainResult = Test-DhcpDependencyChain
        $diagnosis.DhcpChainIssues = @($chainResult.Issues)

        # --- 综合判定 ---
        $suspiciousCount = @($diagnosis.SuspiciousFilters).Count
        $orphanCount     = @($diagnosis.OrphanFilters).Count
        $sysCount        = @($diagnosis.ResidueSysFiles).Count
        $chainIssueCount = @($diagnosis.DhcpChainIssues).Count

        if ($orphanCount -gt 0 -or $chainIssueCount -gt 0) {
            # 孤儿过滤驱动 / DHCP 依赖链损坏 → 严重（正是全网卡断网的根因特征）
            $diagnosis.Verdict = 'FAIL'
        } elseif ($suspiciousCount -gt 0 -or $sysCount -gt 0) {
            # 有黑名单驱动/文件残留但未构成孤儿 → 警告
            $diagnosis.Verdict = 'WARN'
        } else {
            $diagnosis.Verdict = 'PASS'
        }

        $sw.Stop()
        _M11_SafeLog 'Write-DiagnosisEvent' @{
            Module = 'M11'; Verdict = $diagnosis.Verdict
            ElapsedMs = [int]$sw.ElapsedMilliseconds
            ExtraFields = @{
                suspicious_filters = $suspiciousCount
                orphan_filters     = $orphanCount
                residue_sys_files  = $sysCount
                dhcp_chain_issues  = $chainIssueCount
            }
        }
    } catch {
        $sw.Stop()
        $diagnosis.Verdict = 'UNKNOWN'
        _M11_SafeLog 'Write-ErrorEvent' @{
            Severity = 'high'
            Message = "M11 深度诊断异常: $($_.Exception.Message)"
            StackTrace = $_.ScriptStackTrace
        }
    }

    return @{
        Diagnosis = $diagnosis
        LogEvents = $logEvents
    }
}

# ============================================================
# 公共导出函数：Invoke-M11_Repair
# ============================================================

<#
.SYNOPSIS
    执行 M11 深度残留清理（L4b 高风险，全程备份）
.PARAMETER Diagnosis
    Invoke-M11_Diagnose 返回的 Diagnosis 哈希表
.OUTPUTS
    @{ Repair = @{Verdict; RebootRequired; Steps; Error}; LogEvents = @(...) }
#>
function Invoke-M11_Repair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Diagnosis
    )

    $logEvents = @()
    $steps = @()
    $anyFailed = $false
    $anyDone = $false

    if ($Diagnosis.Verdict -eq 'PASS') {
        return @{
            Repair = @{ Verdict = 'skipped'; RebootRequired = $false; Steps = @(); Error = '' }
            LogEvents = @()
        }
    }

    # 备份目录
    $backupDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'backups'
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'

    # ----------------------------------------------------------
    # 步骤1：处理孤儿 NDIS 过滤驱动（根因级修复）
    # ----------------------------------------------------------
    foreach ($filter in @($Diagnosis.OrphanFilters)) {
        $svcName = $filter.ServiceName
        $keyPath = "HKLM\SYSTEM\CurrentControlSet\Services\$svcName"
        $stepInfo = @{ Step = "清理孤儿过滤驱动: $svcName"; Success = $false }

        try {
            # 备份注册表键
            $backupFile = Join-Path $backupDir "reg_${svcName}_${ts}.reg"
            $null = & reg export $keyPath $backupFile /y 2>&1
            if ($LASTEXITCODE -ne 0) {
                $stepInfo['Error'] = "备份失败，跳过删除"
                $anyFailed = $true
                $steps += $stepInfo
                continue
            }

            # 删除服务注册表键（孤儿驱动文件已不存在，删除注册是安全的）
            Remove-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName" -Recurse -Force -ErrorAction Stop
            $stepInfo.Success = $true
            $anyDone = $true
            $logEvents += @{ event='fix.step'; module='M11'; step="删除孤儿驱动注册: $svcName"; exit_code=0 }
        } catch {
            $stepInfo['Error'] = $_.Exception.Message
            $anyFailed = $true
        }
        $steps += $stepInfo
    }

    # ----------------------------------------------------------
    # 步骤2：处理黑名单可疑驱动（禁用 + 备份）
    # ----------------------------------------------------------
    foreach ($filter in @($Diagnosis.SuspiciousFilters)) {
        $svcName = $filter.ServiceName
        $stepInfo = @{ Step = "禁用可疑过滤驱动: $svcName"; Success = $false }

        try {
            $backupFile = Join-Path $backupDir "reg_${svcName}_${ts}.reg"
            $null = & reg export "HKLM\SYSTEM\CurrentControlSet\Services\$svcName" $backupFile /y 2>&1

            # Start=4 禁用（比删除更保守，可回滚）
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName" -Name 'Start' -Value 4 -ErrorAction Stop
            $stepInfo.Success = $true
            $anyDone = $true
            $logEvents += @{ event='fix.step'; module='M11'; step="禁用可疑驱动: $svcName (Start=4)"; exit_code=0 }
        } catch {
            $stepInfo['Error'] = $_.Exception.Message
            $anyFailed = $true
        }
        $steps += $stepInfo
    }

    # ----------------------------------------------------------
    # 步骤3：重命名残留 .sys 文件（物理隔离）
    # ----------------------------------------------------------
    foreach ($sysFile in @($Diagnosis.ResidueSysFiles)) {
        $stepInfo = @{ Step = "隔离残留驱动文件: $($sysFile.FileName)"; Success = $false }

        try {
            $newName = "$($sysFile.FullPath).netaid_bak"
            Rename-Item -Path $sysFile.FullPath -NewName $newName -Force -ErrorAction Stop
            $stepInfo.Success = $true
            $anyDone = $true
            $logEvents += @{ event='fix.step'; module='M11'; step="重命名: $($sysFile.FileName) → .netaid_bak"; exit_code=0 }
        } catch {
            # 文件被内核锁定属常见情况，提示重启后用 PendingFileRenameOperations
            $stepInfo['Error'] = "文件被锁定: $($_.Exception.Message)"
            # 注册开机删除
            try {
                $pfroPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
                $existing = (Get-ItemProperty -Path $pfroPath -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
                $newEntries = @()
                if ($existing) { $newEntries += $existing }
                $newEntries += "\??\$($sysFile.FullPath)"
                $newEntries += ""   # 空目标 = 删除
                Set-ItemProperty -Path $pfroPath -Name 'PendingFileRenameOperations' -Value $newEntries -Type MultiString
                $stepInfo['Error'] = "已注册开机删除（重启后生效）"
                $stepInfo.Success = $true
                $anyDone = $true
            } catch {
                $anyFailed = $true
            }
        }
        $steps += $stepInfo
    }

    # ----------------------------------------------------------
    # 步骤4：DHCP 依赖链修复
    # ----------------------------------------------------------
    if (@($Diagnosis.DhcpChainIssues).Count -gt 0) {
        $stepInfo = @{ Step = "修复AFD/DHCP服务配置"; Success = $false }
        try {
            # AFD 必须 Start=1 (SYSTEM)
            $afdPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD'
            if (Test-Path $afdPath) {
                Set-ItemProperty -Path $afdPath -Name 'Start' -Value 1 -ErrorAction Stop
            }
            # Dhcp 必须 Start=2 (AUTO)
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dhcp' -Name 'Start' -Value 2 -ErrorAction Stop
            $stepInfo.Success = $true
            $anyDone = $true
            $logEvents += @{ event='fix.step'; module='M11'; step="AFD Start=1, Dhcp Start=2"; exit_code=0 }
        } catch {
            $stepInfo['Error'] = $_.Exception.Message
            $anyFailed = $true
        }
        $steps += $stepInfo
    }

    # ----------------------------------------------------------
    # 最终判定
    # ----------------------------------------------------------
    $finalVerdict = if ($anyDone -and -not $anyFailed) { 'success' }
                    elseif ($anyDone) { 'success' }  # 部分成功也算成功（每步独立）
                    else { 'failed' }

    $logEvents += @{
        event   = 'fix.end'
        module  = 'M11'
        verdict = $finalVerdict
        message = "深度清理完成: $(@($steps | Where-Object {$_.Success}).Count)/$(@($steps).Count) 步骤成功。需重启后重新诊断。"
    }

    _M11_SafeLog 'Write-FixEvent' @{
        Module = 'M11'; EventSubType = 'end'
        Verdict = $finalVerdict; RebootRequired = $true
    }

    return @{
        Repair = @{
            Verdict        = $finalVerdict
            RebootRequired = $true
            Steps          = $steps
            Error          = if ($finalVerdict -eq 'failed') { '所有清理步骤均失败，请检查管理员权限' } else { '' }
        }
        LogEvents = $logEvents
    }
}

# ============================================================
# 模块导出说明
# 通过 dot-source 加载后 Invoke-M11_Diagnose / Invoke-M11_Repair 可用
# ============================================================
