# 断网急救箱 — CLI 交互设计文档

> Windows 网络诊断与修复工具 | PowerShell 5.1 零依赖 | Win10/11 全版本兼容

---

## 1. 主菜单 ASCII 界面

### 1.1 配色方案

```
┌──────────────────────────────────────────────────────────────┐
│ 终端配色定义 (Write-Host -ForegroundColor)                      │
├──────────┬──────────┬─────────────────────────────────────────┤
│ 颜色      │ 代码      │ 用途                                     │
├──────────┼──────────┼─────────────────────────────────────────┤
│ Green    │ 正常/通过 │ 诊断通过、修复成功、网络正常                  │
│ Yellow   │ 警告/需注意│ 诊断警告、可忽略异常、非关键问题              │
│ Red      │ 异常/失败 │ 诊断失败、修复失败、需要手动干预              │
│ Cyan     │ 信息/提示 │ 标题、分隔线、模块名、操作说明                │
│ White    │ 普通文本  │ 描述文字、数值展示                          │
│ Gray     │ 次要信息  │ 时间戳、分隔符、示例路径                     │
│ Magenta  │ 高亮/强调 │ 关键警告、IP地址高亮、管理员提示              │
└──────────┴──────────┴─────────────────────────────────────────┘
```

### 1.2 主菜单界面

```
╔══════════════════════════════════════════════════════════════╗
║                   断 网 急 救 箱  v1.0                        ║
║                  Windows Network First Aid                   ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  [1] 全面诊断    — 扫描全部 10 类网络故障 (最快 < 5s)          ║
║  [2] 自动修复    — 诊断 + 自动修复所有可修复问题                ║
║  [3] 单项诊断    — 针对某一模块进行诊断                         ║
║  [4] 单项修复    — 针对某一模块进行修复                         ║
║  [5] 生成报告    — 导出诊断/修复日志                           ║
║  [6] 查看历史    — 浏览历史诊断记录                            ║
║  [7] 帮助说明    — 命令行参数与使用说明                         ║
║  [0] 退出        — 安全退出程序                               ║
║                                                              ║
║  快捷命令行: NetAid -auto | -check | -fix <模块> | -help      ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

  当前权限: [管理员]   系统版本: Windows 11 Home China 10.0.26200
  网络状态: [已连接]   适配器: Ethernet0 (192.168.1.100)

  请输入选项 [1-7, 0]:
```

### 1.3 诊断进度界面

```
╔══════════════════════════════════════════════════════════════╗
║              全 面 诊 断 进 行 中 ...                         ║
╚══════════════════════════════════════════════════════════════╝

  [01/10] DHCP 配置检测 ............................ 正常
  [02/10] 第三方安全软件残留 ........................ 警告 — 检测到 360 残留驱动
  [03/10] VPN/代理残留 .............................. 正常
  [04/10] DNS 解析测试 .............................. 失败 — 无法解析 www.baidu.com
  [05/10] Winsock/TCP-IP 协议栈 ...................... 正常
  [06/10] 网卡驱动状态 .............................. 正常
  [07/10] 防火墙规则 ................................ 异常 — 检测到非默认阻止规则
  [08/10] 路由表检查 ................................ 正常
  [09/10] IP 冲突检测 ................................ 正常
  [10/10] hosts 文件劫持 ............................. 正常

  ─────────────────────────────────────────────────────────────
  诊断耗时: 3.2s     发现问题: 3 项    严重: 1 项    警告: 2 项
  ─────────────────────────────────────────────────────────────
```

### 1.4 修复确认界面

```
╔══════════════════════════════════════════════════════════════╗
║                诊 断 完 成 — 发现 3 项问题                      ║
╚══════════════════════════════════════════════════════════════╝

  [!!] 严重 — DNS 解析失败 (无法解析 www.baidu.com)
       建议修复: 刷新 DNS 缓存 + 重置 DNS 客户端服务

  [!]  警告 — 360 安全卫士残留驱动 (360FsFlt.sys)
       建议修复: 尝试清理残留驱动项 (需重启)

  [!]  警告 — 防火墙存在非默认入站阻止规则
       建议修复: 重置 Windows 防火墙为默认配置

  ─────────────────────────────────────────────────────────────
  可自动修复: 3 项    需手动处理: 0 项    需重启后生效: 1 项
  ─────────────────────────────────────────────────────────────

  是否执行自动修复? [Y/n]:
  详细模式查看每项修复详情? [y/N]:
```

### 1.5 修复进度界面

```
╔══════════════════════════════════════════════════════════════╗
║                执 行 修 复 中 ...                             ║
╚══════════════════════════════════════════════════════════════╝

  [1/3] 刷新 DNS 缓存 + 重置 DNS 客户端 ............. 成功
  [2/3] 清理 360 残留驱动 .......................... 成功 (需重启生效)
  [3/3] 重置 Windows 防火墙 ........................ 成功

  ─────────────────────────────────────────────────────────────
  修复完成: 3/3 成功    失败: 0    需重启: 1
  ─────────────────────────────────────────────────────────────

  正在执行修复后验证...

  [验证] DNS 解析测试 ............................... 正常

  全部修复已生效。建议立即重启计算机以完成驱动清理。

  是否现在重启? [Y/n]:
```

---

## 2. 命令行参数完整设计

### 2.1 参数概览

