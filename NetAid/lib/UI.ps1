<#
.SYNOPSIS
    NetAid UI 模块 - 断网急救箱用户界面组件
.DESCRIPTION
    提供统一的控制台 UI 输出功能，包括彩色输出、进度条、菜单、报告等。
    兼容 Windows PowerShell 5.1，零第三方依赖。
.NOTES
    脚本级变量：
        $Script:ColorEnabled  - 是否启用彩色输出（默认 $true）
        $Script:ConsoleWidth  - 控制台宽度（默认 120，最小 60）
#>

# ============================================================
# 脚本级变量
# ============================================================
$Script:ColorEnabled = $true

# 初始化控制台宽度：优先从 Host.UI.RawUI 获取，失败时回退到默认值 120
try {
    $rawWidth = $Host.UI.RawUI.WindowSize.Width
    if ($rawWidth -lt 60) {
        $Script:ConsoleWidth = 60
    } elseif ($rawWidth -gt 120) {
        $Script:ConsoleWidth = 120
    } else {
        $Script:ConsoleWidth = $rawWidth
    }
} catch {
    $Script:ConsoleWidth = 120
}

# ============================================================
# 辅助函数：获取安全的主机 UI 宽度
# ============================================================
function Get-SafeWidth {
    <#
    .SYNOPSIS
        安全获取控制台宽度，带异常保护
    #>
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -lt 60) { return 60 }
        if ($w -gt 120) { return 120 }
        return $w
    } catch {
        return 120
    }
}

# ============================================================
# Write-ColorLine
# ============================================================
function Write-ColorLine {
    <#
    .SYNOPSIS
        输出带颜色的行
    .PARAMETER Text
        要输出的文本
    .PARAMETER Color
        颜色名称，默认 "White"
    .PARAMETER NoNewline
        是否不换行
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$Text,
        [string]$Color = "White",
        [switch]$NoNewline
    )

    if ($Script:ColorEnabled) {
        Write-Host -Object $Text -ForegroundColor $Color -NoNewline:$NoNewline
    } else {
        if ($NoNewline) {
            Write-Output -InputObject $Text -NoEnumerate
        } else {
            Write-Output -InputObject $Text
        }
    }
}

# ============================================================
# Write-Separator
# ============================================================
function Write-Separator {
    <#
    .SYNOPSIS
        输出宽度适配的分隔线
    .PARAMETER Char
        分隔符字符，默认 "-"
    .PARAMETER Color
        颜色，默认 "Cyan"
    #>
    param(
        [string]$Char = "-",
        [string]$Color = "Cyan"
    )

    $width = Get-SafeWidth
    $line = $Char * $width
    Write-ColorLine -Text $line -Color $Color
}

# ============================================================
# Write-Banner
# ============================================================
function Write-Banner {
    <#
    .SYNOPSIS
        显示程序横幅（双线框）
    .PARAMETER Version
        版本号，默认 "1.0.0"
    #>
    param(
        [string]$Version = "1.0.0"
    )

    $width = Get-SafeWidth
    # 内框宽度 = 总宽度 - 2（左右边框各占1个字符位置）
    $innerWidth = $width - 2
    if ($innerWidth -lt 10) { $innerWidth = 10 }

    # 中文标题行
    $cnTitle = "断 网 急 救 箱  v$Version"
    # 英文副标题行
    $enTitle = "Windows Network First Aid"

    # 计算中文标题的显示宽度（中文字符约占2个英文字符宽度）
    $cnDisplayWidth = 0
    foreach ($ch in $cnTitle.ToCharArray()) {
        if ([int]$ch -gt 127) {
            $cnDisplayWidth += 2
        } else {
            $cnDisplayWidth += 1
        }
    }
    $enDisplayWidth = $enTitle.Length

    $cnPadding = [Math]::Max(0, [Math]::Floor(($innerWidth - $cnDisplayWidth) / 2))
    $cnLeftPad = ' ' * $cnPadding
    # 右侧填充（考虑中英文混排导致的宽度差异）
    $cnRightNeeded = $innerWidth - $cnDisplayWidth - $cnPadding
    if ($cnRightNeeded -lt 0) { $cnRightNeeded = 0 }
    $cnRightPad = ' ' * $cnRightNeeded

    $enPadding = [Math]::Max(0, [Math]::Floor(($innerWidth - $enDisplayWidth) / 2))
    $enLeftPad = ' ' * $enPadding
    $enRightNeeded = $innerWidth - $enDisplayWidth - $enPadding
    if ($enRightNeeded -lt 0) { $enRightNeeded = 0 }
    $enRightPad = ' ' * $enRightNeeded

    # 构建各行
    $topLine    = [char]0x2554 + ("$([char]0x2550)" * $innerWidth) + [char]0x2557
    $cnLine     = [char]0x2551 + $cnLeftPad + $cnTitle + $cnRightPad + [char]0x2551
    $enLine     = [char]0x2551 + $enLeftPad + $enTitle + $enRightPad + [char]0x2551
    $bottomLine = [char]0x255A + ("$([char]0x2550)" * $innerWidth) + [char]0x255D

    Write-ColorLine -Text "" -Color "Cyan"
    Write-ColorLine -Text $topLine -Color "Cyan"
    Write-ColorLine -Text $cnLine -Color "Cyan"
    Write-ColorLine -Text $enLine -Color "Cyan"
    Write-ColorLine -Text $bottomLine -Color "Cyan"
    Write-ColorLine -Text "" -Color "Cyan"
}

