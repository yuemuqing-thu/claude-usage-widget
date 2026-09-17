#!/bin/sh
# collect.sh — 桌面挂件的数据命令。输出一段 JSON。
#
# 同时采集两家，挂件里可以切：
#   claude  额度来自 statusLine 写的快照；统计来自 ~/.claude/projects/**/*.jsonl
#   codex   额度和统计都来自 ~/.codex/sessions/**/*.jsonl(.zst) —— 全程不联网、不读凭据
#
# jsonl 是只追加的，所以按「已处理字节数」做增量扫描：首次全量几秒，之后只读新增部分。
# 只用 sh + awk，无外部依赖。

set -u

LIB=$(cd "$(dirname "$0")" && pwd)
STATE="$HOME/.claude/usage-widget"
WINDOW=91
CODEX_CACHE_VERSION=4

# 「这台机器装没装 Claude Code」不能看 ~/.claude 在不在 —— install.sh 自己就会
# mkdir 它。得看 Claude Code 自己创建的东西：主配置文件，或者会话目录。
CLAUDE_PROJ="${CLAUDE_PROJ:-$HOME/.claude/projects}"
CLAUDE_CFG="${CLAUDE_CFG:-$HOME/.claude.json}"

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

# 原来这里每轮启动 91 次 date；挂件常驻后，这部分进程开销比真正的增量扫描还大。
# 用同一套公历换算一次生成整个窗口，BSD awk 也能运行。
DAYS=$(awk -v now="$NOW" -v tzoff="$TZOFF" -v window="$WINDOW" '
  function civil(z,   era, doe, yoe, y, doy, mp, d, m) {
    z += 719468
    era = (z >= 0 ? int(z / 146097) : int((z - 146096) / 146097))
    doe = z - era * 146097
    yoe = int((doe - int(doe/1460) + int(doe/36524) - int(doe/146096)) / 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe/4) - int(yoe/100))
    mp = int((5 * doy + 2) / 153)
    d = doy - int((153 * mp + 2) / 5) + 1
    m = mp + (mp < 10 ? 3 : -9)
    if (m <= 2) y++
    return sprintf("%04d-%02d-%02d", y, m, d)
  }
  BEGIN {
    today = int((now + tzoff) / 86400)
    for (i = window - 1; i >= 0; i--)
      printf "%s%s", (i == window - 1 ? "" : ","), civil(today - i)
    print ""
  }
')

# ---------- 一个数据源的增量扫描 ----------
# $1 缓存目录  $2 会话根目录  $3 scan 脚本
# Codex 从 2026-06 起会把超过 7 天的会话原地压成 rollout-*.jsonl.zst。
# 不读它们的话，热力图和柱状图只剩最近一周。macOS 不自带 zstd，找不到就跳过。
ZCAT=""
for _z in zstd zstdcat; do
  if command -v "$_z" >/dev/null 2>&1; then
    [ "$_z" = "zstd" ] && ZCAT="zstd -dcq" || ZCAT="zstdcat"
    break
  fi
done

