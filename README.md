# Lenovo TB-J716F (p11_pro_plus) — LineageOS 21 修复集

联想小新 Pad Pro 2021（TB-J716F / 代号 `p11_pro_plus`，Snapdragon 870 / SM8250-AC）
在 LineageOS 21（Android 14）上的移植修复记录：**WLAN、传感器栈、音频（含 4 颗
CS35L41 扬声器功放）、指纹**。

本仓库包含完整的排查过程与修复所需的全部源码改动（补丁形式）。

> **状态：下列缺陷均已修复并经真机验证。**
> 设备稳定运行、WiFi 可扫描到 AP、45 个传感器全部在位、声卡已注册、
> 麦克风采集正常、4 扬声器全部出声、指纹可用。
> 目标读者：为同一台设备（或其他 SM8250 设备）编译 LineageOS 的开发者。

---

## 问题全貌

表面现象各不相同，实际可分为几组**互相独立**的缺陷。
其中两条贯穿始终的线索是：

1. **用原厂 blob 覆盖自编 AOSP 组件**，导致 ABI 或 HAL 接口版本
   （HIDL vs AIDL）不匹配；
2. **VINTF 重复声明**——AOSP 模块已自带 fragment，又在 `manifest.xml`
   手写一份，导致 manifest 解析失败、卡第一屏。

### 第一组：WLAN（4 个缺陷）

| # | 缺陷 | 层次 | 症状 | 提交 |
|---|---|---|---|---|
| 1 | `init.qcom.rc` 缺 `vendor.qrtr-ns` 服务定义 | 内核 / 固件 | 开机 **126 秒必 panic 重启**（死循环） | `32c9d56` |
| 2 | `libwifi-hal.so` 被原厂 blob 覆盖成空桩 | HAL | wifi HAL 反复 **SIGSEGV** | `ca00c21` |
| 3 | `wpa_supplicant` / `hostapd` 用 HIDL blob 覆盖 AIDL 栈 | HAL 框架 | supplicant **动态链接失败** | `a96a4ac` |
| 4 | `init.qcom.rc` 存在第二份 `service wpa_supplicant` | init | AIDL interface **注册失败**，supplicant 不被拉起 | `a49600a` |

缺陷 2/3/4 是**同一错误模式的三种表现**：用原厂 blob（或原厂 rc 定义）
覆盖了我们自编的 AOSP 组件，而原厂组件与框架声明的 HAL 接口
**版本/传输方式不匹配**（HIDL vs AIDL）。

### 第二组：传感器栈（3 个缺陷）

| # | 缺陷 | 层次 | 症状 | 提交 |
|---|---|---|---|---|
| 5 | 传感器栈缺失（SSC blob 未打包） | HAL | `dumpsys sensorservice` 报 **No Sensors on the device** | `22cfba36` |
| 6 | VINTF 重复声明同一 sensors HAL | VINTF | **卡第一屏**（无开机动画，无 panic） | `22cfba36` |
| 7 | 原厂 `libssrec.so` 与重建 HAL 的 ABI 不匹配 | HAL | audioserver **崩溃循环**，卡开机动画 | `22cfba36` |

### 第三组：音频内核与功放（4 个缺陷）

| # | 缺陷 | 层次 | 症状 | 提交 |
|---|---|---|---|---|
| 8 | 内核 DAI 链引用不存在的 wsa-macro | 内核音频 | `/proc/asound/cards` 为空，**无声卡** | `8b250d7d` |
| 9 | 跳过 WSA 链路时漏掉 `msm_int_audrx_init` | 内核音频 | **麦克风采集失效**（录音是静音） | `b8e1bed9` |
| 10 | 采集 `app_type` 用错（69938） | 音频 HAL 配置 | 麦克风**数字静音**（能出文件但全 0） | `e1347e04` |
| 11 | 缺少 `SPKn AMP Enable Switch` 控件 | 内核功放 | 4 扬声器**只响 2 个** | `ed5347ca6` |

> 缺陷 9 是缺陷 8 引入的回归，两个补丁需一并应用。
> 缺陷 11 的接口规格来自对原厂 `audio_cirrus_cs35l41.ko` 的反汇编
> （`SOC_SINGLE` 不补 " Switch" 后缀；原厂用 `regmap_write` 而非读改写）。
> 该修复经历了一次 Revert 后重做，补丁集中保留了完整的 Revert 对。

### 第四组：指纹（2 个缺陷）

| # | 缺陷 | 层次 | 症状 | 提交 |
|---|---|---|---|---|
| 12 | GoodIX 指纹 HAL 与 qfp-daemon 全漏提取 | vendor | 设置里**没有指纹入口** | `07a8bb224` |
| 13 | 指纹 HAL 的 VINTF 安装/声明方式错误 | VINTF | 重复声明 → **卡第一屏** | `49dc142bf` |

缺陷 13 与缺陷 6 是同一个坑的第二次出现：AOSP 的
`android.hardware.biometrics.fingerprint@2.1-service` 模块自带
`vintf_fragments`，不能又在 `manifest.xml` 里手写一遍。

