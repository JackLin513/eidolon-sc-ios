# MLTD `CharacterMaterials.apply_color` 运行时覆盖的属性清单

> 目标：回答"`_Color` / `_IllumiColor` 在运行时是不是材质里那个 0.5"。
> 结论先行：**`_Color` 是，`_IllumiColor` 不是。**
> 对象：`jp.co.bandainamcoent.BNEI0310` 的 `UnityFramework`（用户自己的只读副本）。
> 工具链：沿用上一轮的 Il2CppDumper 产物（`/tmp/il2cpp-out`，`run.log` 显示 Metadata v31 / Il2Cpp v31，CodeRegistration `0x8E6BD80`、MetadataRegistration `0x90ECEF0`），本次用 `objdump` 逐函数反汇编 + 三个自写扫描器（§9）交叉验证；每个引用的 RVA 都重新反汇编核对过，和 `dump.cs` 的 RVA、`script.json` 的 `ScriptMethod` 地址一致。

---

## 0. TL;DR

1. `apply_color` 一共碰 **15 个**材质属性（14 写 + 1 读，表见 §2），其中和"整体颜色"有关的是：
   - `_DiffuseColor`（只有 Live 的 `idol_override_color` 生效时）
   - `matcol.cid` —— **不是固定 `_Color`**，而是材质上第一个存在的 `{_IllumiColor, _Color, _TintColor}`。
     16 个人物材质**全都有 `_IllumiColor`**（`research-mltd-shading-math.md:619-627`），所以实际写的是 **`_IllumiColor`**。
   - `_MonoColor` / `_Whiteness`（= `id_MonoColorRatio`）
2. **`_Color` 在整个游戏里没有一处 C# 写入**（全量 `bl` 扫描，§5）。它永远是材质序列化的 `0.502`。
3. **`_IllumiColor` 会被改写**，公式（非皮肤材质）：

   ```text
   _IllumiColor.rgb = authored(0.5) × tint.rgb × Color.gray(0.5) × 4.0
                    = 2 × tint.rgb
   ```

   `tint` 是"当前舞台色"：`this.idol_color.color`，或 `GlobalColorCtrl._theaterColor.value`；两者都不活跃且 `force_update` 时用 `Color.gray = (0.5,0.5,0.5)`（此时结果恰好等于原值，是"注册时空操作"）。
4. 皮肤材质（`MatCol.isSkin`）把上面的 `Color.gray(0.5)` 换成 `skinBias`（`calcSkinBias`，默认 0.5）：

   ```text
   _IllumiColor.rgb = 2 × tint.rgb × skinBias.rgb
   ```

   也就是说皮肤和头发**不是同一个系数**，`skinBias` 偏离 0.5 时皮肤会单独偏色。
5. 写 `_IllumiColor` 的块**不是无条件每帧跑**：`UpdateProperties` 每帧调 `apply_color(force=false)`，但颜色块被 `(idol_color 活跃 | force)` 门控；dirty 标记在**同一帧稍后**被清掉——`CharacterDrawer.LateUpdate` 在 `UpdateProperties` 之后用**尾调用**（`b`，不是 `bl`）进 `CharacterMaterials.UnsetDirty`（`0x1C188B8`），一次清掉 `idol_color`/`mono_color`/`rim_light`/`cheek_redden`/`spotlight` 等全部 dirty。所以：**每次 `SetIdolColor` / `SetTheaterColor` 之后的下一帧写一次，之后保持不变**。
6. `_Color` 在 C# 里**不是**"亮度/曝光"乘数，只是 `cids_idol` 的第二顺位 fallback 颜色槽；0.5 是"中性值"，由 shader 里的 ×2 补偿（§6）。

---

## 1. 调用链：谁、什么时候调 apply_color

| 事实 | 证据 |
|---|---|
| `apply_color` = RVA `0x1C21158`，下一个方法 `ApplyOutline` = `0x1C21F9C` | `dump.cs:491288`；`objdump` 反汇编 `0x1C21158-0x1C21F9C` |
| 每帧：`CharacterDrawer.LateUpdate` → `CharacterMaterials.UpdateProperties(deltaTime)` → `apply_color(force=false)` + `ApplyOutline()`，**同一条 LateUpdate 的末尾尾调用 `CharacterMaterials.UnsetDirty()`** | `bl 0x1c2308c` @ `0x1C1889C`（`CharacterDrawer.LateUpdate+0x64`）；`UpdateProperties` 内 `bl 0x1c21158` @ `0x1C232BC`（`mov w1,#0`）；`b 0x1c2341c` @ `0x1C188B8` |
| 注册时：`register_material` → `create_MatCol` → `chk_add_Outline` → `apply_on_awake` → **`apply_color(force=true)`** → `ApplyOutline` | `register_material` = `0x1C1D37C`（`dump.cs:491240`），`bl 0x1c21158` @ `0x1C1D4D4`（`mov w1,#1`） |
| 颜色块的 dirty 标记在帧末清掉：`CharacterManager.DrawManagerUpdate+0x544` → `GlobalColorCtrl.ClearDirtyToAllProperties`（把 `theaterColor.isDirty`@0xF8、`idol_light_vector.is_dirty`@0x10、`idol_override_color.is_dirty`@0x10 清零） | `0x1DD4AB8` 反汇编；`bl 0x1dd4ab8` @ `0x37859C0` |

`apply_color` 本身只清除 `idol_light_vector.is_dirty`（`strb wzr,[x25,#0x10]` @ `0x1C21434`）和 `idol_override_color.is_dirty`（@ `0x1C2163C`）。其余 dirty 由 `CharacterMaterials.UnsetDirty`（`0x1C2341C`，`dump.cs:491269`）清：

