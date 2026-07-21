# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

NetAid（断网急救箱）是一个纯 PowerShell 5.1 零依赖的 Windows 网络诊断与修复工具，覆盖 10+ 类网络故障的一键诊断与分级自动修复。

## 关键文件编码规则

| 文件类型 | 内容编码 | BOM | 备注 |
|----------|----------|-----|------|
| `.ps1` | UTF-8 | **必须带 BOM** | PowerShell 5.1 按 ANSI 读无 BOM 的 .ps1，中文乱码 |
| `.bat`（纯 ASCII） | ASCII | 无 | 中文输出交给 .ps1，不要在 .bat 里写中文 |
| `.bat`（含中文） | GBK | 无 | 不要加 `chcp 65001`，否则 GBK 字节被按 UTF-8 重新解析 |
| `.md` / `.json` | UTF-8 | 通常不加 | 任意 |

写入 BOM 的可靠代码：
```powershell
$content = Get-Content -Path $path -Raw -Encoding UTF8
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($path, $content, $utf8Bom)
```

`.ps1` 脚本开头必须加：
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
```

## 运行命令

```powershell
# 交互式菜单（无参数，双击或直接运行）
.\NetAid\NetAid.ps1

# 仅诊断（无需管理员，全部模块）
.\NetAid\NetAid.ps1 -Check

# 诊断指定模块
.\NetAid\NetAid.ps1 -Check -Module dns

# 全自动诊断+修复
.\NetAid\NetAid.ps1 -Auto

# 修复指定模块
.\NetAid\NetAid.ps1 -Fix dns

# 修复多个模块
.\NetAid\NetAid.ps1 -Fix dns,hosts,proxy

# 修复所有
.\NetAid\NetAid.ps1 -FixAll

# 静默模式 + JSON 输出
.\NetAid\NetAid.ps1 -Check -Silent -Output JSON

# 清理旧日志
.\NetAid\NetAid.ps1 -CleanLogs
```

诊断不需要管理员，修复必须管理员运行。`NetAid.bat` 双击时会通过 VBS 自动弹出 UAC 提权对话框。

## 架构概览

### 加载链

```
NetAid.bat (启动器，ASCII)
  └─ 提权后调用 powershell.exe -File NetAid.ps1
       ├─ dot-source lib/Utils.ps1   → 基础工具函数 + 黑名单数据
       ├─ dot-source lib/Logger.ps1  → JSONL 日志系统
       ├─ dot-source lib/UI.ps1      → 控制台 UI（菜单/进度/报告）
       ├─ dot-source lib/Parallel.ps1 → Start-Job 并行编排引擎
       └─ dot-source modules/M01~M11_*.ps1 → 诊断/修复模块
