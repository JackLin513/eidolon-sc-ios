using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Native-faithful replica of the game's <c>Imas.FaceCtrl</c> (dump.cs
/// TypeDefIndex 9605) plus the five <see cref="TransitionModuleNative"/>
/// cross-fades it owns.  This is the B3 replacement for the approximate
/// <c>FaceCtrl.cs</c> spike component; see ADR-0033: only performance-layer
/// substitutions are allowed, no formula/constant/default/branch may change.
///
/// Source of truth: decompiled <c>UnityFramework</c> 2026-10, all RVAs 1:1 with
/// <c>dump.cs</c> (and with <c>ida-decomp/FaceCtrl__*.c</c>):
/// <list type="bullet">
/// <item><c>.ctor</c> @0x379DC1C — buffers, five TransitionModules, face renderer
/// (<c>GameObject.Find(objname + "/obj_head_GP/face")</c> → <c>SkinnedMeshRenderer</c>),
/// shader property ids</item>
/// <item><c>BlendParamLoad</c> @0x379E080 + iterator <c>BlendParamLoadStep</c>
/// @0x37A0D98 — JSON → <c>FaceBlendParam[]</c></item>
/// <item><c>Init</c> @0x379E5B8, <c>Init2</c> @0x379E8A4 — select the character's
/// expression row, seed the buffers from <c>expressions[0]</c>, force eye open /
/// cheek off</item>
/// <item><c>ConvLip</c> @0x379F3A4, <c>SetLip</c> @0x379F46C,
/// <c>SetLipDirect</c> @0x379F53C, <c>SetSinging</c> @0x379F3FC</item>
/// <item><c>SetFace</c> @0x379F5F0, <c>SetFaceDirect</c> @0x379F674</item>
/// <item><c>SetEyeClose</c> @0x379E858, <c>SetEyeCloseDirect</c> @0x379F6EC,
/// <c>GetEyeBuff</c> @0x379F718, <c>GetCurrentEyeClose</c> @0x379F744</item>
/// <item><c>SetCheek</c> @0x379E810, <c>SetCheekDirect</c> @0x379F768,
/// <c>CheekUpdate</c> @0x379F790, <c>GetCheekValue</c> @0x379F818,
/// <c>SetCheekValue</c> @0x379F840, <c>GetCurrentCheekLV</c> @0x379FA2C</item>
/// <item><c>UpdateFace</c> @0x379E94C — the five-buffer composition and the 32
/// blend-shape writes</item>
/// <item><c>Action</c> @0x379FA48 — per-frame: advance the five modules,
/// <c>UpdateFace</c>, then the cheek cross-fade</item>
/// <item><c>cctor</c> @0x379FD10 — <c>lipChar[60]</c> and <c>facialMenu[28]</c>
/// (resolved below)</item>
/// </list>
///
/// Buffer semantics recovered from @0x379E94C (verified against the mixed
/// mouth/eye write indices in the disassembly: eye writes are
/// <c>SetBlendShapeWeight(i + 14, v)</c>, mouth writes are
/// <c>SetBlendShapeWeight(i, v)</c>):
/// <code>
///   mouthCloseBuff[14] ← expressions[cur].param32close[0..13]   (facial fade)
///   eyeOpenBuff[19]    ← expressions[cur].param32open[14..32]   (facial fade)
///   eyeCloseBuff[19]   ← expressions[cur].param32close[14..32]  (facial fade)
///   facialMouthBuff[14]← mouthCloseBuff  or  lipParam[muteLip-1] (mute-lip fade)
///   render BS 0..13    ← lipParam[lip] or facialMouthBuff        (lip fade)
///   render BS 14..31   ← eyeOpen/eyeCloseBuff                   (blink fade)
///   BS 32 is not a mesh channel; the facial fade uses it as the
///   EyeTracking scale: 1 / (param32open-or-close[32] * 0.01).
/// </code>
/// <c>mouthOpenBuff</c> is written by <c>Init</c> but never read by
/// <c>UpdateFace</c> (observed; kept for layout fidelity).
///
/// Data gaps (ADR-0033 §5 — code complete, empty resource runs):
/// * <c>lipParam</c> (<c>float[11,14]</c>, native field @0x10) is a compiler
///   array-initializer blob in global-metadata (<c>RuntimeHelpers.InitializeArray</c>);
///   it is not in the asset snapshot.  It is allocated as zeros here and can be
///   filled with <see cref="LoadLipParam"/> — see the notes file.
/// * Expression weights themselves come from <c>facial_chara.json</c> (asset
///   export), the same table <c>SetFace</c>/<c>UpdateFace</c> consume.
/// </summary>
[DisallowMultipleComponent]
public sealed class FaceCtrlNative : MonoBehaviour
{
    // =====================================================================
    // Native serializable types (Imas.MeshBlendParam / Imas.FaceBlendParam)
    // =====================================================================

    /// <summary>`Imas.MeshBlendParam` (TypeDefIndex 9600): two 33-wide weight
    /// vectors, eyes-open and eyes-closed.</summary>
    [Serializable]
    public sealed class MeshBlendParam
    {
        public float[] param32open;   // 0x10
        public float[] param32close;  // 0x18
    }

    /// <summary>`Imas.FaceBlendParam` (TypeDefIndex 9601): one character's
    /// expression rows, keyed by <c>cid</c> ("001har").</summary>
    [Serializable]
    public sealed class FaceBlendParam
    {
        public string cid;                    // 0x10
        public MeshBlendParam[] expressions;  // 0x18
    }

    /// <summary>
    /// Native `BlendParamLoad` JSON schema, recovered by resolving the
    /// dictionary-key string literals in `BlendParamLoadStep.MoveNext`
    /// (@0x37A0D98): keys are <c>"id"</c>, <c>"face"</c>, <c>"index"</c>,
    /// <c>"open"</c>, <c>"close"</c> (metadata usage slots 0x9816D68,
    /// 0x9813D40, 0x9818F20, 0x98201E8, 0x980D0B8 → string literals). Values
    /// arrive as JSON numbers and go through ToString→Single.Parse in the
    /// native loader; "index" is Int32.Parse and is 1-based into the 28-entry
    /// expression array.
    /// </summary>
    [Serializable]
    private sealed class NativeFaceBlendParam
    {
        public string id;
        public NativeMeshBlendParam[] face;
    }

