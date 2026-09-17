// 挂件渲染测试台。跑之前先 sh install.sh 让 Übersicht 编译出 bundle。
//   node test/render-test.js
// 没有参数时自己去 Übersicht 取 bundle。
const fs=require("fs"),vm=require("vm"),cp=require("child_process");
const BUNDLE=process.argv[2]||(()=>{const p="/tmp/cuw-bundle.js";
  cp.execSync(`curl -s http://127.0.0.1:41416/widgets/claude-usage-widget-index-jsx -o ${p}`);return p;})();
const store={};
const nodes=[];
function html(tag,props,...kids){
  const n={tag,props:props||{},kids:kids.flat(Infinity).filter(x=>x!=null)};
  nodes.push(n);
  if(typeof tag==='function'){ try{ return tag(Object.assign({},props,{children:n.kids})); }catch(e){ return n; } }
  return n;
}
const req=(n)=>{ if(n==='uebersicht') return {run:async()=>''}; throw new Error('no mod '+n); };
const ctx={console,html,require:req,setTimeout:(f)=>{},clearTimeout(){},Date,Math,JSON,String,Number,Boolean,Array,Object,parseInt,parseFloat,isNaN,
  window:{localStorage:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v},addEventListener(){},matchMedia:()=>({matches:false})},
  document:{getElementById:()=>null,createElement:()=>({style:{},appendChild(){},setAttribute(){}}),head:{appendChild(){}},body:{appendChild(){}},addEventListener(){}},
  navigator:{language:'zh-CN'},localStorage:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v},
  module:{exports:{}},exports:{}};
ctx.globalThis=ctx; ctx.self=ctx.window;
vm.createContext(ctx);
try{ vm.runInContext(fs.readFileSync(BUNDLE,'utf8'),ctx,{timeout:10000}); }catch(e){ console.log('BUNDLE ERROR',e.message); process.exit(1); }
const M=ctx.require('claude-usage-widget-index-jsx');
function flat(n,out){ if(!n||typeof n!=='object')return out; if(n.tag)out.push(n);
  (n.kids||[]).forEach(k=>flat(k,out)); return out; }
function txt(n,acc){ acc=acc||[]; if(typeof n==='string'){acc.push(n);return acc;}
  if(n&&n.kids)n.kids.forEach(k=>txt(k,acc)); return acc; }
function cls(tree){ return flat(tree,[]).map(n=>(n.props&&n.props.className)||'').join(' '); }

const codexSrc={ok:true,limits:{snapshot_at:1,age:60,five:{pct:67.5,resets_at:9,in:900},seven:{pct:14.25,resets_at:9,in:9000}},days:[],today:{cost:0,tok:0},days14:{cost:0,tok:0},models:[]};
const claudeSrc={ok:true,limits:{snapshot_at:1,age:60,five:{pct:30,resets_at:9,in:900},seven:{pct:10,resets_at:9,in:9000}},days:[],today:{cost:0,tok:0},days14:{cost:0,tok:0},models:[]};
const cases=[
 ['两家都有',   {ok:true,gen:1,hasClaude:true, hasCodex:true, sources:{claude:claudeSrc,codex:codexSrc}}],
 ['只有 Claude',{ok:true,gen:1,hasClaude:true, hasCodex:false,sources:{claude:claudeSrc,codex:null}}],
 ['只有 Codex', {ok:true,gen:1,hasClaude:false,hasCodex:true, sources:{claude:{ok:true,limits:{},days:[],today:{},days14:{},models:[]},codex:codexSrc}}],
 ['两家都没有', {ok:true,gen:1,hasClaude:false,hasCodex:false,sources:{claude:{ok:true,limits:{},days:[],today:{},days14:{},models:[]},codex:null}}],
 ['老格式(无 hasClaude)',{ok:true,gen:1,hasCodex:false,sources:{claude:claudeSrc,codex:null}}],
];
for(const [name,payload] of cases){
  nodes.length=0;
  let tree; try{ tree=M.render({output:JSON.stringify(payload)}); }catch(e){ console.log(`  ${name.padEnd(22)} ★ 渲染抛错 ${e.message}`); continue; }
  const c=cls(tree), all=flat(tree,[]);
  const t=txt(tree).join('|');
  const tabs=/srcTabs/.test(c), solo=(c.match(/v-solo/g)||[]).length,
        vc=/v-claude/.test(c), vx=/v-codex/.test(c);
  const title=/Codex Usage/.test(t)?'Codex Usage':(/Claude Usage/.test(t)?'Claude Usage':(/没找到/.test(t)?'(无数据源提示)':'?'));
  const pcts=[...new Set(nodes.filter(n=>n.props&&typeof n.props.pct==='number').map(n=>n.props.pct))].sort((a,b)=>a-b);
  console.log(`  ${name.padEnd(22)} 环里的百分比=[${pcts}]  页签=${tabs?'有':'无'}  v-solo=${solo}  v-claude=${vc?'有':'无'} v-codex=${vx?'有':'无'}  标题=${title}  节点=${all.length}`);
}
