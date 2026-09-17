# merge.awk — 把 scan.awk 产出的日聚合行合并成挂件用的 JSON。
#
# stdin : <日期>\t<模型>\t<in>\t<out>\t<c5m>\t<c1h>\t<cread>\t<条数>
# 变量  : DAYS=逗号分隔的 14 个日期（旧→新）  TODAY=今天  NOW=epoch  SNAP=快照文件路径
# stdout: 一整段 JSON

# ---- 各模型单价（美元 / 百万 token）----
# PRICES 变量决定用哪张表："claude"（默认）或 "codex"。
function price_in(m) {
  if (PRICES == "codex") {
    if (m ~ /^gpt-6-astra($|-)/)              return 10
    if (m == "gpt-5.6" || m ~ /^gpt-5[.]6-sol($|-)/) return 4
    if (m ~ /^gpt-5[.]6-terra($|-)/)          return 2
    if (m ~ /^gpt-5[.]6-luna($|-)/)           return 0.20
    if (m ~ /^gpt-5[.]5-pro($|-)/)            return 30
    if (m ~ /^gpt-5[.]5($|-)/)                return 5
    if (m ~ /^gpt-5[.]4-pro($|-)/)            return 30
    if (m ~ /^gpt-5[.]4-mini($|-)/)           return 0.75
    if (m ~ /^gpt-5[.]4-nano($|-)/)           return 0.20
    if (m ~ /^gpt-5[.]4($|-)/)                return 2.50
    if (m ~ /^gpt-5[.]2($|-)/)                return 1.75
    if (m ~ /gpt-5.*mini|o4-mini|o3-mini/) return 0.25
    if (m ~ /gpt-5|codex/)                 return 1.25
    if (m ~ /o3/)                          return 2
    if (m ~ /gpt-4\.1/)                    return 2
    return -1
  }
  if (m ~ /fable|mythos/)  return 10
  if (m ~ /sonnet-5/)      return 2
  if (m ~ /sonnet/)        return 3
  if (m ~ /haiku/)         return 1
  return 5                                  # opus 系列，也作为兜底
}
function price_out(m) {
  if (PRICES == "codex") {
    if (m ~ /^gpt-6-astra($|-)/)              return 50
    if (m == "gpt-5.6" || m ~ /^gpt-5[.]6-sol($|-)/) return 20
    if (m ~ /^gpt-5[.]6-terra($|-)/)          return 12
    if (m ~ /^gpt-5[.]6-luna($|-)/)           return 1.20
    if (m ~ /^gpt-5[.]5-pro($|-)/)            return 180
    if (m ~ /^gpt-5[.]5($|-)/)                return 30
    if (m ~ /^gpt-5[.]4-pro($|-)/)            return 180
    if (m ~ /^gpt-5[.]4-mini($|-)/)           return 4.50
    if (m ~ /^gpt-5[.]4-nano($|-)/)           return 1.25
    if (m ~ /^gpt-5[.]4($|-)/)                return 15
    if (m ~ /^gpt-5[.]2($|-)/)                return 14
    if (m ~ /gpt-5.*mini|o4-mini|o3-mini/) return 2
    if (m ~ /gpt-5|codex/)                 return 10
    if (m ~ /o3/)                          return 8
    if (m ~ /gpt-4\.1/)                    return 8
    return -1
  }
  if (m ~ /fable|mythos/)  return 50
  if (m ~ /sonnet-5/)      return 10
  if (m ~ /sonnet/)        return 15
  if (m ~ /haiku/)         return 5
  return 25
}

function price_cached(m,   p) {
  if (PRICES != "codex") return 0
  if (m ~ /^gpt-6-astra($|-)/)              return 1
  if (m == "gpt-5.6" || m ~ /^gpt-5[.]6-sol($|-)/) return 0.40
  if (m ~ /^gpt-5[.]6-terra($|-)/)          return 0.20
  if (m ~ /^gpt-5[.]6-luna($|-)/)           return 0.02
  if (m ~ /^gpt-5[.]5-pro($|-)|^gpt-5[.]4-pro($|-)/) return price_in(m)
  if (m ~ /^gpt-5[.]5($|-)/)                return 0.50
  if (m ~ /^gpt-5[.]4-mini($|-)/)           return 0.075
  if (m ~ /^gpt-5[.]4-nano($|-)/)           return 0.02
  if (m ~ /^gpt-5[.]4($|-)/)                return 0.25
  p = price_in(m)
  return (p < 0 ? -1 : p * 0.1)
}

