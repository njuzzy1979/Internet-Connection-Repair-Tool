# Utils.ps1 - NetAid 网络修复工具通用工具库
# 提供管理员检测、系统信息采集、注册表备份、数字签名验证等基础功能
# 本文件通过 dot-source 加载，所有函数和变量自动导入调用方作用域
# 编码: UTF-8 with BOM | 兼容: Windows PowerShell 5.1+

# ============================================================
# 脚本级变量
# ============================================================

# 模块短名到文件名的映射表，供 Get-ModulePath 使用
$Script:ModuleMap = @{
    "adapter"    = "M01_Adapter"
    "dhcp"       = "M02_IP_DHCP"
    "dns"        = "M03_DNS"
    "route"      = "M04_Route"
    "firewall"   = "M05_Firewall"
    "proxy"      = "M06_Proxy"
    "thirdparty" = "M07_ThirdParty"
    "winsock"    = "M08_Winsock"
    "hosts"      = "M09_Hosts"
    "ipconflict" = "M10_IPConflict"
    "deepclean"  = "M11_DeepClean"
    "all"        = "*"
}

# ============================================================
# 黑名单数据：已知安全软件残留驱动 (供 M07_ThirdParty 使用)
# 参考设计文档 3.7.2 节
# ============================================================

$Script:KnownResidueDrivers = @{
    # ---- 360 系列 ----
    "360Box64.sys"              = "360 安全卫士 - 核心驱动"
    "360AntiHacker64.sys"       = "360 安全卫士 - 防黑客驱动"
    "360AntiAttack64.sys"       = "360 安全卫士 - 防攻击驱动"
    "360netmon.sys"             = "360 安全卫士 - 网络监控驱动"
    "360AntiFraud64.sys"        = "360 安全卫士 - 反欺诈驱动"
    "360Hvm64.sys"              = "360 安全卫士 - 硬件虚拟化驱动"
    "360AvFlt.sys"              = "360 安全卫士 - 反病毒过滤驱动"
    "360SelfProtection.sys"     = "360 安全卫士 - 自保护驱动"
    "BAPIDRV64.sys"             = "360 安全卫士 - BAPI 驱动"
    "efimon.sys"                = "360 安全卫士 - EFI 监控驱动"
    "360qpesv64.sys"            = "360 安全卫士 - QPE 服务驱动"
    "360FsFlt.sys"              = "360 安全卫士 - 文件系统过滤驱动"
    "360AntiMalware.sys"        = "360 安全卫士 - 反恶意软件驱动"
    "360AntiSteal64.sys"        = "360 安全卫士 - 防盗号驱动"
    "360AntiExploit64.sys"      = "360 安全卫士 - 漏洞利用防护驱动"

    # ---- 火绒系列 ----
    "sysdiag.sys"               = "火绒安全软件 - 系统诊断驱动"
    "sysdiag_win10.sys"         = "火绒安全软件 - Win10 系统诊断驱动"
    "hrwfpdrv.sys"              = "火绒安全软件 - WFP 网络过滤驱动"
    "hrwfpdrv_win10.sys"        = "火绒安全软件 - Win10 WFP 网络过滤驱动"
    "hrdevmon.sys"              = "火绒安全软件 - 设备监控驱动"
    "hrdevmon_win10.sys"        = "火绒安全软件 - Win10 设备监控驱动"
    "hrfwdrv.sys"               = "火绒安全软件 - 防火墙驱动"
    "hrfwdrv_win10.sys"         = "火绒安全软件 - Win10 防火墙驱动"
    "hrelam.sys"                = "火绒安全软件 - ELAM 反恶意软件早期启动驱动"
    "hrelam_win10.sys"          = "火绒安全软件 - Win10 ELAM 驱动"

    # ---- 腾讯管家系列 ----
    "TSDefenseBT.sys"           = "腾讯电脑管家 - 防御驱动"
    "TSDefenseBT64.sys"         = "腾讯电脑管家 - 64位防御驱动"
    "TSSysKit.sys"              = "腾讯电脑管家 - 系统工具驱动"
    "TSSysKit64.sys"            = "腾讯电脑管家 - 64位系统工具驱动"
    "TSKsp.sys"                 = "腾讯电脑管家 - 内核服务驱动"
    "TSKsp64.sys"               = "腾讯电脑管家 - 64位内核服务驱动"
    "TSSafeBox.sys"             = "腾讯电脑管家 - 安全箱驱动"
    "TSSafeBox64.sys"           = "腾讯电脑管家 - 64位安全箱驱动"
    "TFsFlt.sys"                = "腾讯电脑管家 - 文件系统过滤驱动"
    "TFsFlt64.sys"              = "腾讯电脑管家 - 64位文件系统过滤驱动"
    "TNetMon.sys"               = "腾讯电脑管家 - 网络监控驱动"
    "TNetMon64.sys"             = "腾讯电脑管家 - 64位网络监控驱动"
    "TSSysMon.sys"              = "腾讯电脑管家 - 系统监控驱动"
    "TSSysMon64.sys"            = "腾讯电脑管家 - 64位系统监控驱动"

    # ---- 金山毒霸 ----
    "kavbase.sys"               = "金山毒霸 - 基础驱动"
    "kavbase64.sys"             = "金山毒霸 - 64位基础驱动"
    "kisknl.sys"                = "金山毒霸 - 内核驱动"
    "kisknl64.sys"              = "金山毒霸 - 64位内核驱动"
    "kmodurl.sys"               = "金山毒霸 - URL 过滤驱动"
    "kmodurl64.sys"             = "金山毒霸 - 64位 URL 过滤驱动"
    "kwatch.sys"                = "金山毒霸 - 监控驱动"
    "kwatch64.sys"              = "金山毒霸 - 64位监控驱动"
    "KSafeSD.sys"               = "金山毒霸 - 安全防护驱动"
    "KSafeSD64.sys"             = "金山毒霸 - 64位安全防护驱动"

    # ---- 国外安全软件 ----
    "avipbb.sys"                = "Avira - 反病毒驱动"
    "avkmgr.sys"                = "Avira - 内核管理器"
    "avgntflt.sys"              = "Avira - 实时保护过滤驱动"
    "avdevprot.sys"             = "Avira - 设备保护驱动"
    "bdfwfpf.sys"               = "Bitdefender - WFP 过滤驱动"
    "bdvedisk.sys"              = "Bitdefender - 虚拟加密磁盘驱动"
    "bdsandbox.sys"             = "Bitdefender - 沙箱驱动"
    "edevmon.sys"               = "ESET - 设备监控驱动"
    "ehdrv.sys"                 = "ESET - 辅助驱动"
    "eamonm.sys"                = "ESET - 实时监控驱动"
    "epfw.sys"                  = "ESET - 个人防火墙驱动"
    "epfwwfp.sys"               = "ESET - WFP 防火墙驱动"
    "klif.sys"                  = "Kaspersky - 核心过滤驱动"
    "klflt.sys"                 = "Kaspersky - 文件系统过滤驱动"
    "klim6.sys"                 = "Kaspersky - NDIS 6.x 网络过滤驱动"
    "klwfp.sys"                 = "Kaspersky - WFP 过滤驱动"
    "klpd.sys"                  = "Kaspersky - 进程监控驱动"
    "kneps.sys"                 = "Kaspersky - 网络包截获驱动"
    "mfehidk.sys"               = "McAfee - 隐藏驱动"
    "mfeavfk.sys"               = "McAfee - 反病毒过滤驱动"
    "mfefirek.sys"              = "McAfee - 防火墙驱动"
    "mfewfpk.sys"               = "McAfee - WFP 过滤驱动"
    "symefasi.sys"              = "Symantec/Norton - 早期启动反恶意软件驱动"
    "symefa64.sys"              = "Symantec/Norton - 64位早期启动反恶意软件"
    "symnets.sys"               = "Symantec/Norton - 网络安全驱动"
    "symevnt.sys"               = "Symantec/Norton - 事件驱动"
    "Ironx64.sys"               = "Symantec/Norton - Iron 驱动"
    "srtsp64.sys"               = "Symantec/Norton - 实时保护驱动"
    "srtsp.sys"                 = "Symantec/Norton - 32位实时保护驱动"
    "tmcomm.sys"                = "Trend Micro - 通用通信驱动"
    "tmactmon.sys"              = "Trend Micro - 活动监控驱动"
    "tmevtmgr.sys"              = "Trend Micro - 事件管理器驱动"
    "tmwfp.sys"                 = "Trend Micro - WFP 过滤驱动"
    "tmusa.sys"                 = "Trend Micro - USA 驱动"
    "wdfilter.sys"              = "Windows Defender / WD - 过滤驱动残留 (wdfilter/WdFilter)"
    "WdNisDrv.sys"              = "Windows Defender - 网络检查系统驱动 (残留)"
    "aswArPot.sys"              = "Avast - 反 Rootkit/ARP 防护"
    "aswbidsh.sys"              = "Avast - 行为 ID 防护"
    "aswbuniv.sys"              = "Avast - 通用驱动"
    "aswHwid.sys"               = "Avast - 硬件 ID 驱动"
    "aswKbd.sys"                = "Avast - 键盘过滤驱动"
    "aswMonFlt.sys"             = "Avast - 文件系统过滤驱动"
    "aswNetHub.sys"             = "Avast - 网络集线器驱动"
    "aswRdr2.sys"               = "Avast - WFP 重定向驱动"
    "aswRvrt.sys"               = "Avast - 还原驱动"
    "aswSnx.sys"                = "Avast - 网络安全驱动"
    "aswSP.sys"                 = "Avast - 自保护驱动"
    "aswStm.sys"                = "Avast - 流过滤驱动"
    "aswVmm.sys"                = "Avast - 虚拟机监控驱动"
    "avgArPot.sys"              = "AVG - 反 Rootkit 驱动"
    "avgSnx.sys"                = "AVG - 网络安全驱动"

    # ---- VPN 虚拟网卡驱动 ----
    "tap0901.sys"               = "OpenVPN - TAP 虚拟网卡驱动"
    "tapwindows.sys"            = "OpenVPN - TAP Windows 驱动"
    "tunparse.sys"              = "TunSafe - TUN 解析驱动"
    "wintun.sys"                = "WireGuard - WinTUN 虚拟网卡驱动"
    "WireGuard.sys"             = "WireGuard - 内核驱动"
    "npcap.sys"                 = "Npcap - 数据包捕获驱动"
    "npf.sys"                   = "WinPcap - 数据包捕获驱动"
    "neo6_x64.sys"              = "SaferVPN / Speedify - Neo 虚拟网卡"
    "pango_driver.sys"          = "Pango VPN - 虚拟网卡驱动"
    "vpnclient.sys"             = "Cisco VPN Client - 虚拟网卡驱动"
    "CVPNDRVA.sys"              = "Cisco AnyConnect - 虚拟网卡驱动 A"
    "acpiex.sys"                = "Cisco AnyConnect - ACPIEx 驱动"
    "splashvpn.sys"             = "Splashtop VPN - 虚拟网卡驱动"
    "surfshark_tap.sys"         = "Surfshark VPN - TAP 驱动"
    "nordvpn_tap.sys"           = "NordVPN - TAP 驱动"
    "expressvpntap.sys"         = "ExpressVPN - TAP 驱动"
    "pppop64.sys"               = "PPPoP VPN - 虚拟网卡驱动"

    # ---- 其他国内安全软件 ----
    "QQSysMonX64.sys"           = "QQ 电脑管家 - 系统监控驱动"
    "QMNetFlowwin10.sys"        = "QQ 电脑管家 - 网络流量驱动"
    "qutmdrv.sys"               = "QQ 电脑管家 - 防御驱动"
    "TsNetHlpX64.sys"           = "腾讯安全 - 网络帮助驱动"
    "wanguard_x64.sys"          = "位盾 - 64位核心驱动"
    "RansomDefender.sys"        = "勒索防护 - 通用反勒索驱动"
    "SafeDogGuardian.sys"       = "安全狗 - 服务器安全驱动"
    "SafeDogApche.sys"          = "安全狗 - Apache 插件驱动"
    "SafeDogSiteIIS.sys"        = "安全狗 - IIS 插件驱动"
    "yunsuo.sys"                = "云锁 - 服务器安全驱动"
    "LittleRedBook.sys"         = "小红书安全 - 内核驱动"
    "dingjiasafe.sys"           = "顶佳安全 - 内核驱动"
    "JdProtect.sys"             = "京东 - 安全防护驱动"
}

