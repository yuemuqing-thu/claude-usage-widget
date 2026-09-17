# 从 Codex 的会话记录里读出订阅额度，不联网、不碰凭据。
#
# Codex 每次回合结束都会写一条 token_count 事件，自 protocol.rs 起
# 它带着服务端返回的 rate_limits 快照：
#
#   TokenCountEvent { info, rate_limits }
#   RateLimitSnapshot { limit_id, limit_name, primary, secondary, plan_type, ... }
#   RateLimitWindow   { used_percent, window_minutes, resets_at }
#
# 也就是说两个环要的三个数全在本地文件里，不需要读 auth.json 去调接口。
#
# 输入：若干 rollout-*.jsonl（顺序无所谓，按事件 timestamp 取最新的一条）
# 输出：five_pct / five_reset / seven_pct / seven_reset / snapshot_at / limit_name
#      —— 与 Claude 侧快照同名，merge.awk 不用改。

function after_key(s, key, from,   p, i, n) {
  p = index(substr(s, from), "\"" key "\"")
  if (p == 0) return 0
  i = from + p - 1 + length(key) + 2
  n = length(s)
  while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
  if (substr(s, i, 1) != ":") return 0
  i++
  while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
  return i
}

# 取 i 处那个 {...} 的完整子串（要数括号，窗口对象里还嵌着别的键）
function obj_at(s, i,   n, d, j, c, inq, esc) {
  n = length(s)
  if (substr(s, i, 1) != "{") return ""
  d = 0; inq = 0; esc = 0
  for (j = i; j <= n; j++) {
    c = substr(s, j, 1)
    if (inq) {
      if (esc) esc = 0
      else if (c == "\\") esc = 1
      else if (c == "\"") inq = 0
      continue
    }
    if (c == "\"") { inq = 1; continue }
    if (c == "{") d++
    else if (c == "}") { d--; if (d == 0) return substr(s, i, j - i + 1) }
  }
  return ""
}

function num_at(s, key,   i, t) {
  i = after_key(s, key, 1)
  if (i == 0) return "NA"
  t = substr(s, i)
  if (t ~ /^null/) return "NA"
  if (t !~ /^-?[0-9]/) return "NA"
  sub(/[^0-9eE.+-].*$/, "", t)
  return (t == "" ? "NA" : t + 0)
}

function str_at(s, key,   i, t, e) {
  i = after_key(s, key, 1)
  if (i == 0) return ""
  if (substr(s, i, 1) != "\"") return ""
  t = substr(s, i + 1)
  e = index(t, "\"")
  return (e ? substr(t, 1, e - 1) : "")
}

# ISO8601（UTC）→ epoch 秒。onetrueawk 没有 mktime，按公历天数公式自己算。
function iso_epoch(ts,   y, mo, d, h, mi, se, yy, era, yoe, doy, doe, days) {
  if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) return 0
  y  = substr(ts, 1, 4) + 0;  mo = substr(ts, 6, 2) + 0;  d  = substr(ts, 9, 2) + 0
  h  = substr(ts, 12, 2) + 0; mi = substr(ts, 15, 2) + 0; se = substr(ts, 18, 2) + 0
  yy = y - (mo <= 2 ? 1 : 0)
  era = int((yy >= 0 ? yy : yy - 399) / 400)
  yoe = yy - era * 400
  doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  days = era * 146097 + doe - 719468
  return days * 86400 + h * 3600 + mi * 60 + se
}

# ISO 时间戳 → 可比较的数字（只用来挑最新的一条，不做时区换算）
function ts_key(ts,   t) {
  t = ts
  gsub(/[^0-9]/, "", t)
  return t + 0
}

{
  if (index($0, "\"rate_limits\"") == 0) next
  rl = after_key($0, "rate_limits", 1)
  if (rl == 0) next
  snap = obj_at($0, rl)
  if (snap == "") next

  ts = ts_key(str_at($0, "timestamp"))
  if (ts <= best_ts) next

  # 两个窗口都按 window_minutes 归位，不假定 primary 就是 5 小时。
  # 官方给的是 300 / 10080，但换套餐可能不一样，所以取最接近的那个。
  bf_p = "NA"; bf_r = "NA"; bs_p = "NA"; bs_r = "NA"
  bf_d = -1; bs_d = -1
  for (k = 1; k <= 2; k++) {
    key = (k == 1 ? "primary" : "secondary")
    wi = after_key(snap, key, 1)
    if (wi == 0) continue
    w = obj_at(snap, wi)
    if (w == "") continue
    pct = num_at(w, "used_percent")
    if (pct == "NA") continue
    mins = num_at(w, "window_minutes")
    at   = num_at(w, "resets_at")
    if (at == "NA") {
      # 老版本给的是相对秒数
      rel = num_at(w, "resets_in_seconds")
      if (rel != "NA") at = NOW + rel
    }
    if (mins == "NA") mins = (k == 1 ? 300 : 10080)
    d5 = (mins > 300 ? mins - 300 : 300 - mins)
    d7 = (mins > 10080 ? mins - 10080 : 10080 - mins)
    if (d5 <= d7) { if (bf_d < 0 || d5 < bf_d) { bf_d = d5; bf_p = pct; bf_r = at } }
    else          { if (bs_d < 0 || d7 < bs_d) { bs_d = d7; bs_p = pct; bs_r = at } }
  }
  if (bf_p == "NA" && bs_p == "NA") next

  best_ts = ts
  f_p = bf_p; f_r = bf_r; s_p = bs_p; s_r = bs_r
  lname = str_at(snap, "limit_name")
  # 事件自身的时间就是这份数据的新鲜度，不能用文件 mtime
  ev = str_at($0, "timestamp")
}

END {
  if (best_ts == 0) exit 1
  e = iso_epoch(ev)
  if (e <= 0) e = NOW
  print "snapshot_at=" e
  if (f_p != "NA") { print "five_pct=" f_p;  if (f_r != "NA") print "five_reset=" f_r }
  if (s_p != "NA") { print "seven_pct=" s_p; if (s_r != "NA") print "seven_reset=" s_r }
  if (lname != "") print "limit_name=" lname
}