    [Serializable]
    private sealed class NativeMeshBlendParam
    {
        public int index;
        public float[] open;
        public float[] close;
    }

    // JsonUtility cannot read a top-level array; wrap it natively-compatibly.
    [Serializable]
    private sealed class FaceBlendParamList
    {
        public List<FaceBlendParam> items;
    }

    [Serializable]
    private sealed class NativeFaceBlendParamList
    {
        public List<NativeFaceBlendParam> items;
    }

    // =====================================================================
    // Native enums (FaceCtrl.EyeState / FaceCtrl.CheekState)
    // =====================================================================

    /// <summary>`FaceCtrl.EyeState` (TypeDefIndex 9602).</summary>
    public enum EyeState
    {
        Close = 0,
        Open = 1,
    }

    /// <summary>`FaceCtrl.CheekState` (TypeDefIndex 9603).</summary>
    public enum CheekState
    {
        OFF = 0,
        Weak = 1,
        Strong = 2,
    }

    // =====================================================================
    // Native constants
    // =====================================================================

    public const float eyeBlinkTime = 0.1f;          // FaceCtrl.eyeBlinkTime
    public const float cheekTransTime = 0.1f;        // FaceCtrl.cheekTransTime
    public const float lipTransitionTime = 0.2f;     // FaceCtrl.lipTransitionTime
    public const float faceTransitionTime = 0.13333334f; // FaceCtrl.faceTransitionTime
    public const int mouthShapes = 14;               // FaceCtrl.mouthShapes
    public const int eyeShapes = 18;                 // FaceCtrl.eyeShapes
    public const int expressionCount = 28;           // FaceBlendParam..ctor @0x379DAA4
    public const int paramCount = 33;                // MeshBlendParam..ctor @0x379DA18
    public const int lipKinds = 11;                  // lipParam.GetLength(0)
    public const int lipParamColumns = 14;           // lipParam.GetLength(1)

    /// <summary>
    /// Shader keyword passed to `CustomShaderUtility.SetMaterialToggle` from
    /// `SetCheekValue` @0x379F840.  The string literal itself is a chained-fixup
    /// slot; the same literal is present in the head bundle's face shader
    /// (`_ISREDDISH_ON`, next to `_ISBIHAKU_ON`), which is the same property —
    /// see notes.  Property ids are resolved from metadata:
    /// `_IsReddish` and `_ReddishIntensity`.
    /// </summary>
    public const string ReddishKeyword = "_ISREDDISH_ON";

    /// <summary>
    /// `FaceCtrl.lipChar[60]` (@0x379FD10).  Recovered from the cctor's
    /// RuntimeHelpers array-init assignments + global-metadata string-literal
    /// table (see notes); 8 slots are null in the native array (36, 38, 46, 47,
    /// 48, 51, 52, 53) and are null here too.
    /// </summary>
    public static readonly string[] lipChar =
    {
        "ア", "イ", "ウ", "エ", "オ", "カ", "キ", "ク", "ケ", "コ",
        "サ", "シ", "ス", "セ", "ソ", "タ", "チ", "ツ", "テ", "ト",
        "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "ヒ", "フ", "ヘ", "ホ",
        "マ", "ミ", "ム", "メ", "モ", "ヤ", null, "ユ", null, "ヨ",
        "ラ", "リ", "ル", "レ", "ロ", "ワ", null, null, null, "ヲ",
        "ン", null, null, null, "＿", "ァ", "ィ", "ゥ", "ェ", "ォ",
    };

    /// <summary>
    /// `FaceCtrl.facialMenu[28]` (@0x379FD10): display names for the 28
    /// expression indices, in <c>expressions[]</c> order.  Recovered the same
    /// way as <see cref="lipChar"/>.
    /// </summary>
    public static readonly string[] facialMenu =
    {
        "通常", "明るい", "興味", "安堵", "照れる", "微笑み", "泣き笑い",
        "困り笑い", "真剣", "不敵な笑い", "企み", "考える", "きょとん",
        "驚き", "超驚き", "呆れ", "不機嫌", "怒り", "不安", "哀しみ",
        "泣き", "痛い", "拗ねる", "嫌そう", "つまらない", "がっかり",
        "右ウィンク", "左ウィンク",
    };

    // =====================================================================
    // Native hooks for systems that are out of B3 scope
    // =====================================================================

    /// <summary>
    /// `CharacterDrawer.SetCheekReddenEnable(bool)` @0x1C103FC /
    /// `SetCheekReddenIntensity(float)` @0x1C10418.  Achieved by
    /// `FaceCtrl.SetCharacterDrawer` @0x379FD08; native also relays to
    /// `CharacterMaterials` internals, which is B5's job.
    /// </summary>
    public interface ICharacterDrawerSink
    {
        void SetCheekReddenEnable(bool enable);

        void SetCheekReddenIntensity(float intensity);
    }

    /// <summary>
    /// The one cross-system write `FaceCtrl.UpdateFace` performs:
    /// `info.model.EyeTarget.scale = ...` (@0x379E94C), i.e.
    /// `JointBodyHead.EyeTarget` is an `EyeTracking` whose `scale` field is
    /// written.  B4 owns `EyeTrackingNative`; wire it here.
    /// </summary>
    public interface IEyeTargetScaleSink
    {
        float scale { get; set; }
    }

    // =====================================================================
    // Native fields (offsets are the IL2CPP object offsets)
    // =====================================================================

    /// <summary>`lipParam` @0x10, `float[11,14]`.  Native fills it from the
    /// compiler array initializer (data-gap); zeros keep the code runnable.</summary>
    [NonSerialized] public float[,] lipParam;

    /// <summary>`info.facialID` @0x18 (native holds DanceIdolInfo; the spike
    /// only needs the character id, e.g. "001har").</summary>
    public string facialID;

    public TransitionModuleNative facialTrs;  // 0x20
    public TransitionModuleNative eyeTrs;     // 0x28
    public TransitionModuleNative lipTrs;     // 0x30
    public TransitionModuleNative cheekTrs;   // 0x38
    public TransitionModuleNative muteLipTrs; // 0x40

