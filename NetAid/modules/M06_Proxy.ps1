<#
.SYNOPSIS
    M06_Proxy - 代理与VPN检测修复模块
.DESCRIPTION
    检测系统代理设置（IE代理、WinHTTP代理、环境变量代理）和VPN虚拟适配器/残留路由，
    并提供安全修复功能。
    诊断：检查代理配置与VPN残留，超时目标 800ms。
    修复：关闭IE代理、重置WinHTTP、清除环境变量代理、移除VPN残留路由。
    风险等级：L1（极低，仅修改本机代理配置）
.NOTES
    文件名: M06_Proxy.ps1
    依赖: 零第三方依赖，需 Logger.ps1 (Write-DiagnosisEvent/Write-FixEvent/Write-ErrorEvent)
    兼容: Windows PowerShell 5.1
    编码: UTF-8 with BOM
    导出: Invoke-M06_Diagnose, Invoke-M06_Repair
#>

# ============================================================
# 脚本级常量
# ============================================================

# VPN 虚拟适配器特征关键词（用于匹配 InterfaceDescription）
# 注意：不含 'Virtual'——过于宽泛，会误伤 Hyper-V/WSL/VMware 等合法虚拟交换机
$Script:VpnAdapterPatterns = @(
    'TAP-Windows', 'TAP Adapter', 'Wintun', 'PANGP',
    'CheckPoint', 'WireGuard', 'OpenVPN', 'Tunnel',
    'ZeroTier', 'Tailscale', 'SoftEther', 'NordLynx',
    'Clash', 'V2Ray', 'sing-tun'
)

# 合法虚拟适配器白名单（Hyper-V/WSL/VMware/VirtualBox/Wi-Fi Direct）
$Script:LegitVirtualPatterns = @(
    'Hyper-V', 'WSL', 'VMware', 'VirtualBox',
    'Wi-Fi Direct', 'Microsoft Network Adapter Multiplexor'
)

# 代理相关环境变量名（大小写不敏感检测）
$Script:ProxyEnvVarNames = @(
    'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY',
    'http_proxy', 'https_proxy', 'no_proxy'
)

# 诊断超时目标（毫秒）
$Script:DiagnosisTimeoutMs = 800

# ============================================================
# 内部辅助函数
# ============================================================

<#
.SYNOPSIS
    检查接口描述是否匹配 VPN 特征关键词
#>
function Test-IsVpnAdapter {
    param(
        [string]$InterfaceDescription,
        [string]$InterfaceAlias
    )

    if (-not $InterfaceDescription -and -not $InterfaceAlias) {
        return $false
    }

    $combined = "$InterfaceDescription $InterfaceAlias"

    # 白名单优先：合法虚拟适配器（Hyper-V/WSL等）不算 VPN
    foreach ($legit in $Script:LegitVirtualPatterns) {
        if ($combined -match [regex]::Escape($legit)) {
            return $false
        }
    }

    foreach ($pattern in $Script:VpnAdapterPatterns) {
        if ($combined -match $pattern) {
            return $true
        }
    }

    # 独立的 'VPN' 单词匹配（避免误伤含 vpn 子串的其他词）
    if ($combined -match '\bVPN\b') {
        return $true
    }

    return $false
}

<#
.SYNOPSIS
    运行 netsh winhttp show proxy 并返回原始输出字符串
