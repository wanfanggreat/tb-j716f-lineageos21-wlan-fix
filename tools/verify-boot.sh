#!/usr/bin/env bash
# 启动验证脚本：刷入 WLAN 修复后，观察设备是否越过历史 panic 点、wlan0 是否出现。
#
# 用法:
#   ADB=adb ./verify-boot.sh [输出目录]
#
# 环境变量:
#   ADB       adb 可执行文件路径 (默认: adb)
#   OUTDIR    输出目录 (默认: ./verify-qrtrns)
#   PANIC_AT  历史 panic 时间点(秒)，用于判断是否已越过 (默认: 126)
set +e

ADB="${ADB:-adb}"
OUTDIR="${OUTDIR:-./verify-qrtrns}"
PANIC_AT="${PANIC_AT:-126}"

mkdir -p "$OUTDIR"
LOG="$OUTDIR/monitor.log"
: > "$LOG"
log() { echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

"$ADB" kill-server >/dev/null 2>&1

maxup=0; grabbed=0
for _ in $(seq 1 240); do
    st=$("$ADB" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && NF{print $2}' | head -1)
    if [ "$st" = "device" ]; then
        up=$("$ADB" shell cat /proc/uptime 2>/dev/null | tr -d '\r' | awk '{print $1}')
        bc=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        if [ -n "$up" ]; then
            awk "BEGIN{exit !($up > $maxup)}" && maxup=$up
            log "adb OK uptime=$up boot_completed=${bc:-?} (峰值=${maxup})"

            # 首次取证：确认 qrtr-ns 是否运行、事件流是否完整
            if [ "$grabbed" = "0" ] && awk "BEGIN{exit !($up > 30)}"; then
                grabbed=1
                ts=$(date '+%H%M%S')
                {
                    echo "=== 首次取证 uptime=$up $(date '+%T') ==="
                    "$ADB" shell 'id; getprop ro.lineage.version; getprop sys.boot_completed
                        getprop init.svc.vendor.qrtr-ns; getprop init.svc.cnss-daemon' 2>&1 | tr -d '\r'
                    echo "--- qrtr-ns 进程:"
                    "$ADB" shell 'ps -A -o PID,USER,NAME 2>/dev/null | grep -i qrtr' 2>&1 | tr -d '\r'
                    echo "--- 网络接口:"
                    "$ADB" shell 'ls /sys/class/net/' 2>&1 | tr -d '\r'
                    echo "--- cnss 事件流:"
                    "$ADB" shell 'dmesg | grep -iE "cnss|wlfw|wlan" | head -40' 2>&1 | tr -d '\r'
                } > "$OUTDIR/first-$ts.txt" 2>&1
                log "已取证 -> $OUTDIR/first-$ts.txt"
            fi

            # boot_completed 达成后取证：模块、接口、事件流
            if [ "$bc" = "1" ]; then
                ts=$(date '+%H%M%S')
                {
                    echo "=== boot_completed uptime=$up $(date '+%T') ==="
                    echo "--- qrtr-ns:"
                    "$ADB" shell 'getprop init.svc.vendor.qrtr-ns
                        ps -A -o PID,USER,NAME 2>/dev/null | grep -i qrtr' 2>&1 | tr -d '\r'
                    echo "--- 网络接口:"
                    "$ADB" shell 'ls /sys/class/net/' 2>&1 | tr -d '\r'
                    echo "--- lsmod wlan:"
                    "$ADB" shell 'lsmod | grep -i wlan' 2>&1 | tr -d '\r'
                    echo "--- cnss 事件流:"
                    "$ADB" shell 'dmesg | grep -iE "cnss|wlfw" | head -60' 2>&1 | tr -d '\r'
                } > "$OUTDIR/booted-$ts.txt" 2>&1
                log "boot_completed=1 已取证 -> $OUTDIR/booted-$ts.txt"
            fi
        fi
    else
        log "state='${st:-none}'"
    fi
    if awk "BEGIN{exit !($maxup > $((PANIC_AT + 74)))}"; then
        log "已越过 $((PANIC_AT + 74))s（历史 panic 点在 ${PANIC_AT}s）"
        break
    fi
    sleep 5
done
log "结束：uptime 峰值=$maxup"
