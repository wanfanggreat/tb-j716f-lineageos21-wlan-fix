# WLAN 崩溃修复验证记录（2026-10-14 晚）

> 承接 `WLAN-PANIC-ROOTCAUSE.md`。**启动崩溃循环已彻底解决**，WiFi 接口已出现。

---

## 一、结论摘要

| 项 | 修复前 | 修复后 |
|---|---|---|
| 系统稳定性 | 开机 ~126s 必 panic 重启（无限循环） | **稳定运行 400+ 秒，0 次 panic** |
| `boot_completed` | 从未达成 | **71 秒达成** |
| cnss 事件流 | 仅 4 条（无 SERVER_ARRIVE） | **完整 11 条，含 SERVER_ARRIVE** |
| 冷启动校准 | `Timeout (40000ms)` → panic | **`Calibration completed successfully`（25.5s 完成）** |
| `wlan0` 接口 | 不存在 | **已出现**（MAC `00:03:7f:xx:xx:xx`） |
| WiFi 服务 | 无 | **`WifiState 1`（已启用）** |

## 二、真正的根因（已用真机 A/B 实验证实）

### 2.1 一句话

我们的 `init.qcom.rc` **漏了原厂的 `vendor.qrtr-ns` 服务定义**（6 行），
导致固件的 WLFW QMI 服务永远无法被内核发现。

### 2.2 机制链

```
内核 net/qrtr/Makefile 里没有 ns.o  →  本内核【没有】内核态 QRTR 名称服务
                    ↓
cnss2 用 QMI over QRTR 查找固件 WLFW 服务（qmi_interface.c qmi_add_lookup
→ qmi_send_new_lookup → QRTR_TYPE_NEW_LOOKUP 发往 QRTR_PORT_CTRL）
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

### 2.3 决定性证据（同一设备、同一内核，唯一变量 = qrtr-ns 在不在）

**实验环境**：recovery 模式（该模式下 init 不会自动启动 qrtr-ns），root adb。

**A. 缺 qrtr-ns（复现失败）**

```
$ LD_LIBRARY_PATH=/tmp /tmp/qrtr-lookup
  Service Version Instance Node  Port
                                  ← 表头下【空】，零条服务

$ 写 fs_ready 触发冷启动校准后：
  cnss: Posting event: COLD_BOOT_CAL_START(5)
  （此后无任何 SERVER_ARRIVE）
```

**B. 手动启动 qrtr-ns（修复生效）**

```
$ LD_LIBRARY_PATH=/tmp nohup /tmp/qrtr-ns -f &
$ ps -A | grep qrtr-ns
  833 root  qrtr-ns                       ← 启动成功

$ LD_LIBRARY_PATH=/tmp /tmp/qrtr-lookup
  Service Version Instance Node  Port
     4097     N/A      388    1 16439 DIAG service (<unk>:DCI)
     ...（共 22 条 DIAG 服务）...
       69       1        1    7     1 ATH10k WLAN firmware service
       ↑ service 0x45 = 69 = WLFW_SERVICE_ID_V01

$ 写 fs_ready 触发后：
  [ 2893.857210] cnss: WLFW server arriving: node 7 port 1     ← 历史首次
  [ 2893.857216] cnss: Posting event: SERVER_ARRIVE(0), state: 0x8
  [ 2893.857250] cnss: QMI WLFW service connected, state: 0x9
  [ 2893.857260] cnss: Sending indication register message, state: 0x9
```

## 三、修复内容

### 3.1 改动（设备树，1 个文件 13 行）

`device/lenovo/p11_pro_plus/rootdir/etc/init.qcom.rc`，在
`on property:vold.decrypt=trigger_restart_framework` 之后补回：

```rc
service vendor.qrtr-ns /vendor/bin/qrtr-ns -f
    class core
    user vendor_qrtr
    group vendor_qrtr
    capabilities NET_BIND_SERVICE
```

（上面还加了 8 行中文注释说明根因，见文件）

### 3.2 与原厂的逐字节核对

```
$ diff <(debugfs -R "cat /etc/init/hw/init.qcom.rc" vendor_a.img) <我们的源文件>
  （修复前：缺 6 行 service 定义）
  （修复后：仅多出我加的注释行，服务定义本身逐字符相同）
