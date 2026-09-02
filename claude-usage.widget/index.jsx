import { run } from "uebersicht";
// Claude Usage — Übersicht 桌面挂件
//
// 折叠时是一枚窄药丸，只显示两个额度百分比；点右侧箭头展开成完整卡片
// （环形额度 / 上下文 / 14 天柱状图 / 91 天活动热力图 / 主题色）。
//
// 展开状态和主题色用 CSS :checked 兄弟选择器驱动，点击即时生效，
// 不依赖 React state；localStorage 只负责跨重启记住选择。
//
// ⚠️ 点击需要 Übersicht 偏好设置里的 Interaction → Enable interaction 打开。

// ─────────── 想改的东西都在这 ───────────
const POSITION = { top: "48px", right: "48px" }; // 想靠左就把 right 换成 left
const HEAT_WEEKS = 13;                            // 热力图周数
const STALE_AFTER = 900;                          // 超过这么多秒判定快照过期

// 拖动时用来判断该按上边缘还是下边缘吸附（近似值即可，只影响展开方向）
const PILL_H = 62;
const CARD_H = 500;

export const command =
  "sh ./claude-usage.widget/lib/collect.sh 2>/dev/null || sh ./lib/collect.sh";
export const refreshFrequency = 8000;

// ─────────── 主题色 ───────────
// a1/a2 是渐变两端，rgb 用于发光和热力图的透明度阶梯
const PALETTES = [
  { id: "coral",  label: "珊瑚",  a1: "#F0906F", a2: "#D97757", rgb: "217,119,87"  },
  { id: "blue",   label: "蔚蓝",  a1: "#64D2FF", a2: "#0A84FF", rgb: "10,132,255"  },
  { id: "purple", label: "紫罗兰", a1: "#DA8FFF", a2: "#BF5AF2", rgb: "191,90,242" },
  { id: "green",  label: "薄荷",  a1: "#5BE49B", a2: "#30D158", rgb: "48,209,88"   },
  { id: "mono",   label: "石墨",  a1: "#E5E5EA", a2: "#8E8E93", rgb: "174,174,178" },
];

// 额度吃紧时压过主题色 —— 告警语义比配色偏好优先
const WARN = { a1: "#FFD426", a2: "#FF9F0A", rgb: "255,159,10" };
const CRIT = { a1: "#FF8A80", a2: "#FF453A", rgb: "255,69,58"  };
const rampFor = (pct, base) => (pct >= 85 ? CRIT : pct >= 60 ? WARN : base);

// ─────────── 偏好存取 ───────────
const K_OPEN = "cu.open";
const K_THEME = "cu.theme";
const readPref = (k, d) => {
  try { const v = window.localStorage.getItem(k); return v == null ? d : v; }
  catch (e) { return d; }
};
const writePref = (k, v) => {
  try { window.localStorage.setItem(k, v); } catch (e) {}
};

// ─────────── 中英切换 ───────────
// 语言存在 localStorage，默认跟随系统。所有面向用户的字都走 t()，
// 带参数的句子用 {0} {1} 占位 —— 中英语序不同，不能靠拼接。
const K_LANG = "cu.lang";
const I18N = {
  zh: {
    expand: "展开 / 收起", home: "双击归位", loading: "正在读取用量…", err: "脚本出错：",
    h5: "5 小时", d7: "7 天", h5full: "5 小时会话", d7full: "7 天周额度",
    resetIn: "{0}后重置", noData: "暂无数据", soon: "即将重置",
    dh: "{0}天{1}小时", hm: "{0}小时{1}分", mm: "{0}分钟",
    justNow: "刚刚", minAgo: "{0} 分钟前", hrAgo: "{0} 小时前", dayAgo: "{0} 天前",
    ctx: "当前会话上下文", last14: "近 14 天", heat: "活动热力图", nDays: "{0} 天",
    today: "今日", todayTok: "今日 token", share: "{0}% 占比",
    less: "少", more: "多", months: ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"],
    setupTitle: "还没拿到订阅额度",
    setupBody: "额度百分比只能由运行中的 Claude Code 会话提供。跑一次 claude-usage-widget install 配好 statusLine，然后开一个会话即可。",
    coats: "花色", plays: "玩法", loveTip: "亲密度",
    feed: "投喂小鱼", toy: "毛线球", laser: "激光笔", box: "纸箱", bird: "放只小鸟",
    themes: { coral: "珊瑚", blue: "蔚蓝", purple: "紫罗兰", green: "薄荷", mono: "石墨" },
    catCoats: { orange: "橘猫", grey: "灰猫", black: "黑猫", cream: "奶白", calico: "三花", siam: "暹罗" },
    wantCoffee: "{0}想喝咖啡了", aCat: "小猫", namePh: "给它起个名字",
    nameLocked: "摸满 {0} 次就能给它起名字", loveEgg: "Love {0}",
    langTip: "切换到英文", coffeeTip: "请我喝杯咖啡 ☕",
  },
  en: {
    expand: "Expand / collapse", home: "Double-click to reset", loading: "Reading usage…", err: "Script error: ",
    h5: "5-hour", d7: "7-day", h5full: "5-hour session", d7full: "Weekly quota",
    resetIn: "resets in {0}", noData: "no data yet", soon: "resetting soon",
    dh: "{0}d {1}h", hm: "{0}h {1}m", mm: "{0}m",
    justNow: "just now", minAgo: "{0}m ago", hrAgo: "{0}h ago", dayAgo: "{0}d ago",
    ctx: "Context used", last14: "Last 14 days", heat: "Activity", nDays: "{0} days",
    today: "Today", todayTok: "Tokens today", share: "{0}% share",
    less: "less", more: "more", months: ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"],
    setupTitle: "No quota data yet",
    setupBody: "Percentages come from a running Claude Code session. Run claude-usage-widget install to set up the statusLine, then start a session.",
    coats: "Coat", plays: "Play", loveTip: "Affection",
    feed: "Feed a fish", toy: "Yarn ball", laser: "Laser pointer", box: "Cardboard box", bird: "Send a bird",
    themes: { coral: "Coral", blue: "Azure", purple: "Violet", green: "Mint", mono: "Graphite" },
    catCoats: { orange: "Ginger", grey: "Grey", black: "Black", cream: "Cream", calico: "Calico", siam: "Siamese" },
    wantCoffee: "{0} wants a coffee", aCat: "The cat", namePh: "Name your cat",
    nameLocked: "Pet it {0} times to unlock naming", loveEgg: "Love {0}",
    langTip: "Switch to Chinese", coffeeTip: "Buy me a coffee ☕",
  },
};
const curLang = () => {
  const v = readPref(K_LANG, "");
  if (v === "zh" || v === "en") return v;
  try { return /^zh/i.test(navigator.language || "") ? "zh" : "en"; } catch (e) { return "zh"; }
};
const tr = (lang, k, ...a) => {
  const s = (I18N[lang] || I18N.zh)[k];
  if (typeof s !== "string") return s;
  return s.replace(/\{(\d)\}/g, (_, i) => a[+i]);
};
// 用于 title 等属性：属性里塞不了 JSX，只能取当前语言，切换后下一次刷新才更新
const t = (k, ...a) => tr(curLang(), k, ...a);
// 用于正文：中英两份都渲染进 DOM，由 CSS 的 #cu-lang:checked 选显示哪份。
// 挂件 8 秒才重渲染一次，靠 JS 切语言会卡顿 —— 主题色和花色也是这个套路。
const T = ({ k, a }) => (
  <span className="i18n">
    <span className="zh">{tr("zh", k, ...(a || []))}</span>
    <span className="en">{tr("en", k, ...(a || []))}</span>
  </span>
);

// ─────────── 拖动 ───────────
// 位置存的是药丸左上角坐标。拖动中的实时值放在模块变量里，
// 这样 8 秒一次的刷新重渲染不会让卡片跳回上一次落点。
const K_POS = "cu.pos";
let livePos = null;

const readPos = () => {
  if (livePos) return livePos;
  const raw = readPref(K_POS, "");
  if (!raw) return null;
  const a = raw.split(",");
  const x = Number(a[0]), y = Number(a[1]);
  if (a.length !== 2 || !isFinite(x) || !isFinite(y)) return null;
  return { x: x, y: y };
};

// 上半屏按 top 吸附，下半屏按 bottom 吸附 —— 这样在屏幕下方展开时
// 卡片是向上长的，不会掉出屏幕外。
const posStyle = () => {
  const p = readPos();
  if (!p) return { top: POSITION.top, right: POSITION.right };
  const vh = (typeof window !== "undefined" && window.innerHeight) || 900;
  if (p.y + CARD_H <= vh) return { left: p.x + "px", top: p.y + "px" };
  return { left: p.x + "px", bottom: Math.max(0, vh - p.y - PILL_H) + "px" };
};

const startDrag = (e) => {
  if (e.button !== 0) return;
  const el = e.currentTarget.closest(".drag");
  if (!el) return;
  const r = el.getBoundingClientRect();
  const ox = e.clientX - r.left;
  const oy = e.clientY - r.top;
  const vw = window.innerWidth, vh = window.innerHeight;
  el.classList.add("dragging");
  e.preventDefault();

  const move = (ev) => {
    // 按较宽的展开态来夹取 x，保证无论折叠还是展开都不会超出右边界
    const x = Math.round(Math.max(0, Math.min(vw - 336, ev.clientX - ox)));
    const y = Math.round(Math.max(0, Math.min(vh - PILL_H, ev.clientY - oy)));
    livePos = { x: x, y: y };
    el.style.right = "auto";
    el.style.bottom = "auto";
    el.style.left = x + "px";
    el.style.top = y + "px";
  };
  const up = () => {
    window.removeEventListener("mousemove", move);
    window.removeEventListener("mouseup", up);
    el.classList.remove("dragging");
    if (livePos) writePref(K_POS, livePos.x + "," + livePos.y);
  };
  window.addEventListener("mousemove", move);
  window.addEventListener("mouseup", up);
};

// 双击左上角圆点归位
const resetPos = () => {
  livePos = null;
  try { window.localStorage.removeItem(K_POS); } catch (e) {}
  const els = document.querySelectorAll(".cu .drag");
  for (let i = 0; i < els.length; i++) {
    const st = els[i].style;
    st.left = ""; st.top = ""; st.right = ""; st.bottom = "";
  }
};

const stop = (e) => e.stopPropagation();

// ─────────── 格式化 ───────────
const fmtTok = (n) => {
  if (!n) return "0";
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(0) + "K";
  return String(n);
};
const fmtUsd = (n) => {
  if (!n) return "$0";
  if (n >= 100) return "$" + Math.round(n);
  if (n >= 10) return "$" + n.toFixed(1);
  return "$" + n.toFixed(2);
};
const fmtDur = (s) => {
  if (s == null || s <= 0) return t("soon");
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return t("dh", d, h);
  if (h > 0) return t("hm", h, m);
  return t("mm", m);
};
const fmtAge = (s) => {
  if (s == null) return "";
  if (s < 90) return t("justNow");
  if (s < 3600) return t("minAgo", Math.floor(s / 60));
  if (s < 86400) return t("hrAgo", Math.floor(s / 3600));
  return t("dayAgo", Math.floor(s / 86400));
};

// ─────────── 组件 ───────────