# ============================================================
# 可疑 WFP Provider 名单 (供 M07_ThirdParty 使用)
# 参考设计文档 3.7.3 节
# ============================================================

$Script:SuspiciousWfpProviders = @(
    # 360 系列 WFP Provider
    "360 Internet Security"
    "360 Total Security"
    "360Safe"
    # 火绒系列 WFP Provider
    "Huorong Internet Security"
    "HuoRong Security"
    "HRWFP"
    # 腾讯管家系列 WFP Provider
    "Tencent PC Manager"
    "QQPCMgr"
    "TNetMon"
    # 金山毒霸 WFP Provider
    "Kingsoft Internet Security"
    "KIS WFP"
    # 国外安全软件 WFP Provider
    "Kaspersky Anti-Virus"
    "Kaspersky Internet Security"
    "KLWFP"
    "ESET Personal Firewall"
    "ESET WFP"
    "McAfee WFP"
    "McAfee Firewall"
    "Norton Internet Security"
    "Symantec Endpoint Protection"
    "Bitdefender Firewall"
    "Bitdefender WFP"
    "Trend Micro WFP"
    "Avast Antivirus"
    "AVG Antivirus"
    "Avira WFP"
    "Comodo Firewall"
    "Comodo Internet Security"
    "F-Secure WFP"
    "G Data Internet Security"
    "Malwarebytes WFP"
    "Sophos Network Threat Protection"
    "Webroot SecureAnywhere"
    # 其他国内安全软件 WFP Provider
    "SafeDog WFP"
    "YunSuo WFP"
    "ServerSafe"
    # 代理/VPN 类 WFP Provider
    "Proxifier"
    "SocksCap"
    "NetLimiter"
    "NetBalance"
    "cFosSpeed"
    "SoftPerfect"
    "GlassWire"
)

