using System.Globalization;
using UnityEngine;

/// <summary>
/// The face half of the 3D stand: emotion → native FaceCtrl expression, speaking
/// lip cycle and the blink loop the native game drives from CharacterFace_RC.
///
/// The game's own FaceCtrl (B3) runs its update every frame; this component only
/// schedules native calls (SetFace / SetCheek / SetSinging / SetLip /
/// SetEyeClose). Values are native: SetFace takes the 0..27 facialMenu index and
/// SetCheek the 0..2 level, both as the app's emotion table resolves them.
/// </summary>
public sealed class EidolonStandFace : MonoBehaviour
{
    /// Native lip codes: SetLip(n) maps n%5 to the mouth row; 0..4 = A I U E O.
    private static readonly int[] LipCycle = { 0, 1, 2, 3, 4 };

    /// CharacterFace_RC constants (spike migration-progress.md): blink is
    /// 0.125 s closed, random interval 0.225–0.07 s around a 3–6 s cadence.
    private const float BlinkClosed = 0.125f;
    private const float BlinkMinInterval = 3.2f;
    private const float BlinkMaxInterval = 6.0f;

    private FaceCtrlNative face;
    private bool speaking;
    private float[] lipEnvelope;
    private int lipEnvelopeFps;
    private float lipEnvelopeStart;
    private int lipIndex;
    private int lipFrame;
    private float blinkTimer;
    private float blinkRemaining = -1f;
    private bool eyeClosed;

    /// <summary>
    /// The game's CharacterEyeMode (CharacterEyeMode {Blink=0, Open=1, Close=2}).
    /// The ADV script drives it explicitly through EyeblinkActor -> SetEyeMode;
    /// `blink` restores the automatic cadence, `close`/`open` hold the state.
    /// </summary>
    private enum ScriptEyeMode { Blink, Open, Close }

    private ScriptEyeMode scriptEyeMode = ScriptEyeMode.Blink;

    public void Bind(FaceCtrlNative faceCtrl)
    {
        face = faceCtrl;
        // Seed the native buffers directly. FaceCtrl's own Init2 leaves the eye
        // module in an unopened state and native SetFace(0) is a no-op while
        // cur == 0, so the first frame would show her with her eyes shut.
        face.SetFaceDirect(0, 0);
        face.SetEyeCloseDirect(false);
        face.SetCheekDirect(0);
        ScheduleBlink();
    }

    public void ApplyExpression(int facialIndex, int cheekLevel)
    {
        if (face == null) return;
        // Native SetFace(0)/SetCheek(0) mean "leave it as it is" rather than "row 0",
        // so resetting to the neutral row has to go through the Direct variants.
        var index = Mathf.Clamp(facialIndex, 0, 27);
        if (index == 0) face.SetFaceDirect(0, 0);
        else face.SetFace(index);
        var cheek = Mathf.Clamp(cheekLevel, 0, 2);
        if (cheek == 0) face.SetCheekDirect(0);
        else face.SetCheek(cheek);
    }

    /// <summary>
    /// Story `actor_facial`: the script already names the native 0..27 facialMenu row,
    /// so it goes in without the seven-mood table in between.
    /// </summary>
    public void SetFacialMenu(int index)
    {
        if (face == null) return;
        Debug.Log($"[stand] facial menu={index}");
        var row = Mathf.Clamp(index, 0, 27);
        if (row == 0) face.SetFaceDirect(0, 0);
        else face.SetFace(row);
    }

    /// <summary>
    /// Story `actor_eye_blink`: close / open / blink — the script's own eye mode,
    /// mirroring CharacterActorBase.SetEyeMode(CharacterEyeMode).
    /// </summary>
    public void SetEyeMode(string mode)
    {
        if (face == null) return;
        Debug.Log($"[stand] eye mode={mode}");
        switch (mode)
        {
            case "close":
                scriptEyeMode = ScriptEyeMode.Close;
                blinkRemaining = -1f;
                eyeClosed = true;
                face.SetEyeClose(true);
                break;
            case "open":
                scriptEyeMode = ScriptEyeMode.Open;
                blinkRemaining = -1f;
                eyeClosed = false;
                face.SetEyeClose(false);
                break;
            default:
                // CharacterEyeMode.Blink (0): native clears the mode flag, resets the
                // blink timer and then calls SetEyeClose(false) — so `blink` also
                // *opens* the eyes before the automatic cadence resumes.
                scriptEyeMode = ScriptEyeMode.Blink;
                eyeClosed = false;
                face.SetEyeClose(false);
                ScheduleBlink();
                break;
        }
    }

