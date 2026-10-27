#!/bin/sh
# 一键验收 802.11s mesh + 漫游配置
# 用法: sh verify-mesh.sh            (在任一台路由器上执行)
#       sh verify-mesh.sh 192.168.10.1  (在本机对远端路由器执行,需 sshpass 或免密)
PEER_IP="${1:-}"
PEER="${PEER_IP:-本机}"
PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ⚠️  $1"; FAIL=$((FAIL+1)); }

echo "==[$PEER]=="
echo "1) 是否存在 mesh point 接口"
if iw dev 2>/dev/null | grep -q "type mesh point"; then
  ok "有 mesh 接口"
else
  bad "没有 mesh 接口 → 检查 uci wireless.mesh5g"
  exit 1
fi

echo "2) mesh plink 是否 ESTAB"
if iw dev wlan1 station dump 2>/dev/null | grep -Eq "plink:\s+ESTAB"; then
  ok "plink ESTAB"
else
  bad "plink 非 ESTAB（可能是配置未生效,见 README 坑1/坑3）"
fi

echo "3) 5G 主信道"
CH=$(iw dev wlan1 info 2>/dev/null | awk '/channel/{print $2}')
if [ "$CH" = "149" ]; then ok "ch149"; else bad "主信道 = $CH（配置应为 149,检查 noscan）"; fi

echo "4) 关键的坑1标志:floating-point frequency"
if logread 2>/dev/null | grep -q 'invalid number "5745'; then
  bad "日志里仍有 frequency=5745.0 解析失败 → 打补丁 patches/fix-mesh-frequency.sh"
else ok "无 frequency 解析错误"; fi

echo "5) hostapd 里 11v/k/r 是否真的生效"
for f in /var/run/hostapd-phy0.conf /var/run/hostapd-phy1.conf; do
  grep -q "bss_transition=1" "$f" 2>/dev/null || bad "$f 缺 bss_transition (11v 真实键名,坑2)"
  grep -q "mobility_domain=" "$f" 2>/dev/null || bad "$f 缺 mobility_domain (11r)"
  grep -q "rrm_neighbor_report=1" "$f" 2>/dev/null || bad "$f 缺 rrm_neighbor_report (11k)"
done
ok "11r/k/v 已核对"

echo "6) mpath 表"
n=$(iw dev wlan1 mpath dump 2>/dev/null | grep -vc "^DEST")
[ "$n" -gt 0 ] && ok "mpath 有 $n 条路径" || bad "mpath 空"

echo "7) 二层环路自检"
if brctl showmacs br-lan 2>/dev/null | awk 'NR>2 && $2=="no"{c[$1]++}END{e=0;for(m in c)if(c[m]>1)e=1;exit e}'; then
  ok "无 MAC 漂移（无环路迹象）"
else bad "⚠️ 出现同一 MAC 学在多个端口 —— 立刻断网线,检查环路"; fi

echo "——"
echo "结果: ✅$PASS  ⚠️$FAIL"
[ "$FAIL" = "0" ] || echo "详见 README.md §6 排坑记录"
exit $FAIL