const Chevron = ({ id, cls }) => (
  <label htmlFor={id} className={"chev " + cls} title={t("expand")} onMouseDown={stop}>
    <svg width="11" height="11" viewBox="0 0 12 12">
      <path
        d="M2.5 4.5 L6 8 L9.5 4.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  </label>
);

const Ring = ({ pct, label, sub, gid, base }) => {
  const R = 32;
  const C = 2 * Math.PI * R;
  const has = pct != null;
  const v = Math.max(0, Math.min(100, has ? pct : 0));
  const ramp = rampFor(v, base);

  return (
    <div className="ring">
      <div className="ringWrap">
        <svg width="84" height="84" viewBox="0 0 84 84">
          <defs>
            <linearGradient id={gid} x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stopColor={ramp.a1} />
              <stop offset="100%" stopColor={ramp.a2} />
            </linearGradient>
          </defs>
          <circle cx="42" cy="42" r={R} className="track" />
          {has && (
            <circle
              cx="42"
              cy="42"
              r={R}
              className="prog"
              stroke={"url(#" + gid + ")"}
              strokeDasharray={C}
              strokeDashoffset={C * (1 - v / 100)}
              style={{ filter: "drop-shadow(0 0 5px rgba(" + ramp.rgb + ",0.5))" }}
            />
          )}
        </svg>
        <div className="ringVal">
          {has ? <span>{Math.round(v)}<i>%</i></span> : <span className="dash">—</span>}
        </div>
      </div>
      <div className="ringLabel">{label}</div>
      <div className="ringSub">{sub}</div>
    </div>
  );
};

const Meter = ({ k, pct, base }) => {
  const has = pct != null;
  const v = Math.max(0, Math.min(100, has ? pct : 0));
  const ramp = rampFor(v, base);
  return (
    <div className="meter">
      <div className="meterTop">
        <span className="meterK">{k}</span>
        <span className="meterV">{has ? Math.round(v) + "%" : "—"}</span>
      </div>
      <div className="meterBar">
        <div
          className="meterFill"
          style={{
            width: v + "%",
            background: "linear-gradient(90deg," + ramp.a1 + "," + ramp.a2 + ")",
            boxShadow: "0 0 6px rgba(" + ramp.rgb + ",0.55)",
          }}
        />
      </div>
    </div>
  );
};

// 近 14 天柱状图
const Bars = ({ days }) => {
  const recent = days.slice(-14);
  const max = recent.reduce((m, d) => Math.max(m, d.cost), 0);
  return (
    <div className="bars">
      {recent.map((d, i) => (
        <div key={d.d} className="barSlot">
          <div
            className={"bar" + (i === recent.length - 1 ? " today" : "") + (d.cost > 0 ? "" : " zero")}
            style={{ height: (max > 0 && d.cost > 0 ? Math.max(3, (d.cost / max) * 38) : 2) + "px" }}
          />
        </div>
      ))}
    </div>
  );
};

// 91 天活动热力图。单日花费分布极偏（作者数据里峰值是中位数的几十倍），
// 所以按非零值的分位数分 4 级，而不是线性映射。
const Heat = ({ days }) => {
  const nz = days.filter((d) => d.cost > 0).map((d) => d.cost).sort((a, b) => a - b);
  const q = (p) => (nz.length ? nz[Math.min(nz.length - 1, Math.floor(nz.length * p))] : 0);
  const cuts = [q(0.25), q(0.5), q(0.75)];
  const level = (c) => {
    if (c <= 0) return 0;
    if (c <= cuts[0]) return 1;
    if (c <= cuts[1]) return 2;
    if (c <= cuts[2]) return 3;
    return 4;
  };

  // 按周分列，每列 7 格（周日在最上）
  const cols = [];
  let cur = [];
  days.forEach((d, i) => {
    const wd = new Date(d.d + "T12:00:00").getDay();
    if (i === 0) for (let p = 0; p < wd; p++) cur.push(null);
    cur.push(d);
    if (wd === 6) { cols.push(cur); cur = []; }
  });
  if (cur.length) { while (cur.length < 7) cur.push(null); cols.push(cur); }
  const weeks = cols.slice(-HEAT_WEEKS);

  // 月份标签：某列的第一个真实日期跨了月，就在该列上方标月份
  let lastMonth = -1;
  const marks = weeks.map((w) => {
    const first = w.find((c) => c);
    if (!first) return "";
    const m = Number(first.d.slice(5, 7));
    if (m !== lastMonth) { lastMonth = m; return t("months")[m - 1]; }
    return "";
  });

  return (
    <div className="heat">
      <div className="heatMonths">
        {marks.map((m, i) => (<span key={i} className="heatMonth">{m}</span>))}
      </div>
      <div className="heatGrid">
        {weeks.map((w, i) => (
          <div key={i} className="heatCol">
            {w.map((c, j) => (
              <div
                key={j}
                className={"cell " + (c ? "l" + level(c.cost) : "l0 pad")}
                title={c ? c.d + "  " + fmtUsd(c.cost) : ""}
              />
            ))}
          </div>
        ))}
      </div>
      <div className="heatLegend">
        <span><T k="less" /></span>
        <i className="cell l1" /><i className="cell l2" /><i className="cell l3" /><i className="cell l4" />
        <span><T k="more" /></span>
      </div>
    </div>
  );
};

// ═══════════════════════ 像素宠物 ═══════════════════════
// 小猫是一个独立于 React 的单例：自己建 canvas、自己跑动画循环、自己听鼠标。
// 挂件每 8 秒重渲染一次，如果把它塞进 React 树里每次都会被重建，动画就断了。
//
// 美术不是手画的：坐姿底图是从一张参考图反解出来的 —— 探测出它真正的像素网格
// （16px / 29×35），逐格取中位色，再把断掉的描边补完整、把采样吃掉的眼睛按结构重画。
// 走路和趴睡都从这张底图衍生：头（含耳与胡须）逐像素复用，只换身体和四肢，
// 所以几个姿势换来换去还是同一只猫。
//
// 语义字符 + 可换调色板：
//   O 描边  D/d/f/l 毛色四阶  m/M 斑纹  o 次深  w/W 白  N 眼珠  e 眼内米白  E 高光
//   p/P 鼻  c 项圈（跟随主题色）
//
// 帧里是【没有眼睛】的，眼睛由运行时按锚点叠贴片 —— 这样眨眼/眯眼/半睁只要换贴片。

const K_PET = "cu.pet";
const K_COAT = "cu.coat";
const K_LOVE = "cu.love";
const K_NAME = "cu.name";        // 猫的名字，100 赞后才解锁
const K_COFF = "cu.coffee";      // 已经提醒过的最近一个 50 的整数倍
const K_EGG  = "cu.egg1000";     // 1000 赞的隐藏彩蛋放过没有
const NAME_AT = 100;             // 解锁改名的门槛
const COFFEE_EVERY = 50;         // 每多少赞提醒一次咖啡
const LOVE_EGG = 1000;           // 隐藏彩蛋门槛
const DEFAULT_NAME = "木木";
const AFDIAN = "https://ifdian.net/a/sonetto_zhou";
// 挂件代码更新后 Übersicht 只重载模块、不重建 WebView —— window 上的旧实例和
// 注入过的 <style> 都会留着。改了小猫这块就把这个号 +1，强制重建。
const PET_VERSION = 4;
const catName = () => (readPref(K_NAME, "") || DEFAULT_NAME);