```asm
1c2341c  strb wzr,[x0,#0x160]   ; stencil_ref
1c23420  strb wzr,[x0,#0x144]   ; outline_color
1c23424  strb wzr,[x0,#0x7c]    ; rim_light
1c23428  strb wzr,[x0,#0x4c]    ; idol_color      ← 关键
1c2342c  strb wzr,[x0,#0x60]    ; mono_color
1c23430  strb wzr,[x0,#0xac]    ; spotlight_color
1c23434  strb wzr,[x0,#0xc4]    ; pinspotlight_color
1c23438  strb wzr,[x0,#0xa8]    ; cheek_redden_enable
1c2343c  strb wzr,[x0,#0x90]    ; cheek_redden
```

它的唯一调用点是 `CharacterDrawer.LateUpdate` 的尾分支（`b 0x1c2341c` @ `0x1C188B8`），所以在 `UpdateProperties`（消费 dirty）之后、同一帧结束前清零。**只扫 `bl` 会漏掉它**——本文件早期版本就踩过这个坑。

---

## 2. `apply_color` 写出的全部属性

循环体：`for (int i = matcols.Count-1; i >= 0; --i) { MatCol mc = matcols[i]; Material mat = mc.mat; Material mirror = mc.mirrorMat; ... }`
（`0x1C21640` 取 `matcols`(0x130) 的 `_size`，`0x1C21680` 递减，`0x1C216A4` `List.get_Item`，`0x1C216B0` `ldp x23,x25,[mc,#0x10]` → mat / mirrorMat）

| # | 属性（`Shader.PropertyToID` 实参） | API | 调用点 RVA | 值来源 | 触发条件 |
|---|---|---|---|---|---|
| 1 | `_IsReddish`（+ 关键字 `_ISREDDISH_ON`） | `CustomShaderUtility.SetMaterialToggle(mat, id, "_ISREDDISH_ON", flag)` | `0x1C21738` | `flag = this.cheek_redden_enable.is_enable (0xA9)` | `(mc.has_reddish \| force) && cheek_redden_enable.is_enable==1` |
| 2 | `_ReddishIntensity` | `Material.SetFloat` | `0x1C21784` | `this.cheek_redden.intensity (0xA4)` | 同上 |
| 3 | `_DiffuseColor` | `SetColor` | `0x1C2183C`（mat）/ `0x1C21898`（mirror） | `gcol.idol_override_color`：`is_enable ? color : (1,1,1,1)` | `(override.is_dirty \| force) && mat.HasProperty(_DiffuseColor)` |
| 4 | **`mc.cid`** = `{_IllumiColor, _Color, _TintColor}` 中第一个存在的 | `SetColor` | `0x1C2191C` | `mc.col × tint × (isSkin ? skinBias : Color.gray) × 4.0`（§3） | `(idol_color 会话活跃 \| force)` |
| 5 | `_IllumiColor`（**镜像材质**） | `SetColor` | `0x1C21978` | 同 #4 | 同 #4 且 `mirror != null` |
| 6 | `_Reflection` | `SetFloat` | `0x1C21A5C` | `lerp(coeffs[0], coeffs[1], saturate(dot(color, rgbLumi))) × mc.reflection(0x48)`；`coeffs = mc.is_span ? spaCoeffs(0x180) : refCoeffs(0x178)`，`rgbLumi` 是静态 `Vector4`(0xB0) | `mc.useReflect==1` |
| 7 | `_Light` | `SetVector` | `0x1C21AB0` | `gcol.idol_light_vector.direction`(0x14)；`from_left`(0x2C) 时 X 取反；相机可旋转时与 `rot90`(静态 0xC8) 相乘，否则乘 `Quaternion.identity` | `(idol_light.is_dirty \| force) && mc.hasLight`（0x41） |
| 8 | `_RimLight` | `SetVector` | `0x1C21AF4` | 同上，取 `directionRim`(0x20)；`rim_left_right_individual`(0x2D) 时 X 的符号改用 `this.rim_fromLeft`(0x188) | 同上且 `mc.hasRim`（0x42） |
| 9 | `_RimLightOn` | `SetInt` | `0x1C21B40` | `this.rim_light.is_enable (0x7D)` | `(rim_light.is_dirty \| force) && mc.hasRim` |
| 10 | `_RimColor` | `SetColor` | `0x1C21B70`（mat）/ `0x1C21BC4`（mirror） | `this.rim_light.color (0x80..0x8C)` | 同 #9 |
| 11 | `_MonoColor` | `SetColor` | `0x1C21CA4`（mat）/ `0x1C21CF8`（mirror） | `this.mono_color.color (0x64..0x70)` | `(mono_color.is_dirty \| force)` |
| 12 | `_Whiteness`（`id_MonoColorRatio`） | `SetFloat` | `0x1C21D64`（mat）/ `0x1C21DB4`（mirror） | `this.mono_color_ratio.ratio (0x78)` | `(mono_color_ratio.is_dirty \| force)` |
| 13 | `_WhiteMode` | **`GetInt`**（读） | `0x1C21E58` | 读回材质 → `mc.glow_property.white_mode (0x18)` | `mc.is_glow`（0x3E） |
| 14 | `_Luminance` | `SetFloat` | `0x1C21F04` | `this.glow_luminance (0x168) × VisualManager3d.instance.glowLuminanceAll (0x128)` | `is_glow && white_mode != 3` |
| 15 | `_ColorBlendRate` | `SetFloat` | `0x1C21F28` | `mc.glow_property.blend_rate (0x24)` | 同 #14 |

