#!/bin/sh
# collect.sh — 桌面挂件的数据命令。输出一段 JSON。
#
# 两路数据合并：
#   1. ~/.claude/usage-widget/snapshot.env  官方 5h / 7d 额度（由 statusLine 脚本写入）
#   2. ~/.claude/projects/**/*.jsonl        本地会话记录，算出近 14 天 token / 等价花费
#
# jsonl 文件是只追加的，所以按「已处理字节数」做增量扫描：首次全量几秒，
# 之后每次刷新只读新增的那几 KB。
#
# 只用 sh + awk，无外部依赖。

set -u

LIB=$(cd "$(dirname "$0")" && pwd)
STATE="$HOME/.claude/usage-widget"
CACHE="$STATE/cache"
SNAP="$STATE/snapshot.env"
PROJECTS="$HOME/.claude/projects"
WINDOW=91          # 热力图 13 周；柱状图在挂件里取最后 14 天

mkdir -p "$CACHE" 2>/dev/null

# ---------- 时间 ----------
NOW=$(date +%s)
TODAY=$(date +%Y-%m-%d)

OFFRAW=$(date +%z)                      # 形如 +0800
OSIGN=$(printf '%s' "$OFFRAW" | cut -c1)
OH=$(printf '%s' "$OFFRAW" | cut -c2-3)
OM=$(printf '%s' "$OFFRAW" | cut -c4-5)
TZOFF=$(( 10#$OH * 3600 + 10#$OM * 60 ))
[ "$OSIGN" = "-" ] && TZOFF=$(( -TZOFF ))

DAYS=""
i=$(( WINDOW - 1 ))
while [ $i -ge 0 ]; do
  d=$(date -v-${i}d +%Y-%m-%d 2>/dev/null) || d=$(date -d "-$i day" +%Y-%m-%d)
  DAYS="${DAYS}${DAYS:+,}${d}"
  i=$(( i - 1 ))
done

# 没有会话记录目录：只输出额度部分
if [ ! -d "$PROJECTS" ]; then
  printf '' | awk -v DAYS="$DAYS" -v TODAY="$TODAY" -v NOW="$NOW" -v SNAP="$SNAP" -f "$LIB/merge.awk"
  exit 0
fi

# ---------- 增量扫描 ----------
find "$PROJECTS" -name '*.jsonl' -mtime -${WINDOW} -type f 2>/dev/null | while IFS= read -r f; do
  [ -f "$f" ] || continue

  # 只在文件以换行结尾时推进游标，否则说明正好写到一半，这轮跳过
  [ "$(tail -c 1 "$f" 2>/dev/null | od -An -c | tr -d ' \n')" = '\n' ] || continue

  size=$(stat -f %z "$f" 2>/dev/null) || continue
  key=$(printf '%s' "$f" | cksum | awk '{ print $1 "-" $2 }')
  agg="$CACHE/$key.agg"

  prev=0
  [ -f "$agg" ] && prev=$(sed -n '1s/^#size //p' "$agg" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac

  if [ "$prev" -eq "$size" ]; then
    touch "$agg"
    continue
  fi

  tmp="$agg.tmp"
  if [ "$prev" -gt 0 ] && [ "$size" -gt "$prev" ]; then
    # 增量：老结果 + 新增字节的扫描结果，按 (日期,模型) 求和
    {
      sed '1d' "$agg" 2>/dev/null
      tail -c "+$(( prev + 1 ))" "$f" 2>/dev/null | awk -v TZOFF="$TZOFF" -f "$LIB/scan.awk"
    } | awk -F'\t' '
        { k = $1 FS $2; I[k]+=$3; O[k]+=$4; A[k]+=$5; B[k]+=$6; R[k]+=$7; N[k]+=$8; seen[k]=1 }
        END { for (k in seen) { split(k, p, FS)
              printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", p[1], p[2], I[k], O[k], A[k], B[k], R[k], N[k] } }
      ' > "$tmp"
  else
    # 全量：首次，或文件被截断/轮转过
    awk -v TZOFF="$TZOFF" -f "$LIB/scan.awk" "$f" > "$tmp"
  fi

  { echo "#size $size"; cat "$tmp"; } > "$agg" && rm -f "$tmp"
done

# 清掉不再对应任何活跃会话文件的缓存
find "$CACHE" -name '*.agg' -mtime +3 -delete 2>/dev/null

# ---------- 汇总输出 ----------
cat "$CACHE"/*.agg 2>/dev/null | grep -v '^#' \
  | awk -v DAYS="$DAYS" -v TODAY="$TODAY" -v NOW="$NOW" -v SNAP="$SNAP" -f "$LIB/merge.awk"