const SPR = {"W":32,"H":36,"frames":{"sit":[["","","....OOOO.............OOOO.......","....OMffOO.........OOffMO.......","...OddmmffOOOOOOOOOffmmddO......","...OddlddfffmfMfmfffddlddO......","...OdllmffffMfffMffffmlfdO......","...OdfMfffffffffffffffMfdO......","...OdmMfffffffffffffffMddO......","...OOmfffffffffffffffffmOO......",".....OmffffffffffffffffO........","..OOOfDfffffffffffffffffOOO.....","....OfDfffffffPPffffffffO.......","..OOOffDffffllpllfffffffOOO.....","....ODffMfflldlldlffMffO........","....OmfflfflllddllfflffO........",".....OOflllllllllllllfOO........",".......OdllllllllllldO..........","........OdddMMMMMdddO...........","........ODdddddddddDO...........","........OddMMMMMMMddO...........","........OMMlllllllMMO...........","........OfflllllllffO....OO.....","........OfflllllllffdO..OffO....","........OMfflllllffMMO..OffmO...","........OfffflfffffffO...OmmO...",".......OmfffffMfffffmO...OmmO...","......OmmfffffdfffffmmO..OdO....","......OmDfffffDfffffDmdOOMfO....","......OmDfffffDfffffDddDmfMO....","......OdDfffffDfffffDddmmmO.....","......OODfffffDfffffddOOOO......","........OOOffMDffffOOO..........","...........OOOOOOOO.............","",""],["","","....OOOO.............OOOO.......","....OMffOO.........OOffMO.......","...OddmmffOOOOOOOOOffmmddO......","...OddlddfffmfMfmfffddlddO......","...OdllmffffMfffMffffmlfdO......","...OdfMfffffffffffffffMfdO......","...OdmMfffffffffffffffMddO......","...OOmfffffffffffffffffmOO......",".....OmffffffffffffffffO........","..OOOfDfffffffffffffffffOOO.....","....OfDfffffffPPffffffffO.......","..OOOffDffffllpllfffffffOOO.....","....ODffMfflldlldlffMffO........","....OmfflfflllddllfflffO........",".....OOflllllllllllllfOO........",".......OdllllllllllldO..........","........OdddMMMMMdddO...........","........ODdddddddddDO...........","........OddMMMMMMMddO...........","........OMMlllllllMMO...........","........OfflllllllffO......OO...","........OfflllllllffdO...OffO...","........OMfflllllffMMO...OffmO..","........OfffflfffffffO....OmmO..",".......OmfffffMfffffmO....OmmO..","......OmmfffffdfffffmmO..OdO....","......OmDfffffDfffffDmdOOMfO....","......OmDfffffDfffffDddDmfMO....","......OdDfffffDfffffDddmmmO.....","......OODfffffDfffffddOOOO......","........OOOffMDffffOOO..........","...........OOOOOOOO.............","",""],["","","....OOOO.............OOOO.......","....OMffOO.........OOffMO.......","...OddmmffOOOOOOOOOffmmddO......","...OddlddfffmfMfmfffddlddO......","...OdllmffffMfffMffffmlfdO......","...OdfMfffffffffffffffMfdO......","...OdmMfffffffffffffffMddO......","...OOmfffffffffffffffffmOO......",".....OmffffffffffffffffO........","..OOOfDfffffffffffffffffOOO.....","....OfDfffffffPPffffffffO.......","..OOOffDffffllpllfffffffOOO.....","....ODffMfflldlldlffMffO........","....OmfflfflllddllfflffO........",".....OOflllllllllllllfOO........",".......OdllllllllllldO..........","........OdddMMMMMdddO...........","........ODdddddddddDO...........","........OddMMMMMMMddO...........","........OMMlllllllMMO...........","........OfflllllllffO....OO.....","........OfflllllllffdO..OffO....","........OMfflllllffMMO..OffmO...","........OfffflfffffffO...OmmO...",".......OmfffffMfffffmO...OmmO...","......OmmfffffdfffffmmO..OdO....","......OmDfffffDfffffDmdOOMfO....","......OmDfffffDfffffDddDmfMO....","......OdDfffffDfffffDddmmmO.....","......OODfffffDfffffddOOOO......","........OOOffMDffffOOO..........","...........OOOOOOOO.............","",""],["","","....OOOO.............OOOO.......","....OMffOO.........OOffMO.......","...OddmmffOOOOOOOOOffmmddO......","...OddlddfffmfMfmfffddlddO......","...OdllmffffMfffMffffmlfdO......","...OdfMfffffffffffffffMfdO......","...OdmMfffffffffffffffMddO......","...OOmfffffffffffffffffmOO......",".....OmffffffffffffffffO........","..OOOfDfffffffffffffffffOOO.....","....OfDfffffffPPffffffffO.......","..OOOffDffffllpllfffffffOOO.....","....ODffMfflldlldlffMffO........","....OmfflfflllddllfflffO........",".....OOflllllllllllllfOO........",".......OdllllllllllldO..........","........OdddMMMMMdddO...........","........ODdddddddddDO...........","........OddMMMMMMMddO...........","........OMMlllllllMMO...........","........OfflllllllffO..OO.......","........OfflllllllffdO.OffO.....","........OMfflllllffMMO.OffmO....","........OfffflfffffffO..OmmO....",".......OmfffffMfffffmO..OmmO....","......OmmfffffdfffffmmO..OdO....","......OmDfffffDfffffDmdOOMfO....","......OmDfffffDfffffDddDmfMO....","......OdDfffffDfffffDddmmmO.....","......OODfffffDfffffddOOOO......","........OOOffMDffffOOO..........","...........OOOOOOOO.............","",""]],"walk":[["","","....OOOO.............OOOO.......","....OMffOO.........OOffMO.......","...OddmmffOOOOOOOOOffmmddO......","...OddlddfffmfMfmfffddlddO......","...OdllmffffMfffMffffmlfdO......","...OdfMfffffffffffffffMfdO......","...OdmMfffffffffffffffMddO......","...OOmfffffffffffffffffmOO......",".....OmffffffffffffffffO........","..OOOfDfffffffffffffffffOOO.....","....OfDfffffffPPffffffffO.......","..OOOffDffffllpllfffffffOOO.....","....ODffMfflldlldlffMffO........","....OmfflfflllddllfflffO........",".....OOflllllllllllllfOO........",".......OdllllllllllldO..........","........OdddMMMMMdddO...........","........ODdddddddddDO...........","........OddMMMMMMMddO...........","........OMMlllllllMMO...........","........OfflllllllffO......OO...","........OfflllllllffdO...OffO...","........OMfflllllffMMO...OffmO..","........OfffflfffffffO....OmmO..",".......OmfffffMfffffmO....OmmO..","......OmmfffffdfffffmmO..OdO....","......OmDfffffDfffffDmdOOMfO....","......OmDfffffDfffffDddDmfMO....","......OdDfffffDfffffDddmmmO.....","......OODfffffDfffffddOOOO......","........OOOffMDffffOOO..........","...........OOOOOOOO.............","",""],["","...OOOO.............OOOO........","...OMffOO.........OOffMO........","..OddmmffOOOOOOOOOffmmddO.......","..OddlddfffmfMfmfffddlddO.......","..OdllmffffMfffMffffmlfdO.......","..OdfMfffffffffffffffMfdO.......","..OdmMfffffffffffffffMddO.......","..OOmfffffffffffffffffmOO.......","....OmffffffffffffffffO.........",".OOOfDfffffffffffffffffOOO......","...OfDfffffffPPffffffffO........",".OOOffDffffllpllfffffffOOO......","...ODffMfflldlldlffMffO.........","...OmfflfflllddllfflffO.........","....OOflllllllllllllfOO.........","......OdllllllllllldO...........",".......OdddMMMMMdddO............",".......ODdddddddddDO............",".......OddMMMMMMMddO............",".......OMMlllllllMMO............",".......OfflllllllffO....OO......",".......OfflllllllffdO..OffO.....",".......OMfflllllffMMO..OffmO....",".......OfffflfffffffO...OmmO....","......OmfffffMfffffmO...OmmO....",".....OmDfffffdfffffmmO..OdO.....",".....OmDfffffDfffffDmdOOMfO.....",".....OmDfffffDfffffDddDmfMO.....",".....OdOOOffMDfffffDddmmmO......",".....OO...OOODfffffddOOOO.......",".............DffffOOO...........",".............OOOOO..............","","",""],["","","....OOOO.............OOOO.......","....OMffOO.........OOffMO.......","...OddmmffOOOOOOOOOffmmddO......","...OddlddfffmfMfmfffddlddO......","...OdllmffffMfffMffffmlfdO......","...OdfMfffffffffffffffMfdO......","...OdmMfffffffffffffffMddO......","...OOmfffffffffffffffffmOO......",".....OmffffffffffffffffO........","..OOOfDfffffffffffffffffOOO.....","....OfDfffffffPPffffffffO.......","..OOOffDffffllpllfffffffOOO.....","....ODffMfflldlldlffMffO........","....OmfflfflllddllfflffO........",".....OOflllllllllllllfOO........",".......OdllllllllllldO..........","........OdddMMMMMdddO...........","........ODdddddddddDO...........","........OddMMMMMMMddO...........","........OMMlllllllMMO...........","........OfflllllllffO..OO.......","........OfflllllllffdO.OffO.....","........OMfflllllffMMO.OffmO....","........OfffflfffffffO..OmmO....",".......OmfffffMfffffmO..OmmO....","......OmmfffffdfffffmmO..OdO....","......OmDfffffDfffffDmdOOMfO....","......OmDfffffDfffffDddDmfMO....","......OdDfffffDfffffDddmmmO.....","......OODfffffDfffffddOOOO......","........OOOffMDffffOOO..........","...........OOOOOOOO.............","",""],["",".....OOOO.............OOOO......",".....OMffOO.........OOffMO......","....OddmmffOOOOOOOOOffmmddO.....","....OddlddfffmfMfmfffddlddO.....","....OdllmffffMfffMffffmlfdO.....","....OdfMfffffffffffffffMfdO.....","....OdmMfffffffffffffffMddO.....","....OOmfffffffffffffffffmOO.....","......OmffffffffffffffffO.......","...OOOfDfffffffffffffffffOOO....",".....OfDfffffffPPffffffffO......","...OOOffDffffllpllfffffffOOO....",".....ODffMfflldlldlffMffO.......",".....OmfflfflllddllfflffO.......","......OOflllllllllllllfOO.......","........OdllllllllllldO.........",".........OdddMMMMMdddO..........",".........ODdddddddddDO..........",".........OddMMMMMMMddO..........",".........OMMlllllllMMO..........",".........OfflllllllffO....OO....",".........OfflllllllffdO..OffO...",".........OMfflllllffMMO..OffmO..",".........OfffflfffffffO...OmmO..","........OmfffffMfffffmO...OmmO..",".......OmmfffffdfffffDmO..OdO...",".......OmDfffffDfffffDmdOOMfO...",".......OmDfffffDfffffdddDmfMO...",".......OdDfffffDffffOOddmmmO....",".......OODfffffDOOOO..dOOOO.....",".........OOOffMD......O.........","............OOOO................","","",""]],"loaf":[["","","","","","","","","","","....OOOO.............OOOO.......","....OMffOO.........OOffMO.......","...OddmmffOOOOOOOOOffmmddO......","...OddlddfffmfMfmfffddlddO......","...OdllmffffMfffMffffmlfdO......","...OdfMfffffffffffffffMfdO......","...OdmMfffffffffffffffMddO......","...OOmfffffffffffffffffmOO......",".....OmffffffffffffffffO........","..OOOfDfffffffffffffffffOOO.....","....OfDfffffffPPffffffffO.......","..OOOffDffffllpllfffffffOOO.....","....ODffMfflldlldlffMffOO.......","...OOmfflfflllddllfflffOlOOO....","..OdfOOflllllllllllllfOOlfffO...",".OddfffOdllllllllllldOlllfffdO..",".OddfffllllllllllllllllllfffdO..",".OddffffffffffffffffffffffffddOO",".OddffffffffffffffffffffffffdddO",".OddffffffffffffffffffffffffdddO",".OmmmmmmmlllllmmlllllmmmmmmmmmmO","..OmmmmmOlllllOOlllllOmmmmmmmmmO","...OOODDOlllllOOlllllODDDODDDDOO","......OOOOOOOOOOOOOOOOOOO.OOOO..","",""],["","","","","","","","","","....OOOO.............OOOO.......","....OMffOO.........OOffMO.......","...OddmmffOOOOOOOOOffmmddO......","...OddlddfffmfMfmfffddlddO......","...OdllmffffMfffMffffmlfdO......","...OdfMfffffffffffffffMfdO......","...OdmMfffffffffffffffMddO......","...OOmfffffffffffffffffmOO......",".....OmffffffffffffffffO........","..OOOfDfffffffffffffffffOOO.....","....OfDfffffffPPffffffffO.......","..OOOffDffffllpllfffffffOOO.....","....ODffMfflldlldlffMffO........","....OmfflfflllddllfflffO........",".....OOflllllllllllllfOOO.......","...OOOfOdllllllllllldOlllOOO....","..OdfffllllllllllllllllllfffO...",".OddfffllllllllllllllllllfffdO..",".OddfffllllllllllllllllllfffddOO",".OddffffffffffffffffffffffffdddO",".OddffffffffffffffffffffffffdddO",".OddffffflllllfflllllfffffffdddO","..OmmmmmOlllllOOlllllOmmmmmmmmmO","...OOODDOlllllOOlllllODDDODDDDOO","......OOOOOOOOOOOOOOOOOOO.OOOO..","",""]]},"anchors":{"sit":[[7,8,17,8],[7,8,17,8],[7,8,17,8],[7,8,17,8]],"walk":[[7,8,17,8],[6,7,16,7],[7,8,17,8],[8,7,18,7]],"loaf":[[7,16,17,16],[7,15,17,15]]},"eyes":{"open":{"l":[".NNNN.","NNNNEN","eNNNNN","eeNNNN","eeNNNN",".eeNN."],"r":[".NNNN.","NENNNN","NNNNNe","NNNNee","NNNNee",".NNee."],"dy":0},"shut":{"l":[".OOOO.","OOOOOO",".O..O."],"r":[".OOOO.","OOOOOO",".O..O."],"dy":2},"happy":{"l":["..OO..",".O..O.","O....O"],"r":["..OO..",".O..O.","O....O"],"dy":2},"half":{"l":["OOOOOO","ONNNNO",".OOOO."],"r":["OOOOOO","ONNNNO",".OOOO."],"dy":2}},"coats":[{"id":"orange","label":"橘猫","pal":{"O":"#33060A","D":"#8C2D1F","o":"#9E4927","d":"#C4472F","m":"#DD6040","M":"#E77444","f":"#FB9444","l":"#FCAE64","w":"#FCCA92","W":"#E8B27A","e":"#FADFB0","p":"#E8635F","P":"#9B2F55","N":"#33060A","E":"#FFFFFF","c":"#FF8A5B"}},{"id":"grey","label":"灰猫","pal":{"O":"#1C2026","D":"#3C444E","o":"#4E5762","d":"#69737E","m":"#7B8590","M":"#8E98A3","f":"#A7B1BB","l":"#C3CBD3","w":"#E4E9ED","W":"#C0C7CE","e":"#F2F6F8","p":"#E890A0","P":"#B4566A","N":"#1C2026","E":"#FFFFFF","c":"#FF8A5B"}},{"id":"black","label":"黑猫","pal":{"O":"#0B0A0F","D":"#211E29","o":"#2C2836","d":"#3A3546","m":"#453F53","M":"#4F4860","f":"#5B5370","l":"#6E6586","w":"#8C82A4","W":"#736B89","e":"#F5E7B8","p":"#D4808F","P":"#8E4E5C","N":"#0B0A0F","E":"#FFFFFF","c":"#FF8A5B"}},{"id":"cream","label":"奶白","pal":{"O":"#4A3526","D":"#9A7A5C","o":"#B08F6E","d":"#C8AC8B","m":"#D6BC9E","M":"#E2CBB0","f":"#EFDCC4","l":"#F7EAD8","w":"#FFF8EC","W":"#E8DAC4","e":"#FFFDF6","p":"#E8909C","P":"#B45A68","N":"#4A3526","E":"#FFFFFF","c":"#FF8A5B"}},{"id":"calico","label":"三花","pal":{"O":"#3A2A1E","D":"#6E4A2E","o":"#8A6242","d":"#C4472F","m":"#DD6040","M":"#E8B27A","f":"#F2E2CC","l":"#FBF2E4","w":"#FFFFFF","W":"#E0D2BE","e":"#FFFDF6","p":"#E8635F","P":"#9B2F55","N":"#3A2A1E","E":"#FFFFFF","c":"#FF8A5B"}},{"id":"siam","label":"暹罗","pal":{"O":"#3A2A20","D":"#6B5240","o":"#8A705A","d":"#A88C72","m":"#BFA286","M":"#D2B999","f":"#E6D4B8","l":"#F2E5CE","w":"#FBF3E4","W":"#DCCBB0","e":"#FFFDF6","p":"#D98A8A","P":"#8E5252","N":"#3A2A20","E":"#FFFFFF","c":"#FF8A5B"}}],"items":{"fish":[".................O","................OO","...OOOOOOOO...OOfO",".OOEElllldlOOOfffO",".OfENllldldfdOOfdO","OdffffffffffdDOfdO",".OffffffffffdOOddO",".OOddddddddOO.OOdO","...OOOOOOOO.....OO",".................O",""],"yarn":["","","...OOOOOOOO....","..OlOOllOOlO...",".OfOOOOOOOOO...",".OOOllOOllOO...",".OffffOOOfffO..",".OffffOfOfffO..",".OffffOfOfffO..",".OOOddOOdddO...","..OOOdOOdOOO...","..ODDOOOOOO.O..","...OOOOOOO...O.",".............O.","............O.."],"bird":["","........OOOO....",".......OllfO....",".......OlfNdO...","....OOOlfdddpp..","OO.OllOfdddOp...","OOOlffOODDO.....","OOllfddOOOO.....","OOllddddddO.....","OOOffdddddO.....","...OOOOOOO......",""],"box":["..OOO..................OOO..",".OlllO................OdddO.",".OlllO................OdddO.",".OlllO................OdddO.","OOOOOOOOOOOOOOOOOOOOOOOOOOOO","OD........................DO","OD........................DO","OOOOOOOOOOOOOOOOOOOOOOOOOOOO","OllffffffffffffffffffffffddO","OllffffffffffffffffffffffddO","OllffdddddddddddddddddffffdO","OllffffffffffffffffffffffddO","OllffffffffffffffffffffffddO","OllffffffffffffffffffffffddO","OllffffffffffffffffffffffddO","OOOOOOOOOOOOOOOOOOOOOOOOOOOO"]},"itemPal":{"fish":{"O":"#1E3A4E","D":"#3D6E8E","d":"#559BC0","f":"#82C3E6","l":"#B6E2F7","E":"#FFFFFF","N":"#14232E","p":"#E8635F"},"yarn":{"O":"#5A1D2A","D":"#8E3444","d":"#B8455A","f":"#E06478","l":"#F49CAA","E":"#FFFFFF","N":"#5A1D2A","p":"#E8635F"},"bird":{"O":"#26401E","D":"#446634","d":"#5E8B42","f":"#8CBE5E","l":"#BCDE92","E":"#FFFFFF","N":"#141F10","p":"#F0A83E"},"box":{"O":"#4E3418","D":"#8A6535","d":"#B48A4A","f":"#D8B274","l":"#EDD3A2","E":"#FFFFFF","N":"#4E3418","p":"#E8635F"}}};
const COATS = SPR.coats;