```
NetAid.exe / NetAid.bat / NetAid.ps1
───────────────────────────────────────────────────────────────

用法:
  NetAid [参数]

参数:
  -Auto             全自动模式：诊断 + 自动修复 + 生成报告 + 退出
  -Check            仅诊断模式：运行全部诊断并输出报告 (不修复)
  -Fix <模块名>      修复指定模块 (需管理员权限)
  -FixAll           修复所有检测到的问题
  -Log <路径>        指定日志输出路径 (默认: %TEMP%\NetAid\)
  -Report            仅生成最近一次诊断的可读报告，不执行诊断
  -Output <格式>     报告输出格式: Console | JSON | HTML | All (默认: Console)
  -Module <模块名>   仅诊断指定模块
  -Silent            静默模式 (仅输出 JSON 到 StdOut，控制台无彩色)
  -NoColor           禁用彩色输出
  -Help              显示帮助信息
  -Version           显示版本信息
  -ListModules       列出所有可用诊断/修复模块

模块名 (用于 -Fix 和 -Module):
  dhcp               DHCP 配置检测与修复
  security           第三方安全软件残留检测与清理
  proxy              VPN/代理残留检测与清理
  dns                DNS 解析检测与修复
  winsock            Winsock/TCP-IP 协议栈检测与修复
  nic                网卡驱动状态检测与修复
  firewall           防火墙规则检测与修复
  route              路由表检测与修复
  ipconflict         IP 冲突检测
  hosts              hosts 文件劫持检测与修复
  all                全部模块 (默认)
```

### 2.2 参数行为矩阵

```
┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│ 参数组合   │ 诊断      │ 修复      │ 报告      │ 交互      │ 退出码    │
├──────────┼──────────┼──────────┼──────────┼──────────┼──────────┤
│ (无参数)   │ —        │ —        │ —        │ 主菜单     │ 0        │
│ -Auto     │ 全部      │ 可修复项   │ JSON+文本 │ 仅确认     │ 0/1      │
│ -Check    │ 全部      │ —        │ 文本+JSON │ 无        │ 0/1      │
│ -Fix dns  │ dns      │ dns      │ 无        │ 确认      │ 0/1      │
│ -FixAll   │ 全部      │ 全部可修复 │ 文本+JSON │ 确认      │ 0/1      │
│ -Help     │ —        │ —        │ —        │ 无        │ 0        │
│ -Version  │ —        │ —        │ —        │ 无        │ 0        │
│ -Silent   │ 按其他参数│ 按其他参数 │ JSON StdOut│ 无       │ 0/1      │
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
```

### 2.3 退出码定义

```
┌────────┬──────────────────────────────────────────────────────┐
│ 退出码  │ 含义                                                  │
├────────┼──────────────────────────────────────────────────────┤
│ 0      │ 成功 (诊断全部通过 或 修复全部成功)                       │
│ 1      │ 诊断发现问题 (仅 -Check 模式，有问题但未修复)              │
│ 2      │ 修复部分失败 (部分项目修复失败)                           │
│ 3      │ 修复全部失败                                           │
│ 4      │ 权限不足 (需要管理员权限)                                │
│ 5      │ 参数错误                                               │
│ 6      │ 系统不支持 (非 Win10/11)                                │
│ 99     │ 未知错误                                               │
└────────┴──────────────────────────────────────────────────────┘
```

### 2.4 使用示例

```powershell
# 交互式主菜单
.\NetAid.ps1

# 快速全自动修复 (适合远程/脚本调用)
.\NetAid.ps1 -Auto

# 仅诊断，不修复
.\NetAid.ps1 -Check

# 仅修复 DNS 问题
.\NetAid.ps1 -Fix dns

# 修复 DNS 和 hosts
.\NetAid.ps1 -Fix dns -Fix hosts

# 诊断并导出 JSON 日志到指定路径
.\NetAid.ps1 -Check -Log "D:\logs\" -Output JSON

# 静默模式 — 适合被其他脚本调用
.\NetAid.ps1 -Check -Silent | ConvertFrom-Json

# 列出所有模块
.\NetAid.ps1 -ListModules

# 查看最近一次报告
.\NetAid.ps1 -Report
```

---

## 3. 诊断报告输出格式

### 3.1 控制台实时输出样例

```
═══════════════════════════════════════════════════════════════
  断网急救箱 — 诊断报告
  时间: 2026-07-21 14:32:18
  主机: DESKTOP-XP3K9M2
  系统: Windows 11 Home China 10.0.26200
═══════════════════════════════════════════════════════════════

── 01 DHCP 配置检测 ───────────────────────────── [ 正常 ] 0.3s
  适配器: Ethernet0
  IPv4:   192.168.1.100 (DHCP)
  网关:   192.168.1.1
  DNS:    223.5.5.5, 8.8.8.8
  DHCP 服务器可达: 是
  租约剩余: 23h 45m

── 02 第三方安全软件残留 ──────────────────────── [ 警告 ] 0.6s
  注册表扫描: 发现 1 个已知残留驱动
    360FsFlt.sys — 360安全卫士 (服务: 已停止, 启动类型: 手动)
  Winsock LSP 目录: 完整 (23 条目)
  WFP 过滤器: 检测到 3 个第三方过滤器
    [360网络防护] FilterId=68423 Layer=ALE Connect v4
    [360网络防护] FilterId=68424 Layer=ALE Connect v6
    [360网络防护] FilterId=68425 Layer=ALE Receive/Accept v4
  TAP/Wintun 适配器: 未检测到
  建议: 使用 -Fix security 清理残留

── 03 VPN/代理残留 ───────────────────────────── [ 正常 ] 0.2s
  系统代理: 未配置
  WinHTTP 代理: 未配置
  IE 代理: 未配置
  VPN 拨号连接: 无活动连接
  TAP 驱动残留: 无

── 04 DNS 解析测试 ───────────────────────────── [ 失败 ] 1.1s
  主测试 (Resolve-DnsName):
    www.baidu.com ............ 超时 (2s)
    www.qq.com ............... 超时 (2s)
    www.microsoft.com ........ 超时 (2s)
  辅测试 (Ping -n 1):
    223.5.5.5 (阿里DNS) ...... 可达 (3ms)
    8.8.8.8 (谷歌DNS) ........ 超时
  诊断结论: DNS 解析服务异常，网络层连通性正常
  影响: 无法通过域名访问网站，直接 IP 访问正常

── 05 Winsock/TCP-IP 协议栈 ──────────────────── [ 正常 ] 0.4s
  Winsock 目录: 完整
  TCP-IP 注册表参数: 默认值
  IPv4 协议: 正常
  IPv6 协议: 正常

── 06 网卡驱动状态 ────────────────────────────── [ 正常 ] 0.5s
  适配器: Ethernet0 (Realtek PCIe GbE)
  状态: Up, 1 Gbps 全双工
  驱动版本: 10.68.307.2024
  已接收/已发送: 12.3 GB / 4.7 GB
  错误/丢弃: 0 / 0
  APIPA (169.254): 否

── 07 防火墙规则 ──────────────────────────────── [ 异常 ] 0.3s
  防火墙状态: 已启用
  配置文件: 域=关闭, 专用=启用, 公用=启用
  入站规则: 328 条 (含 3 条第三方阻止规则)
  异常规则:
    [阻止] "360StopAll" — 阻止所有入站 TCP (作用域: 任何)
    [阻止] "360StopAllUDP" — 阻止所有入站 UDP (作用域: 任何)
  出站规则: 156 条 (正常)

── 08 路由表检查 ──────────────────────────────── [ 正常 ] 0.2s
  默认网关: 192.168.1.1 (跃点数 25, Ethernet0)
  活跃路由: 12 条
  持久路由: 0 条
  路由表完整性: 通过

── 09 IP 冲突检测 ─────────────────────────────── [ 正常 ] 0.3s
  本机 IP: 192.168.1.100 (MAC: AA-BB-CC-DD-EE-FF)
  ARP 表检查: IP 对应 MAC 唯一，未检测到冲突
  Gratuitous ARP: 无响应

── 10 hosts 文件劫持 ──────────────────────────── [ 正常 ] 0.1s
  路径: C:\Windows\System32\drivers\etc\hosts
  大小: 824 bytes
  非注释条目: 0 条
  劫持检测: 无异常

═══════════════════════════════════════════════════════════════
                    最 终 摘 要 报 告
═══════════════════════════════════════════════════════════════

  诊断模块: 10/10 完成    耗时: 4.1s
  ─────────────────────────────────────
  正常: 7    警告: 2    失败: 1    严重: 1
  ─────────────────────────────────────

  严重问题 (需立即处理):
    1. DNS 解析失败 — Resolve-DnsName 全部超时

  警告问题 (建议处理):
    2. 360 残留驱动 — 360FsFlt.sys 仍注册在系统中
    3. 防火墙异常 — 存在第三方全阻断入站规则

  ─────────────────────────────────────
  可自动修复: 3/3    建议重启: 是
  ─────────────────────────────────────

  推荐操作:
    > NetAid -FixAll       # 自动修复所有问题
    > NetAid -Fix dns      # 仅修复 DNS
    > NetAid -Auto         # 诊断+修复一步完成

═══════════════════════════════════════════════════════════════
```

