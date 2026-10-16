# TB-J716F LineageOS 21 修复完成报告 — 批次 4~7（2026-10-16）

> 接续 `FIX-STATUS-2026-10-16.md`（那份记录的是"卡首屏 + 恢复路线"）。
> 本文档记录**本周期的最终结果**：三个缺陷全部修好并在真机验证。
>
> 设备当前状态：**正常开机、45 个传感器全部在位、声卡已注册、12 个 HAL 服务全 running**。

---

## 0. 一句话结论

批次 3 卡首屏的根因是**同一个 HAL 被声明了两次**（VINTF 冲突），不是传感器服务本身有问题；
声卡无声是**内核 DAI 链路引用了本平台不存在的 wsa-macro**，加上**一个原厂 blob（libssrec.so）ABI 不匹配**。
三处修复都已提交，最新可用镜像是 **`super-batch7.img`**（md5 `792fc7d4b9f191029eecc83b478c0582`）。

---

## 1. 最终验证结果（真机实测）

| 检查项 | 结果 |
|---|---|
| `sys.boot_completed` | `1` |
| `dumpsys sensorservice` | **Total 45 h/w sensors, 45 running** |
| `/proc/asound/cards` | **`0 [konamtpsndcard]: kona-mtp-snd-card`** |
| audio 输出线程 | `framesWritten:292800`（音频真的流过声卡） |
| audio 输出设备 | Speaker / Earpiece / Telephony Tx |
| audio 输入设备 | Built-In Mic / Built-In Back Mic / Telephony Rx |
| PCM 设备数 | 47 |
| HAL 服务 | 12 个全 `running`（camera/gnss/wifi/sensors×4/audio×2/wpa/wificond…） |
| `init.svc.*restarting` 计数 | **0** |
| `pm list features` | 89 项（含 `android.software.app_widgets`） |
| `sys.init.updatable_crashing` | 空（已清除） |

---

## 2. 根因一：卡第一屏 = VINTF 重复声明（batch3）

### 症状
刷完 batch3 卡在 kernel logo，**没有开机动画**。pstore 为空 → 不是内核 panic。

### 证据链
先把 batch2（已知可开机）和 batch3 的 super 都拆开做静态 diff：

```bash
# 拆包
simg2img super-batch2.img /tmp/super-b2.raw && lpunpack /tmp/super-b2.raw /tmp/b2-out
simg2img super-batch3.img /tmp/super-b3.raw && lpunpack /tmp/super-b3.raw /tmp/b3-out
# 挂载比对
sudo mount -o ro,loop /tmp/b2-out/vendor_a.img /tmp/vb2
sudo mount -o ro,loop /tmp/b3-out/vendor_a.img /tmp/vb3
diff -rq /tmp/vb2 /tmp/vb3
```

**batch3 相对 batch2 只多了 33 个文件**，全部是传感器相关；其余分区（system/product/system_ext/odm）**只有 build 时间戳不同**。
更要紧的是：5 个 rc 文件、4 个传感器二进制、128 个 `/vendor/etc/sensors` 配置 **与原厂 ZUI 逐字节相同**。
所以"抄错了文件"这个方向从一开始就是错的。

决定性的一步是用 **`checkvintf`**（构建与运行时用的同一个校验器）跑两个 vendor：

```
$ checkvintf --check-one --dirmap /vendor:/tmp/vb3      # batch3
Fetch '/tmp/vb3/etc/vintf/manifest/android.hardware.sensors@2.0-multihal.xml': OK
getDeviceHalManifest: -2147483648 VINTF parse error:
  Cannot add manifest fragment /vendor/etc/vintf/manifest/android.hardware.sensors@2.0-multihal.xml:
  HAL "android.hardware.sensors" has a conflict: Conflicting FqInstance: @2.0::ISensors/default
  (from /vendor/etc/vintf/manifest.xml) vs. @2.0::ISensors/default
  (from /vendor/etc/vintf/manifest/android.hardware.sensors@2.0-multihal.xml).
ERROR: Cannot fetch vendor manifest.

$ checkvintf --check-one --dirmap /vendor:/tmp/vb2      # batch2 → 通过
```

