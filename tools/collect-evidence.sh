#!/usr/bin/env bash
# 设备取证脚本：在重启循环中抢抓证据。
#
# 背景：设备反复 panic 重启时，adb/logcat 常常来不及抓取；pstore 保留上次
# 崩溃的完整内核日志，是唯一可靠的证据源。本脚本在 adb 一上线就立即读走
# pstore，并按 uptime 变化检测重启。
#
# 用法:
#   ADB=adb ./collect-evidence.sh [输出目录]
#
# 环境变量:
#   ADB       adb 可执行文件路径 (默认: adb，Windows 下可设为 adb.exe 全路径)
#   OUTDIR    输出目录 (默认: ./wlan-evidence)
#   ROUNDS    最大轮数，每轮 10 秒 (默认: 300)
set +e

ADB="${ADB:-adb}"
OUTDIR="${OUTDIR:-./wlan-evidence}"
ROUNDS="${ROUNDS:-300}"

mkdir -p "$OUTDIR"
LOG="$OUTDIR/monitor.log"
: > "$LOG"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
dev_state() { "$ADB" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && NF{print $2}' | head -1; }

grab() {
    local note="$1" ts base
    ts=$(date '+%H%M%S'); base="$OUTDIR/evidence-$ts"
    log "grab($note) -> $base"

    {
        echo "===== evidence $ts  note: $note ====="
        echo "--- devices -l"; "$ADB" devices -l 2>&1 | tr -d '\r'
        echo "--- id / uptime / props"
        "$ADB" shell 'id; cat /proc/uptime
            echo "boot_completed=$(getprop sys.boot_completed)"
            echo "lineage=$(getprop ro.lineage.version)"
            echo "verifiedbootstate=$(getprop ro.boot.verifiedbootstate)"
            echo "adbd=$(getprop init.svc.adbd)"' 2>&1 | tr -d '\r'
        echo "--- pstore list"; "$ADB" shell 'ls -la /sys/fs/pstore/' 2>&1 | tr -d '\r'
        echo "--- mounts (firmware_mnt / persist)"
        "$ADB" shell 'mount | grep -E "firmware_mnt|/vendor$|persist"' 2>&1 | tr -d '\r'
        echo "--- /vendor/firmware_mnt/image"
        "$ADB" shell 'ls /vendor/firmware_mnt/image/ 2>&1 | head -20
            echo "--- qca6390:"; ls -la /vendor/firmware_mnt/image/qca6390/ 2>&1 | head -30' 2>&1 | tr -d '\r'
        echo "--- /vendor/lib/modules"
        "$ADB" shell 'ls -la /vendor/lib/modules/ | head -60
            echo "count=$(ls /vendor/lib/modules/*.ko 2>/dev/null | wc -l)"' 2>&1 | tr -d '\r'
        echo "--- lsmod"; "$ADB" shell 'lsmod' 2>&1 | tr -d '\r'
        echo "--- net interfaces"
        "$ADB" shell 'ls /sys/class/net/; ip -o link 2>/dev/null | head -20' 2>&1 | tr -d '\r'
        echo "--- dmesg (cnss/wlan) tail"
        "$ADB" shell 'dmesg | grep -iE "cnss|qca|wlan|hdd" | tail -60' 2>&1 | tr -d '\r'
    } > "$base.txt" 2>&1

    # pstore 优先级最高：每次启动都在，但可能被快速覆盖
    "$ADB" shell 'cat /sys/fs/pstore/console-ramoops-0' > "$base-pstore-console.txt" 2>&1
    "$ADB" shell 'cat /sys/fs/pstore/dmesg-ramoops-0'   > "$base-pstore-dmesg.txt" 2>&1
    "$ADB" shell 'dmesg'                                > "$base-dmesg.txt" 2>&1

    log "sizes: txt=$(wc -c < "$base.txt") pstore-console=$(wc -c < "$base-pstore-console.txt") dmesg=$(wc -c < "$base-dmesg.txt")"
}

"$ADB" kill-server >/dev/null 2>&1
log "monitor start (rounds=$ROUNDS, outdir=$OUTDIR)"

last_up=""; last_note=""
for _ in $(seq 1 "$ROUNDS"); do
    st=$(dev_state)
    case "$st" in
        device)
            uid=$("$ADB" shell id 2>/dev/null | tr -d '\r' | grep -o 'uid=[0-9]*' | head -1)
            if [ "$uid" != "uid=0" ]; then
                "$ADB" root >/dev/null 2>&1
                sleep 4; "$ADB" wait-for-device >/dev/null 2>&1; sleep 2
            fi
            up=$("$ADB" shell cat /proc/uptime 2>/dev/null | tr -d '\r' | awk '{print $1}')
            bc=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
            if [ -n "$up" ]; then
                if [ -z "$last_up" ]; then
                    log "adb up (first), uptime=$up boot_completed=$bc"
                    grab "first-adb"
                elif awk "BEGIN{exit !($up < $last_up - 5)}"; then
                    log "!! REBOOT detected: uptime $last_up -> $up"
                    grab "after-reboot"
                elif [ "$bc" = "1" ] && [ "$last_note" != "booted" ]; then
                    log "boot_completed=1 (uptime=$up)"
                    grab "boot-completed"; last_note="booted"
                else
                    log "adb ok, uptime=$up boot_completed=$bc"
                fi
                last_up="$up"
            fi
            ;;
        unauthorized) log "adb unauthorized (需在设备上点授权)" ;;
        "")           log "no adb" ;;
        *)            log "adb state=$st" ;;
    esac
    sleep 10
done
log "monitor end"
