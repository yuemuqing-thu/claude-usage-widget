# scan.awk — 从 Claude Code 的 .jsonl 会话记录里提取每条 assistant 消息的 token 用量。
#
# 输入：jsonl 文本流（可以是整个文件，也可以是 tail -c 出来的增量片段）
# 输出：制表符分隔的日聚合行
#   <本地日期>\t<模型>\t<input>\t<output>\t<cache_5m>\t<cache_1h>\t<cache_read>\t<条数>
#
# 需要传入 -v TZOFF=<本地时区相对 UTC 的秒数>
#
# 只依赖 awk 自带能力，不用 mktime/strftime（macOS 自带的是 onetrueawk，没有这些扩展）。

function days_from_civil(y, m, d,   era, yoe, doy, doe) {
  if (m <= 2) y--
  era = (y >= 0 ? int(y / 400) : int((y - 399) / 400))
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}

function civil_from_days(z,   era, doe, yoe, y, doy, mp, m, d) {
  z += 719468
  era = (z >= 0 ? int(z / 146097) : int((z - 146096) / 146097))
  doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1
  m = mp + (mp < 10 ? 3 : -9)
  if (m <= 2) y++
  return sprintf("%04d-%02d-%02d", y, m, d)
}

# 取 s 中 "key": 后面紧跟的数字。找不到返回 0。
function num(s, key,   p, t) {
  p = index(s, "\"" key "\":")
  if (p == 0) return 0
  t = substr(s, p + length(key) + 3)
  return t + 0
}

# 取 s 中 "key":"..." 的字符串值。
function str(s, key,   p, t, q) {
  p = index(s, "\"" key "\":\"")
  if (p == 0) return ""
  t = substr(s, p + length(key) + 4)
  q = index(t, "\"")
  if (q == 0) return ""
  return substr(t, 1, q - 1)
}

# 找 pat 在 line 中最后一次出现的位置（1-based），没有则 0。
# 真正的 usage / timestamp 都在 JSON 靠后的位置，取最后一个可以避开
# assistant 正文里恰好写了同名字段的情况（比如这个项目本身的会话记录）。
function last_index(line, pat,   abs, rest, p, found) {
  abs = 0; rest = line; found = 0
  while ((p = index(rest, pat)) > 0) {
    abs = abs + p
    found = abs
    rest = substr(rest, p + 1)
  }
  return found
}

BEGIN {
  FS = "\n"
  USAGE_PAT = "\"usage\":{\"input_tokens\":"
  TS_PAT = "\"timestamp\":\""
}

{
  line = $0

  if (index(line, "\"type\":\"assistant\"") == 0) next

  us = last_index(line, USAGE_PAT)
  if (us == 0) next
  u = substr(line, us)

  # 同一个文件内按 requestId 去重（重放 / 分叉会话可能重复写入同一次请求）
  rid = str(line, "requestId")
  if (rid != "") {
    if (rid in seen) next
    seen[rid] = 1
  }

  model = str(line, "model")
  if (model == "" || model == "<synthetic>") next

  # 时间戳：2026-07-10T07:24:48.197Z
  tp = last_index(line, TS_PAT)
  if (tp == 0) next
  ts = substr(line, tp + length(TS_PAT), 19)
  if (substr(ts, 5, 1) != "-" || substr(ts, 11, 1) != "T") next

  y  = substr(ts, 1, 4)  + 0
  mo = substr(ts, 6, 2)  + 0
  dd = substr(ts, 9, 2)  + 0
  hh = substr(ts, 12, 2) + 0
  mi = substr(ts, 15, 2) + 0
  ss = substr(ts, 18, 2) + 0

  epoch = days_from_civil(y, mo, dd) * 86400 + hh * 3600 + mi * 60 + ss
  local = epoch + TZOFF
  day = civil_from_days(int(local / 86400))

  in_t  = num(u, "input_tokens")
  out_t = num(u, "output_tokens")
  cr_t  = num(u, "cache_read_input_tokens")
  c5    = num(u, "ephemeral_5m_input_tokens")
  c1    = num(u, "ephemeral_1h_input_tokens")
  cw_t  = num(u, "cache_creation_input_tokens")

  # 老版本记录可能没有 5m/1h 拆分，退回到总的 cache_creation，按 5m 计价
  if (c5 + c1 == 0 && cw_t > 0) c5 = cw_t

  k = day SUBSEP model
  I[k] += in_t; O[k] += out_t; C5[k] += c5; C1[k] += c1; R[k] += cr_t; N[k] += 1
  keys[k] = 1
}

END {
  for (k in keys) {
    split(k, a, SUBSEP)
    printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", a[1], a[2], I[k], O[k], C5[k], C1[k], R[k], N[k]
  }
}