scan_source() {
  _cache="$1"; _root="$2"; _scan="$3"; _seen="$4"
  mkdir -p "$_cache" 2>/dev/null
  [ -d "$_root" ] || return 0

  find "$_root" \( -name '*.jsonl' -o -name '*.jsonl.zst' \) -mtime -${WINDOW} -type f 2>/dev/null \
  | while IFS= read -r f; do
    [ -f "$f" ] || continue

    # basename 里的 rollout UUID 才是会话身份。完整路径会在 sessions →
    # archived_sessions 时变化，拿完整路径做键会把同一会话再统计一次。
    _base=$(basename "${f%.zst}")
    key=$(printf '%s' "$_base" | cksum | awk '{ print $1 "-" $2 }')
    printf '%s\n' "$key" >> "$_seen"

    # 压缩过的是冷文件，内容不会再变。键已去掉 .zst，跟压缩前是同一个缓存。
    case "$f" in
      *.jsonl.zst)
        agg="$_cache/$key.agg"
        [ -f "$agg" ] && continue                       # 压缩前已经统计过了
        [ -n "$ZCAT" ] || continue                      # 没有 zstd，只能跳过
        tmp="$agg.scan.$$"; new="$agg.new.$$"
        $ZCAT "$f" 2>/dev/null | awk -v TZOFF="$TZOFF" -f "$_scan" > "$tmp" 2>/dev/null
        { echo "#size zst"; cat "$tmp"; } > "$new" && mv -f "$new" "$agg"
        rm -f "$tmp" "$new"
        continue ;;
    esac
    size=$(stat -f %z "$f" 2>/dev/null) || continue
    [ "$size" -gt 0 ] || continue
    # 只检查这次快照边界上的字节，并且下面最多只读到这个 size。若文件在 stat
    # 之后继续增长，不能顺手把新尾部也读进去却仍保存旧游标，否则下轮会重复。
    [ "$(dd if="$f" bs=1 skip=$(( size - 1 )) count=1 2>/dev/null | od -An -c | tr -d ' \n')" = '\n' ] || continue
    agg="$_cache/$key.agg"

    prev=0
    [ -f "$agg" ] && prev=$(sed -n '1s/^#size //p' "$agg" 2>/dev/null)
    case "$prev" in ''|*[!0-9]*) prev=0 ;; esac

    if [ "$prev" -eq "$size" ]; then continue; fi

    tmp="$agg.scan.$$"; data="$agg.data.$$"; new="$agg.new.$$"
    if [ "$prev" -gt 0 ] && [ "$size" -gt "$prev" ]; then
      tail -c "+$(( prev + 1 ))" "$f" 2>/dev/null \
        | head -c "$(( size - prev ))" \
        | awk -v TZOFF="$TZOFF" -v STATE="$agg" -f "$_scan" > "$tmp"
      {
        grep -v '^#' "$agg" 2>/dev/null
        grep -v '^#' "$tmp" 2>/dev/null
      } | awk -F'\t' '
          { k = $1 FS $2; I[k]+=$3; O[k]+=$4; A[k]+=$5; B[k]+=$6; R[k]+=$7; N[k]+=$8; seen[k]=1 }
          END { for (k in seen) { split(k, p, FS)
                printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", p[1], p[2], I[k], O[k], A[k], B[k], R[k], N[k] } }
        ' > "$data"
      {
        echo "#size $size"
        grep '^#' "$tmp" 2>/dev/null
        cat "$data"
      } > "$new"
    else
      head -c "$size" "$f" | awk -v TZOFF="$TZOFF" -f "$_scan" > "$tmp"
      { echo "#size $size"; cat "$tmp"; } > "$new"
    fi
    [ -f "$new" ] && mv -f "$new" "$agg"
    rm -f "$tmp" "$data" "$new"
  done
}

# 精确删除本轮已经不存在的会话缓存。靠 mtime 延迟三天会让移动或删除后的会话
# 在界面里滞留；每轮 touch 全部缓存又会造成不必要的磁盘写入。
cleanup_cache() {
  _cache="$1"; _seen="$2"; _keys="$_cache/keys.$$"
  find "$_cache" -name '*.agg' -type f 2>/dev/null | sed 's|.*/||; s|[.]agg$||' > "$_keys"
  awk 'FILENAME == ARGV[1] { seen[$0] = 1; next } !seen[$0] { print }' "$_seen" "$_keys" \
    | while IFS= read -r _old; do [ -n "$_old" ] && rm -f "$_cache/$_old.agg"; done
  rm -f "$_keys" "$_seen"
}

# $1 缓存目录  $2 快照文件  $3 价格表（给 merge.awk）
emit_source() {
  _cache="$1"; _snap="$2"; _prices="$3"
  cat "$_cache"/*.agg 2>/dev/null | grep -v '^#' \
    | awk -v DAYS="$DAYS" -v TODAY="$TODAY" -v NOW="$NOW" -v SNAP="$_snap" \
          -v PRICES="$_prices" -f "$LIB/merge.awk"
}

# ---------- Claude ----------
CLAUDE_SEEN="$STATE/cache.seen.$$"
: > "$CLAUDE_SEEN"
scan_source "$STATE/cache" "$CLAUDE_PROJ" "$LIB/scan.awk" "$CLAUDE_SEEN"
cleanup_cache "$STATE/cache" "$CLAUDE_SEEN"

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
  # v4 仅识别真正的 token_count 事件；旧缓存可能把对该字段的
  # 讨论或命令文本当成用量。旧聚合无法可靠迁移，
  # 只在版本变化时清一次，随后仍走增量扫描。
  _cv=$(cat "$STATE/cache-codex.version" 2>/dev/null || true)
  if [ "$_cv" != "$CODEX_CACHE_VERSION" ]; then
    rm -rf "$STATE/cache-codex"
    mkdir -p "$STATE/cache-codex"
    printf '%s\n' "$CODEX_CACHE_VERSION" > "$STATE/cache-codex.version"
  fi
  # 额度：Codex 每回合结束写的 token_count 事件里就带着服务端的 rate_limits
  # 快照，所以直接从本地会话文件读，不需要凭据也不需要联网。
  # 数据的新鲜度 = 你最后一次用 Codex 的时间，挂件会把它显示出来。
  CSNAP="$STATE/codex-snapshot.env"
  _rl=$( { find "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions" \
             -name '*.jsonl' -type f -print0 2>/dev/null \
           | xargs -0 stat -f '%m %N' 2>/dev/null \
           | sort -rn | head -12 | cut -d' ' -f2- ; } | tr '\n' '\0' \
         | xargs -0 grep -h '"rate_limits"' 2>/dev/null \
         | awk -v NOW="$NOW" -f "$LIB/codex-limits.awk" 2>/dev/null )
  if [ -n "$_rl" ]; then
    printf '%s\n' "$_rl" > "$CSNAP.tmp.$$" 2>/dev/null \
      && mv -f "$CSNAP.tmp.$$" "$CSNAP" 2>/dev/null
    rm -f "$CSNAP.tmp.$$" 2>/dev/null
  fi
  CODEX_SEEN="$STATE/cache-codex.seen.$$"
  : > "$CODEX_SEEN"
  scan_source "$STATE/cache-codex" "$CODEX_HOME/sessions"          "$LIB/scan-codex.awk" "$CODEX_SEEN"
  scan_source "$STATE/cache-codex" "$CODEX_HOME/archived_sessions" "$LIB/scan-codex.awk" "$CODEX_SEEN"
  cleanup_cache "$STATE/cache-codex" "$CODEX_SEEN"
fi

# ---------- 输出 ----------
CL=$(emit_source "$STATE/cache" "$STATE/snapshot.env" "claude")
if [ "$CODEX_ON" = "1" ]; then
  CX=$(emit_source "$STATE/cache-codex" "$STATE/codex-snapshot.env" "codex")
else
  CX="null"
fi

HAS_CLAUDE=false
if [ -f "$CLAUDE_CFG" ] || [ -d "$CLAUDE_PROJ" ]; then HAS_CLAUDE=true; fi

HAS_CODEX=false
[ "$CODEX_ON" = "1" ] && [ -d "$CODEX_HOME" ] && HAS_CODEX=true

printf '{"ok":true,"gen":%s,"hasClaude":%s,"hasCodex":%s,"sources":{"claude":%s,"codex":%s}}\n' \
  "$NOW" "$HAS_CLAUDE" "$HAS_CODEX" "$CL" "$CX"
