#!/bin/sh
# roam-stats —— 按天统计无线掉线次数，用于对比 roam-steer / 带宽调整的效果。
#
# 实现要点：OpenWrt 的 logread 是内存环形缓冲（默认 128KB，约 1~2 天），
# 滚掉或重启后旧事件就没了。所以每次采集：
#   ① 只读一份 logread 快照（一次读取，避免多次读取之间缓冲区变化导致计数错乱）；
#   ② 按天统计各原因的条数；
#   ③ 与已有记录**逐项取最大值**写回（idempotent，既不重复累加也不回退）。
# 环形缓冲约能覆盖 1.5 天，每小时采样一次完全够；即使某天滚出缓冲，
# 当天已记录的最大值会留在 daily.csv 里。
#
# 数据文件（默认 /etc/roam-stats，已加入 sysupgrade 保留清单）：
#   daily.csv   按天：日期,不活跃掉线,不活跃去认证,本地去认证(踢人),总掉线,11v请求
#   hourly.log  每次运行的当天快照（看曲线用）
#
# 用法
#   roam-stats              采集一次（cron 每小时调用）
#   roam-stats --show       打印统计表
#   roam-stats --purge N    只保留最近 N 天（默认 14）
set -u

DIR=${ROAM_STATS_DIR:-/etc/roam-stats}
DAILY=$DIR/daily.csv
HOURLY=$DIR/hourly.log
TMP=$DIR/.scan
HDR='日期,不活跃掉线,不活跃去认证,本地去认证(踢人),总掉线,11v请求'

mkdir -p "$DIR"
[ -f "$DAILY" ] || echo "$HDR" > "$DAILY"

purge() {
    keep=${1:-14}
    lines=$(( $(wc -l < "$DAILY") - 1 ))
    [ "$lines" -le "$keep" ] && return 0
    { head -1 "$DAILY"; tail -n "$keep" "$DAILY" | sort; } > "$DAILY.tmp"
    mv "$DAILY.tmp" "$DAILY"
}

collect() {
    # ① 单次快照
    logread > "$TMP" 2>/dev/null || :
    # ② 按天统计
    awk '
        BEGIN {
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", M, " ")
            for (i = 1; i <= 12; i++) mon[M[i]] = i
        }
        /^[A-Z][a-z][a-z] [A-Z][a-z][a-z] [ 0-9][0-9] / {
            d = sprintf("%04d-%02d-%02d", $5, mon[$2], $3)
            hit = 0
            if ($0 ~ /disassociated due to inactivity/)             { dis[d]++; hit = 1 }
            if ($0 ~ /deauthenticated due to inactivity/)            { dea[d]++; hit = 1 }
            if ($0 ~ /deauthenticated due to local deauth request/)  { loc[d]++; hit = 1 }
            if ($0 ~ /AP-STA-DISCONNECTED/)                          { all[d]++; hit = 1 }
            if ($0 ~ /roam-steer: bss_tm_req/)                       { tm[d]++; hit = 1 }
            if (hit) seen[d] = 1
        }
        END {
            for (d in seen)
                printf "%s,%d,%d,%d,%d,%d\n", d, dis[d], dea[d], loc[d], all[d], tm[d]
        }' "$TMP" | sort > "$TMP.count"

    # ③ 逐项取最大值合并（保留旧的更大值，新值更大则覆盖）
    tail -n +2 "$DAILY" > "$TMP.old"
    awk -F, -v OFS=, -v old_file="$TMP.old" '
        FILENAME == old_file { for (i = 2; i <= 6; i++) val[$1,i] = $i; keep[$1] = 1; next }
        {
            for (i = 2; i <= 6; i++) if ($i + 0 > val[$1,i] + 0) val[$1,i] = $i
            keep[$1] = 1
        }
        END {
            for (d in keep)
                print d, val[d,2] + 0, val[d,3] + 0, val[d,4] + 0, val[d,5] + 0, val[d,6] + 0
        }
    ' "$TMP.old" "$TMP.count" | sort > "$TMP.merged"
    { head -1 "$DAILY"; cat "$TMP.merged"; } > "$DAILY.new"
    mv "$DAILY.new" "$DAILY"
    rm -f "$TMP" "$TMP.count" "$TMP.old" "$TMP.merged"

    purge 14

    today=$(date +%Y-%m-%d)
    row=$(grep "^$today," "$DAILY" || echo "$today,0,0,0,0,0")
    echo "$(date '+%Y-%m-%d %H:%M:%S') $row" >> "$HOURLY"
    host=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo router)
    logger -t roam-stats "$host $row"
}

case "${1:-}" in
--show)
    printf '%-12s %10s %10s %10s %8s %8s\n' 日期 不活跃掉线 去认证 本地踢人 总掉线 11v请求
    tail -n +2 "$DAILY" | while IFS=, read -r d a b c e f; do
        printf '%-12s %10s %10s %10s %8s %8s\n' "$d" "$a" "$b" "$c" "$e" "$f"
    done
    ;;
--purge)
    purge "${2:-14}"; echo "已保留最近 ${2:-14} 天"
    ;;
*)
    collect
    ;;
esac
