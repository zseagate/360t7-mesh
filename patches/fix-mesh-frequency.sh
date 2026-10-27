#!/bin/sh
# fix-mesh-frequency.sh — 根治 802.11s mesh "frequency=5745.0" (浮点) 解析失败
#
# 背景:
#   新版 iw (>=6.17) 的 `iw phy info` 输出频率是 `5745.0 MHz`(浮点),
#   netifd 的 get_freq() 用 `awk '{print $2}'` 原样截取,
#   结果 netifd 给 wpa_supplicant 生成 `frequency=5745.0`,
#   wpa_supplicant 只接受整数 → 整个 network 块解析失败 → mesh 压根起不来。
#
# 症状(排在前面的优先看):
#   wpa_supplicant: Line 11: invalid number "5745.0"
#   wpa_suplicpant: failed to parse frequency '5745.0'.
#   netifd: Interface 1 setup failed: WPA_SUPPLICANT_FAILED / IFUP_ERROR
#   iw dev wlan1 永远 <NO-CARRIER>
#
# 说明:
#   - 补丁落在 /lib/netifd/ (overlay 可写层), 重启保留;
#   - **sysupgrade 会抹掉本补丁**, 升级完必须重跑一次;
#   - 与 encryption 是 sae 还是 psk2 无关 — mesh 模式下 hostapd.sh 强制走 SAE;
#   - 幂等, 可重复执行。
#
set -e
F=/lib/netifd/wireless/mac80211.sh
BK="$F.bak-freq"

[ -e "$F" ] || { echo "not found: $F"; exit 1; }

echo "before : $(grep -n '^	print \$2$' "$F" 2>/dev/null || echo '(already patched)')"

# 若与原版一致则先备份
if ! [ -f "$BK" ]; then
  cp -a "$F" "$BK"
  echo "backup -> $BK"
fi

# 幂等替换
if grep -q '^	print \$2$' "$F"; then
  sed -i 's/^	print \$2$/	print int($2)/' "$F"
  echo "patched -> $F"
else
  echo "nothing to do (already patched?)"
fi

echo "after  : $(grep -n 'print int($2)\|^	print \$2$' "$F")"
echo "md5    : $(md5sum "$F")"

# 干跑验证 get_freq 现在输出整数
echo "dryrun : $(iw phy phy1 info 2>/dev/null | awk -v band="2:" -v channel="[149]" '
$1 ~ /Band/ { band_match = band == $2 }
band_match && $3 == "MHz" && $4 == channel { print int($2); exit }')"