const PET_CSS = `
#cu-pet .cu-puff {
  position: fixed; font-size: 14px; line-height: 1; pointer-events: none; color: #fff;
  text-shadow: 0 1px 3px rgba(0,0,0,0.45);
  animation: cuPuff 1000ms cubic-bezier(0.32,0.72,0,1) forwards;
}
@keyframes cuPuff {
  0%   { opacity: 0; transform: translate(-50%, 0) scale(0.6); }
  22%  { opacity: 1; transform: translate(-50%, -11px) scale(1); }
  100% { opacity: 0; transform: translate(-50%, -38px) scale(1); }
}
#cu-pet .cu-say {
  position: fixed; transform: translate(-50%, -100%);
  font: 500 12px/1.4 -apple-system, "PingFang SC", sans-serif;
  color: #2A1D14; background: #FCCA92;
  padding: 5px 10px; border-radius: 11px; white-space: nowrap;
  box-shadow: 0 3px 10px rgba(0,0,0,0.35), inset 0 0 0 1.5px #33060A;
  animation: cuSayIn 260ms cubic-bezier(0.32,0.72,0,1);
}
#cu-pet .cu-say.tap { pointer-events: auto; cursor: pointer; }
#cu-pet .cu-say.tap:hover { background: #FFE0B0; }
@keyframes cuSayIn {
  from { opacity: 0; transform: translate(-50%, -80%) scale(0.85); }
  to   { opacity: 1; transform: translate(-50%, -100%) scale(1); }
}
#cu-pet .cu-heart {
  position: fixed; pointer-events: none; color: #FF6B8A;
  text-shadow: 0 1px 2px rgba(0,0,0,0.35);
  animation: cuHeart 2s cubic-bezier(0.22,0.68,0,1) forwards;
}
@keyframes cuHeart {
  0%   { opacity: 0; transform: translate(-50%,-50%) scale(0.3); }
  18%  { opacity: 1; transform: translate(-50%,-50%) scale(1.1); }
  100% { opacity: 0;
         transform: translate(calc(-50% + var(--dx)), calc(-50% + var(--dy))) scale(0.8); }
}
#cu-pet .cu-egg {
  position: fixed; transform: translate(-50%, -100%); pointer-events: none;
  font: 700 15px/1.3 -apple-system, "PingFang SC", sans-serif;
  color: #FFF; letter-spacing: 0.5px;
  text-shadow: 0 0 10px rgba(255,107,138,0.9), 0 2px 4px rgba(0,0,0,0.5);
  animation: cuEgg 3.2s cubic-bezier(0.22,0.68,0,1) forwards;
}
@keyframes cuEgg {
  0%   { opacity: 0; transform: translate(-50%,-70%) scale(0.6); }
  15%  { opacity: 1; transform: translate(-50%,-100%) scale(1.15); }
  25%  { transform: translate(-50%,-100%) scale(1); }
  80%  { opacity: 1; }
  100% { opacity: 0; transform: translate(-50%,-150%) scale(1); }
}
#cu-pet .cu-dot {
  position: fixed; width: 10px; height: 10px; border-radius: 50%;
  background: #FF3B30; box-shadow: 0 0 12px 4px rgba(255,59,48,0.72);
  transition: left 380ms cubic-bezier(0.32,0.72,0,1), top 380ms cubic-bezier(0.32,0.72,0,1);
}`;

/* ============================================================================
 * 桌面小猫运行时 —— 与框架无关，靠 requestAnimationFrame 驱动。
 *
 * 关键设计：动画时钟和移动时钟是分开的。
 *   - 移动是连续的：加速度 + 上限速度 + 摩擦，位置每帧按 dt 积分；
 *   - 动画是离散的：每个状态有自己的帧时长，走路时帧率还会跟着实际速度变。
 * 老版本用一个 90ms 的 setInterval 同时管这两件事，所以既卡又硬。
 * ==========================================================================*/
/* ============================================================================
 * 桌面小猫运行时 —— 与框架无关，靠 requestAnimationFrame 驱动。
 *
 * 关键设计：动画时钟和移动时钟是分开的。
 *   - 移动是连续的：加速度 + 上限速度 + 摩擦，位置每帧按 dt 积分；
 *   - 动画是离散的：每个状态有自己的帧时长，走路时帧率还跟着实际速度变。
 * 老版本用一个 90ms 的 setInterval 同时管这两件事，所以既卡又硬。
 *
 * 精灵图里的帧都是「没有眼睛」的，眼睛是运行时按锚点叠上去的贴片 ——
 * 这样眨眼、眯眼、半睁只要换贴片，不用为每种眼神各存一套帧。
 * ==========================================================================*/
