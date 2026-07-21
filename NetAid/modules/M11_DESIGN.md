# NetAid M11_DeepClean 模块设计说明

## 针对场景
360等安全软件卸载后，NDIS过滤驱动残留导致全网卡DHCP失效（APIPA 169.254.x.x），
常规 netsh reset / 网络重置 / 就地升级均无效的疑难场景。

## 检测项
1. 枚举 HKLM\SYSTEM\CurrentControlSet\Control\Network\{4D36E972...}\ 绑定配置
2. 扫描所有 FilterClass=NDIS 的过滤驱动（NetCfgInstanceId 交叉验证）
3. 检查 NetworkSetup2 组件数据库中的孤儿引用
4. 扫描 C:\Windows\System32\drivers\ 下的 360/腾讯/金山 .sys 文件
5. 检查 nsi 服务 (Network Store Interface) 完整性

## 修复项（全部先备份）
1. 删除孤儿 NDIS 过滤驱动服务注册表项
2. 物理删除残留 .sys 文件（重命名为 .sys.bak）
3. 重建网卡绑定：netcfg -d（最后手段，需二次确认）
4. 修复 NetworkSetup2（删除让系统重建）