# ============================================================
# Show-MainMenu
# ============================================================
function Show-MainMenu {
    <#
    .SYNOPSIS
        显示主菜单并读取用户选择
    .PARAMETER IsAdmin
        是否以管理员权限运行
    .PARAMETER OSInfo
        操作系统信息字符串
    .PARAMETER NetworkStatus
        网络状态字符串
    #>
    param(
        [Parameter(Mandatory=$true)]
        [bool]$IsAdmin,
        [Parameter(Mandatory=$true)]
        [string]$OSInfo,
        [Parameter(Mandatory=$true)]
        [string]$NetworkStatus
    )

    $width = Get-SafeWidth
    $innerWidth = $width - 2
    if ($innerWidth -lt 10) { $innerWidth = 10 }

    $topLine    = [char]0x2554 + ("$([char]0x2550)" * $innerWidth) + [char]0x2557
    $bottomLine = [char]0x255A + ("$([char]0x2550)" * $innerWidth) + [char]0x255D

    Clear-Host

    # 显示横幅
    Write-Banner -Version "1.0.0"

    # 菜单框头部
    Write-ColorLine -Text $topLine -Color "Cyan"

    # 菜单标题
    $menuTitle = "  主  菜  单"
    $menuPadding = [Math]::Max(0, [Math]::Floor(($innerWidth - 11) / 2))
    $menuLine = [char]0x2551 + (' ' * $menuPadding) + $menuTitle + (' ' * ($innerWidth - $menuPadding - 11)) + [char]0x2551
    Write-ColorLine -Text $menuLine -Color "Cyan"

    # 分隔线
    $sepLine = [char]0x2551 + ('-' * $innerWidth) + [char]0x2551
    Write-ColorLine -Text $sepLine -Color "Cyan"

    # 菜单项（左侧序号，右侧说明）
    $menuItems = @(
        @{Num="[1]"; Desc="全面诊断 - 运行所有诊断模块，生成完整报告"},
        @{Num="[2]"; Desc="自动修复 - 自动诊断并修复所有可修复的问题"},
        @{Num="[3]"; Desc="单项诊断 - 选择特定模块进行诊断"},
        @{Num="[4]"; Desc="单项修复 - 选择特定模块进行修复"},
        @{Num="[5]"; Desc="生成报告 - 将诊断结果导出为报告文件"},
        @{Num="[6]"; Desc="查看历史 - 浏览历史诊断和修复记录"},
        @{Num="[7]"; Desc="帮助说明 - 查看命令行参数和使用说明"},
        @{Num="[0]"; Desc="退出程序"}
    )

    foreach ($item in $menuItems) {
        # 格式: [1] 全面诊断 - 运行所有诊断模块...
        $itemText = "$($item.Num) $($item.Desc)"
        $displayWidth = 0
        foreach ($ch in $itemText.ToCharArray()) {
            if ([int]$ch -gt 127) { $displayWidth += 2 } else { $displayWidth += 1 }
        }
        $rightPad = $innerWidth - $displayWidth - 1  # -1 for the leading space
        if ($rightPad -lt 1) { $rightPad = 1 }
        $line = [char]0x2551 + ' ' + $itemText + (' ' * $rightPad) + [char]0x2551
        Write-ColorLine -Text $line -Color "White"
    }

    # 分隔线
    Write-ColorLine -Text $sepLine -Color "Cyan"

    # 底部信息区
    # 权限状态
    if ($IsAdmin) {
        $permText = "权限: 管理员"
    } else {
        $permText = "权限: 普通用户"
    }
    $permColor = if ($IsAdmin) { "Magenta" } else { "Yellow" }
    $permLine = [char]0x2551 + ' ' + $permText + (' ' * ($innerWidth - $permText.Length - 1)) + [char]0x2551
    Write-ColorLine -Text $permLine -Color $permColor

    # 系统版本
    $osText = "系统: $OSInfo"
    if ($osText.Length -gt ($innerWidth - 2)) {
        $osText = $osText.Substring(0, $innerWidth - 2)
    }
    $osLine = [char]0x2551 + ' ' + $osText + (' ' * ($innerWidth - $osText.Length - 1)) + [char]0x2551
    Write-ColorLine -Text $osLine -Color "DarkGray"

    # 网络状态
    $netText = "网络: $NetworkStatus"
    if ($netText.Length -gt ($innerWidth - 2)) {
        $netText = $netText.Substring(0, $innerWidth - 2)
    }
    $netColor = "White"
    if ($NetworkStatus -eq "未连接") {
        $netColor = "Red"
    } elseif ($NetworkStatus -match "已连接") {
        $netColor = "Green"
    }
    $netLine = [char]0x2551 + ' ' + $netText + (' ' * ($innerWidth - $netText.Length - 1)) + [char]0x2551
    Write-ColorLine -Text $netLine -Color $netColor

    Write-ColorLine -Text $bottomLine -Color "Cyan"
    Write-ColorLine -Text "" -Color "Cyan"

    # 读取用户选择
    $choice = Read-UserChoice -Prompt "请输入选项 [0-7]:" -Min 0 -Max 7
    return $choice
}