# Claude：缓存写入 1.25×（5 分钟）/ 2×（1 小时）输入价，缓存读取 0.1× 输入价
# Codex：input_tokens 已包含 cached / cache_write，output_tokens 已包含 reasoning。
# 两个子集必须先从原价输入里扣掉，否则 token 和费用都会重复计算。
function calc_cost(m, i, o, c5, c1, cr,   pi, pc, po, plain) {
  pi = price_in(m); po = price_out(m)
  if (PRICES == "codex") {
    pc = price_cached(m)
    if (pi < 0 || pc < 0 || po < 0) return -1
    plain = i - c5 - c1
    if (plain < 0) plain = 0
    return (plain * pi + c5 * pc + c1 * pi * 1.25 + o * po) / 1000000
  }
  return (i * pi + c5 * pi * 1.25 + c1 * pi * 2 + cr * pi * 0.1 + o * po) / 1000000
}

# claude-opus-4-8 -> "Opus 4.8"
function pretty(m,   s, n, a, i, fam, ver) {
  s = m
  if (s ~ /^gpt-/) {
    gsub(/-/, " ", s)
    s = "GPT" substr(s, 4)
    gsub(/ sol/, " Sol", s); gsub(/ terra/, " Terra", s); gsub(/ luna/, " Luna", s)
    gsub(/ codex/, " Codex", s); gsub(/ mini/, " Mini", s); gsub(/ nano/, " Nano", s)
    gsub(/ pro/, " Pro", s); gsub(/ astra/, " Astra", s)
    return s
  }
  if (s ~ /^o[0-9]/) {
    gsub(/-/, " ", s); return toupper(substr(s,1,1)) substr(s,2)
  }
  sub(/^claude-/, "", s)
  n = split(s, a, "-")
  fam = toupper(substr(a[1], 1, 1)) substr(a[1], 2)
  ver = ""
  for (i = 2; i <= n; i++) {
    if (a[i] ~ /^[0-9]{8}$/) continue        # 丢掉 -20251001 这类日期后缀
    ver = (ver == "" ? a[i] : ver "." a[i])
  }
  return (ver == "" ? fam : fam " " ver)
}

function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }

BEGIN {
  FS = "\t"
  ndays = split(DAYS, day, ",")
  for (i = 1; i <= ndays; i++) idx[day[i]] = i
}

{
  d = $1; m = $2
  i = $3 + 0; o = $4 + 0; c5 = $5 + 0; c1 = $6 + 0; cr = $7 + 0; n = $8 + 0

  c = calc_cost(m, i, o, c5, c1, cr)
  # Claude 的缓存列是额外计费类别；Codex 的缓存与 reasoning 都已包含在 i/o。
  t = (PRICES == "codex" ? i + o : i + o + c5 + c1 + cr)

  # agg 缓存里存的是整个文件的历史，这里只统计 14 天窗口内的部分
  if (!(d in idx)) next
  if (c < 0) {
    c = 0; day_unpriced[idx[d]] = 1; span_unpriced = 1; model_unpriced[m] = 1
    if (d == TODAY) today_unpriced = 1
  }
  dcost[idx[d]] += c; dtok[idx[d]] += t

  span_cost += c; span_tok += t; span_msg += n
  mcost[m] += c; mtok[m] += t; models[m] = 1

  if (d == TODAY) { t_cost += c; t_tok += t; t_msg += n; t_in += i; t_out += o; t_cr += cr }
}

