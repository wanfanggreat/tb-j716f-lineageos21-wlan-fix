#!/usr/bin/env bash
# 重新编译 vendor.img 与 super.img，并校验 WLAN 修复是否生效。
#
# 为什么必须重建 super.img：
#   WLAN 驱动改为模块构建后，vendor 分区变大（实测 775.4 → 784.8 MiB），
#   设备上的 vendor_a 分区装不下，必须由 super.img 重新分配分区尺寸。
#
# 用法:
#   LINEAGE=~/android/lineage ./rebuild-vendor-super.sh
#
# 环境变量:
#   LINEAGE   LineageOS 源码树路径 (默认: $HOME/android/lineage)
#   JOBS      编译并发度 (默认: 4)
#   LUNCH     产品配置 (默认: lineage_p11_pro_plus-ap2a-userdebug)
set -eo pipefail

LINEAGE="${LINEAGE:-$HOME/android/lineage}"
JOBS="${JOBS:-4}"
LUNCH="${LUNCH:-lineage_p11_pro_plus-ap2a-userdebug}"
P="$LINEAGE/out/target/product/p11_pro_plus"

cd "$LINEAGE"

export USE_CCACHE=1
export CCACHE_EXEC="${CCACHE_EXEC:-/usr/bin/ccache}"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_COMPRESS=1

echo "=== swap 自检（低内存机器必需）==="
free -h | head -2
swapline=$(free -g | awk '/Swap:/{print $2}')
echo "swap=${swapline}GB"
if [ "${swapline:-0}" -lt 20 ]; then
    echo "!! 警告: swap 不足 20GB。AOSP 官方建议 64GB 内存，"
    echo "   低内存机器请确保 swap 已启用，否则 soong/ckati 可能 OOM。"
fi

echo
echo "=== lunch ==="
# shellcheck disable=SC1091
source build/envsetup.sh
lunch "$LUNCH"
[ -n "$TARGET_PRODUCT" ] || { echo "!! lunch 失败, 中止"; exit 1; }
echo "TARGET_PRODUCT=$TARGET_PRODUCT"

echo
echo "=== mka vendorimage ==="
mka -j"$JOBS" vendorimage; echo "vendorimage rc=$?"

echo
echo "=== mka superimage ==="
mka -j"$JOBS" superimage; echo "superimage rc=$?"

echo
echo "=== 校验：libwifi-hal.so 符号大小（应为 72 / 16）==="
readelf -sW "$P/vendor/lib64/libwifi-hal.so" 2>/dev/null |
    grep -E ' wifi_get_driver_version$| wifi_reset_passpoint_list$' ||
    echo "  !! 未找到符号，检查该文件是否来自源码编译（而非原厂 blob）"

echo
echo "=== 校验：wpa_supplicant 依赖（不应有 HIDL @1.2/@1.3）==="
readelf -d "$P/vendor/bin/hw/wpa_supplicant" 2>/dev/null |
    grep NEEDED | grep -iE 'supplicant|wifi' ||
    echo "  !! 未找到 supplicant 相关依赖"

echo
echo "=== 校验：supplicant rc 应为 AIDL 版 ==="
grep -E 'interface' \
    "$P/vendor/etc/init/android.hardware.wifi.supplicant-service.rc" 2>/dev/null ||
    echo "  !! rc 未找到"

echo
echo "=== 校验：init.qcom.rc 不应有重复的 service wpa_supplicant ==="
n=$(grep -cE '^service wpa_supplicant' "$P/vendor/etc/init/hw/init.qcom.rc" 2>/dev/null || true)
echo "  重复定义数: ${n:-0} (应为 0)"

echo
echo "=== 校验：init.qcom.rc 应含 vendor.qrtr-ns ==="
grep -n 'qrtr-ns' "$P/vendor/etc/init/hw/init.qcom.rc" 2>/dev/null || echo "  !! 缺失"

echo
echo "=== 校验：WLAN 模块已产出 ==="
ls -la "$P/vendor/lib/modules/qca_cld3_qca6390.ko" 2>/dev/null ||
    echo "  !! 未找到 qca_cld3_qca6390.ko（检查 CONFIG_QCA_CLD_WLAN=m 是否生效）"

echo
echo "=== 产物 ==="
for img in vendor.img super.img boot.img; do
    [ -f "$P/$img" ] && echo "  $img  $(stat -c '%s' "$P/$img") B"
done
echo
echo "刷入: fastboot flash super <super.img> && fastboot flash boot <boot.img>"
echo "done"
