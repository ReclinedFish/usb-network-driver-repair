# USB 无线网卡驱动绑定诊断与修复

适用于 64 位 Windows 10/11，支持 Windows PowerShell 5.1 和 PowerShell 7。只需分发 `Repair-UsbNetworkDriver.ps1`，不需要第三方模块或编译器。

这是针对“USB 复合设备父子接口绑定异常”的通用脚本，支持不同厂商、VID/PID 和接口编号。它不是所有“代码 10”的一键修复工具，不能修复线材、供电或硬件故障，也不修改驱动签名策略。

## 1. 只检查，不修改

不必切换到脚本目录，也不依赖原来的开发目录。把脚本放到任意本地文件夹，通过完整路径运行（将示例路径换成实际位置）：

```powershell
$tool = 'D:\Tools\usb-network-driver-repair\Repair-UsbNetworkDriver.ps1'
& $tool
```

启动后立即显示查询阶段的进度条，再输出 USB 网络设备及其 USB 父设备的实例 ID、驱动版本、问题码和判断。Windows 设备查询可能持续数秒到数十秒；原生查询返回前，阶段文字可能暂时不更新，并不等于脚本卡死。没有找到网络类设备时输出 `[]`；对尚未归类为网卡的设备，可在设备管理器“详细信息 → 设备实例路径”取得 ID 后指定检查。

进度提示使用独立的 PowerShell 进度流，不混入 JSON。无人值守或不需要进度条时加 `-NoProgress`。无人值守程序还应按需要设置外部超时，本脚本不保证 Windows 原生查询能在固定时间内返回。Inspect 是只读操作，可用 Ctrl+C 取消；不要在实际安装驱动期间拔设备或强制终止。无参数只检查一次，不会自动进入持续观察。

从输出复制一个完整的 `InstanceId`，不要使用示例 ID：

```powershell
$id = 'USB\VID_XXXX&PID_YYYY\完整实例编号'
& $tool -InstanceId $id
& $tool -InstanceId $id -WatchSeconds 300
```

`CompatibleDrivers` 是 Windows 针对此实例列出的兼容候选，不代表各候选都适合整机或都能稳定工作。`SuspectedParentMisbind` 表示值得检查的候选，不能仅凭这个标签认定驱动有错。

观察期间显示采样次数、已用时间和剩余时间；原生查询耗时可能使实际观察时间略长于设定值。结果记录采样时间、问题码和最后枚举时间，可发现采样期间的重新枚举。`WatchSeconds` 支持 0 到 300 秒。Inspect 不连接网络、不主动扫描无线网络、不禁用网卡，也不改路由。短时采样正常不代表联网、吞吐、睡眠唤醒或长期稳定性已经通过；它不是逐事件抓取，极短的状态变化也可能被采样漏过。

默认备份目录始终为**脚本旁边的 `reports`**，不随调用位置变化。可用 `-ReportRoot 'D:\Private\usb-recovery'` 改到可写的私有目录。显式相对路径按 PowerShell 当前工作目录解析。脚本不需要安装到 PATH，也不需要修改系统执行策略；若被组织策略阻止，请遵循本机策略。

## 2. 修复父设备绑定

先断开目标网卡的无线连接。实际修改使用管理员 PowerShell；先预览：

```powershell
& $tool -Action RepairParent -InstanceId $id -WhatIf
& $tool -Action RepairParent -InstanceId $id -WatchSeconds 60
```

只有同时满足以下条件才尝试自动修复：USB 父设备、报告 `USB\COMPOSITE`、以网络类出现且报错、没有子设备、未被人为禁用，且兼容列表含 Windows 自带的 `usb.inf / Composite.Dev`。

已经正确使用 `usbccgp` 且问题码为 0 的父设备会返回 `AlreadyCorrect`，不会重装。正在连接、认证或联网的目标及其子网卡会被拒绝；含键盘、鼠标、HID、存储等子设备的目标也会被拒绝。电脑上的其他联网设备不会因此被重置。

父设备恢复后，Windows 可能自动枚举并安装其功能子设备。脚本会记录子设备状态，但不会自动禁用蓝牙、改无线配置、改路由或替所有子设备更换驱动。

## 3. 给指定网络子接口选择驱动

重新检查当前子接口实例 ID，不能硬编码接口编号、网卡显示名称或 OEM INF 编号。这些值在其他设备或系统上可能不同。

```powershell
$child = 'USB\VID_XXXX&PID_YYYY&MI_ZZ\完整实例编号'
& $tool -InstanceId $child
```

从该输出的 `CompatibleDrivers` 选择 `InfPath`，必要时再指定 `Section`：

```powershell
$inf = 'C:\Windows\INF\oem123.inf' # 替换为本机检查结果
& $tool -Action BindDriver -InstanceId $child -DriverInf $inf -WhatIf
& $tool -Action BindDriver -InstanceId $child -DriverInf $inf -WatchSeconds 60
```

