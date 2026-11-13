#!/bin/sh
# mihomo-switch — 代理总开关（连 DNS 链路一起切，避免关掉代理后全屋断网）
#
# 关掉时：停 mihomo 服务 + 把 dnsmasq 的 DNS 还回运营商/上游
# 打开时：恢复 dnsmasq → mihomo(1053) + 启动 mihomo
# 选择会写 /etc/mihomo/disabled 标记，开机时 /etc/init.d/mihomo 会据此处理
#
# 互斥（两台 360T7）：不允许两台同时开代理（TUN/DNS 会冲突）。
# 开本端前先探测对端 9090（mihomo controller），对端在监听则拒绝并提示。
# 对端经 mesh 可达；mesh 断开时探测失败→允许（两台独立，各服务各的客户端，不冲突）。
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

# 互斥：本机开启前，若对端 9090 有响应（对端代理开）则拒绝
peer_block() {
	MYIP=$(uci get network.lan.ipaddr 2>/dev/null)
	case "$MYIP" in
		192.168.10.1) PEER=192.168.10.2 ;;
		192.168.10.2) PEER=192.168.10.1 ;;
		*) return 0 ;;   # 无法确定对端，不拦截
	esac
	code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://$PEER:9090/version" 2>/dev/null)
	case "$code" in
		''|000) return 0 ;;   # 对端未监听/不可达 → 允许
		*) ;;
	esac
	logger -t mihomo-switch "互斥：对端 $PEER 代理已开(HTTP $code)，拒绝本端开启"
	echo "❌ 对端($PEER)的代理已开启，两台不能同时开（TUN/DNS 会冲突）。"
	echo "   请先在对端执行 mihomo-switch off，再开本端。"
	exit 1
}

case "${1:-status}" in
on)
	peer_block
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
