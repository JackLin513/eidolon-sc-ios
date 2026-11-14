using System;

/// <summary>
/// Native replica of the game's <c>Imas.TransitionModule</c> (dump.cs
/// TypeDefIndex 9606), the little cross-fade state machine <c>Imas.FaceCtrl</c>
/// keeps five of: facial expression, eye close, lip, cheek and mute-lip.
///
/// Source of truth, all RVAs in the 2026-10 <c>UnityFramework</c> binary and
/// 1:1 with <c>dump.cs</c>:
/// <list type="bullet">
/// <item><c>.ctor(float _transTime, int initKind)</c> @0x379E03C</item>
/// <item><c>Init(int initKind)</c> @0x379E93C</item>
/// <item><c>Set(int kind)</c> @0x379F508</item>
/// <item><c>SetDirect(int kind)</c> @0x379F5C0</item>
/// <item><c>Finish()</c> @0x37A1864</item>
/// <item><c>Progress(float deltaTime)</c> @0x379FCA0</item>
/// </list>
///
/// Field layout follows the native object one-for-one (offsets are the IL2CPP
/// field offsets):
/// <code>
///   public  int   last;      // 0x10
///   public  int   cur;       // 0x14
///   public  float ratio;     // 0x18
///   private float timer;     // 0x1C
///   private float transTime; // 0x20
///   public  bool  updated;   // 0x24
/// </code>
/// The native class is a plain object, not a MonoBehaviour; keep it that way.
/// Only performance-layer substitutions are made (none, actually — it is four
/// floats and two ints).
/// </summary>
public sealed class TransitionModuleNative
{
    // ---- native fields, same order/offsets ---------------------------------

    /// <summary>Kind the transition started from (native <c>last</c>, 0x10).</summary>
    public int last;

    /// <summary>Kind the transition is heading to (native <c>cur</c>, 0x14).</summary>
    public int cur;

    /// <summary>Eased progress 0..1, recomputed by <see cref="Progress"/> and read by the owner (0x18).</summary>
    public float ratio;

    /// <summary>Remaining time in seconds (native <c>timer</c>, 0x1C).</summary>
    public float timer;

    /// <summary>Full transition duration in seconds (native <c>transTime</c>, 0x20).</summary>
    public float transTime;

    /// <summary>
    /// "A change happened since the owner last composed its buffers"
    /// (native <c>updated</c>, 0x24). The owner must clear it after composing.
    /// </summary>
    public bool updated;

    /// <summary>
    /// <c>TransitionModule..ctor</c> @0x379E03C.
    /// Native signature is <c>(float _transTime, int initKind)</c>; the
    /// decompiler prints the two arguments in the opposite order because of
    /// how the float travels in s0.
    /// </summary>
    public TransitionModuleNative(float _transTime, int initKind)
    {
        // 0x379E03C: Init(this, initKind) then transTime = _transTime.
        transTime = _transTime;
        last = initKind;
        cur = initKind;
        ratio = 0f;
        timer = 0f;
        updated = false;
    }

    /// <summary><c>TransitionModule.Init</c> @0x379E93C: snap to one kind, idle.</summary>
    public void Init(int initKind)
    {
        last = initKind;
        cur = initKind;
        ratio = 0f;
        timer = 0f;
        updated = false;
    }

    /// <summary>
    /// <c>TransitionModule.Set</c> @0x379F508. Starts a cross-fade from the
    /// current kind to <paramref name="kind"/>; a repeated Set of the kind
    /// already being targeted does nothing (native compares against <c>cur</c>,
    /// so a half-finished transition is not restarted).
    /// </summary>
    public void Set(int kind)
    {
        if (cur == kind) return;
        // 0x379F508: `if (cur != last) last = cur;` — a second Set in the
        // middle of a transition keeps the original start kind.
        if (cur != last) last = cur;
        timer = transTime;
        cur = kind;
        ratio = 0f;
        updated = true;
    }

    /// <summary><c>TransitionModule.SetDirect</c> @0x379F5C0: snap, no fade.</summary>
    public void SetDirect(int kind)
    {
        last = kind;
        cur = kind;
        ratio = 0f;
        timer = 0f;
        updated = true;
    }

    /// <summary><c>TransitionModule.Finish</c> @0x37A1864: jump to the target now.</summary>
    public void Finish()
    {
        last = cur;
        timer = 0f;
        ratio = 0f;
        updated = true;
    }

    /// <summary>
    /// <c>TransitionModule.Progress</c> @0x379FCA0. Advances the timer by
    /// <paramref name="deltaTime"/> and recomputes <see cref="ratio"/>.
    ///
    /// Return value copies the native one: the input delta time when the
    /// module is idle, <c>0</c> on the frame the transition completes, and
    /// <c>1 - timer / transTime</c> while fading. <c>FaceCtrl.Action</c>
    /// ignores it; it is kept so a probe can compare bit-for-bit.
    /// </summary>
    public float Progress(float deltaTime)
    {
        if (timer == 0f) return deltaTime;

        timer -= deltaTime;
        if (timer <= 0f)
        {
            timer = 0f;
            last = cur;
            ratio = 0f;
            updated = true;
            return 0f;
        }

        ratio = 1f - timer / transTime;
        updated = true;
        return ratio;
    }

    public override string ToString()
    {
        return "TransitionModule(last=" + last + ", cur=" + cur + ", ratio=" + ratio.ToString("F3")
               + ", timer=" + timer.ToString("F3") + ", transTime=" + transTime.ToString("F3")
               + (updated ? ", updated)" : ")");
    }
}