```

### 3.3 配套条件（都已核实就绪，无需改动）

| 条件 | 状态 | 证据 |
|---|---|---|
| `qrtr-ns` 二进制 | ✅ 已在镜像内 | 我们镜像内那份与原厂 md5 **完全相同**（`3ffa07dde09dd4e927b7a1a73503be5f`）|
| SELinux 域 `vendor_qrtr` | ✅ 已编译进 vendor_sepolicy.cil | `device/qcom/sepolicy_vndr/legacy-um/qva/vendor/common/qrtr.te` |
| 文件上下文 | ✅ `vendor_qrtr_exec` | 我们镜像的 `vendor_file_contexts` 与原厂一致 |
| AID 2906 | ✅ vendor passwd/group 有 `vendor_qrtr` | 与原厂一致 |
| 内核放行 | ✅ `net/qrtr/qrtr.c:1446` `in_egroup_p(AID_VENDOR_QRTR)` 允许绑定 QRTR_PORT_CTRL | 内核源码 |

## 四、刷入与验证（可复核）

### 4.1 刷入

```
$ fastboot flash super super-qrtrns.img
  Sending sparse 'super' 1/11 ... 11/11          全 OKAY
  Finished. Total time: 70.761s

$ 分区尺寸实测（fastbootd getvar）
  system      0x39B6E000
  vendor      0x310D1000      ← 784.9 MiB（含新增 WLAN 模块）
  product     0x1BE22000
  system_ext  0x1A2D0000
  odm         0x18B000

$ fastboot set_active a && fastboot reboot
```

`super.img` 内 vendor_a 与 `out/vendor.img` md5 一致（`09a13f159cc078741eb88b493eef6659`），
确认刷入的镜像里含 `qrtr-ns` 服务定义。

### 4.2 启动验证（关键时间点）

```
$ 监控 uptime
  40.20s  adb OK
  71.34s  boot_completed=1            ← 历史 panic 点在 126s
  240.03s 仍正常，无 panic
  404.44s 仍正常，wlan0 已出现
```

```
$ dmesg | grep "Posting event" | head          （本次启动）
  19.627  Posting event: COLD_BOOT_CAL_START(5)
  20.355  Posting event: SERVER_ARRIVE(0)        ← 修复前【不存在】
  21.016  Posting event: REQUEST_MEM(2)          ← 修复前【不存在】
  21.028  Posting event: FW_MEM_READY(3)         ← 修复前【不存在】
  21.101  Posting event: FW_READY(4)             ← 修复前【不存在】
  25.551  Posting event: COLD_BOOT_CAL_DONE(6)
  25.555  Posting event: SERVER_EXIT(1)
  315.297 Posting event: REGISTER_DRIVER(7)-sync （驱动注册，用户态触发）
  315.801 Posting event: SERVER_ARRIVE(0)        （驱动侧再次连上固件）
```

```
$ dmesg | grep -i "Calibration"
  25.551122] cnss: Calibration completed successfully     ← 修复前是 Timeout (40000ms)

$ dmesg | grep -icE "Kernel panic|Resetting the SoC|Going down for restart"
  0                                                        ← 修复前每 126s 一次
```

### 4.3 WiFi 功能验证

```
$ ls /sys/class/net/
  bond0 dummy0 lo p2p0 rmnet_ipa0 sit0 wifi-aware0 wlan0   ← wlan0 出现

$ ip addr show wlan0
  10: wlan0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 ... state DOWN
      link/ether 00:03:7f:xx:xx:xx

$ dumpsys wifi | grep WifiState
  WifiState 1                                              ← WiFi 已启用
  （state DOWN / NO-CARRIER 属正常：尚未连接 AP）

$ 服务状态
  init.svc.vendor.qrtr-ns = running
  ps: 1105 vendor_qrtr qrtr-ns                             ← 以正确用户运行
  init.svc.vendor.wifi_hal_legacy = running
  init.svc.wificond = running
