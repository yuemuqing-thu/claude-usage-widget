#!/bin/sh
# codex-usage-fetch.sh — 取 Codex 的额度百分比，写成快照供挂件读取。
#
# Codex 没有 Claude Code 那样的 statusLine 钩子（它的状态栏只能从内置项里选，
# 不能跑自定义脚本；openai/codex#20140、#20244 还开着）。额度也不落在本地会话
# 文件里。所以只能读本机已有的登录凭据，去问 ChatGPT 自己的后端。
#
#   凭据  ~/.codex/auth.json  →  tokens.access_token / tokens.account_id
#   接口  GET https://chatgpt.com/backend-api/wham/usage
#
# ⚠️ 这是未公开接口，OpenAI 随时可能改。所有失败都静默降级 —— 挂件顶多显示
#    「暂无数据」，绝不因为它崩掉。
# ⚠️ 凭据只发给 chatgpt.com 自己，不经任何第三方。
#
# 默认不启用。要用得先 `claude-usage-widget codex on`。

set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTH="$CODEX_HOME/auth.json"
STATE="$HOME/.claude/usage-widget"
SNAP="$STATE/codex-snapshot.env"
UA="claude-usage-widget/0.2"
TIMEOUT=8

mkdir -p "$STATE" 2>/dev/null

fail() { exit 0; }                     # 任何问题都安静退出，不写坏快照

[ -f "$AUTH" ] || fail
command -v curl >/dev/null 2>&1 || fail
command -v osascript >/dev/null 2>&1 || fail

# ---------- 取凭据（字段名试多个候选，防版本差异）----------
CREDS=$(osascript -l JavaScript -e '
function run(argv) {
  var p = argv[0];
  var s = $.NSString.stringWithContentsOfFileEncodingError($(p), 4, null);
  if (!s) return "";
  var d; try { d = JSON.parse(ObjC.unwrap(s)); } catch (e) { return ""; }
  var t = d.tokens || d.token || d;
  var at = t.access_token || t.accessToken || d.access_token || "";
  var ac = t.account_id || t.accountId || d.account_id || "";
  if (!at || !ac) return "";
  return at + "\t" + ac;
}' "$AUTH" 2>/dev/null) || fail
[ -n "$CREDS" ] || fail

TOKEN=$(printf '%s' "$CREDS" | cut -f1)
ACCT=$(printf '%s' "$CREDS" | cut -f2)
[ -n "$TOKEN" ] && [ -n "$ACCT" ] || fail

# ---------- 请求 ----------
BODY=$(curl -sS --max-time "$TIMEOUT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "ChatGPT-Account-ID: $ACCT" \
  -H "User-Agent: $UA" \
  -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/wham/usage" 2>/dev/null) || fail
[ -n "$BODY" ] || fail

# ---------- 解析成快照（键名跟 Claude 那份一致，merge.awk 不用改）----------
# 注意：不能用管道喂给 osascript 再读 /dev/stdin —— NSString 读管道读不到，
# 会静默拿到空串。落成临时文件、把路径当参数传进去。
RESP="$STATE/.codex-resp.$$.json"
printf '%s' "$BODY" > "$RESP" 2>/dev/null || fail
OUT=$(osascript -l JavaScript -e '
function run(argv) {
  var raw = $.NSString.stringWithContentsOfFileEncodingError($(argv[0]), 4, null);
  var txt = raw ? ObjC.unwrap(raw) : "";
  var d; try { d = JSON.parse(txt); } catch (e) { return ""; }
  // 结构可能变，几处候选都试一遍
  var rl = d.rate_limit || d.rateLimit ||
           (d.usage && (d.usage.rate_limit || d.usage.rateLimit)) || null;
  if (!rl) return "";
  function win(w) {
    if (!w || typeof w !== "object") return null;
    var pct = w.used_percent; if (pct == null) pct = w.usedPercent;
    if (pct == null) return null;
    var left = w.reset_after_seconds; if (left == null) left = w.resetAfterSeconds;
    var at = w.reset_at; if (at == null) at = w.resetAt;
    var now = Math.floor(Date.now() / 1000);
    if (at == null && left != null) at = now + Math.round(left);
    return { pct: pct, at: at == null ? 0 : Math.round(at) };
  }
  var p = win(rl.primary_window || rl.primaryWindow);
  var s = win(rl.secondary_window || rl.secondaryWindow);
  if (!p && !s) return "";
  var now = Math.floor(Date.now() / 1000);
  var out = ["snapshot_at=" + now];
  if (p) { out.push("five_pct=" + p.pct);  out.push("five_reset=" + p.at); }
  if (s) { out.push("seven_pct=" + s.pct); out.push("seven_reset=" + s.at); }
  return out.join("\n");
}' "$RESP" 2>/dev/null)
rm -f "$RESP" 2>/dev/null
[ -n "$OUT" ] || fail

tmp="$SNAP.tmp.$$"
printf '%s\n' "$OUT" > "$tmp" 2>/dev/null && mv -f "$tmp" "$SNAP" 2>/dev/null
rm -f "$tmp" 2>/dev/null
exit 0
