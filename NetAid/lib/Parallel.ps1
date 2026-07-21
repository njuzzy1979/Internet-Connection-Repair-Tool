#Requires -Version 5.1
<#
.SYNOPSIS
    诊断模块 Phase 并行编排引擎
.DESCRIPTION
    使用 Start-Job + Wait-Job + Receive-Job 模式实现诊断模块的 Phase 并行编排。
    核心设计原则：
    1. Start-Job 创建独立 PS 进程，父作用域变量不可见 → 通过 -ArgumentList 传入数据切片
    2. 子 Job 不直接写日志文件 → 日志事件通过 Receive-Job 收集后由主线程统一写入
    3. netsh 命令互斥 → M08 必须在 Phase 3 单独串行执行
    4. 超时控制：单模块5s，总诊断12s，WFP子检测15s独立超时
.NOTES
    零第三方依赖，仅使用 PowerShell 内置 cmdlet。
    兼容 Windows PowerShell 5.1。
#>

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

# ============================================================================
# 公共函数
# ============================================================================

<#
.SYNOPSIS
    为单个 Job 设置超时监控。
.DESCRIPTION
    使用 .NET Timer + Register-ObjectEvent 在超时后自动停止目标 Job。
    避免使用 Start-Job 创建监控（子进程无法访问父进程的 Job 对象）。
.PARAMETER Job
    需要监控的目标 Job 对象。
.PARAMETER TimeoutSeconds
    超时秒数，超时后若目标 Job 仍在运行则强制 Stop-Job。
.EXAMPLE
    $monitor = Set-JobTimeout -Job $job -TimeoutSeconds 5
#>
function Set-JobTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Job]$Job,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutSeconds
    )

    # 使用 .NET Timer 在当前进程中触发超时回调
    # 这样回调可以直接访问当前会话的 Job 对象，避免 Start-Job 子进程隔离问题
    $timer = New-Object System.Timers.Timer
    $timer.Interval = $TimeoutSeconds * 1000
    $timer.AutoReset = $false

    $eventJob = Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
        $targetJob = Get-Job -Id $Event.MessageData -ErrorAction SilentlyContinue
        if ($targetJob -and $targetJob.State -eq 'Running') {
            Stop-Job -Job $targetJob -ErrorAction SilentlyContinue
        }
    } -MessageData $Job.Id

    $timer.Start()

    # 返回定时器和事件订阅，供调用者在清理时使用
    return @{
        EventJob = $eventJob
        Timer    = $timer
    }
}

<#
.SYNOPSIS
    启动一个 Phase 的并行 Job。
.DESCRIPTION
    遍历 $Jobs 哈希表，为每个模块创建 Start-Job，传入对应的参数数据。
    如果 Start-Job 因 ConstrainedLanguage 模式等原因失败，降级为串行直接调用。
.PARAMETER Jobs
    键为 Job 名称（如 "M01"），值为 ScriptBlock 的哈希表。
    每个 ScriptBlock 必须能接收单个参数 param($Data)。
.PARAMETER ArgumentData
    键为 Job 名称，值为传给对应 ScriptBlock 的数据对象的哈希表。
.EXAMPLE
    $jobs = Invoke-PhaseJobs -Jobs $scriptBlocks -ArgumentData $dataMap
