# Lenovo TB-J716F (p11_pro_plus) — LineageOS 21 WLAN 修复

联想小新 Pad Pro 2021（TB-J716F / 代号 `p11_pro_plus`，Snapdragon 870 / SM8250-AC）
在 LineageOS 21（Android 14）上 WLAN 完全不可用，并伴随**开机 panic 重启循环**。

本仓库包含完整的排查过程与修复所需的全部源码改动。

> **状态：四个缺陷已全部修复，并经真机验证。**
> 设备稳定运行、`wpa_supplicant` 自启动、WiFi 可扫描到 AP。
> 目标读者：为同一台设备（或其他 SM8250 + QCA6390 设备）编译 LineageOS 的开发者。

---

## 问题全貌：四个独立缺陷

表面上都是"WiFi 不工作"，实际是四个**互不相同**的缺陷依次暴露——
每修好一个，下一个才浮现。

| # | 缺陷 | 层次 | 症状 | 提交 |
|---|---|---|---|---|
| 1 | `init.qcom.rc` 缺 `vendor.qrtr-ns` 服务定义 | 内核 / 固件 | 开机 **126 秒必 panic 重启**（死循环） | `32c9d56` |
| 2 | `libwifi-hal.so` 被原厂 blob 覆盖成空桩 | HAL | wifi HAL 反复 **SIGSEGV** | `ca00c21` |
| 3 | `wpa_supplicant` / `hostapd` 用 HIDL blob 覆盖 AIDL 栈 | HAL 框架 | supplicant **动态链接失败** | `a96a4ac` |
| 4 | `init.qcom.rc` 存在第二份 `service wpa_supplicant` | init | AIDL interface **注册失败**，supplicant 不被拉起 | `a49600a` |

缺陷 2/3/4 是**同一错误模式的三种表现**：用原厂 blob（或原厂 rc 定义）
覆盖了我们自编的 AOSP 组件，而原厂组件与框架声明的 HAL 接口
**版本/传输方式不匹配**（HIDL vs AIDL）。

---

## 缺陷 1：缺 `vendor.qrtr-ns` → 开机 panic（最严重）

### 症状

```
[   19.662564] cnss_pci 0000:01:00.0: Falling back to syfs fallback for: qca6390/amss20.bin
[   60.384018] cnss: fatal: Timeout waiting for FW ready indication
[  103.392113] cnss: Timeout (40000ms) waiting for calibration to complete
[  126.024382] Kernel panic - not syncing: subsys-restart: Resetting the SoC - wlan crashed.
```

### 机制链

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

### 决定性证据：同机同内核 A/B 实验

在 recovery 模式（该模式下 init 不会自动启动 `qrtr-ns`）做对照实验：

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
       69       1        1    7     1 ATH10k WLAN firmware service
       ↑ service 0x45 = 69 = WLFW_SERVICE_ID_V01

$ 写 fs_ready 触发后：
  [ 2893.857210] cnss: WLFW server arriving: node 7 port 1     ← 历史首次
  [ 2893.857250] cnss: QMI WLFW service connected, state: 0x9
```

### 修复与效果

补回 6 行服务定义（与原厂逐字节一致）：

```rc
service vendor.qrtr-ns /vendor/bin/qrtr-ns -f
    class core
    user vendor_qrtr
    group vendor_qrtr
    capabilities NET_BIND_SERVICE
```

| 项 | 修复前 | 修复后 |
|---|---|---|
| 系统稳定性 | 126s 必 panic 循环 | 稳定运行无 panic |
| 冷启动校准 | `Timeout (40000ms)` | `Calibration completed successfully`（25.5s） |
| cnss 事件流 | 仅 4 条 | 完整（含 `SERVER_ARRIVE`） |

---

## 缺陷 2：`libwifi-hal.so` 空桩 → HAL 段错误

启动崩溃修好后 WiFi 仍打不开，wifi HAL 反复崩溃，tombstone 精确指向：

```
signal 11 (SIGSEGV), fault addr 0x102   Cause: null pointer dereference
Cmdline: /vendor/bin/hw/android.hardware.wifi-service
backtrace:
  #00 libwifi-hal.so (wifi_reset_passpoint_list.cfi+28)
  #01 android.hardware.wifi-service (WifiLegacyHal::getDriverVersion()+92)
  ...