# ============================================================
# Show-ProgressHeader
# ============================================================
function Show-ProgressHeader {
    <#
    .SYNOPSIS
        显示进度阶段头部（双线框）
    .PARAMETER Title
        标题文字
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Title
    )

    $width = Get-SafeWidth
    $innerWidth = $width - 2
    if ($innerWidth -lt 10) { $innerWidth = 10 }

    $topLine    = [char]0x2554 + ("$([char]0x2550)" * $innerWidth) + [char]0x2557
    $bottomLine = [char]0x255A + ("$([char]0x2550)" * $innerWidth) + [char]0x255D

    # 计算中文标题的显示宽度
    $displayWidth = 0
    foreach ($ch in $Title.ToCharArray()) {
        if ([int]$ch -gt 127) { $displayWidth += 2 } else { $displayWidth += 1 }
    }
    $padding = [Math]::Max(0, [Math]::Floor(($innerWidth - $displayWidth) / 2))
    $leftPad = ' ' * $padding
    $rightNeeded = $innerWidth - $displayWidth - $padding
    if ($rightNeeded -lt 0) { $rightNeeded = 0 }
    $rightPad = ' ' * $rightNeeded

    $titleLine = [char]0x2551 + $leftPad + $Title + $rightPad + [char]0x2551

    Write-ColorLine -Text "" -Color "Cyan"
    Write-ColorLine -Text $topLine -Color "Cyan"
    Write-ColorLine -Text $titleLine -Color "Cyan"
    Write-ColorLine -Text $bottomLine -Color "Cyan"
    Write-ColorLine -Text "" -Color "Cyan"
}

# ============================================================
# Write-ProgressLine
# ============================================================
function Write-ProgressLine {
    <#
    .SYNOPSIS
        输出单行诊断进度
    .PARAMETER Current
        当前进度序号
    .PARAMETER Total
        总模块数
    .PARAMETER ModuleName
        模块名称
    .PARAMETER Status
        状态：正常/失败/警告/跳过/超时
    #>
    param(
        [Parameter(Mandatory=$true)]
        [int]$Current,
        [Parameter(Mandatory=$true)]
        [int]$Total,
        [Parameter(Mandatory=$true)]
        [string]$ModuleName,
        [Parameter(Mandatory=$true)]
        [string]$Status
    )

    $width = Get-SafeWidth
    # 序号格式 "[01/10]"
    $numStr = "[{0:D2}/{1:D2}]" -f $Current, $Total
    # 状态文字
    $statusStr = $Status
    # 右侧填充到固定宽度的点的最小长度（给状态文字留出足够的空间）
    $statusMaxLen = 4  # 状态文字最长约4个中文字符宽度
    # 点填充的目标列位置：给状态留8个英文字符宽度
    $targetDotEnd = $width - 10

    # 构建行：序号 + 空格 + 模块名 + 点填充 + 状态
    $prefix = "$numStr "
    $prefixLen = $prefix.Length

    # 计算模块名显示宽度
    $modDisplayWidth = 0
    foreach ($ch in $ModuleName.ToCharArray()) {
        if ([int]$ch -gt 127) { $modDisplayWidth += 2 } else { $modDisplayWidth += 1 }
    }

    $dotCount = $targetDotEnd - $prefixLen - $modDisplayWidth
    if ($dotCount -lt 2) { $dotCount = 2 }
    $dots = '.' * $dotCount

    $lineText = "$prefix$ModuleName$dots$statusStr"

    # 根据状态选择颜色
    $statusColor = "White"
    switch ($Status) {
        "正常" { $statusColor = "Green" }
        "失败" { $statusColor = "Red" }
        "警告" { $statusColor = "Yellow" }
        "跳过" { $statusColor = "Gray" }
        "超时" { $statusColor = "Yellow" }
    }

    # 输出：前缀白色 + 模块名白色 + 点灰色 + 状态彩色
    if ($Script:ColorEnabled) {
        Write-Host -Object $prefix -ForegroundColor White -NoNewline
        Write-Host -Object $ModuleName -ForegroundColor White -NoNewline
        Write-Host -Object $dots -ForegroundColor DarkGray -NoNewline
        Write-Host -Object $statusStr -ForegroundColor $statusColor
    } else {
        Write-Output -InputObject $lineText
    }
}

# ============================================================
# Show-DiagnosisSummary
# ============================================================
function Show-DiagnosisSummary {
    <#
    .SYNOPSIS
        显示诊断摘要
    .PARAMETER Total
        总检测项数
    .PARAMETER Pass
        通过数
    .PARAMETER Warn
        警告数
    .PARAMETER Fail
        失败数
    .PARAMETER ElapsedSec
        耗时（秒）
    .PARAMETER Critical
        严重问题数
    #>
    param(
        [Parameter(Mandatory=$true)]
        [int]$Total,
        [Parameter(Mandatory=$true)]
        [int]$Pass,
        [Parameter(Mandatory=$true)]
        [int]$Warn,
        [Parameter(Mandatory=$true)]
        [int]$Fail,
        [Parameter(Mandatory=$true)]
        [double]$ElapsedSec,
        [Parameter(Mandatory=$true)]
        [int]$Critical
    )

    Write-Separator -Char "=" -Color "Cyan"

    # 构建摘要行
    $timeStr = "诊断耗时: {0:F1}s" -f $ElapsedSec
    $issueStr = "发现问题: {0} 项" -f ($Warn + $Fail + $Critical)
    $critStr = "严重: {0} 项" -f $Critical
    $warnStr = "警告: {0} 项" -f $Warn
    $passStr = "通过: {0} 项" -f $Pass

    # 输出摘要行各部分
    if ($Script:ColorEnabled) {
        Write-Host -Object $timeStr -ForegroundColor White -NoNewline
        Write-Host -Object "     " -NoNewline
        Write-Host -Object $issueStr -ForegroundColor $(if (($Warn + $Fail + $Critical) -gt 0) { "Yellow" } else { "Green" }) -NoNewline
        Write-Host -Object "    " -NoNewline
        Write-Host -Object $critStr -ForegroundColor $(if ($Critical -gt 0) { "Red" } else { "DarkGray" }) -NoNewline
        Write-Host -Object "    " -NoNewline
        Write-Host -Object $warnStr -ForegroundColor $(if ($Warn -gt 0) { "Yellow" } else { "DarkGray" }) -NoNewline
        Write-Host -Object "    " -NoNewline
        Write-Host -Object $passStr -ForegroundColor "Green"
    } else {
        Write-Output -InputObject "$timeStr     $issueStr    $critStr    $warnStr    $passStr"
    }

    Write-Separator -Char "=" -Color "Cyan"
}

