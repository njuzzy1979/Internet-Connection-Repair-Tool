# 断网急救箱 (NetAid)

> Windows 网络诊断与修复工具 | PowerShell 5.1 零依赖 | Win10 1809+ / Win11 全版本

## 功能简介

断网急救箱是一款纯 PowerShell 5.1 零依赖网络诊断与修复工具，覆盖 11 类常见网络故障，支持一键诊断与分级自动修复。

### 11 大诊断模块

| 编号 | 模块 | 检测内容 |
| ---- | ---- | ---- |
| M01 | 适配器状态 | 网卡状态、驱动、Wi-Fi 信号、飞行模式、NCSI 探针 |
| M02 | IP配置与DHCP | APIPA检测(169.254)、DHCP租约、IPv6地址、MTU值 |
| M03 | DNS解析 | 域名解析测试(IPv4+IPv6)、Ping辅助验证、DNS服务器可达性 |
| M04 | 路由表 | 默认网关(IPv4+IPv6)、黑洞路由、metric冲突、ARP可达性 |
| M05 | 防火墙 | 三配置文件状态、异常出站阻止规则、MpsSvc/BFE服务 |
| M06 | VPN/代理残留 | IE代理、WinHTTP代理、环境变量代理、VPN残留路由 |
| M07 | 第三方残留 | 安全软件残留驱动(WFP/LSP)、TAP/Wintun虚拟适配器、蓝牙PAN |
| M08 | Winsock/协议栈 | Winsock目录完整性、TCP/IP注册表参数、网络服务状态 |
| M09 | hosts劫持 | 关键域名劫持检测、文件权限、编码异常 |
| M10 | IP冲突 | ARP表IP-MAC冲突、系统事件日志(EventID 4199) |
| M11 | 深度残留 | 内核级NDIS过滤驱动残留、DHCP依赖链损坏、孤儿.sys文件 |

### 4 级修复引擎

| 级别 | 名称 | 典型操作 | 风险 | 影响 |
| ---- | ---- | ---- | ---- | ---- |
| L1 | 轻量刷新 | flushdns、hosts修复、代理重置、ARP清理 | 极低 | 无中断 |
| L2 | 网络层修复 | DHCP续租、DNS重置、路由修复 | 低 | 短暂中断 |
| L3 | 协议栈修复 | Winsock重置、TCP/IP重置、防火墙重置 | 中 | 需重启 |
| L4a | 驱动级修复 | 禁用第三方驱动、重启网卡 | 中-高 | 可能需重启 |
| L4b | 终极重置 | netcfg -d + DISM系统修复 | 极高 | 强制重启 |

## 系统要求

- **操作系统**: Windows 10 1809+ 或 Windows 11 全版本
- **PowerShell**: Windows PowerShell 5.1（系统自带）
- **权限**: 诊断可非管理员运行，修复需管理员权限
- **依赖**: 零第三方依赖，无需联网
- **语言模式**: ConstrainedLanguage 可运行诊断（部分限制）；FullLanguage 全功能

## 快速开始

### 方式一：BAT 启动器（推荐）

右键 `NetAid.bat` → **"以管理员身份运行"**

### 方式二：PowerShell 命令行

```powershell
# 进入脚本目录
cd "C:\path\to\NetAid"

# 仅诊断（无需管理员）
.\NetAid.ps1 -Check

# 诊断并自动修复（需管理员）
.\NetAid.ps1 -Auto

# 修复指定模块
.\NetAid.ps1 -Fix dns

# 查看帮助
.\NetAid.ps1 -Help
```

## 命令行参数

| 参数 | 说明 | 示例 |
| ---- | ---- | ---- |
| `-Auto` | 全自动模式：诊断+修复+报告+退出 | `NetAid -Auto` |
| `-Check` | 仅诊断，输出报告（不修复） | `NetAid -Check` |
| `-Fix <模块>` | 修复指定模块 | `NetAid -Fix dns` |
| `-FixAll` | 修复所有问题（L1+L2自动，L3+L4确认） | `NetAid -FixAll` |
| `-Module <模块>` | 仅诊断指定模块 | `NetAid -Module adapter` |
| `-Log <路径>` | 指定日志输出路径 | `NetAid -Log D:\logs` |
| `-Output <格式>` | 报告格式：Console/JSON/HTML/All | `NetAid -Output JSON` |
| `-Silent` | 静默模式（仅JSON输出到StdOut） | `NetAid -Check -Silent` |
| `-NoColor` | 禁用彩色输出 | `NetAid -Check -NoColor` |
| `-Help` | 显示帮助 | `NetAid -Help` |
| `-Version` | 显示版本 | `NetAid -Version` |
| `-ListModules` | 列出所有模块 | `NetAid -ListModules` |
| `-Report` | 生成最近一次诊断报告 | `NetAid -Report` |

