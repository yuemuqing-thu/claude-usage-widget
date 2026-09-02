# Codex 数据接入规格（从开源实现挖出来的，未在真机验证）

来源：MacSteini/Codex-Usage（GPL，只读规格没抄代码）+ ccusage 文档

## 一、额度（两个环）—— 走凭据 + 私有接口

凭据：`~/.codex/auth.json`
```json
{ "tokens": { "access_token": "...", "account_id": "..." } }
```

请求：
```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access_token>
ChatGPT-Account-ID: <account_id>
```

响应里我们要的部分：
```json
{ "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window":   { "used_percent": 42, "reset_after_seconds": 7200, "reset_at": 1756... },
    "secondary_window": { "used_percent": 18, "reset_after_seconds": 400000, "reset_at": ... }
} }
```

映射到挂件：
- `primary_window`   → 5 小时环
- `secondary_window` → 周额度环
- `used_percent`     → 环上的百分比
- `reset_after_seconds` → 「N 后重置」

**跟 Claude statusLine 的 snapshot 结构几乎同构**，所以复用同一套渲染。

## 二、本地统计（柱状图 / 热力图）—— 不联网

路径：`~/.codex/sessions/**/*.jsonl` 和 `~/.codex/archived_sessions/**/*.jsonl`
（可被 `CODEX_HOME` 覆盖）

每行是一个 JSON。要的是 `payload.type == "token_count"` 的事件。
`payload` 里还带 `model`、`model_provider`、`cwd`。

token 字段：
```
input_tokens, cached_input_tokens, output_tokens,
reasoning_output_tokens, total_tokens
```

⚠️ 与 Claude 的差异：
- Claude 是 `message.usage.{input_tokens, output_tokens, cache_*}`
- Codex 多了 `reasoning_output_tokens`，缓存字段只有 `cached_input_tokens` 一个
- 所以 scan 脚本要单独写一份，不能复用 scan.awk

## 三、没验证的地方（必须让装了 Codex 的人跑一遍）

1. auth.json 的实际字段名（可能有版本差异）
2. `/wham/usage` 是否仍然可用、响应结构是否一致
3. token_count 事件的确切嵌套层级
4. 时间戳字段名（用于按本地日期分桶）

→ 所以要配一个 `claude-usage-widget doctor --codex`，把找到的结构脱敏打印出来。