# ============================================================
# Show-RepairProgress
# ============================================================
function Show-RepairProgress {
    <#
    .SYNOPSIS
        输出单行修复进度
    .PARAMETER Current
        当前进度序号
    .PARAMETER Total
        总修复项数
    .PARAMETER ModuleName
        模块名称
    .PARAMETER Status
        状态：成功/失败/跳过
    #>
    param(
        [Parameter(Mandatory=$true)]
        [int]$Current,
        [Parameter(Mandatory=$true)]
        [int]$Total,
        [Parameter(Mandatory=$true)]
        [string]$ModuleName,
        [Parameter(Mandatory=$true)]
        [string]$Status
    )

    $width = Get-SafeWidth
    # 序号格式
    $numStr = "[{0:D2}/{1:D2}]" -f $Current, $Total
    $prefix = "$numStr "

    # 状态前缀标记
    $statusIcon = ""
    $statusColor = "White"
    switch ($Status) {
        "成功" { $statusIcon = "[OK] "; $statusColor = "Green" }
        "失败" { $statusIcon = "[XX] "; $statusColor = "Red" }
        "跳过" { $statusIcon = "[--] "; $statusColor = "Gray" }
        default  { $statusIcon = "[  ] "; $statusColor = "White" }
    }

    # 计算模块名显示宽度
    $modDisplayWidth = 0
    foreach ($ch in $ModuleName.ToCharArray()) {
        if ([int]$ch -gt 127) { $modDisplayWidth += 2 } else { $modDisplayWidth += 1 }
    }

    $prefixLen = $prefix.Length
    $targetDotEnd = $width - 8
    $dotCount = $targetDotEnd - $prefixLen - $modDisplayWidth
    if ($dotCount -lt 2) { $dotCount = 2 }
    $dots = '.' * $dotCount

    if ($Script:ColorEnabled) {
        Write-Host -Object $prefix -ForegroundColor White -NoNewline
        Write-Host -Object $ModuleName -ForegroundColor White -NoNewline
        Write-Host -Object $dots -ForegroundColor DarkGray -NoNewline
        Write-Host -Object ($statusIcon + $Status) -ForegroundColor $statusColor
    } else {
        Write-Output -InputObject "$prefix$ModuleName$dots$statusIcon$Status"
    }
}

# ============================================================
# Show-FixConfirmation
# ============================================================
function Show-FixConfirmation {
    <#
    .SYNOPSIS
        显示修复确认界面并询问用户是否继续
    .PARAMETER Problems
        问题列表，每项含 Level, Description, Solution, Risk, Reboot, Downtime
    .PARAMETER LevelCount
        各级别计数哈希表：L1, L2, L3, L4a
    #>
    param(
        [Parameter(Mandatory=$true)]
        [array]$Problems,
        [Parameter(Mandatory=$true)]
        [hashtable]$LevelCount
    )

    Write-Separator -Char "=" -Color "Cyan"
    Write-ColorLine -Text "  修复确认 - 以下问题将被修复:" -Color "Cyan"
    Write-Separator -Char "=" -Color "Cyan"
    Write-ColorLine -Text "" -Color "White"

    if ($Problems.Count -eq 0) {
        Write-ColorLine -Text "  没有需要修复的问题。" -Color "Green"
        return $true
    }

    $index = 1
    foreach ($problem in $Problems) {
        $level = $problem.Level
        $desc = $problem.Description
        $solution = $problem.Solution
        $risk = $problem.Risk
        $reboot = $problem.Reboot
        $downtime = $problem.Downtime

        # 严重级别标记
        $levelMark = ""
        $levelColor = "White"
        switch ($level) {
            "L1"   { $levelMark = "[!!]"; $levelColor = "Red" }
            "L2"   { $levelMark = "[!] "; $levelColor = "Yellow" }
            "L3"   { $levelMark = "[i] "; $levelColor = "DarkGray" }
            "L4a"  { $levelMark = "[*] "; $levelColor = "Magenta" }
            default { $levelMark = "[?] "; $levelColor = "White" }
        }

        # 输出问题条目
        if ($Script:ColorEnabled) {
            Write-Host -Object "  $index. " -ForegroundColor White -NoNewline
            Write-Host -Object $levelMark -ForegroundColor $levelColor -NoNewline
            Write-Host -Object " $desc" -ForegroundColor White
            Write-Host -Object "     修复方案: " -ForegroundColor DarkGray -NoNewline
            Write-Host -Object $solution -ForegroundColor White
            Write-Host -Object "     风险等级: " -ForegroundColor DarkGray -NoNewline
            Write-Host -Object $risk -ForegroundColor $(if ($risk -match "高") { "Red" } elseif ($risk -match "中") { "Yellow" } else { "Green" })
            if ($reboot) {
                Write-Host -Object "     需要重启: " -ForegroundColor DarkGray -NoNewline
                Write-Host -Object "是" -ForegroundColor "Red"
            }
            if ($downtime -and $downtime -ne "无" -and $downtime -ne "0") {
                Write-Host -Object "     断网时间: " -ForegroundColor DarkGray -NoNewline
                Write-Host -Object $downtime -ForegroundColor "Yellow"
            }
        } else {
            Write-Output -InputObject "  $index. $levelMark $desc"
            Write-Output -InputObject "     修复方案: $solution"
            Write-Output -InputObject "     风险等级: $risk"
            if ($reboot) { Write-Output -InputObject "     需要重启: 是" }
            if ($downtime -and $downtime -ne "无" -and $downtime -ne "0") {
                Write-Output -InputObject "     断网时间: $downtime"
            }
        }
        Write-ColorLine -Text "" -Color "White"
        $index++
    }

    # 底部各级别统计
    Write-Separator -Char "-" -Color "DarkGray"
    Write-ColorLine -Text "  需确认的项目:" -Color "Cyan"
    $l1 = if ($LevelCount.ContainsKey("L1")) { $LevelCount["L1"] } else { 0 }
    $l2 = if ($LevelCount.ContainsKey("L2")) { $LevelCount["L2"] } else { 0 }
    $l3 = if ($LevelCount.ContainsKey("L3")) { $LevelCount["L3"] } else { 0 }
    $l4a = if ($LevelCount.ContainsKey("L4a")) { $LevelCount["L4a"] } else { 0 }

    if ($Script:ColorEnabled) {
        Write-Host -Object "    L1 严重修复: " -ForegroundColor DarkGray -NoNewline
        Write-Host -Object "$l1 项" -ForegroundColor $(if ($l1 -gt 0) { "Red" } else { "DarkGray" })
        Write-Host -Object "    L2 标准修复: " -ForegroundColor DarkGray -NoNewline
        Write-Host -Object "$l2 项" -ForegroundColor $(if ($l2 -gt 0) { "Yellow" } else { "DarkGray" })
        Write-Host -Object "    L3 低风险修复: " -ForegroundColor DarkGray -NoNewline
        Write-Host -Object "$l3 项" -ForegroundColor $(if ($l3 -gt 0) { "White" } else { "DarkGray" })
        Write-Host -Object "    L4a 需确认修复: " -ForegroundColor DarkGray -NoNewline
        Write-Host -Object "$l4a 项" -ForegroundColor $(if ($l4a -gt 0) { "Magenta" } else { "DarkGray" })
    } else {
        Write-Output -InputObject "    L1 严重修复: $l1 项"
        Write-Output -InputObject "    L2 标准修复: $l2 项"
        Write-Output -InputObject "    L3 低风险修复: $l3 项"
        Write-Output -InputObject "    L4a 需确认修复: $l4a 项"
    }

    Write-Separator -Char "-" -Color "DarkGray"
    Write-ColorLine -Text "" -Color "White"

    # 询问用户确认
    $totalIssues = $l1 + $l2 + $l3 + $l4a
    $confirmMsg = "共 $totalIssues 项待修复，是否继续？"
    return Confirm-UserAction -Message $confirmMsg -Default "Y"
}