    public bool singing = true;               // 0x48
    public float cheekBaseIntensity = 0.2f;   // 0x4C

    public MeshBlendParam[] expressions;      // 0x50
    public FaceBlendParam[] paramsrc;         // 0x58

    public float[] mouthOpenBuff;             // 0x60 (14, written by Init, not read by UpdateFace)
    public float[] mouthCloseBuff;            // 0x68 (14)
    public float[] facialMouthBuff;           // 0x70 (14)
    public float[] eyeOpenBuff;               // 0x78 (19)
    public float[] eyeCloseBuff;              // 0x80 (19)

    public SkinnedMeshRenderer render;        // 0x88
    public Material face_material;            // 0x90
    public ICharacterDrawerSink drawer;       // 0x98
    public IEyeTargetScaleSink eyeTarget;     // native info.model.EyeTarget

    private int shaderPropID_IsReddish;        // 0xA0
    private int shaderPropID_ReddishIntensity; // 0xA4

    /// <summary>
    /// When true (default) the component's `Update` calls <see cref="Action"/>
    /// with `Time.deltaTime`, standing in for the native `JointBodyHead` per-frame
    /// call.  Native FaceCtrl is a plain object; this MonoBehaviour wrapper is a
    /// performance/integration substitute, not a behavior change.
    /// </summary>
    public bool autoAction = true;

    private bool stateReady;
    /// <summary>
    /// Continuous mouth opening (0..1) for story voice, driven by the game's own
    /// `fhout` envelope. Negative means "use the discrete lip rows as usual".
    /// </summary>
    private float mouthOpenOverride = -1f;

    private bool warnedNoLipParam;
    private bool warnedNoRenderer;

    // =====================================================================
    // ctor @0x379DC1C
    // =====================================================================

    private void Awake()
    {
        EnsureNativeState();
    }

    /// <summary>
    /// Scale the open mouth shape by <paramref name="rate"/> (0..1) instead of
    /// switching discrete lip rows.  Native story playback feeds
    /// `CharacterFace_RC`'s mumble rate from the authored <c>fhout</c> envelope;
    /// this replica has no float lip entry point, so the envelope scales blend
    /// shape 0 (the open "A" row) directly after the discrete composition.
    /// </summary>
    public void SetMouthOpen(float rate)
    {
        EnsureNativeState();
        mouthOpenOverride = Clamp01(rate);
    }

    public void ClearMouthOpen()
    {
        mouthOpenOverride = -1f;
    }

    /// <summary>
    /// `FaceCtrl..ctor` @0x379DC1C, minus the `DanceIdolInfo`/scene lookup
    /// (done by <see cref="Bind"/> instead).  Five modules, odd buffer sizes
    /// and the two shader property ids, exactly as the native ctor builds them.
    /// </summary>
    public void EnsureNativeState()
    {
        // Editor-workflow hardening: a play-mode recompile domain-reloads and
        // clears the plain-class modules while the serialized `stateReady`
        // survives. Native never faces this (no hot reload on device); rebuild
        // instead of NRE-ing for the rest of the session.
        if (stateReady && facialTrs != null && eyeTrs != null && muteLipTrs != null
            && lipTrs != null && cheekTrs != null) return;
        stateReady = true;

        lipParam = new float[lipKinds, lipParamColumns]; // native data-gap, zeros

        singing = true;
        cheekBaseIntensity = 0.2f;

        mouthOpenBuff = new float[mouthShapes];
        mouthCloseBuff = new float[mouthShapes];
        facialMouthBuff = new float[mouthShapes];
        // native ctor @0x379DC1C allocates 14 + 19: the eye buffers are 18 eye
        // channels plus the expression's trailing eye-tracking scale slot (32).
        eyeOpenBuff = new float[eyeShapes + 1];
        eyeCloseBuff = new float[eyeShapes + 1];

        facialTrs = new TransitionModuleNative(faceTransitionTime, 0);
        eyeTrs = new TransitionModuleNative(eyeBlinkTime, 1);
        lipTrs = new TransitionModuleNative(lipTransitionTime, -1);
        cheekTrs = new TransitionModuleNative(cheekTransTime, 0);
        muteLipTrs = new TransitionModuleNative(lipTransitionTime, 0);

        shaderPropID_IsReddish = Shader.PropertyToID("_IsReddish");
        shaderPropID_ReddishIntensity = Shader.PropertyToID("_ReddishIntensity");
    }

    private void Start()
    {
        // The component may be added before the hierarchy exists; native's ctor
        // does the Find itself, so retry against our own root once.
        if (render == null && transform != null) Bind(transform);
    }

    // =====================================================================
    // Renderer binding (native ctor: GameObject.Find(objname + suffix))
    // =====================================================================

    /// <summary>
    /// Native ctor @0x379DC1C finds the face object with
    /// <c>GameObject.Find(objname + "/obj_head_GP/face")</c> and falls back to
    /// <c>.../obj_head_GP/head</c>, then `GetComponent&lt;SkinnedMeshRenderer&gt;()`.
    /// Here <paramref name="characterRoot"/> plays `objname`: the same path is
    /// searched relative to it (the sys003/pr001 hierarchy carries
    /// <c>obj_head_GP/face</c>, confirmed from the head bundle).
    /// </summary>
    public void Bind(Transform characterRoot)
    {
        EnsureNativeState();
        SkinnedMeshRenderer found = null;

        if (characterRoot != null)
        {
            var faceT = characterRoot.Find("obj_head_GP/face");
            if (faceT != null) found = faceT.GetComponent<SkinnedMeshRenderer>();
            if (found == null)
            {
                var headT = characterRoot.Find("obj_head_GP/head");
                if (headT != null) found = headT.GetComponent<SkinnedMeshRenderer>();
            }
        }

        if (found == null && characterRoot != null)
        {
            // Spike-convenience fallback (old FaceCtrl.Bind used the renderer
            // name): a descendant named "face", else the richest blend-shape mesh.
            int best = -1;
            foreach (var r in characterRoot.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if (r.name == "face") { found = r; break; }
                int shapes = r.sharedMesh != null ? r.sharedMesh.blendShapeCount : 0;
                if (shapes > best) { best = shapes; found = r; }
            }
        }

        render = found;
        if (render == null)
            Debug.LogError("FaceCtrlNative: no face SkinnedMeshRenderer found (native would have thrown)");
    }

