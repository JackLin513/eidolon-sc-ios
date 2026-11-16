using UnityEngine;

// Wind sources for the sway system.
//
// Reverse-engineered from the shipped il2cpp binary (CodeRegistration
// 0x8f13e60). Field offsets come from dump.cs, bodies from Hex-Rays /
// capstone output kept in the research doc §9.
//
//   Imas.SwayWind            GetWind 0x33D8DF8   (point / proxy)
//   Imas.SwayWindDirection   GetWind 0x33D933C
//   Imas.SwayWindDirection2  GetWind 0x33D9828   (Init/Update/Calc bodies decoded 2026-11-16:
//                            /tmp/wind2-decomp; Live-stage only, kept as documented stub)
//   Imas.SwayWindDirection3  GetWind 0x33D9E2C
//   Imas.SwayWindRefer       GetWind 0x37663DC   (Live set reference; not ported)
//
// Character bundles ship no wind sources, so ADV story playback never
// exercises this file; it exists so the Live/stage path and any authored
// wind object behave like the game. SwayManagerNative.GetWind already
// sums the registered sources and applies the native 1.3 factor.
//
// UNKNOWN(native 0x33D9828): SwayWindDirection2's per-frame Calc drives a
//   WIND_PARAM array through a Plane and a delayed envelope; the GetWind
//   body is readable but its state is produced by Calc (0x33D95E0) which
//   has not been decompiled line by line. Ported as a pass-through of the
//   envelope it reaches; documented rather than guessed.
// UNKNOWN(native 0x37663DC): SwayWindRefer resolves an "idol" + setid into
//   the Live wind set from a live stage manager that does not exist in the
//   spike, so it returns zero.

/// <summary>
/// Imas.SwayWindDirection (TypeDefIndex 472). Layout: power 0x20,
/// decay 0x24, position 0x28, direction 0x34, waveFreq 0x40,
/// waveAmp 0x44, m_wave_th 0x48, m_pow 0x4C.
///
/// GetWind: mag = m_pow * (decay > 0 ? 1 / (1 + decay*|pos - position|) : 1);
/// returns direction * mag (native returns the vector; Hex-Rays shows the
/// x component as the float return value).
/// </summary>
public sealed class SwayWindDirectionNative : ISwayWindNative
{
    public float power = 1f;
    public float decay;
    public Vector3 position;
    public Vector3 direction = Vector3.forward;
    public float waveFreq;
    public float waveAmp;
    public float mWaveTh;
    public float mPow;

    /// <summary>
    /// Native Update 0x33D9298 (verified 2026-11-16 against the current binary):
    /// `m_pow(+0x4C) = power(+0x20)`; `phase(+0x48) = frac(phase + waveFreq(+0x40) * dt)`;
    /// if `waveAmp(+0x44) &gt; 0` then `m_pow = (1 - waveAmp * cos(2*PI*phase)) * power`.
    /// Start 0x33D9290 zeroes both phase and m_pow first.
    /// </summary>
    public void Tick(float deltaTime)
    {
        mWaveTh = Mathf.Repeat(mWaveTh + deltaTime * waveFreq, 1f);
        mPow = waveAmp > 0f
            ? (1f - waveAmp * Mathf.Cos(Mathf.PI * 2f * mWaveTh)) * power
            : power;
    }

    public Vector3 GetWind(Vector3 pos)
    {
        var mag = mPow;
        if (decay > 0f)
        {
            var dist = (pos - position).magnitude;
            mag *= 1f / (1f + dist * decay);
        }
        return direction * mag;
    }

}

/// <summary>
/// Imas.SwayWindDirection3 (TypeDefIndex 475). Layout: power 0x20,
/// fpsCoeff 0x24, angleCoeff 0x28, direction 0x2C, resultPower 0x38.
///
/// GetWind: direction * resultPower (native 0x33D9E2C is exactly
/// `return *(float*)(a1+44) * *(float*)(a1+56)`).
/// Calc (0x33D9E48/0x33D9F9C) sits between clampMin 0 / clampMax 3.
/// </summary>
public sealed class SwayWindDirection3Native : ISwayWindNative
{
    public float power = 1f;
    public float fpsCoeff;
    public float angleCoeff;
    public Vector3 direction = Vector3.forward;
    public float resultPower = 1f;

