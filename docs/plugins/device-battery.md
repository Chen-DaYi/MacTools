# 设备电量插件

`DeviceBattery` 在组件面板中聚合本机和外设电量。它不访问外部网页，也不会上传设备信息。

## 数据来源

- Mac 内置电池：`IOPowerSources`。
- 蓝牙与 Apple 外设：`system_profiler SPBluetoothDataType -json`、`IOBluetoothDevice`、相关 `IORegistry` 服务，以及系统 BatteryCenter / bluetoothd 近期本地日志中的电源状态。
- AirPods / Beats 分体状态：优先使用 `system_profiler` 中的盒、左耳、右耳电量；若系统日志或近场广播携带充电位，则用短时采样补齐“充电中”状态。
- 雷柏 VT 系列鼠标：厂商 HID 接口，匹配 `VendorID = 0x24AE`、`PrimaryUsagePage = 0xFF00`、`PrimaryUsage = 0x0001`。

雷柏鼠标电量来自本机 HID input report，不访问雷柏网页，也不请求网络。第一版只监听设备主动上报，不主动发送刷新命令。

蓝牙日志补偿只查询最近的本机统一日志短窗口，并带有超时和目标过滤；AirPods / Beats 广播扫描只在系统已识别出 Apple/Beats 耳机目标时短时运行，不做常驻全量 BLE 扫描。所有数据均保留在本机。

## 雷柏 HID 维护依据

雷柏 Hub 网页使用 WebHID 直连本机设备，已知过滤条件为 `vendorId = 0x24AE`、`usagePage = 0xFF00`。VT7 在 macOS `ioreg` 中对应厂商接口 `ProductID = 5139`、`PrimaryUsagePage = 65280`、`PrimaryUsage = 1`；雷柏网页设备表将 `5139` 映射到 Web 产品 ID `17939`，型号为 `VT7`，协议字段为 `protocol = "1"`、`featureReportId = 8`。

当前实现固化了已确认的 VT 系列接收器 Product ID 与 Web 产品 ID 映射，并只处理 input report id `7`。协议 1 的电量解析优先使用 `status = data[6]`、`battery = data[7]`，同时保留 `status = data[7]`、`battery = data[8]` 作为候选偏移。`status` 取值 `1` 表示正常，`2` 表示充电中，`battery` 只接受 `0...100`。

## 布局

组件设置中提供三种布局：

- 网格：默认布局，适合 3 到 6 台设备同时扫读。
- 列表：适合长设备名、AirPods 分体电量和来源排查。
- 大卡片：参考 AirBattery 的大电量视觉，把低电量或主设备放在第一视觉层。

## 低电量通知

插件设置中可开启低电量通知，并设置触发百分比。设备电量低于该百分比、且未处于充电或外接电源状态时，插件会发送系统通知；同一次检测中有多台设备低电量时合并为一条通知。

## 权限

系统电池和蓝牙系统信息通常不需要额外授权。雷柏 HID 读取可能被 macOS 归入输入监控权限；如果 `IOHIDManagerOpen` 返回 `0xE00002E2`，插件会提示打开输入监控设置。
