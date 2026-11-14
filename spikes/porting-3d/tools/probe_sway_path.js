// Which sway implementation does the running MLTD actually solve with?
// Attach during an MV / live (a character must be loaded) and watch the counters.
//   工具：frida -n ProductName -l probe_sway_path.js   (已给 launcher 加 get-task-allow)
// RVAs come from build/mltd-spike/out/il2cpp/dump.cs of the same 9.0.350 build.
var mod = Process.getModuleByName('UnityFramework'), base = mod.base;
var c = {};
[
  ['V01_PrepareUpdate',      0x1C81A08],  // Imas.BoneLib.SwayManager (swayBones@0x50)
  ['V01_ExecuteUpdate',      0x1C81CD8],
  ['V01_PostUpdate',         0x1C81E40],
  ['MT_SwayBone_CalcRotate', 0x1C69F04],  // SwayBoneMT path (TransformAccess jobs)
  ['MT_SwayBone_SwayMove',   0x1C6867C],
  ['MT_SwayBone_FinishRotate', 0x1C720E0],
  ['MT_CalcSideLineDistance', 0x1C736B8],
  ['MT_CalcAntiFoldForce',   0x1C738A8],
  ['Mgr_ExecuteParallelSwayIdols', 0x1C6CBD4], // SwayCtrlAllMT: global parallel driver
  ['Ctrl_InitializeParallelSway',  0x1C6FC28],
  ['Ctrl_ExecuteParallelSway',     0x1C70038],
  ['V02_Execute',            0x1C8EE48],  // Imas.BoneLib.SwayVer02 (chain system)
  ['V02_ExecuteChains',      0x1C8FBBC],
  ['V02_CalcFollowMatrix',   0x1C8FAD8],
  ['V02_CalcRestoration',    0x1C8C4EC],
  ['V02_CalcAngleLimitPenetrative', 0x1C91714]
].forEach(function (p) {
  c[p[0]] = 0;
  try { Interceptor.attach(base.add(p[1]), { onEnter: function () { c[p[0]]++; } }); }
  catch (e) { c[p[0]] = 'ERR'; }
});
setInterval(function () { send(c); }, 2000);
