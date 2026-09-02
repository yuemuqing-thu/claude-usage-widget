#!/bin/sh
# Claude Usage 桌面挂件 —— 安装脚本
#
#   claude-usage-widget install              安装
#   claude-usage-widget uninstall  卸载
#
# 做四件事：
#   1. 把 statusLine 脚本装到 ~/.claude/usage-widget/bin/
#   2. 在 ~/.claude/settings.json 里配好 statusLine（自动备份原文件）
#   3. 把挂件复制进 Übersicht 的 widgets 目录
#   4. 预热缓存并刷新 Übersicht
#
# 只依赖 macOS 自带的 sh / awk / osascript，不需要 jq、python、node。

set -u

SRC=$(cd "$(dirname "$0")" && pwd)
WIDGET_SRC="$SRC/claude-usage.widget"
STATE="$HOME/.claude/usage-widget"
BIN="$STATE/bin"
STATUSLINE="$BIN/claude-usage-statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

R='\033[0m'; B='\033[1m'; DIM='\033[2m'
OK='\033[38;5;114m'; CORAL='\033[38;5;209m'; WARN='\033[38;5;215m'; ERR='\033[38;5;203m'

say()  { printf "$*$R\n"; }
step() { printf "${CORAL}▸$R $*\n"; }
good() { printf "  ${OK}✓$R %s\n" "$*"; }
warn() { printf "  ${WARN}!$R %s\n" "$*"; }
die()  { printf "  ${ERR}✗$R %s\n" "$*"; exit 1; }

# ─────────────── 可靠地重启 Übersicht ───────────────
# 注意：`osascript -e 'tell application "Übersicht" to quit'` 可能返回 0 却
# 并没有真的退出（应用忙时会忽略）。而 enableInteraction 这个偏好只在启动时
# 读取，没真重启就等于没生效 —— 所以这里按 PID 确认，必要时升级到 SIGKILL。
# 另外 grep 一律匹配 "bersicht"，避开 Ü 在不同 locale 下的匹配问题。
ub_pid() { ps -eo pid,comm | grep -i bersicht | grep -v grep | grep -v node-arm | awk '{print $1}' | head -1; }

restart_ubersicht() {
  PID=$(ub_pid)
  if [ -n "$PID" ]; then
    osascript -e 'tell application "Übersicht" to quit' >/dev/null 2>&1
    i=0
    while [ $i -lt 8 ]; do
      sleep 1; i=$((i + 1))
      kill -0 "$PID" 2>/dev/null || break
    done
    if kill -0 "$PID" 2>/dev/null; then
      kill -TERM "$PID" 2>/dev/null
      sleep 2
      kill -0 "$PID" 2>/dev/null && { kill -9 "$PID" 2>/dev/null; sleep 1; }
    fi
  fi
  open -a "Übersicht" 2>/dev/null || open -a "Uebersicht" 2>/dev/null
  sleep 4
  [ -n "$(ub_pid)" ]
}

# ─────────────── 定位 Übersicht 的 widgets 目录 ───────────────
find_widgets_dir() {
  for d in \
    "$HOME/Library/Application Support/Übersicht/widgets" \
    "$HOME/Library/Application Support/Uebersicht/widgets"
  do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# 子命令：brew 装完之后用户敲 `claude-usage-widget install` 才真正启用。
# Homebrew 的 formula 不允许在 brew install 阶段改用户主目录，所以必须拆两步。
CMD="${1:-install}"
case "$CMD" in
  install|--install)     ACTION=install ;;
  uninstall|--uninstall) ACTION=uninstall ;;
  doctor)                ACTION=doctor ;;
  codex)                 ACTION=codex ;;
  -h|--help|help)
    say "用法："
    say "  claude-usage-widget install      安装并启用"
    say "  claude-usage-widget uninstall    卸载"
    say "  claude-usage-widget codex off    关掉 Codex 支持（默认是开的）"
    say "  claude-usage-widget codex on     再打开"
    say "  claude-usage-widget doctor       打印诊断信息（值已脱敏，可以直接发给别人）"
    exit 0 ;;
  *) die "未知命令：${CMD}（可用：install / uninstall / codex / doctor）" ;;
esac

STATE_DIR="$HOME/.claude/usage-widget"