```

**根因**：`proprietary-files.txt` 里的 `vendor/lib64/libwifi-hal.so`
把 AOSP 源码编译版覆盖掉了。原厂那份是给 **HIDL** 服务配的，
vendor 实现留空。**决定性证据**（`readelf -sW` 符号大小，单位字节）：

| 函数 | 原厂 blob（曾进镜像） | 源码编译版 |
|---|---|---|
| `wifi_get_driver_version` | **8**（空桩） | **16** |
| `wifi_reset_passpoint_list` | **44** | **72** |

崩溃栈正是 `getDriverVersion+92` → `wifi_reset_passpoint_list+28`。

**修复**：注释掉 `proprietary-files.txt` 中该行，改用源码编译版。

---

## 缺陷 3 & 4：supplicant 起不来（两个叠加原因）

### 缺陷 3：HIDL blob 覆盖 AIDL 服务栈

框架 VINTF manifest 声明的是 **AIDL v3**：

```xml
<hal format="aidl">
  <name>android.hardware.wifi.supplicant</name>
  <version>3</version>
  <fqname>ISupplicant/default</fqname>
```

但 `proprietary-files.txt` 用原厂 **HIDL 版**二进制覆盖了它：

```
$ /vendor/bin/hw/wpa_supplicant
CANNOT LINK EXECUTABLE "/vendor/bin/hw/wpa_supplicant": library
"android.hardware.wifi.supplicant@1.2.so" not found: needed by main executable
```

原厂二进制的 `NEEDED` 含 `@1.0/@1.1/@1.2/@1.3.so` 四个 HIDL 库，
镜像里只有 `@1.0/@1.1`（AOSP 为其它组件编的），故链接失败。

**修复**（`a96a4ac`）：移除 6 项 blob，交给 AOSP 编译版：

```
wpa_supplicant / hostapd / hostapd_cli / wpa_cli
android.hardware.wifi.supplicant-service.rc / hostapd.android.rc
```

### 缺陷 4：init.qcom.rc 里的同名第二份定义

上一修复后二进制可执行了，但**仍不自动启动**：

```
init: Control message: Could not find
    'aidl/android.hardware.wifi.supplicant.ISupplicant/default' for ctl.interface_start
W/ServiceManagerCppClient: Waited one second for
    android.hardware.wifi.supplicant.ISupplicant/default
```

**关键反证**（证明是 interface 注册问题，而非服务缺失）：

```
$ setprop ctl.start wpa_supplicant     ← 服务名存在，能启动！
  init.svc.wpa_supplicant=running
$ 手动启动后 cmd wifi status 立刻变为 "Wifi is enabled"
```

**根因**：设备树 `init.qcom.rc` 保留了原厂 HIDL 时代的
**第二份 `service wpa_supplicant`**（声明
`interface android.hardware.wifi.supplicant@1.0::ISupplicant default` 等）。
它与 AOSP 的 AIDL 定义**同名**，`ServiceParser::ParseInterface`
遇到重复 interface 会报错并丢弃，导致 AIDL interface 从未注册。

**修复**（`a49600a`）：注释掉该重复定义，交由 AOSP 的 rc 提供唯一权威定义。

---

## 最终验证结果（真机实测）

```
$ getprop sys.boot_completed                 1
$ getprop init.svc.vendor.qrtr-ns            running
$ getprop init.svc.wpa_supplicant            running
$ ps -A -o USER,NAME | grep wpa_supplicant   wifi  wpa_supplicant
$ settings get global wifi_on                1
$ cmd wifi list-scan-results                 实测扫描到 19 个 AP（含 2.4G/5G）
$ dmesg | grep -c "Kernel panic"             0
$ uptime                                     217s+（历史 panic 点在 126s）
```

---

## 仓库内容

```
patches/
  device-tree/          设备树仓库的 6 个提交
    0001  修复 wlan 固件符号链导致的 vendorimage 缺源
    0002  补齐基础 WCNSS 配置（内置驱动所需）
    0003  补回 init.qcom.rc 缺失的 vendor.qrtr-ns 服务定义      ← 缺陷 1
    0004  不再用原厂 libwifi-hal.so blob 覆盖                   ← 缺陷 2
    0005  不再用原厂 HIDL blob 覆盖 AIDL 服务栈（supplicant/hostapd） ← 缺陷 3
    0006  移除 init.qcom.rc 里第二份 wpa_supplicant 定义        ← 缺陷 4
  kernel/               内核仓库的 1 个提交
    0001  kona-perf: WLAN 驱动改为模块构建
docs/
  fix-report-final.md       完整修复报告（四个缺陷 + 真机验证，推荐先读）
  fix-verification.md       排查过程记录（含中间阶段的试错与更正）
  rootcause-wlan-panic.md   早期根因分析（缺陷 1，含已排除的假设）
tools/
  collect-evidence.sh       崩溃循环中抢抓 pstore / dmesg / logcat 证据
  verify-boot.sh            刷入后验证：是否越过 panic 点、wlan0 是否出现
  rebuild-vendor-super.sh   重建 vendor/super 镜像并自动校验修复是否生效
