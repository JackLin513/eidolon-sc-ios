var mod=Process.getModuleByName('UnityFramework'), base=mod.base;
var seen={};
function e(n){try{return mod.getExportByName(n);}catch(x){return null;}}
var fDG=new NativeFunction(e('il2cpp_domain_get'),'pointer',[]);
var fDA=new NativeFunction(e('il2cpp_domain_get_assemblies'),'pointer',['pointer','pointer']);
var fAI=new NativeFunction(e('il2cpp_assembly_get_image'),'pointer',['pointer']);
var fCN=new NativeFunction(e('il2cpp_class_from_name'),'pointer',['pointer','pointer','pointer']);
var fCM=new NativeFunction(e('il2cpp_class_get_method_from_name'),'pointer',['pointer','pointer','int']);
var fRI=new NativeFunction(e('il2cpp_runtime_invoke'),'pointer',['pointer','pointer','pointer','pointer']);
var core=null,d=fDG(),cp=Memory.alloc(4),asms=fDA(d,cp),n=cp.readInt();
for(var i=0;i<n;i++){var m=fAI(asms.add(i*8).readPointer());
  try{if((m.readPointer().readUtf8String()||'').indexOf('UnityEngine.AssetBundleModule')>=0){core=m;break;}}catch(x){}}
if(core===null){ for(var i=0;i<n;i++){var m=fAI(asms.add(i*8).readPointer());
  try{if((m.readPointer().readUtf8String()||'').indexOf('UnityEngine.CoreModule')>=0){core=m;break;}}catch(x){} } }
var cAB=fCN(core,Memory.allocUtf8String('UnityEngine'),Memory.allocUtf8String('AssetBundle'));
var mLoad=fCM(cAB,Memory.allocUtf8String('LoadFromFile'),1);
if(mLoad===null) mLoad=fCM(cAB,Memory.allocUtf8String('LoadFromFile'),2);
function str(sp){ if(sp.isNull()) return ''; try{ var L=sp.add(0x10).readS32(); if(L<=0||L>300) return ''; return sp.add(0x14).readByteArray(L*2).readUtf16String(L);}catch(e){return '';} }
try{
  Interceptor.attach(mLoad,{ onEnter:function(a){ try{
    var s=str(a[0]);
    if(s && !seen[s]){ seen[s]=1; send({bundle:s}); }
  }catch(e){} }});
}catch(err){ send({err:String(err)}); }
setInterval(function(){ send({count:Object.keys(seen).length}); }, 5000);
