#!/bin/sh
# apply-mesh-config.example.sh — 360T7 组 mesh (已脱敏,SSID/密码均为占位)
#
# 用法:
#   1) 本脚本在**卧室(哑AP)**上一次性执行,客厅侧只跑 "客厅部分" 下段(手动复制或 sed 拆分);
#   2) 所有 <...> 占位符必须替换;
#   3) 执行后用 ../scripts/verify-mesh.sh 验收。
#
set -u

SSID_5G="${SSID_5G:-MainWiFi-5G}"
SSID_2G="${SSID_2G:-MainWiFi-2G}"
WIFI_KEY="${WIFI_KEY:?need WIFI_KEY}"
MESH_ID="${MESH_ID:-MeshBackhaul}"
MESH_KEY="${MESH_KEY:?need MESH_KEY}"
MOBILITY_DOMAIN="${MOBILITY_DOMAIN:-4f57}"

BK=/root/config-backup-$(date +%Y%m%d-%H%M)
cp -a /etc/config "$BK" && echo "backup -> $BK"

### ---------- 深圳(5G/2.4G 频道) ----------
uci set wireless.radio0.channel='1'
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio0.country='CN'
uci set wireless.radio0.band='2g'
uci set wireless.radio1.band='5g'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.country='CN'
uci set wireless.radio1.noscan='1'
uci set wireless.radio1.txpower='23'

### ---------- SSID / 加密 / 漫游 ----------
uci set wireless.default_radio0.ssid="$SSID_2G"
uci set wireless.default_radio0.encryption='psk-mixed'
uci set wireless.default_radio0.key="$WIFI_KEY"
uci set wireless.default_radio1.ssid="$SSID_5G"
uci set wireless.default_radio1.encryption='psk-mixed'
uci set wireless.default_radio1.key="$WIFI_KEY"

for r in default_radio0 default_radio1; do
  # 11r (FT)
  uci set wireless.$r.ieee80211r='1'
  uci set wireless.$r.mobility_domain="$MOBILITY_DOMAIN"
  uci set wireless.$r.ft_over_ds='1'
  uci set wireless.$r.ft_psk_generate_local='1'
  # 11k (RRM)
  uci set wireless.$r.ieee80211k='1'
  # 11v —— 注意: 正确的 uci 键名是 bss_transition, 不是 ieee80211v!
  uci set wireless.$r.bss_transition='1'
  uci set wireless.$r.wnm_sleep_mode='1'
done

### ---------- 802.11s mesh 回程 ----------
uci -q delete wireless.mesh5g || true
uci set wireless.mesh5g=wifi-iface
uci set wireless.mesh5g.device='radio1'
uci set wireless.mesh5g.mode='mesh'
uci set wireless.mesh5g.mesh_id="$MESH_ID"
uci set wireless.mesh5g.mesh_fwding='1'
uci set wireless.mesh5g.network='lan'
uci set wireless.mesh5g.encryption='sae'   # 与 psk2 效果相同(hostapd.sh 对 mesh 强制 SAE)
uci set wireless.mesh5g.key="$MESH_KEY"
uci commit wireless

### ---------- 哑 AP (仅卧室执行)----------
if [ "${ROLE:-}" = "bedroom" ]; then
  uci set network.lan.ipaddr='192.168.10.2'
  uci set network.lan.netmask='255.255.255.0'
  uci set network.lan.gateway='192.168.10.1'
  uci set network.lan.dns='192.168.10.1'
  uci commit network

  uci set dhcp.lan.ignore='1'
  uci commit dhcp
  /etc/init.d/dnsmasq stop 2>/dev/null; /etc/init.d/dnsmasq disable
  /etc/init.d/odhcpd stop 2>/dev/null;  /etc/init.d/odhcpd disable

  uci set system.@system[0].hostname='bedroom'
  uci commit system
fi

uci commit wireless

### ---------- 应用(两阶段, 防 AP 抢 wlan1 名) ----------
# 阶段一:先把 AP 关掉,让 mesh 拿到 wlan1
uci set wireless.default_radio1.disabled='1'
uci commit wireless
wifi reload radio1
sleep 8
# 阶段二:把 AP 加回来,自动落到 wlan1-1
uci set wireless.default_radio1.disabled='0'
uci commit wireless
wifi reload radio1
sleep 10

echo "=== ifaces ==="
iw dev | grep -E "Interface|type"
echo "=== mesh ==="
iw dev wlan1 station dump 2>/dev/null | grep -E "^Station|plink|bitrate|signal"
iw dev wlan1 mpath dump 2>/dev/null
echo "=== 802.11r/k/v (真的生效才行) ==="
grep -E "bss_transition|wnm_sleep|rrm_neighbor|mobility_domain|ft_" /var/run/hostapd-phy0.conf /var/run/hostapd-phy1.conf

echo "=== 别忘了给 /lib/netifd/wireless/mac80211.sh 打好消息频率补丁! ==="
grep -n "print int(\$2)\|print \$2$" /lib/netifd/wireless/mac80211.sh | head -3
echo "(若仍是 'print \$2' → bash patches/fix-mesh-frequency.sh)"
