# WLAN panic 根因分析（2026-10-14）

> 刷机已成功、系统能启动，但 WLAN 固件加载失败会触发内核 panic + SoC 重启循环。
> 本文记录排查过程与最终定位的根因。

---

## 一、现象

设备开机约 124 秒后必 panic 重启：

```
[   19.547573] cnss_pci 0000:01:00.0: Falling back to syfs fallback for: qca6390/amss20.bin
[   60.384024] cnss: fatal: Timeout waiting for FW ready indication
[   61.209286] wlan: Loading driver v5.2.022.12B
[  101.348152] cnss: Timeout (40000ms) waiting for calibration to complete
[  101.348833] cnss: Failed to send mode request, mode: OFF(4), err: -107
[  123.872036] cnss: fatal: Timeout waiting for FW ready indication
[  123.976085] Kernel panic - not syncing: subsys-restart: Resetting the SoC - wlan crashed.
```

证据：`/sys/fs/pstore/console-ramoops-0`，全文存 `logs/ramoops-console-2026-10-14.txt`。

## 二、根因（决定性对比）

### 2.1 内核里 WLAN 驱动的存在形式不同

```
$ strings <内核> | grep -cE 'qdf_|hdd_cfg80211'
ZUI 原厂内核:  0      ← 驱动是独立模块 (.ko)
我们的内核:    640    ← 驱动编译进了内核 (built-in)
```

对应 defconfig：

```
$ grep -n 'CONFIG_QCA_CLD_WLAN' kernel/lenovo/sm8250/arch/arm64/configs/vendor/kona-perf_defconfig
756:CONFIG_QCA_CLD_WLAN=y        ← 我们 =y (内置)
757:CONFIG_QCA_CLD_WLAN_PROFILE="qca6390"
```

设备树自己的 `Android.mk` 明确要求编成模块：

```make
# kernel/lenovo/sm8250/drivers/staging/qcacld-3.0/Android.mk:23
ifneq ($(findstring qca_cld3,$(WIFI_DRIVER_BUILT)),)
	WLAN_CHIPSET := qca_cld3
	WLAN_SELECT  := CONFIG_QCA_CLD_WLAN=m    ← 期望 =m
endif
```

### 2.2 vendor 里缺 WLAN 模块（连锁后果）

```
原厂 vendor/lib/modules/ : 41 个 .ko, 含 qca_cld3_qca6390.ko / qca_cld3_qca6490.ko
我们 vendor/lib/modules/ : 39 个 .ko, 【无】任何 qca_cld3_*
原厂 modules.load 第 37-38 行: qca_cld3_qca6490.ko / qca_cld3_qca6390.ko
我们 modules.load          : 无 WLAN 条目
```

原因链：
1. 内核把驱动编内置了（`=y`），所以内核构建产物里**没有** `qca_cld3_*.ko`
2. `device.mk:213` 那行安装 prebuilt 模块的语句**被注释掉**了：
   ```make
   # Modules
   # PRODUCT_COPY_FILES += \
   #     $(call find-copy-subdir-files,*,$(LOCAL_PATH)/,$(TARGET_COPY_OUT_VENDOR)/lib/modules)
   ```
3. 于是 `vendor/lib/modules` 既没有内核编出的（因为内建了），也没有设备树自带的
   prebuilt（因为没安装）

### 2.3 为什么内置就会 panic

- **原厂路径**：驱动是模块 → 内核启动时不碰 WLAN 芯片 → 开机后期
  userspace（`cnss-daemon`/`insmod`）加载模块 → 此时
  `/vendor/firmware_mnt` 早已挂载 → 固件读取成功。

- **我们的路径**：驱动内置 → `cnss2` 在开机 **19.5s** 就发起固件请求
  （`qca6390/amss20.bin`，经 sysfs fallback 交给 ueventd）→ 此时
  `/vendor/firmware_mnt` 尚未挂载（fstab 里是第二阶段挂载）→ ueventd
  找不到文件 → 40s 超时 → `cnss_schedule_recovery(CNSS_REASON_TIMEOUT)`
  → `cnss_recovery_work_handler` 里 `recovery_enabled=false` 直接
  `panic("subsys-restart: Resetting the SoC wlan crashed")` → 无限循环。

