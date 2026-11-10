#!/bin/sh
# roam-steer —— 把弱信号客户端赶向信号更好的远端 AP。
#
# 逻辑：客户端 RSSI 低于阈值 & 稳定连接一段时间 →
#   ① 发 802.11v BSS Transition Request (disassociation_imminent)，让客户端扫描并走
#   ② 连续引导无效 → ubus del_client 强制断开一次，逼它重新选 AP
#   ③ 退避：踢了之后仍走不掉的客户端，冷却时间按 2^n 指数拉长，
#      超过 KICK_TOTAL 上限后完全隔音 MUTE 秒，绝不反复强踢
#
# 安全阀（本次加固重点）：
#   - 5G 上只有在 mesh 回程有对端（卧室 AP 在线）时才引导/踢人；
#     否则全网没有第二台可去的 AP，踢谁谁断联 → 直接跳过
#   - 2.4G 只有在 5G AP 接口存在时才引导
#
# 用法
#   roam-steer             执行一次（procd 循环每 30s 调用）
#   roam-steer --dry-run   只打印将执行的动作，不碰任何帧
#
# 可覆盖参数：
#   THRESH=-78     引导阈值(dBm)；放宽后 -72~-78 属"可用但在边缘"，不再乱踢
#   MIN_AGE=120    至少连接这么久才考虑引导(秒)
#   BASE_CD=900    同一客户端两次动作的基础间隔(秒)
#   KICK_MAX=2     需要几次引导无效后才强踢
#   KICK_TOTAL=3   最多强踢几次，超过后进入长隔音
#   MUTE=3600      隔音秒数：强踢满 KICK_TOTAL 次后这段时间完全不碰它
set -u

THRESH=${THRESH:--78}
MIN_AGE=${MIN_AGE:-120}
BASE_CD=${BASE_CD:-900}
KICK_MAX=${KICK_MAX:-2}
KICK_TOTAL=${KICK_TOTAL:-3}
MUTE=${MUTE:-3600}
STATE=/tmp/roam-steer.state
REQ=/tmp/roam-steer.notice     # 环境变化日志去抖用
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

command -v ubus >/dev/null 2>&1 || { echo "缺少 ubus"; exit 1; }

state_get() { awk -v m="$1:$2" '$1==m{print $2" "$3}' "$STATE" 2>/dev/null; }
state_set() {
    awk -v m="$1" '$1!=m' "$STATE" 2>/dev/null > "$STATE.tmp"
    printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}
# 环境类跳过原因每小时提醒一次，不刷日志
notice_once() {
    key="$1"; msg="$2"
    last=$(awk -v k="$key" '$1==k{print $2}' "$REQ" 2>/dev/null)
    if [ -z "$last" ] || [ $(( $(date +%s) - last)) -ge 3600 ]; then
        logger -t roam-steer "$msg"
        awk -v k="$key" '$1!=k' "$REQ" 2>/dev/null > "$REQ.tmp"
        printf '%s %s\n' "$key" "$(date +%s)" >> "$REQ.tmp"
        mv "$REQ.tmp" "$REQ"
    fi
}

now=$(date +%s)

# ---- 全局健康检查 ----
MESH_PEER=0
if [ "$DRY" -eq 1 ]; then
    iw dev wlan1 station dump 2>/dev/null | grep -q "^Station" && MESH_PEER=1
else
    iw dev wlan1 station dump 2>/dev/null | grep -q "^Station" && MESH_PEER=1
fi
[ "$MESH_PEER" -eq 1 ] || notice_once no_mesh \
    "mesh 回程无对端(卧室 AP 疑似离线)，本周期不对 5G 客户端做引导/强踢"
[ -d /sys/class/net/wlan1-1 ] || notice_once no_5g \
    "5G AP 接口不存在，不对 2.4G 客户端做引导"

for iface in wlan0 wlan1-1; do
    [ -d "/sys/class/net/$iface" ] || continue
    # 5G 上的动作依赖 mesh 对端在线；2.4G 依赖 5G AP 在线
    if [ "$iface" = "wlan1-1" ] && [ "$MESH_PEER" -eq 0 ]; then
        continue
    fi
    if [ "$iface" = "wlan0" ] && [ ! -d /sys/class/net/wlan1-1 ]; then
        continue
    fi

    iw dev "$iface" station dump 2>/dev/null | awk '
        /^Station/ {mac=$2}
        /^[[:space:]]*signal:/ {sig=$2}
        /connected time:/ {if (mac!="" && sig!="") print mac, sig, $3}
    ' | while read -r mac sig ct; do
        case "$sig" in ''|*[!-0-9]*) continue ;; esac
        [ "$sig" -gt "$THRESH" ] && continue
        [ "${ct:-0}" -lt "$MIN_AGE" ] && continue

        set -- $(state_get "$mac" "$iface")
        last=${1:-0}; cnt=${2:-0}

        # ---- 退避：按历史动作次数计算本次必须间隔的时间 ----
        # cnt: 0..KICK_MAX-1 是引导；第 KICK_MAX 次是强踢；踢满 KICK_TOTAL 次后隔音
        if [ "$cnt" -ge $((KICK_MAX * KICK_TOTAL)) ]; then
            delay=$MUTE                                  # 隔音
        else
            k=$(( cnt / KICK_MAX + 1 ))                  # 第几轮
            delay=$(( BASE_CD * (2 ** (k - 1)) ))        # 900 → 1800 → 3600 ...
        fi
        [ $((now - last)) -lt "$delay" ] && continue

        if [ $((cnt % KICK_MAX)) -ne $((KICK_MAX - 1)) ] || [ "$cnt" -eq 0 ]; then
            # 普通引导：发 11v 请求（dry-run 只打印，不写状态）
            [ "$DRY" -eq 1 ] && echo "[dry] bss_tm_req $mac@$iface (${sig}dBm, 连接 ${ct}s, 第 $((cnt+1)) 次动作)" && continue
            ubus call "hostapd.$iface" bss_transition_request \
                "{\"addr\":\"$mac\",\"disassociation_imminent\":true,\"disassociation_timer\":10,\"validity_period\":100}" >/dev/null 2>&1
            logger -t roam-steer "bss_tm_req $mac@$iface (${sig}dBm, round $((cnt/KICK_MAX+1)))"
        else
            # 强踢：警示可去的地方，若无处可去会由退避保证不反复踢（dry-run 不写状态）
            [ "$DRY" -eq 1 ] && echo "[dry] del_client $mac@$iface (${sig}dBm, 连接 ${ct}s, 引导 ${cnt} 次无效)" && continue
            ubus call "hostapd.$iface" del_client \
                "{\"addr\":\"$mac\",\"deauth\":true,\"reason\":5,\"ban_time\":10000}" >/dev/null 2>&1
            logger -t roam-steer "del_client $mac@$iface (${sig}dBm, 引导${cnt}次无效, 退避${delay}s)"
        fi
        state_set "$mac:$iface" "$now" $((cnt + 1))
    done
done
