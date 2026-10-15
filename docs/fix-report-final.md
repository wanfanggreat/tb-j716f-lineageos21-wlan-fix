# WLAN 问题完整修复报告（最终版）

> **结论：启动崩溃循环已消除，WiFi 已完全可用（实测能扫描到 19 个 AP）。**
>
> 本文汇总四个独立缺陷的根因、证据与修复，全部经真机验证。
> 过程记录见 `WLAN-FIX-VERIFIED.md`（含中间阶段）。

---

## 一、最终状态（设备实测）

```
$ adb shell
  uptime                    217.94 秒（历史 panic 点在 126 秒）→ 无重启
  sys.boot_completed        1
  ro.lineage.version        21.0-20261014-UNOFFICIAL-p11_pro_plus
  init.svc.vendor.qrtr-ns   running
  init.svc.wpa_supplicant   running
  settings get global wifi_on    1
  dmesg | grep -c "Kernel panic" 0

$ ls /sys/class/net/
  bond0 dummy0 lo p2p0 rmnet_ipa0 sit0 wifi-aware0 wlan0

$ cmd wifi list-scan-results        （示例，BSSID/SSID 已脱敏）
  BSSID              Frequency  RSSI  SSID
  aa:bb:cc:11:22:33       2437   -82  <AP-1>
  aa:bb:cc:11:22:44       2462   -45  <AP-2>
  aa:bb:cc:11:22:55       2437   -78  <AP-3>
  aa:bb:cc:11:22:66       5785   -85  <AP-4>
  aa:bb:cc:11:22:77       2462   -57  （隐藏 SSID）
  ...                          ← 实测共 19 个 AP，含 2.4G/5G
```

---

## 二、问题全貌：四个独立缺陷

表面上都是"WiFi 不工作"，实际是四个**互不相同**的缺陷依次暴露——
每修好一个，下一个才浮现。

| # | 缺陷 | 层 | 症状 | 修复 |
|---|---|---|---|---|
| 1 | `init.qcom.rc` 缺 `vendor.qrtr-ns` 服务定义 | 内核/固件 | 开机 **126s 必 panic 重启**（死循环） | `32c9d56` |
| 2 | `libwifi-hal.so` 被原厂 blob 覆盖成空桩 | HAL | wifi HAL 反复 **SIGSEGV** | `ca00c21` |
| 3 | `wpa_supplicant`/`hostapd` 用 HIDL blob 覆盖 AIDL 栈 | HAL 框架 | supplicant **动态链接失败** | `a96a4ac` |
| 4 | `init.qcom.rc` 有第二份 `service wpa_supplicant` | init | AIDL interface **注册失败**，supplicant 不被拉起 | `a49600a` |

> 缺陷 1 是最早看到的"开机崩溃"根因（初诊曾误判为内核 defconfig，见第六节）。

---

## 三、缺陷 1：缺 vendor.qrtr-ns → 开机 panic

### 3.1 症状

开机约 126 秒内核 panic 重启，无限循环：

```
[   19.662564] cnss_pci 0000:01:00.0: Falling back to syfs fallback for: qca6390/amss20.bin
[   60.384018] cnss: fatal: Timeout waiting for FW ready indication
[  103.392113] cnss: Timeout (40000ms) waiting for calibration to complete
[  126.024382] Kernel panic - not syncing: subsys-restart: Resetting the SoC - wlan crashed.
```

### 3.2 机制链

```
内核 net/qrtr/Makefile 里没有 ns.o  →  本内核【没有】内核态 QRTR 名称服务
                    ↓
cnss2 用 QMI over QRTR 查找固件 WLFW 服务
（qmi_interface.c: qmi_add_lookup → qmi_send_new_lookup
 → QRTR_TYPE_NEW_LOOKUP 发往 QRTR_PORT_CTRL）
                    ↓
必须有用户态进程绑定 QRTR_PORT_CTRL 并应答查询
                    ↓
原厂 init.qcom.rc:546-551 启动 /vendor/bin/qrtr-ns -f（user vendor_qrtr）
我们的副本没有这段  →  无人应答  →  固件服务注册后主机收不到 NEW_SERVER
                    ↓
事件流无 SERVER_ARRIVE / REQUEST_MEM / FW_MEM_READY / FW_READY
                    ↓
40s 校准超时（pci.c:2439）→ cnss_schedule_recovery
→ recovery_enabled=false → panic("subsys-restart: Resetting the SoC wlan crashed")
```

### 3.3 决定性证据：同机同内核 A/B 实验

在 recovery 模式（该模式下 init 不自动启动 qrtr-ns）做对照：

**A. 缺 qrtr-ns（复现失败）**