```

## 五、对上一轮判断的更正

**上一轮结论有误，此处明确更正。**

上一轮把根因归为「WLAN 驱动被编成内置（`CONFIG_QCA_CLD_WLAN=y`）导致固件请求过早」，
并据此改成 `=m`。**该判断不成立**，证据：

1. 改成 `=m` 并刷入后，panic 签名**一字不差**（`60.384s` 固件就绪超时、
   `103.392s` 校准超时、`125.920s` 二次超时、`126.0s` panic）。
2. 时间线显示发起固件请求的**不是** qcacld 驱动：
   - `19.66s` 固件请求（`cnss_pci` → `qca6390/amss20.bin`）
   - `61.42s` 才 `wlan: Loading driver v5.2.022.12B`

   两者相差 41 秒，且 19.66s 那次请求时 qcacld 模块尚未加载，
   所以 `=y` 还是 `=m` 对这条路径没有影响。发起者一直是内置的 `cnss2`。
3. 真正缺失的是用户态 `qrtr-ns`，与驱动的编译方式无关。

**处置**：`CONFIG_QCA_CLD_WLAN=m` 的改动**保留**（与原厂形态一致，利于后续维护），
但不再声称它是本次崩溃的修复手段。真正的修复是 `init.qcom.rc` 补回 `vendor.qrtr-ns`。

## 六、遗留事项

| 项 | 说明 |
|---|---|
| `wifidisplayhalservice` 循环重启 | 缺 `libpng.so`（`libwfdmmsrc_proprietary.so` 依赖），与本问题无关，可另行处理 |
| OTA zip 仍是旧 vendor | `lineage-21.0-20261013-*.zip` 里含旧镜像；如需发布需重跑 `bacon` |
| 未连接 AP 实测 | `wlan0` 已就绪但状态 `DOWN`；UI 连接 WiFi 即可验证（属用户操作） |
| `vbmeta` 与镜像不一致 | 设备上 vbmeta 是 `--flags 3`（校验已禁用），数值上不一致但不影响启动；若重刷 flags=0 的 vbmeta 会挂 |

## 七、现场文件

```
镜像产物
  super.img（含本修复）  2,676,043,368 B  （md5 261c57f3b2417e3bcc4817ea59deb34c）
  super.img（修复前）    2,676,043,368 B
  boot.img（含模块化内核） 100,663,296 B

设备树源码改动:
  device/lenovo/p11_pro_plus/rootdir/etc/init.qcom.rc
  git commit 32c9d56

证据文件（本仓库 tools/ 下的脚本可重新采集）:
  启动验证 dmesg/monitor   —— 缺陷 1 修复后的启动过程
  recovery 手动 A/B 实验    —— SERVER_ARRIVE 首次出现
  修复前崩溃日志            —— 对照用（见 docs/rootcause-wlan-panic.md）
```

---

## 八、后续发现：WiFi 框架层第二个独立问题（未解决）

修复 `qrtr-ns` 后，**内核/驱动层与固件通信完全正常**，但 WiFi 在框架层仍打不开。
这是**另一个独立问题**，与启动崩溃无关。

### 8.1 现象

```
$ svc wifi enable; cmd wifi status
  Wifi is disabled
  Wifi scanning is only available when wifi is enabled
```

框架日志：

```
E/WifiVendorHal: Failed to create STA iface
E/WifiNative: Failed to create iface in vendor HAL
E/HalDevMgr: createIface: no chip info found
E/WifiClientModeManager: Failed to create ClientInterface. Sit in Idle
W/WifiHalAidlImpl: IWifi binder died.
E/WifiSelfRecovery: Already restarted wifi 2 times in last 1 hour. Disabling wifi
```

驱动侧反而**完全正常**（证明修复有效）：

```
wlan: [I:HDD] wlan_hdd_state_ctrl_param_write: Wifi Turning On from UI
wlan: [I:PMO] pmo_core_enable_wow_in_fw: drv wow is enabled
wlan: [I:WMI] send_wow_enable_cmd_tlv: suspend type: WOW_IFACE_PAUSE_ENABLED
```

### 8.2 精确根因（tombstone 证据）

```
signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0000000000000102
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

即：HAL 服务在 `configureChip` → `getDriverVersion` 时调用
`wifi_reset_passpoint_list`，**函数指针为空**（fault addr `0x102`），段错误。

### 8.3 机制（待修的假设，尚未用实验证实）

- `libwifi-hal.so`（`frameworks/opt/net/wifi/libwifi_hal/Android.bp:209`）
  只提供**框架通用层**，vendor 特有实现靠 `libwifi_hal_vendor_impl_defaults`
  按 `board_wlan_device` 选择：
  `qcwcn` → `defaults: ["libwifi-hal-qcom"]`（同文件 `:162-164`）
- `libwifi-hal-qcom.so` 确实定义了 72 个 `wifi_*` 符号，含
  `wifi_reset_passpoint_list` / `wifi_set_passpoint_list`
- 但 `android.hardware.wifi-service` 的 `NEEDED` 里**只有 `libwifi-hal.so`**，
  没有 `libwifi-hal-qcom.so`
- 因此调用落到未初始化的桩上 → 空指针

