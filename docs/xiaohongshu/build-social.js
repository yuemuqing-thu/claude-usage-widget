// 开发期宣传稿生成器；不参与挂件运行。精灵直接取自产品，截图按源比例裁切。
const fs = require('fs');
const path = require('path');
const dir = __dirname;
const src = fs.readFileSync(path.join(dir, '../../claude-usage.widget/index.jsx'), 'utf8');
const spr = JSON.parse(src.match(/^const SPR = (.*);$/m)[1]);
const dark = '#123C35', mint = '#82E0B7', paper = '#F4F0E6', ink = '#193D34';
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
const text = (x,y,s,size=28,color=paper,weight=400,extra='') => `<text x="${x}" y="${y}" fill="${color}" font-size="${size}" font-weight="${weight}" ${extra}>${esc(s)}</text>`;
const rule = (y,color=mint) => `<path d="M72 ${y}H1008" stroke="${color}" stroke-opacity=".25"/>`;
const imageData = name => 'data:image/png;base64,' + fs.readFileSync(path.join(dir,'..',name)).toString('base64');
let clipId=0;
// 源裁切框与目标共用一个缩放系数；圆角贴着真实挂件边缘，没有额外的外壳。
function shot(file, fullW, fullH, box, x, y, w, radius) {
  const [bx,by,bw,bh]=box, scale=w/bw, id='crop'+(++clipId);
  return `<g transform="translate(${x} ${y}) scale(${scale})"><defs><clipPath id="${id}"><rect width="${bw}" height="${bh}" rx="${radius}"/></clipPath></defs><g clip-path="url(#${id})"><image x="${-bx}" y="${-by}" width="${fullW}" height="${fullH}" xlink:href="${imageData(file)}"/></g></g>`;
}
// 2026-09-18 用户提供的双页签实拍；保留原文件，所有裁切都发生在 SVG 中。
const currentShot='shot-desktop-20260918.png';
const card=(x,y,w)=>shot(currentShot,1034,1498,[54,26,752,1350],x,y,w,62);
const pill=(x,y,w)=>shot('shot-pill.png',776,176,[24,36,536,102],x,y,w,48);
function cat(x,y,scale,coat='orange',pose='sit',eye='open') {
  const rows=spr.frames[pose][0].map(s=>Array.from(s.padEnd(spr.W,'.')));
  const a=spr.anchors[pose][0],e=spr.eyes[eye],pal=spr.coats.find(c=>c.id===coat).pal;
  for(const [art,ox,oy] of [[e.l,a[0],a[1]+e.dy],[e.r,a[2],a[3]+e.dy]])
    art.forEach((row,dy)=>Array.from(row).forEach((ch,dx)=>{if(ch!=='.')rows[oy+dy][ox+dx]=ch;}));
  let pixels='';rows.forEach((row,yy)=>row.forEach((ch,xx)=>{if(pal[ch])pixels+=`<rect x="${xx}" y="${yy}" width="1" height="1" fill="${pal[ch]}"/>`;}));
  return `<g transform="translate(${x} ${y}) scale(${scale})" shape-rendering="crispEdges">${pixels}</g>`;
}
function page(n, name, light, body) {
  const fg=light?ink:paper, secondary=light?'#55776B':'#A7C6B6';
  const content=`<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1080" height="1080" viewBox="0 0 1080 1080"><g font-family="PingFang SC,Helvetica Neue,sans-serif"><rect width="1080" height="1080" fill="${light?paper:dark}"/>${text(72,76,'CLAUDE USAGE  /  桌面养猫计划',20,secondary,500)}${text(1008,76,String(n).padStart(2,'0')+' / 06',20,secondary,400,'text-anchor="end"')}${body}${text(72,1030,'macOS · Claude Code + Codex',19,secondary)}${text(1008,1030,'免费开源',19,secondary,400,'text-anchor="end"')}</g></svg>`;
  fs.writeFileSync(path.join(dir,name+'.svg'),content+'\n');
}
page(1,'01-cover',false,
  text(72,190,'本来只是想看 AI 用量',39,'#B9D2C3')+
  text(66,305,'结果在 Mac 上',88,paper,650)+text(66,413,'养了只猫。',98,mint,650)+
  cat(166,502,8,'orange','sit','happy')+card(654,448,294)+
  text(78,861,'Claude / Codex 用量，放在桌面上看。',27)+
  text(78,908,'等它写代码的时候，还能摸两下猫。',27,'#B9D2C3')+
  text(78,964,'跟着鼠标跑 / 投喂 / 玩毛线球 / 摸摸头',21,'#B9D2C3'));
page(2,'02-desktop',true,
  text(70,175,'用掉多少，什么时候重置',61,ink,650)+
  text(72,235,'回到桌面就能看。点一下，还能展开。',29,'#55776B')+
  card(74,297,370)+
  text(515,376,'5 小时 / 7 天',43,ink,600)+text(515,427,'两个窗口，分别看已用额度。',26,'#55776B')+
  text(515,553,'Claude ↔ Codex',40,ink,600)+text(515,604,'装了哪家，就显示哪家。',26,'#55776B')+
  text(515,728,'也可以缩成一小条',35,ink,600)+pill(515,773,477)+
  text(515,944,'界面实拍 · 数值为拍摄时状态',19,'#648175'));