#>
function Invoke-PhaseJobs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Jobs,

        [Parameter(Mandatory = $true)]
        [hashtable]$ArgumentData
    )

    $jobList = @()

    foreach ($jobName in $Jobs.Keys) {
        $scriptBlock = $Jobs[$jobName]
        $data = $null
        if ($ArgumentData.ContainsKey($jobName)) {
            $data = $ArgumentData[$jobName]
        }

        try {
            # 通过 -ArgumentList 将数据切片传入子进程
            # ScriptBlock 以 param($Data) 接收
            $job = Start-Job -Name $jobName -ScriptBlock $scriptBlock -ArgumentList $data
            $jobList += $job
        }
        catch {
            # ConstrainedLanguage 模式或其他原因导致 Start-Job 失败
            # 降级为在当前进程中直接调用 ScriptBlock
            Write-Warning "Start-Job 失败 [${jobName}]，降级为串行执行：$_"

            # 创建一个"伪 Job"来保持接口一致——用直接调用的结果填充
            # 使用 Start-Job 内联在当前作用域执行（如仍失败则彻底放弃）
            try {
                $job = Start-Job -Name $jobName -ScriptBlock $scriptBlock -ArgumentList $data
                $jobList += $job
            }
            catch {
                # 彻底失败：通过 Invoke-Command 在当前作用域直接执行并包装结果
                Write-Warning "串行降级也失败 [${jobName}]，直接执行：$_"
                try {
                    $result = & $scriptBlock -Data $data
                    # 创建哈希表作为伪结果包装
                    if ($result -isnot [hashtable]) {
                        $result = @{
                            Diagnosis = @{
                                Module  = $jobName
                                Verdict = 'FAIL'
                                Error   = "返回类型无效：$($result.GetType().Name)"
                            }
                            LogEvents = @()
                        }
                    }
                    # 将直接执行的结果存入一个特殊标记的临时变量，后续由 Collect-JobResults 处理
                    # 同时创建一个假的 Completed Job 标记
                    $wrapper = @{
                        IsFallback   = $true
                        Name         = $jobName
                        State        = 'Completed'
                        FallbackData = $result
                    }
                    $script:__FallbackResults = @{}  # 确保变量存在
                    $script:__FallbackResults[$jobName] = $result
                    # 将 null 加入列表表示降级结果已在 __FallbackResults 中
                    $jobList += @{Name = $jobName; IsFallbackProxy = $true}
                }
                catch {
                    # 连直接执行都失败了，记录为失败
                    Write-Error "模块 [${jobName}] 执行完全失败：$_"
                    $script:__FallbackResults = @{}
                    $script:__FallbackResults[$jobName] = @{
                        Diagnosis = @{
                            Module  = $jobName
                            Verdict = 'FAIL'
                            Error   = $_.ToString()
                        }
                        LogEvents = @()
                    }
                    $jobList += @{Name = $jobName; IsFallbackProxy = $true}
                }
            }
        }
    }

    # 清理旧的 fallback 存储
    if (-not $script:__FallbackResults) {
        $script:__FallbackResults = @{}
    }

    return $jobList
}

<#
.SYNOPSIS
    等待 Phase 内所有 Job 完成，超时的强制终止。
.DESCRIPTION
    调用 Wait-Job 等待所有 Job，超时的 Job 通过 Stop-Job 强制终止。
.PARAMETER Jobs
    Job 对象数组（由 Invoke-PhaseJobs 返回）。
.PARAMETER TimeoutSeconds
    等待超时秒数，默认 5 秒。
.EXAMPLE
    $status = Wait-PhaseJobs -Jobs $jobs -TimeoutSeconds 5
#>
function Wait-PhaseJobs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Jobs,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutSeconds = 5
    )

    # 过滤出真正的 Job 对象（排除降级代理对象）
    $realJobs = $Jobs | Where-Object {
        $_ -is [System.Management.Automation.Job]
    }

    if ($realJobs.Count -eq 0) {
        # 全部是降级代理，无需等待
        return @{
            Completed = @()
            TimedOut  = @()
        }
    }

    # 等待所有 Job 完成，超时的 Job 状态变为 'Running'（未被 Wait-Job 终止）
    $null = Wait-Job -Job $realJobs -Timeout $TimeoutSeconds

    $completed = @()
    $timedOut  = @()

    foreach ($job in $realJobs) {
        if ($job.State -eq 'Running') {
            # 仍在运行表示超时，强制终止
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            $timedOut += $job
        }
        else {
            $completed += $job
        }
    }

    return @{
        Completed = $completed
        TimedOut  = $timedOut
    }
}

<#
.SYNOPSIS
    收集 Job 结果，提取诊断数据和日志事件（核心函数）。
.DESCRIPTION
    遍历 Job 列表，从 Completed 的 Job 中 Receive-Job 获取结果，
    验证结果格式，将 LogEvents 通过回调写入日志，将 Diagnosis 汇总返回。
    对 Failed/Stopped/Fallback 状态做相应标记处理，最后 Remove-Job 清理。
.PARAMETER Jobs
    Job 对象数组（由 Invoke-PhaseJobs 返回，可能包含降级代理）。
.PARAMETER LogWriter
    日志写入回调 ScriptBlock，签名：param([hashtable]$Event)。
.EXAMPLE
    $collected = Collect-JobResults -Jobs $jobs -LogWriter ${function:Write-LogEvent}