# ═══════════════════════ codex 开关 ═══════════════════════
if [ "$ACTION" = "codex" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null
  _ch="${CODEX_HOME:-$HOME/.codex}"
  [ -f "$STATE_DIR/codex.home" ] && _ch=$(head -1 "$STATE_DIR/codex.home")
  case "${2:-}" in
    on)
      rm -f "$STATE_DIR/codex.off"
      say ""; step "Codex 支持：已启用"
      [ -d "$_ch" ] || warn "但这台机器上没找到 $_ch —— 装了 Codex 才会有数据"
      say "" ; exit 0 ;;
    off)
      : > "$STATE_DIR/codex.off"
      rm -f "$STATE_DIR/codex-snapshot.env" 2>/dev/null
      rm -rf "$STATE_DIR/cache-codex" 2>/dev/null
      say ""; step "Codex 支持：已关闭"
      printf "    ${DIM}相关缓存和快照都删了。不会再读凭据、也不会再联网。${R}\n"
      printf "    ${DIM}想开回来：claude-usage-widget codex on${R}\n\n"
      exit 0 ;;
    *)
      if [ -f "$STATE_DIR/codex.off" ]; then
        say "Codex 支持：已被手动关闭"
      elif [ -d "$_ch" ]; then
        say "Codex 支持：已启用（检测到 ${_ch}）"
      else
        say "Codex 支持：默认启用，但没找到 $_ch —— 装了 Codex 就会自动生效"
      fi
      say "用法：claude-usage-widget codex [on|off]"
      exit 0 ;;
  esac
fi

