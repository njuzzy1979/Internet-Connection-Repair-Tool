<#
.SYNOPSIS
    NetAid JSON Lines 日志系统
.DESCRIPTION
    实现 JSON Lines (.jsonl) 格式的日志系统。
    所有日志由主线程统一写入，子Job不直接写日志文件。
    使用互斥锁保证线程安全。
.NOTES
    文件名: Logger.ps1
    依赖: 零第三方依赖
    兼容: Windows PowerShell 5.1
#>

# ============================================================
# 脚本级变量
# ============================================================
$Script:LogInitialized  = $false
$Script:LogPath         = $null
$Script:SessionId       = $null
$Script:LogFile         = $null
$Script:LogMutex        = $null
$Script:SessionStartTime = $null

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    根据事件类型和判定结果确定日志级别
#>
function Get-LogLevel {
    param(
        [string]$EventType,
        [string]$Verdict
    )

    switch ($EventType) {
        'session.start'      { return 'INFO' }
        'session.end'        { return 'INFO' }
        'check.end' {
            switch ($Verdict) {
                'PASS'    { return 'PASS' }
                'WARN'    { return 'WARN' }
                'FAIL'    { return 'FAIL' }
                'TIMEOUT' { return 'WARN' }
                'SKIP'    { return 'INFO' }
                'UNKNOWN' { return 'INFO' }
                default   { return 'INFO' }
            }
        }
        'fix.step'           { return 'INFO' }
        'fix.end' {
            switch ($Verdict) {
                'success' { return 'INFO' }
                'failed'  { return 'FAIL' }
                'skipped' { return 'INFO' }
                default   { return 'INFO' }
            }
        }
        'diagnosis.summary'  { return 'INFO' }
        'fix.summary'        { return 'INFO' }
        'error'              { return 'ERROR' }
        'env.snapshot'       { return 'INFO' }
        default              { return 'INFO' }
    }
}

<#
.SYNOPSIS
    生成 ISO 8601 格式时间戳（含东八区时区偏移）
#>
function Get-IsoTimestamp {
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
}

<#
.SYNOPSIS
    获取互斥锁
#>
function Enter-LogMutex {
    if ($Script:LogMutex) {
        [void]$Script:LogMutex.WaitOne()
    }
}

<#
.SYNOPSIS
    释放互斥锁
#>
function Exit-LogMutex {
    if ($Script:LogMutex) {
        $Script:LogMutex.ReleaseMutex()
    }
}

# ============================================================
# 公共函数
# ============================================================

<#
.SYNOPSIS
    初始化日志系统
.DESCRIPTION
    创建日志目录和日志文件，初始化脚本级变量，写入会话开始事件。
.PARAMETER LogDir
    日志目录路径，默认 $env:TEMP\NetAid
.PARAMETER SessionId
    会话ID，默认自动生成8位十六进制字符串
.PARAMETER ScriptVersion
    脚本版本号
#>
function Initialize-Logger {
    param(
        [string]$LogDir = "$env:LOCALAPPDATA\NetAid\logs",
        [string]$SessionId,
        [string]$ScriptVersion
    )

    # 自动生成 SessionId（8位十六进制随机字符串）
    if (-not $SessionId) {
        $SessionId = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    }

    # 创建日志目录（如果不存在）
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    # 设置脚本级变量
    $Script:LogPath   = $LogDir
    $Script:SessionId = $SessionId
    $Script:SessionStartTime = Get-Date

    # 生成日志文件名：NetAid_yyyyMMdd_HHmmss.jsonl
    $fileTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Script:LogFile = Join-Path $LogDir "NetAid_${fileTimestamp}.jsonl"

    # 创建互斥锁（用于线程安全的文件写入）
    $Script:LogMutex = New-Object System.Threading.Mutex($false, 'Global\NetAid_Logger_Mutex')

    # 使用 StreamWriter 以 UTF-8 无BOM 创建日志文件
    $writer = New-Object System.IO.StreamWriter($Script:LogFile, $false, [System.Text.Encoding]::UTF8)
    $writer.Close()

    # 标记初始化完成
    $Script:LogInitialized = $true

    # 写入 session.start 事件
    $startEvent = @{
        event   = 'session.start'
        version = $ScriptVersion
    }
    Write-JsonlLog -Event $startEvent
}

<#
.SYNOPSIS
    写入一条 JSONL 日志事件（唯一写入入口）
.DESCRIPTION
    将事件哈希表转为 JSON 并追加写入日志文件。
    自动添加 ts（ISO 8601 时间戳）和 level 字段。
    使用互斥锁保证线程安全。
.PARAMETER Event
    事件数据的哈希表，必须包含 'event' 键