# ============================================================
# Show-FinalReport
# ============================================================
function Show-FinalReport {
    <#
    .SYNOPSIS
        显示最终摘要报告（双线框格式）
    .PARAMETER ReportData
        哈希表，包含：Time, Hostname, OSVersion,
        DiagTotal, DiagPass, DiagWarn, DiagFail, DiagElapsed, DiagCritical,
        RepairTotal, RepairSuccess, RepairFail, RepairSkip,
        FailItems (array of strings), WarnItems (array of strings),
        FixableCount, Recommendations (array of strings)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData
    )

    $width = Get-SafeWidth
    $innerWidth = $width - 2
    if ($innerWidth -lt 10) { $innerWidth = 10 }

    $topLine    = [char]0x2554 + ("$([char]0x2550)" * $innerWidth) + [char]0x2557
    $bottomLine = [char]0x255A + ("$([char]0x2550)" * $innerWidth) + [char]0x255D
    $sepLine    = [char]0x2551 + ('-' * $innerWidth) + [char]0x2551

    # 辅助：生成内容行
    function New-ReportLine {
        param([string]$Text, [string]$Color = "White")
        $txtLen = 0
        foreach ($ch in $Text.ToCharArray()) {
            if ([int]$ch -gt 127) { $txtLen += 2 } else { $txtLen += 1 }
        }
        $right = $innerWidth - $txtLen - 1
        if ($right -lt 1) { $right = 1 }
        $line = [char]0x2551 + ' ' + $Text + (' ' * $right) + [char]0x2551
        Write-ColorLine -Text $line -Color $Color
    }

    Clear-Host
    Write-ColorLine -Text "" -Color "Cyan"
    Write-ColorLine -Text $topLine -Color "Cyan"

    # 报告标题
    $titleText = "断网急救箱 - 诊断修复报告"
    $titleDisp = 0
    foreach ($ch in $titleText.ToCharArray()) { if ([int]$ch -gt 127) { $titleDisp += 2 } else { $titleDisp += 1 } }
    $titlePad = [Math]::Max(0, [Math]::Floor(($innerWidth - $titleDisp) / 2))
    $titleLine = [char]0x2551 + (' ' * $titlePad) + $titleText + (' ' * ($innerWidth - $titleDisp - $titlePad)) + [char]0x2551
    Write-ColorLine -Text $titleLine -Color "Cyan"

    Write-ColorLine -Text $sepLine -Color "Cyan"

    # 基本信息
    $time = if ($ReportData.ContainsKey("Time")) { $ReportData["Time"] } else { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
    $hostname = if ($ReportData.ContainsKey("Hostname")) { $ReportData["Hostname"] } else { $env:COMPUTERNAME }
    $osVer = if ($ReportData.ContainsKey("OSVersion")) { $ReportData["OSVersion"] } else { "Unknown" }

    New-ReportLine -Text "报告时间: $time" -Color "DarkGray"
    New-ReportLine -Text "主机名称: $hostname" -Color "White"
    New-ReportLine -Text "系统版本: $osVer" -Color "DarkGray"

    Write-ColorLine -Text $sepLine -Color "Cyan"

    # 诊断统计
    $dTotal = if ($ReportData.ContainsKey("DiagTotal")) { $ReportData["DiagTotal"] } else { 0 }
    $dPass  = if ($ReportData.ContainsKey("DiagPass")) { $ReportData["DiagPass"] } else { 0 }
    $dWarn  = if ($ReportData.ContainsKey("DiagWarn")) { $ReportData["DiagWarn"] } else { 0 }
    $dFail  = if ($ReportData.ContainsKey("DiagFail")) { $ReportData["DiagFail"] } else { 0 }
    $dElapsed = if ($ReportData.ContainsKey("DiagElapsed")) { $ReportData["DiagElapsed"] } else { 0.0 }
    $dCritical = if ($ReportData.ContainsKey("DiagCritical")) { $ReportData["DiagCritical"] } else { 0 }

    New-ReportLine -Text "【诊断结果】" -Color "Cyan"
    New-ReportLine -Text "  总检测项: $dTotal    通过: $dPass    警告: $dWarn    失败: $dFail    严重: $dCritical" -Color "White"
    New-ReportLine -Text "  诊断耗时: $([Math]::Round($dElapsed, 1))s" -Color "DarkGray"

    Write-ColorLine -Text $sepLine -Color "Cyan"

    # 修复统计（如果有修复数据）
    $rTotal = if ($ReportData.ContainsKey("RepairTotal")) { $ReportData["RepairTotal"] } else { -1 }
    if ($rTotal -ge 0) {
        $rSuccess = if ($ReportData.ContainsKey("RepairSuccess")) { $ReportData["RepairSuccess"] } else { 0 }
        $rFail    = if ($ReportData.ContainsKey("RepairFail")) { $ReportData["RepairFail"] } else { 0 }
        $rSkip    = if ($ReportData.ContainsKey("RepairSkip")) { $ReportData["RepairSkip"] } else { 0 }

        New-ReportLine -Text "【修复结果】" -Color "Cyan"
        New-ReportLine -Text "  总修复项: $rTotal    成功: $rSuccess    失败: $rFail    跳过: $rSkip" -Color "White"

        Write-ColorLine -Text $sepLine -Color "Cyan"
    }

    # 失败问题列表
    $failItems = if ($ReportData.ContainsKey("FailItems")) { $ReportData["FailItems"] } else { @() }
    if ($failItems.Count -gt 0) {
        New-ReportLine -Text "【失败/严重问题】" -Color "Red"
        foreach ($item in $failItems) {
            if ($item.Length -gt ($innerWidth - 4)) {
                $item = $item.Substring(0, $innerWidth - 4)
            }
            New-ReportLine -Text "  [!!] $item" -Color "Red"
        }
        Write-ColorLine -Text $sepLine -Color "Cyan"
    }

    # 警告问题列表
    $warnItems = if ($ReportData.ContainsKey("WarnItems")) { $ReportData["WarnItems"] } else { @() }
    if ($warnItems.Count -gt 0) {
        New-ReportLine -Text "【警告问题】" -Color "Yellow"
        foreach ($item in $warnItems) {
            if ($item.Length -gt ($innerWidth - 4)) {
                $item = $item.Substring(0, $innerWidth - 4)
            }
            New-ReportLine -Text "  [!] $item" -Color "Yellow"
        }
        Write-ColorLine -Text $sepLine -Color "Cyan"
    }

    # 可修复统计
    $fixable = if ($ReportData.ContainsKey("FixableCount")) { $ReportData["FixableCount"] } else { 0 }
    if ($fixable -gt 0) {
        New-ReportLine -Text "【可修复问题】" -Color "Green"
        New-ReportLine -Text "  共 $fixable 项问题可通过自动修复解决" -Color "Green"
        Write-ColorLine -Text $sepLine -Color "Cyan"
    }

    # 推荐操作
    $recommendations = if ($ReportData.ContainsKey("Recommendations")) { $ReportData["Recommendations"] } else { @() }
    if ($recommendations.Count -gt 0) {
        New-ReportLine -Text "【推荐操作】" -Color "Cyan"
        foreach ($cmd in $recommendations) {
            if ($cmd.Length -gt ($innerWidth - 4)) {
                $cmd = $cmd.Substring(0, $innerWidth - 4)
            }
            New-ReportLine -Text "  > $cmd" -Color "Magenta"
        }
    } else {
        # 默认推荐命令
        New-ReportLine -Text "【推荐操作】" -Color "Cyan"
        New-ReportLine -Text "  > NetAid -FixAll" -Color "Magenta"
        New-ReportLine -Text "  > NetAid -Fix dns" -Color "Magenta"
        New-ReportLine -Text "  > NetAid -Auto" -Color "Magenta"
    }

    Write-ColorLine -Text $bottomLine -Color "Cyan"
    Write-ColorLine -Text "" -Color "Cyan"
}

