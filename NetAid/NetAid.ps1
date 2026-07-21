#Requires -Version 5.1
<#
.SYNOPSIS
    断网急救箱 — Windows 网络诊断与修复工具
.DESCRIPTION
    纯 PowerShell 5.1 零依赖脚本，覆盖 10 类网络故障的诊断与自动修复。
    支持交互式菜单、命令行参数、全自动诊断修复三种工作模式。
    集成 4 个公共库 + 10 个诊断修复模块 + 完整状态机 + 修复引擎。
.NOTES
    文件编码: UTF-8 with BOM
    兼容: Windows PowerShell 5.1
    依赖: lib\Utils.ps1, lib\Logger.ps1, lib\UI.ps1, lib\Parallel.ps1
           modules\M01_Adapter.ps1 ~ M10_IPConflict.ps1
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Auto')]    [switch] $Auto,
    [Parameter(ParameterSetName = 'Check')]   [switch] $Check,
    [Parameter(ParameterSetName = 'Fix')]     [ValidateSet('adapter','dhcp','dns','route','firewall','proxy','thirdparty','winsock','hosts','ipconflict','deepclean','all')] [string[]] $Fix,
    [Parameter(ParameterSetName = 'Fix')]     [switch] $FixAll,
    [Parameter(ParameterSetName = 'Check')]
    [Parameter(ParameterSetName = 'Fix')]
    [Parameter(ParameterSetName = 'Auto')]    [string] $Log,
    [Parameter(ParameterSetName = 'Check')]
    [Parameter(ParameterSetName = 'Fix')]
    [Parameter(ParameterSetName = 'Auto')]    [ValidateSet('Console','JSON','HTML','All')] [string] $Output = 'Console',
    [Parameter(ParameterSetName = 'Check')]   [ValidateSet('adapter','dhcp','dns','route','firewall','proxy','thirdparty','winsock','hosts','ipconflict','deepclean','all')] [string] $Module = 'all',
    [switch] $Silent,
    [switch] $NoColor,
    [switch] $Help,
    [switch] $Version,
    [switch] $ListModules,
    [switch] $Report,
    [switch] $CleanLogs
)

# ============================================================
# 全局错误捕获 (Trap)
# 在脚本任何位置发生未处理异常时触发
# ============================================================
trap {
    Write-Host "[!!] 严重错误: $($_.Exception.Message)" -ForegroundColor Red
    if ($Script:LogInitialized) {
        Write-ErrorEvent -Severity "critical" -Message $_.Exception.Message -StackTrace $_.ScriptStackTrace
        Write-SessionEnd -ExitCode 99 -TotalElapsedMs ([int](((Get-Date) - $Script:StartTime).TotalMilliseconds))
        Close-Logger
    }
    exit 99
}

# ============================================================
# 第一部分：脚本初始化
# ============================================================

# --- 2.1 全局配置 ---
$Script:ScriptVersion = '1.0.0'
$Script:SessionId    = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$Script:StartTime    = Get-Date
$Script:IsAdmin      = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Script:ColorEnabled = (-not $NoColor) -and (-not $Silent)
$Script:LogDir       = if ($Log) { $Log } else { Join-Path $Script:PSScriptRoot "logs" }
$Script:DiagCache    = @{}
$Script:FixResults   = @{}
$Script:ExitCode     = 0
$Script:LogInitialized = $false

# 计算脚本所在目录 (NetAid 根目录)
if ($MyInvocation.MyCommand.Path) {
    $Script:PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $Script:PSScriptRoot = $PSScriptRoot
}