```

所有文件通过 dot-source (`. path.ps1`) 加载到同一个作用域，函数和 `$Script:` 作用域变量全局可见。不存在模块导入/导出机制。

### 诊断流水线（5 个 Phase）

模块间存在数据依赖，诊断按 Phase 顺序执行：

- **Phase 0**（5 个并行）: M01 适配器、M05 防火墙、M06 代理、M07 第三方残留、M09 hosts → 无相互依赖
- **Phase 1**（串行）: M02 IP/DHCP → 需要 M01 的 Adapters 数据
- **Phase 2**（3 个并行）: M03 DNS、M04 路由、M10 IP冲突 → 需要 M02 的 IP/DNS/Gateway 数据
- **Phase 3**（串行）: M08 Winsock/协议栈 → `netsh winsock` 命令互斥，必须单独执行
- **Phase 4**（串行）: M11 深度残留检测 → 注册表扫描密集

诊断结果缓存到 `$Script:DiagCache`（全局哈希表），模块间通过 `Context` 参数传递上游数据（由 `Build-Context` 函数构建）。

当前代码中 Phase 0-4 实际上在 `Invoke-FullDiagnosis` 中是串行调用的（注释说并行但未实际使用 `Parallel.ps1` 引擎），但架构上保留了通过 `Get-PhaseSchedule` 切换到 `Start-Job` 并行执行的能力。

### 修复引擎（4 级）

修复计划由 `Build-RepairPlan` 根据诊断结果自动生成，按风险分级：

| 级别 | 风险 | 确认 | 示例操作 |
|------|------|------|----------|
| L1 | 极低 | 自动 | flushdns, hosts 修复, 代理重置 |
| L2 | 低 | 自动 | DHCP 续租, DNS 重置, 路由修复 |
| L3 | 中 | 需确认 | Winsock 重置, TCP/IP 重置, 防火墙重置 |
| L4a | 中-高 | 需二次确认 | 禁用第三方驱动, 重启网卡 |
| L4b | 极高 | 需二次确认 | netcfg -d, DISM 修复 |

修复支持**合并去重**：Winsock 重置可同时覆盖 LSP 清理（M07），防火墙重置可覆盖 WFP 过滤器（M07），避免重复操作。

### 模块规范（M01~M11）

每个模块文件必须导出两个公共函数：

- `Invoke-MXX_Diagnose -Context <hashtable>` → 返回 `@{ Diagnosis = @{...}; LogEvents = @(...) }`
- `Invoke-MXX_Repair -Diagnosis <hashtable>` → 返回 `@{ Repair = @{...}; LogEvents = @(...) }`

`Diagnosis` 哈希表必须包含 `Verdict` 键，值为 `PASS` / `WARN` / `FAIL` / `TIMEOUT`。`Repair` 哈希表必须包含 `Verdict` 键，值为 `success` / `failed` / `skipped`，可选 `RebootRequired = $true`。

模块通过 dot-source 加载后函数直接可用，`Get-DiagnosisFunctionName` / `Get-RepairFunctionName` 通过 `$Script:ModuleMap`（定义在 `Utils.ps1`）将短名映射到函数名。

### 库文件分工

- **Utils.ps1**: 管理员检测、OS 版本获取、注册表备份、数字签名验证、网络适配器 WMI 回退、网络环境快照、安全软件残留驱动黑名单（140+ 条目，覆盖 360/火绒/腾讯管家/金山毒霸/Kaspersky/Bitdefender/ESET/McAfee/Symantec 等）、可疑 WFP Provider 名单
- **Logger.ps1**: JSON Lines (.jsonl) 日志系统，互斥锁线程安全，`Write-JsonlLog` 是唯一写入入口，支持会话索引 (`sessions.jsonl`) 和旧日志清理
- **UI.ps1**: 双线框控制台 UI（使用 Unicode 制表符 `╔═╗║╚═╝`），包括横幅、菜单、进度条、诊断/修复汇总、最终报告，支持 `-NoColor` 降级
- **Parallel.ps1**: `Start-Job` + `Wait-Job` + `Receive-Job` 并行编排引擎，含超时控制、`ConstrainedLanguage` 降级串行回退、日志事件统一收集

### 日志系统

日志以 JSONL 格式写入 `logs/NetAid_yyyyMMdd_HHmmss.jsonl`（UTF-8 无 BOM）。事件类型：`session.start`, `check.end`, `fix.step`, `fix.end`, `diagnosis.summary`, `fix.summary`, `error`, `env.snapshot`, `session.end`。

子 Job 不能直接写日志文件——日志事件通过 `Receive-Job` 收集后由主线程调用 `Write-JsonlLog` 统一写入。

### 四种运行模式

`NetAid.ps1` 通过参数组合路由到不同模式：

1. **无参数** → `Invoke-InteractiveMode`：Clear-Host 循环主菜单（7 选项）
2. **`-Check`** → `Invoke-CheckMode`：诊断 + 输出 + 退出
3. **`-Auto`** → `Invoke-AutoMode`：诊断→修复计划→自动修复→验证→退出
4. **`-Fix` / `-FixAll`** → `Invoke-FixMode`：先诊断指定模块→修复计划→交互确认→执行

### 安全特性

- 远程会话保护（SSH/RDP/WinRM）：跳过 `ipconfig /release` 等危险操作
- 不可逆操作前强制备份到 `backups/` 目录（注册表 .reg、防火墙 .wfw、hosts .bak）
- L3/L4 修复前提示创建系统还原点
- 数字签名校验：Microsoft 签名驱动跳过不删
- ConstrainedLanguage 模式可运行诊断（部分限制），修复需 FullLanguage

## 设计文档

项目根目录有 3 份设计文档（中文）：
- `断网急救箱_最终设计文档.md` — 完整设计规格
- `断网急救箱_统一设计方案.md` — 统一方案设计
- `断网急救箱_执行流程与状态机设计.md` — 执行流程与状态机
- `NetAid_CLI_Design.md` — CLI 设计

修改核心逻辑前应先查阅相关设计文档。

## 典型故障机制分析：安全软件（360/火绒/管家等）卸载后断网

### 问题本质

安全软件通过 **NDIS 内核过滤驱动 + WFP Callout + Winsock LSP** 三层机制嵌入 Windows 网络协议栈。卸载程序常**无法彻底清理**注册表残留，导致 NDIS 绑定链断裂。

### 根因链路（以 360 为例）

```
360 卸载 → .sys 文件被删除，但注册表 Service 键残留
  → HKLM\...\Services\360netmon 仍注册为 FilterClass（NDIS LWF）
    → 网卡初始化时 NDIS 尝试加载 360netmon → 文件不存在
      → 绑定链断裂 → DHCP 报文无法通过 NDIS 栈
        → DHCP 超时 → APIPA (169.254.x.x) → 全网卡断网
