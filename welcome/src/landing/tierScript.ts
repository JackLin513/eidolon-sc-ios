import { layoutOf, TIER_RULES, TIERS } from "./model/tier";

/**
 * 首屏前定档的内联脚本（原型 page.tsx 的 TIER_SCRIPT）：在 <head> 里同步运行，页面画出来之前就把
 * 档位写到 <html> 上（data-lp-tier、data-lp-layout），样式表据此选静止还是运动版式、要不要画布，
 * 首屏不会先按一种版式画出来再跳成另一种。
 *
 * 规则来自落地页模型（tier.ts 的 TIER_RULES，和 initialTier 同一张表），这里只负责逐条探测信号：
 * 探到一条成立就停，所以省流量时不会去建 WebGL 上下文；探测用的上下文当场释放。
 * URL 的 `?tier=` 可以指定档位，给验收和人工检查用。没有 JS 时 <html> 上没有档位，样式表按静态档画。
 */
export const TIER_SCRIPT = `(function(){try{
var d=document.documentElement,T=${JSON.stringify(TIERS)},R=${JSON.stringify(TIER_RULES)},L=${JSON.stringify(Object.fromEntries(TIERS.map((t) => [t, layoutOf(t)])))};
var P={
saveData:function(){var c=navigator.connection;return!!(c&&c.saveData)},
noWebgl:function(){var c=document.createElement('canvas'),g=c.getContext('webgl2')||c.getContext('webgl');if(g){var x=g.getExtension('WEBGL_lose_context');if(x)x.loseContext()}return!g},
reducedMotion:function(){return matchMedia('(prefers-reduced-motion: reduce)').matches},
hoverNone:function(){return matchMedia('(hover: none)').matches}};
var q=new URLSearchParams(location.search).get('tier'),t='full',why='default';
if(q&&T.indexOf(q)>=0){t=q;why='url'}else for(var i=0;i<R.length;i++){if(P[R[i][0]]()){t=R[i][1];why=R[i][0];break}}
d.dataset.lpTier=t;d.dataset.lpWhy=why;d.dataset.lpLayout=L[t];
}catch(e){}})();`;
