# scan-codex.awk — 从 Codex 的 jsonl 会话记录里抽 token 用量，按本地日期分桶。
#
# 输入：~/.codex/sessions/**/*.jsonl（每行一个 JSON）
# 输出：<本地日期>\t<模型>\t<in>\t<out>\t<cached_in>\t<reasoning>\t0\t<条数>
#       —— 列的位置跟 scan.awk 对齐，这样 merge.awk 一套逻辑能同时吃两家的数据。
#
# 跟 Claude 的差异：
#   Claude  message.usage.{input_tokens, output_tokens, cache_creation.*, cache_read_input_tokens}
#   Codex   payload.type=="token_count"，字段 {input_tokens, cached_input_tokens,
#           output_tokens, reasoning_output_tokens, total_tokens}
#
# ⚠️ 嵌套层级没在真机验证过。所以这里不假设结构，只在整行里按键名找值，
#    并且优先用 last_token_usage（单次增量）；只有累计值时自己按文件算差。

function days_from_civil(y, m, d,   era, yoe, doy, doe) {
  if (m <= 2) y--
  era = (y >= 0 ? int(y / 400) : int((y - 399) / 400))
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}

function civil_from_days(z,   era, doe, yoe, y, doy, mp, d, m) {
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

# JSON 冒号前后都可能有空格（"key" : 1），所以不能匹配字面量 "key":。
# 先定位 "key"，再跳过空白和冒号，返回值起始处的绝对位置；找不到返回 0。
function after_key(s, key, from,   p, i, n) {
  p = index(substr(s, from), "\"" key "\"")
  if (p == 0) return 0
  i = from + p - 1 + length(key) + 2          # 跳过 "key"
  n = length(s)
  while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
  if (substr(s, i, 1) != ":") return 0
  i++
  while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
  return i
}

# 在 s 里找 key 对应的整数值
function num_after(s, key, from,   i, t) {
  i = after_key(s, key, from)
  if (i == 0) return -1
  t = substr(s, i)
  if (t !~ /^-?[0-9]/) return -1
  return t + 0
}

# 在 s 里找 key 对应的字符串值
function str_after(s, key, from,   i, rest, q) {
  i = after_key(s, key, from)
  if (i == 0) return ""
  if (substr(s, i, 1) != "\"") return ""
  rest = substr(s, i + 1)
  q = index(rest, "\"")
  return (q > 1) ? substr(rest, 1, q - 1) : ""
}

# 找 key 最后一次出现的位置（1 起；找不到返回 0）
function last_pos(s, key,   abs, rest, p, found) {
  abs = 0; rest = s; found = 0
  while ((p = index(rest, key)) > 0) {
    abs += p; found = abs
    rest = substr(rest, p + length(key)); abs += length(key) - 1
  }
  return found
}

BEGIN {
  FS = "\n"
  TOK_PAT   = "\"token_count\""
  LAST_PAT  = "\"last_token_usage\""
  TOTAL_PAT = "\"total_token_usage\""
}

{
  line = $0
  if (index(line, TOK_PAT) == 0) next        # 不是用量事件

  # ---- 时间戳 → 本地日期 ----
  ts = str_after(line, "timestamp", 1)
  if (ts == "") next
  if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) next
  Y = substr(ts,1,4)+0; M = substr(ts,6,2)+0; D = substr(ts,9,2)+0
  hh = substr(ts,12,2)+0; mm = substr(ts,15,2)+0; ss = substr(ts,18,2)+0
  epoch = days_from_civil(Y,M,D) * 86400 + hh*3600 + mm*60 + ss
  day = civil_from_days(int((epoch + TZOFF) / 86400))

  # ---- 模型 ----
  model = str_after(line, "model", 1)
  if (model == "") model = "unknown"

  # ---- token ----
  # 优先 last_token_usage（单次增量）；只有累计时按文件算差。
  base = last_pos(line, LAST_PAT)
  isDelta = (base > 0)
  if (!isDelta) base = last_pos(line, TOTAL_PAT)
  if (base == 0) base = 1

  i  = num_after(line, "input_tokens", base)
  ci = num_after(line, "cached_input_tokens", base)
  o  = num_after(line, "output_tokens", base)
  r  = num_after(line, "reasoning_output_tokens", base)
  if (i  < 0) i  = 0
  if (ci < 0) ci = 0
  if (o  < 0) o  = 0
  if (r  < 0) r  = 0
  if (i == 0 && o == 0 && ci == 0) next

  if (!isDelta) {
    # 累计值：跟同一文件上一条比，取增量。文件轮转导致变小时就当全新的。
    k = FILENAME "|" model
    di = i - pi[k]; do_ = o - po[k]; dc = ci - pc[k]; dr = r - pr[k]
    if (di < 0 || do_ < 0) { di = i; do_ = o; dc = ci; dr = r }
    pi[k] = i; po[k] = o; pc[k] = ci; pr[k] = r
    i = di; o = do_; ci = dc; r = dr
    if (i == 0 && o == 0 && ci == 0) next
  }

  key = day "\t" model
  IN[key] += i; OUT[key] += o; CIN[key] += ci; RSN[key] += r; CNT[key]++
  seen[key] = 1
}

END {
  for (k in seen) {
    split(k, p, "\t")
    # 第 7 列（Claude 的 cache_read）Codex 没有对应概念，填 0
    printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n",
           p[1], p[2], IN[k], OUT[k], CIN[k], RSN[k], 0, CNT[k]
  }
}