> 属性名 → id 的映射来自 `initStatic`（RVA `0x1C1FF70`，`dump.cs:491xxx`）：40 次 `Shader.PropertyToID`，`str w0,[static_fields,#off]` 与 `dump.cs:491000-491039` 的 `id_*` 偏移一一对应。注意两个反直觉的映射：
> - `id_StencilRef = "_Stencil"`（不是 `_StencilRef`）
> - **`id_MonoColorRatio = "_Whiteness"`**（`initStatic` @ `0x1C207F4` 取 `"_Whiteness"`，`0x1C20800` 存 `static+0x58`）
> - `id_ChrColors[i] = String.Format("_SubColor{0}", i)`（`0x1C203D4-0x1C20568`），但 **apply_color 不用它**，见 §3。

**apply_color 完全不碰**的属性：`_Color`、`_AmbientColor`、`_GlowColor`、`_WhityCol`、`_Whitish`、`_Freq`、`_IrisColor`、`_Irogae`、`_Outline*`、`_Stencil`、`_Yoffsets`、`_Colors`、`_BlendSrc`、`_TintColor`（除非它被选成 cid，见下）、`_RimCtrl`、`_GuradeParams`。

---

## 3. 颜色块逐步推导（`0x1C217A0` – `0x1C21988`）

### 3.1 cid 是怎么来的

`register_material`（`0x1C1D37C`）里：

```asm
1c1d488  mov  x1, x20            ; mat
1c1d48c  bl   0x1c222bc          ; CharacterMaterials.getColorID(mat)  -> x0
1c1d490  mov  x3, x0             ; cid
1c1d494..1c1d4a0 bl 0x1c223b0    ; create_MatCol(this, mat, mirror, cid)
```

`getColorID`（`0x1C222BC`，`dump.cs:491267`）：

```asm
1c222f0  ldr  x8,  [x0, #0xb8]    ; static_fields
1c222f4  ldr  x20, [x8, #0xa0]    ; cids_idol
1c2234c  ldr  w1,  [x22, x21, lsl #2]   ; for i in 0..len-1
1c22358  bl   0x707054c          ; Material.HasProperty(propId)
1c22394  ldr  w0,  [x22, x21, lsl #2]   ; return 命中的 propertyId（不是下标）
```

`cids_idol` 在 `initStatic` 里构造（`0x1C20630-0x1C206C8`）：

```asm
1c20630  ldr  x0,  [x19]          ; int[] 的元素类型
1c20634  mov  w1,  #3             ; new int[3]
1c20638  bl   0x84db3c
1c20654  ldr  w9,  [x0, #0x10]    ; static+0x10 = id_IllumiColor
1c20658  str  w9,  [x1, #0x20]    ; cids_idol[0]
1c20664  ldr  w9,  [x0, #0x18]    ; static+0x18 = id_Color
1c20668  str  w9,  [x1, #0x24]    ; cids_idol[1]
1c206bc  str  x1,  [x0, #0xa0]!   ; static_fields[0xA0] = cids_idol
1c206c0  ldur w8,  [x0, #-0x84]   ; static+0x1c = id_TintColor
1c206c4  str  w8,  [x1, #0x28]    ; cids_idol[2]
```

→ **`cids_idol = { _IllumiColor, _Color, _TintColor }`**。

`create_MatCol`（`0x1C223B0`）把 cid 存进 `MatCol.cid`(0x38)，并**一次性读回**基础色：

```asm
1c22488  str  w23, [x25, #0x20]   ; x25=x20+0x18 -> MatCol.cid  (+0x38)
1c2249c  mov  x1,  x23            ; nameID = cid
1c224a4  bl   0x7070048           ; Material.GetColor(nameID)
1c224a8  stp  s0,s1,[x20,#0x28]   ; MatCol.col = (r,g,b,a)
```

`Material.GetColor` 在整个二进制里只有 **2 个** 调用点：`CharacterMaterials.create_MatCol` 和 `GlobalColorSub.create_MatCol`（§5）。**`matcol.col` 之后再也不刷新。**

### 3.2 tint 的三种来源（`0x1C211D4` – `0x1C2139C`）

```asm
1c211d4  ldr x8,[x0,#0xb8] ; GlobalColorCtrl static_fields
1c211d8  ldr x22,[x8]      ; GlobalColorCtrl.gcol（静态单例）
1c211e0  bl  0x708fa5c     ; Color.gray -> (0.5,0.5,0.5,1)   ← 默认 tint
1c211e4  stp s1,s0,[sp,#0x28] ; str s2,[sp,#0x24]   ; 存到 sp+0x24..0x2c
...
1c21214  ldrb w9,[x20,#0x4d]   ; idol_color.is_enable
1c21218  tbnz w9,#0 → 1c21330
1c2121c  ldrb w9,[x22,#0xf8]   ; gcol._theaterColor.isDirty
1c21220  tbnz w9,#0 → 1c21358
1c21224  b    1c2134c

1c21330: ldrb w8,[x8]          ; idol_color.is_dirty (0x4C)
1c21334: cmp  w8,#1 ; b.ne → 1c213b8  (w23=0)
1c2133c: x8=&(this+0x50) x9=&(this+0x54) x10=&(this+0x58)   ; idol_color.color
1c21394: mov w23,#1            ; “有颜色”

1c2134c: ldrb w8,[x8]          ; idol_color.is_dirty
1c21350: cmp  w8,#1 ; b.ne → 1c213b8
1c21358: ... ldr x8,[x22,#0xfc] 等  ; gcol._theaterColor.value
1c21394: mov w23,#1
```

