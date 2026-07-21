<#
.SYNOPSIS
    NetAid M05 防火墙检测与修复模块
.DESCRIPTION
    检测 Windows 防火墙配置文件状态、出站阻止规则、MpsSvc/BFE 服务状态，
    以及第三方防火墙接管情况。修复功能支持备份当前规则后重置防火墙至出厂默认。
.NOTES
    文件名: M05_Firewall.ps1
    依赖: Logger.ps1 (Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent)
          Utils.ps1 (Backup-RegistryKey)
    兼容: Windows PowerShell 5.1，零第三方依赖
    超时目标: 诊断 500ms
#>

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    通过 Get-NetFirewallProfile cmdlet 获取防火墙配置文件信息
.DESCRIPTION
    返回 Domain/Private/Public 三个配置文件的启用状态和默认操作。
    若 cmdlet 不可用，返回 $null。
#>
function Get-FirewallProfilesViaCmdlet {
    try {
        $profiles = Get-NetFirewallProfile -All -ErrorAction Stop
        $result = @()
        foreach ($p in $profiles) {
            $result += @{
                Name           = $p.Name
                Enabled        = ($p.Enabled -eq [Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetSecurity.ProfileEnabled]::True)
                InboundAction  = $p.DefaultInboundAction.ToString()
                OutboundAction = $p.DefaultOutboundAction.ToString()
            }
        }
        return $result
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    通过 netsh advfirewall show allprofiles 文本解析获取防火墙配置（回退方案）
.DESCRIPTION
    解析 netsh 输出中的 State 和 Firewall Policy 字段，提取各配置文件的启用状态和默认操作。
    兼容中英文系统语言环境。
#>
function Get-FirewallProfilesViaNetsh {
    try {
        $output = netsh advfirewall show allprofiles 2>&1
        $text = if ($output -is [array]) { $output -join "`n" } else { "$output" }

        $profiles = @()
        # 按"Profile Settings"或"配置文件设置"分段
        $sections = $text -split '(?=(?:Domain|Private|Public|域|专用|公用)\s+(?:Profile Settings|配置文件设置))'

        foreach ($section in $sections) {
            if ($section -notmatch '(Profile Settings|配置文件设置)') { continue }

            # 确定配置文件名称
            $profileName = ''
            if ($section -match 'Domain') { $profileName = 'Domain' }
            elseif ($section -match 'Private|专用') { $profileName = 'Private' }
            elseif ($section -match 'Public|公用') { $profileName = 'Public' }
            else { continue }

            # 提取 State (ON/OFF)
            $state = 'OFF'
            if ($section -match 'State\s+ON') { $state = 'ON' }
            elseif ($section -match 'State\s+OFF') { $state = 'OFF' }
            # 中文系统可能输出"状态"
            if ($section -match '状态\s+启用') { $state = 'ON' }
            elseif ($section -match '状态\s+禁用') { $state = 'OFF' }

            # 提取 Firewall Policy (BlockInbound,AllowOutbound 等)
            $inboundAction = 'Allow'
            $outboundAction = 'Allow'
            if ($section -match 'Firewall Policy\s+(.+)') {
                $policy = $Matches[1].Trim()
                if ($policy -match 'BlockInbound') { $inboundAction = 'Block' }
                if ($policy -match 'BlockOutbound') { $outboundAction = 'Block' }
            }
            # 中文系统可能输出"防火墙策略"
            if ($section -match '防火墙策略\s+(.+)') {
                $policy = $Matches[1].Trim()
                if ($policy -match '阻止入站|BlockInbound') { $inboundAction = 'Block' }
                if ($policy -match '阻止出站|BlockOutbound') { $outboundAction = 'Block' }
            }

            $profiles += @{
                Name           = $profileName
                Enabled        = ($state -eq 'ON')
                InboundAction  = $inboundAction
                OutboundAction = $outboundAction
            }
        }

        if ($profiles.Count -gt 0) { return $profiles }
        return $null
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    获取异常出站阻止规则列表（非 Microsoft/Windows/Core 的阻止规则）
.DESCRIPTION
    使用 Get-NetFirewallRule 查找启用的出站 Block 规则，过滤掉已知系统规则。
    若 cmdlet 不可用，返回 $null 表示跳过此项检测。
#>
function Get-AbnormalBlockRules {
    try {
        $rules = Get-NetFirewallRule -Direction Outbound -Action Block -Enabled True -ErrorAction Stop

        $abnormal = @()
        foreach ($rule in $rules) {
            $name = $rule.DisplayName
            # 过滤已知的 Microsoft/Windows 默认规则
            if ($name -match 'Core|Windows|Microsoft') { continue }

            $abnormal += @{
                DisplayName = $name
                Direction   = 'Outbound'
                Action      = 'Block'
                Enabled     = $true
                Program     = if ($rule.Program) { $rule.Program } else { '' }
            }
        }
        return $abnormal
    }
    catch {
        # cmdlet 不可用时返回 $null，由调用方判断为"无法检测"
        return $null
    }
}

<#
.SYNOPSIS
    检测是否存在第三方防火墙接管
.DESCRIPTION
    通过检查 MpsSvc 服务状态、防火墙配置文件状态的一致性判断。
    若 MpsSvc 已停止但防火墙配置文件显示为 Enabled，说明有第三方防火墙接管。
    同时检查注册表中是否有关联的第三方防火墙注册信息。
#>
function Test-ThirdPartyTakeover {
    param(
        [array]$FirewallProfiles,
        [bool]$MpsSvcRunning
    )

    # 核心判断：MpsSvc 停止但防火墙配置文件启用 → 第三方接管
    if (-not $MpsSvcRunning) {
        $anyEnabled = $false
        foreach ($p in $FirewallProfiles) {
            if ($p.Enabled) {
                $anyEnabled = $true
                break
            }
        }
        if ($anyEnabled) {
            return $true
        }
    }

    # 辅助判断：检查注册表中是否有非 Microsoft 的防火墙注册信息
    try {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
        if (Test-Path $regPath) {
            $standardProfile = Get-ItemProperty "$regPath\StandardProfile" -ErrorAction SilentlyContinue
            # 如果防火墙由 GPO 管理且 MpsSvc 异常，也算接管
            if ($standardProfile -and $standardProfile.DoNotAllowExceptions -eq 1 -and -not $MpsSvcRunning) {
                return $true
            }
        }
    }
    catch {
        # 注册表读取失败，忽略
    }

    return $false
}

<#
.SYNOPSIS
    安全获取 Get-NetFirewallProfile（带降级）
.DESCRIPTION
    优先使用 cmdlet，不可用时回退到 netsh 文本解析。
#>
function Get-FirewallProfilesSafe {
    $profiles = Get-FirewallProfilesViaCmdlet
    if ($null -eq $profiles) {
        $profiles = Get-FirewallProfilesViaNetsh
    }
    if ($null -eq $profiles) {
        # 完全无法获取时返回空数组
        return @()
    }
    return $profiles
}

<#
.SYNOPSIS
    检查指定 Windows 服务的运行状态
.DESCRIPTION
    返回包含 Running 布尔值和 Status 字符串的哈希表。
    服务不存在时返回 NotExist 状态。
#>
function Test-ServiceRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    try {
        $svc = Get-Service -Name $ServiceName -ErrorAction Stop
        return @{
            Running = ($svc.Status -eq 'Running')
            Status  = $svc.Status.ToString()
        }
    }
    catch {
        return @{
            Running = $false
            Status  = 'NotExist'
        }
    }
}

# ============================================================
# 公共函数
# ============================================================

<#
.SYNOPSIS
    执行 M05 防火墙诊断
.DESCRIPTION
    检测 Windows 防火墙配置文件、出站阻止规则、MpsSvc/BFE 服务状态，
    以及第三方防火墙接管情况。
.PARAMETER Context
    上下文哈希表（初始为空，可包含额外环境信息）。
.OUTPUTS
    @{ Diagnosis=@{...}; LogEvents=@(...) }
#>
function Invoke-M05_Diagnose {
    param(
        [hashtable]$Context = @{}
    )

    # 计时器
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $logEvents = @()

    # 默认诊断结构
    $diagnosis = @{
        FirewallProfiles    = @()
        ServiceRunning      = $false
        AbnormalBlockRules  = @()
        ThirdPartyTakeover  = $false
        Verdict             = 'UNKNOWN'
    }

    # 预初始化 try 块中使用的变量，防止异常时 Write-DiagnosisEvent 引用未定义变量
    $profiles = @()
    $mpsSvc = @{ Running = $false; Status = 'Unknown' }
    $bfeSvc = @{ Running = $false; Status = 'Unknown' }
    $blockOutboundDetected = $false

    try {
        # ---- 1. 检测防火墙配置文件 ----
        $profiles = Get-FirewallProfilesSafe
        $diagnosis.FirewallProfiles = $profiles

        if ($profiles.Count -eq 0) {
            # 完全无法获取防火墙配置信息
            Write-ErrorEvent -Severity 'high' -Message '无法获取 Windows 防火墙配置信息，cmdlet 和 netsh 均不可用' -StackTrace ''
            $diagnosis.Verdict = 'FAIL'
            $sw.Stop()
            Write-DiagnosisEvent -Module 'M05' -Verdict $diagnosis.Verdict -ElapsedMs $sw.ElapsedMilliseconds -ExtraFields @{
                profiles_count = 0
                reason         = '无法获取防火墙配置'
            }
            return @{
                Diagnosis = $diagnosis
                LogEvents = $logEvents
            }
        }

        # ---- 2. 检测 MpsSvc 和 BFE 服务 ----
        $mpsSvc = Test-ServiceRunning -ServiceName 'MpsSvc'
        $bfeSvc = Test-ServiceRunning -ServiceName 'BFE'
        $diagnosis.ServiceRunning = ($mpsSvc.Running -and $bfeSvc.Running)

        # ---- 3. 检查 DefaultOutboundAction = Block（严重异常） ----
        $blockOutboundDetected = $false
        foreach ($p in $profiles) {
            if ($p.OutboundAction -eq 'Block') {
                $blockOutboundDetected = $true
                break
            }
        }

        # ---- 4. 检测异常出站阻止规则 ----
        $abnormalRules = Get-AbnormalBlockRules
        if ($null -ne $abnormalRules) {
            $diagnosis.AbnormalBlockRules = $abnormalRules
        }
        # 若 $abnormalRules 为 $null，表示 cmdlet 不可用，保持空数组且不计入判定

        # ---- 5. 检测第三方防火墙接管 ----
        $diagnosis.ThirdPartyTakeover = Test-ThirdPartyTakeover -FirewallProfiles $profiles -MpsSvcRunning $mpsSvc.Running

        # ---- 6. 综合判定 Verdict ----
        if ($blockOutboundDetected) {
            # DefaultOutboundAction = Block 是严重异常
            $diagnosis.Verdict = 'FAIL'
        }
        elseif (-not $mpsSvc.Running) {
            # MpsSvc 停止，可能是第三方防火墙卸载残留
            if ($diagnosis.ThirdPartyTakeover) {
                $diagnosis.Verdict = 'WARN'
            }
            else {
                $diagnosis.Verdict = 'WARN'
            }
        }
        elseif ($abnormalRules -ne $null -and $abnormalRules.Count -gt 0) {
            # 存在非默认的阻止规则
            $diagnosis.Verdict = 'WARN'
        }
        elseif (-not $bfeSvc.Running) {
            # BFE 停止但 MpsSvc 运行（异常状态）
            $diagnosis.Verdict = 'WARN'
        }
        else {
            # 所有检测通过
            $diagnosis.Verdict = 'PASS'
        }

        $sw.Stop()
    }
    catch {
        # 未预期的异常
        $sw.Stop()
        $diagnosis.Verdict = 'FAIL'
        Write-ErrorEvent -Severity 'high' -Message "M05 诊断异常: $($_.Exception.Message)" -StackTrace $_.ScriptStackTrace
    }

    # 写入诊断事件日志
    $extraFields = @{
        profiles_count       = $profiles.Count
        abnormal_rules_count = $diagnosis.AbnormalBlockRules.Count
        mps_svc_running      = $mpsSvc.Running
        bfe_svc_running      = $bfeSvc.Running
        third_party_takeover = $diagnosis.ThirdPartyTakeover
        block_outbound       = $blockOutboundDetected
    }
    Write-DiagnosisEvent -Module 'M05' -Verdict $diagnosis.Verdict -ElapsedMs $sw.ElapsedMilliseconds -ExtraFields $extraFields

    return @{
        Diagnosis = $diagnosis
        LogEvents = $logEvents
    }
}

<#
.SYNOPSIS
    执行 M05 防火墙修复
.DESCRIPTION
    备份当前防火墙规则，确保 MpsSvc 和 BFE 服务运行，执行 netsh advfirewall reset 恢复出厂默认。
    风险等级: L3（中，清空所有自定义规则）
.PARAMETER Diagnosis
    诊断结果哈希表（来自 Invoke-M05_Diagnose 的输出）。
.OUTPUTS
    @{ Repair=@{Verdict; RebootRequired; Steps}; LogEvents=@(...) }
#>
function Invoke-M05_Repair {
    param(
        [hashtable]$Diagnosis = @{}
    )

    $logEvents = @()
    # 使用 ArrayList 避免 PowerShell 数组 += 重建导致引用丢失
    $steps = [System.Collections.ArrayList]::new()
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    # 默认修复结构（Steps 在返回前统一赋值，避免引用丢失）
    $repair = @{
        Verdict        = 'failed'
        RebootRequired = $false
        Steps          = @()
    }

    try {
        # ---- 步骤0: 检查诊断结果，确认是否需要修复 ----
        # 根据诊断结果判断是否有可修复的问题
        $diagnosisVerdict = ''
        if ($Diagnosis.ContainsKey('Diagnosis') -and $Diagnosis.Diagnosis -is [hashtable]) {
            $diag = $Diagnosis.Diagnosis
            $diagnosisVerdict = if ($diag.ContainsKey('Verdict')) { $diag.Verdict } else { '' }
        }

        if ($diagnosisVerdict -eq 'PASS') {
            # 没有检测到问题，跳过修复
            $repair.Verdict = 'skipped'
            [void]$steps.Add('诊断结果为 PASS，无需修复，跳过')
            Write-FixEvent -Module 'M05' -EventSubType 'step' -Step '跳过修复（诊断PASS）' -ExitCode 0
            Write-FixEvent -Module 'M05' -EventSubType 'end' -Verdict 'skipped' -RebootRequired $false
            $repair.Steps = $steps
            return @{
                Repair    = $repair
                LogEvents = $logEvents
            }
        }

        # ---- 步骤1: 备份当前防火墙规则 ----
        # 构建备份目录路径（从 modules 向上两级: modules -> NetAid -> 项目根 -> backups）
        # 使用 Split-Path 链式调用兼容 PS 5.1（Join-Path 仅支持单个 -ChildPath）
        $netAidRoot = Split-Path $PSScriptRoot -Parent
        $projectRoot = Split-Path $netAidRoot -Parent
        $backupDir = Join-Path $projectRoot 'backups'
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }

        # 1a) 导出防火墙策略文件 (.wfw)
        $wfwBackupPath = Join-Path $backupDir "firewall_backup_${timestamp}.wfw"
        $exportResult = netsh advfirewall export $wfwBackupPath 2>&1
        $exportExitCode = $LASTEXITCODE

        if ($exportExitCode -eq 0) {
            [void]$steps.Add("防火墙策略已备份至: $wfwBackupPath")
            Write-FixEvent -Module 'M05' -EventSubType 'step' -Step "备份防火墙策略: $wfwBackupPath" -ExitCode 0
        }
        else {
            [void]$steps.Add("防火墙策略备份失败: $exportResult")
            Write-FixEvent -Module 'M05' -EventSubType 'step' -Step "备份防火墙策略失败" -ExitCode $exportExitCode
            Write-ErrorEvent -Severity 'medium' -Message "防火墙策略导出失败: $exportResult" -StackTrace ''
            # 备份失败不阻断修复，继续执行
        }

        # 1b) 导出规则文本详情 (.txt)
        $txtBackupPath = Join-Path $backupDir "firewall_rules_${timestamp}.txt"
        try {
            $rulesOutput = netsh advfirewall show rule name=all verbose 2>&1
            $rulesText = if ($rulesOutput -is [array]) { $rulesOutput -join "`r`n" } else { "$rulesOutput" }
            [System.IO.File]::WriteAllText($txtBackupPath, $rulesText, [System.Text.Encoding]::UTF8)
            [void]$steps.Add("防火墙规则详情已备份至: $txtBackupPath")
            Write-FixEvent -Module 'M05' -EventSubType 'step' -Step "备份规则文本: $txtBackupPath" -ExitCode 0
        }
        catch {
            [void]$steps.Add("防火墙规则文本备份失败: $_")
            Write-FixEvent -Module 'M05' -EventSubType 'step' -Step "备份规则文本失败" -ExitCode 1
            Write-ErrorEvent -Severity 'low' -Message "防火墙规则文本导出失败: $_" -StackTrace ''
        }

        # ---- 步骤2: 确保 MpsSvc 和 BFE 服务运行 ----
        $servicesToStart = @('MpsSvc', 'BFE')
        foreach ($svcName in $servicesToStart) {
            try {
                $svc = Get-Service -Name $svcName -ErrorAction Stop
                if ($svc.Status -ne 'Running') {
                    Start-Service -Name $svcName -ErrorAction Stop
                    [void]$steps.Add("已启动服务: $svcName")
                    Write-FixEvent -Module 'M05' -EventSubType 'step' -Step "启动服务 $svcName" -ExitCode 0
                }
                else {
                    [void]$steps.Add("服务已在运行: $svcName")
                }
            }
            catch {
                [void]$steps.Add("启动服务失败: $svcName - $_")
                Write-FixEvent -Module 'M05' -EventSubType 'step' -Step "启动服务 $svcName 失败" -ExitCode 1
                Write-ErrorEvent -Severity 'high' -Message "无法启动 $svcName 服务: $_" -StackTrace ''
            }
        }

        # 验证服务状态
        $mpsRunning = $false
        $bfeRunning = $false
        try { $mpsRunning = ((Get-Service -Name 'MpsSvc' -ErrorAction SilentlyContinue).Status -eq 'Running') } catch {}
        try { $bfeRunning = ((Get-Service -Name 'BFE' -ErrorAction SilentlyContinue).Status -eq 'Running') } catch {}

        if (-not $mpsRunning -or -not $bfeRunning) {
            $repair.Verdict = 'failed'
            [void]$steps.Add('关键服务未能启动，修复中止')
            Write-FixEvent -Module 'M05' -EventSubType 'end' -Verdict 'failed' -RebootRequired $false
            Write-ErrorEvent -Severity 'high' -Message 'MpsSvc 或 BFE 服务未能启动，防火墙重置中止' -StackTrace ''
            $repair.Steps = $steps
            return @{
                Repair    = $repair
                LogEvents = $logEvents
            }
        }

        # ---- 步骤3: 执行 netsh advfirewall reset ----
        $resetResult = netsh advfirewall reset 2>&1
        $resetExitCode = $LASTEXITCODE

        if ($resetExitCode -eq 0) {
            [void]$steps.Add('netsh advfirewall reset 执行成功，防火墙已恢复出厂默认')
            Write-FixEvent -Module 'M05' -EventSubType 'step' -Step 'netsh advfirewall reset' -ExitCode 0
        }
        else {
            [void]$steps.Add("netsh advfirewall reset 执行失败: $resetResult")
            Write-FixEvent -Module 'M05' -EventSubType 'step' -Step 'netsh advfirewall reset 失败' -ExitCode $resetExitCode
            Write-ErrorEvent -Severity 'high' -Message "防火墙重置失败: $resetResult" -StackTrace ''

            $repair.Verdict = 'failed'
            # 提示回退命令
            [void]$steps.Add("如需回退，请执行: netsh advfirewall import `"$wfwBackupPath`"")
            Write-FixEvent -Module 'M05' -EventSubType 'end' -Verdict 'failed' -RebootRequired $false
            $repair.Steps = $steps
            return @{
                Repair    = $repair
                LogEvents = $logEvents
            }
        }

        # ---- 步骤4: 验证修复结果 ----
        # 重新获取防火墙配置文件，确认 DefaultOutboundAction = Allow
        $verifyProfiles = Get-FirewallProfilesSafe
        $verifyPassed = $true
        if ($verifyProfiles.Count -gt 0) {
            foreach ($p in $verifyProfiles) {
                if ($p.OutboundAction -eq 'Block') {
                    $verifyPassed = $false
                    [void]$steps.Add("验证失败: $($p.Name) 配置文件的 DefaultOutboundAction 仍为 Block")
                    break
                }
            }
            if ($verifyPassed) {
                [void]$steps.Add('验证通过: 所有配置文件的 DefaultOutboundAction 均为 Allow')
            }
        }
        else {
            [void]$steps.Add('验证警告: 无法重新获取防火墙配置信息以验证修复结果')
            # 无法验证时不阻断，reset 已成功执行
        }

        # ---- 步骤5: 给出回退提示 ----
        [void]$steps.Add("如发现问题可回退: netsh advfirewall import `"$wfwBackupPath`"")

        if ($verifyPassed) {
            $repair.Verdict = 'success'
        }
        else {
            $repair.Verdict = 'failed'
        }

        Write-FixEvent -Module 'M05' -EventSubType 'end' -Verdict $repair.Verdict -RebootRequired $false
    }
    catch {
        # 未预期的修复异常
        $repair.Verdict = 'failed'
        [void]$steps.Add("修复过程中发生未预期异常: $($_.Exception.Message)")
        Write-ErrorEvent -Severity 'high' -Message "M05 修复异常: $($_.Exception.Message)" -StackTrace $_.ScriptStackTrace
        Write-FixEvent -Module 'M05' -EventSubType 'end' -Verdict 'failed' -RebootRequired $false
    }

    # 最终统一赋值 Steps（ArrayList 引用在 .Add() 后保持有效）
    $repair.Steps = $steps
    return @{
        Repair    = $repair
        LogEvents = $logEvents
    }
}

# ============================================================
# 模块导出说明
# ============================================================
# 此脚本设计为被主脚本 dot-source 引用或通过 Invoke-PhaseJobs 并行调用。
# 导出函数: Invoke-M05_Diagnose, Invoke-M05_Repair
# 依赖的 lib 函数: Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent, Backup-RegistryKey
# 这些函数应在主脚本中先 dot-source Logger.ps1 和 Utils.ps1 后自动可用。