# ============================================================
# Read-UserChoice
# ============================================================
function Read-UserChoice {
    <#
    .SYNOPSIS
        循环读取用户菜单选择直到合法
    .PARAMETER Prompt
        提示文字
    .PARAMETER Min
        最小合法选项
    .PARAMETER Max
        最大合法选项
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prompt,
        [Parameter(Mandatory=$true)]
        [int]$Min,
        [Parameter(Mandatory=$true)]
        [int]$Max
    )

    while ($true) {
        Write-ColorLine -Text $Prompt -Color "Cyan" -NoNewline
        Write-ColorLine -Text " " -Color "Cyan" -NoNewline

        try {
            $input = [Console]::ReadLine()
        } catch {
            # 如果无法从 Console 读取（非交互模式），返回 0
            return 0
        }

        # 空输入处理
        if ([string]::IsNullOrWhiteSpace($input)) {
            # 默认返回 0（退出）
            return 0
        }

        # 检查是否是退出命令
        if ($input -eq 'q' -or $input -eq 'Q') {
            return 0
        }

        # 尝试解析为数字
        try {
            $choice = [int]$input
            if ($choice -ge $Min -and $choice -le $Max) {
                return $choice
            }
        } catch {
            # 非数字输入，忽略
        }

        # 无效输入提示
        Write-ColorLine -Text "  无效输入，请输入 [$Min-$Max] 之间的数字，或 q 退出。" -Color "Yellow"
    }
}