# --- 2.2 目录创建 ---
if (-not (Test-Path $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}
$Script:BackupDir = Join-Path $Script:PSScriptRoot "backups"
if (-not (Test-Path $Script:BackupDir)) {
    New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null
}

# --- 2.3 控制台编码 ---
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# --- 2.4 加载公共库 (dot-source) ---
$libDir = Join-Path $Script:PSScriptRoot "lib"
$libFiles = @("Utils.ps1", "Logger.ps1", "UI.ps1", "Parallel.ps1")
foreach ($libFile in $libFiles) {
    $libPath = Join-Path $libDir $libFile
    if (Test-Path $libPath) {
        . $libPath
    } else {
        Write-Host "[WARN] 公共库文件不存在: $libPath" -ForegroundColor Yellow
    }
}

# --- 2.5 加载诊断模块 (dot-source 全部 10 个) ---
$Script:ModuleLoadStatus = @{}
$moduleDir = Join-Path $Script:PSScriptRoot "modules"
$moduleOrder = @('M01_Adapter','M02_IP_DHCP','M03_DNS','M04_Route','M05_Firewall','M06_Proxy','M07_ThirdParty','M08_Winsock','M09_Hosts','M10_IPConflict','M11_DeepClean')
foreach ($modName in $moduleOrder) {
    $modPath = Join-Path $moduleDir "$modName.ps1"
    if (Test-Path $modPath) {
        try {
            . $modPath
            $Script:ModuleLoadStatus[$modName] = 'LOADED'
        } catch {
            Write-Host "[WARN] 模块加载失败: $modName — $_" -ForegroundColor Yellow
            $Script:ModuleLoadStatus[$modName] = 'FAILED'
        }
    } else {
        Write-Host "[WARN] 模块文件不存在: $modPath" -ForegroundColor Yellow
        $Script:ModuleLoadStatus[$modName] = 'MISSING'
    }
}

# --- 2.6 初始化日志 ---
Initialize-Logger -LogDir $Script:LogDir -SessionId $Script:SessionId -ScriptVersion $Script:ScriptVersion

# --- 2.7 PowerShell 环境检测 ---
$Script:PSLanguageMode = $ExecutionContext.SessionState.LanguageMode
if ($Script:PSLanguageMode -eq 'ConstrainedLanguage') {
    Write-Host "[WARN] PowerShell 处于 ConstrainedLanguage 模式。" -ForegroundColor Yellow
    # 检测 AppLocker / WDAC
    $appLockerRules = Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue
    if ($appLockerRules) {
        Write-Host "[INFO] 检测到 AppLocker 策略。" -ForegroundColor Gray
    }
}

# --- 2.8 远程会话检测 ---
$Script:IsRemoteSession = $false
if ($env:SSH_CONNECTION) { $Script:IsRemoteSession = $true }
if ($env:REMOTEHOST) { $Script:IsRemoteSession = $true }
try {
    $sessionId = (Get-Process -Id $pid).SessionId
    if ($sessionId -ne 0) {
        # 物理控制台 SessionId 通常是 1，服务是 0。
        # 但我们无法可靠区分远程桌面和物理控制台，仅作标记。
        # 严格判断仅基于环境变量。
    }
} catch {
    # 忽略
}

# --- 2.9 写入会话开始日志 ---
$osInfo = Get-OSVersion
$osDisplay = $osInfo.Name
if ($osInfo.DisplayVersion) {
    $osDisplay = "$($osInfo.Name) $($osInfo.DisplayVersion)"
} elseif ($osInfo.Version) {
    $osDisplay = "$($osInfo.Name) $($osInfo.Version)"
}
Write-SessionStart -HostName $env:COMPUTERNAME -OS $osDisplay -Version $Script:ScriptVersion -Elevated $Script:IsAdmin -LanguageMode $Script:PSLanguageMode

# ============================================================
# 第二部分：特殊参数快速处理
# ============================================================

# --- -Help: 显示帮助文本后退出 ---
if ($Help) {
    Show-HelpText
    exit 0
}

# --- -Version: 显示版本信息后退出 ---
if ($Version) {
    Write-Host "NetAid v$Script:ScriptVersion" -ForegroundColor Cyan
    exit 0
}

# --- -ListModules: 列出所有诊断修复模块 ---
if ($ListModules) {
    Write-Host ""
    Write-Host "NetAid 诊断修复模块列表:" -ForegroundColor Cyan
    Write-Host "============================" -ForegroundColor Cyan
    Write-Host ""
    $moduleDisplay = @(
        @{Code='M01'; ShortName='adapter';    DisplayName='网络适配器状态检测';    FileName='M01_Adapter.ps1'}
        @{Code='M02'; ShortName='dhcp';       DisplayName='IP配置与DHCP检测';       FileName='M02_IP_DHCP.ps1'}
        @{Code='M03'; ShortName='dns';        DisplayName='DNS解析测试';             FileName='M03_DNS.ps1'}
        @{Code='M04'; ShortName='route';      DisplayName='路由表检查';              FileName='M04_Route.ps1'}
        @{Code='M05'; ShortName='firewall';   DisplayName='防火墙规则检测';          FileName='M05_Firewall.ps1'}
        @{Code='M06'; ShortName='proxy';      DisplayName='代理残留检测';            FileName='M06_Proxy.ps1'}
        @{Code='M07'; ShortName='thirdparty'; DisplayName='第三方残留检测';          FileName='M07_ThirdParty.ps1'}
        @{Code='M08'; ShortName='winsock';    DisplayName='Winsock/协议栈检测';      FileName='M08_Winsock.ps1'}
        @{Code='M09'; ShortName='hosts';      DisplayName='hosts文件劫持检测';       FileName='M09_Hosts.ps1'}
        @{Code='M10'; ShortName='ipconflict'; DisplayName='IP冲突检测';              FileName='M10_IPConflict.ps1'}
        @{Code='M11'; ShortName='deepclean';  DisplayName='深度残留检测(内核级)';    FileName='M11_DeepClean.ps1'}
    )
    foreach ($mod in $moduleDisplay) {
        $status = 'OK'
        $modFileName = $mod.FileName -replace '\.ps1$',''
        if ($Script:ModuleLoadStatus.ContainsKey($modFileName)) {
            $loadState = $Script:ModuleLoadStatus[$modFileName]
            if ($loadState -ne 'LOADED') { $status = $loadState }
        } else {
            $status = 'UNKNOWN'
        }
        $statusColor = 'Green'
        if ($status -ne 'OK') { $statusColor = 'Yellow' }
        if ($Script:ColorEnabled) {
            Write-Host "  $($mod.Code)  " -ForegroundColor White -NoNewline
            Write-Host "$($mod.ShortName.PadRight(12))" -ForegroundColor Magenta -NoNewline
            Write-Host "$($mod.DisplayName.PadRight(22))" -ForegroundColor White -NoNewline
            Write-Host "[$status]" -ForegroundColor $statusColor
        } else {
            Write-Output "  $($mod.Code)  $($mod.ShortName.PadRight(12))$($mod.DisplayName.PadRight(22))[$status]"
        }
    }
    Write-Host ""
    Write-Host "用法示例: NetAid -Check -Module dns     # 仅诊断DNS" -ForegroundColor DarkGray
    Write-Host "用法示例: NetAid -Fix dns,hosts         # 修复DNS和hosts" -ForegroundColor DarkGray
    Write-Host "用法示例: NetAid -FixAll                # 修复所有模块" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# --- -CleanLogs: 清理旧日志后退出 ---
if ($CleanLogs) {
    $logDir = if ($Log) { $Log } else { Join-Path $Script:PSScriptRoot "logs" }
    if (-not (Test-Path $logDir)) {
        Write-Host "日志目录不存在: $logDir" -ForegroundColor Yellow
        exit 0
    }
    Write-Host "日志目录: $logDir" -ForegroundColor Cyan
    $statsBefore = @{ FileCount = 0; SizeMB = 0; MaxAgeDays = 0 }
    $files = @(Get-ChildItem -Path $logDir -Recurse -File -ErrorAction SilentlyContinue)
    $statsBefore['FileCount'] = $files.Count
    $statsBefore['SizeMB'] = [math]::Round((($files | Measure-Object -Property Length -Sum).Sum) / 1MB, 2)
    Write-Host "清理前: $($statsBefore.FileCount) 个文件, $($statsBefore.SizeMB) MB" -ForegroundColor White
    Write-Host "清理 30 天前的日志..." -ForegroundColor Gray
    # 临时初始化 logger 以使用 Remove-OldLogs
    $Script:LogPath = $logDir
    $result = Remove-OldLogs -OlderThanDays 30
    Write-Host "已删除 $($result.DeletedCount) 个文件，释放 $($result.FreedMB) MB" -ForegroundColor Green
    exit 0
}

# ============================================================
# 第三部分：核心函数定义
# ============================================================

# --- 辅助：获取操作系统信息的显示字符串 ---
function Get-OSDisplayString {
    [CmdletBinding()]
    param()
    $info = Get-OSVersion
    if ($info.DisplayVersion) {
        return "$($info.Name) $($info.DisplayVersion) (Build $($info.Build))"
    } elseif ($info.Version) {
        return "$($info.Name) $($info.Version)"
    }
    return "Unknown"
}

# --- 辅助：根据模块短名获取对应的诊断函数名 ---
function Get-DiagnosisFunctionName {
    [CmdletBinding()]
    param([string]$ModuleShortName)
    $fileMap = $Script:ModuleMap
    if (-not $fileMap -or -not $fileMap.ContainsKey($ModuleShortName)) {
        return $null
    }
    $fileName = $fileMap[$ModuleShortName]
    $code = $fileName -replace '^M(\d+)_.*$','M$1'
    return "Invoke-${code}_Diagnose"
}

# --- 辅助：根据模块短名获取对应的修复函数名 ---
function Get-RepairFunctionName {
    [CmdletBinding()]
    param([string]$ModuleShortName)
    $fileMap = $Script:ModuleMap
    if (-not $fileMap -or -not $fileMap.ContainsKey($ModuleShortName)) {
        return $null
    }
    $fileName = $fileMap[$ModuleShortName]
    $code = $fileName -replace '^M(\d+)_.*$','M$1'
    return "Invoke-${code}_Repair"
}

# --- 辅助：根据诊断缓存构建上下文参数 ---
function Build-Context {
    [CmdletBinding()]
    param(
        [string]$Module,
        [hashtable]$DiagCache
    )
    $ctx = @{}
    switch ($Module) {
        'M02' {
            if ($DiagCache.ContainsKey('M01') -and $DiagCache['M01'].ContainsKey('Adapters')) {
                $ctx['Adapters'] = $DiagCache['M01']['Adapters']
            }
        }
        'M03' {
            if ($DiagCache.ContainsKey('M02') -and $DiagCache['M02'].ContainsKey('IPv4')) {
                $ctx['DnsServers'] = $DiagCache['M02']['IPv4']['DnsServers']
            }
            if ($DiagCache.ContainsKey('M02') -and $DiagCache['M02'].ContainsKey('IPv6_Enabled')) {
                $ctx['IPv6_Enabled'] = $DiagCache['M02']['IPv6_Enabled']
            }
        }
        'M04' {
            if ($DiagCache.ContainsKey('M02') -and $DiagCache['M02'].ContainsKey('IPv4')) {
                $ctx['DefaultGateways'] = $DiagCache['M02']['IPv4']['DefaultGateway']
            }
            if ($DiagCache.ContainsKey('M02') -and $DiagCache['M02'].ContainsKey('IPv6_Enabled')) {
                $ctx['IPv6_Enabled'] = $DiagCache['M02']['IPv6_Enabled']
            }
        }
        'M10' {
            if ($DiagCache.ContainsKey('M02') -and $DiagCache['M02'].ContainsKey('IPv4')) {
                $ctx['IPv4'] = @($DiagCache['M02']['IPv4'])
            }
        }
        'M08' {
            $ctx['DiagCache'] = $DiagCache
        }
        default {
            $ctx = @{}
        }
    }
    return $ctx
}

# ============================================================
# 诊断统计: Get-DiagnosisStats
# ============================================================
function Get-DiagnosisStats {
    [CmdletBinding()]
    param([hashtable]$DiagCache)
    $total = 0; $pass = 0; $warn = 0; $fail = 0; $critical = 0; $unknown = 0; $skip = 0
    $moduleOrder = @('M01','M02','M03','M04','M05','M06','M07','M08','M09','M10','M11')
    foreach ($m in $moduleOrder) {
        if ($DiagCache.ContainsKey($m)) {
            $total++
            $verdict = if ($DiagCache[$m].ContainsKey('Verdict')) { $DiagCache[$m]['Verdict'] } else { 'UNKNOWN' }
            if ($verdict -eq 'PASS') {
                $pass++
            } elseif ($verdict -eq 'WARN') {
                $warn++
            } elseif ($verdict -eq 'FAIL') {
                $fail++
                $critical++
            } elseif ($verdict -eq 'TIMEOUT') {
                $fail++
            } else {
                $unknown++
            }
        }
    }
    return @{
        Total    = $total
        Pass     = $pass
        Warn     = $warn
        Fail     = $fail
        Critical = $critical
        Unknown  = $unknown
        Skip     = $skip
    }
}

# ============================================================
# 修复计划生成: Build-RepairPlan
# 分析 DiagCache，为每个 FAIL/WARN 生成修复计划
# ============================================================
function Build-RepairPlan {
    [CmdletBinding()]
    param(
        [hashtable]$DiagCache,
        [hashtable]$Stats
    )

    $plan = @()
    # 用于合并去重
    $plannedModules = @{}
    $hasWinsockReset = $false
    $hasDhcpRenew = $false
    $hasFirewallReset = $false

    # 模块代码到诊断数据的快速索引
    $diagMap = @{
        'M01' = if ($DiagCache.ContainsKey('M01')) { $DiagCache['M01'] } else { $null }
        'M02' = if ($DiagCache.ContainsKey('M02')) { $DiagCache['M02'] } else { $null }
        'M03' = if ($DiagCache.ContainsKey('M03')) { $DiagCache['M03'] } else { $null }
        'M04' = if ($DiagCache.ContainsKey('M04')) { $DiagCache['M04'] } else { $null }
        'M05' = if ($DiagCache.ContainsKey('M05')) { $DiagCache['M05'] } else { $null }
        'M06' = if ($DiagCache.ContainsKey('M06')) { $DiagCache['M06'] } else { $null }
        'M07' = if ($DiagCache.ContainsKey('M07')) { $DiagCache['M07'] } else { $null }
        'M08' = if ($DiagCache.ContainsKey('M08')) { $DiagCache['M08'] } else { $null }
        'M09' = if ($DiagCache.ContainsKey('M09')) { $DiagCache['M09'] } else { $null }
        'M10' = if ($DiagCache.ContainsKey('M10')) { $DiagCache['M10'] } else { $null }
        'M11' = if ($DiagCache.ContainsKey('M11')) { $DiagCache['M11'] } else { $null }
    }

    # 判断是否需要修复的条件
    $needsRepair = @{}
    foreach ($key in $diagMap.Keys) {
        $diag = $diagMap[$key]
        if ($null -ne $diag) {
            $v = $diag.Verdict
            if ($v -eq 'FAIL' -or $v -eq 'WARN') {
                $needsRepair[$key] = $diag
            }
        }
    }

    # L1 规则: hosts劫持、代理残留 (自动执行，无风险)
    if ($needsRepair.ContainsKey('M09')) {
        $plan += @{
            Level     = 'L1'
            Module    = 'M09'
            Trigger   = 'hosts文件劫持'
            Function  = 'Invoke-M09_Repair'
            Diagnosis = $needsRepair['M09']
        }
        $plannedModules['M09'] = $true
    }
    if ($needsRepair.ContainsKey('M06')) {
        $plan += @{
            Level     = 'L1'
            Module    = 'M06'
            Trigger   = '代理残留'
            Function  = 'Invoke-M06_Repair'
            Diagnosis = $needsRepair['M06']
        }
        $plannedModules['M06'] = $true
    }

    # L2 规则: DHCP配置、DNS解析、路由问题、IP冲突 (低风险自动执行)
    # 合并规则: R02_DhcpRenew 可覆盖 M10-IP冲突修复
    if ($needsRepair.ContainsKey('M02')) {
        $plan += @{
            Level     = 'L2'
            Module    = 'M02'
            Trigger   = 'IP配置/DHCP异常'
            Function  = 'Invoke-M02_Repair'
            Diagnosis = $needsRepair['M02']
        }
        $plannedModules['M02'] = $true
        $hasDhcpRenew = $true
    }
    if ($needsRepair.ContainsKey('M03')) {
        $plan += @{
            Level     = 'L2'
            Module    = 'M03'
            Trigger   = 'DNS解析失败'
            Function  = 'Invoke-M03_Repair'
            Diagnosis = $needsRepair['M03']
        }
        $plannedModules['M03'] = $true
    }
    if ($needsRepair.ContainsKey('M04')) {
        $plan += @{
            Level     = 'L2'
            Module    = 'M04'
            Trigger   = '路由表异常'
            Function  = 'Invoke-M04_Repair'
            Diagnosis = $needsRepair['M04']
        }
        $plannedModules['M04'] = $true
    }
    # M10: 仅当 M02 未被修复时才独立修复 IP冲突
    if ($needsRepair.ContainsKey('M10') -and (-not $plannedModules.ContainsKey('M10'))) {
        if (-not $hasDhcpRenew) {
            $plan += @{
                Level     = 'L2'
                Module    = 'M10'
                Trigger   = 'IP地址冲突'
                Function  = 'Invoke-M10_Repair'
                Diagnosis = $needsRepair['M10']
            }
            $plannedModules['M10'] = $true
        }
    }

    # L3 规则: 防火墙干扰、Winsock/协议栈异常 (需确认)
    # 合并规则: R05_FirewallReset 可覆盖 M07-部分WFP过滤器
    if ($needsRepair.ContainsKey('M05')) {
        $plan += @{
            Level     = 'L3'
            Module    = 'M05'
            Trigger   = '防火墙规则异常'
            Function  = 'Invoke-M05_Repair'
            Diagnosis = $needsRepair['M05']
        }
        $plannedModules['M05'] = $true
        $hasFirewallReset = $true
    }
    if ($needsRepair.ContainsKey('M08')) {
        $plan += @{
            Level     = 'L3'
            Module    = 'M08'
            Trigger   = 'Winsock/协议栈异常'
            Function  = 'Invoke-M08_Repair'
            Diagnosis = $needsRepair['M08']
        }
        $plannedModules['M08'] = $true
        $hasWinsockReset = $true
    }

    # L4a 规则: 适配器/驱动问题、第三方残留 (高风险，需二次确认)
    # 合并规则: R08_WinsockReset 可覆盖 M07-LSP 清理
    if ($needsRepair.ContainsKey('M01')) {
        $plan += @{
            Level     = 'L4a'
            Module    = 'M01'
            Trigger   = '适配器/驱动异常'
            Function  = 'Invoke-M01_Repair'
            Diagnosis = $needsRepair['M01']
        }
        $plannedModules['M01'] = $true
    }
    # M07: 仅当未被其他修复完全覆盖时才独立修复
    if ($needsRepair.ContainsKey('M07') -and (-not $plannedModules.ContainsKey('M07'))) {
        $skipM07 = $false
        # M08(Winsock重置)覆盖M07的LSP清理
        $lspCovered = $hasWinsockReset
        # M05(防火墙重置)覆盖M07的WFP过滤器
        $wfpCovered = $hasFirewallReset
        # 只有LSP和WFP都被其他修复覆盖时才跳过M07
        if ($lspCovered -and $wfpCovered) {
            $skipM07 = $true
        }
        if (-not $skipM07) {
            $plan += @{
                Level     = 'L4a'
                Module    = 'M07'
                Trigger   = '第三方残留驱动/Provider'
                Function  = 'Invoke-M07_Repair'
                Diagnosis = $needsRepair['M07']
            }
            $plannedModules['M07'] = $true
        }
    }

    # L4b 规则: M11 深度残留（内核级 NDIS 过滤驱动，最高风险，需二次确认）
    if ($needsRepair.ContainsKey('M11')) {
        $plan += @{
            Level     = 'L4a'
            Module    = 'M11'
            Trigger   = '内核级NDIS过滤驱动残留/DHCP依赖链损坏'
            Function  = 'Invoke-M11_Repair'
            Diagnosis = $needsRepair['M11']
        }
        $plannedModules['M11'] = $true
    }

    return $plan
}

# ============================================================
# 执行单个修复: Execute-SingleRepair
# ============================================================
function Execute-SingleRepair {
    [CmdletBinding()]
    param([hashtable]$Item)
    try {
        $funcName = $Item.Function
        if (-not (Get-Command $funcName -ErrorAction SilentlyContinue)) {
            return @{
                Module    = $Item.Module
                Repair    = @{ Verdict = 'failed'; Error = "修复函数不存在: $funcName" }
                LogEvents = @(@{
                    event    = 'error'
                    severity = 'high'
                    message  = "修复函数不存在: $funcName ($($Item.Module))"
                })
            }
        }
        $result = & $funcName -Diagnosis $Item.Diagnosis
        return @{
            Module    = $Item.Module
            Repair    = $result.Repair
            LogEvents = $result.LogEvents
        }
    } catch {
        return @{
            Module    = $Item.Module
            Repair    = @{ Verdict = 'failed'; Error = $_.Exception.Message }
            LogEvents = @(@{
                event        = 'error'
                severity     = 'high'
                message      = "修复失败: $($Item.Module) — $($_.Exception.Message)"
                stack_trace  = $_.ScriptStackTrace
            })
        }
    }
}

# ============================================================
# 修复流水线: Invoke-RepairPipeline
# ============================================================
function Invoke-RepairPipeline {
    [CmdletBinding()]
    param(
        [array]$RepairPlan,
        [switch]$Interactive
    )

    $results = @()
    $rebootRequired = $false
    $repairLogEvents = @()
    $totalItems = $RepairPlan.Count

    # --- 保存修复前网络环境快照 ---
    try {
        $snapBefore = Save-NetworkSnapshot -SnapshotDir $Script:LogDir -Tag 'before_repair'
        if ($snapBefore) {
            Write-Host "[i] 修复前快照: $(Split-Path $snapBefore -Leaf)" -ForegroundColor DarkGray
            $repairLogEvents += @{ event='fix.step'; module='PIPELINE'; step='修复前快照'; output=$snapBefore; exit_code=0 }
        }
    } catch { }

    # 按级别分组
    $l1Items  = @($RepairPlan | Where-Object { $_.Level -eq 'L1' })
    $l2Items  = @($RepairPlan | Where-Object { $_.Level -eq 'L2' })
    $l3Items  = @($RepairPlan | Where-Object { $_.Level -eq 'L3' })
    $l4Items  = @($RepairPlan | Where-Object { $_.Level -match 'L4' })

    $progressCount = 0

    # --- L1: 自动执行（无风险，无需确认） ---
    foreach ($item in $l1Items) {
        $progressCount++
        Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status "修复中..."
        $result = Execute-SingleRepair -Item $item
        $results += $result
        if ($result.LogEvents) {
            $repairLogEvents += $result.LogEvents
        }
        if ($result.Repair.RebootRequired) { $rebootRequired = $true }
        $statusText = $result.Repair.Verdict
        if ($statusText -eq 'success') { $statusText = '成功' }
        elseif ($statusText -eq 'failed') { $statusText = '失败' }
        elseif ($statusText -eq 'skipped') { $statusText = '跳过' }
        Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status $statusText
    }

    # --- L2: 自动执行（低风险，远程会话检测） ---
    foreach ($item in $l2Items) {
        $progressCount++
        Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status "修复中..."
        # 远程会话保护：标记远程会话信息
        if ($Script:IsRemoteSession) {
            $item.Diagnosis.IsRemoteSession = $true
        }
        $result = Execute-SingleRepair -Item $item
        $results += $result
        if ($result.LogEvents) {
            $repairLogEvents += $result.LogEvents
        }
        if ($result.Repair.RebootRequired) { $rebootRequired = $true }
        $statusText = $result.Repair.Verdict
        if ($statusText -eq 'success') { $statusText = '成功' }
        elseif ($statusText -eq 'failed') { $statusText = '失败' }
        elseif ($statusText -eq 'skipped') { $statusText = '跳过' }
        Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status $statusText
    }

    # --- L3: 需用户确认（中风险） ---
    if ($l3Items.Count -gt 0) {
        if ($Interactive) {
            $confirmed = Show-FixConfirmation -Problems $l3Items -LevelCount @{L3 = $l3Items.Count}
        } else {
            # 非交互模式：自动确认
            $confirmed = $true
        }
        if ($confirmed) {
            Write-Host "[INFO] L3 修复前建议创建系统还原点。" -ForegroundColor Magenta
            foreach ($item in $l3Items) {
                $progressCount++
                Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status "修复中..."
                $result = Execute-SingleRepair -Item $item
                $results += $result
                if ($result.LogEvents) {
                    $repairLogEvents += $result.LogEvents
                }
                if ($result.Repair.RebootRequired) { $rebootRequired = $true }
                $statusText = $result.Repair.Verdict
                if ($statusText -eq 'success') { $statusText = '成功' }
                elseif ($statusText -eq 'failed') { $statusText = '失败' }
                Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status $statusText
            }
        } else {
            foreach ($item in $l3Items) {
                $progressCount++
                $results += @{
                    Module    = $item.Module
                    Repair    = @{ Verdict = 'skipped'; Reason = '用户跳过' }
                    LogEvents = @()
                }
                Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status "跳过"
            }
        }
    }

    # --- L4a: 需用户二次确认（高风险） ---
    if ($l4Items.Count -gt 0) {
        if ($Interactive) {
            $confirmed = Show-FixConfirmation -Problems $l4Items -LevelCount @{L4a = $l4Items.Count}
        } else {
            # 非交互模式：自动确认
            $confirmed = $true
        }
        if ($confirmed) {
            Write-Host "[WARN] L4修复可能需重启，已自动备份注册表。" -ForegroundColor Magenta
            foreach ($item in $l4Items) {
                $progressCount++
                Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status "修复中..."
                $result = Execute-SingleRepair -Item $item
                $results += $result
                if ($result.LogEvents) {
                    $repairLogEvents += $result.LogEvents
                }
                if ($result.Repair.RebootRequired) { $rebootRequired = $true }
                $statusText = $result.Repair.Verdict
                if ($statusText -eq 'success') { $statusText = '成功' }
                elseif ($statusText -eq 'failed') { $statusText = '失败' }
                Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status $statusText
            }
        } else {
            foreach ($item in $l4Items) {
                $progressCount++
                $results += @{
                    Module    = $item.Module
                    Repair    = @{ Verdict = 'skipped'; Reason = '用户跳过' }
                    LogEvents = @()
                }
                Show-RepairProgress -Current $progressCount -Total $totalItems -ModuleName $item.Module -Status "跳过"
            }
        }
    }

    # --- 保存修复后网络环境快照 ---
    try {
        $snapAfter = Save-NetworkSnapshot -SnapshotDir $Script:LogDir -Tag 'after_repair'
        if ($snapAfter) {
            Write-Host "[i] 修复后快照: $(Split-Path $snapAfter -Leaf)" -ForegroundColor DarkGray
            $repairLogEvents += @{ event='fix.step'; module='PIPELINE'; step='修复后快照'; output=$snapAfter; exit_code=0 }
        }
    } catch { }

    return @{
        Results        = $results
        RebootRequired = $rebootRequired
        LogEvents      = $repairLogEvents
    }
}

# ============================================================
# 修复后验证: Invoke-VerifyRepairs
# ============================================================
function Invoke-VerifyRepairs {
    [CmdletBinding()]
    param([array]$RepairResults)

    $failedAfterRepair = @()
    $totalSuccess = 0
    $totalFailed = 0

    foreach ($result in $RepairResults) {
        if ($result.Repair.Verdict -eq 'success') {
            $moduleName = $result.Module
            $diagFunc = Get-DiagnosisFunctionName -ModuleShortName $moduleName.ToLower()
            if ($null -eq $diagFunc) {
                # 无法找到对应的诊断函数，尝试直接构建函数名
                $diagFunc = "Invoke-${moduleName}_Diagnose"
            }
            if (Get-Command $diagFunc -ErrorAction SilentlyContinue) {
                $newDiag = & $diagFunc -Context (Build-Context -Module $moduleName -DiagCache $Script:DiagCache)
                if ($newDiag.Diagnosis.Verdict -eq 'FAIL') {
                    $failedAfterRepair += $moduleName
                    $totalFailed++
                } else {
                    $totalSuccess++
                }
            } else {
                # 无法验证，算作成功
                $totalSuccess++
            }
        } elseif ($result.Repair.Verdict -eq 'failed') {
            $totalFailed++
        }
    }

    $passed = ($failedAfterRepair.Count -eq 0)
    return @{
        Passed        = $passed
        FailedModules = $failedAfterRepair
        TotalSuccess  = $totalSuccess
        TotalFailed   = $totalFailed
    }
}

# ============================================================
# 全面诊断引擎: Invoke-FullDiagnosis
# Phase 0-3 编排
# ============================================================
function Invoke-FullDiagnosis {
    [CmdletBinding()]
    param([switch]$Interactive)

    Show-ProgressHeader -Title "全面诊断进行中..."
    $phaseStart = Get-Date
    $allResults = @{}

    # --- 保存诊断前网络环境快照 ---
    try {
        $snapFile = Save-NetworkSnapshot -SnapshotDir $Script:LogDir -Tag 'before_diag'
        if ($snapFile) {
            Write-Host "[i] 网络环境快照已保存: $(Split-Path $snapFile -Leaf)" -ForegroundColor DarkGray
        }
    } catch { }

    # 获取总模块数用于进度显示
    $totalModules = 11

    # ============================================================
    # Phase 0: M01, M05, M06, M07, M09 (5个并行/顺序，无相互依赖)
    # ============================================================

    # M01 - 适配器状态检测
    Write-ProgressLine -Current 1 -Total $totalModules -ModuleName "适配器状态检测" -Status "..."
    try {
        $m01Result = Invoke-M01_Diagnose -Context @{}
        $Script:DiagCache['M01'] = $m01Result.Diagnosis
        $m01VerdictText = $m01Result.Diagnosis.Verdict
        if ($m01VerdictText -eq 'PASS') { $m01VerdictText = '正常' }
        elseif ($m01VerdictText -eq 'FAIL') { $m01VerdictText = '失败' }
        elseif ($m01VerdictText -eq 'WARN') { $m01VerdictText = '警告' }
        Write-ProgressLine -Current 1 -Total $totalModules -ModuleName "适配器状态检测" -Status $m01VerdictText
    } catch {
        $Script:DiagCache['M01'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-DiagnosisEvent -Module 'M01' -Verdict 'FAIL' -ElapsedMs 0 -ExtraFields @{ error = $_.Exception.Message }
        Write-ErrorEvent -Severity 'high' -Message "M01 适配器诊断异常: $($_.Exception.Message)" -StackTrace $_.ScriptStackTrace
        Write-ProgressLine -Current 1 -Total $totalModules -ModuleName "适配器状态检测" -Status "失败"
    }

    # M05 - 防火墙规则检测
    Write-ProgressLine -Current 5 -Total $totalModules -ModuleName "防火墙规则检测" -Status "..."
    try {
        $m05Result = Invoke-M05_Diagnose -Context @{}
        $Script:DiagCache['M05'] = $m05Result.Diagnosis
        $m05VerdictText = $m05Result.Diagnosis.Verdict
        if ($m05VerdictText -eq 'PASS') { $m05VerdictText = '正常' }
        elseif ($m05VerdictText -eq 'FAIL') { $m05VerdictText = '失败' }
        elseif ($m05VerdictText -eq 'WARN') { $m05VerdictText = '警告' }
        Write-ProgressLine -Current 5 -Total $totalModules -ModuleName "防火墙规则检测" -Status $m05VerdictText
    } catch {
        $Script:DiagCache['M05'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-ProgressLine -Current 5 -Total $totalModules -ModuleName "防火墙规则检测" -Status "失败"
    }

    # M06 - 代理残留检测
    Write-ProgressLine -Current 6 -Total $totalModules -ModuleName "代理残留检测" -Status "..."
    try {
        $m06Result = Invoke-M06_Diagnose -Context @{}
        $Script:DiagCache['M06'] = $m06Result.Diagnosis
        $m06VerdictText = $m06Result.Diagnosis.Verdict
        if ($m06VerdictText -eq 'PASS') { $m06VerdictText = '正常' }
        elseif ($m06VerdictText -eq 'FAIL') { $m06VerdictText = '失败' }
        elseif ($m06VerdictText -eq 'WARN') { $m06VerdictText = '警告' }
        Write-ProgressLine -Current 6 -Total $totalModules -ModuleName "代理残留检测" -Status $m06VerdictText
    } catch {
        $Script:DiagCache['M06'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-ProgressLine -Current 6 -Total $totalModules -ModuleName "代理残留检测" -Status "失败"
    }

    # M07 - 第三方残留检测
    Write-ProgressLine -Current 7 -Total $totalModules -ModuleName "第三方残留检测" -Status "..."
    try {
        $m07Result = Invoke-M07_Diagnose -Context @{}
        $Script:DiagCache['M07'] = $m07Result.Diagnosis
        $m07VerdictText = $m07Result.Diagnosis.Verdict
        if ($m07VerdictText -eq 'PASS') { $m07VerdictText = '正常' }
        elseif ($m07VerdictText -eq 'FAIL') { $m07VerdictText = '失败' }
        elseif ($m07VerdictText -eq 'WARN') { $m07VerdictText = '警告' }
        Write-ProgressLine -Current 7 -Total $totalModules -ModuleName "第三方残留检测" -Status $m07VerdictText
    } catch {
        $Script:DiagCache['M07'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-DiagnosisEvent -Module 'M07' -Verdict 'FAIL' -ElapsedMs 0 -ExtraFields @{ error = $_.Exception.Message }
        Write-ErrorEvent -Severity 'high' -Message "M07 第三方残留诊断异常: $($_.Exception.Message)" -StackTrace $_.ScriptStackTrace
        Write-ProgressLine -Current 7 -Total $totalModules -ModuleName "第三方残留检测" -Status "失败"
    }

    # M09 - hosts文件劫持
    Write-ProgressLine -Current 9 -Total $totalModules -ModuleName "hosts文件劫持" -Status "..."
    try {
        $m09Result = Invoke-M09_Diagnose -Context @{}
        $Script:DiagCache['M09'] = $m09Result.Diagnosis
        $m09VerdictText = $m09Result.Diagnosis.Verdict
        if ($m09VerdictText -eq 'PASS') { $m09VerdictText = '正常' }
        elseif ($m09VerdictText -eq 'FAIL') { $m09VerdictText = '失败' }
        elseif ($m09VerdictText -eq 'WARN') { $m09VerdictText = '警告' }
        Write-ProgressLine -Current 9 -Total $totalModules -ModuleName "hosts文件劫持" -Status $m09VerdictText
    } catch {
        $Script:DiagCache['M09'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-ProgressLine -Current 9 -Total $totalModules -ModuleName "hosts文件劫持" -Status "失败"
    }

    # ============================================================
    # Phase 1: M02 (串行，依赖 M01 的 Adapters 数据)
    # ============================================================
    Write-ProgressLine -Current 2 -Total $totalModules -ModuleName "IP配置与DHCP" -Status "..."
    try {
        $m02Context = @{}
        if ($Script:DiagCache.ContainsKey('M01') -and $Script:DiagCache['M01'].ContainsKey('Adapters')) {
            $m02Context['Adapters'] = $Script:DiagCache['M01']['Adapters']
        }
        $m02Result = Invoke-M02_Diagnose -Context $m02Context
        $Script:DiagCache['M02'] = $m02Result.Diagnosis
        $m02VerdictText = $m02Result.Diagnosis.Verdict
        if ($m02VerdictText -eq 'PASS') { $m02VerdictText = '正常' }
        elseif ($m02VerdictText -eq 'FAIL') { $m02VerdictText = '失败' }
        elseif ($m02VerdictText -eq 'WARN') { $m02VerdictText = '警告' }
        Write-ProgressLine -Current 2 -Total $totalModules -ModuleName "IP配置与DHCP" -Status $m02VerdictText
    } catch {
        $Script:DiagCache['M02'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-ProgressLine -Current 2 -Total $totalModules -ModuleName "IP配置与DHCP" -Status "失败"
    }

    # ============================================================
    # Phase 2: M03, M04, M10 (3个可并行，依赖 M02 的数据)
    # ============================================================
    $phase2Context = @{}
    if ($Script:DiagCache.ContainsKey('M02')) {
        $m02Diag = $Script:DiagCache['M02']
        if ($m02Diag.ContainsKey('IPv4')) {
            $phase2Context['DnsServers'] = $m02Diag['IPv4']['DnsServers']
            $phase2Context['DefaultGateways'] = $m02Diag['IPv4']['DefaultGateway']
            $phase2Context['LocalIPv4'] = $m02Diag['IPv4']['Address']
        }
        if ($m02Diag.ContainsKey('IPv6_Enabled')) {
            $phase2Context['IPv6_Enabled'] = $m02Diag['IPv6_Enabled']
        }
    }

    # M03 - DNS解析测试
    Write-ProgressLine -Current 3 -Total $totalModules -ModuleName "DNS解析测试" -Status "..."
    try {
        $m03Ctx = @{}
        if ($phase2Context.ContainsKey('DnsServers')) { $m03Ctx['DnsServers'] = $phase2Context['DnsServers'] }
        if ($phase2Context.ContainsKey('IPv6_Enabled')) { $m03Ctx['IPv6_Enabled'] = $phase2Context['IPv6_Enabled'] }
        $m03Result = Invoke-M03_Diagnose -Context $m03Ctx
        $Script:DiagCache['M03'] = $m03Result.Diagnosis
        $m03VerdictText = $m03Result.Diagnosis.Verdict
        if ($m03VerdictText -eq 'PASS') { $m03VerdictText = '正常' }
        elseif ($m03VerdictText -eq 'FAIL') { $m03VerdictText = '失败' }
        elseif ($m03VerdictText -eq 'WARN') { $m03VerdictText = '警告' }
        Write-ProgressLine -Current 3 -Total $totalModules -ModuleName "DNS解析测试" -Status $m03VerdictText
    } catch {
        $Script:DiagCache['M03'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-DiagnosisEvent -Module 'M03' -Verdict 'FAIL' -ElapsedMs 0 -ExtraFields @{ error = $_.Exception.Message }
        Write-ErrorEvent -Severity 'high' -Message "M03 DNS诊断异常: $($_.Exception.Message)" -StackTrace $_.ScriptStackTrace
        Write-ProgressLine -Current 3 -Total $totalModules -ModuleName "DNS解析测试" -Status "失败"
    }

    # M04 - 路由表检查
    Write-ProgressLine -Current 4 -Total $totalModules -ModuleName "路由表检查" -Status "..."
    try {
        $m04Ctx = @{}
        if ($phase2Context.ContainsKey('DefaultGateways')) { $m04Ctx['DefaultGateways'] = $phase2Context['DefaultGateways'] }
        if ($phase2Context.ContainsKey('IPv6_Enabled')) { $m04Ctx['IPv6_Enabled'] = $phase2Context['IPv6_Enabled'] }
        $m04Result = Invoke-M04_Diagnose -Context $m04Ctx
        $Script:DiagCache['M04'] = $m04Result.Diagnosis
        $m04VerdictText = $m04Result.Diagnosis.Verdict
        if ($m04VerdictText -eq 'PASS') { $m04VerdictText = '正常' }
        elseif ($m04VerdictText -eq 'FAIL') { $m04VerdictText = '失败' }
        elseif ($m04VerdictText -eq 'WARN') { $m04VerdictText = '警告' }
        Write-ProgressLine -Current 4 -Total $totalModules -ModuleName "路由表检查" -Status $m04VerdictText
    } catch {
        $Script:DiagCache['M04'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-ProgressLine -Current 4 -Total $totalModules -ModuleName "路由表检查" -Status "失败"
    }

    # M10 - IP冲突检测
    Write-ProgressLine -Current 10 -Total $totalModules -ModuleName "IP冲突检测" -Status "..."
    try {
        $m10Ctx = @{}
        if ($phase2Context.ContainsKey('LocalIPv4')) { $m10Ctx['LocalIPv4'] = $phase2Context['LocalIPv4'] }
        $m10Result = Invoke-M10_Diagnose -Context $m10Ctx
        $Script:DiagCache['M10'] = $m10Result.Diagnosis
        $m10VerdictText = $m10Result.Diagnosis.Verdict
        if ($m10VerdictText -eq 'PASS') { $m10VerdictText = '正常' }
        elseif ($m10VerdictText -eq 'FAIL') { $m10VerdictText = '失败' }
        elseif ($m10VerdictText -eq 'WARN') { $m10VerdictText = '警告' }
        Write-ProgressLine -Current 10 -Total $totalModules -ModuleName "IP冲突检测" -Status $m10VerdictText
    } catch {
        $Script:DiagCache['M10'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-DiagnosisEvent -Module 'M10' -Verdict 'FAIL' -ElapsedMs 0 -ExtraFields @{ error = $_.Exception.Message }
        Write-ErrorEvent -Severity 'high' -Message "M10 IP冲突诊断异常: $($_.Exception.Message)" -StackTrace $_.ScriptStackTrace
        Write-ProgressLine -Current 10 -Total $totalModules -ModuleName "IP冲突检测" -Status "失败"
    }

    # ============================================================
    # Phase 3: M08 (串行，依赖前序所有模块，netsh 命令互斥)
    # ============================================================
    Write-ProgressLine -Current 8 -Total $totalModules -ModuleName "Winsock/协议栈" -Status "..."
    try {
        $m08Context = @{ DiagCache = $Script:DiagCache }
        $m08Result = Invoke-M08_Diagnose -Context $m08Context
        $Script:DiagCache['M08'] = $m08Result.Diagnosis
        $m08VerdictText = $m08Result.Diagnosis.Verdict
        if ($m08VerdictText -eq 'PASS') { $m08VerdictText = '正常' }
        elseif ($m08VerdictText -eq 'FAIL') { $m08VerdictText = '失败' }
        elseif ($m08VerdictText -eq 'WARN') { $m08VerdictText = '警告' }
        Write-ProgressLine -Current 8 -Total $totalModules -ModuleName "Winsock/协议栈" -Status $m08VerdictText
    } catch {
        $Script:DiagCache['M08'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-DiagnosisEvent -Module 'M08' -Verdict 'FAIL' -ElapsedMs 0 -ExtraFields @{ error = $_.Exception.Message }
        Write-ErrorEvent -Severity 'high' -Message "M08 Winsock诊断异常: $($_.Exception.Message)" -StackTrace $_.ScriptStackTrace
        Write-ProgressLine -Current 8 -Total $totalModules -ModuleName "Winsock/协议栈" -Status "失败"
    }

    # ============================================================
    # Phase 4: M11 (串行，深度残留检测——注册表扫描密集)
    # ============================================================
    Write-ProgressLine -Current 11 -Total $totalModules -ModuleName "深度残留检测" -Status "..."
    try {
        $m11Result = Invoke-M11_Diagnose -Context @{}
        $Script:DiagCache['M11'] = $m11Result.Diagnosis
        $m11VerdictText = $m11Result.Diagnosis.Verdict
        if ($m11VerdictText -eq 'PASS') { $m11VerdictText = '正常' }
        elseif ($m11VerdictText -eq 'FAIL') { $m11VerdictText = '失败' }
        elseif ($m11VerdictText -eq 'WARN') { $m11VerdictText = '警告' }
        Write-ProgressLine -Current 11 -Total $totalModules -ModuleName "深度残留检测" -Status $m11VerdictText
    } catch {
        $Script:DiagCache['M11'] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
        Write-DiagnosisEvent -Module 'M11' -Verdict 'FAIL' -ElapsedMs 0 -ExtraFields @{ error = $_.Exception.Message }
        Write-ErrorEvent -Severity 'high' -Message "M11 深度残留诊断异常: $($_.Exception.Message)" -StackTrace $_.ScriptStackTrace
        Write-ProgressLine -Current 11 -Total $totalModules -ModuleName "深度残留检测" -Status "失败"
    }

    # --- 显示诊断摘要 ---
    $elapsed = ((Get-Date) - $phaseStart).TotalSeconds
    $stats = Get-DiagnosisStats -DiagCache $Script:DiagCache
    Write-Separator
    Show-DiagnosisSummary -Total $stats.Total -Pass $stats.Pass -Warn $stats.Warn -Fail $stats.Fail -ElapsedSec $elapsed -Critical $stats.Critical

    # --- 写入诊断汇总日志 ---
    Write-SummaryEvent -Phase "diagnosis" -Total $stats.Total -Pass $stats.Pass -Warn $stats.Warn -Fail $stats.Fail -ElapsedMs ([int]($elapsed * 1000))

    return @{
        DiagCache  = $Script:DiagCache
        Stats      = $stats
        ElapsedSec = $elapsed
    }
}

# ============================================================
# 全量修复 (用于交互式菜单选项2): Invoke-FullRepair
# ============================================================
function Invoke-FullRepair {
    [CmdletBinding()]
    param([switch]$Interactive)

    # 先运行诊断
    $diagResult = Invoke-FullDiagnosis -Interactive:$Interactive
    $stats = $diagResult.Stats

    # 如果没有问题，直接返回
    if ($stats.Fail -eq 0 -and $stats.Warn -eq 0) {
        Write-Host ""
        Write-Host "网络状态正常，无需修复。" -ForegroundColor Green
        return @{ Repaired = 0; Failed = 0; Skipped = 0; RebootRequired = $false }
    }

    # 检查管理员权限
    if (-not $Script:IsAdmin) {
        Write-Host ""
        Write-Host "修复需要管理员权限。请以管理员身份重新运行。" -ForegroundColor Red
        $Script:ExitCode = 4
        return @{ Repaired = 0; Failed = 0; Skipped = 0; RebootRequired = $false; NeedAdmin = $true }
    }

    # 生成修复计划
    $plan = Build-RepairPlan -DiagCache $Script:DiagCache -Stats $stats

    if ($plan.Count -eq 0) {
        Write-Host ""
        Write-Host "没有生成可执行的修复计划。" -ForegroundColor Yellow
        return @{ Repaired = 0; Failed = 0; Skipped = 0; RebootRequired = $false }
    }

    # 执行修复流水线
    Write-Host ""
    $pipelineResult = Invoke-RepairPipeline -RepairPlan $plan -Interactive:$Interactive

    # 验证修复
    $verifyResult = Invoke-VerifyRepairs -RepairResults $pipelineResult.Results

    # 统计修复结果
    $successCount = 0; $failedCount = 0; $skippedCount = 0
    foreach ($r in $pipelineResult.Results) {
        $v = $r.Repair.Verdict
        if ($v -eq 'success') { $successCount++ }
        elseif ($v -eq 'failed') { $failedCount++ }
        elseif ($v -eq 'skipped') { $skippedCount++ }
    }

    # 显示修复报告
    $reportData = @{
        Time           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Hostname       = $env:COMPUTERNAME
        OSVersion      = Get-OSDisplayString
        DiagTotal      = $stats.Total
        DiagPass       = $stats.Pass
        DiagWarn       = $stats.Warn
        DiagFail       = $stats.Fail
        DiagElapsed    = $diagResult.ElapsedSec
        DiagCritical   = $stats.Critical
        RepairTotal    = $plan.Count
        RepairSuccess  = $successCount
        RepairFail     = $failedCount
        RepairSkip     = $skippedCount
        FailItems      = @()
        WarnItems      = @()
        FixableCount   = $plan.Count
        Recommendations = @()
    }

    if ($pipelineResult.RebootRequired) {
        $reportData['Recommendations'] = @('部分修复需要重启后生效，建议尽快重启系统。')
    }

    Show-FinalReport -ReportData $reportData

    return @{
        Repaired       = $successCount
        Failed         = $failedCount
        Skipped        = $skippedCount
        RebootRequired = $pipelineResult.RebootRequired
        VerifyPassed   = $verifyResult.Passed
    }
}

# ============================================================
# 单项诊断 (交互式菜单选项3): Invoke-SingleModule
# ============================================================
function Invoke-SingleModule {
    [CmdletBinding()]
    param([switch]$Interactive)

    $moduleList = @(
        @{ Num=1;  Short='adapter';    Display='网络适配器状态检测' },
        @{ Num=2;  Short='dhcp';       Display='IP配置与DHCP检测' },
        @{ Num=3;  Short='dns';        Display='DNS解析测试' },
        @{ Num=4;  Short='route';      Display='路由表检查' },
        @{ Num=5;  Short='firewall';   Display='防火墙规则检测' },
        @{ Num=6;  Short='proxy';      Display='代理残留检测' },
        @{ Num=7;  Short='thirdparty'; Display='第三方残留检测' },
        @{ Num=8;  Short='winsock';    Display='Winsock/协议栈检测' },
        @{ Num=9;  Short='hosts';      Display='hosts文件劫持检测' },
        @{ Num=10; Short='ipconflict'; Display='IP冲突检测' },
        @{ Num=11; Short='deepclean';  Display='深度残留检测(NDIS过滤驱动/内核级)' }
    )

    Write-Host ""
    Write-Host "可用诊断模块 (输入数字或短名):" -ForegroundColor Cyan
    Write-Host ""
    foreach ($m in $moduleList) {
        $num = (" " + $m.Num).Substring([Math]::Max(0, (" " + $m.Num).Length - 2))
        Write-Host "  [$num] $($m.Display) ($($m.Short))" -ForegroundColor White
    }
    Write-Host ""

    $inputName = Read-Host "请选择模块 (1-11 或 短名)"
    if ([string]::IsNullOrWhiteSpace($inputName)) {
        Write-Host "已取消。" -ForegroundColor DarkGray
        return
    }

    $inputName = $inputName.Trim().ToLower()

    # 尝试按数字匹配
    if ($inputName -match '^\d+$') {
        $num = [int]$inputName
        $match = $moduleList | Where-Object { $_.Num -eq $num }
        if ($match) {
            $inputName = $match.Short
        }
    }
    $diagFunc = Get-DiagnosisFunctionName -ModuleShortName $inputName
    if ($null -eq $diagFunc) {
        Write-Host "[!!] 未知模块: $inputName" -ForegroundColor Red
        return
    }

    $code = $diagFunc -replace 'Invoke-(M\d+)_Diagnose','$1'
    Write-ProgressLine -Current 1 -Total 1 -ModuleName "$code ($inputName)" -Status "..."
    try {
        $diagResult = & $diagFunc -Context @{}
        if ($diagResult -is [hashtable] -and $diagResult.ContainsKey('Diagnosis')) {
            $verdict = $diagResult.Diagnosis.Verdict
            $verdictText = $verdict
            if ($verdict -eq 'PASS') { $verdictText = '正常' }
            elseif ($verdict -eq 'FAIL') { $verdictText = '失败' }
            elseif ($verdict -eq 'WARN') { $verdictText = '警告' }
            Write-ProgressLine -Current 1 -Total 1 -ModuleName "$code ($inputName)" -Status $verdictText
            Write-Host ""
            # 显示详细诊断信息
            $diagResult.Diagnosis | Format-List | Out-Host
        } else {
            Write-ProgressLine -Current 1 -Total 1 -ModuleName "$code ($inputName)" -Status "失败"
            Write-Host "[!!] 诊断函数返回格式无效。" -ForegroundColor Red
        }
    } catch {
        Write-ProgressLine -Current 1 -Total 1 -ModuleName "$code ($inputName)" -Status "失败"
        Write-Host "[!!] 诊断执行失败: $_" -ForegroundColor Red
    }
}

# ============================================================
# 单项修复 (交互式菜单选项4): Invoke-SingleFix
# ============================================================
function Invoke-SingleFix {
    [CmdletBinding()]
    param([switch]$Interactive)

    if (-not $Script:IsAdmin) {
        Write-Host "[!!] 修复需要管理员权限。请以管理员身份重新运行。" -ForegroundColor Red
        return
    }

    $moduleList = @(
        @{ Num=1;  Short='adapter';    Display='适配器/驱动重置';       Risk='L4a'; RiskColor='Magenta' },
        @{ Num=2;  Short='dhcp';       Display='IP/DHCP续租';           Risk='L2';  RiskColor='Yellow' },
        @{ Num=3;  Short='dns';        Display='DNS刷新';               Risk='L2';  RiskColor='Yellow' },
        @{ Num=4;  Short='route';      Display='路由表修复';            Risk='L2';  RiskColor='Yellow' },
        @{ Num=5;  Short='firewall';   Display='防火墙规则重置';        Risk='L3';  RiskColor='White' },
        @{ Num=6;  Short='proxy';      Display='代理设置清除';          Risk='L1';  RiskColor='Red' },
        @{ Num=7;  Short='thirdparty'; Display='第三方残留清理';        Risk='L4a'; RiskColor='Magenta' },
        @{ Num=8;  Short='winsock';    Display='Winsock重置';           Risk='L3';  RiskColor='White' },
        @{ Num=9;  Short='hosts';      Display='hosts文件修复';         Risk='L1';  RiskColor='Red' },
        @{ Num=10; Short='ipconflict'; Display='IP冲突修复';            Risk='L2';  RiskColor='Yellow' },
        @{ Num=11; Short='deepclean';  Display='深度残留清理(内核级)';  Risk='L4b'; RiskColor='Magenta' }
    )

    Write-Host ""
    Write-Host "可用修复模块 (输入数字或短名):" -ForegroundColor Cyan
    Write-Host ""
    foreach ($m in $moduleList) {
        $num = (" " + $m.Num).Substring([Math]::Max(0, (" " + $m.Num).Length - 2))
        if ($Script:ColorEnabled) {
            Write-Host "  [$num] $($m.Display) ($($m.Short))" -ForegroundColor White -NoNewline
            Write-Host "  [$($m.Risk)]" -ForegroundColor $m.RiskColor
        } else {
            Write-Host "  [$num] $($m.Display) ($($m.Short))  [$($m.Risk)]"
        }
    }
    Write-Host ""

    $inputName = Read-Host "请选择模块 (1-11 或 短名)"
    if ([string]::IsNullOrWhiteSpace($inputName)) {
        Write-Host "已取消。" -ForegroundColor DarkGray
        return
    }

    $inputName = $inputName.Trim().ToLower()

    # 尝试按数字匹配
    if ($inputName -match '^\d+$') {
        $num = [int]$inputName
        $match = $moduleList | Where-Object { $_.Num -eq $num }
        if ($match) {
            $inputName = $match.Short
        }
    }
    $diagFunc = Get-DiagnosisFunctionName -ModuleShortName $inputName
    $repairFunc = Get-RepairFunctionName -ModuleShortName $inputName
    if ($null -eq $diagFunc -or $null -eq $repairFunc) {
        Write-Host "[!!] 未知模块: $inputName" -ForegroundColor Red
        return
    }

    # 先诊断
    Write-Host ""
    Write-Host "[...] 正在诊断 $inputName ..." -ForegroundColor Cyan
    try {
        $diagResult = & $diagFunc -Context @{}
        $diagnosis = $diagResult.Diagnosis
        $verdict = $diagnosis.Verdict
        $verdictText = $verdict
        if ($verdict -eq 'PASS') { $verdictText = '正常' }
        elseif ($verdict -eq 'FAIL') { $verdictText = '失败' }
        elseif ($verdict -eq 'WARN') { $verdictText = '警告' }
        Write-Host "  诊断结果: $verdictText" -ForegroundColor $(if ($verdict -eq 'PASS') { 'Green' } else { 'Red' })
    } catch {
        Write-Host "[!!] 诊断失败: $_" -ForegroundColor Red
        return
    }

    if ($verdict -eq 'PASS') {
        Write-Host "  无需修复。" -ForegroundColor Green
        return
    }

    # 确认修复
    $confirmed = Confirm-UserAction -Message "确认执行修复?" -Default "Y"
    if (-not $confirmed) {
        Write-Host "已取消修复。" -ForegroundColor DarkGray
        return
    }

    # 执行修复
    Write-Host "[...] 正在修复..." -ForegroundColor Cyan
    try {
        # 修复前快照
        try {
            $snapB = Save-NetworkSnapshot -SnapshotDir $Script:LogDir -Tag "before_fix_$inputName"
            if ($snapB) { Write-Host "  [i] 修复前快照: $(Split-Path $snapB -Leaf)" -ForegroundColor DarkGray }
        } catch { }

        $repairResult = & $repairFunc -Diagnosis $diagnosis
        # 将修复事件写入日志
        if ($repairResult.LogEvents) {
            $repairResult.LogEvents | ForEach-Object { Write-JsonlLog $_ }
        }
        $repairVerdict = $repairResult.Repair.Verdict
        if ($repairVerdict -eq 'success') {
            Write-Host "  修复成功!" -ForegroundColor Green
        } elseif ($repairVerdict -eq 'skipped') {
            Write-Host "  已跳过: $($repairResult.Repair.Reason)" -ForegroundColor Yellow
        } else {
            Write-Host "  修复失败: $($repairResult.Repair.Error)" -ForegroundColor Red
        }
        if ($repairResult.Repair.RebootRequired) {
            Write-Host "  [i] 需要重启后生效。" -ForegroundColor Magenta
        }
        # 修复后快照
        try {
            $snapA = Save-NetworkSnapshot -SnapshotDir $Script:LogDir -Tag "after_fix_$inputName"
            if ($snapA) { Write-Host "  [i] 修复后快照: $(Split-Path $snapA -Leaf)" -ForegroundColor DarkGray }
        } catch { }
    } catch {
        Write-Host "[!!] 修复执行失败: $_" -ForegroundColor Red
    }
}

# ============================================================
# 生成报告 (交互式菜单选项5): Invoke-GenerateReport
# ============================================================
function Invoke-GenerateReport {
    [CmdletBinding()]
    param()

    # 如果尚未运行诊断，先运行
    if ($Script:DiagCache.Count -eq 0) {
        Write-Host "尚未运行诊断，正在自动运行..." -ForegroundColor Cyan
        $null = Invoke-FullDiagnosis
    }

    $stats = Get-DiagnosisStats -DiagCache $Script:DiagCache

    # 收集失败/警告项
    $failItems = @()
    $warnItems = @()
    $moduleDisplayNames = @{
        'M01' = '适配器状态检测'
        'M02' = 'IP配置与DHCP'
        'M03' = 'DNS解析测试'
        'M04' = '路由表检查'
        'M05' = '防火墙规则检测'
        'M06' = '代理残留检测'
        'M07' = '第三方残留检测'
        'M08' = 'Winsock/协议栈'
        'M09' = 'hosts文件劫持'
        'M10' = 'IP冲突检测'
        'M11' = '深度残留检测'
    }
    foreach ($key in $Script:DiagCache.Keys) {
        $diag = $Script:DiagCache[$key]
        $displayName = if ($moduleDisplayNames.ContainsKey($key)) { $moduleDisplayNames[$key] } else { $key }
        $v = $diag.Verdict
        if ($v -eq 'FAIL') {
            $failItems += "$displayName — $($diag.Error)"
        } elseif ($v -eq 'WARN') {
            $warnItems += $displayName
        }
    }

    $reportData = @{
        Time           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Hostname       = $env:COMPUTERNAME
        OSVersion      = Get-OSDisplayString
        DiagTotal      = $stats.Total
        DiagPass       = $stats.Pass
        DiagWarn       = $stats.Warn
        DiagFail       = $stats.Fail
        DiagElapsed    = 0
        DiagCritical   = $stats.Critical
        FailItems      = $failItems
        WarnItems      = $warnItems
        FixableCount   = $stats.Fail + $stats.Warn
        Recommendations = @(
            "NetAid -Auto  # 全自动诊断修复"
        )
    }

    Show-FinalReport -ReportData $reportData

    # 导出 JSON 报告到日志目录
    $jsonReportPath = Join-Path $Script:LogDir "NetAid_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    try {
        $reportJson = $reportData | ConvertTo-Json -Depth 4
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($jsonReportPath, $reportJson, $utf8Bom)
        Write-Host "报告已导出至: $jsonReportPath" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] JSON 报告导出失败: $_" -ForegroundColor Yellow
    }
}

# ============================================================
# 查看历史 (交互式菜单选项6): Invoke-ViewHistory
# ============================================================
function Invoke-ViewHistory {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "历史诊断记录:" -ForegroundColor Cyan
    Write-Host "============================" -ForegroundColor Cyan

    $logDir = $Script:LogDir
    if (-not (Test-Path $logDir)) {
        Write-Host "没有找到历史记录目录: $logDir" -ForegroundColor Yellow
        return
    }

    $logFiles = Get-ChildItem -Path $logDir -Filter "NetAid_*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10

    if (-not $logFiles -or $logFiles.Count -eq 0) {
        Write-Host "没有找到历史记录。" -ForegroundColor DarkGray
        return
    }

    $index = 1
    foreach ($file in $logFiles) {
        $fileDate = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        $sizeKB = [math]::Round($file.Length / 1KB, 1)
        Write-Host "  $index. $($file.Name)" -ForegroundColor White
        Write-Host "     时间: $fileDate  大小: ${sizeKB}KB" -ForegroundColor DarkGray

        # 尝试提取诊断汇总信息
        try {
            $lines = Get-Content -Path $file.FullName -TotalCount 50 -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match '"diagnosis.summary"') {
                    $jsonObj = $line | ConvertFrom-Json
                    $pass = $jsonObj.pass
                    $warn = $jsonObj.warn
                    $fail = $jsonObj.fail
                    Write-Host "     通过:$pass  警告:$warn  失败:$fail" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
                    break
                }
            }
        } catch {
            # 忽略 JSON 解析错误
        }
        $index++
    }

    Write-Host ""
    Write-Host "日志目录: $logDir" -ForegroundColor DarkGray
}

# ============================================================
# 交互式菜单模式: Invoke-InteractiveMode
# ============================================================
function Invoke-InteractiveMode {
    [CmdletBinding()]
    param()

    do {
        Clear-Host
        $osDisplay = Get-OSDisplayString
        $networkStatus = Get-NetworkStatus
        Write-Banner -Version $Script:ScriptVersion
        $choice = Show-MainMenu -IsAdmin $Script:IsAdmin -OSInfo $osDisplay -NetworkStatus $networkStatus

        switch ($choice) {
            1 { $null = Invoke-FullDiagnosis -Interactive }
            2 { $null = Invoke-FullRepair -Interactive }
            3 { Invoke-SingleModule -Interactive }
            4 { Invoke-SingleFix -Interactive }
            5 { Invoke-GenerateReport }
            6 { Invoke-ViewHistory }
            7 { Show-HelpText }
            0 { break }
        }

        if ($choice -ne 0) {
            Write-Host ""
            Read-Host "按 Enter 键返回主菜单"
        }
    } while ($choice -ne 0)
}

# ============================================================
# 模式函数: Invoke-CheckMode (-Check 参数)
# ============================================================
function Invoke-CheckMode {
    [CmdletBinding()]
    param()

    if ($Module -ne 'all') {
        # 单项诊断
        $diagFunc = Get-DiagnosisFunctionName -ModuleShortName $Module
        if ($null -eq $diagFunc) {
            Write-Host "[!!] 未知模块: $Module" -ForegroundColor Red
            $Script:ExitCode = 6
            return
        }
        Write-ProgressLine -Current 1 -Total 1 -ModuleName $Module -Status "..."
        try {
            $result = & $diagFunc -Context @{}
            $verdict = $result.Diagnosis.Verdict
            $verdictText = $verdict
            if ($verdict -eq 'PASS') { $verdictText = '正常' }
            elseif ($verdict -eq 'FAIL') { $verdictText = '失败' }
            elseif ($verdict -eq 'WARN') { $verdictText = '警告' }
            Write-ProgressLine -Current 1 -Total 1 -ModuleName $Module -Status $verdictText
            $Script:DiagCache['Single'] = $result.Diagnosis
            if ($verdict -eq 'FAIL') { $Script:ExitCode = 1 }
            else { $Script:ExitCode = 0 }
        } catch {
            Write-ProgressLine -Current 1 -Total 1 -ModuleName $Module -Status "失败"
            $Script:ExitCode = 1
        }
    } else {
        # 全面诊断
        $diagResult = Invoke-FullDiagnosis
        $stats = $diagResult.Stats
        # 设置退出码
        if ($stats.Fail -gt 0) {
            $Script:ExitCode = 1
        } else {
            $Script:ExitCode = 0
        }
    }
}

# ============================================================
# 模式函数: Invoke-AutoMode (-Auto 参数)
# ============================================================
function Invoke-AutoMode {
    [CmdletBinding()]
    param()

    # 1. 运行全面诊断
    $diagResult = Invoke-FullDiagnosis
    $stats = $diagResult.Stats

    # 2. 若没有问题，直接退出
    if ($stats.Fail -eq 0 -and $stats.Warn -eq 0) {
        Write-Host ""
        Write-Host "网络状态正常，无需修复。" -ForegroundColor Green
        $Script:ExitCode = 0
        return
    }

    # 3. 检查管理员权限
    if (-not $Script:IsAdmin) {
        Write-Host ""
        Write-Host "修复需要管理员权限。请以管理员身份重新运行。" -ForegroundColor Red
        $Script:ExitCode = 4
        return
    }

    # 4. 生成修复计划
    $plan = Build-RepairPlan -DiagCache $Script:DiagCache -Stats $stats

    if ($plan.Count -eq 0) {
        Write-Host ""
        Write-Host "当前问题无法自动修复，建议手动排查。" -ForegroundColor Yellow
        $Script:ExitCode = 2
        return
    }

    # 5. 执行修复（非交互模式，自动确认）
    Write-Host ""
    Write-Host "发现 $($plan.Count) 项可修复问题，正在自动修复..." -ForegroundColor Cyan
    $pipelineResult = Invoke-RepairPipeline -RepairPlan $plan -Interactive:$false

    # 6. 验证修复
    $verifyResult = Invoke-VerifyRepairs -RepairResults $pipelineResult.Results

    # 7. 统计结果
    $successCount = 0; $failedCount = 0; $skippedCount = 0
    foreach ($r in $pipelineResult.Results) {
        $v = $r.Repair.Verdict
        if ($v -eq 'success') { $successCount++ }
        elseif ($v -eq 'failed') { $failedCount++ }
        elseif ($v -eq 'skipped') { $skippedCount++ }
    }

    # 8. 显示最终报告
    $reportData = @{
        Time           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Hostname       = $env:COMPUTERNAME
        OSVersion      = Get-OSDisplayString
        DiagTotal      = $stats.Total
        DiagPass       = $stats.Pass
        DiagWarn       = $stats.Warn
        DiagFail       = $stats.Fail
        DiagElapsed    = $diagResult.ElapsedSec
        DiagCritical   = $stats.Critical
        RepairTotal    = $plan.Count
        RepairSuccess  = $successCount
        RepairFail     = $failedCount
        RepairSkip     = $skippedCount
        FailItems      = @()
        WarnItems      = @()
        FixableCount   = $plan.Count
        Recommendations = @()
    }
    Show-FinalReport -ReportData $reportData

    # 9. 重启提示
    if ($pipelineResult.RebootRequired) {
        Write-Host ""
        $rebootConfirm = Confirm-UserAction -Message "有 $successCount 项修复需要重启后生效，是否现在重启?" -Default "N"
        if ($rebootConfirm) {
            Write-Host "正在重启系统..." -ForegroundColor Magenta
            Restart-Computer -Force
        } else {
            Write-Host "请尽快手动重启系统以使修复生效。" -ForegroundColor Yellow
        }
    }

    # 10. 汇总退出码
    if ($failedCount -eq $plan.Count) {
        $Script:ExitCode = 3
    } elseif ($failedCount -gt 0) {
        $Script:ExitCode = 2
    } else {
        $Script:ExitCode = 0
    }
}

# ============================================================
# 模式函数: Invoke-FixMode (-Fix / -FixAll 参数)
# ============================================================
function Invoke-FixMode {
    [CmdletBinding()]
    param()

    # 1. 检查管理员权限
    if (-not $Script:IsAdmin) {
        Write-Host "[!!] 修复需要管理员权限。请以管理员身份重新运行。" -ForegroundColor Red
        $Script:ExitCode = 4
        return
    }

    # 2. 确定要修复的模块列表
    $fixModules = @()
    if ($FixAll) {
        $fixModules = @('adapter','dhcp','dns','route','firewall','proxy','thirdparty','winsock','hosts','ipconflict')
    } else {
        $fixModules = $Fix
    }

    # 3. 先运行涉及模块的诊断
    Write-Host ""
    Write-Host "正在诊断相关模块..." -ForegroundColor Cyan
    Write-Separator

    foreach ($modName in $fixModules) {
        if ($modName -eq 'all') {
            # 全面诊断
            $null = Invoke-FullDiagnosis
            break
        }
        $code = ''
        foreach ($key in $Script:ModuleMap.Keys) {
            if ($key -eq $modName) {
                $code = $Script:ModuleMap[$key] -replace '^M(\d+)_.*$','M$1'
                break
            }
        }
        if ($code -eq '') {
            Write-Host "[WARN] 未知模块: $modName" -ForegroundColor Yellow
            continue
        }

        $diagFunc = "Invoke-${code}_Diagnose"
        Write-ProgressLine -Current 1 -Total 1 -ModuleName "$code ($modName)" -Status "..."
        try {
            $result = & $diagFunc -Context (Build-Context -Module $code -DiagCache $Script:DiagCache)
            $Script:DiagCache[$code] = $result.Diagnosis
            $v = $result.Diagnosis.Verdict
            $vText = $v
            if ($v -eq 'PASS') { $vText = '正常' }
            elseif ($v -eq 'FAIL') { $vText = '失败' }
            elseif ($v -eq 'WARN') { $vText = '警告' }
            Write-ProgressLine -Current 1 -Total 1 -ModuleName "$code ($modName)" -Status $vText
        } catch {
            $Script:DiagCache[$code] = @{ Verdict = 'FAIL'; Error = $_.Exception.Message }
            Write-ProgressLine -Current 1 -Total 1 -ModuleName "$code ($modName)" -Status "失败"
        }
    }

    Write-Separator

    # 4. 生成修复计划
    $stats = Get-DiagnosisStats -DiagCache $Script:DiagCache
    $plan = Build-RepairPlan -DiagCache $Script:DiagCache -Stats $stats

    if ($plan.Count -eq 0) {
        Write-Host "没有需要修复的问题。" -ForegroundColor Green
        $Script:ExitCode = 0
        return
    }

    # 5. 执行修复
    Write-Host ""
    Write-Host "正在执行修复 ($($plan.Count) 项)..." -ForegroundColor Cyan
    $pipelineResult = Invoke-RepairPipeline -RepairPlan $plan -Interactive:$true

    # 6. 验证
    $verifyResult = Invoke-VerifyRepairs -RepairResults $pipelineResult.Results

    # 7. 统计
    $successCount = 0; $failedCount = 0; $skippedCount = 0
    foreach ($r in $pipelineResult.Results) {
        $v = $r.Repair.Verdict
        if ($v -eq 'success') { $successCount++ }
        elseif ($v -eq 'failed') { $failedCount++ }
        elseif ($v -eq 'skipped') { $skippedCount++ }
    }

    # 8. 报告
    $reportData = @{
        Time           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Hostname       = $env:COMPUTERNAME
        OSVersion      = Get-OSDisplayString
        DiagTotal      = $stats.Total
        DiagPass       = $stats.Pass
        DiagWarn       = $stats.Warn
        DiagFail       = $stats.Fail
        DiagElapsed    = 0
        DiagCritical   = $stats.Critical
        RepairTotal    = $plan.Count
        RepairSuccess  = $successCount
        RepairFail     = $failedCount
        RepairSkip     = $skippedCount
        FailItems      = @()
        WarnItems      = @()
        FixableCount   = $plan.Count
        Recommendations = @()
    }
    Show-FinalReport -ReportData $reportData

    if ($failedCount -eq $plan.Count) {
        $Script:ExitCode = 3
    } elseif ($failedCount -gt 0) {
        $Script:ExitCode = 2
    } else {
        $Script:ExitCode = 0
    }
}

# ============================================================
# 模式函数: Invoke-ReportMode (-Report 参数)
# ============================================================
function Invoke-ReportMode {
    [CmdletBinding()]
    param()

    # 如果尚未运行诊断，先运行
    if ($Script:DiagCache.Count -eq 0) {
        Write-Host "尚未运行诊断，正在自动运行..." -ForegroundColor Cyan
        $null = Invoke-FullDiagnosis
    }

    Invoke-GenerateReport
    $Script:ExitCode = 0
}

# ============================================================
# 第四部分：主逻辑路由
# ============================================================

# 判断是否进入了交互式模式（无任何有效参数）
if (-not ($Auto -or $Check -or $Fix -or $FixAll -or $Help -or $Version -or $ListModules -or $Report)) {
    Invoke-InteractiveMode
    $Script:ExitCode = 0
}

# -Auto: 全自动诊断+修复
if ($Auto) {
    Invoke-AutoMode
}

# -Check: 仅诊断
if ($Check) {
    Invoke-CheckMode
}

# -Fix / -FixAll: 修复模式
if ($Fix -or $FixAll) {
    Invoke-FixMode
}

# -Report: 仅生成报告
if ($Report) {
    Invoke-ReportMode
}

# ============================================================
# 第五部分：收尾
# ============================================================

# 写入会话结束日志
Write-SessionEnd -ExitCode $Script:ExitCode -TotalElapsedMs ([int](((Get-Date) - $Script:StartTime).TotalMilliseconds))

# 写入会话索引（记录到 sessions.jsonl）
$diagResult = if ($Script:DiagCache -and $Script:DiagCache.Count -gt 0) {
    @{ Total = ($Script:DiagCache.Count); Pass = @($Script:DiagCache.Values | Where-Object { $_.Verdict -eq 'PASS' }).Count; Warn = @($Script:DiagCache.Values | Where-Object { $_.Verdict -eq 'WARN' }).Count; Fail = @($Script:DiagCache.Values | Where-Object { $_.Verdict -eq 'FAIL' }).Count }
} else { $null }
$repairResult = if ($Script:FixResults -and $Script:FixResults.Count -gt 0) {
    @{ Total = ($Script:FixResults.Count); Success = @($Script:FixResults | Where-Object { $_.Repair.Verdict -eq 'success' }).Count; Failed = @($Script:FixResults | Where-Object { $_.Repair.Verdict -eq 'failed' }).Count; RebootRequired = @($Script:FixResults | Where-Object { $_.Repair.RebootRequired }).Count -gt 0 }
} else { $null }
Write-SessionIndex -ExitCode $Script:ExitCode -TotalMs ([int](((Get-Date) - $Script:StartTime).TotalMilliseconds)) -DiagResult $diagResult -RepairResult $repairResult

# --- 日志清理提示 & 文件路径 ---
$logFile = Get-LogFilePath
$logDir  = Get-LogDirectory
if ($logDir) {
    $stats = Get-LogStats
    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  会话日志: $logFile" -ForegroundColor White
    Write-Host "  日志目录: $logDir" -ForegroundColor DarkGray
    Write-Host "  日志统计: $($stats.FileCount) 个文件, $($stats.SizeMB) MB, 最旧 $($stats.MaxAgeDays) 天" -ForegroundColor DarkGray
    if ($stats.MaxAgeDays -gt 30 -or $stats.SizeMB -gt 50) {
        Write-Host "  [提示] 日志文件较多/较旧，可运行 'NetAid -CleanLogs' 清理" -ForegroundColor Yellow
    }
    Write-Host ("=" * 50) -ForegroundColor Cyan

    # 交互模式下提示清理
    if (-not ($Auto -or $Check -or $Fix -or $Report -or $Silent)) {
        $cleanupChoice = Read-Host "是否清理 30 天前的旧日志？(Y/N，默认 N)"
        if ($cleanupChoice -eq 'Y' -or $cleanupChoice -eq 'y') {
            $result = Remove-OldLogs -OlderThanDays 30
            Write-Host "  已删除 $($result.DeletedCount) 个文件，释放 $($result.FreedMB) MB" -ForegroundColor Green
        }
    }
}

# 关闭日志
Close-Logger

exit $Script:ExitCode