page(3,'03-data',false,
  text(70,178,'最近写了多少代码，',63,paper,650)+text(70,256,'用量也留了点痕迹。',63,paper,650)+
  text(73,338,'近 14 天 · API 等价估算趋势',28,mint,500)+
  shot(currentShot,1034,1498,[94,452,672,180],72,370,936,34)+
  text(73,682,'91 天 · 活动热力图',28,mint,500)+
  shot(currentShot,1034,1498,[118,725,391,279],72,716,330,12)+
  text(466,788,'忙过哪几天，一眼能找到。',30)+
  text(466,843,'按本机会话记录统计。',25,'#B9D2C3')+
  text(466,891,'金额是 API 等价估算，',23,'#B9D2C3')+
  text(466,928,'不是订阅之外多扣的钱。',23,'#B9D2C3'));
page(4,'04-cat',true,
  text(70,175,'正事做完了。',69,ink,650)+text(70,263,'接下来，摸猫。',69,ink,650)+
  cat(88,349,7,'orange','sit','happy')+cat(421,349,7,'cream')+cat(749,349,7,'black','loaf','shut')+
  text(194,666,'点一下，眯眼睛',25,ink,500,'text-anchor="middle"')+
  text(535,666,'跟着鼠标跑',25,ink,500,'text-anchor="middle"')+
  text(863,666,'没事就打个盹',25,ink,500,'text-anchor="middle"')+
  `<path d="M72 740H1008" stroke="#C7D2C4"/>`+
  text(72,804,'还能喂鱼、逗毛线球、追激光点。',31,ink)+
  text(72,858,'摸熟了以后，可以给它起个名字。',31,ink)+
  text(72,944,'六种花色，挑一只顺眼的。',25,'#55776B')+
  spr.coats.map((c,i)=>`<circle cx="${699+i*49}" cy="934" r="13" fill="${c.pal.f}"/>`).join(''));
page(5,'05-privacy',false,
  text(70,179,'装好以后，',68,paper,650)+text(70,269,'不用再交一遍账号。',68,paper,650)+
  text(72,412,'01',25,mint)+text(156,418,'不读登录凭据',43,paper,600)+
  text(156,473,'不用粘贴 token，也不用提供密码。',27,'#B9D2C3')+rule(519)+
  text(72,586,'02',25,mint)+text(156,592,'在本机读，在本机算',43,paper,600)+
  text(156,647,'用量采集不联网，不上传会话记录。',27,'#B9D2C3')+rule(693)+
  text(72,760,'03',25,mint)+text(156,766,'代码也公开了',43,paper,600)+
  text(156,821,'免费使用，MIT 开源。',27,'#B9D2C3')+
  text(72,955,'数据随本地会话更新；停用后显示最后一次记录。',23,'#B9D2C3'));
page(6,'06-install',true,
  text(70,184,'想在桌面养一只？',71,ink,650)+text(72,260,'项目已经开源，README 里有完整安装步骤。',28,'#55776B')+
  text(72,370,'已经有 Homebrew',28,ink,600)+
  text(72,445,'brew install yuemuqing-thu/tap/claude-usage-widget',27,ink,400,'font-family="Menlo,monospace"')+
  text(72,509,'claude-usage-widget install',27,ink,400,'font-family="Menlo,monospace"')+
  `<path d="M72 565H1008" stroke="#C7D2C4"/>`+
  text(72,634,'没有 Homebrew 也能装',28,ink,600)+text(72,686,'去仓库看直接安装方式，或让 Claude Code 帮忙。',26,'#55776B')+
  cat(815,761,4,'orange','sit','happy')+
  text(72,829,'GitHub 搜这个名字',25,'#55776B')+
  text(72,895,'yuemuqing-thu/',31,ink,600,'font-family="Menlo,monospace"')+
  text(72,941,'claude-usage-widget',31,ink,600,'font-family="Menlo,monospace"'));
console.log('已生成六张原比例、单层裁切的宣传 SVG。');

// README 在桌面浏览时以横向图为主，避免把方形轮播图放大成长页面。
// 英文版只翻译图中文字，实拍中的 UI 不作伪造式翻译。
for (const lang of ['zh','en']) {
  const zh=lang==='zh';
  let body=text(80,88,'CLAUDE USAGE',23,'#A7C6B6',600)+
    text(80,187,'Claude + Codex',42,mint,600)+
    text(76,291,zh?'用量放在桌面，':'Your AI usage.',zh?65:76,paper,650)+
    text(76,381,zh?'修猫也住桌面':'And a little cat.',zh?65:76,paper,650)+
    text(80,464,zh?'5 小时与 7 天额度 · 本地统计 · 像素猫':'Quota rings. Local stats. A desktop companion.',zh?26:25,'#B9D2C3')+
    text(80,511,zh?'免费开源，用本机已有的会话记录就能工作。':'Free and open source. Uses your local session data.',zh?25:23,'#B9D2C3')+
    `<path d="M80 574H714" stroke="${mint}" stroke-opacity=".25"/>`+
    text(80,631,zh?'小猫正在等你开工。':'A little company while you work.',26,mint,500)+
    cat(174,665,4,'orange','sit','happy')+cat(409,665,4,'black','loaf','shut')+
    card(867,57,410)+
    text(80,855,zh?'macOS / 中英切换 / 五种主题色':'macOS / Chinese & English / Five accent colours',20,'#A7C6B6')+
    text(1318,855,zh?'真实桌面截图 · 2026.09':'Desktop capture · Sep 2026',18,'#A7C6B6',400,'text-anchor="end"');
  const svg=`<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1440" height="900" viewBox="0 0 1440 900"><g font-family="PingFang SC,Helvetica Neue,sans-serif"><rect width="1440" height="900" fill="${dark}"/>${body}</g></svg>`;
  fs.writeFileSync(path.join(dir,`../readme-hero.${lang}.svg`),svg+'\n');
}
console.log('已生成中英两版 README 横向首图。');
