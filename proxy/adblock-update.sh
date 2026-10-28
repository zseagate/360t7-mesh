#!/bin/sh
# adblock-update — 自动更新 mihomo 的广告拦截规则（anti-AD）
#
# 用法:
#   adblock-update            更新规则并热重载 mihomo
#   adblock-update --check    只检查各源是否可用，不落盘
#   adblock-update --status   显示当前规则状态
#
# 由 cron 每日调用（见 /etc/crontabs/root）：
#   30 4 * * * /usr/sbin/adblock-update >/dev/null 2>&1

set -u
TARGET=/etc/mihomo/rules/anti-ad.txt
TMP=/tmp/.anti-ad-domains.txt
RAW=/tmp/.anti-ad-raw.txt
MIN_LINES=50000          # 少于这个数视为下载不完整，放弃本次更新
STATE=/etc/mihomo/rules/adblock.state

# 记录最近一次运行结果，供网页/命令查看：时间|状态|条数|来源|说明
set_state() {
	printf '%s|%s|%s|%s|%s\n' "$(date '+%F %T')" "$1" "${2:-0}" "${3:-}" "${4:-}" > "$STATE" 2>/dev/null
}

SOURCES="
https://cdn.jsdelivr.net/gh/privacy-protection-tools/anti-AD@master/anti-ad-easylist.txt
https://anti-ad.net/easylist.txt
https://ghfast.top/https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-easylist.txt
"

fetch_ok() {
	# $1=url  $2=输出文件；成功返回 0
	timeout 90 curl -sSL --retry 2 --retry-delay 2 -o "$2" "$1" 2>/dev/null || return 1
	[ -s "$2" ] || return 1
	# 粗校验：必须是 easylist 文本且有一定规模
	size=$(wc -c < "$2")
	[ "$size" -gt 200000 ] || return 1
	grep -q "^||" "$2" || return 1
	return 0
}

convert() {
	# easylist 的 ||domain^  ->  纯域名，去重排序
	awk -F'\\|\\|' '/^\|\|/{split($2,a,"\\^"); if(a[1]!="") print a[1]}' "$1" | sort -u > "$2"
}

reload_mihomo() {
	SEC=$(cat /etc/mihomo/.secret 2>/dev/null)
	code=$(curl -sS -o /dev/null -w '%{http_code}' -m 20 \
		-X PUT -H "Authorization: Bearer $SEC" -H 'Content-Type: application/json' \
		-d '{"path":"/etc/mihomo/config.yaml"}' \
		'http://127.0.0.1:9090/configs?force=true' 2>/dev/null)
	if [ "$code" = "204" ] || [ "$code" = "200" ]; then
		echo "   已热重载 mihomo（HTTP $code）"
		return 0
	fi
	echo "   热重载失败(HTTP ${code:-timeout})，改为重启服务"
	/etc/init.d/mihomo restart
	return 0
}

status() {
	if [ -f "$TARGET" ]; then
		printf "规则文件: %s\n" "$TARGET"
		printf "  域名条数: %s\n" "$(wc -l < "$TARGET")"
		printf "  大小: %s\n" "$(du -h "$TARGET" | cut -f1)"
		printf "  更新于: %s\n" "$(date -r "$TARGET" '+%Y-%m-%d %H:%M')"
	else
		echo "规则文件不存在: $TARGET"
	fi
	if [ -f "$STATE" ]; then
		echo "最近运行: $(cat "$STATE" | awk -F'|' '{printf "%s  状态=%s  条数=%s", $1,$2,$3}')"
	fi
	SEC=$(cat /etc/mihomo/.secret 2>/dev/null)
	echo "mihomo 侧:"
	curl -sS -m 10 -H "Authorization: Bearer ${SEC:-}" http://127.0.0.1:9090/providers/rules 2>/dev/null |
		sed 's/},{/}\n{/g' | grep -o '"name":"adblock"[^}]*' | head -1
}

case "${1:-update}" in
	--status|status) status; exit 0 ;;
	--check|check)
		for u in $SOURCES; do
			printf "%-96s " "$(echo "$u" | cut -c1-60)"
			timeout 40 curl -sSL -o /dev/null -w "%{http_code} %{size_download}B %{time_total}s\n" "$u" 2>&1 | tail -1
		done
		exit 0 ;;
esac

echo "== adblock-update $(date '+%F %T') =="
echo "[1/3] 下载规则"
got=""
for u in $SOURCES; do
	printf "  尝试 %s ... " "$(echo "$u" | cut -c1-58)"
	if fetch_ok "$u" "$RAW"; then
		echo "OK ($(du -h "$RAW" | cut -f1))"
		got="$u"
		break
	fi
	echo "失败"
done
[ -n "$got" ] || { echo "❌ 所有源均失败，保留旧规则"; rm -f "$RAW" "$TMP"; exit 1; }

echo "[2/3] 转换并校验"
convert "$RAW" "$TMP"
lines=$(wc -l < "$TMP")
echo "  域名条数: $lines"
if [ "$lines" -lt "$MIN_LINES" ]; then
	echo "❌ 条数异常(< $MIN_LINES)，保留旧规则"
	rm -f "$RAW" "$TMP"
	set_state fail 0 "$got" "条数异常(< $MIN_LINES)"
	exit 1
fi
old=$(wc -l < "$TARGET" 2>/dev/null || echo 0)
if [ "$old" -eq "$lines" ] && cmp -s "$TMP" "$TARGET"; then
	echo "ℹ️ 与现有规则完全一致，无需更新"
	rm -f "$RAW" "$TMP"
	set_state skip "$lines" "$got" "内容无变化"
	exit 0
fi

echo "[3/3] 落盘并重载"
mkdir -p "$(dirname "$TARGET")"
if cp "$TMP" "$TARGET.new" && mv "$TARGET.new" "$TARGET"; then
	echo "  ${old} -> ${lines} 条"
	reload_mihomo
	set_state ok "$lines" "$got" "更新成功"
else
	echo "❌ 写入失败"
	rm -f "$RAW" "$TMP" "$TARGET.new"
	set_state fail 0 "$got" "写入失败"
	exit 1
fi
rm -f "$RAW" "$TMP"
echo "✅ 完成"