# ============================================================
# 函数定义
# ============================================================

<#
.SYNOPSIS
    检测当前进程是否以管理员权限运行
.DESCRIPTION
    使用 .NET 安全主体 API 判断当前用户是否属于 Administrators 组
.OUTPUTS
    System.Boolean - $true 表示以管理员权限运行
.EXAMPLE
    if (Test-IsAdmin) { Write-Host "已提权" }
#>
function Test-IsAdmin {
    [CmdletBinding()]
    param()

    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Warning "检测管理员权限失败: $_"
        return $false
    }
}

<#
.SYNOPSIS
    获取操作系统版本信息
.DESCRIPTION
    通过 [Environment]::OSVersion 和注册表获取详细 OS 版本信息
.OUTPUTS
    System.Collections.Hashtable - 包含 Name, Version, Build, IsWin10, IsWin11 等字段
.EXAMPLE
    $osInfo = Get-OSVersion
    Write-Host "$($osInfo.Name) Build $($osInfo.Build)"
#>
function Get-OSVersion {
    [CmdletBinding()]
    param()

    $osVersion = [Environment]::OSVersion
    $build     = $osVersion.Version.Build
    $versionStr = "$($osVersion.Version.Major).$($osVersion.Version.Minor).$build"

    # 从注册表获取 DisplayVersion (Win10 20H1+) 和 ReleaseId (旧版)
    $displayVersion = ""
    $releaseId      = ""
    $productName    = ""

    try {
        $regKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
        if ($regKey) {
            $displayVersion = $regKey.DisplayVersion
            $releaseId      = $regKey.ReleaseId
            $productName    = $regKey.ProductName
        }
    } catch {
        # 注册表读取失败时忽略，使用默认值
    }

    # 判断 Windows 版本
    $isWin10 = ($osVersion.Version.Major -eq 10 -and $build -ge 10240)
    # Win11 通常 build >= 22000，也可通过 ProductName 辅助判断
    $isWin11 = ($build -ge 22000) -or ($productName -match "Windows 11")

    $name = "Unknown"
    if ($isWin11) {
        $name = "Win11"
    } elseif ($isWin10) {
        $name = "Win10"
    } elseif ($osVersion.Version.Major -eq 6 -and $osVersion.Version.Minor -ge 1) {
        $name = "Win7/8"
    }

    return @{
        Name            = $name
        Version         = $versionStr
        Build           = $build
        DisplayVersion  = $displayVersion
        ReleaseId       = $releaseId
        ProductName     = $productName
        IsWin10         = $isWin10
        IsWin11         = $isWin11
    }
}