    // =====================================================================
    // BlendParamLoad @0x379E080 (+ step iterator @0x37A0D98)
    // =====================================================================

    /// <summary>
    /// JSON → <c>FaceBlendParam[]</c>.  Native schema (keys documented on
    /// <see cref="NativeFaceBlendParam"/>):
    /// <code>
    /// [ { "id": "001har",
    ///     "face": [ { "index": 1, "open": [33 floats], "close": [33 floats] }, ... ] } ]
    /// </code>
    /// The exported spike asset `facial_chara.json` is the same data in the
    /// ScriptableObject field spelling
    /// (<c>[{cid,expressions:[{param32open,param32close}]}]</c>); both are
    /// accepted so the existing export needs no re-encode.  Rows are normalised
    /// to the native construction sizes (28 expressions × 33 floats, see
    /// `FaceBlendParam..ctor` @0x379DAA4 / `MeshBlendParam..ctor` @0x379DA18).
    /// </summary>
    public static FaceBlendParam[] BlendParamLoad(string json)
    {
        var result = new List<FaceBlendParam>();
        if (string.IsNullOrEmpty(json)) return result.ToArray();

        string body = json.Trim();
        string wrapped;
        if (body.StartsWith("{"))
        {
            // Already an object: the spike's own {"items":[...]} wrapper.
            wrapped = body;
        }
        else
        {
            wrapped = "{\"items\":" + body + "}";
        }

        // JsonUtility does not reject unknown members, so a spike-schema array
        // also deserialises into the native classes with every field null. Pick
        // the schema by the row key actually present ("cid" for the asset export,
        // "id"/"face" for the native schema).
        var looksLikeAssetExport = body.IndexOf("\"cid\"", StringComparison.Ordinal) >= 0;
        if (!looksLikeAssetExport)
        {
            var native = JsonUtility.FromJson<NativeFaceBlendParamList>(wrapped);
            if (native != null && native.items != null && native.items.Count > 0)
            {
                foreach (var row in native.items)
                    result.Add(FromNative(row));
                return result.ToArray();
            }
        }

        var asset = JsonUtility.FromJson<FaceBlendParamList>(wrapped);
        if (asset != null && asset.items != null)
        {
            foreach (var row in asset.items)
                result.Add(Normalise(row));
        }
        return result.ToArray();
    }

    private static FaceBlendParam FromNative(NativeFaceBlendParam row)
    {
        var param = new FaceBlendParam
        {
            cid = row != null ? row.id : null,
            expressions = NewExpressionArray(),
        };
        if (row == null || row.face == null) return param;
        foreach (var expr in row.face)
        {
            if (expr == null) continue;
            int index = expr.index - 1; // native: Int32.Parse("index") - 1
            if (index < 0 || index >= expressionCount) continue;
            var slot = param.expressions[index];
            if (expr.open != null)
                Array.Copy(expr.open, slot.param32open,
                    Mathf.Min(expr.open.Length, paramCount));
            if (expr.close != null)
                Array.Copy(expr.close, slot.param32close,
                    Mathf.Min(expr.close.Length, paramCount));
        }
        return param;
    }

    private static FaceBlendParam Normalise(FaceBlendParam row)
    {
        if (row == null) return null;
        var expressions = NewExpressionArray();
        if (row.expressions != null)
        {
            int n = Mathf.Min(row.expressions.Length, expressionCount);
            for (int i = 0; i < n; i++)
            {
                var src = row.expressions[i];
                if (src == null) continue;
                var dst = expressions[i];
                if (src.param32open != null)
                    Array.Copy(src.param32open, dst.param32open,
                        Mathf.Min(src.param32open.Length, paramCount));
                if (src.param32close != null)
                    Array.Copy(src.param32close, dst.param32close,
                        Mathf.Min(src.param32close.Length, paramCount));
            }
        }
        row.expressions = expressions;
        return row;
    }

    private static MeshBlendParam[] NewExpressionArray()
    {
        var arr = new MeshBlendParam[expressionCount];
        for (int i = 0; i < expressionCount; i++)
        {
            arr[i] = new MeshBlendParam
            {
                param32open = new float[paramCount],
                param32close = new float[paramCount],
            };
        }
        return arr;
    }

    // =====================================================================
    // Init @0x379E5B8 / Init2 @0x379E8A4
    // =====================================================================

    /// <summary>
    /// `FaceCtrl.Init(FaceBlendParam[])` @0x379E5B8.  Picks the row whose
    /// <c>cid</c> equals <see cref="facialID"/> (native compares against
    /// <c>info.facialID</c> with string equality), seeds the four buffers from
    /// <c>expressions[0]</c>, then forces cheek OFF and eyes OPEN through their
    /// transitions (with an <c>UpdateFace</c> after each force).
    /// </summary>
    public void Init(FaceBlendParam[] param)
    {
        EnsureNativeState();
        paramsrc = param;
        if (param == null) return;
        if (param.Length < 1) return;

        MeshBlendParam[] found = null;
        for (int i = 0; i < param.Length; i++)
        {
            if (param[i] != null && string.Equals(param[i].cid, facialID))
            {
                found = param[i].expressions;
                break;
            }
        }
        if (found == null) return; // native: no match → return without touching

        expressions = found;
        if (expressions.Length == 0)
        {
            Debug.LogError("FaceCtrlNative.Init: expression table is empty (native throws)");
            return;
        }

        var first = expressions[0];
        if (!RequireExpression(first, "Init")) return;

        for (int i = 0; i < mouthShapes; i++)
        {
            mouthOpenBuff[i] = first.param32open[i];
            mouthCloseBuff[i] = first.param32close[i];
        }
        int eyeBuffLen = paramCount - mouthShapes; // 19: channels 14..32
        for (int i = 0; i < eyeBuffLen; i++)
        {
            eyeOpenBuff[i] = first.param32open[mouthShapes + i];
            eyeCloseBuff[i] = first.param32close[mouthShapes + i];
        }

        if (cheekTrs.cur != 0) cheekTrs.Set(0);
        UpdateFace();

        if (eyeTrs.cur != 1) eyeTrs.Set(1);
        UpdateFace();
    }