### 模块名（用于 -Fix 和 -Module）

`adapter` | `dhcp` | `dns` | `route` | `firewall` | `proxy` | `thirdparty` | `winsock` | `hosts` | `ipconflict` | `deepclean` | `all`

## 使用场景

### 场景1：快速排查网络问题

```powershell
.\NetAid.ps1 -Check
```

运行全部11项诊断，生成报告，不修改任何设置。

### 场景2：自动修复

```powershell
.\NetAid.ps1 -Auto
```

诊断+自动修复所有可修复问题（L1+L2自动执行，L3+L4会提示确认）。

### 场景3：修复特定问题

```powershell
# DNS 无法解析
.\NetAid.ps1 -Fix dns

# 卸载安全软件后网络异常
.\NetAid.ps1 -Fix thirdparty

# hosts 文件被篡改
.\NetAid.ps1 -Fix hosts
```

### 场景4：远程桌面/SSH 操作

工具自动检测远程会话，跳过危险的网络断开操作（如 `ipconfig /release`）。

### 场景5：企业受控环境

若 PowerShell 处于 ConstrainedLanguage 模式，工具会提供手动诊断路径。

## 退出码

| 退出码 | 含义 |
| ------ | ---- |
| 0 | 成功：诊断全部通过 或 修复全部成功 |
| 1 | 诊断发现问题（仅 -Check 模式） |
| 2 | 修复部分失败 |
| 3 | 修复全部失败 |
| 4 | 权限不足（修复需管理员） |
| 5 | 用户中断 |
| 6 | 参数错误 |
| 99 | 未知错误 |

## 安全特性

- **不可逆操作强制备份**：修改注册表/重置防火墙/修改hosts前自动备份到 `backups/` 目录
- **远程会话保护**：RDP/SSH/WinRM 场景下自动跳过 `ipconfig /release` 等危险操作
- **数字签名校验**：删除驱动前二次检查文件签名，Microsoft签名驱动跳过不删
- **L3/L4 强制确认**：高风险操作前明确展示受影响范围并要求用户确认
- **系统还原点提醒**：L3/L4 修复前提示创建系统还原点

## 备份与恢复

所有修复前备份存放在 `backups/` 目录：

- 防火墙规则备份：`firewall_backup_*.wfw`、`firewall_rules_*.txt`
- 注册表导出：`reg_*.reg`
- hosts 文件备份：`hosts_*.bak`
- 网络配置快照：`netsh_dump_*.txt`

恢复命令会在修复时同时显示。

## 目录结构

```text
NetAid/
├── NetAid.bat              # 启动器（ASCII）
├── NetAid.ps1              # 主脚本（UTF-8 BOM）
├── modules/                # 11个诊断修复模块
│   ├── M01_Adapter.ps1
│   ├── M02_IP_DHCP.ps1
│   ├── M03_DNS.ps1
│   ├── M04_Route.ps1
│   ├── M05_Firewall.ps1
│   ├── M06_Proxy.ps1
│   ├── M07_ThirdParty.ps1
│   ├── M08_Winsock.ps1
│   ├── M09_Hosts.ps1
│   ├── M10_IPConflict.ps1
│   ├── M11_DeepClean.ps1
│   └── M11_DESIGN.md
├── lib/                    # 公共库
│   ├── Utils.ps1
│   ├── Logger.ps1
│   ├── UI.ps1
│   └── Parallel.ps1
├── logs/                   # 日志输出（运行时自动创建）
├── backups/                # 修复前备份（运行时自动创建）
└── README.md
```

## 卸载

工具不写注册表、不安装服务。删除整个 `NetAid/` 目录即完成卸载。旧日志可通过手动清理 `%TEMP%\NetAid\` 删除。

## 常见问题

**Q: 为什么诊断很快但修复很慢？**
A: 诊断以只读操作为主，修复涉及注册表修改、服务重启、网络重置等写操作，某些操作（如 DISM）可能需要较长时间。

**Q: 远程桌面运行会断网吗？**
A: 工具会自动检测远程会话，跳过 `ipconfig /release` 等可能断开当前连接的修复操作。

**Q: 修复会影响我的 VPN 吗？**
A: L3 级别的网络重置会清除 VPN 相关的网络组件，执行前会列出受影响的 LSP 条目供您评估。

**Q: 在域环境中能用吗？**
A: 可以。ConstrainedLanguage 模式下诊断功能仍可运行。如需修复，请联系域管理员。

## 许可与免责

本工具仅供网络故障诊断与修复参考使用。执行高风险修复（L3/L4）前请务必备份重要数据并创建系统还原点。作者不对使用本工具造成的任何损失承担责任。

---

**v1.0.0** | *2026-07-21*