### 反复踩到的两个坑（值得记住）

- **卡第一屏 ≠ 内核 panic。** 缺陷 6、7、13 都表现为卡屏，但 pstore 为空。
  分别是 VINTF 解析失败、HAL 崩溃循环、VINTF 重复声明。
  **必须靠 logcat 区分现象相近的问题**，不能只看 pstore。
- **判断 ABI 类问题的特征**：tombstone backtrace 里
  `/vendor/lib/*.so`（原厂 blob）与 `/vendor/lib/hw/*.so`（重建 HAL）交替出现，
  优先怀疑 ABI 而非逻辑 bug。本设备已出现 3 次同类模式。

### 最终验证结果（真机实测）


```
sys.boot_completed                        1
dumpsys sensorservice                     Total 45 h/w sensors, 45 running
/proc/asound/cards                        kona-mtp-snd-card
audio 输出                                framesWritten:292800（音频真的流过声卡）
audio 输入设备                             Built-In Mic / Built-In Back Mic / Telephony Rx
HAL 服务                                  12 个全 running，init.svc.*restarting 计数 0
pm list features                          89 项
cmd wifi list-scan-results                可扫描到 AP
uptime                                    越过历史 panic 点（126s），无重启
```

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
  device-tree/          设备树仓库的 10 个提交
    0001  修复 wlan 固件符号链导致的 vendorimage 缺源
    0002  补齐基础 WCNSS 配置（内置驱动所需）
    0003  补回 init.qcom.rc 缺失的 vendor.qrtr-ns 服务定义      ← 缺陷 1
    0004  不再用原厂 libwifi-hal.so blob 覆盖                   ← 缺陷 2
    0005  不再用原厂 HIDL blob 覆盖 AIDL 服务栈（supplicant/hostapd） ← 缺陷 3
    0006  移除 init.qcom.rc 里第二份 wpa_supplicant 定义        ← 缺陷 4
    0007  补齐 SSC 传感器栈、修开机卡首屏与无声卡               ← 缺陷 5/6/7
    0008  采集 app_type 69938 -> 69948，修复麦克风数字静音       ← 缺陷 10
    0009  补回 GoodIX 指纹 HAL 与 qfp-daemon                    ← 缺陷 12
    0010  GoodIX 指纹 HAL 注册 VINTF（修正安装方式）             ← 缺陷 13
  kernel/               内核仓库的 12 个提交
    0001  kona-perf: WLAN 驱动改为模块构建
    0002  kona 声卡不再挂载 wsa_macro DAI，并修 mic-bias 电压属性 ← 缺陷 8
    0003  麦克风采集失效：msm_int_audrx_init 从 WSA 链路迁到 RX 链路 ← 缺陷 9
    0004  移植 CS35L41 扬声器功放驱动（4 颗 I2C smart amp）      ← 缺陷 11
    0005  kona.c 支持 cirrus,prince-devs —— 把 4 颗 CS35L41 挂进声卡
    0006  拆分 CS35L41 为 wm_adsp + cs35l41 两个模块（与原厂一致）
    0007  模块文件名改为 audio_cirrus_{wm_adsp,cs35l41}.ko
    0008  功放改走 BE dai_link，修首屏 panic 循环
    0009  kona.c 补 DMIC EN/SEL 控件与 DT GPIO 解析
    0010  补回 AMP Enable 控件（第一版，随后被 Revert）
    0011  Revert "补回 AMP Enable 控件"                        ← 保留完整历史
    0012  补回 AMP Enable Switch 控件（4 扬只响 2 个）           ← 缺陷 11 的最终修复
docs/
  fix-report-final.md         WLAN 完整修复报告（缺陷 1~4 + 真机验证）
  fix-report-sensors-audio.md 传感器/音频修复报告（缺陷 5~9 + 真机验证）
  fix-verification.md         WLAN 排查过程记录（含中间阶段的试错与更正）
  rootcause-wlan-panic.md     WLAN 早期根因分析（缺陷 1，含已排除的假设）
tools/
  collect-evidence.sh       崩溃循环中抢抓 pstore / dmesg / logcat 证据
  verify-boot.sh            刷入后验证：是否越过 panic 点、wlan0 是否出现
  rebuild-vendor-super.sh   重建 vendor/super 镜像并自动校验修复是否生效