### 根因
AOSP 模块 `android.hardware.sensors@2.0-service.multihal` **自带 VINTF fragment**
（`Android.bp` 里 `vintf_fragments: ["android.hardware.sensors@2.0-multihal.xml"]`），会装到
`/vendor/etc/vintf/manifest/`。而此前又往设备 `manifest.xml` 里手写了一份同样的 `<hal>` 声明。
两份合并时 libvintf 判定 **FqInstance 冲突**，整个 vendor manifest 解析失败 →
hwservicemanager 起不来 → `class_start core` 之后的启动流程中断 → 开机动画永远不出现。

### 修复
`device/lenovo/p11_pro_plus/manifest.xml` 中删掉那份重复的 `<hal>` 块（保留注释说明原因）。

### 验证方式（推荐复现）
```bash
# 单看 build 出的 vendor 是否合法，比刷机快得多
sudo mount -o ro,loop out/target/product/p11_pro_plus/vendor.img /tmp/vnew
out/host/linux-x86/bin/checkvintf --check-one --dirmap /vendor:/tmp/vnew
# 期望最后两行：Successfully processed VINTF information
```

> **快速试验技巧**：改 VINTF 这类只涉及 vendor 的问题时，不必重编 super。
> 可以直接 `debugfs` 改 `vendor_a.img`，然后只刷 vendor 分区（约 24 秒）：
> ```bash
> cp /tmp/b3-out/vendor_a.img /tmp/v4-vendor.img
> python3 - <<'PY'   # 从 /tmp/manifest-orig.xml 删掉重复块 → /tmp/manifest-fixed.xml
> ...
> PY
> sudo debugfs -w -R "rm /etc/vintf/manifest.xml" /tmp/v4-vendor.img
> sudo debugfs -w -R "write /tmp/manifest-fixed.xml /etc/vintf/manifest.xml" /tmp/v4-vendor.img
> ```
> ⚠️ vendor 镜像内剩余空间很小（batch3 只剩 635 个 4K 块）。用 `mount -o loop,rw` 改会因
> 日志分配报 `ENOSPC`；**`debugfs` 可直接原地写**，这也是本次能快速定位的原因。

---

## 3. 根因二：无声卡 = wsa_macro DAI 引用不存在的硬件（batch5→6）

### 症状
`/proc/asound/cards` = `--- no soundcards ---`，dmesg 里反复
`ASoC: CODEC DAI wsa_macro_vifeedback not registered` + `deferred probe pending`。

### 证据链
```
$ adb shell 'cat /sys/bus/platform/devices/wsa-macro/modalias'
of:Nwsa-macroT<NULL>                      ← 没有 compatible，驱动没绑定
$ adb shell 'cat /sys/bus/platform/devices/rx-macro/modalias'
of:Nrx-macroT<NULL>Cqcom,rx-macro         ← 有 compatible，已绑定（对照组）
$ adb shell dmesg | grep -E 'skip wsa_macro|wsa_macro_'
... populate_snd_card_dailinks: wsa-max-devs=0, skip wsa_macro vifeedback link
... ASoC: CODEC DAI wsa_macro_rx1 not registered
```

并且用 `dtc` 对比**原厂 boot.img 里的 DTB**，确认 `wsa-macro@3240000` 节点在原厂也没有
`compatible`（只有 `phandle` + `wsa_swr_master`），dtbo 里 `qcom,wsa-max-devs = <0>`。
**所以这不是我们改坏的，是这颗料本来就没焊 WSA 功放**（用 cs35l41 替代）。

### 根因
`techpack/audio/asoc/kona.c` 的 `populate_snd_card_dailinks()` **无条件**把两个数组拷进 DAI 链：
- `msm_bolero_fe_dai_links[]` → `wsa_macro_vifeedback`
- `msm_wsa_cdc_dma_be_dai_links[]` → `wsa_macro_rx1` / `wsa_macro_rx_mix` / `wsa_macro_echo`

