# 设备电量插件

`DeviceBattery` 在组件面板中聚合本机和外设电量。它不访问外部网页，也不会上传设备信息。

## 数据来源

- Mac 内置电池：`IOPowerSources`。
- iPhone / iPad / iPod touch / Vision Pro：运行时加载 macOS 自带的 `MobileDevice.framework`，通过已建立的 lockdown 配对会话读取 `com.apple.mobile.battery`；必要时回退到 diagnostics relay 的 `AppleSmartBattery` 快照。
- Apple Watch：通过已连接 iPhone 的 `com.apple.companion_proxy` 读取配对手表的电量与充电状态，不直接连接手表。
- 蓝牙与 Apple 外设：`system_profiler SPBluetoothDataType -json`、`IOBluetoothDevice`、相关 `IORegistry` 服务，以及系统 BatteryCenter / bluetoothd 近期本地日志中的电源状态。
- AirPods / Beats 分体状态：优先使用 `system_profiler` 中的盒、左耳、右耳电量；若系统日志或近场广播携带充电位，则用短时采样补齐“充电中”状态。
- 雷柏 VT 系列鼠标：厂商 HID 接口，匹配 `VendorID = 0x24AE`、`PrimaryUsagePage = 0xFF00`、`PrimaryUsage = 0x0001`。

雷柏鼠标电量来自本机 HID input report，不访问雷柏网页，也不请求网络。第一版只监听设备主动上报，不主动发送刷新命令。

蓝牙日志补偿只查询最近的本机统一日志短窗口，并带有超时和目标过滤；AirPods / Beats 广播扫描只在系统已识别出 Apple/Beats 耳机目标时短时运行，不做常驻全量 BLE 扫描。所有数据均保留在本机。

Apple 移动设备首次使用时，需要通过数据线连接 Mac 并在设备上选择“信任”。在 Finder 中启用通过 Wi-Fi 显示设备后，同一局域网内可无线读取。该路径使用 Apple 未公开但随 macOS 提供的系统框架，因此按 90 秒最短间隔缓存结果；框架、符号或返回字段变化时会无崩溃降级，不影响其他电量来源。设备 UDID 不进入 UI 或普通日志，仅使用本地稳定摘要做去重。

Apple Pencil 不采用 AirBattery 的长时间设备 syslog 扫描方案。该方案本身属于 Beta，首次发现慢且可能增加 iPad 耗电，不符合 MacTools 的轻量、非干扰目标。

## 雷蛇设备说明

AirBattery 没有雷蛇专用 VID/PID 表、HyperSpeed 接收器命令或厂商 HID 电量协议。它对雷蛇设备的兼容来自通用 `bluetoothd` 电源日志和标准 BLE Battery Service (`0x180F` / `0x2A19`)。DeviceBattery 已具备对应的通用路径，因此蓝牙直连、且由设备或 macOS 上报电量的雷蛇鼠标、键盘或耳机可以显示；使用 2.4G HyperSpeed 接收器且不向系统暴露电量的型号仍需按具体设备协议单独适配。

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

系统电池、Apple 移动设备和蓝牙系统信息通常不需要额外授权。Apple 移动设备需要先信任此 Mac。雷柏 HID 读取可能被 macOS 归入输入监控权限；如果 `IOHIDManagerOpen` 返回 `0xE00002E2`，插件会提示打开输入监控设置。
