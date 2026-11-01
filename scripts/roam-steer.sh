#!/bin/sh
# roam-steer — 弱信号客户端引导（解决"贴着远处 AP 不放、显示已连接但没网"）
#
# 背景：802.11r/k/v 只提供"能力"，不会主动赶人。没有 steering 时，客户端会一直
#       挂在能连上的、信号最差的那台 AP 上（尤其两台发射功率不等时），表现为
#       "WiFi 已连接，但无法访问互联网"。
#
# 做法：客户端 RSSI 低于阈值且已稳定连接一段时间 →
#   ① 发 802.11v BSS Transition Management Request（disassociation_imminent），
#      提示它扫描并切到更近的 AP；
#   ② 冷却期内反复无效 → ubus del_client 强制断开一次，让它重新选 AP。
#
# 用法：
#   roam-steer             执行一次（由 procd 服务每 30s 调用）
#   roam-steer --dry-run   只打印将执行的动作，不发任何帧
#
# 可覆盖参数（环境变量）：
#   THRESH=-72  触发阈值(dBm)        MIN_AGE=90   连接满多少秒才处理(防抖)
#   KICK_MAX=2  冷却期内引导几次后强踢   COOLDOWN=600 冷却窗口(秒)
#
# 说明：本固件的 hostapd ubus 不支持 rrm_nr_set 字符串格式（返回 Invalid argument），
#       因此无法通过 rrm_nr_set 注入 11k 邻居表；改用 11v 主动引导 + 功率平衡。
set -u

THRESH=${THRESH:--72}
MIN_AGE=${MIN_AGE:-90}
KICK_MAX=${KICK_MAX:-2}
COOLDOWN=${COOLDOWN:-600}
STATE=/tmp/roam-steer.state
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

command -v ubus >/dev/null 2>&1 || { echo "缺少 ubus"; exit 1; }

state_get() { awk -v m="$1" '$1==m{print $2" "$3}' "$STATE" 2>/dev/null; }
state_set() {
	awk -v m="$1" '$1!=m' "$STATE" 2>/dev/null > "$STATE.tmp"
	printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE.tmp"
	mv "$STATE.tmp" "$STATE"
}

now=$(date +%s)

for iface in wlan0 wlan1-1; do
	[ -d "/sys/class/net/$iface" ] || continue
	iw dev "$iface" station dump 2>/dev/null | awk '
		/^Station/ {mac=$2}
		/^[[:space:]]*signal:/ {sig=$2}
		/connected time:/ {if (mac!="" && sig!="") print mac, sig, $3}
	' | while read -r mac sig ct; do
		case "$sig" in ''|*[!-0-9]*) continue ;; esac
		[ "$sig" -gt "$THRESH" ] && continue
		[ "${ct:-0}" -lt "$MIN_AGE" ] && continue

		set -- $(state_get "$mac")
		last=${1:-0}; cnt=${2:-0}

		if [ $((now - last)) -lt "$COOLDOWN" ] && [ "$cnt" -ge "$KICK_MAX" ]; then
			if [ "$DRY" -eq 1 ]; then
				echo "[dry] del_client $mac@$iface (${sig}dBm, 已引导 ${cnt} 次无效)"
			else
				ubus call "hostapd.$iface" del_client \
					"{\"addr\":\"$mac\",\"deauth\":true,\"reason\":5,\"ban_time\":10000}" >/dev/null 2>&1
				logger -t roam-steer "del_client $mac@$iface (${sig}dBm, 引导 ${cnt} 次无效)"
			fi
			state_set "$mac" "$now" 0
		else
			if [ "$DRY" -eq 1 ]; then
				echo "[dry] bss_tm_req $mac@$iface (${sig}dBm, 在线 ${ct}s)"
			else
				ubus call "hostapd.$iface" bss_transition_request \
					"{\"addr\":\"$mac\",\"disassociation_imminent\":true,\"disassociation_timer\":10,\"validity_period\":100}" >/dev/null 2>&1
				logger -t roam-steer "bss_tm_req $mac@$iface (${sig}dBm)"
			fi
			state_set "$mac" "$now" $((cnt + 1))
		fi
	done
done