#>
function Write-JsonlLog {
    param(
        [hashtable]$Event
    )

    # 如果日志系统未初始化，使用默认参数自动初始化
    if (-not $Script:LogInitialized) {
        Initialize-Logger -ScriptVersion '0.0.0'
    }

    # 自动添加时间戳
    $Event['ts'] = Get-IsoTimestamp

    # 自动确定日志级别（如果调用方未指定）
    if (-not $Event.ContainsKey('level')) {
        $eventType = $Event['event']
        $verdict   = if ($Event.ContainsKey('verdict')) { $Event['verdict'] } else { $null }
        $Event['level'] = Get-LogLevel -EventType $eventType -Verdict $verdict
    }

    # 将哈希表转为压缩 JSON
    $jsonLine = ConvertTo-Json -InputObject $Event -Compress

    # 互斥锁保护文件写入
    try {
        Enter-LogMutex
        $writer = New-Object System.IO.StreamWriter($Script:LogFile, $true, [System.Text.Encoding]::UTF8)
        $writer.WriteLine($jsonLine)
        $writer.Close()
    }
    finally {
        Exit-LogMutex
    }
}

<#
.SYNOPSIS
    写入诊断事件（便捷函数）
.DESCRIPTION
    构造并写入 check.end 诊断事件。
.PARAMETER Module
    模块编号，如 "M01"
.PARAMETER Verdict
    判定结果：PASS / WARN / FAIL / UNKNOWN / TIMEOUT / SKIP
.PARAMETER ElapsedMs
    耗时（毫秒）
.PARAMETER ExtraFields
    额外字段的哈希表，将合并到事件中
#>
function Write-DiagnosisEvent {
    param(
        [string]$Module,
        [string]$Verdict,
        [int]$ElapsedMs,
        [hashtable]$ExtraFields = @{}
    )

    $eventData = @{
        event      = 'check.end'
        module     = $Module
        verdict    = $Verdict
        elapsed_ms = $ElapsedMs
    }

    # 合并额外字段
    foreach ($key in $ExtraFields.Keys) {
        $eventData[$key] = $ExtraFields[$key]
    }

    Write-JsonlLog -Event $eventData
}

<#
.SYNOPSIS
    写入修复事件
.DESCRIPTION
    根据 EventSubType 写入 fix.step（单步）或 fix.end（最终结果）事件。
.PARAMETER Module
    模块编号，如 "M01"
.PARAMETER EventSubType
    事件子类型：'step' 写入 fix.step，'end' 写入 fix.end
.PARAMETER Step
    修复步骤描述（仅 fix.step 使用）
.PARAMETER ExitCode
    步骤退出码（仅 fix.step 使用）
.PARAMETER Verdict
    最终判定：success / failed / skipped（仅 fix.end 使用）
.PARAMETER RebootRequired
    是否需要重启（仅 fix.end 使用，默认 $false）
#>
function Write-FixEvent {
    param(
        [string]$Module,
        [ValidateSet('step', 'end')]
        [string]$EventSubType,
        [string]$Step,
        [int]$ExitCode,
        [string]$Verdict,
        [bool]$RebootRequired = $false
    )

    if ($EventSubType -eq 'step') {
        $eventData = @{
            event     = 'fix.step'
            module    = $Module
            step      = $Step
            exit_code = $ExitCode
        }
    }
    else {
        $eventData = @{
            event           = 'fix.end'
            module          = $Module
            verdict         = $Verdict
            reboot_required = $RebootRequired
        }
    }

    Write-JsonlLog -Event $eventData
}

<#
.SYNOPSIS
    写入会话开始事件
.DESCRIPTION
    写入包含主机信息的 session.start 事件。
.PARAMETER HostName
    主机名
.PARAMETER OS
    操作系统描述
.PARAMETER Version
    脚本版本号
.PARAMETER Elevated
    是否以管理员权限运行
.PARAMETER LanguageMode
    PowerShell 语言模式
#>
function Write-SessionStart {
    param(
        [string]$HostName,
        [string]$OS,
        [string]$Version,
        [bool]$Elevated,
        [string]$LanguageMode
    )

    $eventData = @{
        event            = 'session.start'
        host             = $HostName
        os               = $OS
        version          = $Version
        elevated         = $Elevated
        ps_language_mode = $LanguageMode
    }

    Write-JsonlLog -Event $eventData
}

<#
.SYNOPSIS
    写入会话结束事件
.PARAMETER ExitCode
    脚本退出码
.PARAMETER TotalElapsedMs
    总耗时（毫秒）