这些 codec DAI 全都由 `wsa-macro` 提供，而该 macro 永不 probe →
DAI 永不注册 → `devm_snd_soc_register_card()` 永远返回 `-EPROBE_DEFER` → 整张声卡注册不上。

### 修复
在这两处加 `wsa_max_devs > 0` 门控（从 DT 读 `qcom,wsa-max-devs`，本平台读到 0 就跳过）。
数组本身按最大长度声明，少拷几条不影响后续偏移计算（`total_links` 自增）。

### 踩到的坑（重要）
只加第一处门控后（batch5），`wsa_macro_vifeedback` 报错消失，但立刻冒出
`CODEC DAI wsa_macro_rx1 not registered` —— 说明**同一类引用有两处，必须一起改**。
排查手法：直接列全 `grep -n 'codec_dai_name = "wsa_macro' kona.c`，一共 4 处、分属 2 个数组。

---

## 4. 根因三：音频 HAL 崩溃循环 = 原厂 blob ABI 不匹配（batch6 暴露）

### 症状
batch6（声卡已能注册）**卡在开机动画**。adb 可达但 `boot_completed` 一直空：
```
[init.svc.audioserver]: [restarting]
[init.svc.vendor.audio-hal]: [restarting]
logcat: AudioSystem: getService: waiting for media.audio_policy   ← 一直重试
logcat -b crash:
  signal 11 (SIGSEGV), fault addr 0x0
  #00 /vendor/lib/libssrec.so (get_device_types+18)
  #01 /vendor/lib/libssrec.so (ssr_check_usecase+90)
  #02 /vendor/lib/hw/audio.primary.kona.so (audio_extn_check_and_set_multichannel_usecase+64)
  #03 /vendor/lib/hw/audio.primary.kona.so (adev_open_input_stream+3420)
```
audioserver 崩溃重启 → 它提供的 `media.audio_policy` 一直不出现 → system_server 阻塞等待 → 开机动画不结束。
**现象（卡开机动画）和 batch3（卡第一屏）很像，但根因完全不同** —— 这也是为什么必须靠 logcat/pstore 区分，不能凭现象下结论。

### 根因
`vendor.audio.feature.ssrec.enable=true` 会让 HAL `dlopen("/vendor/lib/libssrec.so")`。
该库是原厂 blob，`ssr_check_usecase()` **在判断功能开关之前**就执行：
```c
audio_devices_t devices = get_device_types(&in->device_list);   // ← 先解引用
if ((ssr_get_enabled()) && ...) { ... }                          // ← 后判断
```
它按原厂 Android 13 的 `struct stream_in` 布局编译，与我们重建的 `audio.primary.kona.so` 布局不一致 →
读 `in->device_list` 时拿到空指针 → SIGSEGV。

佐证：原厂固件自己也是关的 —— 原厂 `build.prop` 里 `ro.vendor.audio.sdk.ssr=false`，
SSR（多声道同步录音）功能本身没启用。我们的 `vendor.prop` 与原厂这两行**原本完全相同**，
只是原厂跑的是配套的 HAL，我们跑的是重建的 HAL，ABI 才对不上。

### 修复
`device/lenovo/p11_pro_plus/vendor.prop`：`vendor.audio.feature.ssrec.enable=false`。

> **同类问题模式（本设备已出现 3 次）**：原厂 blob 与本树重建的 AOSP/HAL 混用时，
> 只要 blob 和 HAL 共享结构体定义，就有 ABI 风险。
> 已知案例：相机 `postproc` blob（`ProcessState` 线程池）、`libssrec.so`（`stream_in`）、
> 以及历史上 `libwifi-hal.so` 被 stock blob 覆盖。
> **排查手法**：tombstone 的 backtrace 里若出现 `/vendor/lib/*.so`（原厂 blob）与
> `/vendor/lib/hw/*.so`（重建 HAL）交替出现，优先怀疑 ABI，而不是逻辑 bug。
> **处理原则**：若该功能原厂就没开，直接关掉开关（成本最低、风险最小）；不要试图去 patch blob。

