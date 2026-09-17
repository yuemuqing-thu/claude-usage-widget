#!/bin/sh
# 用最小的真实结构验证 Codex 日志解析、跨刷新增量和计价语义。

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cat > "$TMP/first.jsonl" <<'EOF'
{"timestamp":"2026-09-17T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
{"timestamp":"2026-09-17T00:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","input":"please inspect token_count and total_token_usage input_tokens 999999999 output_tokens 999999999"}}
{"timestamp":"2026-09-17T00:00:00Z","type":"event_msg","payload":{"type":"diagnostic","label":"token_count","total_token_usage":{"input_tokens":999999999,"output_tokens":999999999}}}
{"timestamp":"2026-09-17T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":800000,"cache_write_input_tokens":100000,"output_tokens":100000,"reasoning_output_tokens":50000,"total_tokens":1100000},"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":800000,"cache_write_input_tokens":100000,"output_tokens":100000,"reasoning_output_tokens":50000,"total_tokens":1100000}}}}
{"timestamp":"2026-09-17T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":800000,"cache_write_input_tokens":100000,"output_tokens":100000,"reasoning_output_tokens":50000,"total_tokens":1100000},"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":800000,"cache_write_input_tokens":100000,"output_tokens":100000,"reasoning_output_tokens":50000,"total_tokens":1100000}}}}
EOF

awk -v TZOFF=0 -f "$ROOT/claude-usage.widget/lib/scan-codex.awk" "$TMP/first.jsonl" > "$TMP/first.agg"
grep -F '#model	gpt-5.6-sol' "$TMP/first.agg" >/dev/null
grep -F '2026-09-17	gpt-5.6-sol	1000000	100000	800000	100000	50000	1' "$TMP/first.agg" >/dev/null

# 第二轮没有 turn_context，模型和累计基线都必须从缓存继承。
cat > "$TMP/next.jsonl" <<'EOF'
{"timestamp":"2026-09-17T00:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500000,"cached_input_tokens":1200000,"cache_write_input_tokens":150000,"output_tokens":150000,"reasoning_output_tokens":70000,"total_tokens":1650000},"last_token_usage":{"input_tokens":1,"cached_input_tokens":1,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2}}}}
EOF
awk -v TZOFF=0 -v STATE="$TMP/first.agg" -f "$ROOT/claude-usage.widget/lib/scan-codex.awk" "$TMP/next.jsonl" > "$TMP/next.agg"
grep -F '2026-09-17	gpt-5.6-sol	500000	50000	400000	50000	20000	1' "$TMP/next.agg" >/dev/null

grep -v '^#' "$TMP/first.agg" \
  | awk -v DAYS=2026-09-17 -v TODAY=2026-09-17 -v NOW=1 -v PRICES=codex \
      -f "$ROOT/claude-usage.widget/lib/merge.awk" > "$TMP/merged.json"
grep -F '"cost": 3.2200' "$TMP/merged.json" >/dev/null
grep -F '"tok": 1100000' "$TMP/merged.json" >/dev/null
grep -F '"name": "GPT 5.6 Sol"' "$TMP/merged.json" >/dev/null

printf '2026-09-17\tfuture-model\t100\t10\t0\t0\t0\t1\n' \
  | awk -v DAYS=2026-09-17 -v TODAY=2026-09-17 -v NOW=1 -v PRICES=codex \
      -f "$ROOT/claude-usage.widget/lib/merge.awk" > "$TMP/unknown.json"
grep -F '"cost_complete": false' "$TMP/unknown.json" >/dev/null

cat > "$TMP/limit.jsonl" <<'EOF'
{"timestamp":"2026-09-17T00:00:00Z","payload":{"type":"token_count","rate_limits":{"limit_name":null,"plan_type":"plus","primary":{"used_percent":12,"window_minutes":300,"resets_at":2000000000},"secondary":{"used_percent":34,"window_minutes":10080,"resets_at":2000000001}}}}
EOF
awk -v NOW=1 -f "$ROOT/claude-usage.widget/lib/codex-limits.awk" "$TMP/limit.jsonl" > "$TMP/limit.env"
grep -F 'limit_name=Plus' "$TMP/limit.env" >/dev/null

# 模拟「stat 之后文件继续增长」：磁盘上已有第二条事件，但第一次 stat 固定返回
# 第一段的字节数。采集器必须严格停在该边界，下一轮再且只再读取一次尾部。
mkdir -p "$TMP/home/.claude" "$TMP/codex/sessions/2026/09/17" "$TMP/bin"
RACE="$TMP/codex/sessions/2026/09/17/rollout-race.jsonl"
cat > "$RACE" <<'EOF'
{"timestamp":"2026-09-17T12:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
{"timestamp":"2026-09-17T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":800000,"cache_write_input_tokens":100000,"output_tokens":100000,"reasoning_output_tokens":50000,"total_tokens":1100000},"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":800000,"cache_write_input_tokens":100000,"output_tokens":100000,"reasoning_output_tokens":50000,"total_tokens":1100000}}}}
EOF
wc -c < "$RACE" | tr -d ' ' > "$TMP/limited-size"
cat >> "$RACE" <<'EOF'
{"timestamp":"2026-09-17T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500000,"cached_input_tokens":1200000,"cache_write_input_tokens":150000,"output_tokens":150000,"reasoning_output_tokens":70000,"total_tokens":1650000},"last_token_usage":{"input_tokens":500000,"cached_input_tokens":400000,"cache_write_input_tokens":50000,"output_tokens":50000,"reasoning_output_tokens":20000,"total_tokens":550000}}}}
EOF
cat > "$TMP/bin/stat" <<'EOF'
#!/bin/sh
if [ "$1" = "-f" ] && [ "$2" = "%z" ] && [ "${3:-}" = "$LIMITED_FILE" ]; then
  cat "$LIMITED_SIZE"
else
  exec /usr/bin/stat "$@"
fi
EOF
chmod +x "$TMP/bin/stat"

env HOME="$TMP/home" CODEX_HOME="$TMP/codex" LIMITED_FILE="$RACE" LIMITED_SIZE="$TMP/limited-size" \
  PATH="$TMP/bin:$PATH" sh "$ROOT/claude-usage.widget/lib/collect.sh" > "$TMP/bounded.json"
grep -F '"tok": 1100000' "$TMP/bounded.json" >/dev/null

HOME="$TMP/home" CODEX_HOME="$TMP/codex" sh "$ROOT/claude-usage.widget/lib/collect.sh" > "$TMP/after-grow.json"
HOME="$TMP/home" CODEX_HOME="$TMP/codex" sh "$ROOT/claude-usage.widget/lib/collect.sh" > "$TMP/stable.json"
grep -F '"tok": 1650000' "$TMP/after-grow.json" >/dev/null
grep -F '"tok": 1650000' "$TMP/stable.json" >/dev/null

echo "✓ Codex 真实结构、增量、计价和套餐解析通过"