### 3.2 JSON Lines 日志格式 (`.jsonl`)

```jsonl
{"ts":"2026-07-21T14:32:18.342+08:00","level":"INFO","event":"session.start","host":"DESKTOP-XP3K9M2","os":"Win11_10.0.26200","version":"1.0.0","elevated":true}
{"ts":"2026-07-21T14:32:18.358+08:00","level":"INFO","event":"check.start","module":"dhcp","seq":1}
{"ts":"2026-07-21T14:32:18.671+08:00","level":"PASS","event":"check.end","module":"dhcp","seq":1,"elapsed_ms":313,"adapter":"Ethernet0","ipv4":"192.168.1.100","gateway":"192.168.1.1","dhcp_server":"192.168.1.1","apipa":false}
{"ts":"2026-07-21T14:32:18.703+08:00","level":"INFO","event":"check.start","module":"security","seq":2}
{"ts":"2026-07-21T14:32:19.345+08:00","level":"WARN","event":"check.end","module":"security","seq":2,"elapsed_ms":642,"verdict":"warning","findings":[{"type":"residual_driver","name":"360FsFlt.sys","vendor":"Qihu 360","service_status":"Stopped","start_type":"Manual"}],"wfp_third_party":3,"lsp_ok":true}
{"ts":"2026-07-21T14:32:19.367+08:00","level":"INFO","event":"check.start","module":"proxy","seq":3}
{"ts":"2026-07-21T14:32:19.553+08:00","level":"PASS","event":"check.end","module":"proxy","seq":3,"elapsed_ms":186,"system_proxy":null,"winhttp_proxy":null,"vpn_active":false,"tap_driver":false}
{"ts":"2026-07-21T14:32:19.563+08:00","level":"INFO","event":"check.start","module":"dns","seq":4}
{"ts":"2026-07-21T14:32:20.681+08:00","level":"FAIL","event":"check.end","module":"dns","seq":4,"elapsed_ms":1118,"verdict":"fail","resolvedns":{"www.baidu.com":"timeout","www.qq.com":"timeout","www.microsoft.com":"timeout"},"ping":{"223.5.5.5":{"latency_ms":3,"reachable":true},"8.8.8.8":{"latency_ms":null,"reachable":false}},"conclusion":"DNS_resolution_failed_network_reachable"}
{"ts":"2026-07-21T14:32:21.032+08:00","level":"PASS","event":"check.end","module":"winsock","seq":5,"elapsed_ms":351,"verdict":"pass"}
{"ts":"2026-07-21T14:32:21.499+08:00","level":"PASS","event":"check.end","module":"nic","seq":6,"elapsed_ms":467,"verdict":"pass","adapter":"Ethernet0","speed":"1 Gbps","errors":0,"discards":0}
{"ts":"2026-07-21T14:32:21.821+08:00","level":"WARN","event":"check.end","module":"firewall","seq":7,"elapsed_ms":322,"verdict":"warning","findings":[{"rule":"360StopAll","direction":"Inbound","protocol":"TCP","action":"Block"},{"rule":"360StopAllUDP","direction":"Inbound","protocol":"UDP","action":"Block"}]}
{"ts":"2026-07-21T14:32:22.017+08:00","level":"PASS","event":"check.end","module":"route","seq":8,"elapsed_ms":196,"verdict":"pass","default_gw":"192.168.1.1","active_routes":12}
{"ts":"2026-07-21T14:32:22.243+08:00","level":"PASS","event":"check.end","module":"ipconflict","seq":9,"elapsed_ms":226,"verdict":"pass","arp_conflict":false}
{"ts":"2026-07-21T14:32:22.361+08:00","level":"PASS","event":"check.end","module":"hosts","seq":10,"elapsed_ms":118,"verdict":"pass","hijack_entries":0}
{"ts":"2026-07-21T14:32:22.380+08:00","level":"INFO","event":"diagnosis.summary","total":10,"pass":7,"warn":2,"fail":1,"elapsed_ms":4038,"fixable":3}
{"ts":"2026-07-21T14:32:25.102+08:00","level":"INFO","event":"fix.start","module":"dns"}
{"ts":"2026-07-21T14:32:25.456+08:00","level":"INFO","event":"fix.step","module":"dns","step":"ipconfig /flushdns","exit_code":0}
{"ts":"2026-07-21T14:32:25.891+08:00","level":"INFO","event":"fix.step","module":"dns","step":"Restart-Service Dnscache","exit_code":0}
{"ts":"2026-07-21T14:32:26.112+08:00","level":"PASS","event":"fix.end","module":"dns","verdict":"success","reboot_required":false}
{"ts":"2026-07-21T14:32:26.345+08:00","level":"INFO","event":"fix.start","module":"security"}
{"ts":"2026-07-21T14:32:26.782+08:00","level":"PASS","event":"fix.end","module":"security","verdict":"success","reboot_required":true,"cleaned_drivers":["360FsFlt"]}
{"ts":"2026-07-21T14:32:27.045+08:00","level":"INFO","event":"fix.start","module":"firewall"}
{"ts":"2026-07-21T14:32:27.956+08:00","level":"PASS","event":"fix.end","module":"firewall","verdict":"success","reboot_required":false}
{"ts":"2026-07-21T14:32:27.960+08:00","level":"INFO","event":"fix.summary","total":3,"success":3,"failed":0,"reboot_required":true}
{"ts":"2026-07-21T14:32:31.245+08:00","level":"INFO","event":"verify.start","module":"dns"}
{"ts":"2026-07-21T14:32:32.013+08:00","level":"PASS","event":"verify.end","module":"dns","verdict":"pass","resolvedns":{"www.baidu.com":"ok"}}
{"ts":"2026-07-21T14:32:32.015+08:00","level":"INFO","event":"session.end","exit_code":0}
```