function createPet(SPR, opts) {
  opts = opts || {};
  const SCALE = opts.scale || 2;
  const W = SPR.W, H = SPR.H;
  const CW = W * SCALE, CH = H * SCALE;
  const root = opts.root || document.body;
  const POS = opts.pos || "fixed";
  const area = opts.area || (() => ({ w: window.innerWidth, h: window.innerHeight }));

  const S = {
    x: opts.x != null ? opts.x : 200, y: opts.y != null ? opts.y : 200,
    vx: 0, vy: 0, face: 1,
    state: "idle", anim: "idle", frame: 0, animT: 0,
    coat: opts.coat || "orange", accent: opts.accent || "#FF8A5B",
    idleT: 0, blinkT: 2 + Math.random() * 4, blinkLeft: 0, blinkTwice: false,
    moodT: 0, hopT: 0, love: 0,
    item: null, laser: null, box: null, bird: null,
    mouse: { x: 0, y: 0, live: false }, paused: false,
  };

  const ANIM = {
    idle:  { pose: "sit",  dur: 210 },
    walk:  { pose: "walk", dur: 130 },
    sleep: { pose: "loaf", dur: 950 },
  };
  const MAXV = 210, ACC = 1100, FRIC = 7.0, ARRIVE = 26;

  // ---- DOM ----
  const wrap = document.createElement("div");
  wrap.id = "cu-pet";
  wrap.style.cssText = "position:" + POS +
    ";left:0;top:0;width:0;height:0;pointer-events:none;z-index:" + (opts.z || 2147483000);
  const cat = document.createElement("canvas");
  cat.className = "cu-cat";
  cat.width = W; cat.height = H;
  cat.style.cssText = "position:" + POS +
    ";image-rendering:pixelated;pointer-events:auto;cursor:pointer;width:" + CW +
    "px;height:" + CH + "px;transform-origin:50% 100%;";
  wrap.appendChild(cat);
  root.appendChild(wrap);
  const cg = cat.getContext("2d");

  // ---- 绘制 ----
  const palOf = (id) => (SPR.coats.find((c) => c.id === id) || SPR.coats[0]).pal;

  function stampInto(buf, art, ox, oy) {
    for (let y = 0; y < art.length; y++) {
      const line = art[y];
      for (let x = 0; x < line.length; x++) {
        const ch = line[x];
        if (ch === "." || ch === " ") continue;
        const X = ox + x, Y = oy + y;
        if (X >= 0 && Y >= 0 && X < W && Y < H) buf[Y][X] = ch;
      }
    }
  }
  function composeFrame(pose, idx, eyeKind) {
    const src = SPR.frames[pose][idx];
    const buf = [];
    for (let y = 0; y < H; y++) buf.push(new Array(W));
    for (let y = 0; y < src.length; y++) {
      const line = src[y] || "";
      for (let x = 0; x < line.length; x++) if (line[x] !== ".") buf[y][x] = line[x];
    }
    const a = SPR.anchors[pose][idx], e = SPR.eyes[eyeKind];
    stampInto(buf, e.l, a[0], a[1] + e.dy);
    stampInto(buf, e.r, a[2], a[3] + e.dy);
    return buf;
  }
  const cache = {};
  function eyeKind() {
    if (S.state === "sleep") return "shut";
    if (S.moodT > 0) return "happy";
    if (S.blinkLeft > 0) return "shut";
    if (S.state === "stalk") return "half";
    return "open";
  }
  function drawCat() {
    const pose = ANIM[S.anim].pose;
    const n = SPR.frames[pose].length;
    const idx = S.frame % n;
    const eye = eyeKind();
    const key = pose + idx + eye;
    let buf = cache[key] || (cache[key] = composeFrame(pose, idx, eye));
    const pal = palOf(S.coat);
    cg.clearRect(0, 0, W, H);
    for (let y = 0; y < H; y++) {
      const row = buf[y];
      for (let x = 0; x < W; x++) {
        const ch = row[x];
        if (!ch) continue;
        const col = ch === "c" ? S.accent : pal[ch];
        if (!col) continue;
        cg.fillStyle = col; cg.fillRect(x, y, 1, 1);
      }
    }
  }

  // ---- 泡泡 / 道具 ----
  function puff(txt, dx, dy) {
    const e = document.createElement("div");
    e.className = "cu-puff"; e.textContent = txt;
    e.style.left = (S.x + CW / 2 + (dx || 0)) + "px";
    e.style.top = (S.y + (dy || 0)) + "px";
    wrap.appendChild(e);
    setTimeout(() => e.remove(), 1000);
  }
  function makeItem(kind, x, y) {
    const rows = SPR.items[kind], pal = SPR.itemPal[kind];
    const iw = Math.max.apply(null, rows.map((r) => r.length)), ih = rows.length;
    const c = document.createElement("canvas");
    c.width = iw; c.height = ih;
    c.className = "cu-item cu-" + kind;
    c.style.cssText = "position:" + POS + ";image-rendering:pixelated;pointer-events:none;width:" +
      iw * SCALE + "px;height:" + ih * SCALE + "px;left:" + x + "px;top:" + y + "px;";
    const g = c.getContext("2d");
    for (let yy = 0; yy < ih; yy++) {
      const line = rows[yy] || "";
      for (let xx = 0; xx < line.length; xx++) {
        const col = pal[line[xx]];
        if (!col) continue;
        g.fillStyle = col; g.fillRect(xx, yy, 1, 1);
      }
    }
    wrap.appendChild(c);
    return { el: c, w: iw * SCALE, h: ih * SCALE, x: x, y: y, kind: kind };
  }

  // ---- 每帧 ----
  let last = 0, raf = 0;
  function tick(now) {
    raf = requestAnimationFrame(tick);
    if (!last) last = now;
    let dt = (now - last) / 1000; last = now;
    if (dt > 0.1) dt = 0.1;                     // 切回前台时别一次跳太远
    if (S.paused) return;

    S.blinkT -= dt;
    if (S.blinkLeft > 0) {
      S.blinkLeft -= dt;
      if (S.blinkLeft <= 0 && S.blinkTwice) { S.blinkTwice = false; S.blinkLeft = 0.10; }
    } else if (S.blinkT <= 0) {
      S.blinkLeft = 0.11; S.blinkTwice = Math.random() < 0.35;
      S.blinkT = 2.4 + Math.random() * 4.5;
    }
    if (S.moodT > 0) S.moodT -= dt;
    if (S.hopT > 0) S.hopT -= dt;

    // 目标优先级：激光 > 小鸟 > 道具 > 纸箱 > 鼠标
    let tx = null, ty = null, maxv = MAXV, stalk = false;
    if (S.laser)           { tx = S.laser.x; ty = S.laser.y; maxv = MAXV * 1.35; }
    else if (S.bird)       { tx = S.bird.x + S.bird.w / 2; ty = S.bird.y + S.bird.h; maxv = MAXV * 0.42; stalk = true; }
    else if (S.item)       { tx = S.item.x + S.item.w / 2; ty = S.item.y + S.item.h; }
    else if (S.box)        { tx = S.box.x + S.box.w / 2;   ty = S.box.y + S.box.h * 0.55; }
    else if (S.mouse.live) { tx = S.mouse.x; ty = S.mouse.y; }

    const cx = S.x + CW / 2, cy = S.y + CH;
    let moving = false;
    if (tx !== null) {
      const dx = tx - cx, dy = ty - cy, d = Math.hypot(dx, dy);
      if (d > ARRIVE) {
        moving = true;
        S.vx += (dx / d) * ACC * dt; S.vy += (dy / d) * ACC * dt;
        const sp = Math.hypot(S.vx, S.vy);
        if (sp > maxv) { S.vx = S.vx / sp * maxv; S.vy = S.vy / sp * maxv; }
      } else arrived();
    }
    if (!moving) {
      const k = Math.max(0, 1 - FRIC * dt);
      S.vx *= k; S.vy *= k;
      if (Math.abs(S.vx) < 3) S.vx = 0;
      if (Math.abs(S.vy) < 3) S.vy = 0;
    }
    S.x += S.vx * dt; S.y += S.vy * dt;
    const A = area();
    S.x = Math.max(0, Math.min(A.w - CW, S.x));
    S.y = Math.max(0, Math.min(A.h - CH, S.y));

    const speed = Math.hypot(S.vx, S.vy);
    if (Math.abs(S.vx) > 12) S.face = S.vx > 0 ? 1 : -1;

    if (speed > 14) { S.state = stalk ? "stalk" : "walk"; S.anim = "walk"; S.idleT = 0; }
    else {
      S.idleT += dt;
      // 15 秒就犯困：26 秒太久，多数时候还没等到睡着就又动鼠标了
      if (S.idleT > 15 && !S.item && !S.laser && !S.box && !S.bird) { S.state = "sleep"; S.anim = "sleep"; }
      else { S.state = S.box ? "inbox" : "idle"; S.anim = "idle"; }
    }
    if (S.state === "sleep" && Math.random() < dt * 0.55) puff("z", 8 + Math.random() * 6, 2);
    if (S.state === "inbox" && Math.random() < dt * 0.5) puff("♪", -4 + Math.random() * 14, 0);

    const AN = ANIM[S.anim];
    let dur = AN.dur;
    if (S.anim === "walk") dur = Math.max(70, Math.min(200, AN.dur * (MAXV / Math.max(30, speed))));
    S.animT += dt * 1000;
    while (S.animT >= dur) { S.animT -= dur; S.frame++; }

    let sy = 1, sx = 1, lift = 0;
    if (S.hopT > 0) {
      const t = 1 - S.hopT / 0.42;
      lift = Math.sin(t * Math.PI) * 12;
      sy = 1 + Math.sin(t * Math.PI) * 0.10;
      sx = 1 - Math.sin(t * Math.PI) * 0.07;
    }
    cat.style.left = S.x + "px";
    cat.style.top = (S.y - lift) + "px";
    cat.style.transform = "scale(" + (sx * S.face) + "," + sy + ")";
    if (S.laser) moveLaser(dt);
    if (S.bird) driftBird(dt);
    drawCat();
  }

  function arrived() {
    if (S.laser) { jumpLaser(); return; }
    if (S.bird) { flyAway(); return; }
    if (S.item) {
      const k = S.item.kind;
      S.item.el.remove();
      puff(k === "fish" ? "♥" : "!", 0, -2);
      bumpLove(k === "fish" ? 2 : 1);
      S.item = null; S.moodT = 1.1; S.hopT = 0.42;
    }
  }

  function bumpLove(n) { S.love += n; if (opts.onLove) opts.onLove(S.love); }
  cat.addEventListener("mousedown", (e) => {
    e.stopPropagation(); e.preventDefault();
    S.moodT = 1.3; S.hopT = 0.42; S.idleT = 0;
    puff(["♥", "♥", "✦"][Math.floor(Math.random() * 3)], -6 + Math.random() * 12, -2);
    bumpLove(1);
  });
  const onMove = (e) => {
    const p = opts.toLocal ? opts.toLocal(e) : { x: e.clientX, y: e.clientY };
    if (!p) { S.mouse.live = false; return; }
    S.mouse.x = p.x; S.mouse.y = p.y; S.mouse.live = true;
  };
  (opts.moveOn || window).addEventListener("mousemove", onMove, true);

  function spawnNear(kind) {
    const A = area();
    const side = Math.random() < 0.5 ? -1 : 1;
    const x = Math.max(20, Math.min(A.w - 140, S.x + side * (150 + Math.random() * 160)));
    const y = Math.max(20, Math.min(A.h - 110, S.y + CH - 44 + (Math.random() * 60 - 30)));
    return makeItem(kind, x, y);
  }

  let laserT = 0, laserHop = 0;
  function laser() {
    if (S.laser) return;
    const d = document.createElement("div");
    d.className = "cu-dot"; wrap.appendChild(d);
    S.laser = { el: d, x: 0, y: 0 };
    laserT = 13; jumpLaser();
  }
  function jumpLaser() {
    const A = area();
    S.laser.x = 60 + Math.random() * Math.max(40, A.w - 120);
    S.laser.y = 60 + Math.random() * Math.max(40, A.h - 140);
    S.laser.el.style.left = S.laser.x + "px";
    S.laser.el.style.top = S.laser.y + "px";
    laserHop = 1.1 + Math.random() * 0.7;
  }
  function moveLaser(dt) {
    laserT -= dt; laserHop -= dt;
    if (laserHop <= 0) jumpLaser();
    if (laserT <= 0) { S.laser.el.remove(); S.laser = null; S.moodT = 1.0; bumpLove(2); }
  }

  function bird() { if (!S.bird) { S.bird = spawnNear("bird"); S.bird.t = 0; } }
  function driftBird(dt) {
    S.bird.t += dt;
    S.bird.el.style.transform = "translateY(" + Math.sin(S.bird.t * 3.4) * 3 + "px)";
  }
  function flyAway() {
    const b = S.bird; S.bird = null;
    b.el.style.transition = "left 1s ease-in, top 1s ease-in, opacity 1s ease-in";
    b.el.style.left = (b.x + (Math.random() < 0.5 ? -300 : 300)) + "px";
    b.el.style.top = (b.y - 260) + "px";
    b.el.style.opacity = "0";
    setTimeout(() => b.el.remove(), 1100);
    S.moodT = 0.9; puff("…", 0, -2);
  }

  let boxT = 0, boxIv = 0;
  function box() {
    if (S.box) return;
    const rows = SPR.items.box;
    const iw = Math.max.apply(null, rows.map((r) => r.length));
    const x = Math.max(6, Math.min(area().w - iw * SCALE - 6, S.x - (iw * SCALE - CW) / 2));
    S.box = makeItem("box", x, S.y + CH - rows.length * SCALE + 6);
    S.box.el.style.zIndex = "2";           // 箱子要盖住猫的下半身
    boxT = 14;
    boxIv = setInterval(() => {
      boxT -= 0.25;
      if (boxT <= 0) {
        clearInterval(boxIv);
        if (S.box) { S.box.el.remove(); S.box = null; bumpLove(2); }
      }
    }, 250);
  }

  // 猫头顶的气泡。跟 puff 不同：它停留几秒、可以点、点了走 onClick。
  function say(text, onClick, ms) {
    const old = wrap.querySelector(".cu-say");
    if (old) old.remove();
    const e = document.createElement("div");
    e.className = "cu-say" + (onClick ? " tap" : "");
    e.textContent = text;
    e.style.left = (S.x + CW / 2) + "px";
    e.style.top = (S.y - 12) + "px";
    if (onClick) {
      e.addEventListener("mousedown", (ev) => {
        ev.stopPropagation(); ev.preventDefault();
        try { onClick(); } catch (err) {}
        e.remove();
      });
    }
    wrap.appendChild(e);
    setTimeout(() => e.remove(), ms || 9000);
    return e;
  }

  // 1000 赞的隐藏彩蛋：一堆爱心从猫身上炸出来，中间浮一行字
  function celebrate(text) {
    for (let i = 0; i < 14; i++) {
      const h = document.createElement("div");
      h.className = "cu-heart";
      h.textContent = "♥";
      const a = (i / 14) * Math.PI * 2 + Math.random() * 0.4;
      const r = 50 + Math.random() * 70;
      h.style.left = (S.x + CW / 2) + "px";
      h.style.top = (S.y + CH / 2) + "px";
      h.style.setProperty("--dx", Math.cos(a) * r + "px");
      h.style.setProperty("--dy", (Math.sin(a) * r - 30) + "px");
      h.style.animationDelay = (i * 40) + "ms";
      h.style.fontSize = (11 + Math.random() * 9) + "px";
      wrap.appendChild(h);
      setTimeout(() => h.remove(), 2200 + i * 40);
    }
    const b = document.createElement("div");
    b.className = "cu-egg";
    b.textContent = text;
    b.style.left = (S.x + CW / 2) + "px";
    b.style.top = (S.y - 20) + "px";
    wrap.appendChild(b);
    setTimeout(() => b.remove(), 3200);
    S.moodT = 3.2; S.hopT = 0.42;
  }

  function destroy() {
    cancelAnimationFrame(raf);
    if (boxIv) clearInterval(boxIv);
    (opts.moveOn || window).removeEventListener("mousemove", onMove, true);
    wrap.remove();
  }

  raf = requestAnimationFrame(tick);
  return {
    setCoat: (id) => { S.coat = id; },
    setAccent: (c) => { S.accent = c; },
    feed: () => { if (!S.item) S.item = spawnNear("fish"); },
    toy:  () => { if (!S.item) S.item = spawnNear("yarn"); },
    laser: laser, bird: bird, box: box,
    love: () => S.love, setLove: (n) => { S.love = n; },
    say: say, celebrate: celebrate,
    pause: (v) => { S.paused = v; },
    destroy: destroy, _S: S,
  };
}