#>
function Write-SessionEnd {
    param(
        [int]$ExitCode,
        [int]$TotalElapsedMs
    )

    $eventData = @{
        event            = 'session.end'
        exit_code        = $ExitCode
        total_elapsed_ms = $TotalElapsedMs
    }

    Write-JsonlLog -Event $eventData
}

<#
.SYNOPSIS
    写入汇总事件
.DESCRIPTION
    根据阶段（diagnosis / fix）写入对应的汇总事件。
.PARAMETER Phase
    阶段名称：'diagnosis' 或 'fix'
.PARAMETER Total
    总检查/修复项数
.PARAMETER Pass
    通过数（仅 diagnosis 阶段）
.PARAMETER Warn
    警告数（仅 diagnosis 阶段）
.PARAMETER Fail
    失败数（仅 diagnosis 阶段）
.PARAMETER ElapsedMs
    耗时（毫秒，仅 diagnosis 阶段）
.PARAMETER Success
    成功数（仅 fix 阶段）
.PARAMETER Failed
    失败数（仅 fix 阶段）
.PARAMETER RebootRequired
    是否需要重启（仅 fix 阶段）
#>
function Write-SummaryEvent {
    param(
        [ValidateSet('diagnosis', 'fix')]
        [string]$Phase,
        [int]$Total,
        [int]$Pass,
        [int]$Warn,
        [int]$Fail,
        [int]$ElapsedMs,
        [int]$Success,
        [int]$Failed,
        [bool]$RebootRequired
    )

    if ($Phase -eq 'diagnosis') {
        $eventData = @{
            event      = 'diagnosis.summary'
            total      = $Total
            pass       = $Pass
            warn       = $Warn
            fail       = $Fail
            elapsed_ms = $ElapsedMs
        }
    }
    else {
        $eventData = @{
            event           = 'fix.summary'
            total           = $Total
            success         = $Success
            failed          = $Failed
            reboot_required = $RebootRequired
        }
    }

    Write-JsonlLog -Event $eventData
}

<#
.SYNOPSIS
    写入错误事件
.PARAMETER Severity
    严重程度：critical / high / medium / low
.PARAMETER Message
    错误消息
.PARAMETER StackTrace
    堆栈跟踪信息
#>
function Write-ErrorEvent {
    param(
        [ValidateSet('critical', 'high', 'medium', 'low')]
        [string]$Severity,
        [string]$Message,
        [string]$StackTrace
    )

    $eventData = @{
        event      = 'error'
        severity   = $Severity
        message    = $Message
        stack_trace = $StackTrace
    }

    Write-JsonlLog -Event $eventData
}

<#
.SYNOPSIS
    写入环境快照
.DESCRIPTION
    将 Get-SystemSnapshot 返回的哈希表展开写入 env.snapshot 事件。
.PARAMETER Snapshot
    环境快照哈希表（来自 Utils.ps1 的 Get-SystemSnapshot）
#>
function Write-EnvSnapshot {
    param(
        [hashtable]$Snapshot
    )

    $eventData = @{
        event = 'env.snapshot'
    }

    # 展开快照哈希表的所有键值对
    foreach ($key in $Snapshot.Keys) {
        $eventData[$key] = $Snapshot[$key]
    }

    Write-JsonlLog -Event $eventData
}

<#
.SYNOPSIS
    返回当前日志文件路径
.DESCRIPTION
    返回 $Script:LogFile 的当前值。
#>
function Get-LogFilePath {
    return $Script:LogFile
}

<#
.SYNOPSIS
    关闭日志写入器
.DESCRIPTION
    释放互斥锁资源。应在脚本退出时调用。
#>
function Close-Logger {
    if ($Script:LogMutex) {
        $Script:LogMutex.Close()
        $Script:LogMutex.Dispose()
        $Script:LogMutex = $null
    }
    $Script:LogInitialized = $false
}

# ============================================================
# 会话索引与日志管理
# ============================================================

<#
.SYNOPSIS
    向日志目录下的 sessions.jsonl 追加当前会话索引记录
.DESCRIPTION
    每次会话结束时调用，在日志根目录维护一个会话索引文件，
    记录每次运行的概要信息，方便快速浏览历史记录。
.PARAMETER ExitCode
    脚本退出码
.PARAMETER TotalMs
    会话总耗时（毫秒）
.PARAMETER DiagResult
    诊断摘要哈希表：@{Total; Pass; Warn; Fail}
.PARAMETER RepairResult
    修复摘要哈希表：@{Total; Success; Failed; RebootRequired}（未运行修复则为 $null）
