# merge.awk — 把 scan.awk 产出的日聚合行合并成挂件用的 JSON。
#
# stdin : <日期>\t<模型>\t<in>\t<out>\t<c5m>\t<c1h>\t<cread>\t<条数>
# 变量  : DAYS=逗号分隔的 14 个日期（旧→新）  TODAY=今天  NOW=epoch  SNAP=快照文件路径
# stdout: 一整段 JSON

# ---- 各模型单价（美元 / 百万 token），与官方价目表一致 ----
function price_in(m) {
  if (m ~ /fable|mythos/)  return 10
  if (m ~ /sonnet-5/)      return 2
  if (m ~ /sonnet/)        return 3
  if (m ~ /haiku/)         return 1
  return 5                                  # opus 系列，也作为兜底
}
function price_out(m) {
  if (m ~ /fable|mythos/)  return 50
  if (m ~ /sonnet-5/)      return 10
  if (m ~ /sonnet/)        return 15
  if (m ~ /haiku/)         return 5
  return 25
}

# 缓存写入按 1.25×（5 分钟）/ 2×（1 小时）输入价，缓存读取按 0.1× 输入价
function calc_cost(m, i, o, c5, c1, cr,   pi, po) {
  pi = price_in(m); po = price_out(m)
  return (i * pi + c5 * pi * 1.25 + c1 * pi * 2 + cr * pi * 0.1 + o * po) / 1000000
}

# claude-opus-4-8 -> "Opus 4.8"
function pretty(m,   s, n, a, i, fam, ver) {
  s = m; sub(/^claude-/, "", s)
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
  t = i + o + c5 + c1 + cr

  # agg 缓存里存的是整个文件的历史，这里只统计 14 天窗口内的部分
  if (!(d in idx)) next
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
  for (i = ndays - 6;  i <= ndays; i++) { w_cost  += dcost[i]; w_tok  += dtok[i] }
  for (i = ndays - 13; i <= ndays; i++) { f_cost  += dcost[i]; f_tok  += dtok[i] }

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
    printf "\n  "
  }
  printf "},\n"

  # ---- 每日序列（完整 ISO 日期：热力图要按周几对齐）----
  printf "  \"days\": [\n"
  for (i = 1; i <= ndays; i++) {
    printf "    { \"d\": \"%s\", \"cost\": %.4f, \"tok\": %d }%s\n",
      day[i], dcost[i] + 0, dtok[i] + 0, (i < ndays ? "," : "")
  }
  printf "  ],\n"

  printf "  \"today\": { \"cost\": %.4f, \"tok\": %d, \"msgs\": %d, \"in\": %d, \"out\": %d, \"cache_read\": %d },\n",
    t_cost + 0, t_tok + 0, t_msg + 0, t_in + 0, t_out + 0, t_cr + 0
  printf "  \"week\":  { \"cost\": %.4f, \"tok\": %d },\n", w_cost + 0, w_tok + 0
  printf "  \"days14\": { \"cost\": %.4f, \"tok\": %d },\n", f_cost + 0, f_tok + 0
  printf "  \"span\":  { \"cost\": %.4f, \"tok\": %d, \"msgs\": %d },\n", span_cost + 0, span_tok + 0, span_msg + 0

  # ---- 按模型拆分，成本降序 ----
  nm = 0
  for (m in models) { nm++; ord[nm] = m }
  for (a = 1; a <= nm; a++)
    for (b = a + 1; b <= nm; b++)
      if (mcost[ord[b]] > mcost[ord[a]]) { tmp = ord[a]; ord[a] = ord[b]; ord[b] = tmp }

  printf "  \"models\": [\n"
  for (a = 1; a <= nm; a++) {
    m = ord[a]
    printf "    { \"id\": \"%s\", \"name\": \"%s\", \"cost\": %.4f, \"tok\": %d, \"share\": %.4f }%s\n",
      jesc(m), jesc(pretty(m)), mcost[m], mtok[m],
      (span_cost > 0 ? mcost[m] / span_cost : 0), (a < nm ? "," : "")
  }
  printf "  ]\n"
  printf "}\n"
}