`Color.get_gray`（`0x708FA5C`）就是静态 `Color.gray`，4 条 `fmov` 直接返回 `0.5,0.5,0.5,1`（`dump.cs:1738581`）。

### 3.3 写入（`0x1C218C8` – `0x1C21978`）

```asm
1c2189c  ldr  w8,[sp,#0x34]      ; = w23 | force_update
1c218a0  cbnz w8, 0x1c218c8      ; 不满足就跳过颜色块
1c218c8  cbz  x23, ...           ; mat 空检查
1c218cc  ldp  s0,s1,[x24,#0x28]  ; mc.col.r, mc.col.g
1c218d0  ldp  s2,s15,[x24,#0x30]; mc.col.b, mc.col.a
1c218d4  ldp  s3,s4,[sp,#0x28]   ; tint.g, tint.r
1c218d8  fmul s0,s4,s0           ; col.r × tint.r
1c218dc  fmul s1,s3,s1           ; col.g × tint.g
1c218e0  ldr  s3,[sp,#0x24]      ; tint.b
1c218e4  fmul s2,s3,s2           ; col.b × tint.b
1c218e8  fmul s0,s12,s0          ; × (isSkin ? skinBias.r : Color.gray.r=0.5)
1c218ec  fmul s1,s13,s1
1c218f0  fmul s2,s14,s2
1c218f4  fmul s13,s0,s10         ; × 4.0     (s10 由 0x1C21678 fmov 载入)
1c218f8  fmul s14,s1,s10
1c218fc  fmul s12,s2,s10
1c21900  ldr  w1,[x24,#0x38]     ; nameID = MatCol.cid
1c2191c  bl   0x70700f4          ; Material.SetColor(mat, mc.cid, color, a 保持 mc.col.a)
1c2195c  ldr  w1,[x8,#0x10]      ; = id_IllumiColor（静态 +0x10）
1c21978  bl   0x70700f4          ; Material.SetColor(mirror, _IllumiColor, color)
```

（`s12/s13/s14` 的赋值：`0x1C216B8` 调 `Color.get_gray` → `0.5/0.5/0.5`；`0x1C21788` 若 `mc.isSkin(0x43)` 则改读 `this.skinBias(0x11C/0x120/0x124)`。）

**结论公式**（`C` = tint）：

```text
非皮肤 : mc.cid = 0.5 × C × 0.5 × 4.0 = C                    （每个通道）
皮肤   : mc.cid = 0.5 × C × skinBias × 4.0 = 2·C·skinBias
镜像   : _IllumiColor（镜像）= 同上（总是 _IllumiColor，不看 cid）
                                  alpha 用 mc.col.a（不参与乘法）
```

`skinBias`（`calcSkinBias`，`0x1C20914`，`dump.cs:491252`）：

```text
skinBias[c] = saturate(0.5 × lastSkinCol[c] / defaultLastSkin[c])   c = r,g,b
```

（`lastSkinCol` 0x10C、`defaultLastSkin` 0xFC；两者相等时 `skinBias = 0.5`，此时皮肤与非皮肤完全一致。）

### 3.4 "force 但无 dirty" 的情况

`force_update=1` 而 `w23=0` 时，颜色块仍然执行，`tint` 用的是入口处存的 `Color.gray(0.5,0.5,0.5)`，于是

```text
0.5 × 0.5 × 0.5 × 4.0 = 0.5  = 原值
```

也就是说 **注册时的 `apply_color(true)` 对颜色是恒等变换**——这正是 `Color.gray` 那个默认值的用途，也反证了"0.5 是中性值"这个设计约定。

---

## 4. 所以运行时到底等于多少？

| 材质 | `_Color` | `_IllumiColor` |
|---|---|---|
| 全部 16 个人物材质（有 `_IllumiColor`） | **0.502，从不被写** | `= tint`（非皮肤）/ `= 2·tint·skinBias`（皮肤） |
| 无 `_IllumiColor`、有 `_Color` 的材质（舞台物件等） | `= tint`（同上公式） | 不写 |
| 只有 `_TintColor` 的材质 | 不写 | 不写，`_TintColor = tint` |

代入两个典型场景：

- **舞台色 = 白 (1,1,1)** → `_IllumiColor = 1.0`（是材质里 0.5 的 **2 倍**）
- **舞台色 = 中灰 (0.5,0.5,0.5)**（`_theaterColor` / `idol_color.color` 的序列化默认值很可能就是它，因为材质本身也用 0.5 表示"中性"）→ `_IllumiColor = 0.5`，与材质一致
- **舞台色带色偏**（例如暖灯 `(1.0, 0.85, 0.83)`）→ `_IllumiColor` 就带同样的色偏，逐通道生效

`_Color` 在三种情况下都是 `0.502`。

---

## 5. 还有谁在写 `_Color` / `_IllumiColor` / `_AmbientColor` / `_DiffuseColor`

### 5.1 字符串字面量槽 → 引用者（全文本段 ADRP+ADD 扫描）

`Shader.PropertyToID` 的实参是 `Il2CppString*`，每个字面量在数据段有一个固定槽（`script.json` 的 `ScriptString`）。扫描 `__TEXT` 全部 32.8M 条指令里的 `adrp/add` 对（§9 命令 2），得到：