```

> **补丁需按编号顺序应用**，尤其是内核的 0010~0012
> （补丁 → Revert → 重做）三者构成一条完整的历史链，顺序不能打乱。


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
# 启动
adb shell getprop sys.boot_completed                # 1
adb shell 'getprop | grep restarting'               # 应为空（无服务崩溃循环）

# WLAN
adb shell 'getprop init.svc.vendor.qrtr-ns'         # running
adb shell 'getprop init.svc.wpa_supplicant'         # running
adb shell 'ls /sys/class/net/ | grep wlan'          # wlan0 存在
adb shell 'ls /vendor/lib/modules/qca_cld3*'        # 模块就位
adb shell 'dmesg | grep SERVER_ARRIVE'              # 事件流完整
adb shell 'cmd wifi list-scan-results'              # 能扫到 AP

# 传感器
adb shell dumpsys sensorservice | grep 'h/w sensors'  # Total 45 ... 45 running

# 音频
adb shell 'cat /proc/asound/cards'                  # kona-mtp-snd-card
adb shell 'dmesg | grep -E "skip wsa_macro|Sound card .* registered"'

# 麦克风（缺陷 9/10 的症状都是"能生成 .m4a 但内容静音"）
adb shell 'tinymix -D 0 | grep -E "TX_CDC_DMA_TX_3|DMIC"'
# 走 tinycap 绕开 HAL 录一段，确认不是数字静音：
adb shell 'tinycap /sdcard/t.wav -D 0 -d 2 -c 2 -r 48000 -b 16 -T 3'
adb pull /sdcard/t.wav && sox t.wav -n stat    # Maximum amplitude 应远大于 0

# 扬声器（4 颗 CS35L41 应全部有声）
adb shell 'tinymix -D 0 | grep -E "SPK[1-4] AMP Enable Switch"'   # 应存在且为 1
adb shell 'cat /sys/kernel/debug/asoc/kona-mtp-snd-card/dais' 2>/dev/null

# 指纹
adb shell 'getprop | grep -iE "fingerprint|goodix"'
adb shell 'service list | grep -i fingerprint'      # IBiometricsFingerprint
adb shell 'dumpsys fingerprint' 2>/dev/null | head -20

# VINTF 合法性（在主机上对镜像做，比刷机快得多）
sudo mount -o ro,loop out/target/product/p11_pro_plus/vendor.img /tmp/vnew
out/host/linux-x86/bin/checkvintf --check-one --dirmap /vendor:/tmp/vnew
sudo umount /tmp/vnew
# 期望：Successfully processed VINTF information
```

> **关键：开机 3 分钟以上不 panic 且无 `init.svc.*restarting`。**

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
- **"卡开机画面"未必是内核 panic。** 缺陷 6/8 都是卡屏但 pstore 为空——
  分别是 VINTF 解析失败和 HAL 崩溃循环。必须靠 logcat 区分现象相近的问题。
- **VINTF 冲突可在主机上先验。** 用 `checkvintf --check-one --dirmap`
  对 `vendor.img` 做静态检查，比刷机排查快得多（见上方验证一节）。
- **vendor 镜像内空间极小时，`debugfs` 可直接原地修改**。用
  `mount -o loop,rw` 会因日志分配报 `ENOSPC`，而 `debugfs` 不会——
  这能大幅加快 VINTF 这类只涉及 vendor 的迭代验证（改完只刷 vendor 分区）。

---

## 适用范围与已知限制

- 针对 **TB-J716F / p11_pro_plus**（QCA6390 + CS35L41 功放）验证。
  其他 SM8250 设备可能有类似问题，但路径与包名不同，需自行核对。
- 缺陷 1 的初诊曾误判为内核 defconfig 问题（`CONFIG_QCA_CLD_WLAN=y`），
  已用 A/B 实验更正；`=m` 的改动保留（与原厂形态一致），但**它不是
  崩溃的修复手段**。详见 `docs/fix-report-final.md` 第六节。
- **缺陷 9 是缺陷 8 引入的回归**（跳过 WSA 链路时漏掉挂在链路 0 上的
  `.init` 回调，导致 mixer 控件缺失、麦克风静音）。两个补丁需一并应用。
- **缺陷 11 的补丁链包含一次 Revert**（0010 补丁 → 0011 Revert → 0012 重做）。
  这是保留真实开发历史的做法；应用时务必**按编号顺序**，`git am` 会正确处理。
- **`AMP Enable Switch` 这个控件名不能想当然。** `SOC_SINGLE` 不会自动补
  `" Switch"` 后缀，`mixer_paths.xml` 里找的是 `SPK1 AMP Enable Switch`；
  写错名字时 audio_route **静默跳过**，不报错——表现为"4 扬声器只响 2 个"。
- 无线投屏（`wifidisplayhalservice`）另有独立问题（缺 `libpng.so`），
  不在本仓库范围。
- 未做的功能级验证：实际联网（需在 UI 输入密码）、相机拍照、GNSS 定位。
  已验证到「服务 running + provider 在位 + 能扫描到 AP」这一层。
- `AudioFX` 服务存在 NPE，不影响开机与音频播放，属 LineageOS 侧组件问题。
- 设备树侧另有 2 处**尚未提交**的改动（指纹 VINTF 重复声明的进一步修正），
  不在本仓库补丁集内。

## 许可

本仓库的**文档与工具**采用 Apache-2.0（与 LineageOS 设备树一致），详见 [LICENSE](LICENSE)。

补丁沿用其上游代码的许可：

| 补丁 | 适用许可 |
|---|---|
| `patches/device-tree/` | Apache-2.0（设备树上游为 LineageOS 设备树） |
| `patches/kernel/` | **GPL-2.0**（Linux 内核） |

原始代码版权归 The LineageOS Project、The Linux Foundation 及其他原作者所有。
补丁仅修改配置与构建规则，不改变上游许可条款。