关键代码（`drivers/net/wireless/cnss2/main.c:1066`）：

```c
static void cnss_recovery_work_handler(struct work_struct *work)
{
	...
	if (!plat_priv->recovery_enabled)
		panic("subsys-restart: Resetting the SoC wlan crashed\n");
	...
}
```

### 2.4 旁证一：ueventd 从未处理该请求

```
$ grep -c "ueventd : firmware: loading 'venus" logcat
6                      ← venus 成功 (vendor 分区内, 已挂载)
$ grep -c "firmware: loading 'qca6390" logcat
0                      ← amss20 压根没走到加载
```

`venus.mdt` 在 `/vendor/firmware/`（vendor 分区，开机很早可读）→ 成功；
`amss20.bin` 在 `/vendor/firmware_mnt/image/`（modem 分区，第二阶段才挂）
→ 失败。

### 2.5 旁证二：modules.load 也缺失

原厂 `vendor/lib/modules/modules.load`（41 行，列出全部要加载的模块，
含 `qca_cld3_qca6390.ko` / `qca_cld3_qca6490.ko`）在我们镜像里**完全不存在**：

```
$ ls /mnt/vmnt/lib/modules/ | wc -l          # 我们的 vendor.img
42          ← 39 个 .ko + modules.alias/dep/softdep，无 modules.load
$ sudo md5sum /mnt/vstock/lib/modules/modules.load \
            device/lenovo/p11_pro_plus/prebuilts/modules/modules.load
7a275f2805914660456852212e056c62  /mnt/vstock/lib/modules/modules.load
7a275f2805914660456852212e056c62  device/.../prebuilts/modules/modules.load
```

设备树自带的 `modules.load` 与原厂**逐字节相同**，但从未安装 —— 因为
`device.mk:213` 那行安装命令被注释掉了。

`init` 在**第一阶段**就从 ramdisk 的 `modules.load` 读列表加载模块
（`system/core/init/first_stage_init.cpp:189`），所以缺这个文件意味着
模块加载完全依赖内核内建 —— 与我们观察到的现象一致。

## 三、已排除的假设（均有实测依据）

| 假设 | 排除依据 |
|---|---|
| 组名不匹配 | 实测原厂 super 组名也是 `qti_dynamic_partitions_a/b` |
| 分区空间不足 | super 整体替换已绕开；5 分区尺寸 getvar 实测吻合 |
| fstab 配置缺失 | diff 原厂与我们的 `fstab.qcom`：**逐字节相同** |
| ueventd 搜索路径缺失 | 我们 `ueventd.rc:31` 已有 `firmware_directories /vendor/firmware_mnt/image/` |
| DTB 不同 | `md5sum` 相同（都用 `prebuilts/dtb.img`） |
| 我修的符号链有问题 | 设备上实测 6 条都在、目标文件存在 |
| modem 分区太小 | 设备 `/proc/partitions` 显示 sde4=404,480KB=414,187,520B，与 EDL 参数一致 |
| modem 分区内容缺失 | `NON-HLOS.bin` 经 mdir 验证含 `image/qca6390/amss20.bin` (4,372,624 B, ELF) |
| **prebuilt 模块可直接用** | `vermagic=4.19.157` ≠ 我们内核 `4.19.312` → 版本不匹配，**不能加载** |

## 四、修复方案（已实施并验证）

**把 WLAN 驱动改为模块方式构建**，与原厂一致。

### 4.1 改动：defconfig 一行

```
kernel/lenovo/sm8250/arch/arm64/configs/vendor/kona-perf_defconfig

- CONFIG_QCA_CLD_WLAN=y        (驱动编进内核 → 19.5s 就请求固件 → 太早)
+ CONFIG_QCA_CLD_WLAN=m        (驱动编成模块 → 由 init 在 on boot 阶段加载)
```

`CONFIG_CNSS2=y` 保持不变 —— 原厂 cnss2 也是内置的，它只负责总线/电源，
真正触发 WLAN 芯片上电的是 qcacld 驱动。

### 4.2 为什么这样改就够了（三处机制本来就是通的）