#>
function Write-SessionIndex {
    param(
        [int]$ExitCode,
        [int]$TotalMs,
        [hashtable]$DiagResult,
        [hashtable]$RepairResult
    )

    $indexFile = Join-Path $Script:LogPath 'sessions.jsonl'

    $record = @{
        session_id   = $Script:SessionId
        log_file     = Split-Path $Script:LogFile -Leaf
        start_time   = (Get-Date $Script:SessionStartTime).ToString('yyyy-MM-ddTHH:mm:ss')
        exit_code    = $ExitCode
        total_ms     = $TotalMs
        diag_total   = if ($DiagResult) { $DiagResult['Total'] } else { 0 }
        diag_pass    = if ($DiagResult) { $DiagResult['Pass'] } else { 0 }
        diag_warn    = if ($DiagResult) { $DiagResult['Warn'] } else { 0 }
        diag_fail    = if ($DiagResult) { $DiagResult['Fail'] } else { 0 }
    }

    if ($RepairResult) {
        $record['repair_total']   = $RepairResult['Total']
        $record['repair_success'] = $RepairResult['Success']
        $record['repair_failed']  = $RepairResult['Failed']
        $record['repair_reboot']  = $RepairResult['RebootRequired']
    }

    try {
        $line = ConvertTo-Json -InputObject $record -Compress
        if (Test-Path $indexFile) {
            Add-Content -Path $indexFile -Value $line -Encoding UTF8
        } else {
            $parentDir = Split-Path $indexFile -Parent
            if (-not (Test-Path $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
            }
            Set-Content -Path $indexFile -Value $line -Encoding UTF8
        }
    } catch {
        # 索引写入失败不应影响主流程
        Write-Warning "无法写入会话索引: $_"
    }
}

<#
.SYNOPSIS
    计算日志目录的总大小（字节）
#>
function Get-LogDirectorySize {
    if (-not (Test-Path $Script:LogPath)) { return 0 }
    $totalBytes = 0
    Get-ChildItem -Path $Script:LogPath -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { $totalBytes += $_.Length }
    return $totalBytes
}

<#
.SYNOPSIS
    获取日志目录中最旧文件的天数
#>
function Get-LogMaxAge {
    if (-not (Test-Path $Script:LogPath)) { return 0 }
    $oldest = Get-ChildItem -Path $Script:LogPath -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        Select-Object -First 1
    if (-not $oldest) { return 0 }
    return [math]::Floor(((Get-Date) - $oldest.LastWriteTime).TotalDays)
}

<#
.SYNOPSIS
    获取日志目录统计信息
.DESCRIPTION
    返回日志目录的文件数、总大小(MB)、最旧文件天数。
#>
function Get-LogStats {
    if (-not (Test-Path $Script:LogPath)) {
        return @{ FileCount = 0; SizeMB = 0; MaxAgeDays = 0 }
    }
    $files = @(Get-ChildItem -Path $Script:LogPath -Recurse -File -ErrorAction SilentlyContinue)
    $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $totalBytes) { $totalBytes = 0 }
    $maxAge = 0
    if ($files.Count -gt 0) {
        $oldest = $files | Sort-Object LastWriteTime | Select-Object -First 1
        $maxAge = [math]::Floor(((Get-Date) - $oldest.LastWriteTime).TotalDays)
    }
    return @{
        FileCount  = $files.Count
        SizeMB     = [math]::Round($totalBytes / 1MB, 2)
        MaxAgeDays = $maxAge
    }
}

<#
.SYNOPSIS
    清理旧日志文件
.DESCRIPTION
    删除指定天数之前的日志文件（保留 sessions.jsonl 索引）。
.PARAMETER OlderThanDays
    删除超过该天数的日志，默认 30
.PARAMETER WhatIf
    仅列出将删除的文件而不实际操作
.OUTPUTS
    Hashtable: @{DeletedCount; FreedMB}
#>
function Remove-OldLogs {
    param(
        [int]$OlderThanDays = 30,
        [switch]$WhatIf
    )

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $deleted = 0
    $freed = 0L

    if (-not (Test-Path $Script:LogPath)) {
        return @{ DeletedCount = 0; FreedMB = 0 }
    }

    $oldFiles = Get-ChildItem -Path $Script:LogPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'sessions.jsonl' -and $_.LastWriteTime -lt $cutoff }

    foreach ($f in $oldFiles) {
        if ($WhatIf) {
            Write-Host "  [WHATIF] 将删除: $($f.FullName) ($([math]::Round($f.Length/1KB,1)) KB)" -ForegroundColor Yellow
        } else {
            $freed += $f.Length
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            if ($?) { $deleted++ }
        }
    }

    return @{
        DeletedCount = $deleted
        FreedMB      = [math]::Round($freed / 1MB, 2)
    }
}

<#
.SYNOPSIS
    返回日志根目录路径（供外部清理逻辑使用）
#>
function Get-LogDirectory {
    return $Script:LogPath
}