| 字面量 | 槽地址 | 引用它的函数（去掉 `initStatic` 里的 PropertyToID 与无关模块） |
|---|---|---|
| `_Color` | `0x98079A0` | `GlobalColorSub.<InitializeAsync>d__48.MoveNext`（0x3516EE4）、`Commu2.CommuModel.Awake`、`Commu2.CommuPostProcessColorCollection.Setup`、`Live.LEDScreen.initStatic`、`HutongGames.SetMaterialColor`、`Imas.VR.*`、`UnityEngine.Material.cctor` |
| `_IllumiColor` | `0x9807E08` | `GlobalColorSub.<InitializeAsync>d__48.MoveNext`、`Commu2.CommuModel.Awake` |
| `_AmbientColor` | `0x9807720` | **只有** `ModelLib.CharacterDrawerAO.copy_light_color_from_in_asset_material`（in-asset 配件材质） |
| `_DiffuseColor` | `0x9807AE0` | `GlobalColorSub.initStatic`、`CharacterMaterials.initStatic` |
| `_Whiteness` | `0x9808908` | `GlobalPropsOnLoad.resetGlobalProps`（全局置 0）、`PaintOutIdolEventCtrl` |

> 注：`Commu2.CommuModel.Awake` 也取 `_TintColor`/`_Color`/`_IllumiColor` 三个 id（`0x1D0B27C/0x1D0B294/0x1D0B2AC`），属于**交流模式（Commu）**的独立材质链；Live 演出不走它。

### 5.2 `Material.SetColor` 全量调用点（扫描 `bl 0x70700F4`）
```
CharacterMaterials.apply_color            x8   ← §2
CharacterMaterials.apply_on_awake         x1   (_ReddishColor)
CharacterMaterials.ApplyOutlineColor      x1   (_OutlineColor)
GlobalColorSub.ApplyColor                 x5   (_ChrColor / _ReddishColor / _DiffuseColor / matcol.cid / _RimColor)
其余：Commu2 / LEDScreen / FloorMesh / Bloom / Laser / PropertyCopier ……（Live 舞台特效与交流模式，与人物材质无关）
```

**结论：人物材质上写 `_Color` 的地方一处都没有。**
`_Color` 唯一可能的写入路径是 §2 的 #4——即"材质没有 `_IllumiColor` 但 有 `_Color`"，而 16 个人物材质全部有 `_IllumiColor`，这条路径走不到。

> **保留意见（数据驱动的写入者）**：`HutongGames.PlayMaker.Actions.SetMaterialColor`（`dump.cs:65729`，`DoSetMaterialColor` 在 `0x21D8900`）和 `Imas.PropertyCopier.LateUpdate` 都能按**场景里配置的属性名**写任意颜色属性（PlayMaker 的 `namedColor` 默认值是 `_Color`，还有 `everyFrame` 开关）。它们会不会作用到人物材质，取决于 Live 场景的 FSM 资产，二进制里看不出来。若后面发现 `_Color` 真的变了，先查这两个。

### 5.3 你点名的那些类，谁真的碰材质？

| 类/方法 | 是否直接写材质 | 证据 |
|---|---|---|
| `GlowProperty`（`dump.cs:490838`） | **否**。字段只有 `mat/white_mode/whitish/freq/blend_rate`；`CalcGlowBlendRate`（`0x1C23354`）和 `blink2blend`（`0x1C233EC`）只算并写自己的 `blend_rate`（`str s1,[x0,#0x24]`），材质写入全在 `apply_color` | 反汇编 2 个方法，无任何 `bl Material.*` |
| `SetMonoColor`（`0x1C1DAEC`）/ `SetMonoColorRatio`（`0x1C1DB00`）/ `SetRimLight`（`0x1C1DB10`） | **否**，纯字段 + 置 dirty：`mono_color.is_dirty=1, color=…` / `ratio.is_dirty=1, ratio=…` / `rim.is_dirty=1, is_enable=…, color=…` | 见下 |
| `CharacterMaterialController` | **类不存在**（`dump.cs` 全文检索无此类型；`*MaterialController` 也无） | `grep "MaterialController" dump.cs` → 空 |
| `MonoColor*` / `IllumiColor*` 的其它持有者 | C# 侧只有 `id_IllumiColor` 一个符号（`dump.cs:491006`）；`MonoColor` 是 `CharacterMaterials` 的嵌套结构体，只被 `apply_color` 读取 | 同上 |

```asm
1c1daec  mov  w8,#1 ; strb w8,[x0,#0x60] ; stp s0,s1,[x0,#0x64] ; stp s2,s3,[x0,#0x6c]   ; SetMonoColor
1c1db00  mov  w8,#1 ; strb w8,[x0,#0x74] ; str  s0,[x0,#0x78]                            ; SetMonoColorRatio
1c1db10  mov  w8,#1 ; strb w8,[x0,#0x7c] ; strb w1,[x0,#0x7d] ; stp/stp color [x0,#0x80]  ; SetRimLight
1c1dac4  strb w8,[x0,#0x4c] ; strb w1,[x0,#0x4d] ; stp color [x0,#0x50]                  ; SetIdolColor
```

### 5.4 `GlobalColorSub`：同一套逻辑的平行实现

`GlobalColorSub`（`dump.cs:278941`，`GlobalColorCtrl.SetupObj` 为每个对象创建）与 `CharacterMaterials` 同构：

