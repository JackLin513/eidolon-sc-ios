using System.Collections.Generic;
using System.Linq;
using UnityEngine;

/// The game's `Imas.FaceCtrl`, reduced to what a standing character needs.
///
/// Expressions are blend shapes on the face mesh (`blendShape1.M_*` for the
/// mouth, `B_*` for the brows, `E_*`/`EL_*` for the eyes), and the game drives
/// them from `FaceBlendParam { cid, expressions }` loaded from a JSON asset.
/// The transitions are the game's own: `eyeBlinkTime` 0.1 s, `lipTransitionTime`
/// 0.2 s, `faceTransitionTime` 0.1333 s, `cheekTransTime` 0.1 s.
///
/// The JSON that names the per-character expression groups ships in
/// `commu_params.unity3d`, which is not in this character's bundles, so the
/// groups used here are read off the blend shape names themselves — the same
/// split the game's constants imply (`mouthShapes` 14, `eyeShapes` 18).
public sealed class FaceCtrl : MonoBehaviour
{
    /// `Imas.MeshBlendParam`: one expression as two 32-wide blend-shape weight
    /// vectors — the mouth-closed and mouth-open forms the game cross-fades
    /// while a character talks.
    [System.Serializable]
    public sealed class MeshBlendParam
    {
        public float[] param32open;
        public float[] param32close;
    }

    /// `Imas.FaceBlendParam`: the per-character expression table.
    [System.Serializable]
    public sealed class FaceBlendParam
    {
        public string cid;
        public MeshBlendParam[] expressions;
    }

    [System.Serializable]
    private sealed class FaceBlendParamList
    {
        public List<FaceBlendParam> items;
    }

    public const float EyeBlinkTime = 0.1f;
    public const float LipTransitionTime = 0.2f;
    public const float FaceTransitionTime = 0.13333334f;

    public bool blink = true;
    public float blinkIntervalMin = 2.5f;
    public float blinkIntervalMax = 6f;

    private SkinnedMeshRenderer face;
    private readonly Dictionary<string, int> shapeIndex = new Dictionary<string, int>();

    private float eyeClosed;        // 0 open, 1 closed
    private float eyeTarget;
    private float blinkTimer;
    private float mouthWeight;      // whatever mouth shape is showing
    private string mouthShape = "M_n";
    private string lipShape;
    private float lipWeight;
    /// How many blinks have run; the probes read it to prove the eyelids move.
    public int Blinks { get; private set; }

    private float[] openWeights = new float[0];
    private float[] closeWeights = new float[0];
    private float[] targetOpen = new float[0];
    private float[] targetClose = new float[0];

    /// Every character in the game's face table, and the expression list of the
    /// one this model uses. `FaceBlendParam.cid` is the character id, so the
    /// table has to be narrowed to the model before it can be indexed by
    /// expression.
    public List<FaceBlendParam> Characters { get; private set; } = new List<FaceBlendParam>();
    public List<MeshBlendParam> Expressions { get; private set; } = new List<MeshBlendParam>();
    public string CharacterId { get; private set; }
    public int CurrentFace { get; private set; } = -1;

    public bool Ready => face != null;

    /// `FaceCtrl.BlendParamLoad(string json)`: the game's face data is a JSON
    /// array of `{cid, expressions[{param32open, param32close}]}`. The weights
    /// are already scaled 0..1 per blend shape index.
    public int LoadJson(string json, string cid)
    {
        if (string.IsNullOrEmpty(json)) return 0;
        var list = JsonUtility.FromJson<FaceBlendParamList>("{\"items\":" + json + "}");
        Characters = list?.items ?? new List<FaceBlendParam>();
        var match = Characters.FirstOrDefault(c => c.cid == cid);
        if (match == null)
        {
            Debug.LogWarning($"FaceCtrl: no face params for '{cid}'");
            Expressions = new List<MeshBlendParam>();
            return 0;
        }
        CharacterId = cid;
        Expressions = match.expressions != null
            ? new List<MeshBlendParam>(match.expressions)
            : new List<MeshBlendParam>();
        return Expressions.Count;
    }

    /// `FaceCtrl.SetFace(n, muteLip)`: blend shape `i` takes
    /// `param32open[i]` or `param32close[i]`, times 100 for Unity's weights.
    public void SetFace(int expression)
    {
        if (face == null || expression < 0 || expression >= Expressions.Count) return;
        var param = Expressions[expression];
        if (param == null) return;
        CurrentFace = expression;
        targetOpen = param.param32open ?? new float[0];
        targetClose = param.param32close ?? new float[0];
        if (openWeights.Length != targetOpen.Length)
        {
            openWeights = (float[])targetOpen.Clone();
            closeWeights = (float[])targetClose.Clone();
        }
    }

    /// `faceTransitionTime`: the game eases from one expression to the next
    /// over 0.1333 s instead of snapping.
    private void AdvanceExpression()
    {
        if (openWeights.Length == 0) return;
        var step = Time.deltaTime / FaceTransitionTime;
        for (var i = 0; i < openWeights.Length; i++)
        {
            var open = i < targetOpen.Length ? targetOpen[i] : 0f;
            var close = i < targetClose.Length ? targetClose[i] : 0f;
            openWeights[i] = Mathf.MoveTowards(openWeights[i], open, step * 100f);
            closeWeights[i] = Mathf.MoveTowards(closeWeights[i], close, step * 100f);
        }
    }