# ============================================================
# Confirm-UserAction
# ============================================================
function Confirm-UserAction {
    <#
    .SYNOPSIS
        确认用户操作 [Y/n] 或 [y/N]
    .PARAMETER Message
        确认消息
    .PARAMETER Default
        默认选项，"Y" 或 "N"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [Parameter(Mandatory=$true)]
        [string]$Default = "Y"
    )

    # 根据默认值显示不同格式
    if ($Default -eq "Y") {
        $promptText = "$Message [Y/n]:"
        $defaultVal = $true
    } else {
        $promptText = "$Message [y/N]:"
        $defaultVal = $false
    }

    while ($true) {
        Write-ColorLine -Text $promptText -Color "Cyan" -NoNewline
        Write-ColorLine -Text " " -Color "Cyan" -NoNewline

        try {
            $input = [Console]::ReadLine()
        } catch {
            return $defaultVal
        }

        if ([string]::IsNullOrWhiteSpace($input)) {
            return $defaultVal
        }

        $input = $input.Trim().ToLower()
        if ($input -eq 'y' -or $input -eq 'yes') {
            return $true
        }
        if ($input -eq 'n' -or $input -eq 'no') {
            return $false
        }

        Write-ColorLine -Text "  请输入 Y (是) 或 N (否)。" -Color "Yellow"
    }
}

# ============================================================
# Show-HelpText
# ============================================================
function Show-HelpText {
    <#
    .SYNOPSIS
        显示命令行帮助（参数概览和模块列表）
    #>
    Write-ColorLine -Text "" -Color "Cyan"
    Write-Banner -Version "1.0.0"

    Write-ColorLine -Text "用法:" -Color "Cyan"
    Write-ColorLine -Text "  NetAid [参数] [选项]" -Color "White"
    Write-ColorLine -Text "" -Color "White"

    Write-ColorLine -Text "参数:" -Color "Cyan"
    Write-ColorLine -Text "" -Color "White"

    $params = @(
        @{Flag="-Help";        Desc="显示此帮助信息"},
        @{Flag="-Version";     Desc="显示版本信息"},
        @{Flag="-Auto";        Desc="自动诊断并修复所有问题（全自动模式）"},
        @{Flag="-Check";       Desc="运行全面诊断（不修复）"},
        @{Flag="-FixAll";      Desc="修复所有可修复的问题"},
        @{Flag="-Fix <模块>";  Desc="修复指定模块（见下方模块列表）"},
        @{Flag="-Check <模块>"; Desc="诊断指定模块"},
        @{Flag="-Report";      Desc="生成诊断报告并导出到文件"},
        @{Flag="-NoColor";     Desc="禁用彩色输出"},
        @{Flag="-Silent";      Desc="安静模式：减少输出信息"},
        @{Flag="-Log <路径>";  Desc="指定日志目录路径"},
        @{Flag="-CleanLogs";   Desc="清理 30 天前的旧日志"}
    )

    foreach ($p in $params) {
        if ($Script:ColorEnabled) {
            Write-Host -Object "  " -NoNewline
            Write-Host -Object $p.Flag -ForegroundColor Magenta -NoNewline
            Write-Host -Object (" " * [Math]::Max(1, 18 - $p.Flag.Length)) -NoNewline
            Write-Host -Object $p.Desc -ForegroundColor White
        } else {
            $pad = " " * [Math]::Max(1, 18 - $p.Flag.Length)
            Write-Output -InputObject "  $($p.Flag)$pad$($p.Desc)"
        }
    }

    Write-ColorLine -Text "" -Color "White"
    Write-ColorLine -Text "诊断/修复模块:" -Color "Cyan"
    Write-ColorLine -Text "" -Color "White"

    $modules = @(
        @{Name="adapter";   Desc="网络适配器状态检测"},
        @{Name="ip";        Desc="IP 地址配置检测"},
        @{Name="dns";       Desc="DNS 解析检测与修复"},
        @{Name="gateway";   Desc="网关连通性检测"},
        @{Name="firewall";  Desc="防火墙规则检测"},
        @{Name="proxy";     Desc="代理服务器检测"},
        @{Name="route";     Desc="路由表检测"},
        @{Name="dhcp";      Desc="DHCP 服务检测"},
        @{Name="hosts";     Desc="Hosts 文件检测"},
        @{Name="mtu";       Desc="MTU 值检测"},
        @{Name="driver";    Desc="网卡驱动状态检测"},
        @{Name="winsock";   Desc="Winsock 目录检测与重置"},
        @{Name="tcpip";     Desc="TCP/IP 协议栈检测与重置"},
        @{Name="ie";        Desc="IE 代理与高级设置检测"},
        @{Name="service";   Desc="网络相关服务状态检测"}
    )

    foreach ($m in $modules) {
        if ($Script:ColorEnabled) {
            Write-Host -Object "  " -NoNewline
            Write-Host -Object $m.Name -ForegroundColor Green -NoNewline
            Write-Host -Object (" " * [Math]::Max(1, 14 - $m.Name.Length)) -NoNewline
            Write-Host -Object $m.Desc -ForegroundColor White
        } else {
            $pad = " " * [Math]::Max(1, 14 - $m.Name.Length)
            Write-Output -InputObject "  $($m.Name)$pad$($m.Desc)"
        }
    }

    Write-ColorLine -Text "" -Color "White"
    Write-ColorLine -Text "示例:" -Color "Cyan"
    Write-ColorLine -Text "  NetAid -Auto              # 全自动诊断修复" -Color "DarkGray"
    Write-ColorLine -Text "  NetAid -Check             # 仅诊断，不修复" -Color "DarkGray"
    Write-ColorLine -Text "  NetAid -Fix dns           # 仅修复 DNS" -Color "DarkGray"
    Write-ColorLine -Text "  NetAid -Check dns,ip      # 诊断 DNS 和 IP" -Color "DarkGray"
    Write-ColorLine -Text "  NetAid -Report            # 导出诊断报告" -Color "DarkGray"
    Write-ColorLine -Text "  NetAid -Auto -Log out.log # 自动修复并指定日志" -Color "DarkGray"
    Write-ColorLine -Text "  NetAid -CleanLogs          # 清理30天前的旧日志" -Color "DarkGray"
    Write-ColorLine -Text "" -Color "White"

    Write-ColorLine -Text "严重级别说明:" -Color "Cyan"
    Write-ColorLine -Text "" -Color "White"
    if ($Script:ColorEnabled) {
        Write-Host -Object "  L1  " -ForegroundColor White -NoNewline
        Write-Host -Object "[!!]" -ForegroundColor Red -NoNewline
        Write-Host -Object " 严重 - 核心网络功能故障，必须修复" -ForegroundColor White
        Write-Host -Object "  L2  " -ForegroundColor White -NoNewline
        Write-Host -Object "[!] " -ForegroundColor Yellow -NoNewline
        Write-Host -Object " 警告 - 配置不当，建议修复" -ForegroundColor White
        Write-Host -Object "  L3  " -ForegroundColor White -NoNewline
        Write-Host -Object "[i] " -ForegroundColor DarkGray -NoNewline
        Write-Host -Object " 信息 - 可忽略项，仅提示" -ForegroundColor White
        Write-Host -Object "  L4a " -ForegroundColor White -NoNewline
        Write-Host -Object "[*] " -ForegroundColor Magenta -NoNewline
        Write-Host -Object " 需确认 - 可能涉及重启或断网" -ForegroundColor White
    } else {
        Write-Output -InputObject "  L1  [!!] 严重 - 核心网络功能故障，必须修复"
        Write-Output -InputObject "  L2  [!]  警告 - 配置不当，建议修复"
        Write-Output -InputObject "  L3  [i]  信息 - 可忽略项，仅提示"
        Write-Output -InputObject "  L4a [*]  需确认 - 可能涉及重启或断网"
    }
    Write-ColorLine -Text "" -Color "White"
}