    /// <summary>`FaceCtrl.Init2` @0x379E8A4.</summary>
    public void Init2()
    {
        EnsureNativeState();
        if (paramsrc != null) Init(paramsrc);

        singing = true;

        facialTrs.Init(0);
        eyeTrs.Init(1);
        lipTrs.Init(-1);
        cheekTrs.Init(0);
        muteLipTrs.Init(0);

        UpdateFace();
    }

    // =====================================================================
    // Convenience wrapper used by the spike's CharacterBootstrap
    // =====================================================================

    /// <summary>
    /// `BlendParamLoad` + `Init` + `Init2`; returns the expression count.
    /// Same three steps the native `JointBodyHead` performs.  (Native has no
    /// single call; this wrapper exists only for the spike's loading path.)
    /// </summary>
    public int LoadJson(string json, string cid)
    {
        EnsureNativeState();
        facialID = cid;
        var table = BlendParamLoad(json);
        Init(table);
        Init2();
        return expressions != null ? expressions.Length : 0;
    }

    /// <summary>
    /// Data-gap filler for native `lipParam[11,14]` (see notes).  The native
    /// table is a compiler array initializer in global-metadata; supply the
    /// 11×14 floats recovered by a metadata RVA dump here.  Any values that do
    /// not cover the table are padded with zeros.
    /// </summary>
    public void LoadLipParam(float[,] table)
    {
        EnsureNativeState();
        lipParam = new float[lipKinds, lipParamColumns];
        if (table == null) return;
        int rows = Mathf.Min(table.GetLength(0), lipKinds);
        int cols = Mathf.Min(table.GetLength(1), lipParamColumns);
        for (int r = 0; r < rows; r++)
            for (int c = 0; c < cols; c++)
                lipParam[r, c] = table[r, c];
        warnedNoLipParam = false;
    }

    // =====================================================================
    // Face / lip / eye / cheek setters
    // =====================================================================

    /// <summary>`FaceCtrl.SetFace(int n, int muteLip)` @0x379F5F0.</summary>
    public void SetFace(int n, int muteLip)
    {
        EnsureNativeState();
        if (facialTrs == null || muteLipTrs == null) return;
        facialTrs.Set(n);
        muteLipTrs.Set(muteLip);
        UpdateFace();
    }

    /// <summary>Spike convenience overload: native's second argument is a
    /// required mute-lip kind; expression-only callers pass 0 (off).</summary>
    public void SetFace(int n)
    {
        SetFace(n, 0);
    }

    /// <summary>`FaceCtrl.SetFaceDirect(int n, int muteLip)` @0x379F674.</summary>
    public void SetFaceDirect(int n, int muteLip)
    {
        EnsureNativeState();
        if (facialTrs == null || muteLipTrs == null) return;
        facialTrs.SetDirect(n);
        muteLipTrs.SetDirect(muteLip);
        UpdateFace();
    }

    public int GetCurrentFace()
    {
        EnsureNativeState();
        return facialTrs.cur;
    }

    public int GetCurrentMuteLip()
    {
        EnsureNativeState();
        return muteLipTrs.cur;
    }

    /// <summary>
    /// `FaceCtrl.ConvLip(int n)` @0x379F3A4: caller lip code → lip kind
    /// (−1 mute, 0..10 mouth row).  50→5, 54→−1, 55..59→6..10, otherwise n%5.
    /// Native is private; exposed here so the probe can diff the mapping.
    /// </summary>
    public static int ConvLip(int n)
    {
        if (n == 50) return 5;
        if (n == 54) return -1;
        if (unchecked((uint)(n - 60)) >= 0xFFFFFFFBu) return n - 49; // 55..59 → 6..10
        return n % 5;
    }

    /// <summary>`FaceCtrl.SetLip(int n)` @0x379F46C (0.2 s fade, forced to −1
    /// while not singing).</summary>
    public void SetLip(int n)
    {
        EnsureNativeState();
        int kind = ConvLip(n);
        if (!singing) kind = -1;
        lipTrs.Set(kind);
        UpdateFace();
    }

    /// <summary>`FaceCtrl.SetLipDirect(int n)` @0x379F53C.</summary>
    public void SetLipDirect(int n)
    {
        EnsureNativeState();
        int kind = ConvLip(n);
        if (!singing) kind = -1;
        lipTrs.SetDirect(kind);
        UpdateFace();
    }

    public int GetCurrentLip()
    {
        EnsureNativeState();
        return lipTrs.cur;
    }

    /// <summary>`FaceCtrl.SetSinging(bool)` @0x379F3FC: turning singing off
    /// forces the lip module to −1 (through the 0.2 s transition) and recomposes;
    /// turning it on only flips the flag.</summary>
    public void SetSinging(bool sw)
    {
        EnsureNativeState();
        if (!sw)
        {
            if (lipTrs.cur != -1) lipTrs.Set(-1);
            UpdateFace();
        }
        singing = sw;
    }

    /// <summary>`FaceCtrl.SetEyeClose(bool)` @0x379E858.  Note the native
    /// inversion: <c>Set(true)</c> targets <c>EyeState.Close</c> (kind 0).</summary>
    public void SetEyeClose(bool sw)
    {
        EnsureNativeState();
        eyeTrs.Set(sw ? (int)EyeState.Close : (int)EyeState.Open);
        UpdateFace();
    }

    /// <summary>`FaceCtrl.SetEyeCloseDirect(bool)` @0x379F6EC.</summary>
    public void SetEyeCloseDirect(bool sw)
    {
        EnsureNativeState();
        eyeTrs.SetDirect(sw ? (int)EyeState.Close : (int)EyeState.Open);
        UpdateFace();
    }

    public bool GetCurrentEyeClose()
    {
        EnsureNativeState();
        return eyeTrs.cur == (int)EyeState.Close;
    }