# ═══════════════════════ doctor ═══════════════════════
# 打印诊断信息。所有值都脱敏 —— 输出可以直接发给别人看。
if [ "$ACTION" = "doctor" ]; then
  ok()   { printf "  ${OK}✓${R} %s\n" "$*"; }
  no()   { printf "  ${ERR}✗${R} %s\n" "$*"; }
  info() { printf "    ${DIM}%s${R}\n" "$*"; }

  say ""
  step "环境"
  info "macOS $(sw_vers -productVersion 2>/dev/null || echo '?')  $(uname -m)"
  info "挂件版本 $(sed -n 's/^const PET_VERSION = \([0-9]*\).*/pet v\1/p' "$WIDGET_SRC/index.jsx" 2>/dev/null || echo '?')"
  for c in curl awk osascript; do
    command -v "$c" >/dev/null 2>&1 && ok "$c" || no "$c 缺失"
  done

  say ""
  step "Claude"
  [ -d "$HOME/.claude/projects" ] && ok "会话目录存在（$(find "$HOME/.claude/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ') 个 jsonl）" \
                                  || no "没有 ~/.claude/projects"
  if [ -f "$STATE_DIR/snapshot.env" ]; then
    _age=$(( $(date +%s) - $(stat -f %m "$STATE_DIR/snapshot.env" 2>/dev/null || echo 0) ))
    ok "额度快照存在（${_age} 秒前写的）"
    info "字段：$(cut -d= -f1 "$STATE_DIR/snapshot.env" 2>/dev/null | tr '\n' ' ')"
  else
    no "没有额度快照 —— statusLine 没配好，或还没跑过 Claude Code"
  fi
  info "缓存 $(ls "$STATE_DIR/cache"/*.agg 2>/dev/null | wc -l | tr -d ' ') 个"

  say ""
  step "Codex"
  CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
  if [ -f "$STATE_DIR/codex.off" ]; then no "被手动关闭了（claude-usage-widget codex on 开回来）"
  else ok "支持已启用（有 Codex 就自动生效）"; fi
  if [ -d "$CODEX_HOME" ]; then
    ok "CODEX_HOME = $CODEX_HOME"
    _n=$(find "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
    info "会话文件 $_n 个"
    if [ "$_n" -gt 0 ]; then
      _f=$(find "$CODEX_HOME/sessions" "$CODEX_HOME/archived_sessions" -name '*.jsonl' 2>/dev/null | head -1)
      _tc=$(grep -c 'token_count' "$_f" 2>/dev/null || echo 0)
      info "抽样文件含 token_count 事件 $_tc 条"
      # 用量事件的键名（只有键，没有值）
      if [ "$_tc" -gt 0 ]; then
        info "该事件的键名："
        grep -m1 'token_count' "$_f" 2>/dev/null | osascript -l JavaScript -e '
          function run(argv){ return ""; }' >/dev/null 2>&1
        grep -m1 'token_count' "$_f" 2>/dev/null \
          | tr ',{}' '\n\n\n' | grep -o '"[a-z_]*":' | sort -u | tr -d '":' | tr '\n' ' ' \
          | fold -w 70 -s | sed 's/^/      /'
        printf "\n"
      fi
      _parsed=$(awk -v TZOFF=0 -f "$WIDGET_SRC/lib/scan-codex.awk" "$_f" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$_parsed" -gt 0 ]; then ok "解析器能读出 $_parsed 组（日期×模型）"
      else no "解析器读不出东西 —— 格式跟预期不符，请把上面那行键名发给作者"; fi
    fi
    if [ -f "$CODEX_HOME/auth.json" ]; then
      ok "auth.json 存在"
      info "顶层键：$(tr ',{}' '\n\n\n' < "$CODEX_HOME/auth.json" | grep -o '"[a-zA-Z_]*":' | sort -u | tr -d '":' | tr '\n' ' ')"
      _has=$(osascript -l JavaScript -e '
        function run(argv){
          var s=$.NSString.stringWithContentsOfFileEncodingError($(argv[0]),4,null);
          if(!s) return "读不到";
          var d; try{ d=JSON.parse(ObjC.unwrap(s)); }catch(e){ return "JSON 解析失败"; }
          var t=d.tokens||d.token||d;
          var at=t.access_token||t.accessToken||d.access_token||"";
          var ac=t.account_id||t.accountId||d.account_id||"";
          return (at?"access_token 有("+at.length+"字符)":"access_token 缺失")+"  "+
                 (ac?"account_id 有("+ac.length+"字符)":"account_id 缺失");
        }' "$CODEX_HOME/auth.json" 2>/dev/null)
      info "$_has"
    else
      no "没有 auth.json —— 没登录过 Codex？"
    fi
    if [ -f "$STATE_DIR/codex-snapshot.env" ]; then
      _cage=$(( $(date +%s) - $(stat -f %m "$STATE_DIR/codex-snapshot.env" 2>/dev/null || echo 0) ))
      ok "额度快照存在（${_cage} 秒前）"
      info "字段：$(cut -d= -f1 "$STATE_DIR/codex-snapshot.env" 2>/dev/null | tr '\n' ' ')"
    else
      no "没有额度快照 —— 接口没通，或还没打开支持"
    fi
  else
    no "没有 $CODEX_HOME —— 这台机器没装 Codex"
  fi

  say ""
  step "采集器输出"
  _out=$(sh "$WIDGET_SRC/lib/collect.sh" 2>/dev/null | head -c 400)
  if [ -n "$_out" ]; then
    ok "collect.sh 有输出（前 400 字节）"
    printf "%s\n" "$_out" | fold -w 76 -s | sed 's/^/      /'
  else
    no "collect.sh 没有输出"
  fi
  say ""
  printf "  ${DIM}以上内容不含任何 token、账号或会话内容，可以直接截图发给作者。${R}\n\n"
  exit 0
fi

# ═══════════════════════ 卸载 ═══════════════════════
if [ "$ACTION" = "uninstall" ]; then
  say "\n${B}卸载 Claude Usage 挂件$R\n"

  if WD=$(find_widgets_dir); then
    rm -rf "$WD/claude-usage.widget" && good "已移除挂件"
  fi

  if [ -f "$SETTINGS" ]; then
    osascript -l JavaScript -e '
      ObjC.import("Foundation");
      var p = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey("SETTINGS"));
      var raw = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null));
      var cfg = JSON.parse(raw);
      if (cfg.statusLine && String(cfg.statusLine.command || "").indexOf("claude-usage-statusline") >= 0) {
        delete cfg.statusLine;
        var s = $.NSString.alloc.initWithUTF8String(JSON.stringify(cfg, null, 2) + "\n");
        s.writeToFileAtomicallyEncodingError(p, true, $.NSUTF8StringEncoding, null);
        "removed";
      } else { "kept"; }
    ' >/dev/null 2>&1 && good "已从 settings.json 移除 statusLine"
  fi

  rm -rf "$STATE" && good "已清除缓存与快照"
  say "\n${DIM}完成。Übersicht 本身没有动，如果不再需要可以自行删除。$R\n"
  exit 0
fi

# ═══════════════════════ 安装 ═══════════════════════
say "\n${B}Claude Usage 桌面挂件$R ${DIM}· 安装$R\n"

[ -d "$WIDGET_SRC" ] || die "找不到 claude-usage.widget，请在解压后的文件夹里运行本脚本"

