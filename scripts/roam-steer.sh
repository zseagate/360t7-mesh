#!/bin/sh
# roam-steer —— 用 802.11v 把弱信号客户端「建议」到信号更好的远端 AP。
#
# 设计原则：绝不主动断开客户端。
#   - 只发 BSS Transition Management Request，且 disassociation_imminent=false
#     （= 纯建议，客户端可以不理，不会掉线）
#   - 请求里带上对端 AP 的 BSS Transition Candidate List（neighbors），
#     客户端才知道「该去哪里」；不带候选时手机会原地重连，等于白白断一次
#   - 不用 ubus del_client 强踢（强踢 = 用户可感知的断网，且客户端往往回到原 AP）
#
# 退避：同一客户端每引导一次，下次间隔翻倍（900s→1800s→3600s…），
#       满 MAX_ROUNDS 次后完全静音 MUTE 秒，避免无意义的重复请求。
#
# 安全阀：
#   - 5G 上只有 mesh 回程存在对端（另一台 AP 在线）时才引导；
#     否则全网没有第二台可去，引导毫无意义
#   - 2.4G 只有在 5G AP 存在时才引导
#
# 接口名不写死：不同版本的 netifd 可能把 mesh 建成 wlan1 或 wlan1-2，
# 这里用 `iw dev <if> info` 的 type / 频段动态识别 AP 与 mesh 接口。
#
# 邻居候选来源：/etc/roam-steer.neighbors
#   每行 "<频段> <NR hex>"，频段写 5g 或 2g；内容是「对端 AP」的
#   `ubus call hostapd.<if> rrm_nr_get_own` 返回的第三个字段。
#   例：5g b6a7b9cbeebccbf5900008064090603026a00
#   没有该文件时退化为「无候选的纯建议」（仍然不断线，但命中率低）。
#   生成方法见 README「生成邻居候选列表」。
#
# 用法
#   roam-steer               执行一次（procd 循环每 30s 调用）
#   roam-steer --dry-run     只打印将执行的动作，不发帧
#
# 可覆盖参数：
#   THRESH=-78     引导阈值(dBm)
#   MIN_AGE=120    至少连接这么久才考虑引导(秒)
#   BASE_CD=900    首次引导后，第二次的最短间隔(秒)，之后翻倍
#   MAX_ROUNDS=3   同一客户端最多引导几次，超过后静音 MUTE 秒
#   MUTE=3600      静音秒数
set -u

THRESH=${THRESH:--78}
MIN_AGE=${MIN_AGE:-120}
BASE_CD=${BASE_CD:-900}
MAX_ROUNDS=${MAX_ROUNDS:-3}
MUTE=${MUTE:-3600}
NR_FILE=${NR_FILE:-/etc/roam-steer.neighbors}
STATE=/tmp/roam-steer.state
REQ=/tmp/roam-steer.notice     # 环境变化日志去抖用
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

command -v ubus >/dev/null 2>&1 || { echo "缺少 ubus"; exit 1; }

iftype() { iw dev "$1" info 2>/dev/null | awk '/^[[:space:]]*type /{printf "%s", $2; if ($3 != "") printf " %s", $3}'; }
iffreq() { iw dev "$1" info 2>/dev/null | sed -n 's/.*(\([0-9]\+\) MHz).*/\1/p' | head -1; }

state_get() { awk -v m="$1" '$1==m{print $2" "$3}' "$STATE" 2>/dev/null; }
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

# 取某频段对应的邻居 NR 串，拼成 JSON 数组片段
neighbors_json() {
    [ -f "$NR_FILE" ] || return 1
    out=""
    while read -r band nr; do
        [ "$band" = "$1" ] || continue
        [ -n "${nr:-}" ] || continue
        out="$out${out:+,}\"$nr\""
    done < "$NR_FILE"
    [ -n "$out" ] || return 1
    printf '[%s]' "$out"
}

now=$(date +%s)

# ---- 盘点无线接口（名字不写死） ----
AP_5G=""; AP_2G=""; MESH=""
for d in /sys/class/net/wlan*; do
    [ -e "$d" ] || continue
    i=${d##*/}
    case "$(iftype "$i")" in
        "AP")   f=$(iffreq "$i")
                if [ -n "$f" ] && [ "$f" -ge 5000 ] 2>/dev/null; then
                    [ -n "$AP_5G" ] || AP_5G=$i
                else
                    [ -n "$AP_2G" ] || AP_2G=$i
                fi ;;
        "mesh point") [ -n "$MESH" ] || MESH=$i ;;
    esac
done

MESH_PEER=0
[ -n "$MESH" ] && iw dev "$MESH" station dump 2>/dev/null | grep -q "^Station" && MESH_PEER=1
[ "$MESH_PEER" -eq 1 ] || notice_once no_mesh \
    "mesh 回程无对端(另一台 AP 疑似离线)，本周期不对 5G 客户端做引导"
[ -n "$AP_5G" ] || notice_once no_5g "5G AP 接口不存在，不对 2.4G 客户端做引导"

for iface in $AP_2G $AP_5G; do
    [ -n "$iface" ] || continue
    if [ "$iface" = "$AP_5G" ]; then
        band=5g
        [ "$MESH_PEER" -eq 1 ] || continue
    else
        band=2g
        [ -n "$AP_5G" ] || continue
    fi
    NB=$(neighbors_json "$band" || true)

    iw dev "$iface" station dump 2>/dev/null | awk '
        /^Station/ {mac=$2}
        /^[[:space:]]*signal:/ {sig=$2}
        /connected time:/ {if (mac!="" && sig!="") print mac, sig, $3}
    ' | while read -r mac sig ct; do
        case "$sig" in ''|*[!-0-9]*) continue ;; esac
        [ "$sig" -gt "$THRESH" ] && continue
        [ "${ct:-0}" -lt "$MIN_AGE" ] && continue

        key="$mac:$iface"
        set -- $(state_get "$key")
        last=${1:-0}; cnt=${2:-0}

        # ---- 退避 / 静音 ----
        if [ "$cnt" -ge "$MAX_ROUNDS" ]; then
            delay=$MUTE
        else
            delay=$(( BASE_CD * (2 ** (cnt > 0 ? cnt - 1 : 0)) ))
        fi
        [ $((now - last)) -lt "$delay" ] && continue

        req="{\"addr\":\"$mac\",\"disassociation_imminent\":false,\"disassociation_timer\":0,\"validity_period\":120,\"abridged\":true"
        [ -n "$NB" ] && req="$req,\"neighbors\":$NB"
        req="$req}"
        round=$((cnt + 1))

        if [ "$DRY" -eq 1 ]; then
            echo "[dry] bss_tm_req $mac@$iface($band,${sig}dBm,连接${ct}s,round $round/$MAX_ROUNDS,候选=${NB:-无})"
            continue
        fi

        if ubus call "hostapd.$iface" bss_transition_request "$req" >/dev/null 2>&1; then
            if [ -n "$NB" ]; then
                logger -t roam-steer "bss_tm_req $mac@$iface ${sig}dBm round $round/$MAX_ROUNDS (带候选)"
            else
                logger -t roam-steer "bss_tm_req $mac@$iface ${sig}dBm round $round/$MAX_ROUNDS (无候选)"
            fi
            state_set "$key" "$now" "$round"
        else
            # 失败多半是客户端刚断开，不记状态，下轮再试
            logger -t roam-steer "bss_tm_req $mac@$iface ${sig}dBm 失败（客户端可能已离开）"
        fi
    done
done
