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
    private int lipIndex;
    private int lipFrame;
    private float blinkTimer;
    private float blinkRemaining = -1f;
    private bool eyeClosed;

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
        face.SetFace(Mathf.Clamp(facialIndex, 0, 27));
        face.SetCheek(Mathf.Clamp(cheekLevel, 0, 2));
    }

    public void SetSpeaking(bool value)
    {
        if (face == null) return;
        if (speaking == value) return;
        speaking = value;
        face.SetSinging(value);
        if (!value) face.SetLip(54); // native mute lip code: ConvLip(54) = -1
    }

    private void Update()
    {
        if (face == null) return;
        TickBlink();
        if (!speaking) return;
        lipFrame++;
        if (lipFrame < 4) return;
        lipFrame = 0;
        lipIndex = (lipIndex + 1) % LipCycle.Length;
        face.SetLip(LipCycle[lipIndex]);
    }

    private void TickBlink()
    {
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