<#
.SYNOPSIS
    检测 PowerShell 运行环境
.DESCRIPTION
    检查语言模式、受限模式、AppLocker 策略、PS 版本等
.OUTPUTS
    System.Collections.Hashtable - 包含 LanguageMode, IsConstrained, IsAppLocker, PSVersion
.EXAMPLE
    $env = Test-PSEnvironment
    if ($env.IsConstrained) { Write-Warning "当前为受限语言模式" }
#>
function Test-PSEnvironment {
    [CmdletBinding()]
    param()

    $languageMode  = $ExecutionContext.SessionState.LanguageMode.ToString()
    $isConstrained = ($languageMode -eq "ConstrainedLanguage")
    $isAppLocker   = $false

    if ($isConstrained) {
        # 受限模式下尝试检测 AppLocker 策略
        try {
            $appLockerPolicy = Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue
            if ($appLockerPolicy) { $isAppLocker = $true }
        } catch {
            # 获取失败时不中断
        }
    }

    $psVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Build).$($PSVersionTable.PSVersion.Revision)"

    return @{
        LanguageMode  = $languageMode
        IsConstrained = $isConstrained
        IsAppLocker   = $isAppLocker
        PSVersion     = $psVersion
        PSEdition     = $PSVersionTable.PSEdition
    }
}

<#
.SYNOPSIS
    检测当前是否为远程会话 (RDP/SSH/WinRM)
.DESCRIPTION
    通过环境变量和会话 ID 检测当前会话类型
.OUTPUTS
    System.Boolean - $true 表示当前为远程会话
.EXAMPLE
    if (Test-RemoteSession) { Write-Host "当前为远程会话，部分操作可能受限" }
#>
function Test-RemoteSession {
    [CmdletBinding()]
    param()

    $isRemote = $false

    # 检查 SSH 会话环境变量
    if ($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SSH_TTY) {
        $isRemote = $true
    }

    # 检查 WinRM / Remote Desktop 环境变量
    if ($env:REMOTEHOST) {
        $isRemote = $true
    }

    # 通过会话 ID 检测: 控制台会话通常 SessionId 为 1 或 0 (服务)
    try {
        $currentSessionId = (Get-Process -Id $pid).SessionId
        if ($currentSessionId -ne 0 -and $currentSessionId -ne 1) {
            # 会话 ID 不为 0(服务) 或 1(物理控制台)，可能为远程
            $isRemote = $true
        }
    } catch {
        # 获取进程信息失败时忽略
    }

    return $isRemote
}

<#
.SYNOPSIS
    根据 CLI 短名返回对应模块文件的完整路径
.DESCRIPTION
    使用 $Script:ModuleMap 将短名映射到 modules/Mxx_Name.ps1
.PARAMETER ModuleName
    模块短名，如 "adapter", "dhcp", "dns" 等
.OUTPUTS
    System.String - 模块文件的完整路径
.EXAMPLE
    $path = Get-ModulePath -ModuleName "firewall"
    # 返回如 "...\NetAid\modules\M05_Firewall.ps1"
#>
function Get-ModulePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName
    )

    $moduleFileName = $Script:ModuleMap[$ModuleName.ToLower()]
    if (-not $moduleFileName) {
        Write-Warning "未知的模块短名: '$ModuleName'，可用值: $($Script:ModuleMap.Keys -join ', ')"
        return $null
    }

    # 从 lib 目录向上到 NetAid 根目录，再进 modules
    $rootPath   = Join-Path $PSScriptRoot ".."
    $modulePath = Join-Path $rootPath "modules" "$moduleFileName.ps1"

    return (Resolve-Path $modulePath -ErrorAction SilentlyContinue).Path
}

<#
.SYNOPSIS
    备份注册表键到 backups 目录
.DESCRIPTION
    使用 reg export 命令导出注册表键，备份文件以 sanitized 键名 + 时间戳命名
