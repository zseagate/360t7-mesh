#!/bin/sh
# mihomo-backup — mihomo 配置一键备份/恢复（含内核配置、订阅、密钥、规则、面板）
#
# 用法:
#   mihomo-backup                备份（默认不含 UI 静态文件 / GeoSite.dat / 内核二进制）
#   mihomo-backup --full         备份时额外包含 /etc/mihomo/ui 与 GeoSite.dat
#   mihomo-backup --with-core    额外包含 /usr/bin/mihomo 内核（约 +20MB，谨慎使用）
#   mihomo-backup list           列出已有备份
#   mihomo-backup restore FILE   从备份恢复并重启服务
#   mihomo-backup clean          只执行轮转清理（保留最近 N 份）
#
# 环境变量:
#   KEEP=5                       保留份数（默认 5）

set -u
DIR=/root
PREFIX=mihomo-backup-
KEEP=${KEEP:-5}
DATE=$(date +%Y%m%d-%H%M%S)

# 备份内容
INCLUDE_BASE="/etc/mihomo /etc/init.d/mihomo /www/mihomo /www/cgi-bin/mihomo-sub /etc/sysupgrade.conf"
# BusyBox tar 不支持 --exclude，用 -X 排除文件；注意成员名已去掉开头的 /
EXCL_TMP=/tmp/.mihomo-backup.excl

write_excl() {
	# $1=1 表示 full 模式（只排除缓存与易变文件）
	if [ "${1:-0}" -eq 1 ]; then
		cat > "$EXCL_TMP" <<'EOF'
etc/mihomo/cache.db
etc/mihomo/providers/test.yaml
EOF
	else
		cat > "$EXCL_TMP" <<'EOF'
etc/mihomo/ui
etc/mihomo/GeoSite.dat
etc/mihomo/cache.db
EOF
	fi
}

usage() { awk 'NR>1 && NR<=22 && /^#/ {sub(/^# ?/,""); print}' "$0"; exit 1; }

list_backups() {
	ls -1t "$DIR/$PREFIX"*.tgz 2>/dev/null | while read -r f; do
		printf "%-40s %8s  %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%Y-%m-%d %H:%M')"
	done
	[ -z "$(ls -1 "$DIR/$PREFIX"*.tgz 2>/dev/null)" ] && echo "(暂无备份)"
}

rotate() {
	# 只保留最近 $KEEP 份
	n=0
	ls -1t "$DIR/$PREFIX"*.tgz 2>/dev/null | while read -r f; do
		n=$((n+1))
		[ "$n" -gt "$KEEP" ] && { rm -f "$f"; echo "  已清理旧备份: $(basename "$f")"; }
	done
}

do_backup() {
	full=0; with_core=0; force=0
	for a in "$@"; do
		case "$a" in
			--full) full=1 ;;
			--with-core) with_core=1; full=1 ;;
			--force) force=1 ;;
			*) usage ;;
		esac
	done

	need_mb=0
	[ "$full" -eq 1 ] && need_mb=6
	[ "$with_core" -eq 1 ] && need_mb=28
	if [ "$need_mb" -gt 0 ]; then
		avail=$(df -m /overlay | awk 'NR==2{print $4}')
		if [ "$avail" -lt "$need_mb" ]; then
			echo "⚠️ overlay 仅剩 ${avail}MB，该模式建议至少 ${need_mb}MB。已中止。"
			echo "   可先删除旧备份：mihomo-backup clean   或改用默认模式（不带 --full）"
			exit 1
		fi
	fi

	out="$DIR/${PREFIX}${DATE}.tgz"
	tmp="/tmp/.mihomo-backup.tgz"
	targets="$INCLUDE_BASE"
	[ "$with_core" -eq 1 ] && targets="$targets /usr/bin/mihomo"
	write_excl "$full"

	# shellcheck disable=SC2086
	tar czf "$tmp" -X "$EXCL_TMP" $targets 2>/dev/null
	if [ ! -s "$tmp" ]; then
		echo "❌ 备份失败（可能是空间不足）"; rm -f "$tmp"; exit 1
	fi

	# 内容与最新备份一致则跳过（省 flash 写入）
	latest=$(ls -1t "$DIR/$PREFIX"*.tgz 2>/dev/null | grep -v pre-restore | head -1)
	if [ "$force" -eq 0 ] && [ -n "$latest" ]; then
		sum_new=$(sha256sum "$tmp" | awk '{print $1}')
		sum_old=$(sha256sum "$latest" | awk '{print $1}')
		if [ "$sum_new" = "$sum_old" ]; then
			rm -f "$tmp"
			echo "ℹ️ 内容与最新备份完全一致，跳过（$(basename "$latest")）"
			echo "   如需强制新建：mihomo-backup --force"
			exit 0
		fi
	fi
	mv "$tmp" "$out"

	echo "✅ 备份完成: $out  ($(du -h "$out" | cut -f1))"
	echo "   内含: 配置/订阅/密钥/规则/自启脚本/订阅管理页$( [ "$full" -eq 1 ] && echo ' +面板静态文件' )$( [ "$with_core" -eq 1 ] && echo ' +内核' )"
	rotate
	echo "   保留最近 $KEEP 份，当前:"; list_backups | sed 's/^/     /'
}

do_restore() {
	f="$1"
	[ -f "$f" ] || { echo "文件不存在: $f"; exit 1; }
	echo "== 校验归档 =="
	tar tzf "$f" >/dev/null 2>&1 || { echo "❌ 归档损坏"; exit 1; }
	echo "== 备份当前配置到 /root/${PREFIX}pre-restore-${DATE}.tgz =="
	write_excl 0
	# shellcheck disable=SC2086
	tar czf "/root/${PREFIX}pre-restore-${DATE}.tgz" -X "$EXCL_TMP" $INCLUDE_BASE 2>/dev/null

	echo "== 停止服务 =="
	/etc/init.d/mihomo stop 2>/dev/null

	echo "== 解压覆盖 =="
	tar xzf "$f" -C / || { echo "❌ 解压失败"; exit 1; }
	chmod 755 /etc/init.d/mihomo /etc/mihomo/gen-config.sh 2>/dev/null
	chmod 600 /etc/mihomo/.secret 2>/dev/null
	chmod 755 /www/cgi-bin/mihomo-sub 2>/dev/null

	echo "== 生成配置并启动 =="
	[ -x /etc/mihomo/gen-config.sh ] && /etc/mihomo/gen-config.sh
	/etc/init.d/mihomo enable 2>/dev/null
	/etc/init.d/mihomo start
	sleep 5
	printf "   服务状态: "; /etc/init.d/mihomo status 2>&1 | head -1
	echo "✅ 恢复完成（secret: $(cat /etc/mihomo/.secret 2>/dev/null)）"
}

cmd=${1:-backup}
case "$cmd" in
	backup|"")     shift 2>/dev/null || true; do_backup "$@" ;;
	--full|--with-core|--force) do_backup "$@" ;;
	list)          list_backups ;;
	clean)         rotate; list_backups ;;
	restore)       shift; [ $# -ge 1 ] || usage; do_restore "$1" ;;
	-h|--help|help) usage ;;
	*)             usage ;;
esac