### 3.3 JSON 日志字段说明

```json
// 每条日志的公共字段
{
  "ts":        "ISO 8601 时间戳 (本地时区)",
  "level":     "INFO | PASS | WARN | FAIL | ERROR | DEBUG",
  "event":     "事件类型 (check.start / check.end / fix.start / fix.end / ...)",
  "module":    "模块名 (dhcp / security / proxy / dns / winsock / nic / firewall / route / ipconflict / hosts)",
  "elapsed_ms":"该操作耗时 (毫秒)",
  "verdict":   "pass | warning | fail | error"
}
```

---

## 4. 交互流程

### 4.1 完整交互流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                      程序启动入口                                  │
│                  NetAid.bat / NetAid.ps1                          │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────┐
              │  1. 解析命令行参数        │
              │     -Help? → 显示帮助退出  │
              │     -Version? → 显示版本退出│
              └────────────┬────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │  2. 权限检查              │
              │  ([Security.Principal.   │
              │   WindowsPrincipal]      │
              │   IsInRole(Admin))       │
              └────────────┬────────────┘
                           │
              ┌────────────┴────────────┐
              │ 管理员?                   │
              └────────────┬────────────┘
                    ┌──────┴──────┐
                    │             │
                   是             否
                    │             │
                    ▼             ▼
              ┌──────────┐  ┌──────────────────┐
              │ 标记      │  │ 非管理员模式       │
              │ Elevated  │  │ 诊断可用 / 修复禁用 │
              │ = $true   │  │ 显示黄色权限提醒    │
              └────┬─────┘  └────────┬─────────┘
                   │                 │
                   └────────┬────────┘
                            │
                            ▼
              ┌─────────────────────────┐
              │  3. 系统环境检测          │
              │  - OS 版本检查            │
              │  - PS 版本检查            │
              │  - 网络适配器枚举          │
              │  - 时区/编码设置           │
              └────────────┬────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │  4. 路由到执行模式         │
              │  -Auto/-Check/-Fix/...   │
              └────────────┬────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
  ┌────────────┐   ┌────────────┐   ┌────────────┐
  │ -Auto 模式  │   │ -Check 模式 │   │ 无参/交互   │
  └─────┬──────┘   └─────┬──────┘   └─────┬──────┘
        │                │                │
        ▼                ▼                ▼
  ┌───────────┐   ┌───────────┐   ┌───────────┐
  │ 显示主界面  │   │ 直接诊断   │   │ 显示主菜单  │
  │ (精简版)   │   │ 全部模块   │   │ 等待用户选择 │
  └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
        │               │               │
        └───────┬───────┘               │
                │                       │
                ▼                       ▼
  ┌─────────────────────────┐   ┌───────────────┐
  │  5. 并行诊断引擎          │   │ 单项诊断/修复   │
  │  Start-Job × N 模块      │   │ 用户指定的模块  │
  │  收集结果 + 汇总          │   └───────┬───────┘
  └────────────┬────────────┘           │
               │                        │
               ▼                        │
  ┌─────────────────────────┐           │
  │  6. 生成诊断报告          │◄──────────┘
  │  控制台输出 + JSONL 日志  │
  └────────────┬────────────┘
               │
               ▼
  ┌─────────────────────────┐
  │  7. 判断是否需要修复       │
  │  全部通过? → 完成退出      │
  │  有问题?   → 进入修复流程   │
  └────────────┬────────────┘
               │
    ┌──────────┴──────────┐
    │ 全部通过              │ 有问题
    ▼                      ▼
  ┌────────┐    ┌─────────────────────┐
  │ 显示    │    │ 8. 修复确认           │
  │ 正常    │    │ 非管理员? → 提权提示   │
  │ 退出    │    │ -Auto? → 跳过确认     │
  └────────┘    │ 列出: 可自动修复 / 需手动│
                └──────────┬──────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │  9. 执行修复              │
              │  按依赖排序执行            │
              │  每步记录结果              │
              │  标记 reboot_required     │
              └────────────┬────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │  10. 修复后验证           │
              │  对每个修复模块重新诊断     │
              │  确认问题已解决            │
              └────────────┬────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │  11. 完成 / 输出摘要      │
              │  成功数 / 失败数 / 需重启  │
              │  退出码                   │
              │  如需重启 → 询问          │
              └─────────────────────────┘