```
$ /tmp/qrtr-lookup
  Service Version Instance Node  Port
                                  ← 表头下【空】，零条服务
$ 写 fs_ready 触发冷启动校准后：无任何 SERVER_ARRIVE
```

**B. 手动启动 qrtr-ns（立即恢复）**

```
$ nohup /tmp/qrtr-ns -f &
$ /tmp/qrtr-lookup
  Service Version Instance Node  Port
     4097     N/A      388    1 16439 DIAG service ...
     ...（共 22 条）...
       69       1        1    7     1 ATH10k WLAN firmware service
       ↑ service 0x45 = 69 = WLFW_SERVICE_ID_V01

$ 写 fs_ready 触发后：
  [ 2893.857210] cnss: WLFW server arriving: node 7 port 1     ← 历史首次
  [ 2893.857250] cnss: QMI WLFW service connected, state: 0x9
```

### 3.4 修复与验证

补回 6 行（与原厂逐字节一致）：

```rc
service vendor.qrtr-ns /vendor/bin/qrtr-ns -f
    class core
    user vendor_qrtr
    group vendor_qrtr
    capabilities NET_BIND_SERVICE
```

刷入后：

```
$ dmesg | grep "Posting event"
  19.627  Posting event: COLD_BOOT_CAL_START(5)
  20.355  Posting event: SERVER_ARRIVE(0)        ← 修复前【不存在】
  21.016  Posting event: REQUEST_MEM(2)          ← 修复前【不存在】
  21.028  Posting event: FW_MEM_READY(3)         ← 修复前【不存在】
  21.101  Posting event: FW_READY(4)             ← 修复前【不存在】
  25.551  Posting event: COLD_BOOT_CAL_DONE(6)
  25.555  Posting event: SERVER_EXIT(1)

$ dmesg | grep -i Calibration
  25.551122] cnss: Calibration completed successfully    ← 修复前是 Timeout (40000ms)

$ uptime → 越过 126s，无 panic
```

### 3.5 配套条件（均已核实，无需改动）

| 条件 | 状态 | 证据 |
|---|---|---|
| `qrtr-ns` 二进制 | ✅ 已在镜像内 | 与原厂 md5 相同（`3ffa07dde09dd4e927b7a1a73503be5f`） |
| SELinux 域 `vendor_qrtr` | ✅ | `device/qcom/sepolicy_vndr/legacy-um/qva/vendor/common/qrtr.te` |
| 文件上下文 | ✅ `vendor_qrtr_exec` | 与原厂一致 |
| AID 2906 | ✅ | vendor passwd/group 有 `vendor_qrtr` |
| 内核放行绑定控制端口 | ✅ | `net/qrtr/qrtr.c:1446` `in_egroup_p(AID_VENDOR_QRTR)` |

---

## 四、缺陷 2：libwifi-hal.so 空桩 → HAL 段错误

### 4.1 症状

启动崩溃修好后 WiFi 仍打不开，wifi HAL 反复崩溃：

```
E/WifiVendorHal: Failed to create STA iface
E/WifiNative: Failed to create iface in vendor HAL
E/HalDevMgr: createIface: no chip info found
E/WifiClientModeManager: Failed to create ClientInterface. Sit in Idle
W/WifiHalAidlImpl: IWifi binder died.
E/WifiSelfRecovery: Already restarted wifi 2 times in last 1 hour. Disabling wifi
```

tombstone 精确指向崩溃点：

```
signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x102
Cause: null pointer dereference
Cmdline: /vendor/bin/hw/android.hardware.wifi-service
backtrace:
  #00 libwifi-hal.so (wifi_reset_passpoint_list.cfi+28)
  #01 android.hardware.wifi-service (WifiLegacyHal::getDriverVersion()+92)
  #02 android.hardware.wifi-service (WifiChip::requestChipDebugInfoInternal()+116)
  #03 android.hardware.wifi-service (WifiChip::handleChipConfiguration()+632)
  #04 android.hardware.wifi-service (WifiChip::configureChipInternal()+204)
  #05 android.hardware.wifi-service (WifiChip::configureChip()+80)
```

### 4.2 根因：blob 覆盖

`proprietary-files.txt:1686` 的 `vendor/lib64/libwifi-hal.so` 把 AOSP
**源码编译版**覆盖掉了。原厂那份是给 HIDL 服务配的，vendor 实现留空。

**决定性证据（readelf -sW 符号大小，单位字节）：**

| 函数 | 原厂 blob（曾进镜像） | 源码编译版 |
|---|---|---|
| `wifi_get_driver_version` | **8**（空桩） | **16** |
| `wifi_reset_passpoint_list` | **44** | **72** |
| `wifi_set_passpoint_list` | 4 | 4 |

