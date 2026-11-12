#!/bin/sh
# chinaip-update — 自动更新 mihomo 的国内 IP 旁路表（china_ip_list.txt）
#
# 背景：mihomo TUN 模式把国内流量也压到 ~136Mbps。为了在国内直连全速，
# config.yaml 的 tun.route-exclude-address 里列出了中国 IP 段（不送 TUN）。
# 该列表要定期更新，否则新增的中国 IP 段仍会被送进 TUN（变慢）。
#
# 用法:
#   chinaip-update            下载→校验→落盘→重生成 config→重启 mihomo
#   chinaip-update --check    只检查各源是否可用，不落盘
#   chinaip-update --status   显示当前列表状态
#
# 由 cron 每周一 05:00 调用（见 /etc/crontabs/root）：
#   0 5 * * 1 /usr/sbin/chinaip-update >/dev/null 2>&1

set -u
TARGET=/etc/mihomo/china_ip_list.txt
TMP=/tmp/.china_ip_list.txt
MIN_LINES=5000           # 少于这个数视为下载不完整，放弃本次更新
STATE=/etc/mihomo/chinaip.state

# 记录最近一次运行结果：时间|状态|条数|来源|说明
set_state() {
	printf '%s|%s|%s|%s|%s\n' "$(date '+%F %T')" "$1" "${2:-0}" "${3:-}" "${4:-}" > "$STATE" 2>/dev/null
}

SOURCES="
https://cdn.jsdelivr.net/gh/17mon/china_ip_list@master/china_ip_list.txt
https://ghfast.top/https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt
https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt
"

fetch_ok() {
	# $1=url  $2=输出文件；成功返回 0
	timeout 90 curl -sSL --retry 2 --retry-delay 2 -o "$2" "$1" 2>/dev/null || return 1
	[ -s "$2" ] || return 1
	# 粗校验：行数达标且是 CIDR 格式
	lines=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$2" 2>/dev/null || echo 0)
	[ "$lines" -ge "$MIN_LINES" ] || return 1
	return 0
}

case "${1:-}" in
--check)
	for u in $SOURCES; do
		if fetch_ok "$u" "$TMP"; then
			echo "  可用: $u （$(wc -l < "$TMP") 条）"
			rm -f "$TMP"
			exit 0
		fi
		echo "  不可用: $u"
	done
	echo "  所有源均不可用"
	exit 1
	;;
--status)
	if [ -f "$TARGET" ]; then
		echo "  当前列表: $(wc -l < "$TARGET") 条  ($(wc -c < "$TARGET") 字节)"
	else
		echo "  当前列表: 不存在"
	fi
	[ -f "$STATE" ] && echo "  上次结果: $(cat "$STATE")"
	;;
*)
	for u in $SOURCES; do
		if fetch_ok "$u" "$TMP"; then
			break
		fi
		echo "  源不可用: $u" >&2
		TMP=""
	done
	[ -n "${TMP:-}" ] || { set_state fail 0 none "所有源均不可用"; echo "失败：无可用源"; exit 1; }

	# 内容完全相同则跳过（避免无谓的 mihomo 重启）
	if [ -f "$TARGET" ] && cmp -s "$TARGET" "$TMP"; then
		lines=$(wc -l < "$TMP")
		rm -f "$TMP"
		set_state skip "$lines" same "内容无变化，未重启"
		echo "已跳过（内容无变化，$(wc -l < "$TARGET") 条）"
		exit 0
	fi

	mv "$TMP" "$TARGET"
	lines=$(wc -l < "$TARGET")

	# 重生成 config 并重启（route-exclude-address 是启动时读取的，需重启）
	if /etc/mihomo/gen-config.sh >/dev/null 2>&1; then
		/etc/init.d/mihomo restart >/dev/null 2>&1
		set_state ok "$lines" chinaip "已更新并重启"
		echo "已更新（$lines 条）并重启 mihomo"
	else
		set_state fail "$lines" chinaip "gen-config 失败，已保留旧列表"
		echo "gen-config 失败，未重启（保留旧列表）"
		exit 1
	fi
	;;
esac