**需要的验证**（下一步）：
1. 确认 `board_wlan_device` 在本次构建里是否被设为 `qcwcn`
   （`grep -r board_wlan_device device/lenovo/p11_pro_plus/`，及 soong 变量注入）
2. 若未设置，`libwifi-hal.so` 里 vendor 实现为空 → 需补
   `SOONG_CONFIG_..._board_wlan_device := qcwcn` 或等效配置
3. 验证方式：修复后重编 vendor，检查
   `readelf -d android.hardware.wifi-service | grep -i wifi-hal`

### 8.4 与原厂形态的差异

| | 原厂 | 我们 |
|---|---|---|
| wifi HAL 二进制 | `android.hardware.wifi@1.0-service`（HIDL，463,600 B） | `android.hardware.wifi-service`（AIDL，517,904 B） |
| `libwifi-hal.so` | 460,800 B（md5 `a036796e...`） | **同 md5**（是同一个 blob） |
| `libwifi-hal-qcom.so` | 有（450,648 B） | 有 |

`libwifi-hal.so` 双方 md5 相同（都是从原厂 vendor 提取的同一文件），
说明问题不在 blob 本身，而在**我们用的 HAL 服务（AIDL）与这个 blob 的配合**：
原厂 HIDL 服务自己带完整实现，AIDL 服务则需要 `libwifi-hal-qcom` 一起链接。

### 8.5 不阻塞已完成的修复

本节问题**不影响**第七节之前的结论：启动崩溃循环已消除、系统稳定、
驱动与固件通信正常、`wlan0` 已创建。它只影响 WiFi 的框架层开关。

### 8.6 【已修复】根因确认与改动

后续调查证实了 8.3 节的假设，并进一步定位到**blob 覆盖**这一具体原因。

**决定性证据（readelf -sW 符号大小，单位字节）：**

| 函数 | 原厂 blob（曾进镜像） | 源码编译版 |
|---|---|---|
| `wifi_get_driver_version` | **8** | **16** |
| `wifi_reset_passpoint_list` | **44** | **72** |
| `wifi_set_passpoint_list` | 4 | 4 |

blob 版这两个函数短到只剩空桩实现；崩溃栈正是
`getDriverVersion+92` → `wifi_reset_passpoint_list+28`。

**机制链：**

```
proprietary-files.txt:1686  vendor/lib64/libwifi-hal.so   ← 原厂 blob
        ↓ 作为 PRODUCT_COPY_FILES 覆盖
AOSP 编译版 frameworks/opt/net/wifi/libwifi_hal/libwifi-hal.so（含 qcwcn 实现）被覆盖掉
        ↓
镜像里的 libwifi-hal.so 变成空桩版（其 qcwcn 实现靠 HIDL 服务自己带）
        ↓
AIDL 服务 android.hardware.wifi-service 链接它，
configureChip → getDriverVersion → wifi_reset_passpoint_list 解引用空指针
        ↓
SIGSEGV (fault addr 0x102) → wifi HAL 反复崩溃 → WiFi 被框架自动禁用
```

**改动**（commit `ca00c21`）：注释掉 `proprietary-files.txt` 里
`vendor/lib64/libwifi-hal.so` 一行，并重新生成 `p11_pro_plus-vendor.mk`
（`vendor.mk` 里该条已消失，`libwifi-hal-qcom` 保留）。

**编译验证：**

```
$ readelf -sW out/.../vendor/lib64/libwifi-hal.so | grep -E 'get_driver_version|reset_passpoint'
  wifi_reset_passpoint_list    72 B     ← 由空桩(44B)恢复为真实实现
  wifi_get_driver_version      16 B     ← 由空桩(8B)恢复为真实实现

$ mka vendorimage   → build completed successfully (01:54)
$ mka superimage    → rc=0
  vendor.img = 822,927,360 B
  super.img  = 2,676,031,080 B  (md5 bdd5f2909195ad993391c7ed9c2e2cbb)
```

待刷入验证（下一步）。

---

## 九、第三层问题：HIDL blob 覆盖 AIDL 服务栈（已修复，待刷入验证）

第二层（`libwifi-hal.so`）修复刷入后，**wifi HAL 不再崩溃**
（`/data/tombstones/` 里最新一个仍是修复前的 `tombstone_05`，无新增；
`IWifi binder died` / `Failed to create ClientInterface` 全部消失），
`iw dev` 显示驱动侧完全就绪：

```
$ iw dev
phy#0
	Interface wifi-aware0        type NAN
	Interface p2p0               type ...
```