#>
function Collect-JobResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Jobs,

        [Parameter(Mandatory = $true)]
        [scriptblock]$LogWriter
    )

    $results  = @{}
    $timeouts = @()
    $failures = @()

    foreach ($jobItem in $Jobs) {
        # 处理降级代理对象（非真正 Job，而是哈希表包装的结果）
        if ($jobItem -isnot [System.Management.Automation.Job]) {
            if ($jobItem.IsFallbackProxy) {
                $jobName = $jobItem.Name
                if ($script:__FallbackResults -and $script:__FallbackResults.ContainsKey($jobName)) {
                    $fallbackResult = $script:__FallbackResults[$jobName]
                    # 写入日志事件
                    if ($fallbackResult -is [hashtable] -and $fallbackResult.ContainsKey('LogEvents')) {
                        foreach ($event in $fallbackResult.LogEvents) {
                            try {
                                & $LogWriter $event
                            }
                            catch {
                                Write-Warning "日志写入回调失败 [${jobName}]：$_"
                            }
                        }
                    }
                    # 提取诊断结果
                    if ($fallbackResult -is [hashtable] -and $fallbackResult.ContainsKey('Diagnosis')) {
                        $results[$jobName] = $fallbackResult.Diagnosis
                    }
                    else {
                        $results[$jobName] = @{
                            Module  = $jobName
                            Verdict = 'FAIL'
                            Error   = "降级结果格式无效"
                        }
                    }
                }
            }
            continue
        }

        $jobName = $jobItem.Name

        # 根据 Job 状态分别处理
        switch ($jobItem.State) {
            'Completed' {
                try {
                    # Receive-Job 获取子进程输出（含错误流）
                    $result = Receive-Job -Job $jobItem -ErrorAction Stop

                    # 验证返回值是否为有效哈希表
                    if ($result -is [hashtable]) {
                        # 检查是否包含必需的键
                        $hasDiagnosis = $result.ContainsKey('Diagnosis')
                        $hasLogEvents = $result.ContainsKey('LogEvents')

                        if (-not $hasDiagnosis) {
                            # 缺少 Diagnosis 键，自动包装
                            $result['Diagnosis'] = @{
                                Module  = $jobName
                                Verdict = 'FAIL'
                                Error   = "Job 返回值缺少 Diagnosis 键"
                            }
                        }

                        if (-not $hasLogEvents) {
                            $result['LogEvents'] = @()
                        }

                        # 逐条写入日志事件（主线程统一写入，子 Job 不直接操作文件）
                        foreach ($event in $result['LogEvents']) {
                            try {
                                & $LogWriter $event
                            }
                            catch {
                                Write-Warning "日志写入回调失败 [${jobName}]：$_"
                            }
                        }

                        $results[$jobName] = $result['Diagnosis']
                    }
                    else {
                        # 返回值不是哈希表
                        $results[$jobName] = @{
                            Module  = $jobName
                            Verdict = 'FAIL'
                            Error   = "Job 返回值类型无效：$($result.GetType().Name)"
                        }
                        $failures += $jobName
                    }
                }
                catch {
                    # Receive-Job 本身失败
                    $results[$jobName] = @{
                        Module  = $jobName
                        Verdict = 'FAIL'
                        Error   = "Receive-Job 失败：$($_.Exception.Message)"
                    }
                    $failures += $jobName
                }
            }

            'Failed' {
                # Job 执行过程中抛出未捕获异常
                $errorInfo = $null
                try {
                    # 尝试获取 Job 的错误信息
                    $jobErrors = $jobItem.ChildJobs | ForEach-Object { $_.Error } | Where-Object { $_ -ne $null }
                    if ($jobErrors) {
                        $errorInfo = ($jobErrors | ForEach-Object { $_.ToString() }) -join '; '
                    }
                }
                catch {
                    $errorInfo = $jobItem.JobStateInfo.Reason
                }

                $results[$jobName] = @{
                    Module  = $jobName
                    Verdict = 'FAIL'
                    Error   = if ($errorInfo) { $errorInfo } else { 'Job 执行失败，无详细错误信息' }
                }
                $failures += $jobName
            }

            'Stopped' {
                # Job 被 Stop-Job 强制终止（通常是超时）
                $results[$jobName] = @{
                    Module  = $jobName
                    Verdict = 'TIMEOUT'
                    Error   = '模块执行超时，已被强制终止'
                }
                $timeouts += $jobName
            }

            default {
                # 其他未知状态（如 NotStarted, Suspended 等）
                $results[$jobName] = @{
                    Module  = $jobName
                    Verdict = 'FAIL'
                    Error   = "未知 Job 状态：$($jobItem.State)"
                }
                $failures += $jobName
            }
        }

        # 清理 Job，释放资源
        Remove-Job -Job $jobItem -Force -ErrorAction SilentlyContinue
    }

    # 清理 fallback 存储
    if ($script:__FallbackResults) {
        $script:__FallbackResults = @{}
    }

    return @{
        Results  = $results
        Timeouts = $timeouts
        Failures = $failures
    }
}

<#
.SYNOPSIS
    串行运行单个模块（用于 Phase 1 和 Phase 3 等依赖/互斥场景）。
.DESCRIPTION
    若有超时要求（TimeoutSeconds > 0），通过 Start-Job + Wait-Job 包装执行；
    若超时 <= 0，直接在当前进程调用 ScriptBlock。
    执行完成后通过 Collect-JobResults 统一收集结果和日志。
.PARAMETER ModuleName
    模块名称，如 "M02"、"M08"。