- 它自己有一张静态 id 表（`dump.cs:278958-278977`，偏移**和 CharacterMaterials 不同**，别混用：`id_DiffuseColor` 是 0x38 而不是 0x50）。
- `cids_idol` 在 `InitializeAsync` 里**运行时**算出来，顺序同样是 `{_IllumiColor, _Color, _TintColor}`（`0x3516EDC/0x3516EF4/0x3516F0C` 三次 `PropertyToID`）。
- `GlobalColorSub.ApplyColor`（RVA `0x3515F88`，注意不是 `0x35166F8`——那是 `ApplyOutline`）写：
  - `SetColor(matcol.cid, matcol.col × tint × … × 4.0)`（`0x3516560`，`nameID = [matcol+0x28]`）
  - `SetColor(_DiffuseColor, gcol.diffuseColor)`（`0x3516524`，`[gcol+0x1B0..0x1BC]`）
  - `_ChrColor` / `_ReddishColor` / `_RimColor` / `_Light` / `_RimLight` / `_RimLightOn` / `_Stencil` / `_TanFov` / `_Outline` / `_OutlineZadj`
  - tint 取自 `gcol.idolColors[idolInx % 20]`（`[gcol+0x150]`）、`gcol.idolRimColors`/`idolRimFlags`，或 `gcol.theaterColor`（0xE8）；常量同样有 `fmov.2s v10, #4.0`（`0x35162B0`）。
- 调用者：`GlobalColorCtrl.ApplyColorReal+0xb4`（`0x1DD5AC8`）、`GlobalColorCtrl.appendMaterials`、`InitializeAsync`。

> 换句话说，**"整体色调"的实现方式不是一次性乘一个全局色，而是把每个材质自己的颜色槽（`_IllumiColor`/`_Color`/`_TintColor`）覆盖成 `2×舞台色`**，再由 shader 里的 `2×_IllumiColor` 乘回去。

---

## 6. `_Color` 在 C# 里是不是"亮度/曝光"乘数？

不是。证据链：

1. C# 只把 `id_Color` 用在两处：`initStatic` 的 `PropertyToID("_Color")`，和 `cids_idol[1]`（fallback 颜色槽）。没有任何乘法、没有和曝光/亮度相关的代码。
2. `create_MatCol` 用它 `GetColor` 一次，作为 `matcol.col`（基础色）；`apply_color` 把这个基础色乘上 tint 写回去。
3. shader 侧（`research-mltd-shading-math.md:256`）：`base = correction(_Color * _MainTex)`，即 `_Color` 是 **基础的 albedo 乘数**，不是曝光。
4. 所有材质都写 0.5 的真正原因：它是这套"×2 补偿"体系的中性值——shader 里 `col = 2*shade*base*(2*_IllumiColor)`，两处 2 倍正好把 0.5 抵消。`apply_color` 的 `×4 × 0.5(gray)` 是同一个约定在 C# 侧的镜像（§3.4 的恒等性就是最直接的证明）。

---

## 7. 其它会改变"整体观感"的运行时覆盖（供移植时取舍）

| 属性 | 谁写 | 值 | 备注 |
|---|---|---|---|
| `_IllumiColor` | `CharacterMaterials.apply_color` / `GlobalColorSub.ApplyColor` | §3 | **每材质**，由舞台色驱动 |
| `_DiffuseColor` | `apply_color`（`idol_override_color`）、`GlobalColorSub.ApplyColor`（`gcol.diffuseColor`） | 默认 `1,1,1` | shader: `shade = lerp(_AmbientColor, _DiffuseColor, ramp)`，所以它会**同时**影响亮部颜色 |
| `_MonoColor` / `_Whiteness` | `apply_color`（来自 `SetMonoColor`/`SetMonoColorRatio`） | 默认「材质值 / 0」 | shader: `col = lerp(col, _MonoColor, _Whiteness)`；`_Whiteness` 是**每材质**属性，全局那个只在 `resetGlobalProps` 里被置 0 |
| `_FadeColV` / `_TheaterColV` / `_FadeTheaterColV` | `GlobalPropsOnLoad.resetGlobalProps`（`0x3517DF8`，`Shader.SetGlobalVector` @ `0x3517EC4`/`0x3517EFC`/`0x3517F6C`）= `(1,1,1,1)`；`GlobalColorCtrl.LateUpdate` 改 | 换装/淡出过渡 | 最终 rgb 乘数 |
| `_Whiteness`(global) / `_FogMode` / `_IsLive` | `resetGlobalProps`：`SetGlobalFloat(_Whiteness,0)` @ `0x3517F78`、`SetGlobalInt(_FogMode,0)`、`SetGlobalInt(_IsLive,0)` | 0 | Live 启动后由 `MainLoop` 把 `_IsLive` 置 1 |
| `_RimCtrl` | `CharacterManager.RimTypeCtrl.SetRimEnv` / `resetGlobalProps (0,0,0,0)` | — | 上一轮已确认 |
| `_GuradeParams` | `CharGuradeCtrl.setGlobalVector` / `resetGlobalProps (0,1,0,1)` | — | 上一轮已确认 |
| `_Grayscale` / `_Graycolor` / `_RShift` / `_GShift` / `_BShift` | `GlobalColorCtrl.update_grayscale`（`0x1DD6048`）/ `update_colorShiftScale`（`0x1DD6214`） | `gcol.grayscale`(0x11C) / `graycolor`(0x120) / `colorShiftScale`×`redShift`… | **逐材质** `SetFloat`/`SetColor`/`SetVector`，只作用于 `GlobalColorSub` 管的材质（人物材质的 shader 不含这些属性，见 `research-mltd-shading-math.md:136` 的属性计数表） |
| `_Irogae` | `SetInherentColorToMaterial`（`0x1C1EA38`，`apply_on_awake` 里对 4 个 inherent color 各调一次、`SetInherentColor` 时再调） | 角色固有发色 | `SetColor(_Irogae, color)`，`HasProperty` 保护 |
| `_AmbientColor` | **只有** `CharacterDrawerAO.copy_light_color_from_in_asset_material` | 从 in-asset 材质拷过来 | 人物材质不写 |
| `_OutlineColor` | `ApplyOutlineColor` / `SetOutlineColor` | `this.outline_color` | shader 里还会 `× 2*_IllumiColor`（`research-mltd-shading-math.md:462`），**所以描边颜色也跟着舞台色变** |