```

### 4.2 模块依赖与修复顺序

```
修复排序 (拓扑顺序，先底层后上层):
────────────────────────────────────────────────
  优先级 1 (底层协议):
    nic          → 网卡驱动重置 (最底层)
    winsock      → Winsock 重置 (影响所有网络)
    route        → 路由表修复

  优先级 2 (网络配置):
    dhcp         → DHCP 续租
    ipconflict   → IP 冲突处理

  优先级 3 (名称解析):
    dns          → DNS 缓存/客户端重置
    hosts        → hosts 文件清理

  优先级 4 (安全/过滤):
    firewall     → 防火墙重置
    proxy        → 代理清理
    security     → 第三方残留清理 (最后, 可能需重启)
────────────────────────────────────────────────

  执行规则:
  - 同优先级可并行 Start-Job
  - 优先级间串行 (Wait-Job)
  - security 模块的驱动删除操作始终在最后执行
  - 存在 reboot_required 标记时，后续模块仍执行但记录"待重启生效"
```

### 4.3 状态机定义

```
┌──────────────────────────────────────────────────────────────────┐
│                         状态机                                     │
├──────────────┬───────────────────────────────────────────────────┤
│ 状态           │ 说明                                               │
├──────────────┼───────────────────────────────────────────────────┤
│ INIT         │ 程序启动，解析参数                                    │
│ CHECK_PRIV   │ 检查管理员权限                                       │
│ CHECK_ENV    │ 检查系统环境 (OS/PS/网络)                             │
│ MENU         │ 显示主菜单，等待输入                                  │
│ DIAGNOSING   │ 诊断进行中                                          │
│ DIAG_DONE    │ 诊断完成，展示报告                                    │
│ FIX_CONFIRM  │ 等待用户确认修复                                      │
│ FIXING       │ 修复进行中                                          │
│ FIX_DONE     │ 修复完成                                            │
│ VERIFYING    │ 修复后验证                                          │
│ DONE         │ 流程结束，准备退出                                    │
│ ERROR        │ 发生错误                                            │
│ EXIT         │ 退出                                                │
└──────────────┴───────────────────────────────────────────────────┘
```

---

## 5. BAT 启动器设计

### 5.1 设计原则

```
┌─────────────────────────────────────────────────────────────────┐
│  .bat 文件编码: ASCII (纯英文)                                     │
│  中文输出: 全部由 .ps1 处理                                        │
│  职责: 权限检测 + 提权 + 绕过ExecutionPolicy + 参数透传             │
│  不要做的事: 写中文 echo、设 chcp 65001、加 BOM                     │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 BAT 启动器完整代码 (NetAid.bat)

```bat
@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  NetAid.bat — 断网急救箱启动器
::  职责: 权限检测 / UAC提权 / PowerShell策略绕过 / 参数透传
::  编码: ASCII (纯英文, 无中文, 无BOM)
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "PS1_SCRIPT=%SCRIPT_DIR%NetAid.ps1"

:: ============================================================
::  0. 检查 PowerShell 脚本是否存在
:: ============================================================
if not exist "%PS1_SCRIPT%" (
    echo [ERROR] NetAid.ps1 not found: %PS1_SCRIPT%
    echo Please ensure NetAid.ps1 is in the same directory as NetAid.bat
    pause
    exit /b 1
)

:: ============================================================
::  1. 检测管理员权限
:: ============================================================
net session >nul 2>&1
if %errorlevel% equ 0 (
    set "IS_ADMIN=1"
) else (
    set "IS_ADMIN=0"
)

:: ============================================================
::  2. 收集所有传入参数 (透传给 .ps1)
:: ============================================================
set "ARGS="
:parse_args
if "%~1"=="" goto args_done
set "ARGS=%ARGS% %1"
shift
goto parse_args
:args_done

:: ============================================================
::  3. 非管理员 → 弹出 UAC 提权对话框
:: ============================================================
if "%IS_ADMIN%"=="0" (
    echo [INFO] Requesting administrator privileges...
    :: 使用 VBScript 创建 Shell.Application 以触发 UAC
    set "VBS_FILE=%TEMP%\NetAid_Elevate.vbs"
    (
        echo Set UAC = CreateObject^("Shell.Application"^)
        echo UAC.ShellExecute "cmd.exe", "/c """"%SCRIPT_DIR%NetAid.bat""" %ARGS%", "", "runas", 1
    ) > "%VBS_FILE%"
    cscript //nologo "%VBS_FILE%" >nul 2>&1
    del "%VBS_FILE%" >nul 2>&1

    :: 当前非管理员实例退出，等待提权后的新实例
    exit /b %errorlevel%
)

:: ============================================================
::  4. 已是管理员: 设置控制台标题
:: ============================================================
title NetAid - Network First Aid

:: ============================================================
::  5. 调用 PowerShell 脚本
::     策略: Bypass ExecutionPolicy
::     编码: UTF8 (读写控制台)
::     参数: 透传所有命令行参数
:: ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; ^
     $OutputEncoding = [System.Text.Encoding]::UTF8; ^
     & '%PS1_SCRIPT%' %ARGS%; ^
     exit $LASTEXITCODE"

:: ============================================================
::  6. 捕获退出码并返回
:: ============================================================
set "EXIT_CODE=%errorlevel%"

:: 如果用户按了任意键退出，暂停一下让用户看到输出
if "%EXIT_CODE%" neq "0" (
    echo.
    echo [NetAid] Exit code: %EXIT_CODE%
)

exit /b %EXIT_CODE%
```

### 5.3 架构决策说明