# ============================================================
# Show-Error
# ============================================================
function Show-Error {
    <#
    .SYNOPSIS
        显示格式化的错误消息
    .PARAMETER Message
        错误消息文本
    .PARAMETER Severity
        严重级别：critical / warning / info
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [Parameter(Mandatory=$true)]
        [ValidateSet("critical", "warning", "info")]
        [string]$Severity = "info"
    )

    $prefix = ""
    $color = "White"

    switch ($Severity) {
        "critical" {
            $prefix = "[!!] 严重: "
            $color = "Red"
        }
        "warning" {
            $prefix = "[!] 警告: "
            $color = "Yellow"
        }
        "info" {
            $prefix = "[i] "
            $color = "DarkGray"
        }
    }

    Write-ColorLine -Text "$prefix$Message" -Color $color
}

# ============================================================
# Get-NetworkStatus
# ============================================================
function Get-NetworkStatus {
    <#
    .SYNOPSIS
        获取当前网络状态摘要字符串
    .DESCRIPTION
        返回格式："已连接 | Ethernet0 (192.168.1.100)" 或 "未连接"
    #>
    try {
        # 获取活跃适配器
        $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        if (-not $adapters -or $adapters.Count -eq 0) {
            return "未连接"
        }

        # 获取 IPv4 地址（排除 APIPA 和回环地址）
        $ipAddresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.PrefixOrigin -ne 'WellKnown' -and
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*'
        }

        if (-not $ipAddresses -or $ipAddresses.Count -eq 0) {
            # 有活跃适配器但没有有效IP
            $adapterName = $adapters[0].Name
            return "已连接 | $adapterName (无有效IP)"
        }

        # 取第一个有效 IP 和对应的适配器
        $ip = $ipAddresses[0]
        # 尝试匹配适配器
        $matchingAdapter = $adapters | Where-Object { $_.ifIndex -eq $ip.InterfaceIndex } | Select-Object -First 1
        if (-not $matchingAdapter) {
            $matchingAdapter = $adapters[0]
        }

        $adapterName = $matchingAdapter.Name
        $ipAddr = $ip.IPAddress

        return "已连接 | $adapterName ($ipAddr)"
    } catch {
        # 如果网络 cmdlet 不可用（如在非 Windows 系统），返回默认状态
        try {
            # 尝试用传统方式检测
            $pingResult = Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction Stop
            if ($pingResult) {
                return "已连接 | (网络可用)"
            }
        } catch {
            # 忽略
        }
        return "未连接"
    }
}

# ============================================================
# 模块导出提示
# ============================================================
# 此脚本设计为被主脚本 dot-source 引用：
#   . "$PSScriptRoot\lib\UI.ps1"
# 或者通过模块清单导入