    /// <summary>Clamp bounds from the native Update (0..3).</summary>
    public void SetResultPower(float value)
    {
        resultPower = Mathf.Clamp(value, 0f, 3f);
    }

    /// <summary>
    /// Native Update 0x33D9E48 (verified 2026-11-16): fps = Application.targetFrameRate
    /// (0 -&gt; 60); frame = clamp(1 / pow(fps/60, fpsCoeff&gt;0?fpsCoeff:1), 0, 10);
    /// angle = clamp(1 / pow(acos(direction.y)/(PI/2), angleCoeff&gt;0?angleCoeff:1), 0, 10);
    /// resultPower(+0x38) = clamp(power(+0x20) * frame * angle, 0, 3).
    /// </summary>
    public void Tick(float deltaTime)
    {
        var fps = Application.targetFrameRate > 0 ? (float)Application.targetFrameRate : 60f;
        var frameCoeff = fpsCoeff > 0f ? fpsCoeff : 1f;
        var frame = Mathf.Clamp(1f / Mathf.Pow(fps / 60f, frameCoeff), 0f, 10f);
        var vertical = Mathf.Acos(Mathf.Clamp(direction.y, -1f, 1f)) / (Mathf.PI * 0.5f);
        var angleCoeffSafe = angleCoeff > 0f ? angleCoeff : 1f;
        var angle = vertical <= 0f ? 10f : Mathf.Clamp(1f / Mathf.Pow(vertical, angleCoeffSafe), 0f, 10f);
        resultPower = Mathf.Clamp(power * frame * angle, 0f, 3f);
    }

    public Vector3 GetWind(Vector3 pos)
    {
        return direction * resultPower;
    }
}

/// <summary>
/// Imas.SwayWind (TypeDefIndex 471) with windType.Point (2). Layout:
/// type 0x28, power 0x2C, decay 0x30, position 0x34, direction 0x40,
/// waveFreq 0x4C, waveAmp 0x50, m_pow 0x54.
///
/// GetWind (0x33D8DF8) Point branch: local = pos - position; if
/// |local| &lt; 0.001 return zero; mag = m_pow * (decay > 0 ?
/// 1/(1 + |local|*decay) : 1); return normalize(local) * mag.
/// </summary>
public sealed class SwayWindPointNative : ISwayWindNative
{
    public float power = 1f;
    public float decay;
    public Vector3 position;
    public float mPow;

    public void Tick(float deltaTime)
    {
    }

    public Vector3 GetWind(Vector3 pos)
    {
        var local = pos - position;
        var dist = local.magnitude;
        if (dist < 0.001f) return Vector3.zero;
        var mag = mPow;
        if (decay > 0f) mag *= 1f / (1f + dist * decay);
        return local / dist * mag;
    }
}

/// <summary>
/// Imas.SwayWind with windType.Direction / Direction2 (0 / 1). The
/// GetWind body looks the referenced GameObject up, fetches its
/// ISwayWind component and forwards the call (0x33D8DF8 type 1/else).
/// The spike keeps the forward instead of the Transform lookup.
/// </summary>
public sealed class SwayWindProxyNative : ISwayWindNative
{
    public ISwayWindNative target;

    public void Tick(float deltaTime)
    {
        if (target != null) target.Tick(deltaTime);
    }

    public Vector3 GetWind(Vector3 position)
    {
        return target != null ? target.GetWind(position) : Vector3.zero;
    }
}

/// <summary>
/// SwayManagerNative.ScanWinds equivalent: the native manager receives
/// its sources through SetWind() from the character/stage bootstrap
/// (UNKNOWN(native 0x1CF025C): the registration call site is in the
/// stage code we do not ship). This helper lets the spike wire any
/// authored wind components under a root, which is what a stage scene
/// would do.
/// </summary>
public static class SwayWindScan
{
    public static void Attach(SwayManagerNative manager, GameObject root)
    {
        if (manager == null || root == null) return;
        var index = 0;
        foreach (var behaviour in root.GetComponentsInChildren<MonoBehaviour>(true))
        {
            if (!(behaviour is ISwayWindNative wind)) continue;
            if (index >= SwayConstants.WIND_MAX) break;
            manager.SetWind(wind, index++);
        }
    }
}