崩溃栈正是 `getDriverVersion+92` → `wifi_reset_passpoint_list+28`。
另外原厂 blob 里搜不到 qcwcn 实现（`strings | grep -c qcwcn` = 0），
而源码编译版有。

### 4.3 修复与验证

注释掉 `proprietary-files.txt` 里该行，重新生成 `p11_pro_plus-vendor.mk`：

```
$ readelf -sW out/.../vendor/lib64/libwifi-hal.so | grep -E 'get_driver_version|reset_passpoint'
  wifi_reset_passpoint_list    72 B     ← 由空桩(44B)恢复为真实实现
  wifi_get_driver_version      16 B     ← 由空桩(8B)恢复为真实实现
```

刷入后（tombstone 无新增，错误全部消失）：

```
$ dmesg | grep -icE 'IWifi binder died|Failed to create STA iface|no chip info'
  0
$ iw dev
  phy#0
    Interface wifi-aware0   type NAN
    Interface p2p0
```

---

## 五、缺陷 3 & 4：supplicant 起不来（两个叠加原因）

### 5.1 缺陷 3：HIDL blob 覆盖

框架 VINTF manifest 声明的是 **AIDL v3**：

```xml
/vendor/etc/vintf/manifest/android.hardware.wifi.supplicant.xml
  <hal format="aidl">
    <name>android.hardware.wifi.supplicant</name>
    <version>3</version>
    <fqname>ISupplicant/default</fqname>
```

但 `proprietary-files.txt` 用原厂 **HIDL 版**二进制覆盖了它。实测：

```
$ /vendor/bin/hw/wpa_supplicant
CANNOT LINK EXECUTABLE "/vendor/bin/hw/wpa_supplicant": library
"android.hardware.wifi.supplicant@1.2.so" not found: needed by main executable
```

原厂二进制的 `NEEDED` 含四个 HIDL 库（`@1.0/@1.1/@1.2/@1.3.so`），
我们镜像里只有 `@1.0/@1.1`（AOSP 为其它组件编的）。

**修复**（commit `a96a4ac`）：移除 6 项 blob，交给 AOSP 编译版：

```
# vendor/bin/hw/wpa_supplicant     -> external/wpa_supplicant_8/wpa_supplicant (AIDL v3)
# vendor/bin/hw/hostapd            -> external/wpa_supplicant_8/hostapd
# vendor/bin/hostapd_cli           -> 同上
# vendor/bin/wpa_cli               -> 同上
# vendor/etc/init/android.hardware.wifi.supplicant-service.rc
#     -> LOCAL_INIT_RC 自动安装 AIDL 版
# vendor/etc/init/hostapd.android.rc
#     -> LOCAL_INIT_RC 自动安装 AIDL 版
```

编译验证：

```
$ readelf -d out/.../vendor/bin/hw/wpa_supplicant | grep NEEDED | grep -i supplicant
  android.hardware.wifi.supplicant-V3-ndk.so       ← AIDL，不再有 @1.2/@1.3
$ grep interface out/.../vendor/etc/init/android.hardware.wifi.supplicant-service.rc
  interface aidl android.hardware.wifi.supplicant.ISupplicant/default
$ /vendor/bin/hw/wpa_supplicant        （设备上实测）
  wpa_supplicant v2.11-devel-14        ← 能执行了（修复前是链接失败）
```

### 5.2 缺陷 4：init.qcom.rc 里的同名第二份定义

上一修复后 supplicant 二进制可执行了，但**仍不自动启动**：

```
W/ServiceManagerCppClient: Waited one second for
    android.hardware.wifi.supplicant.ISupplicant/default
I/servicemanager: Tried to start aidl service ... as a lazy service, but was unable to
init: Control message: Could not find
    'aidl/android.hardware.wifi.supplicant.ISupplicant/default'
    for ctl.interface_start from pid: 642 (/system/bin/servicemanager)
```

**关键反证**（证明是 interface 注册问题，而非服务缺失）：

```
$ setprop ctl.start wpa_supplicant     ← 服务名存在，能启动！
  rc=0 ; init.svc.wpa_supplicant=running
$ 手动启动后 cmd wifi status 立刻变为 "Wifi is enabled"
```

**根因**：设备树 `init.qcom.rc:570-587` 保留了原厂 HIDL 时代的
**第二份 `service wpa_supplicant`**（声明
`interface android.hardware.wifi.supplicant@1.0::ISupplicant default` 等）。
它与 AOSP 的 AIDL 定义**同名**，`ServiceParser::ParseInterface`
对重复 interface 报错并丢弃，导致 AIDL interface 从未注册。

**修复**（commit `a49600a`）：注释掉该重复定义。