.PARAMETER KeyPath
    要备份的注册表键路径，如 "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip"
.OUTPUTS
    System.String - 备份文件的完整路径，失败返回 $null
.EXAMPLE
    $backupFile = Backup-RegistryKey -KeyPath "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
#>
function Backup-RegistryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    try {
        # 构建 backups 目录路径 (从 lib 向上两级到 NetAid\backups)
        $backupDir = Join-Path $PSScriptRoot ".." ".." "backups"
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }

        # 清理键名作为文件名一部分
        $sanitized = $KeyPath -replace '[\\:<>"/|?*]', '_' -replace '\s+', '_'
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $fileName  = "reg_${sanitized}_${timestamp}.reg"
        $filePath  = Join-Path $backupDir $fileName

        # 使用 reg export 导出
        $result = & reg export $KeyPath $filePath /y 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "注册表备份失败: $result"
            return $null
        }

        Write-Verbose "注册表已备份至: $filePath"
        return $filePath
    } catch {
        Write-Warning "备份注册表键时出错: $_"
        return $null
    }
}

<#
.SYNOPSIS
    展开注册表中可能包含 %SystemRoot% 等环境变量的路径
.DESCRIPTION
    使用 [Environment]::ExpandEnvironmentVariables 展开环境变量
.PARAMETER RawPath
    包含环境变量的原始路径字符串
.OUTPUTS
    System.String - 展开后的完整路径
.EXAMPLE
    $fullPath = Expand-EnvironmentPath -RawPath "%SystemRoot%\System32\drivers\etc\hosts"
    # 返回 "C:\Windows\System32\drivers\etc\hosts"
#>
function Expand-EnvironmentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawPath
    )

    try {
        return [Environment]::ExpandEnvironmentVariables($RawPath)
    } catch {
        Write-Warning "展开环境变量路径失败: $_"
        return $RawPath
    }
}

<#
.SYNOPSIS
    检查文件的数字签名主体
.DESCRIPTION
    使用 Get-AuthenticodeSignature 验证文件数字签名，返回规范化签名主体名称
.OUTPUTS
    System.String - "Microsoft" (微软签名), 签名主体名称, 或 "Unsigned"
.EXAMPLE
    $sig = Test-DigitalSignature -FilePath "C:\Windows\System32\drivers\tcpip.sys"
#>
function Test-DigitalSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    try {
        if (-not (Test-Path $FilePath)) {
            return "NotFound"
        }

        $signature = Get-AuthenticodeSignature -FilePath $FilePath -ErrorAction SilentlyContinue

        if ($null -eq $signature -or $signature.Status -eq "NotSigned") {
            return "Unsigned"
        }

        if ($signature.Status -eq "Valid" -or $signature.Status -eq "UnknownError") {
            $subject = $signature.SignerCertificate.Subject
            # 规范化微软签名
            if ($subject -match "Microsoft Windows" -or $subject -match "Microsoft Corporation") {
                return "Microsoft"
            }
            # 提取 CN (Common Name)
            if ($subject -match 'CN=([^,]+)') {
                return $Matches[1]
            }
            return $subject
        }

        return "Unsigned"
    } catch {
        Write-Warning "检查数字签名失败 ($FilePath): $_"
        return "Error"
    }
}

<#
.SYNOPSIS
    当 Get-NetAdapter 不可用时的 WMI 回退方案
.DESCRIPTION
    使用 Get-WmiObject 或 Get-CimInstance 查询 Win32_NetworkAdapter，返回类似 Get-NetAdapter 的结构化对象
.OUTPUTS
    System.Object[] - 网络适配器对象列表，包含 Name, Status, InterfaceDescription, MacAddress 等
.EXAMPLE
    $adapters = Get-NetAdapterFallback
    $adapters | Format-Table Name, Status
#>
function Get-NetAdapterFallback {
    [CmdletBinding()]
    param()

    $adapters = @()

    try {
        # 优先尝试 CIM (更现代)
        $wmiAdapters = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue

        if (-not $wmiAdapters) {
            # 回退到 WMI
            $wmiAdapters = Get-WmiObject -Class Win32_NetworkAdapter -ErrorAction SilentlyContinue
        }

        if (-not $wmiAdapters) {
            Write-Warning "无法通过 WMI/CIM 查询网络适配器"
            return $adapters
        }

        foreach ($adapter in $wmiAdapters) {
            # 仅返回启用的物理适配器
            if ($adapter.NetEnabled -eq $true) {
                $adapters += [PSCustomObject]@{
                    Name                 = $adapter.Name
                    InterfaceDescription = $adapter.Description
                    Status               = if ($adapter.NetConnectionStatus -eq 2) { "Up" } else { "Disconnected" }
                    MacAddress           = $adapter.MacAddress
                    Speed                = $adapter.Speed
                    AdapterType          = $adapter.AdapterType
                    InterfaceIndex       = $adapter.Index
                    DeviceID             = $adapter.DeviceID
                }
            }
        }

        return $adapters
    } catch {
        Write-Warning "获取网络适配器时出错: $_"
        return $adapters
    }
}

<#
.SYNOPSIS
    将字符串内容以 UTF-8 BOM 编码写入文件
