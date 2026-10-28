#!/bin/sh
# 根据 /etc/mihomo/subs.list 与 /etc/mihomo/regions.conf 生成 /etc/mihomo/config.yaml
# subs.list 每行：名称|订阅URL|启用(0/1)
# regions.conf 每行：显示名|节点名正则
CONF=/etc/mihomo/config.yaml
SUBS=/etc/mihomo/subs.list
REGIONS=/etc/mihomo/regions.conf
PROVDIR=/etc/mihomo/providers
SECRET=$(cat /etc/mihomo/.secret 2>/dev/null)

[ -f "$SUBS" ] || : > "$SUBS"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-40; }

# 排除机场的"剩余流量/到期/官网"这类假节点
EXCLUDE_FILTER='(?i)(剩余流量|距离下次|套餐到期|官网|到期时间|expire|traffic left|自动选择|节点选择|故障转移|负载均衡|Direct|REJECT)'

# 若已有 provider 缓存，则判断该正则能否匹配到节点（避免生成空分组）
region_has_nodes() {
	regex=$(printf '%s' "$1" | sed 's/^(?i)//')
	[ -d "$PROVDIR" ] || return 0          # 没有缓存时先都生成
	ls "$PROVDIR"/*.yaml >/dev/null 2>&1 || return 0
	grep -hE '^[[:space:]]*-?[[:space:]]*name:' "$PROVDIR"/*.yaml 2>/dev/null | grep -qiE "$regex" 2>/dev/null
}

# 收集启用的订阅
subs_tmp=/tmp/.subs.enabled
: > "$subs_tmp"
while IFS='|' read -r name url en; do
	[ -z "$name" ] && continue
	[ -z "$url" ] && continue
	[ "${en:-1}" = "0" ] && continue
	printf '%s|%s\n' "$(sanitize "$name")" "$url" >> "$subs_tmp"
done < "$SUBS"
n=$(wc -l < "$subs_tmp")

{
cat <<'STATIC'
mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: rule
log-level: warning
ipv6: true
unified-delay: true
tcp-concurrent: true
find-process-mode: 'off'
external-controller: 0.0.0.0:9090
external-ui: ui
STATIC
[ -n "$SECRET" ] && echo "secret: \"$SECRET\""
cat <<'STATIC2'
profile:
  store-selected: true
sniffer:
  enable: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
  skip-domain:
    - '+.push.apple.com'
tun:
  enable: true
  stack: mixed
  device: mihomo0
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - 'any:53'
  strict-route: false
  mtu: 1500
dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: true
  enhanced-mode: redir-host
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
STATIC2

# ---- 订阅 (proxy-providers) ----
echo "proxy-providers:"
if [ "$n" -gt 0 ]; then
	while IFS='|' read -r name url; do
		echo "  $name:"
		echo "    type: http"
		echo "    url: \"$url\""
		echo "    interval: 3600"
		echo "    path: ./providers/$name.yaml"
		echo "    health-check:"
		echo "      enable: true"
		echo "      url: https://www.gstatic.com/generate_204"
		echo "      interval: 300"
	done < "$subs_tmp"
else
	echo "  {}"
fi

# ---- 策略组 ----
# 设计原则（避免风控）：
#   默认出口 = 第一个可用地区分组（同地区内切换，出口国家不变）
#   Auto     = 跨地区最快，仅作备选，不设为默认
#   Proxy 组同时挂出所有节点（use），可手动钉死某一个节点，选择会持久化
echo "proxy-groups:"

REG_LIST=/tmp/.regions.avail
: > "$REG_LIST"
if [ -f "$REGIONS" ]; then
	while IFS='|' read -r label regex; do
		[ -z "$label" ] && continue
		[ -z "$regex" ] && continue
		region_has_nodes "$regex" || continue
		printf '%s|%s\n' "$label" "$regex" >> "$REG_LIST"
	done < "$REGIONS"
fi
first_region=$(head -1 "$REG_LIST" 2>/dev/null | cut -d'|' -f1)

echo "  - name: Proxy"
echo "    type: select"
echo "    proxies:"
[ -n "$first_region" ] && echo "      - $first_region"
echo "      - Auto"
echo "      - DIRECT"
if [ -s "$REG_LIST" ]; then
	tail -n +2 "$REG_LIST" | while IFS='|' read -r label regex; do
		echo "      - $label"
	done
fi
if [ "$n" -gt 0 ]; then
	while IFS='|' read -r name url; do
		echo "      - sub-$name"
	done < "$subs_tmp"
	echo "    exclude-filter: \"$EXCLUDE_FILTER\""
	echo "    use:"
	while IFS='|' read -r name url; do echo "      - $name"; done < "$subs_tmp"
fi

echo "  - name: Auto"
echo "    type: url-test"
echo "    url: https://www.gstatic.com/generate_204"
echo "    interval: 300"
echo "    tolerance: 80"
echo "    proxies:"
echo "      - DIRECT"
if [ "$n" -gt 0 ]; then
	echo "    exclude-filter: \"$EXCLUDE_FILTER\""
	echo "    use:"
	while IFS='|' read -r name url; do echo "      - $name"; done < "$subs_tmp"
fi

# 地区分组：同地区内自动选最快（tolerance 放宽，减少无谓切换）
if [ -s "$REG_LIST" ]; then
	while IFS='|' read -r label regex; do
		echo "  - name: $label"
		echo "    type: url-test"
		echo "    url: https://www.gstatic.com/generate_204"
		echo "    interval: 300"
		echo "    tolerance: 80"
		echo "    proxies:"
		echo "      - DIRECT"
		if [ "$n" -gt 0 ]; then
			echo "    filter: \"$regex\""
			echo "    exclude-filter: \"$EXCLUDE_FILTER\""
			echo "    use:"
			while IFS='|' read -r name url; do echo "      - $name"; done < "$subs_tmp"
		fi
	done < "$REG_LIST"
fi

# 每个订阅一个分组
if [ "$n" -gt 0 ]; then
	while IFS='|' read -r name url; do
		echo "  - name: sub-$name"
		echo "    type: select"
		echo "    proxies:"
		echo "      - DIRECT"
		echo "    exclude-filter: \"$EXCLUDE_FILTER\""
		echo "    use:"
		echo "      - $name"
	done < "$subs_tmp"
fi

# ---- 规则 ----
# 广告拦截开关：/etc/mihomo/adblock.enabled（1=启用，0=停用），缺省视为启用
ADB=1
[ -f /etc/mihomo/adblock.enabled ] && ADB=$(cat /etc/mihomo/adblock.enabled 2>/dev/null)
case "$ADB" in 0) ;; *) ADB=1 ;; esac

if [ "$ADB" = "1" ]; then
	echo "rule-providers:"
	echo "  adblock:"
	echo "    type: file"
	echo "    behavior: domain"
	echo "    format: text"
	echo "    path: ./rules/anti-ad.txt"
	echo "rules:"
	echo "  - RULE-SET,adblock,REJECT"
else
	echo "rules:"
fi

cat <<'RULES'
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
RULES
} > "$CONF.tmp"

if /usr/bin/mihomo -t -d /etc/mihomo -f "$CONF.tmp" >/tmp/mihomo-check.log 2>&1; then
	mv "$CONF.tmp" "$CONF"
	rm -f "$subs_tmp" "$REG_LIST"
	echo "config OK -> $CONF"
else
	echo "config INVALID, keep old:"; tail -5 /tmp/mihomo-check.log
	rm -f "$CONF.tmp" "$subs_tmp" "$REG_LIST"
	exit 1
fi