```
┌──────────────────────────────────────────────────────────────────┐
│  为什么用 VBScript ShellExecute 而不是 PowerShell Start-Process   │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  方案A (推荐): VBScript ShellExecute("runas")                     │
│    - 纯 Windows 原生，零依赖                                       │
│    - UAC 对话框最干净 ("你要允许此应用对你的设备进行更改吗?")        │
│    - 不依赖 PowerShell 已可用 (cmd.exe 自身提权)                    │
│                                                                  │
│  方案B (备选): PowerShell Start-Process -Verb RunAs               │
│    - 需要 PowerShell 可用                                         │
│    - 参数含空格时转义复杂                                          │
│    - 优点: 可以显示更友好的提示                                     │
│                                                                  │
│  方案C (不使用): runas 命令                                        │
│    - runas.exe 需要目标用户的明文密码，不适合 UAC 提权              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 5.4 PowerShell 主脚本骨架 (NetAid.ps1 头部)

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    断网急救箱 — Windows 网络诊断与修复工具
.DESCRIPTION
    纯 PowerShell 5.1 零依赖脚本，覆盖 10 类网络故障的诊断与自动修复。
    诊断模式无需管理员权限，修复模式需要管理员权限。
    支持 Win10/11 全版本。
.PARAMETER Auto
    全自动模式: 诊断 + 修复 + 报告 + 退出
.PARAMETER Check
    仅诊断模式: 运行全部诊断并输出报告
.PARAMETER Fix
    修复指定模块 (需要管理员权限)
.PARAMETER FixAll
    修复所有检测到的问题
.PARAMETER Log
    指定日志输出路径
.PARAMETER Output
    报告输出格式: Console | JSON | HTML | All
.PARAMETER Module
    仅诊断指定模块
.PARAMETER Silent
    静默模式 (仅 JSON StdOut)
.PARAMETER NoColor
    禁用彩色输出
.PARAMETER Help
    显示帮助
.PARAMETER Version
    显示版本
.PARAMETER ListModules
    列出所有可用模块
.PARAMETER Report
    生成最近一次诊断的可读报告
.EXAMPLE
    .\NetAid.ps1 -Auto
    全自动诊断并修复
.EXAMPLE
    .\NetAid.ps1 -Check
    仅诊断
.EXAMPLE
    .\NetAid.ps1 -Fix dns
    仅修复 DNS 问题
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Auto')]
    [switch] $Auto,

    [Parameter(ParameterSetName = 'Check')]
    [switch] $Check,

    [Parameter(ParameterSetName = 'Fix')]
    [ValidateSet('dhcp', 'security', 'proxy', 'dns', 'winsock', 'nic', 'firewall', 'route', 'ipconflict', 'hosts', 'all')]
    [string[]] $Fix,

    [Parameter(ParameterSetName = 'Fix')]
    [switch] $FixAll,

    [Parameter(ParameterSetName = 'Check')]
    [Parameter(ParameterSetName = 'Fix')]
    [Parameter(ParameterSetName = 'Auto')]
    [string] $Log,

    [Parameter(ParameterSetName = 'Check')]
    [Parameter(ParameterSetName = 'Fix')]
    [Parameter(ParameterSetName = 'Auto')]
    [ValidateSet('Console', 'JSON', 'HTML', 'All')]
    [string] $Output = 'Console',

    [Parameter(ParameterSetName = 'Check')]
    [ValidateSet('dhcp', 'security', 'proxy', 'dns', 'winsock', 'nic', 'firewall', 'route', 'ipconflict', 'hosts', 'all')]
    [string] $Module = 'all',

    [Parameter(ParameterSetName = 'Check')]
    [Parameter(ParameterSetName = 'Fix')]
    [Parameter(ParameterSetName = 'Auto')]
    [switch] $Silent,

    [switch] $NoColor,

    [Parameter(ParameterSetName = 'Help')]
    [switch] $Help,

    [Parameter(ParameterSetName = 'Version')]
    [switch] $Version,

    [Parameter(ParameterSetName = 'ListModules')]
    [switch] $ListModules,

    [Parameter(ParameterSetName = 'Report')]
    [switch] $Report
)

# ============================================================
#  全局配置
# ============================================================
$Script:Version      = '1.0.0'
$Script:SessionId    = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$Script:StartTime    = Get-Date
$Script:IsAdmin      = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Script:ColorEnabled = -not $NoColor -and -not $Silent
$Script:LogDir       = if ($Log) { $Log } else { Join-Path $env:TEMP "NetAid" }
$Script:LogFile      = Join-Path $Script:LogDir "NetAid_$(Get-Date -Format 'yyyyMMdd_HHmmss').jsonl"
$Script:DiagResults  = @{}
$Script:FixResults   = @{}

# 确保日志目录存在
if (-not (Test-Path $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}

# ============================================================
#  编码设置 (控制台中文输出)
# ============================================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# ... (后续: 参数路由, 模块定义, 诊断引擎, 修复引擎, 报告生成等)
```

### 5.5 项目文件结构

```
NetAid/
├── NetAid.bat              # 启动器 (ASCII, 无中文, 无BOM)
├── NetAid.ps1              # 主脚本 (UTF-8 BOM)
├── modules/
│   ├── dhcp.ps1            # DHCP 诊断/修复模块 (UTF-8 BOM)
│   ├── security.ps1        # 第三方残留检测/清理 (UTF-8 BOM)
│   ├── proxy.ps1           # 代理/VPN 检测/清理 (UTF-8 BOM)
│   ├── dns.ps1             # DNS 诊断/修复 (UTF-8 BOM)
│   ├── winsock.ps1         # Winsock/TCP-IP 修复 (UTF-8 BOM)
│   ├── nic.ps1             # 网卡驱动检测/修复 (UTF-8 BOM)
│   ├── firewall.ps1        # 防火墙诊断/修复 (UTF-8 BOM)
│   ├── route.ps1           # 路由表诊断/修复 (UTF-8 BOM)
│   ├── ipconflict.ps1      # IP 冲突检测 (UTF-8 BOM)
│   └── hosts.ps1           # hosts 劫持检测/修复 (UTF-8 BOM)
├── lib/
│   ├── logger.ps1          # JSONL 日志模块 (UTF-8 BOM)
│   ├── ui.ps1              # 控制台 UI/彩色输出 (UTF-8 BOM)
│   ├── parallel.ps1        # Start-Job 并行封装 (UTF-8 BOM)
│   └── utils.ps1           # 通用工具函数 (UTF-8 BOM)
├── logs/                   # 默认日志输出目录
├── README.md               # 使用说明 (UTF-8)
└── CHANGELOG.md            # 版本历史 (UTF-8)
```