    public int ExpressionCount => Expressions.Count;
    public int CharacterCount => Characters.Count;

    /// `FaceCtrl.SetLip`: the mouth is one of the 14 `M_*` shapes on top of
    /// the current expression, so the expression's own mouth channels are
    /// cleared before the vowel goes in. The game blends this with a 0.2 s
    /// `lipTransitionTime`; a caller that drives it per phoneme can pass
    /// `immediate` for the frame-by-frame case.
    public void SetLip(string shape, float weight = 100f)
    {
        lipShape = shape;
        lipWeight = Mathf.Clamp(weight, 0f, 100f);
    }

    public void ClearLip() => lipShape = null;

    /// Starts a blink now (the probes use it to catch the eyelid mid-move).
    public void BlinkNow() => eyeTarget = 1f;

    public void Bind(Transform root)
    {
        face = root.GetComponentsInChildren<SkinnedMeshRenderer>(true)
            .FirstOrDefault(r => r.name == "face");
        shapeIndex.Clear();
        if (face == null) return;
        var mesh = face.sharedMesh;
        for (var i = 0; i < mesh.blendShapeCount; i++)
        {
            var name = mesh.GetBlendShapeName(i);
            var dot = name.LastIndexOf('.');
            shapeIndex[dot >= 0 ? name.Substring(dot + 1) : name] = i;
        }
        ResetMouth();
        blinkTimer = Random.Range(blinkIntervalMin, blinkIntervalMax);
    }

    private void Update()
    {
        if (face == null) return;
        if (eyeTarget > 0f)
        {
            // Closing: the game holds the blink for `eyeBlinkTime`.
            eyeClosed = Mathf.MoveTowards(eyeClosed, 1f, Time.deltaTime / EyeBlinkTime);
            if (eyeClosed >= 1f)
            {
                Blinks++;
                eyeTarget = 0f;
                blinkTimer = Random.Range(blinkIntervalMin, blinkIntervalMax);
            }
        }
        else
        {
            eyeClosed = Mathf.MoveTowards(eyeClosed, 0f, Time.deltaTime / EyeBlinkTime);
            if (blink)
            {
                blinkTimer -= Time.deltaTime;
                if (blinkTimer <= 0f) eyeTarget = 1f;
            }
        }
        AdvanceExpression();
        ApplyEyes();
    }

    /// Each expression is two weight vectors — the eyes-open and the
    /// eyes-closed form — so the blink is a straight lerp between them, the
    /// same way the game swaps `param32open` for `param32close` while the
    /// eyelid is down.
    private void ApplyEyes()
    {
        if (face == null) return;
        if (openWeights.Length == 0)
        {
            if (!shapeIndex.TryGetValue("E_metoji_r", out var right) ||
                !shapeIndex.TryGetValue("E_metoji_l", out var left)) return;
            face.SetBlendShapeWeight(right, eyeClosed * 100f);
            face.SetBlendShapeWeight(left, eyeClosed * 100f);
            return;
        }
        var open = openWeights;
        var close = closeWeights;
        var count = Mathf.Min(face.sharedMesh.blendShapeCount, Mathf.Min(open.Length, close.Length));
        for (var i = 0; i < count; i++)
            face.SetBlendShapeWeight(i, Mathf.Lerp(open[i], close[i], eyeClosed));

        // The mouth channel of the expression gives way to the vowel the
        // caller is driving for lip sync.
        if (lipShape == null) return;
        foreach (var pair in shapeIndex)
            if (pair.Key.StartsWith("M_")) face.SetBlendShapeWeight(pair.Value, 0f);
        if (shapeIndex.TryGetValue(lipShape, out var lip))
            face.SetBlendShapeWeight(lip, lipWeight);
    }

    /// The mouth shapes the game's `mouthShapes` window covers.
    public void SetMouth(string shape, float weight = 100f)
    {
        if (face == null) return;
        if (mouthShape != null && shapeIndex.TryGetValue(mouthShape, out var previous))
            face.SetBlendShapeWeight(previous, 0f);
        mouthShape = shape;
        mouthWeight = weight;
        if (shapeIndex.TryGetValue(shape, out var index))
            face.SetBlendShapeWeight(index, weight);
    }

    public void ResetMouth()
    {
        foreach (var name in new[] { "M_a", "M_i", "M_u", "M_e", "M_o", "M_ng" })
            if (shapeIndex.TryGetValue(name, out var index)) face.SetBlendShapeWeight(index, 0f);
        mouthShape = null;
        SetMouth("M_n", 100f);
    }

    /// One expression, given as shape → weight in percent.
    public void SetExpression(params (string shape, float weight)[] shapes)
    {
        foreach (var (shape, weight) in shapes)
            if (shapeIndex.TryGetValue(shape, out var index))
                face.SetBlendShapeWeight(index, weight);
    }

    public string Describe()
    {
        if (face == null) return "FaceCtrl: no face renderer";
        return $"FaceCtrl: {CharacterId} {Expressions.Count} expressions of {Characters.Count} characters, "
               + $"{shapeIndex.Count} shapes, eyes {eyeClosed:F2}, face {CurrentFace}, blinks {Blinks}";
    }
}