---

## 5. 代码变更清单（已提交）

### `device/lenovo/p11_pro_plus` — commit `22cfba36`
| 文件 | 变更 |
|---|---|
| `manifest.xml` | **删除**重复的 `android.hardware.sensors` HAL 声明（VINTF 冲突根因） |
| `vendor.prop` | `vendor.audio.feature.ssrec.enable=true` → **`false`** |
| `proprietary-files.txt` | +299 行：SSC 栈（151 条）、音频配置、Qualcomm XML libs、factory rc 注释掉 |
| `device.mk` | +99 行：`.vendor` 库、PRODUCT_COPY_FILES（5 个传感器 rc）、handheld_core_hardware.xml |
| `rootdir/etc/*.rc` | 新增 5 个传感器 init 脚本（与原厂逐字节相同） |
| `prebuilts/dtbo*.img` | mic-bias 属性 6→8 字节等长二进制补丁 |

### `kernel/lenovo/sm8250` — commit `8b250d7d`
| 文件 | 变更 |
|---|---|
| `techpack/audio/asoc/kona.c` | +44 行：两处 `wsa_max_devs > 0` 门控 |
| `arch/arm64/boot/dts/vendor/lenovo/kona_*.dts` | 10 个文件：`"\02K\0\02K"` → `<0x00324b00 0x00324b00>` |

---

## 6. 镜像归档（（本地镜像归档目录））

| 镜像 | md5 | 说明 |
|---|---|---|
| **`super-batch7.img`** | `792fc7d4b9f191029eecc83b478c0582` | ✅ **当前推荐**：开机 + 45 传感器 + 声卡 |
| `super-batch6.img` | — | ⚠️ 卡开机动画（libssrec 崩溃），仅作诊断记录 |
| `super-batch5.img` | — | 有声卡报错消失但 DAI rx1 仍缺，卡住（无 ssrec 修复） |
| `super-batch4.img` | — | 开机 + 传感器，无声卡（VINTF 修复的最简验证） |
| `super-batch2.img` | `8ab2a6d2810d214bfa009ab470887841` | 已知可开机（无传感器栈）；应急回退用 |
| `vendor-batch4-vintffix.img` | — | 仅 vendor，用于 24 秒快速验证 VINTF 修复 |

---

## 7. 当前遗留问题

| # | 问题 | 状态 |
|---|---|---|
| 1 | `ScopedWakelock.so` 同时被 stock blob 和 AOSP `.vendor` 安装，**stock 胜出** | 已确认**无害**（传感器工作正常；AOSP `.vendor` 中间产物根本不存在），暂不处理 |
| 2 | AudioFX 服务 NPE（`SessionManager.removeSession` 空指针） | 存在但**不影响开机/音频播放**；属 LineageOS 侧组件问题，与本次三类根因无关 |
| 3 | 相机实际拍照未验证 | 相机 provider 已 running，但未做功能级验证 |
| 4 | GNSS 定位未验证 | 服务已 running、provider 已在位，未做实际定位测试 |
| 5 | WLAN 连接稳定性 | 历史批次已修，本批次回归未见异常，但未长时间压测 |

---

## 8. 复现/验证命令速查

```bash

# 开机是否完成
adb shell getprop sys.boot_completed            # 期望 1

# 传感器
adb shell dumpsys sensorservice | grep 'h/w sensors'    # 期望 Total 45 ... 45 running

# 声卡
adb shell 'cat /proc/asound/cards'              # 期望 kona-mtp-snd-card

# 服务健康（restarting 应为 0）
adb shell 'getprop | grep restarting'

# VINTF 合法性（在主机上对镜像做，比刷机快）
sudo mount -o ro,loop out/target/product/p11_pro_plus/vendor.img /tmp/vnew
out/host/linux-x86/bin/checkvintf --check-one --dirmap /vendor:/tmp/vnew
sudo umount /tmp/vnew

# dmesg 里的音频结论性日志
adb shell 'dmesg | grep -E "skip wsa_macro|Sound card .* registered"'
```