### 5.6 与 bat 启动器配套的代码块 (NetAid.ps1 中的调用)

```powershell
# 当通过 .bat 启动时，$MyInvocation.Line 会显示完整命令行
# 用户也可以直接运行 .ps1 (绕过 .bat)，以下代码确保两种方式都工作:

# 如果直接双击 .ps1 (非管理员)，自动尝试提权:
if (-not $Script:IsAdmin -and $Auto -or $Fix -or $FixAll) {
    # 修复模式需要管理员，自动触发提权
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($MyInvocation.Line -replace '^.*?\.ps1\s*', '')"
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0
}
```

---

## 6. 附录: 辅助设计细节

### 6.1 APIPA 检测逻辑

```powershell
# APIPA (169.254.x.x) 检测 — 必须关联适配器状态
# 正确的检测流程:
function Test-APIPA {
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($adapter in $adapters) {
        $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                               -AddressFamily IPv4 `
                               -ErrorAction SilentlyContinue
        if ($ip -and $ip.IPAddress -match '^169\.254\.') {
            return @{
                Detected  = $true
                Adapter   = $adapter.Name
                IP        = $ip.IPAddress
                Interface = $adapter.InterfaceIndex
            }
        }
    }
    return @{ Detected = $false }
}

# 错误做法: 不检查 Status -eq 'Up'，会把已断开的虚拟适配器的 169.254 也报出来
# 错误做法: 用 Get-NetIPAddress 直接查 169.254 前缀，不关联 InterfaceIndex
```

### 6.2 DNS 测试策略

```powershell
# 主测试: Resolve-DnsName (UDP 53, 走系统 DNS 解析路径)
# 辅测试: Ping (ICMP, 可能被防火墙阻止)
# 逻辑:
#   - Resolve-DnsName 成功 → PASS
#   - Resolve-DnsName 失败, Ping 成功 → 纯 DNS 故障
#   - Resolve-DnsName 失败, Ping 失败 → 网络层连通性问题
#   - 两者都失败且 APIPA → DHCP 故障

function Test-DNS {
    param([string[]]$Targets = @('www.baidu.com', 'www.qq.com', 'www.microsoft.com'))

    $result = @{ ResolveDns = @{}; Ping = @{}; Verdict = 'unknown' }

    # 主: Resolve-DnsName (PS 5.1 原生可用)
    foreach ($t in $Targets) {
        try {
            $r = Resolve-DnsName -Name $t -Type A -QuickTimeout -ErrorAction Stop
            $result.ResolveDns[$t] = if ($r) { 'ok' } else { 'nxdomain' }
        } catch {
            $result.ResolveDns[$t] = 'timeout'
        }
    }

    # 辅: Ping 知名 DNS IP
    $pingTargets = @('223.5.5.5', '8.8.8.8', '114.114.114.114')
    foreach ($ip in $pingTargets) {
        $ping = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
        $result.Ping[$ip] = $ping
    }

    # 判决
    $allDnsFailed = ($result.ResolveDns.Values | Where-Object { $_ -ne 'ok' }).Count -eq $Targets.Count
    $anyPingOk    = $result.Ping.Values -contains $true

    if (-not $allDnsFailed) {
        $result.Verdict = 'pass'
    } elseif ($anyPingOk) {
        $result.Verdict = 'dns_only_failure'
    } else {
        $result.Verdict = 'network_unreachable'
    }

    return $result
}
```

### 6.3 并行诊断引擎 (PS 5.1 Start-Job 替代 ForEach-Object -Parallel)

```powershell
# PS 5.1 不支持 ForEach-Object -Parallel (那是 PS 7.0+ 的功能)
# 使用 Start-Job 实现并行诊断

function Invoke-ParallelDiagnosis {
    param(
        [string[]]$Modules,
        [int]$ThrottleLimit = 5   # 最多并行 5 个 Job
    )

    $jobs = @{}
    $running = @()

    foreach ($mod in $Modules) {
        # 等待直到有空闲槽位
        while ($running.Count -ge $ThrottleLimit) {
            $completed = $running | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' }
            foreach ($j in $completed) {
                $running = $running | Where-Object { $_.Id -ne $j.Id }
            }
            if ($running.Count -ge $ThrottleLimit) {
                Start-Sleep -Milliseconds 100
            }
        }

        $job = Start-Job -Name "Diag_$mod" -ScriptBlock {
            param($ModuleName, $ScriptRoot)
            . "$ScriptRoot\modules\$ModuleName.ps1"
            return Invoke-Diagnosis -Module $ModuleName
        } -ArgumentList $mod, $PSScriptRoot

        $jobs[$mod] = $job
        $running += $job
    }

    # 等待全部完成
    $results = @{}
    foreach ($mod in $Modules) {
        $job = $jobs[$mod]
        $result = $job | Wait-Job | Receive-Job
        $results[$mod] = $result
        $job | Remove-Job -Force
    }

    return $results
}
```

### 6.4 第三方残留检测注册表扫描键

```powershell
# 已知第三方安全软件驱动名 (HKLM\SYSTEM\CurrentControlSet\Services\)
$KnownSecurityDrivers = @{
    # 360 安全卫士 / 杀毒
    '360FsFlt'    = @{ Vendor = 'Qihu 360'; Product = '360安全卫士'; Type = 'FileSystemFilter' }
    '360AntiHacker' = @{ Vendor = 'Qihu 360'; Product = '360安全卫士'; Type = 'Kernel' }
    '360Box'      = @{ Vendor = 'Qihu 360'; Product = '360安全卫士'; Type = 'Kernel' }
    '360Hvm'      = @{ Vendor = 'Qihu 360'; Product = '360安全卫士'; Type = 'Hypervisor' }
    '360netmon'   = @{ Vendor = 'Qihu 360'; Product = '360安全卫士'; Type = 'Network' }

    # 火绒
    'hrwfpdrv'    = @{ Vendor = 'Huorong'; Product = '火绒安全'; Type = 'WFP' }
    'hrdevmon'    = @{ Vendor = 'Huorong'; Product = '火绒安全'; Type = 'DeviceMonitor' }
    'sysdiag'     = @{ Vendor = 'Huorong'; Product = '火绒安全'; Type = 'Kernel' }

    # 腾讯电脑管家
    'TSDefenseBT' = @{ Vendor = 'Tencent'; Product = '腾讯电脑管家'; Type = 'Kernel' }
    'TSSysKit'    = @{ Vendor = 'Tencent'; Product = '腾讯电脑管家'; Type = 'Kernel' }
    'TSNetMon'    = @{ Vendor = 'Tencent'; Product = '腾讯电脑管家'; Type = 'Network' }
    'TSSysKitProxy' = @{ Vendor = 'Tencent'; Product = '腾讯电脑管家'; Type = 'Kernel' }

    # 金山毒霸
    'kisknl'      = @{ Vendor = 'Kingsoft'; Product = '金山毒霸'; Type = 'Kernel' }

    # 瑞星
    'RisingKernel' = @{ Vendor = 'Rising'; Product = '瑞星杀毒'; Type = 'Kernel' }
}

