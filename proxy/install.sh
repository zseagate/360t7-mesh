#!/bin/sh
# install.sh —— 在 OpenWrt 路由器上部署「mihomo 代理 + 广告拦截 + 网页管理」
#
# 适合：OpenWrt 24.10 / aarch64（如 360T7 / MT7981），内存 ≥ 200MB，overlay 剩余 ≥ 60MB
# 特点：纯 TUN 模式，不依赖 firewall4 / nft 表 inet fw4（老 iptables 固件也能跑）
#
# 用法：
#   sh install.sh --dry-run     # 只打印将要做什么
#   sh install.sh               # 真正执行
#
# 前置：先把 mihomo 内核放到 /usr/bin/mihomo（见 README「安装内核」）
set -eu

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

SRC=$(cd "$(dirname "$0")" && pwd)
API=127.0.0.1:9090

say() { printf '\033[36m== %s\033[0m\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then echo "  [dry] $*"; else "$@"; fi; }

say "0. 环境检查"
[ -x /usr/bin/mihomo ] || { echo "缺少 /usr/bin/mihomo，请先安装内核（README 里有下载与校验步骤）"; exit 1; }
[ -e /dev/net/tun ] || { echo "缺少 /dev/net/tun（需要 kmod-tun）"; exit 1; }
avail=$(df -m /overlay | awk 'NR==2{print $4}')
if [ "$avail" -lt 20 ]; then
	if [ "$DRY" -eq 1 ]; then
		echo "  [warn] overlay 仅剩 ${avail}MB（真实执行要求 ≥20MB，dry-run 继续）"
	else
		echo "overlay 仅剩 ${avail}MB，请先腾出 20MB 以上"; exit 1
	fi
fi
echo "  mihomo: $(/usr/bin/mihomo -v | head -1)"
echo "  overlay 可用: ${avail}MB"

say "1. 创建目录"
for d in /etc/mihomo /etc/mihomo/providers /etc/mihomo/rules /etc/mihomo/ui \
         /www/mihomo /www/cgi-bin /usr/lib/lua/luci/controller /usr/lib/lua/luci/view; do
	run mkdir -p "$d"
done

say "2. 安装脚本与页面"
run cp "$SRC/gen-config.sh"          /etc/mihomo/gen-config.sh
run cp "$SRC/regions.conf"           /etc/mihomo/regions.conf
run cp "$SRC/mihomo.init"            /etc/init.d/mihomo
run cp "$SRC/adblock-update.sh"      /usr/sbin/adblock-update
run cp "$SRC/mihomo-backup.sh"       /usr/sbin/mihomo-backup
run cp "$SRC/www/cgi-bin/mihomo-sub" /www/cgi-bin/mihomo-sub
run cp "$SRC/www/mihomo/index.html"  /www/mihomo/index.html
run cp "$SRC/luci/controller/mihomo_ui.lua" /usr/lib/lua/luci/controller/mihomo_ui.lua
run cp "$SRC/luci/view/mihomo_ui.htm"       /usr/lib/lua/luci/view/mihomo_ui.htm
run chmod 755 /etc/mihomo/gen-config.sh /etc/init.d/mihomo \
	/usr/sbin/adblock-update /usr/sbin/mihomo-backup \
	/www/cgi-bin/mihomo-sub

say "3. 初始化凭据与订阅列表"
if [ -s /etc/mihomo/.secret ]; then
	echo "  secret 已存在，保留"
else
	run sh -c 'openssl rand -hex 12 > /etc/mihomo/.secret'
	run chmod 600 /etc/mihomo/.secret
	echo "  已生成新 secret: $(cat /etc/mihomo/.secret 2>/dev/null || echo '(dry-run)')"
fi
[ -f /etc/mihomo/subs.list ] || run sh -c ': > /tmp/subs.list && cp /tmp/subs.list /etc/mihomo/subs.list'

say "4. 生成配置（此时还没有订阅，先跑通直连）"
run /etc/mihomo/gen-config.sh

say "5. 让 dnsmasq 把 DNS 交给 mihomo"
run uci set dhcp.@dnsmasq[0].noresolv=1
# server 是 list 类型，必须用 add_list
run sh -c "uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#1053' 2>/dev/null || true"
run uci add_list dhcp.@dnsmasq[0].server=127.0.0.1#1053
run uci commit dhcp

say "6. TUN 接口加入 LAN 区域（否则 LAN→tun 转发会被丢）"
run sh -c "uci -q del_list firewall.@zone[0].device='mihomo0' 2>/dev/null || true"
run uci add_list firewall.@zone[0].device=mihomo0
run uci commit firewall

say "7. 加入 sysupgrade 保留清单"
if [ "$DRY" -eq 0 ]; then
	for f in /etc/mihomo/ /usr/bin/mihomo /etc/init.d/mihomo /www/mihomo/ \
	         /www/cgi-bin/mihomo-sub /usr/sbin/adblock-update /usr/sbin/mihomo-backup \
	         /usr/lib/lua/luci/controller/mihomo_ui.lua /usr/lib/lua/luci/view/mihomo_ui.htm; do
		grep -qx "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
	done
	echo "  已写入 /etc/sysupgrade.conf"
else
	echo "  [dry] 追加保留条目到 /etc/sysupgrade.conf"
fi

say "8. 启动服务"
run /etc/init.d/mihomo enable
run /etc/init.d/firewall reload
run /etc/init.d/dnsmasq restart
run /etc/init.d/mihomo restart

say "9. 初始化广告规则（需要外网）"
run /usr/sbin/adblock-update

say "10. 定时任务"
if [ "$DRY" -eq 0 ]; then
	grep -q 'mihomo-backup'   /etc/crontabs/root 2>/dev/null || echo "0 4 * * * /usr/sbin/mihomo-backup >/dev/null 2>&1"  >> /etc/crontabs/root
	grep -q 'adblock-update'  /etc/crontabs/root 2>/dev/null || echo "30 4 * * * /usr/sbin/adblock-update >/dev/null 2>&1" >> /etc/crontabs/root
	/etc/init.d/cron restart
	echo "  已添加：每天 4:00 备份、4:30 更新广告规则"
fi

say "完成"
cat <<EOF

接下来：
  1) 浏览器打开  http://<路由器IP>/mihomo/   添加订阅（名称 + Clash 订阅链接）
  2) 面板密钥：cat /etc/mihomo/.secret
  3) 面板地址：http://<路由器IP>:9090/ui/
  4) LuCI 菜单：服务 → 代理管理（已通过 iframe 挂载）

提示：默认出口锁定单一地区（香港），避免出口 IP 跨国跳变触发风控。
EOF
