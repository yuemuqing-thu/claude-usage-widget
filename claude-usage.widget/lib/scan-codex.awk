# scan-codex.awk — 从 Codex 的 jsonl 会话记录里抽 token 用量，按本地日期分桶。
#
# 输入：~/.codex/sessions/**/*.jsonl（每行一个 JSON）
# 输出：<本地日期>\t<模型>\t<in>\t<out>\t<cached_in>\t<cache_write>\t<reasoning>\t<条数>
#       —— 列的位置跟 scan.awk 对齐，这样 merge.awk 一套逻辑能同时吃两家的数据。
#
# 跟 Claude 的差异：
#   Claude  message.usage.{input_tokens, output_tokens, cache_creation.*, cache_read_input_tokens}
#   Codex   payload.type=="token_count"，字段 {input_tokens, cached_input_tokens,
#           cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens}
#
# 模型在 turn_context 事件里，不在 token_count 事件里。增量扫描时 collect.sh 会把
# 本文件输出的 #model / #cum 元数据留在缓存中，再通过 STATE 传回来。这样即使本轮
# 新增内容从 token_count 开始，也不会丢模型；累计值分支也能跨刷新正确取差值。

# RFC3339 允许 Z，也允许 +HH:MM / -HH:MM。只按位置取时分秒会把带偏移的
# 时间戳当成 UTC —— 东八区就是 8 小时的误差。返回需要补上的秒数。
function tz_adjust(ts,   tail, p, sign, oh, om) {
  tail = substr(ts, 11)
  p = match(tail, /[+-][0-9][0-9]:?[0-9][0-9]$/)
  if (p == 0) return 0
  sign = substr(tail, p, 1)
  oh = substr(tail, p + 1, 2) + 0
  om = substr(tail, length(tail) - 1, 2) + 0
  return (sign == "-" ? 1 : -1) * (oh * 3600 + om * 60)
}

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
  LAST_PAT  = "\"last_token_usage\""
  TOTAL_PAT = "\"total_token_usage\""

  current_model = INITIAL_MODEL
  if (STATE != "") {
    while ((getline meta < STATE) > 0) {
      if (meta ~ /^#model\t/) current_model = substr(meta, 8)
      else if (meta ~ /^#cum\t/) {
        split(meta, cm, "\t")
        prev_i = cm[2] + 0; prev_o = cm[3] + 0; prev_ci = cm[4] + 0
        prev_cw = cm[5] + 0; prev_r = cm[6] + 0; have_prev = 1
      }
    }
    close(STATE)
  }
}

{
  line = $0

  # 每个 turn_context 之后的 token_count 都属于这个模型。不要取 session_meta
  # 里的 base_instructions.model_provenance，它不是这个回合实际使用的模型。
  if (index(line, "\"turn_context\"") > 0) {
    context_model = str_after(line, "model", 1)
    if (context_model != "") current_model = context_model
  }
  # 限定 token_count 必须是 type 的值，避免把标签等同名字符串当作用量。
  # 日志里的命令文本带转义引号，不应作为真正的 JSON 字段参与匹配。
  if (line !~ /"type"[ \t]*:[ \t]*"token_count"/) next

  # ---- 时间戳 → 本地日期 ----
  ts = str_after(line, "timestamp", 1)
  if (ts == "") next
  if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) next
  Y = substr(ts,1,4)+0; M = substr(ts,6,2)+0; D = substr(ts,9,2)+0
  hh = substr(ts,12,2)+0; mm = substr(ts,15,2)+0; ss = substr(ts,18,2)+0
  epoch = days_from_civil(Y,M,D) * 86400 + hh*3600 + mm*60 + ss + tz_adjust(ts)
  day = civil_from_days(int((epoch + TZOFF) / 86400))

  # ---- 模型 ----
  model = current_model
  if (model == "") model = str_after(line, "model", 1)  # 兼容曾把模型写在事件里的版本
  if (model == "") model = "unknown"

  # ---- token ----
  # 真实日志偶尔会重复写同一份 total_token_usage，但 last_token_usage 仍保留
  # 上一次的非零值。若盲信 last，就会重复计数。因此只要有累计值，一律对
  # 累计值取差；last 只用于没有累计值或累计值重置时的降级。
  total_base = last_pos(line, TOTAL_PAT)
  if (total_base > 0) {
    ti = num_after(line, "input_tokens", total_base)
    tc = num_after(line, "cached_input_tokens", total_base)
    tw = num_after(line, "cache_write_input_tokens", total_base)
    to_ = num_after(line, "output_tokens", total_base)
    tr = num_after(line, "reasoning_output_tokens", total_base)
    if (ti < 0 || to_ < 0) next
    if (tc < 0) tc = 0
    if (tw < 0) tw = 0
    if (tr < 0) tr = 0
    if (have_prev) {
      i = ti - prev_i; o = to_ - prev_o; ci = tc - prev_ci
      cw = tw - prev_cw; r = tr - prev_r
    } else {
      i = ti; o = to_; ci = tc; cw = tw; r = tr
    }

    if (i < 0 || o < 0 || ci < 0 || cw < 0 || r < 0) {
      base = last_pos(line, LAST_PAT)
      if (base > 0) {
        i = num_after(line, "input_tokens", base); o = num_after(line, "output_tokens", base)
        ci = num_after(line, "cached_input_tokens", base); cw = num_after(line, "cache_write_input_tokens", base)
        r = num_after(line, "reasoning_output_tokens", base)
      } else {
        i = ti; o = to_; ci = tc; cw = tw; r = tr
      }
    }
    prev_i = ti; prev_o = to_; prev_ci = tc; prev_cw = tw; prev_r = tr; have_prev = 1
  } else {
    base = last_pos(line, LAST_PAT)
    if (base == 0) next
    i = num_after(line, "input_tokens", base); o = num_after(line, "output_tokens", base)
    ci = num_after(line, "cached_input_tokens", base); cw = num_after(line, "cache_write_input_tokens", base)
    r = num_after(line, "reasoning_output_tokens", base)
  }

  if (i < 0) i = 0; if (o < 0) o = 0; if (ci < 0) ci = 0
  if (cw < 0) cw = 0; if (r < 0) r = 0
  if (i == 0 && o == 0 && ci == 0 && cw == 0) next

  key = day "\t" model
  IN[key] += i; OUT[key] += o; CIN[key] += ci; CWRITE[key] += cw; RSN[key] += r; CNT[key]++
  seen[key] = 1
}

END {
  if (current_model != "") print "#model\t" current_model
  if (have_prev) printf "#cum\t%d\t%d\t%d\t%d\t%d\n", prev_i, prev_o, prev_ci, prev_cw, prev_r
  for (k in seen) {
    split(k, p, "\t")
    printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n",
           p[1], p[2], IN[k], OUT[k], CIN[k], CWRITE[k], RSN[k], CNT[k]
  }
}