只接受系统驱动库中已经存在、与这个网络子接口兼容的驱动。外部驱动包需要先通过其官方安装方式加入驱动库，再重新检查；脚本不下载、删除驱动包，也不按版本号猜测“最佳驱动”。

## 4. 备份、结果与恢复

每次实际修改前，脚本在 `reports\时间-随机编号\` 保存 `before.json`，并通过 PnPUtil 导出当前 OEM 驱动和文件哈希。Windows 内置驱动使用本机内置包，记录 INF 哈希但不导出。备份失败则停止，不修改设备。

执行结果可能为：

| Status | 含义 |
|---|---|
| `PreviewOnly` | 预览，没有写备份或修改设备 |
| `AlreadyCorrect` | 父设备绑定已正确，无需操作 |
| `BindingApplied` | 绑定与短时检查通过，仍需实际联网验证 |
| `NeedsAttention` | 绑定不符、设备/子设备报错或观察到重新枚举 |
| `RebootRequired` | Windows 要求重启；脚本不会自动重启 |

`after.json` 保存结果；操作异常时尽量保存 `failure.json`。快照保留，不会自动回滚：恢复旧的错误驱动可能重现原故障。退出码 1 表示脚本异常；调用成功后还须检查 `Status`，不能只看进程退出码。

需要恢复一次操作前的**驱动绑定**时：

```powershell
$snapshot = Join-Path (Split-Path $tool) 'reports\对应目录\before.json'
& $tool -Action Restore -InstanceId $id -Snapshot $snapshot -WhatIf
& $tool -Action Restore -InstanceId $id -Snapshot $snapshot
```

恢复只接受同一电脑、相同实例 ID、硬件 ID 与容器 ID。若旧 OEM 包已不在驱动库，会先校验备份，再加入驱动库，按 INF 哈希识别新发布名称。系统升级、驱动库变化或更换端口导致实例变化时，恢复可能被拒绝，需要重新人工核对。恢复不重建被枚举出的整个设备树，也不承诺恢复所有厂商高级属性。

默认 Inspect 不保存文件；需要保留诊断可把 JSON 输出重定向到本地文件。报告含设备标识，但不读取 Wi-Fi 密码或上传数据。`-WhatIf` 仍会查询设备和兼容驱动，不会执行安装、导出或暂存。

这是按需运行的修复工具，不会常驻、锁定驱动或阻止 Windows 更新。将来重新枚举设备或更新驱动后仍可能需要重新检查，不能保证问题永不复发。

## 5. 脱敏与 GitHub 发布

公开诊断时，单独生成脱敏摘要：

```powershell
& $tool -InstanceId $id -WatchSeconds 60 -ShareSafe
# 也可保存这一份脱敏 JSON；不要公开原始终端记录或恢复快照。
& $tool -InstanceId $id -ShareSafe > '.\share-safe.json'
```

`-ShareSafe` 只允许 Inspect，采用字段白名单，不输出用户名、设备实例 ID、序列号、硬件 ID、容器 ID、本机路径、精确时间或原始错误。保留问题码、驱动版本、判断类别和观察汇总。它不能用于恢复，也不会改写原始恢复文件。详细边界见 [PRIVACY.md](PRIVACY.md)。

只打包经过审核的源码和说明，不打包本地记录、厂商驱动或 Git 历史：

```powershell
& (Join-Path (Split-Path $tool) 'Export-PublicPackage.ps1')
```

命令在 `dist` 下创建新的干净目录和 ZIP，遇到已存在的目标会停止。把这个**干净目录**作为 GitHub 仓库根目录，不要上传整个开发工作区。`.gitignore` 默认拒绝未明确允许的文件；它不能阻止强制添加，也不能清除旧的 Git 历史。脚本不会自动创建仓库或上传。

项目使用 [MIT License](LICENSE)。许可证仅覆盖本项目源码与文档，不包含任何第三方驱动的再分发许可。

## 验证

`tests\Repair-UsbNetworkDriver.Tests.ps1` 使用 Windows PowerShell 5.1 / Pester 3.4，修改操作均被模拟。测试使用同一个修复互斥锁，请勿与真实修复或预览同时运行。在 Windows PowerShell 5.1 中设置好 `$tool` 后执行，不会重绑真实设备：

```powershell
$r = Invoke-Pester -Script (Join-Path (Split-Path $tool) 'tests\Repair-UsbNetworkDriver.Tests.ps1') -PassThru
if ($r.FailedCount) { throw 'Tests failed.' }
```

实现依据：[USB 复合设备枚举](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/enumeration-of-the-composite-parent-device)、[DiInstallDevice](https://learn.microsoft.com/en-us/windows/win32/api/newdev/nf-newdev-diinstalldevice)、[PnPUtil](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax)。