    private float[] GetEyeBuff(EyeState state)
    {
        if (state == EyeState.Open) return eyeOpenBuff;
        if (state == EyeState.Close) return eyeCloseBuff;
        return null;
    }

    /// <summary>`FaceCtrl.SetCheek(int lv)` @0x379E810 (0.1 s fade).</summary>
    public void SetCheek(int lv)
    {
        EnsureNativeState();
        cheekTrs.Set(lv);
        UpdateFace();
    }

    /// <summary>`FaceCtrl.SetCheekDirect(int lv)` @0x379F768.</summary>
    public void SetCheekDirect(int lv)
    {
        EnsureNativeState();
        cheekTrs.SetDirect(lv);
        UpdateFace();
    }

    public int GetCurrentCheekLV()
    {
        EnsureNativeState();
        return cheekTrs.cur;
    }

    /// <summary>`FaceCtrl.GetCheekValue(int lv)` @0x379F818: OFF→0,
    /// Weak→cheekBaseIntensity*0.5, Strong→cheekBaseIntensity.</summary>
    public float GetCheekValue(int lv)
    {
        if (lv < 1) return 0f;
        float result = cheekBaseIntensity;
        if (lv == (int)CheekState.Weak) return result * 0.5f;
        return result;
    }

    // =====================================================================
    // Cheek material + CharacterDrawer relay
    // =====================================================================

    /// <summary>
    /// `FaceCtrl.CheekUpdate` @0x379F790: cross-fade the cheek level into the
    /// material intensity and relay it to the drawer.
    /// </summary>
    private void CheekUpdate()
    {
        EnsureNativeState();
        float from = GetCheekValue(cheekTrs.last);
        float to = GetCheekValue(cheekTrs.cur);
        SetCheekValue(from + (to - from) * Clamp01(cheekTrs.ratio));
    }

    /// <summary>
    /// `FaceCtrl.SetCheekValue(float)` @0x379F840.  Material selection is the
    /// native one: `face_material` if `SetFaceMaterial` supplied one, else the
    /// renderer's shared material.  Writes `_ReddishIntensity`, then the
    /// `_IsReddish` toggle (`SetMaterialToggle`: HasFloat → SetFloat(0/1),
    /// HasInteger → SetInteger, HasInt → SetInt, then enable/disable the
    /// `_ISREDDISH_ON` keyword).  Then relays to `CharacterDrawer`.
    /// </summary>
    public void SetCheekValue(float val)
    {
        EnsureNativeState();
        if (render == null)
        {
            if (!warnedNoRenderer)
            {
                warnedNoRenderer = true;
                Debug.LogError("FaceCtrlNative.SetCheekValue: no face renderer");
            }
            return;
        }

        Material material = render.sharedMaterial;
        if (face_material != null) material = face_material;
        if (material == null)
        {
            Debug.LogError("FaceCtrlNative.SetCheekValue: no face material");
            return;
        }

        material.SetFloat(shaderPropID_ReddishIntensity, val);
        bool flag = val != 0f;
        if (material.HasFloat(shaderPropID_IsReddish))
            material.SetFloat(shaderPropID_IsReddish, flag ? 1f : 0f);
        else if (material.HasInteger(shaderPropID_IsReddish))
            material.SetInteger(shaderPropID_IsReddish, flag ? 1 : 0);
        else if (material.HasInt(shaderPropID_IsReddish))
            material.SetInt(shaderPropID_IsReddish, flag ? 1 : 0);
        if (flag) material.EnableKeyword(ReddishKeyword);
        else material.DisableKeyword(ReddishKeyword);

        if (drawer != null)
        {
            drawer.SetCheekReddenEnable(flag);
            drawer.SetCheekReddenIntensity(val);
        }
    }

    /// <summary>`FaceCtrl.SetFaceMaterial` @0x379FD00.</summary>
    public void SetFaceMaterial(Material material)
    {
        face_material = material;
    }

    /// <summary>`FaceCtrl.SetCharacterDrawer` @0x379FD08.</summary>
    public void SetCharacterDrawer(ICharacterDrawerSink sink)
    {
        drawer = sink;
    }

    /// <summary>Native hook for `info.model.EyeTarget` (B4 EyeTracking).</summary>
    public void SetEyeTarget(IEyeTargetScaleSink sink)
    {
        eyeTarget = sink;
    }

    // =====================================================================
    // Action @0x379FA48 / UpdateFace @0x379E94C
    // =====================================================================

    private void Update()
    {
        if (autoAction) Action();
    }

    /// <summary>
    /// `FaceCtrl.Action` @0x379FA48.  Advances the five modules in the native
    /// order (facial, eye, muteLip, lip, cheek), composes, then runs the cheek
    /// cross-fade exactly like the native tail (which duplicates
    /// <see cref="CheekUpdate"/> on a busy frame).
    /// </summary>
    public void Action()
    {
        ActionWithDeltaTime(Time.deltaTime); // FaceCtrl.GetDeltaTime @0x379FC98
    }

    /// <summary>
    /// The body of <see cref="Action"/> with the delta time passed in.  Native
    /// always reads `Time.deltaTime`; the editor probe has no per-frame ticks, so
    /// it steps the same code with an explicit dt.  Pure substitution of the
    /// time source, no formula change.
    /// </summary>
    public void ActionWithDeltaTime(float dt)
    {
        if (!stateReady) EnsureNativeState();

        facialTrs.Progress(dt);
        eyeTrs.Progress(dt);
        muteLipTrs.Progress(dt);
        lipTrs.Progress(dt);
        cheekTrs.Progress(dt);

        UpdateFace();
        CheekUpdate();
    }