// 每次渲染都调一次，幂等
const ensurePet = (on, accent, coatId) => {
  if (typeof document === "undefined" || typeof window === "undefined") return;
  if (!on) {
    if (window.__cuPet) { window.__cuPet.destroy(); window.__cuPet = null; }
    return;
  }
  // 版本对不上说明是上一版代码留下的实例／样式，先清掉
  if (window.__cuPetV !== PET_VERSION) {
    if (window.__cuPet) { try { window.__cuPet.destroy(); } catch (e) {} window.__cuPet = null; }
    const oldCss = document.getElementById("cu-pet-css");
    if (oldCss) oldCss.remove();
    window.__cuPetV = PET_VERSION;
  }
  if (!document.getElementById("cu-pet-css")) {
    const st = document.createElement("style");
    st.id = "cu-pet-css"; st.textContent = PET_CSS;
    document.head.appendChild(st);
  }
  if (!window.__cuPet) {
    window.__cuPet = createPet(SPR, {
      scale: 2,
      coat: coatId,
      accent: accent,
      x: Math.max(40, window.innerWidth * 0.5 - 32),
      y: Math.max(40, window.innerHeight - 180),
      onLove: (n) => {
        writePref(K_LOVE, String(n));
        const el = document.querySelector(".cu .loveN");
        if (el) el.textContent = String(n);
        // 到 100 才显示名字，所以这一刻要把名字那块点亮
        const nameEl = document.querySelector(".cu .loveName");
        if (nameEl && n >= NAME_AT) nameEl.textContent = catName();
        const pet = window.__cuPet;
        if (!pet) return;

        // 每 50 提醒一次咖啡。记住已经提过的那个整数倍，免得同一档反复弹。
        const mile = Math.floor(n / COFFEE_EVERY) * COFFEE_EVERY;
        const shown = parseInt(readPref(K_COFF, "0"), 10) || 0;
        if (mile >= COFFEE_EVERY && mile > shown) {
          writePref(K_COFF, String(mile));
          const who = n >= NAME_AT ? catName() : t("aCat");
          pet.say(t("wantCoffee", who) + " ☕", () => {
            try { run("open " + JSON.stringify(AFDIAN)); } catch (e) {}
          });
        }

        // 1000 赞的隐藏彩蛋，只放一次
        if (n >= LOVE_EGG && readPref(K_EGG, "") !== "1") {
          writePref(K_EGG, "1");
          setTimeout(() => pet.celebrate(t("loveEgg", catName())), 400);
        }
      },
    });
    window.__cuPet.setLove(parseInt(readPref(K_LOVE, "0"), 10) || 0);
  }
  window.__cuPet.setAccent(accent);
  window.__cuPet.setCoat(coatId);
};

const petDo = (fn) => () => { if (window.__cuPet) window.__cuPet[fn](); };

// ─────────── 主体 ───────────

export const render = ({ output, error }) => {
  const open = readPref(K_OPEN, "0") === "1";
  const themeId = readPref(K_THEME, "coral");
  const base = PALETTES.find((p) => p.id === themeId) || PALETTES[0];
  const petOn = readPref(K_PET, "0") === "1";
  // 花色 id 改过（white -> cream），本地存的旧值要能回落，否则色卡一个都不高亮
  const savedCoat = readPref(K_COAT, "orange");
  const coatId = COATS.some((c) => c.id === savedCoat) ? savedCoat : "orange";
  const love = parseInt(readPref(K_LOVE, "0"), 10) || 0;

  // 小猫独立于 React 存活，这里只是把开关 / 主题色 / 花色同步过去（幂等）
  ensurePet(petOn, base.a2, coatId);

  // 展开态和主题色由这几个隐藏 input 的 :checked 驱动。
  // ⚠️ 它们必须是 .body 的【直接兄弟】—— CSS 规则用的是通用兄弟选择器
  // (#cu-open:checked ~ .body)，一旦被任何元素包起来就永远匹配不上。
  // 所以这里返回数组、由 React 平铺成兄弟节点，不要包 <span>。
  const switches = [
    <input
      key="open" type="checkbox" id="cu-open" className="sw"
      defaultChecked={open}
      onChange={(e) => writePref(K_OPEN, e.target.checked ? "1" : "0")}
    />,
    <input
      key="lang" type="checkbox" id="cu-lang" className="sw"
      defaultChecked={curLang() === "en"}
      onChange={(e) => writePref(K_LANG, e.target.checked ? "en" : "zh")}
    />,
    <input
      key="pet" type="checkbox" id="cu-pet-sw" className="sw"
      defaultChecked={petOn}
      onChange={(e) => {
        writePref(K_PET, e.target.checked ? "1" : "0");
        ensurePet(e.target.checked, base.a2, coatId);
      }}
    />,
  ].concat(
    COATS.map((c) => (
      <input
        key={c.id} type="radio" name="cu-coat" id={"cu-c-" + c.id} className="sw"
        defaultChecked={c.id === coatId}
        onChange={() => { writePref(K_COAT, c.id); if (window.__cuPet) window.__cuPet.setCoat(c.id); }}
      />
    ))
  ).concat(
    PALETTES.map((p) => (
      <input
        key={p.id} type="radio" name="cu-theme" id={"cu-t-" + p.id} className="sw"
        defaultChecked={p.id === themeId}
        onChange={() => writePref(K_THEME, p.id)}
      />
    ))
  );

  const shell = (inner) => (<div className="cu">{switches}<div className="body">{inner}</div></div>);

  if (error) return shell(<div className="pill"><div className="hint"><T k="err" />{String(error)}</div></div>);

  let data = null;
  try { data = JSON.parse(output); } catch (e) { data = null; }
  if (!data || !data.ok) return shell(<div className="pill"><div className="hint"><T k="loading" /></div></div>);

  const L = data.limits || {};
  const five = L.five || null;
  const seven = L.seven || null;
  const hasLimits = !!(five || seven);
  const stale = L.age != null && L.age > STALE_AFTER;

  const days = data.days || [];
  const today = data.today || { cost: 0, tok: 0 };
  const d14 = data.days14 || { cost: 0, tok: 0 };
  const topModel = (data.models && data.models[0]) || null;
  const modelName = L.model || (topModel ? topModel.name : "—");

  const pos = posStyle();

  return shell(
    <div className={stale ? "stale" : ""}>
      {/* ── 折叠态 ── */}
      <div className="pill drag" style={pos} onMouseDown={startDrag}>
        <span className="dot" title={t("home")} onDoubleClick={resetPos}
              style={{ background: base.a2, boxShadow: "0 0 8px rgba(" + base.rgb + ",0.85)" }} />
        <Meter k={<T k="h5" />} pct={five ? five.pct : null} base={base} />
        <Meter k={<T k="d7" />}  pct={seven ? seven.pct : null} base={base} />
        <Chevron id="cu-open" cls="down" />
      </div>

      {/* ── 展开态 ── */}
      <div className="card drag" style={pos}>
        <div className="head" onMouseDown={startDrag}>
          <div className="brand">
            <span className="dot" title={t("home")} onDoubleClick={resetPos}
                  style={{ background: base.a2, boxShadow: "0 0 8px rgba(" + base.rgb + ",0.85)" }} />
            Claude Usage
          </div>
          <div className="headRight">
            <span className={"age" + (stale ? " warn" : "")}>{hasLimits ? fmtAge(L.age) : ""}</span>
            <Chevron id="cu-open" cls="up" />
          </div>
        </div>

        {hasLimits ? (
          <div className="rings">
            <Ring gid="cuG5" base={base} pct={five ? five.pct : null}
                  label={<T k="h5full" />} sub={five ? <T k="resetIn" a={[fmtDur(five["in"])]} /> : <T k="noData" />} />
            <div className="vline" />
            <Ring gid="cuG7" base={base} pct={seven ? seven.pct : null}
                  label={<T k="d7full" />} sub={seven ? <T k="resetIn" a={[fmtDur(seven["in"])]} /> : <T k="noData" />} />
          </div>
        ) : (
          <div className="setup">
            <div className="setupTitle"><T k="setupTitle" /></div>
            <div className="setupBody">
              <T k="setupBody" />
            </div>
          </div>
        )}

        {L.ctx != null && (
          <div className="ctx">
            <span className="ctxK"><T k="ctx" /></span>
            <div className="ctxBar">
              <div className="ctxFill" style={{
                width: Math.min(100, L.ctx) + "%",
                background: "linear-gradient(90deg," + base.a1 + "," + base.a2 + ")",
              }} />
            </div>
            <span className="ctxV">{Math.round(L.ctx)}%</span>
          </div>
        )}

        <div className="plate">
          <div className="plateHead"><span><T k="last14" /></span><span className="strong">{fmtUsd(d14.cost)}</span></div>
          <Bars days={days} />
        </div>

        <div className="plate">
          <div className="plateHead"><span><T k="heat" /></span><span className="strong"><T k="nDays" a={[days.length]} /></span></div>
          <Heat days={days} />
        </div>

        <div className="foot">
          <div className="stat">
            <div className="statVal">{fmtUsd(today.cost)}</div>
            <div className="statKey"><T k="today" /></div>
          </div>
          <div className="stat">
            <div className="statVal">{fmtTok(today.tok)}</div>
            <div className="statKey"><T k="todayTok" /></div>
          </div>
          <div className="stat right">
            <div className="statVal accent">{modelName}</div>
            <div className="statKey">{topModel ? <T k="share" a={[Math.round(topModel.share * 100)]} /> : ""}</div>
          </div>
        </div>

        <div className="themes">
          {PALETTES.map((p) => (
            <label key={p.id} htmlFor={"cu-t-" + p.id} title={t("themes")[p.id] || p.id} onMouseDown={stop}
                   className={"swatch sw-" + p.id}
                   style={{ background: "linear-gradient(135deg," + p.a1 + "," + p.a2 + ")" }} />
          ))}
          <label htmlFor="cu-lang" className="langSw" title={t("langTip")} onMouseDown={stop}>
            <span className="zh">EN</span>
            <span className="en">中</span>
          </label>
          <label htmlFor="cu-pet-sw" className="petSw" title={t("plays")} onMouseDown={stop}>
            <span className="petPaw">🐾</span>
          </label>
        </div>

        {/* 小猫面板：开关打开后才展开 */}
        <div className="petPanel">
          <div className="petRow">
            <span className="petKey"><T k="coats" /></span>
            {COATS.map((c) => (
              <label key={c.id} htmlFor={"cu-c-" + c.id} title={t("catCoats")[c.id] || c.id} onMouseDown={stop}
                     className={"coat coat-" + c.id}
                     style={{ background: c.pal.f, boxShadow: "inset 0 0 0 1.5px " + c.pal.O }} />
            ))}
            <span className="loveBox" title={love >= NAME_AT ? t("loveTip") : t("nameLocked", NAME_AT)}>
              {love >= NAME_AT ? (
                <input
                  className="loveName" type="text" maxLength={8}
                  defaultValue={catName()} placeholder={t("namePh")}
                  onMouseDown={stop}
                  onChange={(e) => {
                    const v = e.target.value.trim();
                    writePref(K_NAME, v || DEFAULT_NAME);
                  }}
                />
              ) : null}
              <span className="loveH">♥</span><span className="loveN">{love}</span>
            </span>
          </div>
          <div className="petRow">
            <span className="petKey"><T k="plays" /></span>
            <button className="petAct" title={t("feed")} onMouseDown={stop} onClick={petDo("feed")}>🐟</button>
            <button className="petAct" title={t("toy")} onMouseDown={stop} onClick={petDo("toy")}>🧶</button>
            <button className="petAct" title={t("laser")} onMouseDown={stop} onClick={petDo("laser")}>🔴</button>
            <button className="petAct" title={t("box")} onMouseDown={stop} onClick={petDo("box")}>📦</button>
            <button className="petAct" title={t("bird")} onMouseDown={stop} onClick={petDo("bird")}>🐦</button>
              <button className="coffeeSw" title={t("coffeeTip")} onMouseDown={stop}
                      onClick={() => { try { run("open " + JSON.stringify(AFDIAN)); } catch (e) {} }}>
                ☕
              </button>
          </div>
        </div>
      </div>
    </div>
  );
};

