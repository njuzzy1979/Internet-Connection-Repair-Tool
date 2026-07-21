# 断网急救箱 (NetAid)

> Windows 网络诊断与修复工具 | PowerShell 5.1 零依赖 | Win10 1809+ / Win11 全版本

断网急救箱是一款纯 PowerShell 5.1 零依赖网络诊断与修复工具，覆盖 11 类常见网络故障，支持一键诊断与分级自动修复。

## 快速开始

右键 `NetAid/NetAid.bat` → **"以管理员身份运行"**，或：

```powershell
cd NetAid

# 仅诊断（无需管理员）
.\NetAid.ps1 -Check

# 诊断并自动修复（需管理员）
.\NetAid.ps1 -Auto

# 修复指定模块
.\NetAid.ps1 -Fix dns
```

诊断不需要管理员，修复必须管理员运行。

## 功能模块

| 编号 | 模块 | 检测内容 |
|------|------|----------|
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
| M11 | 深度残留 | NDIS过滤驱动残留检测、孤儿驱动清理 (v1.0.0 新增) |

### 修复分级

| 级别 | 风险 | 自动/确认 | 典型操作 |
|------|------|-----------|----------|
| L1 | 极低 | 自动 | flushdns、hosts修复、代理重置 |
| L2 | 低 | 自动 | DHCP续租、DNS重置、路由修复 |
| L3 | 中 | 需确认 | Winsock重置、TCP/IP重置、防火墙重置 |
| L4a | 中-高 | 需二次确认 | 禁用第三方驱动、重启网卡 |
| L4b | 极高 | 需二次确认 | netcfg -d + DISM系统修复 |

## 命令行参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `-Auto` | 全自动诊断+修复+退出 | `NetAid -Auto` |
| `-Check` | 仅诊断（不修复） | `NetAid -Check` |
| `-Fix <模块>` | 修复指定模块 | `NetAid -Fix dns` |
| `-FixAll` | 修复所有 | `NetAid -FixAll` |
| `-Module <模块>` | 仅诊断指定模块 | `NetAid -Module adapter` |
| `-Log <路径>` | 指定日志路径 | `NetAid -Log D:\logs` |
| `-Output <格式>` | 报告格式：Console/JSON/HTML/All | `NetAid -Output JSON` |
| `-Silent` | 静默模式 | `NetAid -Check -Silent` |
| `-NoColor` | 禁用彩色输出 | `NetAid -Check -NoColor` |
| `-Help` | 显示帮助 | `NetAid -Help` |

## 系统要求

- **操作系统**: Windows 10 1809+ 或 Windows 11 全版本
- **PowerShell**: Windows PowerShell 5.1（系统自带）
- **权限**: 诊断可非管理员运行，修复需管理员权限
- **依赖**: 零第三方依赖，无需联网

## 项目结构

```
├── NetAid/                   # 主程序
│   ├── NetAid.bat            # 启动器（双击提权）
│   ├── NetAid.ps1            # 主脚本（入口 + 状态机 + 修复引擎）
│   ├── modules/              # 11 个诊断修复模块
│   │   ├── M01_Adapter.ps1
│   │   ├── M02_IP_DHCP.ps1
│   │   ├── M03_DNS.ps1
│   │   ├── M04_Route.ps1
│   │   ├── M05_Firewall.ps1
│   │   ├── M06_Proxy.ps1
│   │   ├── M07_ThirdParty.ps1
│   │   ├── M08_Winsock.ps1
│   │   ├── M09_Hosts.ps1
│   │   ├── M10_IPConflict.ps1
│   │   └── M11_DeepClean.ps1
│   ├── lib/                  # 公共库
│   │   ├── Utils.ps1         # 工具函数 + 安全软件驱动黑名单(140+条)
│   │   ├── Logger.ps1        # JSONL 日志系统
│   │   ├── UI.ps1            # 控制台 UI 组件
│   │   └── Parallel.ps1      # Start-Job 并行编排引擎
│   └── README.md
├── backups/                  # 修复前自动备份（注册表、防火墙规则、hosts）
├── 断网急救箱_最终设计文档.md
├── 断网急救箱_统一设计方案.md
├── 断网急救箱_执行流程与状态机设计.md
├── NetAid_CLI_Design.md
└── README.md
```

## 安全特性

- **不可逆操作强制备份**：修改注册表/重置防火墙/修改hosts前自动备份到 `backups/` 目录
- **远程会话保护**：RDP/SSH/WinRM 场景下自动跳过 `ipconfig /release` 等危险操作
- **数字签名校验**：删除驱动前二次检查文件签名，Microsoft 签名驱动跳过不删
- **L3/L4 强制确认**：高风险操作前明确展示受影响范围并要求用户确认
- **系统还原点提醒**：L3/L4 修复前提示创建系统还原点

## 卸载

工具不写注册表、不安装服务。删除整个项目目录即完成卸载。旧日志可通过 `NetAid -CleanLogs` 清理。

## 许可与免责

本工具仅供网络故障诊断与修复参考使用。执行高风险修复（L3/L4）前请务必备份重要数据并创建系统还原点。作者不对使用本工具造成的任何损失承担责任。

---

*v1.0.0 | 2026-07-21*