    /// <summary>
    /// `FaceCtrl.UpdateFace` @0x379E94C.  Writes the 32 blend-shape channels:
    /// mouth 0..13, eye region 14..31.  Block gating copied from the native
    /// code (each block also runs when the facial module itself changed):
    /// <list type="number">
    /// <item>facial updated → rebuild mouthClose/eyeOpen/eyeClose + eye-track scale</item>
    /// <item>eye updated or facial updated → blend eye buffer, write BS 14..31</item>
    /// <item>muteLip updated or facial updated → build facialMouthBuff</item>
    /// <item>lip updated or muteLip updated or facial updated → blend mouth, write BS 0..13</item>
    /// <item>cheek updated → cheek cross-fade (SetCheekValue)</item>
    /// </list>
    /// Then clears all five <c>updated</c> flags.
    /// </summary>
    public void UpdateFace()
    {
        EnsureNativeState();
        if (facialTrs == null || eyeTrs == null || muteLipTrs == null
            || lipTrs == null || cheekTrs == null) return;
        if (render == null)
        {
            if (!warnedNoRenderer)
            {
                warnedNoRenderer = true;
                Debug.LogError("FaceCtrlNative.UpdateFace: no face renderer bound (native throws)");
            }
            return;
        }

        bool facialUpdated = facialTrs.updated;
        bool eyeUpdated = eyeTrs.updated;
        bool muteUpdated = muteLipTrs.updated;
        bool lipUpdated = lipTrs.updated;
        bool cheekUpdated = cheekTrs.updated;

        // ---- 1. facial fade: expression weights → buffers @0x379E94C head ----
        if (facialUpdated)
        {
            if (expressions == null || expressions.Length == 0)
            {
                Debug.LogError("FaceCtrlNative.UpdateFace: no expressions loaded (native throws)");
                return;
            }
            MeshBlendParam last, cur;
            if (!TryGetExpression(facialTrs.last, out last) || !TryGetExpression(facialTrs.cur, out cur))
                return;

            float ratio = Clamp01(facialTrs.ratio);
            for (int i = 0; i < mouthShapes; i++)
                mouthCloseBuff[i] = last.param32close[i]
                                    + (cur.param32close[i] - last.param32close[i]) * ratio;

            int eyeLen = paramCount - mouthShapes; // 19: channels 14..32
            for (int i = 0; i < eyeLen; i++)
            {
                int k = mouthShapes + i;
                eyeOpenBuff[i] = last.param32open[k] + (cur.param32open[k] - last.param32open[k]) * ratio;
                eyeCloseBuff[i] = last.param32close[k] + (cur.param32close[k] - last.param32close[k]) * ratio;
            }

            // EyeTracking scale: 1 / (param[32] * 0.01) of the open or close
            // vector, selected by the eye module's current kind (0 = close).
            float scaleSource = eyeTrs.cur != (int)EyeState.Close
                ? cur.param32open[paramCount - 1]
                : cur.param32close[paramCount - 1];
            float scale = scaleSource * 0.01f;
            if (scale != 0f) scale = 1f / scale;
            if (eyeTarget != null) eyeTarget.scale = scale;
        }

        // ---- 2. blink fade: write BS 14..31 @0x379F044 ----
        if (eyeUpdated || facialUpdated)
        {
            float[] from;
            switch (eyeTrs.last)
            {
                case (int)EyeState.Open: from = eyeOpenBuff; break;
                case (int)EyeState.Close: from = eyeCloseBuff; break;
                default: from = null; break;
            }
            float[] to = GetEyeBuff(eyeTrs.cur == (int)EyeState.Open ? EyeState.Open : EyeState.Close);
            if (to != null)
            {
                float ratio = Clamp01(eyeTrs.ratio);
                int n = from != null ? Mathf.Min(eyeShapes, Mathf.Min(from.Length, to.Length))
                                     : Mathf.Min(eyeShapes, to.Length);
                for (int i = 0; i < n; i++)
                {
                    // Compute the blend into a temporary. Writing back into eyeOpenBuff /
                    // eyeCloseBuff would corrupt the expression weights (the buffers are the
                    // fade endpoints, not a scratch pad); after one blink the "open" buffer
                    // would hold closed values and the character would sit half-lidded until
                    // the next actor_facial event rebuilt it.
                    float blended = from != null ? from[i] + (to[i] - from[i]) * ratio : to[i];
                    render.SetBlendShapeWeight(mouthShapes + i, blended); // index W1 = i + 14
                }
            }
        }

        // ---- 3. mute-lip fade: build facialMouthBuff (sources: mouthCloseBuff
        //      or lipParam[muteLipKind - 1]) ----
        if (muteUpdated || facialUpdated)
        {
            int lastKind = muteLipTrs.last;
            int curKind = muteLipTrs.cur;
            float ratio = Clamp01(muteLipTrs.ratio);
            for (int i = 0; i < mouthShapes; i++)
            {
                float from = lipParam != null && lastKind - 1 >= 0 && lastKind - 1 < lipKinds
                    ? lipParam[lastKind - 1, i]
                    : mouthCloseBuff[i];
                float to = lipParam != null && curKind - 1 >= 0 && curKind - 1 < lipKinds
                    ? lipParam[curKind - 1, i]
                    : mouthCloseBuff[i];
                facialMouthBuff[i] = from + (to - from) * ratio;
            }
        }

        // ---- 4. lip fade: write BS 0..13 @0x379F260 ----
        if (lipUpdated || muteUpdated || facialUpdated)
        {
            int lastKind = lipTrs.last;
            int curKind = lipTrs.cur;
            float ratio = Clamp01(lipTrs.ratio);
            for (int i = 0; i < mouthShapes; i++)
            {
                float from = facialMouthBuff[i];
                float to = facialMouthBuff[i];
                if (lipParam != null)
                {
                    if (lastKind >= 0 && lastKind < lipKinds) from = lipParam[lastKind, i];
                    if (curKind >= 0 && curKind < lipKinds) to = lipParam[curKind, i];
                }
                else if ((lastKind >= 0 || curKind >= 0) && !warnedNoLipParam)
                {
                    warnedNoLipParam = true;
                    Debug.LogWarning(
                        "FaceCtrlNative: lipParam is a data-gap (native array initializer); "
                        + "lip kinds >= 0 fall back to the expression mouth weights. "
                        + "Feed it with LoadLipParam once the metadata blob is dumped.");
                }
                render.SetBlendShapeWeight(i, from + (to - from) * ratio);
            }
        }

        // ---- 4b. continuous story lip -------------------------------------
        // The theater drives the mouth from the authored `fhout` envelope. Native
        // story playback feeds CharacterFace_RC's mumble rate; this replica has no
        // float lip entry point, so the same envelope scales the open "A" row
        // (blend shape 0) directly after the discrete lip composition.
        if (mouthOpenOverride >= 0f)
        {
            render.SetBlendShapeWeight(0, mouthOpenOverride * 100f);
            for (int i = 1; i < mouthShapes; i++) render.SetBlendShapeWeight(i, 0f);
        }

        // ---- 5. cheek cross-fade (same body as CheekUpdate @0x379F790) ----
        if (cheekUpdated)
        {
            float from = GetCheekValue(cheekTrs.last);
            float to = GetCheekValue(cheekTrs.cur);
            SetCheekValue(from + (to - from) * Clamp01(cheekTrs.ratio));
        }

        // ---- clear the five composition flags (native tail) ----
        facialTrs.updated = false;
        eyeTrs.updated = false;
        muteLipTrs.updated = false;
        lipTrs.updated = false;
        cheekTrs.updated = false;
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    private static float Clamp01(float value)
    {
        if (value <= 1f) return value < 0f ? 0f : value;
        return 1f;
    }

    private bool TryGetExpression(int index, out MeshBlendParam param)
    {
        param = null;
        if (expressions == null || index < 0 || index >= expressions.Length) return false;
        param = expressions[index];
        return RequireExpression(param, "UpdateFace");
    }

    private bool RequireExpression(MeshBlendParam param, string where)
    {
        if (param == null || param.param32open == null || param.param32close == null)
        {
            Debug.LogError("FaceCtrlNative." + where + ": expression has no 33-wide weight vectors (native throws)");
            return false;
        }
        if (param.param32open.Length < paramCount || param.param32close.Length < paramCount)
        {
            Debug.LogError("FaceCtrlNative." + where + ": weight vectors shorter than 33 (native throws)");
            return false;
        }
        return true;
    }

    // =====================================================================
    // Probe helpers
    // =====================================================================

    /// <summary>One-line state for the editor probe.</summary>
    public string Describe()
    {
        EnsureNativeState();
        return "FaceCtrlNative cid=" + (facialID ?? "?")
               + " expressions=" + (expressions != null ? expressions.Length : 0)
               + " chars=" + (paramsrc != null ? paramsrc.Length : 0)
               + " animated=" + (render != null && render.sharedMesh != null && render.sharedMesh.blendShapeCount > 0)
               + " face=" + (render != null ? render.name : "null")
               + " singing=" + singing
               + " faceTrs[" + facialTrs.last + "→" + facialTrs.cur + " r=" + facialTrs.ratio.ToString("F3") + "]"
               + " eye[" + eyeTrs.last + "→" + eyeTrs.cur + " r=" + eyeTrs.ratio.ToString("F3") + "]"
               + " lip[" + lipTrs.last + "→" + lipTrs.cur + " r=" + lipTrs.ratio.ToString("F3") + "]"
               + " mute[" + muteLipTrs.last + "→" + muteLipTrs.cur + " r=" + muteLipTrs.ratio.ToString("F3") + "]"
               + " cheek[" + cheekTrs.last + "→" + cheekTrs.cur + " r=" + cheekTrs.ratio.ToString("F3")
               + " base=" + cheekBaseIntensity.ToString("F3") + "]";
    }

    /// <summary>Dump of the current 32 blend-shape weights on the face mesh.</summary>
    public string DumpChannelWeights()
    {
        EnsureNativeState();
        if (render == null || render.sharedMesh == null) return "no face mesh";
        var mesh = render.sharedMesh;
        var lines = new System.Text.StringBuilder();
        lines.Append("chan\tweight\tname\n");
        for (int i = 0; i < mesh.blendShapeCount; i++)
            lines.Append(i).Append('\t').Append(render.GetBlendShapeWeight(i).ToString("F2"))
                 .Append('\t').Append(mesh.GetBlendShapeName(i)).Append('\n');
        return lines.ToString();
    }

    /// <summary>Dump of the four composition buffers + both 33-wide vectors of one expression.</summary>
    public string DumpBuffers()
    {
        EnsureNativeState();
        var sb = new System.Text.StringBuilder();
        sb.Append("mouthOpenBuff   ").Append(JoinFloats(mouthOpenBuff)).Append('\n');
        sb.Append("mouthCloseBuff  ").Append(JoinFloats(mouthCloseBuff)).Append('\n');
        sb.Append("facialMouthBuff ").Append(JoinFloats(facialMouthBuff)).Append('\n');
        sb.Append("eyeOpenBuff     ").Append(JoinFloats(eyeOpenBuff)).Append('\n');
        sb.Append("eyeCloseBuff    ").Append(JoinFloats(eyeCloseBuff)).Append('\n');
        sb.Append("lipParam        ").Append(lipParam == null ? "null" : LipParamHasData() ? "present" : "zeros (data-gap)").Append('\n');
        return sb.ToString();
    }

    /// <summary>Dump the open/close vector of <paramref name="index"/> (33 floats each).</summary>
    public string DumpExpression(int index)
    {
        EnsureNativeState();
        if (expressions == null || index < 0 || index >= expressions.Length)
            return "no expression " + index;
        var param = expressions[index];
        if (param == null) return "expression " + index + " is null";
        var sb = new System.Text.StringBuilder();
        sb.Append("expression ").Append(index).Append(" menu=")
          .Append(index < facialMenu.Length ? facialMenu[index] : "?").Append('\n');
        sb.Append("open  ").Append(JoinFloats(param.param32open)).Append('\n');
        sb.Append("close ").Append(JoinFloats(param.param32close)).Append('\n');
        return sb.ToString();
    }

    private bool LipParamHasData()
    {
        if (lipParam == null) return false;
        for (int r = 0; r < lipParam.GetLength(0); r++)
            for (int c = 0; c < lipParam.GetLength(1); c++)
                if (lipParam[r, c] != 0f) return true;
        return false;
    }

    private static string JoinFloats(float[] values)
    {
        if (values == null) return "null";
        var parts = new string[values.Length];
        for (int i = 0; i < values.Length; i++) parts[i] = values[i].ToString("G7");
        return string.Join(",", parts);
    }
}
