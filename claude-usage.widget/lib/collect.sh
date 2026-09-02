#!/bin/sh
# collect.sh — 桌面挂件的数据命令。输出一段 JSON。
#
# 同时采集两家，挂件里可以切：
#   claude  额度来自 statusLine 写的快照；统计来自 ~/.claude/projects/**/*.jsonl
#   codex   额度来自 codex-usage-fetch.sh 写的快照；统计来自 ~/.codex/sessions/**/*.jsonl
#
# jsonl 是只追加的，所以按「已处理字节数」做增量扫描：首次全量几秒，之后只读新增部分。
# 只用 sh + awk，无外部依赖。

set -u

LIB=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$LIB/../bin" 2>/dev/null && pwd)
STATE="$HOME/.claude/usage-widget"
WINDOW=91

mkdir -p "$STATE" 2>/dev/null

# ---------- 时间 ----------
NOW=$(date +%s)
TODAY=$(date +%Y-%m-%d)

OFFRAW=$(date +%z)
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

# ---------- 一个数据源的增量扫描 ----------
# $1 缓存目录  $2 会话根目录  $3 scan 脚本
scan_source() {
  _cache="$1"; _root="$2"; _scan="$3"
  mkdir -p "$_cache" 2>/dev/null
  [ -d "$_root" ] || return 0

  find "$_root" -name '*.jsonl' -mtime -${WINDOW} -type f 2>/dev/null | while IFS= read -r f; do
    [ -f "$f" ] || continue
    # 只在文件以换行结尾时推进游标，否则说明正好写到一半，这轮跳过
    [ "$(tail -c 1 "$f" 2>/dev/null | od -An -c | tr -d ' \n')" = '\n' ] || continue

    size=$(stat -f %z "$f" 2>/dev/null) || continue
    key=$(printf '%s' "$f" | cksum | awk '{ print $1 "-" $2 }')
    agg="$_cache/$key.agg"

    prev=0
    [ -f "$agg" ] && prev=$(sed -n '1s/^#size //p' "$agg" 2>/dev/null)
    case "$prev" in ''|*[!0-9]*) prev=0 ;; esac

    if [ "$prev" -eq "$size" ]; then touch "$agg"; continue; fi

    tmp="$agg.tmp"
    if [ "$prev" -gt 0 ] && [ "$size" -gt "$prev" ]; then
      {
        sed '1d' "$agg" 2>/dev/null
        tail -c "+$(( prev + 1 ))" "$f" 2>/dev/null | awk -v TZOFF="$TZOFF" -f "$_scan"
      } | awk -F'\t' '
          { k = $1 FS $2; I[k]+=$3; O[k]+=$4; A[k]+=$5; B[k]+=$6; R[k]+=$7; N[k]+=$8; seen[k]=1 }
          END { for (k in seen) { split(k, p, FS)
                printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", p[1], p[2], I[k], O[k], A[k], B[k], R[k], N[k] } }
        ' > "$tmp"
    else
      awk -v TZOFF="$TZOFF" -f "$_scan" "$f" > "$tmp"
    fi
    { echo "#size $size"; cat "$tmp"; } > "$agg" && rm -f "$tmp"
  done

  find "$_cache" -name '*.agg' -mtime +3 -delete 2>/dev/null
}

# $1 缓存目录  $2 快照文件  $3 价格表（给 merge.awk）
emit_source() {
  _cache="$1"; _snap="$2"; _prices="$3"
  cat "$_cache"/*.agg 2>/dev/null | grep -v '^#' \
    | awk -v DAYS="$DAYS" -v TODAY="$TODAY" -v NOW="$NOW" -v SNAP="$_snap" \
          -v PRICES="$_prices" -f "$LIB/merge.awk"
}

# ---------- Claude ----------
scan_source "$STATE/cache"       "$HOME/.claude/projects" "$LIB/scan.awk"

# ---------- Codex ----------
# 默认跟随环境：机器上有 Codex 就启用，没有就完全不触发（也就不读凭据、不联网）。
# 想关掉：claude-usage-widget codex off —— 会落一个 codex.off 标记。
CODEX_ON=0
# Codex 目录：环境变量 > 配置文件 > 默认。配置文件那条是给两种人用的 ——
# 把 Codex 装在非标准位置的，和想拿假数据先看看界面长什么样的。
CODEX_HOME="${CODEX_HOME:-}"
if [ -z "$CODEX_HOME" ] && [ -f "$STATE/codex.home" ]; then
  CODEX_HOME=$(head -1 "$STATE/codex.home" 2>/dev/null)
fi
[ -z "$CODEX_HOME" ] && CODEX_HOME="$HOME/.codex"

if [ ! -f "$STATE/codex.off" ] && [ -d "$CODEX_HOME" ]; then CODEX_ON=1; fi

if [ "$CODEX_ON" = "1" ]; then
  # 额度：最多每 60 秒问一次，别把接口打爆
  CSNAP="$STATE/codex-snapshot.env"
  need=1
  if [ -f "$CSNAP" ]; then
    age=$(( NOW - $(stat -f %m "$CSNAP" 2>/dev/null || echo 0) ))
    [ "$age" -lt 60 ] && need=0
  fi
  if [ "$need" = "1" ] && [ -n "${BIN:-}" ] && [ -x "$BIN/codex-usage-fetch.sh" ]; then
    "$BIN/codex-usage-fetch.sh" >/dev/null 2>&1 &
  fi
  scan_source "$STATE/cache-codex" "$CODEX_HOME/sessions"          "$LIB/scan-codex.awk"
  scan_source "$STATE/cache-codex" "$CODEX_HOME/archived_sessions" "$LIB/scan-codex.awk"
fi

# ---------- 输出 ----------
CL=$(emit_source "$STATE/cache" "$STATE/snapshot.env" "claude")
if [ "$CODEX_ON" = "1" ]; then
  CX=$(emit_source "$STATE/cache-codex" "$STATE/codex-snapshot.env" "codex")
else
  CX="null"
fi

HAS_CODEX=false
[ "$CODEX_ON" = "1" ] && [ -d "$CODEX_HOME" ] && HAS_CODEX=true

printf '{"ok":true,"gen":%s,"hasCodex":%s,"sources":{"claude":%s,"codex":%s}}\n' \
  "$NOW" "$HAS_CODEX" "$CL" "$CX"