# ── 1. statusLine 脚本 ──
step "安装 statusLine 脚本"
mkdir -p "$BIN" || die "无法创建 $BIN"
cp "$WIDGET_SRC/bin/claude-usage-statusline.sh" "$STATUSLINE" || die "复制失败"
chmod +x "$STATUSLINE"
good "$STATUSLINE"

# ── 2. 配置 settings.json ──
step "配置 Claude Code 的 statusLine"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

SETTINGS="$SETTINGS" STATUSLINE="$STATUSLINE" osascript -l JavaScript <<'JXA' > /tmp/claude_usage_install_result 2>/tmp/claude_usage_install_err
ObjC.import("Foundation");
var env = $.NSProcessInfo.processInfo.environment;
var path = ObjC.unwrap(env.objectForKey("SETTINGS"));
var cmd  = ObjC.unwrap(env.objectForKey("STATUSLINE"));

var raw = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null));
// 解析失败时绝不能当成空对象写回去 —— 那会抹掉用户原有的全部配置
var cfg;
try { cfg = JSON.parse(raw); } catch (e) { cfg = null; }
if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) {
  "UNPARSEABLE";
} else {

var existing = cfg.statusLine ? String(cfg.statusLine.command || "") : "";
var result;
if (existing && existing.indexOf("claude-usage-statusline") < 0) {
  result = "CONFLICT\t" + existing;
} else {
  cfg.statusLine = { type: "command", command: cmd, padding: 0 };
  var out = $.NSString.alloc.initWithUTF8String(JSON.stringify(cfg, null, 2) + "\n");
  var ok = out.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  result = ok ? "OK" : "FAIL";
}
result;
}
JXA

RESULT=$(cat /tmp/claude_usage_install_result 2>/dev/null)
rm -f /tmp/claude_usage_install_result /tmp/claude_usage_install_err

case "$RESULT" in
  OK*)
    good "settings.json 已更新（备份：$(basename "$BACKUP")）"
    ;;
  CONFLICT*)
    OLD=$(printf '%s' "$RESULT" | cut -f2-)
    warn "你已经配了别的 statusLine，没有覆盖它："
    printf "    ${DIM}%s$R\n" "$OLD"
    printf "\n    想两个都要的话，把你原来的脚本改成把 stdin 转发给我们的脚本：\n"
    printf "    ${DIM}INPUT=\$(cat); printf '%%s' \"\$INPUT\" | %s\n" "$STATUSLINE"
    printf "    printf '%%s' \"\$INPUT\" | 你原来的脚本$R\n"
    rm -f "$BACKUP"
    ;;
  UNPARSEABLE*)
    warn "settings.json 不是合法 JSON，没有改动它。修好之后重跑本脚本，或手动加入："
    printf "    ${DIM}\"statusLine\": { \"type\": \"command\", \"command\": \"%s\" }$R\n" "$STATUSLINE"
    rm -f "$BACKUP"
    ;;
  *)
    warn "settings.json 写入失败，请手动加入："
    printf "    ${DIM}\"statusLine\": { \"type\": \"command\", \"command\": \"%s\" }$R\n" "$STATUSLINE"
    ;;
esac

# ── 3. 安装挂件 ──
step "安装桌面挂件"
if ! WD=$(find_widgets_dir); then
  if [ -d "/Applications/Übersicht.app" ]; then
    WD="$HOME/Library/Application Support/Übersicht/widgets"
    mkdir -p "$WD"
  elif command -v brew >/dev/null 2>&1; then
    # Homebrew 不允许 formula 依赖 cask，所以宿主只能在这一步自己拉。
    warn "没找到 Übersicht（挂件的宿主），正在装……"
    if brew install --cask ubersicht; then
      WD="$HOME/Library/Application Support/Übersicht/widgets"
      mkdir -p "$WD"
      good "Übersicht 已装好"
    else
      die "Übersicht 安装失败，请手动跑：brew install --cask ubersicht"
    fi
  else
    warn "没找到 Übersicht，请先安装："
    printf "    ${DIM}brew install --cask ubersicht$R\n"
    printf "    ${DIM}或从 https://tracesof.net/uebersicht/ 下载$R\n"
    printf "\n    装好之后重新运行。\n\n"
    exit 1
  fi
fi