.DESCRIPTION
    使用 .NET System.IO.File::WriteAllText 配合 UTF8Encoding($true) 确保写入 BOM
.PARAMETER Path
    目标文件路径
.PARAMETER Content
    要写入的字符串内容
.EXAMPLE
    ConvertTo-Utf8Bom -Path "C:\temp\output.txt" -Content "Hello, 世界"
#>
function ConvertTo-Utf8Bom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    try {
        $utf8BomEncoding = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($Path, $Content, $utf8BomEncoding)
        Write-Verbose "文件已以 UTF-8 BOM 编码写入: $Path"
    } catch {
        Write-Error "写入 UTF-8 BOM 文件失败: $_"
        throw
    }
}

<#
.SYNOPSIS
    采集系统环境快照，用于诊断和故障排除
.DESCRIPTION
    收集操作系统、PowerShell、.NET、WMI/CIM、网络、磁盘等信息
.OUTPUTS
    System.Collections.Hashtable - 包含各项系统环境信息
.EXAMPLE
    $snapshot = Get-SystemSnapshot
    $snapshot | ConvertTo-Json
#>
function Get-SystemSnapshot {
    [CmdletBinding()]
    param()

    $snapshot = @{}

    # --- OS 版本 ---
    try {
        $osInfo = Get-OSVersion
        $snapshot.os_version = $osInfo.Version
        $snapshot.os_name    = $osInfo.Name
        $snapshot.os_build   = $osInfo.Build
    } catch {
        $snapshot.os_version = "Unknown"
    }

    # --- PowerShell 版本 ---
    try {
        $snapshot.ps_version = $PSVersionTable.PSVersion.ToString()
    } catch {
        $snapshot.ps_version = "Unknown"
    }

    # --- .NET 版本 ---
    try {
        $dotnetKey = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
        if ($dotnetKey) {
            $dotnetProps = Get-ItemProperty $dotnetKey.PSPath -ErrorAction SilentlyContinue
            $snapshot.dotnet_version = if ($dotnetProps.Release) { $dotnetProps.Release } else { "Unknown" }
        } else {
            $snapshot.dotnet_version = "Not Found"
        }
    } catch {
        $snapshot.dotnet_version = "Unknown"
    }

    # --- WMI 状态 ---
    try {
        $wmiService = Get-Service -Name "Winmgmt" -ErrorAction SilentlyContinue
        $snapshot.wmi_status = if ($wmiService.Status -eq "Running") { "Running" } else { $wmiService.Status }
    } catch {
        $snapshot.wmi_status = "Unavailable"
    }

    # --- CIM 状态 ---
    try {
        $testCim = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $snapshot.cim_status = if ($testCim) { "Available" } else { "Unavailable" }
    } catch {
        $snapshot.cim_status = "Unavailable"
    }

    # --- PowerShell 语言模式 ---
    try {
        $snapshot.ps_language_mode = $ExecutionContext.SessionState.LanguageMode.ToString()
    } catch {
        $snapshot.ps_language_mode = "Unknown"
    }

    # --- 管理员权限检测 ---
    try {
        $snapshot.admin_elevated = Test-IsAdmin
    } catch {
        $snapshot.admin_elevated = $false
    }

    # --- 网络适配器数量 ---
    try {
        $snapshot.network_adapters_count = @(Get-NetAdapterFallback).Count
    } catch {
        $snapshot.network_adapters_count = 0
    }

    # --- 活动网络连接数 ---
    try {
        $connections = Get-NetTCPConnection -ErrorAction SilentlyContinue
        $snapshot.active_connections = if ($connections) { @($connections).Count } else { 0 }
    } catch {
        $snapshot.active_connections = 0
    }

    # --- 磁盘剩余空间 (GB) ---
    try {
        $logicalDisks = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        $freeGB = 0
        foreach ($disk in $logicalDisks) {
            $freeGB += [math]::Round($disk.FreeSpace / 1GB, 2)
        }
        $snapshot.disk_free_gb = $freeGB
    } catch {
        $snapshot.disk_free_gb = 0
    }

    # --- 远程会话检测 ---
    try {
        $snapshot.is_remote_session = Test-RemoteSession
    } catch {
        $snapshot.is_remote_session = $false
    }

    # --- Windows Update 服务状态 ---
    try {
        $wuService = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
        $snapshot.windows_update_service = if ($wuService) { $wuService.Status } else { "Not Found" }
    } catch {
        $snapshot.windows_update_service = "Unknown"
    }

    return $snapshot
}

<#
.SYNOPSIS
    检测系统是否为 Windows 10 1809 或更高版本
.DESCRIPTION
    从注册表读取 CurrentBuild 和 ReleaseId，要求 build >= 17763 (Win10 1809+)
.OUTPUTS
    System.Boolean - $true 表示 Win10 1809+ / Win11
.EXAMPLE
    if (Test-IsWin10OrLater) { Write-Host "满足最低系统要求" }