但 `wlan0` 仍停在 `DOWN`，框架报 supplicant 服务找不到：

```
W/ServiceManagerCppClient: Waited one second for
    android.hardware.wifi.supplicant.ISupplicant/default
I/servicemanager: Since 'android.hardware.wifi.supplicant.ISupplicant/default'
    could not be found ... trying to start it as a lazy AIDL service.
I/servicemanager: Tried to start aidl service ... as a lazy service, but was
    unable to. Usually this happens when a service is not installed...
```

### 9.1 根因（同一模式的第三处）

框架的 VINTF manifest 声明的是 **AIDL**：

```
/vendor/etc/vintf/manifest/android.hardware.wifi.supplicant.xml
  <hal format="aidl">
    <name>android.hardware.wifi.supplicant</name>
    <version>3</version>
    <fqname>ISupplicant/default</fqname>
```

但 `proprietary-files.txt` 用**原厂 HIDL 版二进制**覆盖了它。实测：

```
$ /vendor/bin/hw/wpa_supplicant
CANNOT LINK EXECUTABLE "/vendor/bin/hw/wpa_supplicant": library
"android.hardware.wifi.supplicant@1.2.so" not found: needed by main executable
```

原厂二进制的 `NEEDED` 里有四个 HIDL 库：

```
android.hardware.wifi.supplicant@1.0.so
android.hardware.wifi.supplicant@1.1.so
android.hardware.wifi.supplicant@1.2.so   ← 我们镜像里没有
android.hardware.wifi.supplicant@1.3.so   ← 我们镜像里没有
```

> 注：`@1.0.so` / `@1.1.so` 我们镜像里有，是 AOSP 为
> `libkeystore-wifi-hidl` 等编译的，与 supplicant 本体无关。

### 9.2 与 libwifi-hal 是同一类错误

| | 框架要的 | blob 给的 | 结果 |
|---|---|---|---|
| libwifi-hal.so | AIDL 服务栈 + qcwcn 实现 | HIDL 配的空桩 | `wifi_reset_passpoint_list` SIGSEGV |
| wpa_supplicant | AIDL v3 (`ISupplicant/default`) | HIDL（依赖 `@1.2.so`） | 动态链接失败，服务起不来 |
| hostapd | AIDL (`IHostapd/default`) | HIDL（依赖 `@1.0~1.2`） | 同上 |
| 两个 .rc | `interface aidl ...` | `interface ...@1.x::...` | 声明与实现不匹配 |

### 9.3 改动（commit `a96a4ac`）

移除 6 项 blob，全部由 AOSP 编译版取代（`device.mk:362-368` 已声明
`PRODUCT_PACKAGES += hostapd wpa_supplicant ...`，无需新增配置）：

```
# vendor/bin/hw/wpa_supplicant     -> external/wpa_supplicant_8/wpa_supplicant (AIDL v3)
# vendor/bin/hw/hostapd            -> external/wpa_supplicant_8/hostapd
# vendor/bin/hostapd_cli           -> 同上
# vendor/bin/wpa_cli               -> 同上
# vendor/etc/init/android.hardware.wifi.supplicant-service.rc
#     -> LOCAL_INIT_RC 自动安装 AIDL 版 (interface aidl ...ISupplicant/default)
# vendor/etc/init/hostapd.android.rc
#     -> LOCAL_INIT_RC 自动安装 AIDL 版 (interface aidl ...IHostapd/default)
```

保留（对照，未动）：`cnss-daemon`、`libwifi-hal-qcom`、`libwifi-hal-ctrl`。

重新生成 `p11_pro_plus-vendor.mk` 后逐项核对：

```
  bin/hw/wpa_supplicant      0      (已移除)
  bin/hw/hostapd             0      (已移除)
  bin/hostapd_cli            0      (已移除)
  bin/wpa_cli                0      (已移除)
  supplicant-service.rc      0      (已移除)
  hostapd.android.rc         0      (已移除)
  libwifi-hal.so             0      (已移除)
  cnss-daemon                1      (保留)
  libwifi-hal-qcom           2      (保留)
  libwifi-hal-ctrl           2      (保留)
```

### 9.4 状态

编译中，待刷入验证。验证判据：

```
readelf -d out/.../vendor/bin/hw/wpa_supplicant | grep NEEDED    # 不应有 @1.2/@1.3
/ 设备上 /vendor/bin/hw/wpa_supplicant 能执行（之前报 not found）
  wlan0 能 UP、cmd wifi status 有输出、可扫描到 AP
```
