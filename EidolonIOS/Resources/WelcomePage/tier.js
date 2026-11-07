(function(){try{
var d=document.documentElement,T=["full","lite","basic","reduced","static"],R=[["saveData","static"],["noWebgl","static"],["reducedMotion","reduced"],["hoverNone","lite"]],L={"full":"motion","lite":"motion","basic":"motion","reduced":"still","static":"still"};
var P={
saveData:function(){var c=navigator.connection;return!!(c&&c.saveData)},
noWebgl:function(){var c=document.createElement('canvas'),g=c.getContext('webgl2')||c.getContext('webgl');if(g){var x=g.getExtension('WEBGL_lose_context');if(x)x.loseContext()}return!g},
reducedMotion:function(){return matchMedia('(prefers-reduced-motion: reduce)').matches},
hoverNone:function(){return matchMedia('(hover: none)').matches}};
var q=new URLSearchParams(location.search).get('tier'),t='full',why='default';
if(q&&T.indexOf(q)>=0){t=q;why='url'}else for(var i=0;i<R.length;i++){if(P[R[i][0]]()){t=R[i][1];why=R[i][0];break}}
d.dataset.lpTier=t;d.dataset.lpWhy=why;d.dataset.lpLayout=L[t];
}catch(e){}})();