#>
function Test-IsWin10OrLater {
    [CmdletBinding()]
    param()

    try {
        $regKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
        if (-not $regKey) {
            return $false
        }

        $currentBuild  = [int]$regKey.CurrentBuild
        $releaseId     = $regKey.ReleaseId

        # Win10 1809 = build 17763
        # ReleaseId 1809 或更高 (1809, 1903, 1909, 2004, 2009, 20H2+, 21H1+)
        if ($currentBuild -ge 17763) {
            return $true
        }

        # 如果 build 号旧，但 ReleaseId 高 (部分早期 Win10 版本)
        if ($releaseId) {
            $releaseNum = $releaseId -replace '[^0-9]', ''
            if ($releaseNum.Length -ge 4) {
                $releaseInt = [int]$releaseNum.Substring(0, 4)
                if ($releaseInt -ge 1809) {
                    return $true
                }
            }
        }

        return $false
    } catch {
        Write-Warning "检测系统版本时出错: $_"
        return $false
    }
}

# ============================================================
# 网络环境快照（供事后离线分析）
# ============================================================

<#
.SYNOPSIS
    保存完整的系统网络环境快照到日志目录
.DESCRIPTION
    采集网络配置、适配器、路由、服务、驱动、注册表等完整信息，
    写入单个文本文件。修复失败时用户可将此文件提供给技术支持分析。
.PARAMETER SnapshotDir
    快照保存目录（通常为 logs 目录）
.PARAMETER Tag
    快照标签：before_diag / before_repair / after_repair
.OUTPUTS
    String - 快照文件完整路径，失败返回 $null
