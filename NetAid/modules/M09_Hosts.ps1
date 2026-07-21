<#
.SYNOPSIS
    M09 - hosts 文件劫持检测与修复模块
.DESCRIPTION
    检测 Windows hosts 文件中的关键域名劫持（被映射到非本机 IP）、
    文件权限异常、文件编码异常（BOM / NULL 字节 / C0 控制字符）。
    支持 L1 级别一键修复：注释劫持条目、重写编码、修复权限，
    修复前自动备份到 backups/ 目录。
.NOTES
    文件名: M09_Hosts.ps1
    依赖: Logger.ps1 (Write-DiagnosisEvent, Write-FixEvent, Write-ErrorEvent)
    兼容: Windows PowerShell 5.1
    编码: UTF-8 with BOM
#>

# ============================================================
# 脚本级常量
# ============================================================

# 需要检测劫持的关键域名列表
$Script:KeyDomains = @(
    "microsoft.com",
    "windows.com",
    "live.com",
    "office.com",
    "baidu.com",
    "qq.com",
    "taobao.com",
    "jd.com"
)

# 本地回环地址（不被视为劫持）
$Script:LocalIPs = @("0.0.0.0", "127.0.0.1", "::1")

# hosts 文件路径
$Script:HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    判断域名是否为关键域名或其子域名
.DESCRIPTION
    精确匹配关键域名，或以 ".关键域名" 结尾的子域名均视为关键域名。
    例如 "microsoft.com" 和 "www.microsoft.com" 都会命中，
    但 "fake-microsoft.com" 不会命中。