.PARAMETER ScriptBlock
    需要执行的 ScriptBlock，必须能接收 param($Data) 参数。
.PARAMETER ContextData
    传给 ScriptBlock 的上下文数据对象。
.PARAMETER TimeoutSeconds
    超时秒数，默认 5 秒。设为 0 或负数则不设超时直接执行。
.PARAMETER LogWriter
    日志写入回调 ScriptBlock，签名：param([hashtable]$Event)。
.EXAMPLE
    $result = Run-PhaseSerial -ModuleName "M08" -ScriptBlock $sb -ContextData $ctx -LogWriter ${function:Write-Log}
#>
function Run-PhaseSerial {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [object]$ContextData,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 5,

        [Parameter(Mandatory = $true)]
        [scriptblock]$LogWriter
    )

    if ($TimeoutSeconds -gt 0) {
        # 通过 Start-Job 包装执行，以支持超时控制
        $job = Start-Job -Name $ModuleName -ScriptBlock $ScriptBlock -ArgumentList $ContextData

        # 等待 Job 完成或超时
        $waitResult = Wait-PhaseJobs -Jobs @($job) -TimeoutSeconds $TimeoutSeconds

        # 如果超时，标记结果
        if ($waitResult.TimedOut.Count -gt 0) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $result = @{
                Diagnosis = @{
                    Module  = $ModuleName
                    Verdict = 'TIMEOUT'
                    Error   = "串行模块 [${ModuleName}] 执行超时 (${TimeoutSeconds}s)"
                }
                LogEvents = @()
            }
            # 写入日志
            foreach ($event in $result.LogEvents) {
                try { & $LogWriter $event } catch { }
            }
            return $result.Diagnosis
        }
    }
    else {
        # 无超时限制，直接在当前进程中调用
        try {
            $directResult = & $ScriptBlock -Data $ContextData
            if ($directResult -is [hashtable]) {
                # 写入日志事件
                if ($directResult.ContainsKey('LogEvents')) {
                    foreach ($event in $directResult.LogEvents) {
                        try { & $LogWriter $event } catch { }
                    }
                }
                if ($directResult.ContainsKey('Diagnosis')) {
                    return $directResult.Diagnosis
                }
                return @{
                    Module  = $ModuleName
                    Verdict = 'FAIL'
                    Error   = 'ScriptBlock 返回的哈希表缺少 Diagnosis 键'
                }
            }
            return @{
                Module  = $ModuleName
                Verdict = 'FAIL'
                Error   = "ScriptBlock 返回值类型无效：$($directResult.GetType().Name)"
            }
        }
        catch {
            return @{
                Module  = $ModuleName
                Verdict = 'FAIL'
                Error   = "直接执行异常：$($_.Exception.Message)"
            }
        }
    }

    # 收集 Job 结果
    $collected = Collect-JobResults -Jobs @($job) -LogWriter $LogWriter

    if ($collected.Results.ContainsKey($ModuleName)) {
        return $collected.Results[$ModuleName]
    }

    # 如果结果中没有该模块（异常情况）
    return @{
        Module  = $ModuleName
        Verdict = 'FAIL'
        Error   = '未收集到模块执行结果'
    }
}

<#
.SYNOPSIS
    返回预定义的 Phase 调度表。
.DESCRIPTION
    描述 4 个 Phase 的调度信息：
    - Phase 0: 并行执行基础网络检测模块
    - Phase 1: 串行执行依赖 M01 结果的模块
    - Phase 2: 并行执行依赖 M02 结果的模块
    - Phase 3: 串行执行 netsh 互斥命令模块
.EXAMPLE
    $schedule = Get-PhaseSchedule
#>
function Get-PhaseSchedule {
    [CmdletBinding()]
    param()

    return @(
        @{
            Phase   = 0
            Modules = @('M01', 'M05', 'M07', 'M09')
            Mode    = 'Parallel'
        },
        @{
            Phase     = 1
            Modules   = @('M02')
            Mode      = 'Serial'
            DependsOn = 'M01'
        },
        @{
            Phase     = 2
            Modules   = @('M03', 'M04', 'M10')
            Mode      = 'Parallel'
            DependsOn = 'M02'
        },
        @{
            Phase     = 3
            Modules   = @('M08')
            Mode      = 'Serial'
            DependsOn = '*'
        }
    )
}

# ============================================================================
# 公共 API（通过 dot-source 加载后自动导出）
# ============================================================================
# Invoke-PhaseJobs    - 启动 Phase 并行 Job
# Wait-PhaseJobs      - 等待 Phase Job 完成
# Collect-JobResults  - 收集 Job 结果与日志
# Run-PhaseSerial     - 串行运行单个模块
# Get-PhaseSchedule   - 获取 Phase 调度表
# Set-JobTimeout      - 设置单 Job 超时监控
