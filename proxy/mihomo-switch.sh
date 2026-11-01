#!/bin/sh
# mihomo-switch — 代理总开关（连 DNS 链路一起切，避免关掉代理后全屋断网）
#
# 关掉时：停 mihomo 服务 + 把 dnsmasq 的 DNS 还回运营商/上游
# 打开时：恢复 dnsmasq → mihomo(1053) + 启动 mihomo
# 选择会写 /etc/mihomo/disabled 标记，开机时 /etc/init.d/mihomo 会据此处理
#
# 用法：mihomo-switch on|off|status|toggle
set -u
MARK=/etc/mihomo/disabled
UP=127.0.0.1#1053

dns_on() {
	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci -q del_list dhcp.@dnsmasq[0].server="$UP" 2>/dev/null
	uci add_list dhcp.@dnsmasq[0].server="$UP"
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

dns_off() {
	uci -q del_list dhcp.@dnsmasq[0].server="$UP" 2>/dev/null
	uci set dhcp.@dnsmasq[0].noresolv='0'
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

is_running() { /etc/init.d/mihomo status 2>&1 | grep -q "^running"; }

case "${1:-status}" in
on)
	rm -f "$MARK"
	dns_on
	/etc/init.d/mihomo start >/dev/null 2>&1
	sleep 2
	logger -t mihomo-switch "代理已开启"
	echo "代理已开启"
	;;
off)
	: > "$MARK"
	/etc/init.d/mihomo stop >/dev/null 2>&1
	dns_off
	logger -t mihomo-switch "代理已关闭（DNS 已切回直连）"
	echo "代理已关闭"
	;;
toggle)
	if [ -f "$MARK" ]; then "$0" on; else "$0" off; fi
	;;
status)
	if [ -f "$MARK" ]; then echo "off"; else echo "on"; fi
	;;
*)
	echo "用法: $0 on|off|status|toggle"; exit 1 ;;
esac