刷入后**决定性验证**：

```
$ dmesg | grep -i "Could not find.*supplicant"
  （空）                                     ← 错误消失
$ getprop init.svc.wpa_supplicant
  running
$ ps -A -o USER,NAME | grep wpa_supplicant
  wifi  wpa_supplicant                       ← 自动启动，以 wifi 用户运行
$ cmd wifi status
  Wifi is enabled
$ cmd wifi list-scan-results
  ...（19 个真实 AP）                        ← 功能级验证通过
```

---

## 六、对先前误判的更正

**先前结论有误，此处明确更正。**

初诊把开机崩溃归为「WLAN 驱动被编成内置
（`CONFIG_QCA_CLD_WLAN=y`）导致固件请求过早」，据此改成 `=m`。
**该判断不成立**，证据：

1. 改成 `=m` 并刷入后，panic 签名**一字不差**（`60.384s` 固件就绪超时、
   `103.392s` 校准超时、`125.920s` 二次超时、`126.0s` panic）。
2. 时间线显示发起固件请求的**不是** qcacld 驱动：
   - `19.66s` 固件请求（`cnss_pci` → `qca6390/amss20.bin`）
   - `61.42s` 才 `wlan: Loading driver v5.2.022.12B`

   两者相差 41 秒。发起者一直是内置的 `cnss2`，与 qcacld 加载时机无关。
3. 真正病因是用户态 `qrtr-ns` 缺失（第三节）。

**处置**：`CONFIG_QCA_CLD_WLAN=m` 改动**保留**（与原厂形态一致，利于维护），
但不再声称它是本次崩溃的修复手段。

---

## 七、四次修复的提交记录

| commit | 内容 | 验证方式 |
|---|---|---|
| `32c9d56` | 补回 `init.qcom.rc` 的 `vendor.qrtr-ns` | 真机 A/B 实验 + 刷入后事件流完整 |
| `ca00c21` | 移除 `libwifi-hal.so` blob 覆盖 | 符号大小 44→72 / 8→16；HAL 崩溃消失 |
| `a96a4ac` | 移除 supplicant/hostapd 的 HIDL blob | 依赖无 `@1.2/@1.3`；二进制可执行 |
| `a49600a` | 移除重复的 `service wpa_supplicant` | init 错误消失；supplicant 自启；可扫描 AP |

均在 `~/android/lineage/device/lenovo/p11_pro_plus/`。

## 八、刷机步骤（可复现）

```bash
# 1. 编译（也可直接用本仓库 tools/rebuild-vendor-super.sh）
cd "$LINEAGE"                                  # 你的 LineageOS 源码树
source build/envsetup.sh
lunch lineage_p11_pro_plus-ap2a-userdebug
mka -j"$(nproc)" vendorimage superimage

# 2. 刷入（设备需在 fastbootd）
fastboot flash super out/target/product/p11_pro_plus/super.img
fastboot flash boot  out/target/product/p11_pro_plus/boot.img
fastboot set_active a
fastboot reboot

# 3. 验证（约 2 分钟后）
adb shell 'getprop sys.boot_completed'              # 1
adb shell 'getprop init.svc.wpa_supplicant'         # running
adb shell 'cmd wifi list-scan-results | head'       # 有 AP
```

> 必须重建 `super.img`：WLAN 驱动改为模块构建后 vendor 分区变大
> （775.4 → 784.8 MiB），设备上的 `vendor_a` 装不下旧尺寸。

## 九、产物尺寸（供核对）

```
super.img（最终版）   2,676,452,968 B  （md5 69a8d69689e201e1bf675a4cd3fcf241）
super.img（仅缺陷 2）  2,676,448,872 B
super.img（仅缺陷 1）  2,676,043,368 B
boot.img（含模块化内核） 100,663,296 B
```

各修复阶段对应的 `super.img` 均已在真机上验证。

## 十、遗留事项（不影响本次目标）

| 项 | 说明 |
|---|---|
| `wifidisplayhalservice` 循环重启 | 缺 `libpng.so`（`libwfdmmsrc_proprietary.so` 依赖），与 WiFi 无关 |
| OTA zip 仍是旧镜像 | `lineage-21.0-20261013-*.zip` 含修复前的 vendor；发布需重跑 `bacon` |
| `vbmeta` 与镜像数值不一致 | 设备上 vbmeta 是 `--flags 3`（校验已禁用），不影响启动 |
| 其它 HAL 缺库 | `libsqlite.so`（dolby dms）、`libjsoncpp.so`（c2 service）等，与本问题无关 |
| 未实测联网 | 扫描已验证到 AP；实际连接需在 UI 输入密码（属用户操作） |
