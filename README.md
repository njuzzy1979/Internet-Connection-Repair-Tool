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

## 典型故障案例分析：360 安全卫士卸载后全网断网

### 故障现象

用户卸载 360 安全卫士后重启，所有网卡（有线+无线）均无法获取 IP 地址，表现为 `ipconfig` 显示 **APIPA 地址 (169.254.x.x)**，无法访问互联网和局域网。

> 此案例同样适用于**火绒、腾讯电脑管家、金山毒霸**等同类安全软件的卸载后断网问题。

### 根因分析：360 对网络协议栈的深度侵入

360 安全卫士通过以下三层机制深度嵌入 Windows 网络协议栈：

#### 第一层：NDIS 内核过滤驱动（最关键）

360 安装了大量内核级 NDIS（Network Driver Interface Specification）过滤驱动，直接注册在 Windows 网络驱动绑定链中。已知的 360 网络相关驱动包括：

| 驱动文件名 | 功能 | 影响的网络层 |
|-----------|------|------------|
| `360netmon.sys` | 网络流量监控 | NDIS 过滤层 |
| `360AntiHacker64.sys` | 防黑客攻击 | NDIS 过滤层 |
| `360AntiAttack64.sys` | 防网络攻击 | NDIS 过滤层 |
| `360AntiFraud64.sys` | 反欺诈检测 | NDIS 过滤层 |
| `360Box64.sys` | 核心驱动框架 | 驱动总线层 |
| `BAPIDRV64.sys` | BAPI 辅助驱动 | NDIS 过滤层 |
| `360FsFlt.sys` | 文件系统过滤 | 文件系统层 |

这些驱动的注册表项位于 `HKLM\SYSTEM\CurrentControlSet\Services\`，其 **FilterClass** 属性使其被 Windows 视为合法的 NDIS 轻量过滤驱动 (LWF)，在网卡初始化时强制参与绑定链。

#### 第二层：WFP（Windows 过滤平台）Callout 驱动

360 向 WFP 引擎注册了多个 Provider（如 `360 Internet Security`、`360Safe`、`360 Total Security`），在应用层 (ALE) 和传输层插入过滤规则，可拦截/检查所有 TCP/UDP 数据包。

#### 第三层：Winsock LSP（分层服务提供者）

360 可能向 Winsock 目录注入 LSP 条目，在 Socket API 层面拦截网络通信。

### 卸载后为什么断网：孤儿驱动锁死绑定链

**关键问题在于 360 的卸载程序存在缺陷**：

1. **驱动文件被删除**：`C:\Windows\System32\drivers\360netmon.sys` 等 `.sys` 文件被卸载程序删除
2. **注册表残留**：但 `HKLM\SYSTEM\CurrentControlSet\Services\360netmon` 等注册表键**未被清理**
3. **FilterClass 仍然指向已删除文件**：注册表中的 `ImagePath` 指向不存在的驱动文件，但 `FilterClass` 属性仍让 Windows 将其视为合法 NDIS 过滤驱动

**断网机制**：

```
网卡初始化
  └→ NDIS 绑定引擎遍历 FilterClass 服务列表
       └→ 读取 360netmon → ImagePath → 文件不存在！
            └→ 绑定链在此处断裂
                 └→ DHCP 请求无法通过 NDIS 栈发出
                      └→ DHCP 超时 → APIPA 169.254.x.x
                           └→ 全网卡断网（有线/无线均受影响）