---

## 8. 对"更饱和"这个偏差的意义 / 怎么验证

按 §3，移植端有两个容易漏的点：

1. **`_IllumiColor` 不是常量。** 你的公式 `col = 2*shade*base*(2*_IllumiColor)` 里，`2*_IllumiColor` 在游戏里等于 `2×舞台色`，不是一个固定的 1.0。如果参考画面的舞台色是白，这一项应该是 **2.0**（而不是你现在用的 1.0）；如果是中灰 0.5，才是 1.0。
2. **`_IllumiColor` 可能带色偏**，而且是逐通道的：
   - `theaterColor` / `idolColors[i]` 只要 R≠G≠B，`_IllumiColor` 就逐通道不同，shader 乘上去会让 G/B 单独升降——这正好能解释"G/B 各低 15–17%，R 不变，于是 sat 升高/降低"这种"非等比"偏差（等比缩放不会改变 HSV 的 S）。
   - 皮肤材质还额外乘 `skinBias`（`0.5×lastSkin/defaultLastSkin`，可偏离 0.5），所以**脸/身体的 `_IllumiColor` 与头发/衣服不是同一个系数**。
   - `_DiffuseColor` 在 Live 的 `idol_override_color` 生效时也会被替换（`shade` 的亮部），同样逐通道。
3. **`_Color` 可以确定按 0.502 处理**，这一项不是误差来源；`_AmbientColor`（头发 0.841/0.709/0.647）也不会被改写。

验证手段（都是只读的，不改游戏文件）：

- **静态**：`theaterColor`(GlobalColorCtrl 0xE8)、`idolColors`(0x150)、`diffuseColor`(0x1B0) 是场景/Prefab 上的序列化字段，不在二进制里——要拿到具体值得解析对应 Live 场景的 AssetBundle（`spikes/porting-3d` 已有 UnityFS 读取脚本），或者
- **运行时**（用户自己决定是否做）：在 `apply_color` 返回处下断点，读 `mat.GetColor(Shader.PropertyToID("_IllumiColor"))` 与 `_Color`。这是唯一能一锤定音的办法；本文只从代码给出"它会等于什么"。

---

## 9. 复现

```bash
BIN="/Users/jacklin/Library/Containers/io.playcover.PlayCover/Applications/jp.co.bandainamcoent.BNEI0310.app/Frameworks/UnityFramework.framework/UnityFramework"
META=".../Data/Managed/Metadata/global-metadata.dat"

# 1) 反汇编任意方法（本二进制 Offset == VA == RVA，直接按 dump.cs 的 RVA 取）
objdump -d --start-address=0x1C21158 --stop-address=0x1C21F9C "$BIN"
objdump -d --start-address=0x1C1FF70 --stop-address=0x1C2082C "$BIN"   # initStatic

# 2) 字面量槽 / 类型槽交叉引用（扫描 __TEXT 全部 adrp/add；TEXT_OFF=0x4000，TEXT_SIZE=0x7D09E38）
python3 /tmp/mltd-work/scan_slots.py

# 3) 所有 Material.* / Shader.SetGlobal* 调用点（扫描 BL）
python3 /tmp/mltd-work/scan_calls.py

# 4) initStatic 里 PropertyToID ↔ 静态字段偏移的对应
python3 /tmp/mltd-work/track.py /tmp/mltd-work/initStatic.asm
```

脚本与中间产物都在 `/tmp/mltd-work/`（`apply_color.ann.txt`、`initStatic.asm`、`create_MatCol.asm`、`GCS_ApplyColor.asm` …），Il2CppDumper 的输出沿用 `/tmp/il2cpp-out/`（`dump.cs`、`script.json`、`il2cpp.h`）。没有改动游戏文件，也没有碰 `SC_Info` / `appguard*`。

---

## 附录 A：`CharacterMaterials` 静态 id 表（`dump.cs:491000-491039`，`initStatic` RVA `0x1C1FF70`）