```

## 上游基线

补丁基于以下上游提交，已验证可**干净应用**：

| 仓库 | 分支 | 基线 commit |
|---|---|---|
| `ungeskriptet/android_device_lenovo_p11_pro_plus` | `lineage-21` | `ac8ab86` |
| `ungeskriptet/android_kernel_lenovo_sm8250` | `lineage-21` | `50476ae` |

---

## 使用方法

### 方式一：应用补丁（最通用）

```bash
# 设备树
git clone -b lineage-21 https://github.com/ungeskriptet/android_device_lenovo_p11_pro_plus
cd android_device_lenovo_p11_pro_plus
git am /path/to/patches/device-tree/*.patch

# 内核
git clone -b lineage-21 https://github.com/ungeskriptet/android_kernel_lenovo_sm8250
cd android_kernel_lenovo_sm8250
git am /path/to/patches/kernel/*.patch
```

### 方式二：直接使用 fork（已含全部修复）

以下 fork 已包含上述全部提交：

- 设备树：`https://github.com/wanfanggreat/android_device_lenovo_p11_pro_plus`（分支 `lineage-21`）
- 内核：`https://github.com/wanfanggreat/android_kernel_lenovo_sm8250`（分支 `lineage-21`）

在 `.repo/local_manifests/` 里把这两个项目的来源指向上面的 fork 即可：

### 编译与刷入

```bash
LINEAGE=~/android/lineage ./tools/rebuild-vendor-super.sh
```

或手工：

```bash
source build/envsetup.sh
lunch lineage_p11_pro_plus-ap2a-userdebug
mka -j$(nproc) vendorimage superimage
```

> **必须重建 `super.img`**：WLAN 驱动改为模块构建后 vendor 分区变大
> （实测 775.4 → 784.8 MiB），设备上的 `vendor_a` 装不下旧尺寸，
> 需由 `super.img` 重新分配。

```bash
fastboot flash super super.img
fastboot flash boot  boot.img
fastboot set_active a
fastboot reboot
```

### 验证

```bash
adb shell 'getprop init.svc.vendor.qrtr-ns'     # running
adb shell 'getprop init.svc.wpa_supplicant'     # running
adb shell 'ls /sys/class/net/ | grep wlan'      # wlan0 存在
adb shell 'ls /vendor/lib/modules/qca_cld3*'    # 模块就位
adb shell 'dmesg | grep SERVER_ARRIVE'          # 事件流完整
adb shell 'cmd wifi list-scan-results'          # 能扫到 AP
# 关键：开机 3 分钟以上不 panic
```

---

## 关键调试技巧

**pstore 是唯一可靠的证据源。** 设备反复重启时 adb/logcat 往往来不及抓取，
而 pstore 保留上次崩溃的完整内核日志：

```bash
adb root
adb shell 'cat /sys/fs/pstore/console-ramoops-0'   # 上次崩溃的完整日志
```

用 `tools/collect-evidence.sh` 可自动在重启循环中抢抓。

**其他踩过的坑：**

- **原厂 `.ko` 模块通常无法加载**，因为 `vermagic` 与自编内核不匹配
  （实测原厂 `4.19.157` vs 自编 `4.19.312`）。必须用自编模块。
- **Android 14 已无 VNDK 目录**，vendor 命名空间
  （`/linkerconfig/ld.config.txt`）不再包含 `/system/${LIB}`，
  vendor 侧依赖需用 `.vendor` 变体并真正打进 vendor 镜像。
- **`repo status` 在 detached HEAD 的树上会漏报本地提交**——
  它只检查工作区文件差异。要查"我改过什么"应使用：
  `git rev-list HEAD --not --remotes`

---

## 适用范围与已知限制

- 针对 **TB-J716F / p11_pro_plus**（QCA6390）验证。其他 SM8250 设备可能有
  类似问题，但路径与包名不同，需自行核对。
- 缺陷 1 的初诊曾误判为内核 defconfig 问题（`CONFIG_QCA_CLD_WLAN=y`），
  已用 A/B 实验更正；`=m` 的改动保留（与原厂形态一致），但**它不是
  崩溃的修复手段**。详见 `docs/fix-report-final.md` 第六节。
- 无线投屏（`wifidisplayhalservice`）另有独立问题（缺 `libpng.so`），
  不在本仓库范围。
- 未实测实际联网（需在 UI 输入密码），仅验证到可扫描 AP。

## 许可

本仓库的**文档与工具**采用 Apache-2.0（与 LineageOS 设备树一致），详见 [LICENSE](LICENSE)。

补丁沿用其上游代码的许可：

| 补丁 | 适用许可 |
|---|---|
| `patches/device-tree/` | Apache-2.0（设备树上游为 LineageOS 设备树） |
| `patches/kernel/` | **GPL-2.0**（Linux 内核） |

原始代码版权归 The LineageOS Project、The Linux Foundation 及其他原作者所有。
补丁仅修改配置与构建规则，不改变上游许可条款。