    /// <summary>
    /// Story `actor_eye_direction`: gaze rate in -100…100, mapped onto the eye limits
    /// the way CharacterActorBase.SetEyeDirectionByRate does.
    /// </summary>
    public void SetGaze(int h, int v)
    {
        Debug.Log($"[stand] gaze {h},{v}");
        EyeTracking.Active?.SetForcedGaze(h / 100f, v / 100f);
    }

    /// <summary>Cheek blush only (story `actor_cheek`), without touching the emotion.</summary>
    public void SetCheek(int level)
    {
        face?.SetCheek(Mathf.Clamp(level, 0, 2));
    }

    public void SetSpeaking(bool value)
    {
        if (face == null) return;
        if (speaking == value) return;
        speaking = value;
        face.SetSinging(value);
        if (value) return;
        face.SetLip(54); // native mute lip code: ConvLip(54) = -1
        face.ClearMouthOpen();
        lipEnvelope = null;
    }

    /// <summary>
    /// Story lines ship the game's authored `fhout` mouth envelope ("textid" →
    /// 0..1 opening at 60 fps, resampled to 30 fps by the packer). Play it instead
    /// of the placeholder vowel cycle, so the mouth follows the recorded voice.
    /// Passing an empty message stops envelope playback and closes the mouth.
    /// </summary>
    public void SetLipEnvelope(string payload)
    {
        if (face == null) return;
        if (string.IsNullOrEmpty(payload))
        {
            lipEnvelope = null;
            face.ClearMouthOpen();
            if (speaking) face.SetLip(54);
            return;
        }

        var separator = payload.IndexOf(':');
        if (separator <= 0)
        {
            Debug.LogWarning($"[stand] lip envelope malformed: {payload.Length} chars");
            return;
        }
        if (!int.TryParse(payload.Substring(0, separator), out var fps) || fps <= 0)
        {
            Debug.LogWarning($"[stand] lip envelope fps malformed");
            return;
        }
        var parts = payload.Substring(separator + 1).Split(',');
        var values = new float[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            values[i] = float.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out var v)
                ? Mathf.Clamp01(v)
                : 0f;
        }
        lipEnvelope = values;
        lipEnvelopeFps = fps;
        lipEnvelopeStart = Time.time;
        Debug.Log($"[stand] lip envelope {values.Length} samples @{fps}fps");
    }

    private void Update()
    {
        if (face == null) return;
        TickBlink();
        if (lipEnvelope != null)
        {
            var index = Mathf.FloorToInt((Time.time - lipEnvelopeStart) * lipEnvelopeFps);
            var opening = index >= 0 && index < lipEnvelope.Length ? lipEnvelope[index] : 0f;
            face.SetMouthOpen(opening);
            return;
        }
        if (!speaking) return;
        lipFrame++;
        if (lipFrame < 4) return;
        lipFrame = 0;
        lipIndex = (lipIndex + 1) % LipCycle.Length;
        face.SetLip(LipCycle[lipIndex]);
    }

    private void TickBlink()
    {
        // While the script holds the eyes closed/open the automatic cadence is off
        // (CharacterEyeMode.Close / Open). Only Blink lets it run.
        if (scriptEyeMode != ScriptEyeMode.Blink) return;
        if (blinkRemaining >= 0f)
        {
            blinkRemaining -= Time.deltaTime;
            if (blinkRemaining <= 0f)
            {
                eyeClosed = false;
                face.SetEyeClose(false);
                ScheduleBlink();
            }
            return;
        }
        blinkTimer -= Time.deltaTime;
        if (blinkTimer > 0f) return;
        eyeClosed = true;
        blinkRemaining = BlinkClosed;
        face.SetEyeClose(true);
    }

    private void ScheduleBlink()
    {
        blinkTimer = Random.Range(BlinkMinInterval, BlinkMaxInterval);
        blinkRemaining = -1f;
        if (eyeClosed)
        {
            eyeClosed = false;
            face.SetEyeClose(false);
        }
    }
}
