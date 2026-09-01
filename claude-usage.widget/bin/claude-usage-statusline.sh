#!/bin/sh
# claude-usage-statusline.sh
#
# 这是一个 Claude Code 的 statusLine 命令。Claude Code 会通过 stdin 递给它一段 JSON，
# 里面含有订阅额度的官方数值（rate_limits.five_hour / seven_day）——这是本机唯一
# 能拿到这两个百分比的地方。
#
# 它做两件事：
#   1. 把关键字段快照到 ~/.claude/usage-widget/snapshot.env（桌面挂件读这个文件）
#   2. 往 stdout 打印一行状态栏文本（Claude Code 会显示在输入框下方）
#
# 只用 sh + awk，不依赖 jq / python / node。

STATE_DIR="$HOME/.claude/usage-widget"
SNAP="$STATE_DIR/snapshot.env"
mkdir -p "$STATE_DIR" 2>/dev/null

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

printf '%s' "$INPUT" | awk -v snap="$SNAP" -v now="$(date +%s)" '
  # 把整个 stdin 当成一个字符串读进来（JSON 可能跨行）
  { buf = buf $0 }

  # 取 s 中 "key": 后面的数字
  function num(s, key,   p, t) {
    p = index(s, "\"" key "\":")
    if (p == 0) return ""
    t = substr(s, p + length(key) + 3)
    if (t !~ /^-?[0-9]/) return ""
    return t + 0
  }

  # 取 s 中 "key":"..." 的字符串值
  function str(s, key,   p, t, q) {
    p = index(s, "\"" key "\":\"")
    if (p == 0) return ""
    t = substr(s, p + length(key) + 4)
    q = index(t, "\"")
    if (q == 0) return ""
    return substr(t, 1, q - 1)
  }

  # 从 "key":{ 开始截取一段子串，用来把查找限制在某个对象内部
  # （used_percentage 在 context_window 和 rate_limits 里都出现，必须限定范围）
  function scope(s, key,   p) {
    p = index(s, "\"" key "\":{")
    if (p == 0) return ""
    return substr(s, p, 400)
  }

  function esc(s) { gsub(/[\r\n\t]/, " ", s); return s }

  # 把秒数转成 "2h14m" / "4d06h" / "38m"
  function human(sec,   d, h, m) {
    if (sec < 0) sec = 0
    d = int(sec / 86400); sec -= d * 86400
    h = int(sec / 3600);  sec -= h * 3600
    m = int(sec / 60)
    if (d > 0) return sprintf("%dd%02dh", d, h)
    if (h > 0) return sprintf("%dh%02dm", h, m)
    return sprintf("%dm", m)
  }

  # 8 格进度条
  function bar(pct,   i, n, s) {
    n = int(pct / 12.5 + 0.5); if (n > 8) n = 8; if (n < 0) n = 0
    s = ""
    for (i = 0; i < 8; i++) s = s (i < n ? "\342\226\223" : "\342\226\221")
    return s
  }

  END {
    rl   = scope(buf, "rate_limits")
    five = scope(rl,  "five_hour")
    sevn = scope(rl,  "seven_day")
    ctx  = scope(buf, "context_window")
    cost = scope(buf, "cost")
    mdl  = scope(buf, "model")
    ws   = scope(buf, "workspace")

    five_pct   = num(five, "used_percentage")
    five_reset = num(five, "resets_at")
    sevn_pct   = num(sevn, "used_percentage")
    sevn_reset = num(sevn, "resets_at")
    ctx_pct    = num(ctx,  "used_percentage")
    usd        = num(cost, "total_cost_usd")
    name       = str(mdl,  "display_name")
    dir        = str(ws,   "current_dir")
    sid        = str(buf,  "session_id")

    # ---------- 1. 写快照 ----------
    # 只在真的拿到额度数据时覆盖额度字段，避免用 API key 跑的会话把好数据抹掉
    if (five_pct != "" || sevn_pct != "") {
      tmp = snap ".tmp"
      printf "snapshot_at=%d\n", now                > tmp
      if (five_pct != "") {
        printf "five_pct=%.4f\n",  five_pct         > tmp
        printf "five_reset=%d\n",  five_reset       > tmp
      }
      if (sevn_pct != "") {
        printf "seven_pct=%.4f\n", sevn_pct         > tmp
        printf "seven_reset=%d\n", sevn_reset       > tmp
      }
      if (ctx_pct != "") printf "ctx_pct=%.2f\n", ctx_pct > tmp
      if (usd != "")     printf "session_cost=%.6f\n", usd > tmp
      if (name != "")    printf "model=%s\n", esc(name)    > tmp
      if (sid != "")     printf "session_id=%s\n", esc(sid) > tmp
      close(tmp)
      system("mv -f " "\"" tmp "\" \"" snap "\" 2>/dev/null")
    }

    # ---------- 2. 打印状态栏 ----------
    DIM  = "\033[2m"; R = "\033[0m"
    CORAL= "\033[38;5;209m"; GREY = "\033[38;5;245m"
    n = split(dir, parts, "/")
    short = (n > 0 ? parts[n] : "")

    out = CORAL "\342\227\211 " R (name != "" ? name : "Claude")
    if (short != "") out = out DIM "  " short R

    if (five_pct != "") {
      c = (five_pct >= 85 ? "\033[38;5;203m" : (five_pct >= 60 ? "\033[38;5;215m" : GREY))
      out = out DIM "  \342\224\202  " R c sprintf("5h %d%% ", int(five_pct + 0.5)) bar(five_pct) R
      if (five_reset > now) out = out DIM " " human(five_reset - now) R
    }
    if (sevn_pct != "") {
      c = (sevn_pct >= 85 ? "\033[38;5;203m" : (sevn_pct >= 60 ? "\033[38;5;215m" : GREY))
      out = out DIM "  \342\224\202  " R c sprintf("7d %d%%", int(sevn_pct + 0.5)) R
      if (sevn_reset > now) out = out DIM " " human(sevn_reset - now) R
    }
    if (ctx_pct != "") out = out DIM sprintf("  \342\224\202  ctx %d%%", int(ctx_pct + 0.5)) R

    print out
  }
'