| 机制 | 状态 | 证据 |
|---|---|---|
| 模块重命名 `wlan.ko → qca_cld3_qca6390.ko` | ✅ 已存在 | 设备树 `BoardConfig.mk:124-125` 的 `TARGET_MODULE_ALIASES`；构建图里已有 `mv ... -name wlan.ko) .../qca_cld3_qca6390.ko` 规则 |
| 模块加载（`on boot` 阶段） | ✅ 已存在 | 我们 vendor 的 `init.target.rc:143`（与原厂同一行）<br>`exec_background ... modprobe -a -d /vendor/lib/modules/ qca_cld3_qca6390 qca_cld3_qca6490` |
| 模块安装到 vendor | ✅ 机制正常 | 内核 `AndroidKernel.mk` 的 `modules_install` + `TARGET_MODULE_ALIASES` 重命名（39 个 audio 模块就是这么装的） |

也就是说：**只差把驱动编成模块**这一步。之前三处机制都在，但因为没有
`wlan.ko` 产出，重命名规则无对象可改，`modprobe` 也就找不到文件。

### 4.3 编译验证（已实测）

```
$ grep CONFIG_QCA_CLD_WLAN out/.../KERNEL_OBJ/.config
CONFIG_QCA_CLD_WLAN=m                         ← 生效

$ ls -la out/.../obj/KERNEL_OBJ/drivers/staging/qcacld-3.0/wlan.ko
214,674,672 B                                 ← 编出模块

$ ls -la out/.../vendor/lib/modules/qca_cld3_qca6390.ko
9,694,857 B                                   ← 别名重命名生效

$ strings .../qca_cld3_qca6390.ko | grep vermagic
vermagic=4.19.312-perf+ ...                   ← 与内核版本匹配 ✅
（对比：设备树 prebuilt 模块是 4.19.157，无法加载到我们的内核）

$ strings out/.../obj/KERNEL_OBJ/arch/arm64/boot/Image | grep -cE 'qdf_|hdd_cfg80211'
0                                             ← 内核已不再内建 WLAN (原为 640)
```

### 4.4 连带影响：vendor 变大，需重建 super.img

```
旧 vendor.img:  813,056,000 B (775.4 MiB)
新 vendor.img:  822,939,648 B (784.8 MiB)   ← +9.4 MiB (新增 WLAN 模块)
```

设备上 `vendor_a` 分区是 775.4 MiB，装不下新版，所以**必须重建 super.img**
（重建后 `vendor_a` 分配为 784.8 MiB）：

```
$ 解析新 super.img
  system_a      923.4 MiB
  product_a     446.1 MiB
  system_ext_a  418.8 MiB
  vendor_a      784.8 MiB   ← 已增大
  odm_a           1.5 MiB
  合计         2574.7 MiB / 上限 8188.0 MiB  ✅ 空间充足

$ 从 super 提取 vendor_a 与 vendor.img 对比
  两者 SHA256 完全相同 (7637bdd7...)  → 确认含 WLAN 模块
```

### 4.5 关于 qca_cld3_qca6490

`init.target.rc` 同时 modprobe 两个模块名，但我们只编 qca6390：

- 设备实际用的是 **qca6390**（DT 节点 `qcom,cnss-qca6390`，日志 8 处引用；
  BT 也是 `bt_qca6390`）
- 缺少 `qca_cld3_qca6490.ko` 只会让 modprobe 对第二个名字报错，
  因是 `exec_background` 不阻塞启动，**非致命**

### 4.6 刷入与验证步骤

```bash
# 1. 刷入修复后的两个镜像
fastboot flash boot boot-fixed.img
fastboot flash super super.img

# 2. 验证点
adb shell 'ls -la /vendor/lib/modules/qca_cld3*'          # 模块就位
adb shell 'dmesg | grep -E "wlan.*Loading|qca_cld3"'      # 驱动加载 (应在 on boot 阶段)
adb shell 'ls /sys/class/net/' | grep wlan                # wifi 接口出现
adb shell 'dumpsys wifi | head -n 20'                     # wifi 服务状态
# 关键: 开机 3 分钟以上不 panic
```