#>
function Get-WinHttpProxyOutput {
    try {
        $output = & netsh winhttp show proxy 2>&1
        return ($output | Out-String).Trim()
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
    安全执行指定作用域的环境变量读取，异常时返回空
#>
function Get-EnvVarSafe {
    param(
        [string]$Name,
        [string]$Scope  # 'User' 或 'Machine'
    )

    try {
        $value = [Environment]::GetEnvironmentVariable($Name, $Scope)
        return $value
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
    安全执行指定作用域的环境变量清除，异常时返回 $false
#>
function Clear-EnvVarSafe {
    param(
        [string]$Name,
        [string]$Scope  # 'User' 或 'Machine'
    )

    try {
        [Environment]::SetEnvironmentVariable($Name, $null, $Scope)
        return $true
    } catch {
        return $false
    }
}

# ============================================================
# 公共函数: Invoke-M06_Diagnose
# ============================================================

<#
.SYNOPSIS
    诊断代理与VPN相关配置
.DESCRIPTION
    检测项：
      1. IE 系统代理（ProxyEnable / AutoConfigURL）
      2. WinHTTP 代理（netsh winhttp show proxy）
      3. 环境变量代理（User + Machine 级别）
      4. VPN 虚拟适配器（通过接口描述关键词匹配）
      5. VPN 残留路由（指向已断开VPN适配器的路由）
    判定规则：
      - 任一代理开启或存在残留 VPN 路由 → WARN
      - 多个代理同时开启或 VPN 适配器处于活动状态 → FAIL
      - 全部干净 → PASS
.PARAMETER Context
    上下文哈希表（初始为空，可用于传递会话级状态）
.OUTPUTS
    System.Collections.Hashtable
    返回 @{ Diagnosis = @{...}; LogEvents = @(...) }
.EXAMPLE
    $result = Invoke-M06_Diagnose -Context @{}
    $result.Diagnosis.Verdict  # "PASS" / "WARN" / "FAIL"
#>
function Invoke-M06_Diagnose {
    param(
        [hashtable]$Context = @{}
    )

    # ---------- 初始化 ----------
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $logEvents = New-Object System.Collections.ArrayList

    # 诊断结果容器
    $diag = @{
        WinHttpProxy       = $null
        IEProxy            = $null
        EnvProxy           = @()
        VpnAdapters        = @()
        VpnResidualRoutes  = @()
        Verdict            = "PASS"
    }

    $issueCount  = 0   # 警告级问题计数
    $failCount   = 0   # 失败级问题计数
    $errors      = @() # 错误信息收集

    # ---------- 检测1: IE 系统代理 ----------
    try {
        $ieSettings = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop

        $proxyEnable    = $ieSettings.ProxyEnable
        $proxyServer    = $ieSettings.ProxyServer
        $autoConfigProp = $ieSettings.PSObject.Properties['AutoConfigURL']
        $autoConfigUrl  = if ($autoConfigProp) { $autoConfigProp.Value } else { $null }

        $ieProxyInfo = @()

        if ($proxyEnable -eq 1) {
            $ieProxyInfo += "ProxyServer=$proxyServer"
            $issueCount++
        }

        if ($autoConfigUrl -and $autoConfigUrl.Trim() -ne '') {
            $ieProxyInfo += "PAC=$autoConfigUrl"
            $issueCount++
        }

        if ($ieProxyInfo.Count -gt 0) {
            $diag.IEProxy = ($ieProxyInfo -join '; ')
        }
    } catch {
        $errors += "IE代理检测失败: $_"
    }

    # ---------- 检测2: WinHTTP 代理 ----------
    try {
        $winHttpOutput = Get-WinHttpProxyOutput

        if ($winHttpOutput) {
            # 判断是否包含"直接访问"（中文）或 "direct"（英文）
            $isDirect = ($winHttpOutput -match '直接访问') -or
                        ($winHttpOutput -match 'direct')

            if (-not $isDirect) {
                # WinHTTP 代理已设置，尝试提取代理地址
                # 中文输出示例: "代理服务器: proxy.example.com:8080"
                # 英文输出示例: "Proxy Server: proxy.example.com:8080"
                if ($winHttpOutput -match '代理服务器[:\s]+(.+)' -or
                    $winHttpOutput -match 'Proxy Server[:\s]+(.+)') {
                    $diag.WinHttpProxy = $Matches[1].Trim()
                } else {
                    $diag.WinHttpProxy = $winHttpOutput
                }
                $issueCount++
            }
        }
    } catch {
        $errors += "WinHTTP代理检测失败: $_"
    }

    # ---------- 检测3: 环境变量代理 ----------
    try {
        $envProxyList = New-Object System.Collections.ArrayList
        $foundVarNames = @{}  # 用于去重（大小写不敏感）

        foreach ($scope in @('User', 'Machine')) {
            foreach ($varName in $Script:ProxyEnvVarNames) {
                $varNameLower = $varName.ToLowerInvariant()
                if ($foundVarNames.ContainsKey($varNameLower)) {
                    continue  # 跳过已记录的重复变量（不同大小写视为同一个）
                }

                $value = Get-EnvVarSafe -Name $varName -Scope $scope
                if ($value -and $value.Trim() -ne '') {
                    $foundVarNames[$varNameLower] = $true
                    [void]$envProxyList.Add(@{
                        Name  = $varName
                        Value = $value
                        Scope = $scope
                    })
                    $issueCount++
                }
            }
        }

        $diag.EnvProxy = $envProxyList.ToArray()
    } catch {
        $errors += "环境变量代理检测失败: $_"
    }

    # ---------- 检测4: VPN 虚拟适配器 ----------
    try {
        $allAdapters = Get-NetAdapter -ErrorAction Stop
        $vpnAdapterList = New-Object System.Collections.ArrayList

        foreach ($adapter in $allAdapters) {
            if (Test-IsVpnAdapter -InterfaceDescription $adapter.InterfaceDescription -InterfaceAlias $adapter.Name) {
                $adapterType = 'VPN'
                # 细分VPN类型
                if ($adapter.InterfaceDescription -match 'WireGuard|Wintun|NordLynx') {
                    $adapterType = 'WireGuard'
                } elseif ($adapter.InterfaceDescription -match 'OpenVPN|TAP') {
                    $adapterType = 'OpenVPN'
                } elseif ($adapter.InterfaceDescription -match 'CheckPoint|PANGP') {
                    $adapterType = 'EnterpriseVPN'
                } elseif ($adapter.InterfaceDescription -match 'ZeroTier|Tailscale') {
                    $adapterType = 'MeshVPN'
                }

                [void]$vpnAdapterList.Add(@{
                    Name   = $adapter.Name
                    Status = $adapter.Status
                    Type   = $adapterType
                })

                # 活动状态的VPN适配器 → 标记为失败级
                if ($adapter.Status -eq 'Up') {
                    $failCount++
                } else {
                    $issueCount++
                }
            }
        }

        $diag.VpnAdapters = $vpnAdapterList.ToArray()
    } catch {
        $errors += "VPN适配器检测失败: $_"
    }

    # ---------- 检测5: VPN 残留路由 ----------
    try {
        $allRoutes = Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop
        $residualRouteList = New-Object System.Collections.ArrayList

        # 收集VPN适配器的InterfaceIndex集合
        $vpnIfIndexes = @{}
        if ($diag.VpnAdapters.Count -gt 0) {
            # 重新获取以匹配InterfaceIndex
            $allAdaptersForIndex = Get-NetAdapter -ErrorAction SilentlyContinue
            if ($allAdaptersForIndex) {
                foreach ($adapter in $allAdaptersForIndex) {
                    if (Test-IsVpnAdapter -InterfaceDescription $adapter.InterfaceDescription -InterfaceAlias $adapter.Name) {
                        $vpnIfIndexes[$adapter.InterfaceIndex] = $true
                    }
                }
            }
        }

        # 也检查InterfaceAlias匹配的（回退方案）
        foreach ($route in $allRoutes) {
            $isVpnRoute = $false

            # 方案A: 通过InterfaceIndex匹配
            if ($vpnIfIndexes.ContainsKey($route.InterfaceIndex)) {
                $isVpnRoute = $true
            }

            # 方案B: 通过InterfaceAlias匹配（回退）
            if (-not $isVpnRoute -and $route.InterfaceAlias) {
                if (Test-IsVpnAdapter -InterfaceAlias $route.InterfaceAlias -InterfaceDescription '') {
                    $isVpnRoute = $true
                }
            }

            if ($isVpnRoute) {
                [void]$residualRouteList.Add(@{
                    Dest    = "$($route.DestinationPrefix)"
                    NextHop = "$($route.NextHop)"
                })
                # 残留路由算作警告级（非活动VPN的残留才算问题）
                $issueCount++
            }
        }

        $diag.VpnResidualRoutes = $residualRouteList.ToArray()
    } catch {
        $errors += "VPN残留路由检测失败: $_"
    }

    # ---------- 判定 Verdict ----------
    if ($failCount -gt 0) {
        $diag.Verdict = "FAIL"
    } elseif ($issueCount -gt 0) {
        $diag.Verdict = "WARN"
    } else {
        $diag.Verdict = "PASS"
    }

    # 超时警告
    $stopwatch.Stop()
    $elapsedMs = $stopwatch.ElapsedMilliseconds
    if ($elapsedMs -gt $Script:DiagnosisTimeoutMs) {
        if ($diag.Verdict -eq "PASS") {
            $diag.Verdict = "WARN"
        }
        $errors += "诊断超时: ${elapsedMs}ms (目标: $Script:DiagnosisTimeoutMs`ms)"
    }

    # ---------- 日志事件 ----------
    # 记录错误事件
    foreach ($err in $errors) {
        Write-ErrorEvent -Severity "low" -Message "[M06] $err" -StackTrace $null
    }

    # 记录诊断结论事件
    $extraFields = @{
        ie_proxy_set       = ($null -ne $diag.IEProxy)
        winhttp_proxy_set  = ($null -ne $diag.WinHttpProxy)
        env_proxy_count    = $diag.EnvProxy.Count
        vpn_adapter_count  = $diag.VpnAdapters.Count
        vpn_route_count    = $diag.VpnResidualRoutes.Count
        issue_count        = $issueCount
        fail_count         = $failCount
    }
    Write-DiagnosisEvent -Module "M06" -Verdict $diag.Verdict -ElapsedMs $elapsedMs -ExtraFields $extraFields

    # ---------- 返回 ----------
    return @{
        Diagnosis = $diag
        LogEvents = $logEvents.ToArray()
    }
}

# ============================================================
# 公共函数: Invoke-M06_Repair
# ============================================================

<#
.SYNOPSIS
    修复代理与VPN相关问题
.DESCRIPTION
    修复步骤：
      1. 关闭 IE 系统代理（ProxyEnable → 0）
      2. 重置 WinHTTP 代理（netsh winhttp reset proxy）
      3. 清除环境变量代理（User + Machine）
      4. 移除 VPN 残留路由（Remove-NetRoute）
      5. 验证修复结果
    风险等级：L1（极低，仅修改本机代理配置，不影响核心网络）
.PARAMETER Diagnosis
    由 Invoke-M06_Diagnose 返回的诊断结果哈希表
.OUTPUTS
    System.Collections.Hashtable
    返回 @{ Repair = @{...}; LogEvents = @(...) }
.EXAMPLE
    $diagResult = Invoke-M06_Diagnose -Context @{}
    $repairResult = Invoke-M06_Repair -Diagnosis $diagResult.Diagnosis
#>
function Invoke-M06_Repair {
    param(
        [hashtable]$Diagnosis
    )

    # ---------- 初始化 ----------
    $logEvents  = New-Object System.Collections.ArrayList
    $steps      = New-Object System.Collections.ArrayList
    $allSuccess = $true

    # 如果传入的诊断结果为空，跳过修复
    if (-not $Diagnosis) {
        Write-FixEvent -Module "M06" -EventSubType "end" -Verdict "skipped" -RebootRequired $false
        return @{
            Repair   = @{
                Verdict        = "skipped"
                RebootRequired = $false
                Steps          = @("诊断数据为空，跳过修复")
            }
            LogEvents = $logEvents.ToArray()
        }
    }

    # 如果诊断结果为 PASS（无问题），跳过修复
    if ($Diagnosis.Verdict -eq "PASS") {
        Write-FixEvent -Module "M06" -EventSubType "end" -Verdict "skipped" -RebootRequired $false
        return @{
            Repair   = @{
                Verdict        = "skipped"
                RebootRequired = $false
                Steps          = @("诊断结果全部通过，无需修复")
            }
            LogEvents = $logEvents.ToArray()
        }
    }

    # ---------- 步骤1: 关闭 IE 系统代理 ----------
    if ($Diagnosis.IEProxy) {
        $stepName = "关闭IE系统代理"
        try {
            Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 0 -ErrorAction Stop
            [void]$steps.Add("[OK] $stepName")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step $stepName -ExitCode 0
        } catch {
            [void]$steps.Add("[FAIL] $stepName : $_")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step "$stepName 失败: $_" -ExitCode 1
            Write-ErrorEvent -Severity "low" -Message "[M06] $stepName 失败: $_" -StackTrace $_.Exception.StackTrace
            $allSuccess = $false
        }
    } else {
        [void]$steps.Add("[SKIP] IE系统代理未设置，跳过")
    }

    # ---------- 步骤2: 重置 WinHTTP 代理 ----------
    if ($Diagnosis.WinHttpProxy) {
        $stepName = "重置WinHTTP代理"
        try {
            $resetOutput = & netsh winhttp reset proxy 2>&1
            $resetSuccess = ($LASTEXITCODE -eq 0)

            if ($resetSuccess) {
                [void]$steps.Add("[OK] $stepName")
                Write-FixEvent -Module "M06" -EventSubType "step" -Step $stepName -ExitCode 0
            } else {
                throw "netsh 退出码: $LASTEXITCODE, 输出: $resetOutput"
            }
        } catch {
            [void]$steps.Add("[FAIL] $stepName : $_")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step "$stepName 失败: $_" -ExitCode 1
            Write-ErrorEvent -Severity "low" -Message "[M06] $stepName 失败: $_" -StackTrace $_.Exception.StackTrace
            $allSuccess = $false
        }
    } else {
        [void]$steps.Add("[SKIP] WinHTTP代理未设置，跳过")
    }

    # ---------- 步骤3: 清除环境变量代理 ----------
    if ($Diagnosis.EnvProxy -and $Diagnosis.EnvProxy.Count -gt 0) {
        $stepName = "清除环境变量代理"
        $clearOk = $true

        foreach ($envEntry in $Diagnosis.EnvProxy) {
            $varName = $envEntry.Name
            # 同时清除 User 和 Machine 级别
            $userResult   = Clear-EnvVarSafe -Name $varName -Scope 'User'
            $machineResult = Clear-EnvVarSafe -Name $varName -Scope 'Machine'

            if (-not $userResult -or -not $machineResult) {
                $clearOk = $false
            }
        }

        if ($clearOk) {
            [void]$steps.Add("[OK] $stepName (已清除 $($Diagnosis.EnvProxy.Count) 个变量)")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step $stepName -ExitCode 0
        } else {
            [void]$steps.Add("[WARN] $stepName : 部分变量清除失败")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step "$stepName 部分失败" -ExitCode 1
            $allSuccess = $false
        }
    } else {
        [void]$steps.Add("[SKIP] 环境变量代理未设置，跳过")
    }

    # ---------- 步骤4: 移除 VPN 残留路由 ----------
    if ($Diagnosis.VpnResidualRoutes -and $Diagnosis.VpnResidualRoutes.Count -gt 0) {
        $stepName = "移除VPN残留路由"
        $routeRemoveOk = $true

        foreach ($residualRoute in $Diagnosis.VpnResidualRoutes) {
            $dest = $residualRoute.Dest
            try {
                Remove-NetRoute -DestinationPrefix $dest -Confirm:$false -ErrorAction Stop
            } catch {
                # 尝试用 NextHop 辅助匹配
                try {
                    $matchingRoutes = Get-NetRoute -DestinationPrefix $dest -ErrorAction SilentlyContinue
                    foreach ($r in $matchingRoutes) {
                        if (Test-IsVpnAdapter -InterfaceAlias $r.InterfaceAlias -InterfaceDescription '') {
                            Remove-NetRoute -DestinationPrefix $dest -NextHop $r.NextHop -Confirm:$false -ErrorAction Stop
                        }
                    }
                } catch {
                    $routeRemoveOk = $false
                    Write-ErrorEvent -Severity "low" -Message "[M06] 移除VPN残留路由失败: $dest : $_" -StackTrace $_.Exception.StackTrace
                }
            }
        }

        if ($routeRemoveOk) {
            [void]$steps.Add("[OK] $stepName (已移除 $($Diagnosis.VpnResidualRoutes.Count) 条路由)")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step $stepName -ExitCode 0
        } else {
            [void]$steps.Add("[WARN] $stepName : 部分路由移除失败")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step "$stepName 部分失败" -ExitCode 1
            $allSuccess = $false
        }
    } else {
        [void]$steps.Add("[SKIP] 无VPN残留路由，跳过")
    }

    # ---------- 步骤5: 验证修复结果 ----------
    $stepName = "验证修复结果"
    try {
        $verifyResult = Invoke-M06_Diagnose -Context @{}
        $verifyVerdict = $verifyResult.Diagnosis.Verdict

        if ($verifyVerdict -eq "PASS") {
            [void]$steps.Add("[OK] $stepName - 代理配置已清理完毕")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step $stepName -ExitCode 0
        } else {
            [void]$steps.Add("[WARN] $stepName - 仍有残留问题 (Verdict: $verifyVerdict)")
            Write-FixEvent -Module "M06" -EventSubType "step" -Step "$stepName 仍有问题: $verifyVerdict" -ExitCode 1
            $allSuccess = $false
        }
    } catch {
        [void]$steps.Add("[FAIL] $stepName : $_")
        Write-FixEvent -Module "M06" -EventSubType "step" -Step "$stepName 失败: $_" -ExitCode 1
        $allSuccess = $false
    }

    # ---------- 最终判定 ----------
    $finalVerdict = if ($allSuccess) { "success" } else { "failed" }

    Write-FixEvent -Module "M06" -EventSubType "end" -Verdict $finalVerdict -RebootRequired $false

    return @{
        Repair = @{
            Verdict        = $finalVerdict
            RebootRequired = $false
            Steps          = $steps.ToArray()
        }
        LogEvents = $logEvents.ToArray()
    }
}

<#
.SYNOPSIS
    导出函数清单
.DESCRIPTION
    本模块导出以下公共函数：
      - Invoke-M06_Diagnose  诊断代理与VPN配置
      - Invoke-M06_Repair    修复代理与VPN问题
#>