```

NDIS 过滤驱动是**全局性**的——一个错误的 FilterClass 条目可以**影响所有网络适配器**，这正是卸载 360 后"所有网卡一起断"的根本原因。

### NetAid 的检测-修复全链路

#### 检测阶段

NetAid 的 3 个模块从不同层面捕捉 360 残留：

| 模块 | 检测项 | 发现 360 残留的典型输出 |
|------|--------|----------------------|
| **M07** 第三方残留 | 扫描 `HKLM\...\Services` 中 140+ 黑名单驱动 | `360netmon` 注册表存在、文件不存在 → 幽灵残留 |
| **M02** IP/DHCP | 检查是否为 APIPA 地址 | 169.254.x.x → `APIPA_DETECTED` |
| **M11** 深度残留 | 扫描 NDIS FilterClass 注册表项 | 孤儿 FilterClass 条目 → DHCP 依赖链损坏 |

#### 修复阶段（按执行顺序）

修复引擎 `Build-RepairPlan` 自动编排多模块协同修复，并支持合并去重：

```
┌─────────────────────────────────────────────────────┐
│ 步骤1: M11 深度清理 (L4a)                             │
│   ├─ 备份注册表 Service 键到 backups/                 │
│   ├─ 删除孤儿 NDIS 驱动注册表键 (360netmon 等)        │
│   ├─ 禁用但仍存文件的可疑驱动 (Start=4)                │
│   ├─ 重命名残留 .sys 文件为 .sys.netaid_bak           │
│   └─ 修复 DHCP 依赖链 (AFD Start=1, Dhcp Start=2)     │
├─────────────────────────────────────────────────────┤
│ 步骤2: M07 第三方残留清理 (L4a)                        │
│   ├─ 活跃残留驱动 → Set Start=4 禁用                  │
│   ├─ 幽灵残留驱动 → 删除注册表 Service 键             │
│   └─ LSP/WFP 异常 → 记录，交由后续模块覆盖            │
├─────────────────────────────────────────────────────┤
│ 步骤3: M08 Winsock/协议栈重置 (L3)                     │
│   ├─ netsh winsock reset  → 重建 Winsock 目录        │
│   ├─ netsh int ip reset   → 重置 TCP/IP 协议栈       │
│   ├─ netsh int tcp reset  → 重置 TCP 全局参数        │
│   └─ netsh winhttp reset proxy → 清除代理设置        │
├─────────────────────────────────────────────────────┤
│ 步骤4: M02 DHCP 续租 (L2)                              │
│   ├─ ipconfig /release → 释放当前 APIPA              │
│   └─ ipconfig /renew  → 向 DHCP 服务器请求新 IP      │
├─────────────────────────────────────────────────────┤
│ 步骤5: 重启生效                                        │
│   NDIS 绑定链在重启时重建，不再包含已清理的 360 驱动     │
│   → 网卡正常获取 DHCP IP，网络恢复                     │
└─────────────────────────────────────────────────────┘
```

#### 修复计划的智能合并去重

NetAid 的修复引擎理解修复操作之间的覆盖关系：

- M08（Winsock 重置）**覆盖** M07 的 LSP 清理 → M07 可能被跳过
- M05（防火墙重置）**覆盖** M07 的 WFP 过滤器清理 → M07 可能被跳过
- 仅当 LSP **且** WFP 都被其他模块覆盖时，M07 才完全不执行

这避免了重复的 `netsh` 操作和多次重启需求。

### 同类安全软件对比

360 并非唯一有此问题的安全软件。NetAid 的黑名单覆盖了：

| 安全软件 | 典型残留驱动 | 网络影响机制 |
|---------|-------------|------------|
| **火绒** | `hrwfpdrv.sys`（WFP 过滤）、`sysdiag.sys` | 同 360，NDIS + WFP 双重拦截 |
| **腾讯管家** | `TSNetMon.sys`、`TNetMon64.sys` | NDIS 流量监控驱动残留 |
| **金山毒霸** | `kisknl.sys`、`kmodurl.sys` | 内核+URL 过滤驱动残留 |
| **Kaspersky** | `klim6.sys`（NDIS 6.x）、`klwfp.sys`（WFP） | NDIS + WFP 双重拦截 |
| **ESET** | `epfwwfp.sys`（WFP 防火墙）、`eamonm.sys` | WFP 过滤残留 |

### 总结

**360 卸载后断网的本质是：安全软件的"深度网络防护"机制在内核层面劫持了网络数据包路径，卸载时未能正确还原。残留的注册表项让 Windows 继续尝试加载不存在的驱动，导致 NDIS 绑定链断裂 → DHCP 失败 → APIPA → 全网断网。**

修复的关键不是简单的 `ipconfig /renew` 或 DNS 刷新，而是**从注册表中清除孤儿 NDIS 过滤驱动引用，然后重置整个 Winsock/TCP-IP 协议栈，使 Windows 在重启后重建干净的网络绑定链**。这正是 NetAid 多模块协同修复的核心价值。

---

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