# Winsock LSP 目录完整性
$WinsockCatalogPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinSock2\Parameters\Protocol_Catalog9\Catalog_Entries'

# WFP 过滤器 (netsh wfp show filters)
# 检测非 Microsoft 发行者的过滤器
```

### 6.5 修复命令基准序列

```powershell
# 标准修复序列 (按依赖顺序，不可并行)
$FixCommands = @(
    # 1. Winsock 重置 (最底层)
    @{ Cmd = 'netsh'; Args = @('winsock', 'reset'); Desc = '重置 Winsock 目录' },

    # 2. IP 协议栈重置
    @{ Cmd = 'netsh'; Args = @('int', 'ip', 'reset'); Desc = '重置 IPv4/IPv6 协议栈' },
    @{ Cmd = 'netsh'; Args = @('int', 'ipv4', 'reset'); Desc = '重置 IPv4' },
    @{ Cmd = 'netsh'; Args = @('int', 'ipv6', 'reset'); Desc = '重置 IPv6' },

    # 3. TCP 协议栈重置
    @{ Cmd = 'netsh'; Args = @('int', 'tcp', 'reset'); Desc = '重置 TCP 协议栈' },

    # 4. IP 地址续租
    @{ Cmd = 'ipconfig'; Args = @('/release'); Desc = '释放 DHCP 租约' },
    @{ Cmd = 'ipconfig'; Args = @('/renew'); Desc = '续租 DHCP 地址' },

    # 5. DNS 缓存刷新
    @{ Cmd = 'ipconfig'; Args = @('/flushdns'); Desc = '刷新 DNS 解析缓存' },

    # 6. 防火墙重置
    @{ Cmd = 'netsh'; Args = @('advfirewall', 'reset'); Desc = '重置 Windows 防火墙' },

    # 7. WinHTTP 代理重置
    @{ Cmd = 'netsh'; Args = @('winhttp', 'reset', 'proxy'); Desc = '重置 WinHTTP 代理' },

    # 8. ARP 缓存清理
    @{ Cmd = 'arp'; Args = @('-d', '*'); Desc = '清理 ARP 缓存' }
)
```

---

## 7. 总结: 关键设计决策

```
┌──────┬──────────────────────────────────────────────────────────────┐
│ 决策   │ 理由                                                         │
├──────┼──────────────────────────────────────────────────────────────┤
│ .bat  │ cmd 在 chcp 65001 后会把 GBK 字节按 UTF-8 重新解析, 造成乱码。   │
│ ASCII │ 所有中文输出交给 .ps1 (UTF-8 BOM + OutputEncoding=UTF8) 处理。  │
├──────┼──────────────────────────────────────────────────────────────┤
│ VBS   │ ShellExecute("runas") 是触发 UAC 最干净的方式, 不依赖 PS 已可用。│
│ 提权   │ runas.exe 需要明文密码, Start-Process -Verb RunAs 参数转义复杂。│
├──────┼──────────────────────────────────────────────────────────────┤
│Start- │ PS 5.1 无 ForEach-Object -Parallel, Start-Job 是唯一并行方案。  │
│Job    │ 设 ThrottleLimit=5 避免资源耗尽, 同优先级模块可并行。            │
├──────┼──────────────────────────────────────────────────────────────┤
│Resolve│ ICMP (Ping) 经常被防火墙/路由器阻止, Resolve-DnsName 走 UDP 53   │
│-Dns   │ 更贴近真实 DNS 解析路径。两者结合: 主+辅 双检测交叉验证。        │
├──────┼──────────────────────────────────────────────────────────────┤
│APIPA  │ 仅检测 Status='Up' 的适配器上的 169.254 — 避免断开状态的虚拟适配器 │
│关联   │ 产生误报。                                                      │
├──────┼──────────────────────────────────────────────────────────────┤
│JSONL  │ 每行一条独立 JSON, 可追加写入, 可流式解析, 单行损坏不影响其他行。  │
│       │ 比单一大 JSON 更适合日志场景, 也方便 grep/jq 处理。              │
├──────┼──────────────────────────────────────────────────────────────┤
│彩色方  │ 语义映射直观: 绿=通过, 黄=警告, 红=失败, 青=信息 — 用户无需看文字 │
│案     │ 也能快速判断状态。禁用 -NoColor 和 -Silent 用于脚本集成场景。      │
└──────┴──────────────────────────────────────────────────────────────┘
```