#>
function Save-NetworkSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SnapshotDir,

        [Parameter(Mandatory = $false)]
        [string]$Tag = 'manual'
    )

    try {
        if (-not (Test-Path $SnapshotDir)) {
            New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null
        }

        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $file = Join-Path $SnapshotDir "snapshot_${Tag}_${ts}.txt"
        $sb = New-Object System.Text.StringBuilder

        # 关键编码修复：原生命令(ipconfig/route/arp/netsh)在中文系统输出 GBK 字节，
        # 若控制台编码被设为 UTF-8 会解码成乱码/方框。
        # 采集期间临时切换为系统 OEM 编码(中文=GBK 936)，结束后恢复。
        $prevConsoleEnc = [Console]::OutputEncoding
        try {
            $oemCodePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding($oemCodePage)
        } catch { }

        [void]$sb.AppendLine("=" * 70)
        [void]$sb.AppendLine("NetAid 网络环境快照  [$Tag]")
        [void]$sb.AppendLine("时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$sb.AppendLine("主机: $env:COMPUTERNAME  用户: $env:USERNAME")
        [void]$sb.AppendLine("=" * 70)

        # --- 1. 系统信息 ---
        [void]$sb.AppendLine("`n### 1. 系统信息 ###")
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            [void]$sb.AppendLine("OS: $($os.Caption) $($os.Version) Build $($os.BuildNumber)")
            [void]$sb.AppendLine("安装日期: $($os.InstallDate)")
            [void]$sb.AppendLine("最后启动: $($os.LastBootUpTime)")
        } catch { [void]$sb.AppendLine("获取失败: $_") }

        # --- 2. ipconfig /all ---
        [void]$sb.AppendLine("`n### 2. ipconfig /all ###")
        try { [void]$sb.AppendLine((& ipconfig /all 2>&1 | Out-String)) } catch { [void]$sb.AppendLine("失败: $_") }

        # --- 3. 网络适配器 ---
        [void]$sb.AppendLine("`n### 3. Get-NetAdapter ###")
        try {
            $adapters = Get-NetAdapter -ErrorAction Stop | Format-Table Name, InterfaceDescription, Status, LinkSpeed, MacAddress, DriverVersion, DriverDate -AutoSize | Out-String -Width 200
            [void]$sb.AppendLine($adapters)
        } catch { [void]$sb.AppendLine("失败: $_") }

        # --- 4. 适配器绑定 ---
        [void]$sb.AppendLine("`n### 4. Get-NetAdapterBinding (已启用的绑定) ###")
        try {
            $bindings = Get-NetAdapterBinding -ErrorAction Stop | Where-Object Enabled | Format-Table Name, ComponentID, DisplayName -AutoSize | Out-String -Width 200
            [void]$sb.AppendLine($bindings)
        } catch { [void]$sb.AppendLine("失败: $_") }

        # --- 5. 路由表 ---
        [void]$sb.AppendLine("`n### 5. route print ###")
        try { [void]$sb.AppendLine((& route print 2>&1 | Out-String)) } catch { [void]$sb.AppendLine("失败: $_") }

        # --- 6. ARP 表 ---
        [void]$sb.AppendLine("`n### 6. arp -a ###")
        try { [void]$sb.AppendLine((& arp -a 2>&1 | Out-String)) } catch { [void]$sb.AppendLine("失败: $_") }

        # --- 7. 关键网络服务 ---
        [void]$sb.AppendLine("`n### 7. 关键网络服务状态 ###")
        $svcNames = @('Dhcp','Dnscache','NlaSvc','netprofm','WlanSvc','WinHttpAutoProxySvc','BFE','MpsSvc','nsi','Netman','LanmanWorkstation','iphlpsvc')
        foreach ($sn in $svcNames) {
            try {
                $svc = Get-Service -Name $sn -ErrorAction Stop
                $st = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$sn" -Name Start -ErrorAction SilentlyContinue).Start
                [void]$sb.AppendLine("  $sn : $($svc.Status)  StartType=$($svc.StartType)  RegStart=$st")
            } catch { [void]$sb.AppendLine("  $sn : NOT_FOUND") }
        }

        # --- 8. Winsock 目录 ---
        [void]$sb.AppendLine("`n### 8. netsh winsock show catalog (前80行) ###")
        try {
            $ws = & netsh winsock show catalog 2>&1 | Select-Object -First 80
            [void]$sb.AppendLine(($ws | Out-String))
        } catch { [void]$sb.AppendLine("失败: $_") }

        # --- 9. WinHTTP 代理 ---
        [void]$sb.AppendLine("`n### 9. netsh winhttp show proxy ###")
        try { [void]$sb.AppendLine((& netsh winhttp show proxy 2>&1 | Out-String)) } catch { [void]$sb.AppendLine("失败: $_") }

        # --- 10. NDIS 过滤驱动（FilterClass 服务） ---
        [void]$sb.AppendLine("`n### 10. NDIS 过滤驱动注册扫描 ###")
        try {
            $svcKeys = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue
            foreach ($k in $svcKeys) {
                $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
                if ($p -and $p.PSObject.Properties['FilterClass']) {
                    $img = if ($p.PSObject.Properties['ImagePath']) { $p.ImagePath } else { '' }
                    $start = if ($p.PSObject.Properties['Start']) { $p.Start } else { '?' }
                    $imgExpand = [Environment]::ExpandEnvironmentVariables("$img") -replace '^\\SystemRoot\\', "$env:SystemRoot\"
                    $exists = if ($imgExpand -and (Test-Path $imgExpand -ErrorAction SilentlyContinue)) { 'YES' } else { 'NO' }
                    [void]$sb.AppendLine("  $($k.PSChildName) : FilterClass=$($p.FilterClass) Start=$start File=$exists Path=$img")
                }
            }
        } catch { [void]$sb.AppendLine("失败: $_") }

        # --- 11. 可疑驱动文件 ---
        [void]$sb.AppendLine("`n### 11. drivers 目录可疑 .sys 文件 ###")
        $patterns = @('360*.sys','Bapidrv*.sys','QKNet*.sys','TS*.sys','QQPC*.sys','KNB*.sys','hrwfp*.sys','hrdev*.sys','sysdiag*.sys')
        foreach ($pat in $patterns) {
            try {
                $fs = Get-ChildItem "$env:SystemRoot\System32\drivers" -Filter $pat -File -ErrorAction SilentlyContinue
                foreach ($f in $fs) {
                    [void]$sb.AppendLine("  $($f.Name)  $([math]::Round($f.Length/1KB,1))KB  修改:$($f.LastWriteTime.ToString('yyyy-MM-dd'))")
                }
            } catch { }
        }

        # --- 12. DHCP/AFD 注册表关键值 ---
        [void]$sb.AppendLine("`n### 12. DHCP/AFD 服务注册表 ###")
        foreach ($sn in @('Dhcp','AFD','Tcpip','NetBT','nsi')) {
            try {
                $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$sn" -ErrorAction Stop
                $start = if ($p.PSObject.Properties['Start']) { $p.Start } else { '?' }
                $deps = if ($p.PSObject.Properties['DependOnService']) { ($p.DependOnService -join ',') } else { '' }
                [void]$sb.AppendLine("  $sn : Start=$start Depends=[$deps]")
            } catch { [void]$sb.AppendLine("  $sn : NOT_FOUND") }
        }

        # --- 13. 事件日志（网络相关错误，最近24h，前20条） ---
        [void]$sb.AppendLine("`n### 13. 系统事件日志（网络相关错误 24h内 前20条） ###")
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName = 'System'
                Level = 1,2,3
                StartTime = (Get-Date).AddHours(-24)
                ProviderName = 'Microsoft-Windows-Dhcp-Client','Microsoft-Windows-Tcpip','Microsoft-Windows-NDIS','Microsoft-Windows-DNS-Client','Tcpip','Dhcp'
            } -MaxEvents 20 -ErrorAction Stop
            foreach ($ev in $events) {
                $msg = if ($ev.Message) { $ev.Message.Split("`n")[0] } else { '(no message)' }
                [void]$sb.AppendLine("  [$($ev.TimeCreated.ToString('MM-dd HH:mm'))] ID=$($ev.Id) $($ev.ProviderName): $msg")
            }
        } catch { [void]$sb.AppendLine("  无相关事件或查询失败: $($_.Exception.Message)") }

        [void]$sb.AppendLine("`n" + ("=" * 70))
        [void]$sb.AppendLine("快照结束")

        # 恢复控制台编码
        try { [Console]::OutputEncoding = $prevConsoleEnc } catch { }

        # 写入文件（UTF-8 with BOM，记事本可正确识别）
        [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        return $file
    } catch {
        # 异常路径同样恢复编码
        try { if ($prevConsoleEnc) { [Console]::OutputEncoding = $prevConsoleEnc } } catch { }
        Write-Warning "网络快照保存失败: $_"
        return $null
    }
}

# ============================================================
# 脚本结束
# 本文件通过 dot-source (. .\lib\Utils.ps1) 加载时，
# 所有函数和变量自动在当前作用域中可用，无需显式导出。
# ============================================================