END {
  # ---- 读 statusLine 写下的额度快照 ----
  if (SNAP != "") {
    while ((getline ln < SNAP) > 0) {
      p = index(ln, "=")
      if (p > 0) S[substr(ln, 1, p - 1)] = substr(ln, p + 1)
    }
    close(SNAP)
  }

  # 近 7 天 / 近 14 天
  for (i = ndays - 6;  i <= ndays; i++) {
    w_cost += dcost[i]; w_tok += dtok[i]; if (day_unpriced[i]) w_unpriced = 1
  }
  for (i = ndays - 13; i <= ndays; i++) {
    f_cost += dcost[i]; f_tok += dtok[i]; if (day_unpriced[i]) f_unpriced = 1
  }

  printf "{\n"
  printf "  \"ok\": true,\n"
  printf "  \"gen\": %d,\n", NOW

  # ---- 官方额度 ----
  printf "  \"limits\": {"
  if ("snapshot_at" in S) {
    printf "\n    \"snapshot_at\": %d,\n", S["snapshot_at"] + 0
    printf "    \"age\": %d", NOW - (S["snapshot_at"] + 0)
    if ("five_pct" in S) {
      printf ",\n    \"five\": { \"pct\": %.2f, \"resets_at\": %d, \"in\": %d }",
        S["five_pct"] + 0, S["five_reset"] + 0, (S["five_reset"] + 0) - NOW
    }
    if ("seven_pct" in S) {
      printf ",\n    \"seven\": { \"pct\": %.2f, \"resets_at\": %d, \"in\": %d }",
        S["seven_pct"] + 0, S["seven_reset"] + 0, (S["seven_reset"] + 0) - NOW
    }
    if ("ctx_pct" in S)  printf ",\n    \"ctx\": %.2f", S["ctx_pct"] + 0
    if ("model" in S)    printf ",\n    \"model\": \"%s\"", jesc(S["model"])
    # Codex 会告诉你套餐名（Plus / Pro …），挂件在右上角显示
    if ("limit_name" in S) printf ",\n    \"plan\": \"%s\"", jesc(S["limit_name"])
    printf "\n  "
  }
  printf "},\n"

  # ---- 每日序列（完整 ISO 日期：热力图要按周几对齐）----
  printf "  \"days\": [\n"
  for (i = 1; i <= ndays; i++) {
    printf "    { \"d\": \"%s\", \"cost\": %.4f, \"tok\": %d, \"cost_complete\": %s }%s\n",
      day[i], dcost[i] + 0, dtok[i] + 0, (day_unpriced[i] ? "false" : "true"), (i < ndays ? "," : "")
  }
  printf "  ],\n"

  printf "  \"today\": { \"cost\": %.4f, \"cost_complete\": %s, \"tok\": %d, \"msgs\": %d, \"in\": %d, \"out\": %d, \"cache_read\": %d },\n",
    t_cost + 0, (today_unpriced ? "false" : "true"), t_tok + 0, t_msg + 0, t_in + 0, t_out + 0, t_cr + 0
  printf "  \"week\":  { \"cost\": %.4f, \"cost_complete\": %s, \"tok\": %d },\n",
    w_cost + 0, (w_unpriced ? "false" : "true"), w_tok + 0
  printf "  \"days14\": { \"cost\": %.4f, \"cost_complete\": %s, \"tok\": %d },\n",
    f_cost + 0, (f_unpriced ? "false" : "true"), f_tok + 0
  printf "  \"span\":  { \"cost\": %.4f, \"cost_complete\": %s, \"tok\": %d, \"msgs\": %d },\n",
    span_cost + 0, (span_unpriced ? "false" : "true"), span_tok + 0, span_msg + 0

  # ---- 按模型拆分，成本降序 ----
  nm = 0
  for (m in models) { nm++; ord[nm] = m }
  for (a = 1; a <= nm; a++)
    for (b = a + 1; b <= nm; b++)
      if (mtok[ord[b]] > mtok[ord[a]]) { tmp = ord[a]; ord[a] = ord[b]; ord[b] = tmp }

  printf "  \"models\": [\n"
  for (a = 1; a <= nm; a++) {
    m = ord[a]
    printf "    { \"id\": \"%s\", \"name\": \"%s\", \"cost\": %.4f, \"cost_complete\": %s, \"tok\": %d, \"share\": %.4f }%s\n",
      jesc(m), jesc(pretty(m)), mcost[m], (model_unpriced[m] ? "false" : "true"), mtok[m],
      (span_tok > 0 ? mtok[m] / span_tok : 0), (a < nm ? "," : "")
  }
  printf "  ]\n"
  printf "}\n"
}