```

关键特征：**所有网卡同时断网**（有线+无线），因为 NDIS 过滤驱动是全局的。

### NetAid 检测链路（3 模块协作）

| 模块 | 检测机制 | 发现的典型问题 |
|------|----------|---------------|
| M07 第三方残留 | 遍历 `HKLM\...\Services`，匹配 140+ 黑名单驱动 | 360 驱动注册表残留（文件已删除/仍存在） |
| M02 IP/DHCP | `Get-NetIPAddress` 扫描 Up 适配器 | APIPA (169.254.x.x) 地址 |
| M11 深度残留 | 扫描 `FilterClass` 注册表项 + DHCP 依赖链 | 孤儿 NDIS 过滤驱动、AFD/Dhcp 配置异常 |

### 修复链路（4 模块协同，含合并去重）

```
M11 (L4a) → 删除孤儿 NDIS 过滤驱动注册表、禁用活跃残留、处理 .sys 文件
M07 (L4a) → 禁用残留驱动(Start=4)、删除幽灵注册表、记录 LSP/WFP 异常
M08 (L3)  → netsh winsock/int ip/int tcp/winhttp reset（覆盖 M07 LSP 清理）
M02 (L2)  → ipconfig /release → /renew、DHCP 服务启动、MTU 修复
→ 重启 → NDIS 绑定链重建，网络恢复
```

**合并去重规则**：
- M08（Winsock 重置）覆盖 M07 的 LSP 清理
- M05（防火墙重置）覆盖 M07 的 WFP 过滤器清理
- 仅当 LSP **且** WFP 都被覆盖时 M07 才完全跳过

### 开发注意事项

- 新增安全软件驱动黑名单时，同步更新 `Utils.ps1` 的 `$Script:KnownResidueDrivers`、`$Script:SuspiciousWfpProviders`，以及 `M11_DeepClean.ps1` 的 `$Script:KnownNdisFilterServices`、`$Script:ResidueSysPatterns`
- M11 的孤儿 FilterClass 检测是**断网根因定位的核心**——`FilterClass` 非空 + `ImagePath` 文件不存在 + `Start ≠ 4` = 孤儿（最危险）
- 修复后**必须重启**才能让 NDIS 绑定链重建，仅 `ipconfig /renew` 无效
- 安全保护：修复前强制备份注册表到 `backups/`，数字签名为 Microsoft 的驱动**绝不能操作**
- 参见 README.md "典型故障案例分析"章节获取面向用户的完整说明