// ─────────── 样式 ───────────
// macOS 26 Liquid Glass：大圆角、镜面高光、发丝描边用 inset box-shadow
// （比 border 在 Retina 上更锐），三层阴影拉开景深，内容分组用更亮的内嵌玻璃板。

export const className = `
  /* 容器铺满全屏，但对鼠标完全穿透 —— Übersicht 靠「e.target 是不是容器本身」
     来判断鼠标在不在挂件上，pointer-events:none 正好让空白处命中容器，
     所以桌面右键、拖选图标都不受影响。 */
  top: 0; left: 0; right: 0; bottom: 0;
  pointer-events: none;
  font-family: "SF Pro Display", -apple-system, "PingFang SC", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  color: #F5F5F7;

  /* 默认主题变量；下面的 :checked 规则会覆盖它们 */
  .body {
    --a1: #F0906F;
    --a2: #D97757;
    --glow: 217, 119, 87;
  }
  #cu-t-blue:checked   ~ .body { --a1:#64D2FF; --a2:#0A84FF; --glow:10,132,255;  }
  #cu-t-purple:checked ~ .body { --a1:#DA8FFF; --a2:#BF5AF2; --glow:191,90,242;  }
  #cu-t-green:checked  ~ .body { --a1:#5BE49B; --a2:#30D158; --glow:48,209,88;   }
  #cu-t-mono:checked   ~ .body { --a1:#E5E5EA; --a2:#8E8E93; --glow:174,174,178; }

  /* 视觉隐藏但仍可被 label 激活的标准写法。不要用 display:none 或 0 尺寸，
     那些在某些引擎下会影响 label 的转发行为。 */
  .sw {
    position: absolute;
    width: 1px; height: 1px;
    opacity: 0; overflow: hidden;
    clip-path: inset(50%);
    pointer-events: none;
  }

  /* 折叠 / 展开切换
     ⚠️ 这里刻意不用 display:none。WebKit 在元素由 display:none 变为可见时
     会新建合成层，而 backdrop-filter 此时还没采样到背景，要等下一次重绘才
     正确 —— 表现就是刚展开时没有毛玻璃，得再点一下才出现。
     改用 visibility + opacity，让两张卡片始终留在层树里，背景采样不中断。 */
  .pill, .card {
    transform: translateZ(0);          /* 常驻独立合成层，保证 backdrop 持续采样 */
    will-change: opacity;
    transition:
      opacity 200ms cubic-bezier(0.32, 0.72, 0, 1),
      visibility 0s linear 0s;
  }
  .card { opacity: 0; visibility: hidden; pointer-events: none; }
  #cu-open:checked ~ .body .card { opacity: 1; visibility: visible; pointer-events: auto; }
  #cu-open:checked ~ .body .pill { opacity: 0; visibility: hidden; pointer-events: none; }

  #cu-open:checked ~ .body .chev.down { display: none; }
  .chev.up { display: none; }
  #cu-open:checked ~ .body .chev.up { display: flex; }

  /* 拖动手柄：折叠态整枚药丸都能拖，展开态拖顶栏 */
  .pill, .card .head { cursor: grab; }
  .pill.dragging, .card.dragging .head { cursor: grabbing; }
  .pill.dragging, .card.dragging { transition: none; }
  .dot { cursor: pointer; }

  /* ── 玻璃基底 ── */
  .pill, .card {
    position: absolute;
    pointer-events: auto;
    background:
      linear-gradient(155deg, rgba(70, 62, 58, 0.52) 0%, rgba(28, 25, 23, 0.62) 55%, rgba(20, 18, 17, 0.70) 100%);
    -webkit-backdrop-filter: blur(44px) saturate(200%) brightness(1.06);
    backdrop-filter: blur(44px) saturate(200%) brightness(1.06);
    box-shadow:
      inset 0 0.5px 0 rgba(255, 255, 255, 0.22),
      inset 0 0 0 0.5px rgba(255, 255, 255, 0.10),
      0 1px 2px rgba(0, 0, 0, 0.30),
      0 12px 30px rgba(0, 0, 0, 0.34),
      0 30px 64px rgba(0, 0, 0, 0.24);
    overflow: hidden;
  }
  /* 镜面高光：左上角一团极淡的光，模拟玻璃折射 */
  .pill::after, .card::after {
    content: "";
    position: absolute;
    inset: 0;
    pointer-events: none;
    background: radial-gradient(120% 70% at 18% -12%, rgba(255,255,255,0.16), rgba(255,255,255,0) 60%);
  }

  /* ── 折叠药丸 ── */
  .pill {
    width: 244px;
    border-radius: 21px;
    padding: 12px 8px 12px 16px;
    display: flex;
    align-items: center;
    gap: 14px;
  }
  .dot { width: 7px; height: 7px; border-radius: 50%; flex: none; }

  .meter { flex: 1; min-width: 0; }
  .meterTop { display: flex; align-items: baseline; justify-content: space-between; gap: 6px; }
  .meterK { font-size: 9.5px; letter-spacing: 0.04em; color: rgba(245,245,247,0.42); white-space: nowrap; }
  .meterV {
    font-size: 15px; font-weight: 590; letter-spacing: -0.02em;
    font-variant-numeric: tabular-nums;
  }
  .meterBar {
    height: 3px; margin-top: 6px; border-radius: 2px;
    background: rgba(255,255,255,0.11); overflow: hidden;
  }
  .meterFill { height: 100%; border-radius: 2px; transition: width 700ms cubic-bezier(0.32,0.72,0,1); }

  /* ── 箭头按钮 ── */
  .chev {
    flex: none;
    width: 22px; height: 22px;
    display: flex; align-items: center; justify-content: center;
    border-radius: 50%;
    color: rgba(245,245,247,0.50);
    cursor: pointer;
    transition: background 180ms ease, color 180ms ease, transform 260ms cubic-bezier(0.32,0.72,0,1);
  }
  .chev:hover { background: rgba(255,255,255,0.12); color: rgba(245,245,247,0.92); }
  .chev.up { transform: rotate(180deg); }

  /* ── 展开卡片 ── */
  .card { width: 336px; border-radius: 27px; padding: 18px 20px 16px; }

  .head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
  .brand {
    display: flex; align-items: center; gap: 8px;
    font-size: 11.5px; font-weight: 600; letter-spacing: 0.09em; text-transform: uppercase;
    color: rgba(245,245,247,0.88);
  }
  .headRight { display: flex; align-items: center; gap: 4px; }
  .age { font-size: 10.5px; color: rgba(245,245,247,0.34); font-variant-numeric: tabular-nums; }
  .age.warn { color: #FF9F0A; }
  .stale .ringWrap, .stale .meterBar { opacity: 0.45; }

  /* ── 环 ── */
  .rings { display: flex; align-items: flex-start; margin-bottom: 4px; }
  .ring { flex: 1; display: flex; flex-direction: column; align-items: center; }
  .vline {
    width: 1px; align-self: stretch; margin: 6px 0 16px;
    background: linear-gradient(180deg, transparent, rgba(255,255,255,0.11), transparent);
  }
  .ringWrap { position: relative; width: 84px; height: 84px; transition: opacity 400ms ease; }
  .ringWrap svg { transform: rotate(-90deg); display: block; }
  .track { fill: none; stroke: rgba(255,255,255,0.08); stroke-width: 7; }
  .prog {
    fill: none; stroke-width: 7; stroke-linecap: round;
    transition: stroke-dashoffset 900ms cubic-bezier(0.32,0.72,0,1);
  }
  .ringVal {
    position: absolute; inset: 0;
    display: flex; align-items: center; justify-content: center;
    font-size: 22px; font-weight: 620; letter-spacing: -0.035em;
    font-variant-numeric: tabular-nums;
  }
  .ringVal i { font-style: normal; font-size: 11px; font-weight: 500; opacity: 0.40; margin-left: 1.5px; }
  .ringVal .dash { opacity: 0.22; font-size: 19px; }
  .ringLabel { margin-top: 9px; font-size: 11.5px; font-weight: 500; color: rgba(245,245,247,0.80); }
  .ringSub { margin-top: 2px; font-size: 10px; color: rgba(245,245,247,0.34); font-variant-numeric: tabular-nums; }

  /* ── 上下文细条 ── */
  .ctx { display: flex; align-items: center; gap: 9px; margin: 12px 2px 2px; }
  .ctxK { font-size: 10px; color: rgba(245,245,247,0.38); white-space: nowrap; }
  .ctxBar { flex: 1; height: 3px; border-radius: 2px; background: rgba(255,255,255,0.10); overflow: hidden; }
  .ctxFill { height: 100%; border-radius: 2px; transition: width 700ms cubic-bezier(0.32,0.72,0,1); }
  .ctxV { font-size: 10px; color: rgba(245,245,247,0.55); font-variant-numeric: tabular-nums; }

  /* ── 内嵌玻璃板 ── */
  .plate {
    margin-top: 13px; padding: 12px 13px 13px;
    border-radius: 16px;
    background: rgba(255,255,255,0.045);
    box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.07);
  }
  .plateHead {
    display: flex; justify-content: space-between; align-items: baseline;
    font-size: 10.5px; color: rgba(245,245,247,0.40); margin-bottom: 11px;
  }
  .plateHead .strong {
    font-size: 11.5px; font-weight: 600; color: rgba(245,245,247,0.80);
    font-variant-numeric: tabular-nums;
  }

  /* ── 柱状图 ── */
  .bars { display: flex; align-items: flex-end; gap: 4px; height: 40px; }
  .barSlot { flex: 1; display: flex; align-items: flex-end; height: 100%; }
  .bar {
    width: 100%; border-radius: 2.5px;
    background: linear-gradient(180deg, var(--a1), var(--a2));
    transition: height 700ms cubic-bezier(0.32,0.72,0,1);
  }
  .bar.zero { background: rgba(255,255,255,0.09); }
  .bar.today { box-shadow: 0 0 9px rgba(var(--glow), 0.55); }

  /* ── 热力图 ── */
  .heatMonths { display: flex; gap: 3px; margin-bottom: 5px; }
  .heatMonth {
    width: 12px; flex: none;
    font-size: 8.5px; color: rgba(245,245,247,0.30); white-space: nowrap;
  }
  .heatGrid { display: flex; gap: 3px; }
  .heatCol { display: flex; flex-direction: column; gap: 3px; }
  .cell { width: 12px; height: 12px; border-radius: 3px; }
  .cell.l0 { background: rgba(255,255,255,0.055); }
  .cell.l1 { background: rgba(var(--glow), 0.30); }
  .cell.l2 { background: rgba(var(--glow), 0.52); }
  .cell.l3 { background: rgba(var(--glow), 0.76); }
  .cell.l4 { background: rgba(var(--glow), 1); box-shadow: 0 0 7px rgba(var(--glow), 0.45); }
  .cell.pad { background: transparent; }
  .heatLegend {
    display: flex; align-items: center; gap: 3px;
    margin-top: 9px; font-size: 8.5px; color: rgba(245,245,247,0.30);
  }
  .heatLegend i { width: 9px; height: 9px; border-radius: 2.5px; }
  .heatLegend span:first-child { margin-right: 2px; }
  .heatLegend span:last-child { margin-left: 2px; }

  /* ── 页脚 ── */
  .foot { display: flex; align-items: flex-end; gap: 18px; margin-top: 15px; }
  .stat.right { margin-left: auto; text-align: right; }
  .statVal {
    font-size: 14px; font-weight: 590; letter-spacing: -0.02em;
    color: rgba(245,245,247,0.95); font-variant-numeric: tabular-nums;
  }
  .statVal.accent { color: var(--a1); }
  .statKey { margin-top: 2px; font-size: 9.5px; color: rgba(245,245,247,0.32); }

  /* ── 主题色选择 ── */
  .themes {
    display: flex; align-items: center; gap: 9px;
    margin-top: 15px; padding-top: 13px;
    box-shadow: inset 0 0.5px 0 rgba(255,255,255,0.07);
  }
  .swatch {
    width: 13px; height: 13px; border-radius: 50%;
    cursor: pointer; opacity: 0.42;
    box-shadow: inset 0 0 0 0.5px rgba(0,0,0,0.28);
    transition: opacity 200ms ease, transform 260ms cubic-bezier(0.32,0.72,0,1);
  }
  .swatch:hover { opacity: 0.85; transform: scale(1.12); }
  #cu-t-coral:checked  ~ .body .sw-coral,
  #cu-t-blue:checked   ~ .body .sw-blue,
  #cu-t-purple:checked ~ .body .sw-purple,
  #cu-t-green:checked  ~ .body .sw-green,
  #cu-t-mono:checked   ~ .body .sw-mono {
    opacity: 1;
    box-shadow: inset 0 0 0 0.5px rgba(0,0,0,0.28), 0 0 0 2px rgba(255,255,255,0.30);
  }

  /* ── 中英切换 ── */
  /* 两份文案都在 DOM 里，用兄弟选择器挑显示哪份 —— 切换是瞬时的，
     不用等 8 秒后的重渲染。 */
  .i18n .en { display: none; }
  #cu-lang:checked ~ .body .i18n .zh { display: none; }
  #cu-lang:checked ~ .body .i18n .en { display: inline; }
  .langSw {
    margin-left: auto; margin-right: 6px; cursor: pointer;
    font-size: 9.5px; font-weight: 600; letter-spacing: 0.5px;
    color: rgba(245,245,247,0.42);
    padding: 3px 7px; border-radius: 7px;
    background: rgba(255,255,255,0.06);
    box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.10);
    transition: color 200ms ease, background 200ms ease;
  }
  .langSw:hover { color: rgba(245,245,247,0.85); background: rgba(255,255,255,0.12); }
  /* 咖啡按钮：那一排的最后一个，也就是展开卡片的右下角 */
  .coffeeSw {
    -webkit-appearance: none; appearance: none; border: none; outline: none;
    cursor: pointer; padding: 3px 6px;
    margin-left: auto;   /* 顶到「玩法」那行的最右 = 面板展开后的右下角 */
    font-size: 12px; line-height: 1; border-radius: 7px;
    background: transparent; opacity: 0.42;
    transition: opacity 200ms ease, background 200ms ease, transform 260ms cubic-bezier(0.32,0.72,0,1);
  }
  .coffeeSw:hover {
    opacity: 1; background: rgba(255,255,255,0.12); transform: scale(1.14);
  }
  .coffeeSw:active { transform: scale(0.94); }
  .langSw .en { display: none; }
  #cu-lang:checked ~ .body .langSw .zh { display: none; }
  #cu-lang:checked ~ .body .langSw .en { display: inline; }

  /* ── 宠物控制 ── */
  .petSw {
    display: flex; align-items: center; justify-content: center;
    width: 22px; height: 22px; border-radius: 7px;
    cursor: pointer; opacity: 0.34;
    background: rgba(255,255,255,0.06);
    transition: opacity 200ms ease, background 200ms ease;
  }
  .petSw:hover { opacity: 0.7; }
  .petPaw { font-size: 11px; filter: grayscale(1); transition: filter 200ms ease; }
  #cu-pet-sw:checked ~ .body .petSw { opacity: 1; background: rgba(var(--glow), 0.22); }
  #cu-pet-sw:checked ~ .body .petPaw { filter: none; }

  /* 小猫关着时整个面板收起来 */
  .petPanel {
    max-height: 0; opacity: 0; overflow: hidden;
    transition: max-height 300ms cubic-bezier(0.32,0.72,0,1), opacity 220ms ease, margin-top 300ms;
  }
  #cu-pet-sw:checked ~ .body .petPanel { max-height: 90px; opacity: 1; margin-top: 12px; }
  .petRow { display: flex; align-items: center; gap: 6px; margin-top: 8px; }
  .petKey { font-size: 9.5px; color: rgba(245,245,247,0.32); width: 24px; flex: none; }
  .coat {
    width: 14px; height: 14px; border-radius: 50%; cursor: pointer;
    opacity: 0.45; transition: opacity 200ms ease, transform 260ms cubic-bezier(0.32,0.72,0,1);
  }
  .coat:hover { opacity: 0.85; transform: scale(1.12); }
  #cu-c-orange:checked ~ .body .coat-orange,
  #cu-c-cream:checked  ~ .body .coat-cream,
  #cu-c-black:checked  ~ .body .coat-black,
  #cu-c-grey:checked   ~ .body .coat-grey,
  #cu-c-calico:checked ~ .body .coat-calico,
  #cu-c-siam:checked   ~ .body .coat-siam { opacity: 1; transform: scale(1.14); }
  .loveBox {
    margin-left: auto; display: flex; align-items: center; gap: 3px;
    font-size: 10px; font-variant-numeric: tabular-nums;
  }
  /* 名字输入框：平时看着像普通文字，点上去才显出可编辑 */
  .loveName {
    width: 46px; border: none; outline: none; background: transparent;
    font: inherit; font-size: 10px; color: rgba(245,245,247,0.78);
    text-align: right; padding: 1px 3px; border-radius: 5px;
    -webkit-user-select: text; user-select: text;
    transition: background 180ms ease;
  }
  .loveName::placeholder { color: rgba(245,245,247,0.28); }
  .loveName:hover  { background: rgba(255,255,255,0.07); }
  .loveName:focus  { background: rgba(255,255,255,0.13); color: #fff; }
  .loveH { color: var(--a1); font-size: 9px; }
  .loveN { color: rgba(245,245,247,0.62); }
  .petAct {
    flex: none; width: 23px; height: 22px; padding: 0;
    border: 0; border-radius: 7px; cursor: pointer;
    background: rgba(255,255,255,0.06);
    font-size: 11px; line-height: 1;
    transition: background 180ms ease, transform 200ms cubic-bezier(0.32,0.72,0,1);
  }
  .petAct:hover { background: rgba(255,255,255,0.14); transform: translateY(-1px); }
  .petAct:active { transform: translateY(0) scale(0.94); }

  /* ── 引导 / 提示 ── */
  .setup { padding: 2px 2px 8px; }
  .setupTitle { font-size: 12.5px; font-weight: 600; color: rgba(245,245,247,0.88); margin-bottom: 6px; }
  .setupBody { font-size: 11px; line-height: 1.7; color: rgba(245,245,247,0.44); }
  .setupBody code {
    font-family: "SF Mono", ui-monospace, monospace; font-size: 10px;
    padding: 1px 5px; margin: 0 2px; border-radius: 5px;
    background: rgba(var(--glow), 0.18); color: var(--a1);
  }
  .hint { font-size: 11.5px; color: rgba(245,245,247,0.42); padding: 2px 6px; }
`;