rm -rf "$WD/claude-usage.widget"
cp -R "$WIDGET_SRC" "$WD/" || die "复制挂件失败"
chmod +x "$WD/claude-usage.widget/lib/collect.sh" "$WD/claude-usage.widget/bin/claude-usage-statusline.sh" 2>/dev/null
good "$WD/claude-usage.widget"

# ── 4. 预热 + 刷新 ──
step "预热数据缓存"
printf "  ${DIM}首次要通读会话记录，约几秒…$R\n"
if sh "$WD/claude-usage.widget/lib/collect.sh" > /tmp/claude_usage_probe 2>/dev/null; then
  DAYS=$(grep -c '"d":' /tmp/claude_usage_probe 2>/dev/null || echo 0)
  good "数据可用（已聚合 ${DAYS} 天）"
else
  warn "采集脚本返回异常，挂件仍会安装，稍后可自行排查"
fi
rm -f /tmp/claude_usage_probe

# ── 5. 打开点击交互 ──
# 折叠/展开按钮和主题色选择都需要 Übersicht 允许点击挂件。
# 这是 Übersicht 的全局开关，它按鼠标是否悬停在挂件上动态生效，
# 不会把桌面空白处的点击吃掉。
step "启用挂件点击交互"
WAS=$(defaults read tracesOf.Uebersicht enableInteraction 2>/dev/null)
if [ "$WAS" = "1" ]; then
  good "已经是开启状态"
  NEED_RESTART=0
else
  defaults write tracesOf.Uebersicht enableInteraction -bool true
  good "已开启（Übersicht 偏好设置 → Interaction 可随时关掉）"
  NEED_RESTART=1
fi

step "启动 Übersicht"
if [ "$NEED_RESTART" = "1" ] || [ -z "$(ub_pid)" ]; then
  BEFORE=$(ub_pid)
  if restart_ubersicht; then
    AFTER=$(ub_pid)
    if [ -n "$BEFORE" ] && [ "$BEFORE" = "$AFTER" ]; then
      warn "Übersicht 没能重启（PID 仍是 ${BEFORE}），点击交互可能未生效"
      printf "    ${DIM}请手动退出 Übersicht 再打开一次$R\n"
    else
      good "已重启（PID ${AFTER}）"
    fi
  else
    warn "Übersicht 未能启动，请手动打开"
  fi
else
  osascript -e 'tell application "Übersicht" to refresh' >/dev/null 2>&1
  good "已刷新（PID $(ub_pid)）"
fi

# 检测到 Codex 就明说会发生什么。默认打开 ≠ 可以不告诉用户。
_CH="${CODEX_HOME:-$HOME/.codex}"
[ -f "$STATE_DIR/codex.home" ] && _CH=$(head -1 "$STATE_DIR/codex.home" 2>/dev/null)
if [ -d "$_CH" ] && [ ! -f "$STATE_DIR/codex.off" ]; then
  say ""
  step "顺便：检测到你装了 Codex，已自动一起显示"
  printf "    ${DIM}展开面板的标题会变成 Claude / Codex 两个页签，点一下就切。${R}\n\n"
  printf "    ${DIM}柱状图和热力图读的是本机 $_CH/sessions 里的会话记录。${R}\n"
  printf "    ${DIM}两个额度环需要读 $_CH/auth.json 里你已有的登录凭据，${R}\n"
  printf "    ${DIM}拿它去问 ChatGPT 官方接口 —— 凭据只发给 chatgpt.com，不经第三方。${R}\n\n"
  printf "    ${DIM}不想要：claude-usage-widget codex off${R}\n"
fi

say "\n${B}装好了。$R\n"
printf "${DIM}挂件现在应该在桌面右上角。如果只看到「还没拿到订阅额度」，$R\n"
printf "${DIM}那是正常的 —— 5h / 7d 百分比要由一个运行中的 Claude Code 会话喂给它，$R\n"
printf "${DIM}随便开一个 claude 会话说句话，几秒后挂件就会亮起来。$R\n\n"
printf "  ${DIM}拖动：$R    按住药丸拖；展开后按住顶栏拖。双击左上圆点归位\n"
printf "  ${DIM}展开：$R    点药丸右侧的箭头（展开后可选主题色）\n"
printf "  ${DIM}调位置：$R  编辑 %s/claude-usage.widget/index.jsx 顶部的 POSITION\n" "$WD"
printf "  ${DIM}临时隐藏：$R 菜单栏 Übersicht 图标 → 点挂件名切换显示\n"
printf "  ${DIM}卸载：$R    claude-usage-widget uninstall\n\n"