#>
function Test-IsKeyDomain {
    param(
        [string]$Domain
    )

    $domainLower = $Domain.ToLower().Trim()
    foreach ($key in $Script:KeyDomains) {
        if ($domainLower -eq $key) { return $true }
        if ($domainLower -like "*.$key") { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    判断 IP 地址是否为本地回环地址
#>
function Test-IsLocalIP {
    param(
        [string]$IP
    )

    $ipTrimmed = $IP.Trim()
    foreach ($local in $Script:LocalIPs) {
        if ($ipTrimmed -eq $local) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    解析 hosts 文件中的一行，提取 IP 和域名
.DESCRIPTION
    按空白字符分割行内容，第一个非空 token 为 IP，第二个为域名。
    跳过注释行（以 # 开头）、空行、格式异常行。
.OUTPUTS
    System.Collections.Hashtable - @{ IP; Domain }，或 $null（跳过）
#>
function Parse-HostsLine {
    param(
        [string]$Line
    )

    $trimmed = $Line.Trim()

    # 跳过空行和注释行
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^\s*#') {
        return $null
    }

    # 按空白字符分割，第一个非空 token 为 IP，后续为域名
    $tokens = $trimmed -split '\s+' | Where-Object { $_ -ne '' }
    if ($tokens.Count -lt 2) {
        return $null
    }

    $ip     = $tokens[0]
    $domain = $tokens[1]  # 取第一个域名（hosts 一行可有多个别名，取主域名）

    return @{ IP = $ip; Domain = $domain }
}

<#
.SYNOPSIS
    检测 hosts 文件的编码异常
.DESCRIPTION
    三项检测：
    1. BOM 检测 - UTF-16 LE BOM (FF FE) 或 UTF-8 BOM (EF BB BF)
    2. NULL 字节检测 - 超过 10 个 NULL 字节表明可能是 UTF-16 无 BOM
    3. C0 控制字符检测 - 排除 Tab/LF/CR 和 0x20+ 的可打印字符，
       其他 0x00-0x1F 范围的控制字符视为异常
.OUTPUTS
    System.Collections.Hashtable - @{ OK = $bool; Details = $string }
#>
function Test-HostsEncoding {
    param(
        [string]$Path
    )

    $details = @()
    $ok = $true

    # 读取原始字节
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch {
        return @{ OK = $false; Details = "CANNOT_READ: $_" }
    }

    if ($bytes.Count -eq 0) {
        return @{ OK = $true; Details = "EMPTY_FILE" }
    }

    # --- 检测1: BOM (Byte Order Mark) ---
    if ($bytes.Count -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $details += "UTF16_LE_BOM_DETECTED"
        $ok = $false
    }
    if ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $details += "UTF8_BOM_DETECTED"
        $ok = $false
    }

    # --- 检测2: NULL 字节（超过 10 个说明可能是 UTF-16 但无 BOM） ---
    $nullCount = @($bytes | Where-Object { $_ -eq 0 }).Count
    if ($nullCount -gt 10) {
        $details += "NULL_BYTES_DETECTED($nullCount)"
        $ok = $false
    }

    # --- 检测3: C0 控制字符 (0x00-0x1F，排除 Tab/LF/CR) ---
    $abnormalChars = @()
    foreach ($b in $bytes) {
        if ($b -lt 0x20 -and $b -ne 0x09 -and $b -ne 0x0A -and $b -ne 0x0D) {
            $abnormalChars += "0x{0:X2}" -f $b
        }
    }
    if ($abnormalChars.Count -gt 0) {
        $uniqueAbnormal = $abnormalChars | Select-Object -Unique
        $details += "ABNORMAL_CONTROL_CHARS: $($uniqueAbnormal -join ',')"
        $ok = $false
    }

    # 一切正常
    if ($details.Count -eq 0) {
        $details += "NORMAL"
    }

    return @{
        OK      = $ok
        Details = ($details -join '; ')
    }
}

# ============================================================
# 公共函数（对外导出）
# ============================================================

<#
.SYNOPSIS
    诊断 hosts 文件是否存在关键域名劫持、权限异常、编码异常
.DESCRIPTION
    检测项：
    1. hosts 文件存在性 - 若不存在则 PASS（正常状态，非故障）
    2. 关键域名劫持检测 - 关键域名若被映射到非 0.0.0.0/127.0.0.1/::1 的 IP，标记劫持
    3. 文件权限检测 - Get-Acl 检查当前用户是否有读取权限
    4. 编码异常检测 - BOM / NULL 字节 / C0 控制字符

    判定逻辑：
    - 关键域名被劫持 → FAIL
    - 文件权限异常   → FAIL
    - 编码异常       → WARN（继续）
    - 全部正常       → PASS
    - 文件不存在     → PASS（降级）
    - 文件被锁不可读 → UNKNOWN（降级）
.PARAMETER Context
    诊断上下文哈希表（初始为空）
.OUTPUTS
    System.Collections.Hashtable - 诊断结果结构：
    @{ HijackEntries; FileEncoding_OK; EncodingDetails;
       TotalActiveEntries; Permissions_OK; Verdict }
#>
function Invoke-M09_Diagnose {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{}
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutMs = 300

    # 结果变量初始化
    $hijackEntries      = @()
    $fileEncoding_OK    = $true
    $encodingDetails    = ""
    $totalActiveEntries = 0
    $permissions_OK     = $true
    $verdict            = "PASS"

    try {
        # ============================================================
        # 检测1: hosts 文件存在性
        # ============================================================
        if (-not (Test-Path $Script:HostsPath)) {
            # 文件不存在 → PASS（正常状态，非故障）
            $sw.Stop()
            $elapsed = $sw.ElapsedMilliseconds

            Write-DiagnosisEvent -Module "M09" -Verdict "PASS" -ElapsedMs $elapsed -ExtraFields @{
                hosts_path     = $Script:HostsPath
                file_exists    = $false
                hijack_count   = 0
                encoding_ok    = $true
                permissions_ok = $true
            }

            return @{
                Diagnosis = @{
                    HijackEntries      = @()
                    FileEncoding_OK    = $true
                    EncodingDetails    = "FILE_NOT_FOUND"
                    TotalActiveEntries = 0
                    Permissions_OK     = $true
                    Verdict            = "PASS"
                }
                LogEvents = @()
            }
        }

        # ============================================================
        # 检测2: 文件权限
        # ============================================================
        try {
            $acl = Get-Acl $Script:HostsPath -ErrorAction Stop
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            # 检查当前用户、Users 组或 Everyone 是否有读取权限
            $accessRules = $acl.Access | Where-Object {
                $_.IdentityReference.Value -eq $currentUser -or
                $_.IdentityReference.Value -eq "BUILTIN\Users" -or
                $_.IdentityReference.Value -eq "Everyone"
            }
            $readAccess = $accessRules | Where-Object {
                $_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Read
            }
            if (-not $readAccess) {
                $permissions_OK = $false
            }
        } catch {
            # Get-Acl 本身失败也说明权限有问题
            $permissions_OK = $false
        }

        # ============================================================
        # 检测3: 编码异常
        # ============================================================
        $encodingResult = Test-HostsEncoding -Path $Script:HostsPath
        $fileEncoding_OK = $encodingResult.OK
        $encodingDetails = $encodingResult.Details

        # ============================================================
        # 检测4: 读取并解析 hosts 内容，检测劫持条目
        # ============================================================
        try {
            $lines = Get-Content $Script:HostsPath -ErrorAction Stop
        } catch {
            # 文件被锁不可读 → UNKNOWN
            $sw.Stop()
            $elapsed = $sw.ElapsedMilliseconds

            Write-DiagnosisEvent -Module "M09" -Verdict "UNKNOWN" -ElapsedMs $elapsed -ExtraFields @{
                hosts_path     = $Script:HostsPath
                error          = "无法读取 hosts 文件"
                permissions_ok = $permissions_OK
            }

            return @{
                Diagnosis = @{
                    HijackEntries      = @()
                    FileEncoding_OK    = $fileEncoding_OK
                    EncodingDetails    = "FILE_LOCKED: $_"
                    TotalActiveEntries = 0
                    Permissions_OK     = $permissions_OK
                    Verdict            = "UNKNOWN"
                }
                LogEvents = @()
            }
        }

        # 逐行解析，检测劫持条目
        $activeEntries = 0
        foreach ($line in $lines) {
            # 超时保护
            if ($sw.ElapsedMilliseconds -gt $timeoutMs) {
                Write-ErrorEvent -Severity "low" -Message "M09 诊断超时 (${timeoutMs}ms)" -StackTrace ""
                $verdict = "UNKNOWN"
                break
            }

            $parsed = Parse-HostsLine -Line $line
            if ($null -eq $parsed) { continue }

            $activeEntries++

            # 关键域名 + 非本机 IP → 标记劫持
            if ((Test-IsKeyDomain -Domain $parsed.Domain) -and -not (Test-IsLocalIP -IP $parsed.IP)) {
                $hijackEntries += @{
                    Domain = $parsed.Domain
                    IP     = $parsed.IP
                }
            }
        }

        $totalActiveEntries = $activeEntries

        # ============================================================
        # 综合判定
        # ============================================================
        if ($verdict -ne "UNKNOWN") {
            if ($hijackEntries.Count -gt 0) {
                $verdict = "FAIL"
            } elseif (-not $permissions_OK) {
                $verdict = "FAIL"
            } elseif (-not $fileEncoding_OK) {
                $verdict = "WARN"
            } else {
                $verdict = "PASS"
            }
        }

        $sw.Stop()
        $elapsed = $sw.ElapsedMilliseconds

        Write-DiagnosisEvent -Module "M09" -Verdict $verdict -ElapsedMs $elapsed -ExtraFields @{
            hosts_path          = $Script:HostsPath
            file_exists         = $true
            hijack_count        = $hijackEntries.Count
            total_active_entries = $totalActiveEntries
            encoding_ok         = $fileEncoding_OK
            encoding_details    = $encodingDetails
            permissions_ok      = $permissions_OK
        }

        return @{
            Diagnosis = @{
                HijackEntries      = $hijackEntries
                FileEncoding_OK    = $fileEncoding_OK
                EncodingDetails    = $encodingDetails
                TotalActiveEntries = $totalActiveEntries
                Permissions_OK     = $permissions_OK
                Verdict            = $verdict
            }
            LogEvents = @()
        }

    } catch {
        # 顶层异常兜底
        $sw.Stop()
        $elapsed = $sw.ElapsedMilliseconds

        Write-ErrorEvent -Severity "medium" -Message "M09 诊断异常: $_" -StackTrace $_.ScriptStackTrace
        Write-DiagnosisEvent -Module "M09" -Verdict "UNKNOWN" -ElapsedMs $elapsed -ExtraFields @{
            error = "诊断过程异常: $_"
        }

        return @{
            Diagnosis = @{
                HijackEntries      = @()
                FileEncoding_OK    = $false
                EncodingDetails    = "EXCEPTION: $_"
                TotalActiveEntries = 0
                Permissions_OK     = $false
                Verdict            = "UNKNOWN"
            }
            LogEvents = @()
        }
    }
}

<#
.SYNOPSIS
    修复 hosts 文件中的劫持条目、编码异常和权限异常
.DESCRIPTION
    L1 级别修复（风险：极低），执行步骤：
    1. 备份当前 hosts 文件到 backups/hosts_yyyyMMdd_HHmmss.bak
    2. 逐行读取 hosts，在劫持行开头加 "# [NetAid] 已注释 - 劫持条目: " 注释掉
    3. 若编码异常，将文件重写为 UTF-8 无 BOM 编码
    4. 若权限异常，使用 icacls 修复读取权限
    5. 重新运行 M09 诊断子集验证关键域名无劫持条目
    6. 失败时提示从 .bak 备份文件恢复

    注意：修复后的 hosts 文件使用 UTF-8 无 BOM 编码以保持最大兼容性。
.PARAMETER Diagnosis
    诊断结果哈希表（来自 Invoke-M09_Diagnose 的返回值）
.OUTPUTS
    System.Collections.Hashtable - 修复结果：
    @{ Repair = @{ Verdict; RebootRequired; Steps }; LogEvents = @(...) }
#>
function Invoke-M09_Repair {
    [CmdletBinding()]
    param(
        [hashtable]$Diagnosis
    )

    $steps     = @()
    $logEvents = @()
    $verdict   = "success"

    try {
        # ============================================================
        # 前置检查
        # ============================================================
        if (-not (Test-Path $Script:HostsPath)) {
            $steps += "hosts 文件不存在，无需修复"
            Write-FixEvent -Module "M09" -EventSubType "step" -Step "hosts 文件不存在，跳过" -ExitCode 0
            Write-FixEvent -Module "M09" -EventSubType "end" -Verdict "skipped" -RebootRequired $false

            return @{
                Repair    = @{
                    Verdict        = "skipped"
                    RebootRequired = $false
                    Steps          = $steps
                }
                LogEvents = $logEvents
            }
        }

        $hijackEntries      = $Diagnosis.HijackEntries
        $hasHijack          = ($hijackEntries -and $hijackEntries.Count -gt 0)
        $hasEncodingIssue   = (-not $Diagnosis.FileEncoding_OK)
        $hasPermissionIssue = (-not $Diagnosis.Permissions_OK)

        if (-not $hasHijack -and -not $hasEncodingIssue -and -not $hasPermissionIssue) {
            $steps += "无需修复：未检测到劫持条目、编码异常或权限异常"
            Write-FixEvent -Module "M09" -EventSubType "step" -Step "无需修复" -ExitCode 0
            Write-FixEvent -Module "M09" -EventSubType "end" -Verdict "skipped" -RebootRequired $false

            return @{
                Repair    = @{
                    Verdict        = "skipped"
                    RebootRequired = $false
                    Steps          = $steps
                }
                LogEvents = $logEvents
            }
        }

        # ============================================================
        # 步骤1: 备份当前 hosts 文件
        # ============================================================
        $backupDir = Join-Path (Split-Path $PSScriptRoot -Parent) "backups"
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupFile = Join-Path $backupDir "hosts_${timestamp}.bak"

        try {
            Copy-Item $Script:HostsPath $backupFile -Force -ErrorAction Stop
            $steps += "已备份 hosts 文件至: $backupFile"
            Write-FixEvent -Module "M09" -EventSubType "step" -Step "备份 hosts 文件至 $backupFile" -ExitCode 0
        } catch {
            $steps += "备份失败: $_"
            Write-FixEvent -Module "M09" -EventSubType "step" -Step "备份 hosts 文件失败: $_" -ExitCode 1
            Write-FixEvent -Module "M09" -EventSubType "end" -Verdict "failed" -RebootRequired $false

            return @{
                Repair    = @{
                    Verdict        = "failed"
                    RebootRequired = $false
                    Steps          = $steps
                }
                LogEvents = $logEvents
            }
        }

        # ============================================================
        # 步骤2: 注释被标记为劫持的行
        # ============================================================
        if ($hasHijack) {
            try {
                $lines = Get-Content $Script:HostsPath -ErrorAction Stop
                $modifiedLines = @()
                $commentCount  = 0

                foreach ($line in $lines) {
                    $parsed = Parse-HostsLine -Line $line
                    $isHijacked = $false

                    if ($null -ne $parsed) {
                        # 与劫持列表比对：域名和 IP 均匹配才注释
                        foreach ($entry in $hijackEntries) {
                            if ($parsed.Domain -eq $entry.Domain -and $parsed.IP -eq $entry.IP) {
                                $isHijacked = $true
                                break
                            }
                        }
                    }

                    if ($isHijacked) {
                        $modifiedLines += "# [NetAid] 已注释 - 劫持条目: $line"
                        $commentCount++
                    } else {
                        $modifiedLines += $line
                    }
                }

                # 写回文件：UTF-8 无 BOM（Windows hosts 文件的标准编码）
                $content = $modifiedLines -join "`r`n"
                if ($modifiedLines[-1] -ne "") {
                    $content += "`r`n"
                }
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($Script:HostsPath, $content, $utf8NoBom)

                $steps += "已注释 $commentCount 条劫持条目"
                Write-FixEvent -Module "M09" -EventSubType "step" -Step "注释 $commentCount 条劫持条目" -ExitCode 0
            } catch {
                $steps += "注释劫持条目失败: $_"
                Write-FixEvent -Module "M09" -EventSubType "step" -Step "注释劫持条目失败: $_" -ExitCode 1
                $verdict = "failed"
            }
        }

        # ============================================================
        # 步骤3: 修复编码异常（重写为 UTF-8 无 BOM）
        # ============================================================
        if ($hasEncodingIssue) {
            try {
                $rawContent = Get-Content $Script:HostsPath -Raw -ErrorAction Stop
                $utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($Script:HostsPath, $rawContent, $utf8NoBom)

                $steps += "已将 hosts 文件编码重写为 UTF-8 (无 BOM)"
                Write-FixEvent -Module "M09" -EventSubType "step" -Step "编码重写为 UTF-8 无 BOM" -ExitCode 0
            } catch {
                $steps += "编码修复失败: $_"
                Write-FixEvent -Module "M09" -EventSubType "step" -Step "编码修复失败: $_" -ExitCode 1
                # 编码修复失败不改变整体 verdict（非致命，劫持条目修复优先）
            }
        }

        # ============================================================
        # 步骤4: 修复权限异常
        # ============================================================
        if ($hasPermissionIssue) {
            try {
                $userName = $env:USERNAME
                if (-not $userName) {
                    $userName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -replace '.*\\', ''
                }
                $result = & icacls $Script:HostsPath /grant "${userName}:R" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $steps += "已通过 icacls 修复 hosts 文件读取权限"
                    Write-FixEvent -Module "M09" -EventSubType "step" -Step "修复文件读取权限" -ExitCode 0
                } else {
                    $steps += "权限修复失败 (icacls exit code: $LASTEXITCODE): $result"
                    Write-FixEvent -Module "M09" -EventSubType "step" -Step "权限修复失败" -ExitCode 1
                }
            } catch {
                $steps += "权限修复异常: $_"
                Write-FixEvent -Module "M09" -EventSubType "step" -Step "权限修复异常: $_" -ExitCode 1
            }
        }

        # ============================================================
        # 步骤5: 验证修复结果（重新诊断确认关键域名无劫持条目）
        # ============================================================
        try {
            $verifyResult = Invoke-M09_Diagnose -Context @{}
            if ($verifyResult.HijackEntries.Count -eq 0) {
                $steps += "验证通过：关键域名无劫持条目"
                Write-FixEvent -Module "M09" -EventSubType "step" -Step "验证通过" -ExitCode 0
            } else {
                $steps += "验证警告：仍有 $($verifyResult.HijackEntries.Count) 条劫持条目未清除"
                Write-FixEvent -Module "M09" -EventSubType "step" -Step "验证失败：仍有劫持条目" -ExitCode 1
                if ($verdict -ne "failed") { $verdict = "failed" }
            }
        } catch {
            $steps += "验证过程异常: $_"
            Write-FixEvent -Module "M09" -EventSubType "step" -Step "验证异常: $_" -ExitCode 1
        }

        # ============================================================
        # 步骤6: 失败时提示从 .bak 备份恢复
        # ============================================================
        if ($verdict -eq "failed") {
            $steps += "修复未完全成功，可从备份恢复: Copy-Item '$backupFile' '$($Script:HostsPath)' -Force"
        }

        Write-FixEvent -Module "M09" -EventSubType "end" -Verdict $verdict -RebootRequired $false

        return @{
            Repair    = @{
                Verdict        = $verdict
                RebootRequired = $false
                Steps          = $steps
            }
            LogEvents = $logEvents
        }

    } catch {
        # 顶层异常兜底
        Write-ErrorEvent -Severity "high" -Message "M09 修复异常: $_" -StackTrace $_.ScriptStackTrace
        Write-FixEvent -Module "M09" -EventSubType "end" -Verdict "failed" -RebootRequired $false

        return @{
            Repair    = @{
                Verdict        = "failed"
                RebootRequired = $false
                Steps          = @("修复过程异常: $_"; "请从 backups/ 目录的 .bak 文件手动恢复 hosts")
            }
            LogEvents = $logEvents
        }
    }
}

# ============================================================
# 脚本结束
# 本文件通过 dot-source (. .\modules\M09_Hosts.ps1) 加载时，
# 导出两个公共函数：Invoke-M09_Diagnose 和 Invoke-M09_Repair。
# 内部辅助函数（Test-IsKeyDomain 等）仅供模块内部使用。
# ============================================================