| 偏移 | 字段 | `PropertyToID` 实参 | 偏移 | 字段 | 实参 |
|---|---|---|---|---|---|
| 0x00 | id_Yoffsets | `_Yoffsets` | 0x50 | id_DiffuseColor | `_DiffuseColor` |
| 0x04 | id_Colors | `_Colors` | 0x54 | id_MonoColor | `_MonoColor` |
| 0x08 | id_BlendSrc | `_BlendSrc` | 0x58 | id_MonoColorRatio | **`_Whiteness`** |
| 0x0C | id_StencilRef | **`_Stencil`** | 0x5C | id_UseReflect | `_UseReflect` |
| 0x10 | id_IllumiColor | `_IllumiColor` | 0x60 | id_Reflection | `_Reflection` |
| 0x14 | id_GlowColor | `_GlowColor` | 0x64 | id_Outline | `_Outline` |
| 0x18 | id_Color | `_Color` | 0x68 | id_OutlineZadj | `_OutlineZadj` |
| 0x1C | id_TintColor | `_TintColor` | 0x6C | id_TanFov | `_TanFov` |
| 0x20 | id_Irogae | `_Irogae` | 0x70..0x7C | ZShift* | `_ZShift1000*` |
| 0x24 | id_Light | `_Light` | 0x80 | id_OutlineColor | `_OutlineColor` |
| 0x28 | id_RimLight | `_RimLight` | 0x84 | id_Luminance | `_Luminance` |
| 0x2C | id_RimLightOn | `_RimLightOn` | 0x88 | id_ColorBlendRate | `_ColorBlendRate` |
| 0x30 | id_RimColor | `_RimColor` | 0x8C | id_WhiteMode | `_WhiteMode` |
| 0x38 | id_ChrColors | `int[]{ "_SubColor0..3" }`（数组，apply_color 不用） | 0x90 | id_Whitish | `_Whitish` |
| 0x40 | id_IrisColor | `_IrisColor` | 0x94 | id_Freq | `_Freq` |
| 0x44 | id_IsReddish | `_IsReddish` | 0x98 | id_ForceNoSkin | `_ForceNoSkin` |
| 0x48 | id_ReddishColor | `_ReddishColor` | 0xA0 | cids_idol | `{_IllumiColor,_Color,_TintColor}` |
| 0x4C | id_ReddishIntensity | `_ReddishIntensity` | 0xB0 | rgbLumi | `Vector4`（反射点积权重） |

## 附录 B：`MatCol` 字段偏移（`dump.cs:490724`）

```text
0x10 mat  0x18 mirrorMat  0x20 glow_property  0x28 col(Color)
0x38 cid  0x3C has_inherent_color 0x3D is_outline 0x3E is_glow 0x3F is_span
0x40 has_reddish 0x41 hasLight 0x42 hasRim 0x43 isSkin 0x44 isFace
0x45 useReflect 0x48 reflection
```

`GlowProperty`（`dump.cs:490838`）：`0x10 mat  0x18 white_mode  0x1C whitish  0x20 freq  0x24 blend_rate`
`GlowProperty.CalcGlowBlendRate`（`0x1C23354`）与 `blink2blend`（`0x1C233EC`）就是把 `whitish/freq` 算成 `blend_rate`：

```text
white_mode ∈ {0,3} → blend_rate = 0
white_mode == 1    → blend_rate = whitish × (1 - frac(t·freq))
否则（TRIANGLE）   → blend_rate = whitish × tri(t·freq)   （2 周期三角波，ss003 即此）
blink2blend(r)     → blend_rate = whitish × (1 - saturate(r))
```

## 附录 C：本文件引用到的 RVA 一览

| 符号 | RVA | 出处 |
|---|---|---|
| `CharacterMaterials.apply_color` | `0x1C21158` | `dump.cs:491288` |
| `CharacterMaterials.ApplyOutline` | `0x1C21F9C` | `dump.cs:491291` |
| `CharacterMaterials.apply_on_awake` | `0x1C20DD8` | `dump.cs:491282` |
| `CharacterMaterials.UpdateProperties` | `0x1C2308C` | `dump.cs:491255` |
| `CharacterMaterials.GetGlowPropertyFromMaterial_` | `0x1C1E568` | `dump.cs:491287` |
| `CharacterMaterials.initStatic` | `0x1C1FF70` | `dump.cs:491228` |
| `CharacterMaterials.getColorID` | `0x1C222BC` | `dump.cs:491267` |
| `CharacterMaterials.create_MatCol` | `0x1C223B0` | `dump.cs:491264` |
| `CharacterMaterials.register_material` | `0x1C1D37C` | `dump.cs:491240` |
| `CharacterMaterials.calcSkinBias` | `0x1C20914` | `dump.cs:491252` |
| `CharacterMaterials.UnsetDirty` | `0x1C2341C` | `dump.cs:491269` |
| `CharacterMaterials.SetIdolColor` | `0x1C1DAC0` | `dump.cs:491117` |
| `CharacterMaterials.SetInherentColorToMaterial` | `0x1C1EA38` | `dump.cs:491198` |
| `GlowProperty.CalcGlowBlendRate` / `blink2blend` | `0x1C23354` / `0x1C233EC` | `dump.cs:490859/490862` |
| `CharacterDrawer.LateUpdate`（调 UpdateProperties） | `bl` @ `0x1C1889C` | — |
| `GlobalColorCtrl.SetTheaterColor` | `0x1DD4AE8` | `dump.cs:524590` |
| `GlobalColorCtrl.ClearDirtyToAllProperties` | `0x1DD4AB8` | — （`bl` @ `0x37859C0`） |
| `GlobalColorCtrl.ApplyColorReal` | `0x1DD5A14` | `dump.cs:524650` |
| `GlobalColorCtrl.update_grayscale` / `update_colorShiftScale` | `0x1DD6048` / `0x1DD6214` | `dump.cs:524635/524638` |
| `GlobalColorSub.ApplyColor` | `0x3515F88` | `dump.cs:279029` |
| `GlobalColorSub.<InitializeAsync>d__48.MoveNext` | `0x3516CE8` | — |
| `GlobalPropsOnLoad.resetGlobalProps` | `0x3517DF8` | `dump.cs:358758` |
| `UnityEngine.Color.get_gray`（静态 `Color.gray`） | `0x708FA5C` | `dump.cs:1738581` |
| `UnityEngine.Material.SetColor` / `SetFloat` / `SetVector` / `SetInt` / `GetColor` / `HasProperty` | `0x70700F4` / `0x70739FC` / `0x7073AFC` / `0x70739B4` / `0x7070048` / `0x707054C` | `script.json` |
| `Shader.PropertyToID` | `0x706A2C0` | `script.json` |
