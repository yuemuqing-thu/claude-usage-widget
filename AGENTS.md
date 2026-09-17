# Claude Usage — 给接手的 agent

macOS 的 Übersicht 桌面挂件：显示 Claude 和 Codex 的订阅额度、本地用量统计，
外加一只在桌面上跑的像素猫。当前 v0.3.4，已发布到 GitHub + Homebrew tap。

## 硬性约束

**零运行时依赖。** 只用 macOS 自带的 `sh`、`awk`、`osascript`。
不准引入 node / python / jq。唯一的例外是 `zstd`（Homebrew 依赖，缺了会优雅降级）。

**全程不联网。** 挂件运行时一个字节都不往外发。这条写在 README 里，是项目的卖点之一。
曾经有过读凭据调私有接口的实现，已整个删除，别再加回来。

**awk 是 onetrueawk（BSD），不是 gawk。** 没有 `nextfile`、`mktime`、`gensub`、`asort`。
日期换算得自己按公历公式算（见 `codex-limits.awk` 的 `iso_epoch`）。

## 文件结构

```
install.sh                    安装/卸载/codex 开关/doctor 四个子命令，是唯一入口
claude-usage.widget/
  index.jsx                   挂件本体（~1500 行），JSX 编译成全局 html() 超文本
  lib/collect.sh              数据命令，每 8 秒跑一次，输出一段 JSON
  lib/scan.awk                扫 ~/.claude/projects 的会话
  lib/scan-codex.awk          扫 ~/.codex/sessions 的会话
  lib/codex-limits.awk        从 Codex 会话记录里取额度快照
  lib/merge.awk               聚合成挂件要的 JSON
  lib/.lint.sh                检查下面第 1 条那个坑
  bin/claude-usage-statusline.sh   Claude 的 statusLine 钩子
test/render-test.js           挂件渲染测试，覆盖数据源的四种组合
```

## 已经踩过的坑（都付出过代价，别重蹈）

**1. `$VAR` 紧跟全角字符，多字节会被吞进变量名。**
`say "已启用（检测到 $_ch）"` 里的 `$_ch）` 会被解析成变量名 `_ch）`，
`set -u` 下直接报 unbound variable 退出。**这个坑犯过两次**，第二次是带着 bug 发了版。
一律写 `${_ch}`。改完跑 `sh claude-usage.widget/lib/.lint.sh`。

**2. Übersicht 只重载模块，不重载 WebView。**
`window.__cuPet` 和注入的 `<style>` 会跨代码更新存活，改了猫的逻辑看不到效果。
用 `index.jsx` 顶部的 `PET_VERSION` 常量做版本戳，加一就强制重建。

**3. 所有即时 UI 状态都是 CSS `:checked` 兄弟选择器状态机。**
展开、主题、毛色、宠物、语言、数据源都靠隐藏的 `<input>`。
这些 input **必须是 `.body` 前面的直接兄弟节点**，挪位置会整个失效。
为什么不用 React state：数据命令 8 秒才刷一次，走 state 会有 8 秒延迟。

**4. 两个数据源同时渲染，用 CSS 选显示哪个。**
不是切换后重新取数——那样标题会先变、数字后变，比延迟更糟，是误导。

**5. Homebrew formula 不能 `depends_on cask:`。**
Übersicht 是 cask，所以由 `install.sh` 在运行时自己拉（先试 brew，失败走官网直链）。

**6. GitHub 的 markdown 里，`<table>` 内部有空行会截断整块 HTML。**

**7. 发版前必须验证 tarball 是不是真的。**
`SHA=$(curl ... | shasum)` 在 GitHub 还没生成好 tarball 时会取到错误页的哈希，
写进 formula 会让所有人的 `brew install` 失败。**这个事故发生过一次。**
先 `tar -tzf` 确认是合法归档且含预期文件，再取哈希。

**8. 改测试台之后，先确认测试本身是对的。**
这个项目里测试脚本自己出错的次数比代码出错还多：`timeout` 在 macOS 不存在（报 127
被误读成代码挂了）、剥 PATH 时把 `sh` 也剥掉了、stub 的 `html()` 不调用函数式组件
导致断言永远为空。**看到异常结果，先怀疑测试。**

## Codex 数据的关键事实

额度来自会话记录里的 `token_count` 事件（`codex-rs/protocol/src/protocol.rs`）：

```rust
TokenCountEvent { info, rate_limits }
RateLimitSnapshot { limit_id, limit_name, primary, secondary, plan_type, ... }
RateLimitWindow   { used_percent, window_minutes, resets_at }
```

- 两个窗口按 `window_minutes` 归位（300 = 5 小时，10080 = 7 天），**不要假定 primary 就是 5 小时**
- 数据新鲜度 = 用户最后一次用 Codex 的时间。过期阈值 Codex 是 1 小时，Claude 是 15 分钟（statusLine 会持续刷新，语义不同）
- **超过 7 天的会话被压成 `rollout-*.jsonl.zst`**（2026-06 起）。缓存键必须去掉 `.zst` 后缀，
  否则同一份会话在改名前后各统计一遍
- CLI、VS Code 扩展、桌面 App 写的是同一套记录；**网页云端不写本地文件**

## 待办（按重要性排序）

### 1. 用真实数据验证 Codex 整条链路 ← 最重要

**Codex 的实现至今没有在真实数据上跑过一行。** 全部是照着协议定义写的，
用构造的样例测的。开发机现在已装 Codex CLI 0.154.0。

要做的：开一个 codex 会话，然后 `claude-usage-widget doctor`，确认
额度环的数字跟 codex 里 `/status` 显示的一致。不一致就查 `lib/codex-limits.awk`。

### 2. 核对计价表

`lib/merge.awk` 里 Codex 的模型单价（gpt-5 $1.25/$10、mini $0.25/$2、o3 $2/$8）
是凭当时印象写死的，**没核对过**。还要确认遇到表里没有的模型时不会算出离谱的数。
这个数字直接显示在界面上。

### 3. 验证增量扫描不会重复计数

`scan-codex.awk` 优先用 `last_token_usage`（单次增量），没有才按文件算 `total_token_usage`
的差值。这两条分支切换的边界没有专门测过。

### 4. 彩蛋阈值的边界

每 50 赞弹咖啡提示、100 赞解锁改名、1000 赞爱心。有没有差一没验过。

### 5. `install.sh` 的 settings.json 改写与卸载完整性

写入是用 JXA 解析再回写的。用户原来的 statusLine 配置、格式怪异的 JSON、
卸载后是否还原干净，都没系统测过。

### 6. 把发版流程固化成脚本

现在是手敲一长串命令，已经因此发过一次坏版本（见坑 7）。
应当包含：跑 lint、跑测试、验 tarball 再取哈希、推送失败可重入。

## 惯例

- 提交信息用中文，说清「为什么」而不只是「改了什么」
- 注释解释权衡和陷阱，不复述代码在干什么
- 改了 `index.jsx` 之后：`sh install.sh` 部署，再 `node test/render-test.js`
- 改了 shell 之后：`sh -n` 过语法，再跑 `lib/.lint.sh`
- README 有中英两版，功能改动要同步，且**不要让声明过期**——
  「不联网」这类绝对表述曾经因为加了功能而变成假话
