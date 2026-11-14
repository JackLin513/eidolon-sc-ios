var mod=Process.getModuleByName('UnityFramework'), base=mod.base;
function e(n){try{return mod.getExportByName(n);}catch(x){return null;}}
var fDG=new NativeFunction(e('il2cpp_domain_get'),'pointer',[]);
var fDA=new NativeFunction(e('il2cpp_domain_get_assemblies'),'pointer',['pointer','pointer']);
var fAI=new NativeFunction(e('il2cpp_assembly_get_image'),'pointer',['pointer']);
var fCN=new NativeFunction(e('il2cpp_class_from_name'),'pointer',['pointer','pointer','pointer']);
var fCM=new NativeFunction(e('il2cpp_class_get_method_from_name'),'pointer',['pointer','pointer','int']);
var fRI=new NativeFunction(e('il2cpp_runtime_invoke'),'pointer',['pointer','pointer','pointer','pointer']);
var core=null,d=fDG(),cp=Memory.alloc(4),asms=fDA(d,cp),n=cp.readInt();
for(var i=0;i<n;i++){var m=fAI(asms.add(i*8).readPointer());
  try{if((m.readPointer().readUtf8String()||'').indexOf('UnityEngine.CoreModule')>=0){core=m;break;}}catch(x){}}
var cTf=fCN(core,Memory.allocUtf8String('UnityEngine'),Memory.allocUtf8String('Transform'));
var mChildCount=fCM(cTf,Memory.allocUtf8String('get_childCount'),0);
var mGetChild=fCM(cTf,Memory.allocUtf8String('GetChild'),1);
var mLocalRot=fCM(cTf,Memory.allocUtf8String('get_localRotation'),0);
var mParent=fCM(cTf,Memory.allocUtf8String('get_parent'),0);
function call0(m,o){try{return fRI(m,o,ptr(0),ptr(0));}catch(e){return ptr(0);}}
function callI(m,o,i){try{var args=Memory.alloc(8); args.writeInt(i); return fRI(m,o,args,ptr(0));}catch(e){return ptr(0);}}
function q4(sp){return sp.isNull()?null:[+sp.add(0x10).readFloat().toFixed(5),+sp.add(0x14).readFloat().toFixed(5),+sp.add(0x18).readFloat().toFixed(5),+sp.add(0x1C).readFloat().toFixed(5)];}
function walk(node, out, depth){
  if(depth>6||out.length>400) return;
  out.push(q4(call0(mLocalRot,node)));
  var cc=call0(mChildCount,node).toInt32();
  for(var i=0;i<cc;i++){ var ch=callI(mGetChild,node,i); if(!ch.isNull()) walk(ch,out,depth+1); }
}
var mgr=null, t=-1;
try{Interceptor.attach(base.add(0x37EDF1C),{onEnter:function(a){try{t=a[0].add(0x44).readFloat();}catch(e){}}});}catch(e){}
try{Interceptor.attach(base.add(0x1C817F0),{onEnter:function(a){ if(mgr===null){ try{ var arr=a[0].add(0x50).readPointer();
  if(!arr.isNull()&&arr.add(0x18).readS32()===20) mgr=a[0]; }catch(e){} } }});}catch(e){}
setInterval(function(){
  if(mgr===null||t<0) return;
  try{
    var baseTr=mgr.add(0x70).readPointer();
    var root=baseTr; for(var i=0;i<8;i++){ var p=call0(mParent,root); if(p.isNull()) break; root=p; }
    var out=[]; walk(root,out,0);
    send({t:+t.toFixed(2), n:out.length, q:out});
  }catch(e){}
}, 100);
