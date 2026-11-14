// Native-faithful data types for the game's V01 sway solver (`Imas.BoneLib`).
//
// Field order, names and types mirror the Il2CppDumper dump.cs declarations of
//   SwayBoneMT.FixedParams            (dump.cs TypeDefIndex 15272, 0x00..0xEB)
//   SwayBoneMT.WorkingParams          (15273, 0x00..0x57)
//   SwayBoneMT.SideLinkParams         (15274, 0x00..0x23)
//   SwayBoneMT.ColliderParams         (15275, 0x00..0x6B)
//   SwayBoneMT.ColliderIndexParams    (15277, numOfColliders + int[16])
// and the enums used by them.
//
// The native assembly lives in SwayBoneMT (Burst jobs). ADR-0033 allows the
// performance layer to be replaced (NativeArray/TransformAccess -> arrays /
// Transform, jobs -> serial), so these structs are plain managed structs; the
// order is kept identical so the mapping can still be checked offset by offset
// against dump.cs and the IDA decompiles.
//
// Native mapping (World-space convention used by both implementations):
//   FixedParams  : static per bone, built by SwayBoneMT.InitializeFixedParams
//                  (0x1C69508) from SwayBone/SwayManager/JointBodyHead.
//   WorkingParams: per-frame state, world space. SwayBone.InitSub 0x1C711A4
//                  seeds it; SwayBoneMT.CopyFromWorkingParams 0x1C69DE8 writes
//                  curTip/prevTip/lastBase back to the SwayBone fields.
//   SideLinkParams: positions refreshed before the side-line pass
//                  (SwayBoneMT.UpdateSideLinkParams 0x1C69B50); cached here for
//                  the serial path.
//   ColliderParams: static geometry refreshed each frame by
//                  SwayColliderMT.ExecUpdate / SwayCollider.ExecUpdate
//                  (0x1C6A9E0 / 0x1C73FF0).

using System;
using System.Runtime.InteropServices;
using UnityEngine;

/// <summary>`SwayBone.swaycategory` (dump.cs TypeDefIndex 15297).</summary>
public enum SwayCategory
{
    Normal = 0,
    Hair = 1,
    Skirt = 2,
    Opai = 3,
    SideHair = 4,
}

/// <summary>`SwayBone.hittypes` (15298); the text data always writes Sphere.</summary>
public enum SwayHitType
{
    Sphere = 0,
    Line = 1,
}

/// <summary>`SwayBone.reftypes` (15299). The text data is `refParam: Self|Manager`.</summary>
public enum SwayRefType
{
    Manager = 0,
    Self = 1,
}

/// <summary>`SwayCollider.types` (15304).</summary>
public enum SwayColliderType
{
    Sphere = 0,
    Capsule = 1,
    Plane = 2,
    Bridge = 3,
}

/// <summary>`SwayCollider.typeaxis1` (15305), capsule axis.</summary>
public enum SwayColliderAxis
{
    X = 0,
    Y = 1,
    Z = 2,
}

/// <summary>`SwayCollider.typeaxis2` (15306), plane normal.</summary>
public enum SwayPlaneAxis
{
    plusX = 0,
    minusX = 1,
    plusY = 2,
    minusY = 3,
    plusZ = 4,
    minusZ = 5,
}

/// <summary>`SwayCollider.typeaxis3` (15307), plane clip.</summary>
public enum SwayClipPlane
{
    All = 0,
    Axis2ndPlus = 1,
    Axis2ndMinus = 2,
    Axis3rdPlus = 3,
    Axis3rdMinus = 4,
}

/// <summary>SwayBone.RecordParameter (15300), `Record()` snapshot, kept for parity.</summary>
[Serializable]
[StructLayout(LayoutKind.Sequential)]
public struct SwayRecordParameter
{
    public float minYAngle;      // 0x00
    public float maxYAngle;      // 0x04
    public float minZAngle;      // 0x08
    public float maxZAngle;      // 0x0C
    public float stiffnessForce; // 0x10
    public float dragForce;      // 0x14
    public Vector3 gravity;      // 0x18
    public float followForce;    // 0x24
}

/// <summary>
/// SwayBoneMT.FixedParams (TypeDefIndex 15272), 0xEC bytes in native layout.
/// Built by SwayBoneMT.InitializeFixedParams (0x1C69508) from
/// SwayBone (fields 0x2C..0x208) + SwayManager + JointBodyHead.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct SwayFixedParams
{
    public int swbIndex;                            // 0x00  ghidra a3->i32[0]
    public int sideLink;                            // 0x04  -1 = none
    public int sideLink2;                           // 0x08  -1 = none
    public int isSkirt;                             // 0x0C  bool as int
    public int useLinkHit;                          // 0x10  bool as int
    public float m_side_line_initial_dist;          // 0x14
    public float sideSpringTorelance;               // 0x18
    public float sideSpringForce;                   // 0x1C
    public Quaternion parentRotation;               // 0x20  world rotation of parent (rebuilt each frame)
    public int SkirtFallFollow;                     // 0x30
    public Vector3 side_tipPosition;                // 0x34  sideLink tip position (world)
    public Vector3 gravity;                         // 0x40
    public SwayCategory category;                   // 0x4C
    public Quaternion initialLocalRotation;         // 0x50
    public float followForce;                       // 0x60
    public float fallFollow;                        // 0x64
    public Vector3 aimVector;                       // 0x68  bind tip direction, normalised, bone-local
    public float stiffnessForce;                    // 0x74
    public float dragForce;                         // 0x78
    public float radius;                            // 0x7C  n_radius * bodyScale
    public float n_radius;                          // 0x80
    public Quaternion m_offset_rot;                 // 0x84  FromToRotation(aimVector, -right)
    public float minYAngle;                         // 0x94
    public float maxYAngle;                         // 0x98
    public float minZAngleTgt;                      // 0x9C  wing transition target
    public float maxZAngleTgt;                      // 0xA0
    public int limitAngle;                          // 0xA4  bool as int
    public Vector3 colliderOffset;                  // 0xA8
    public int HitMuteForce;                        // 0xB4  bool as int
    public float HitMuteRate;                       // 0xB8
    public float swayLength;                        // 0xBC
    public int hitTwice;                            // 0xC0  bool as int
    public int isWing;                              // 0xC4  bool as int
    public int hasSideLinkTipTrs;                   // 0xC8  sideLink != null
    public float sideAntiSpringForce;               // 0xCC
    public float sideAntiSpringTorelance;           // 0xD0
    public float antiFoldForceK;                    // 0xD4
    public float antiFoldAngleRad;                  // 0xD8  degrees -> radians
    public float resolveDepthFactor;                // 0xDC  default 0.9
    public Vector3 bodyScale;                       // 0xE0  BODY_SCALE local scale
}

/// <summary>
/// SwayBoneMT.WorkingParams (TypeDefIndex 15273), 0x58 bytes.
/// World-space per-frame state; the four passes read/write this record.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct SwayWorkingParams
{
    public Vector3 force;        // 0x00
    public int lineHitF;         // 0x0C  bool as int (useLinkHit pass)
    public int sphereHitF;       // 0x10  bool as int (point collider pass)
    public Vector3 skirtNormal;  // 0x14  rotation * Vector3.up
    public Vector3 skirtDir;     // 0x20  rotation * Vector3.right
    public float minZAngle;      // 0x2C  animated window (wing transitions toward *Tgt)
    public float maxZAngle;      // 0x30
    public Vector3 curTipPos;    // 0x34  world
    public Vector3 prevTipPos;   // 0x40  world
    public Vector3 lastBasePos;  // 0x4C  world position of the bone transform
}

/// <summary>
/// SwayBoneMT.SideLinkParams (TypeDefIndex 15274).
/// Refreshed before the side-line pass; sideLinkTipTrsPosition is the side
/// neighbour's first child world position (0x1C69B50).
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct SwaySideLinkParams
{
    public Vector3 tipTrsPosition;        // 0x00
    public Vector3 tipTrsLocalPosition;   // 0x0C
    public Vector3 sideLinkTipTrsPosition;// 0x18
}

/// <summary>
/// SwayBoneMT.ColliderParams (TypeDefIndex 15275), 0x6C bytes.
/// World geometry of one SwayCollider after ExecUpdate.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public struct SwayColliderParams
{
    public SwayColliderType type;        // 0x00
    public Vector3 m_w_center;           // 0x04
    public float n_radius;               // 0x10
    public float radius;                 // 0x14  n_radius * m_scale
    public float distance;               // 0x18
    public float m_scale;                // 0x1C
    public Vector3 offset;               // 0x20
    public float m_culling_r;            // 0x2C
    public int transformIndex;           // 0x30
    public int bridgetgtIndex;           // 0x34
    public SwayColliderAxis axis;        // 0x38
    public Vector3 m_w_dir;              // 0x3C
    public Quaternion planeRotQ;         // 0x48
    public int planeRotOn;               // 0x58
    public SwayPlaneAxis planeAxis;      // 0x5C
    public SwayClipPlane clipPlane;      // 0x60
    public int useSkirtBarrier;          // 0x64
    public float skirtGuardOffset;       // 0x68
}

/// <summary>
/// SwayBoneMT.ColliderIndexParams (TypeDefIndex 15277).
/// MAX_COLLIDERS = 16 in SwayBoneMT; index[] holds per-gathered-collider ids
/// for one sway bone. In the serial port the per-joint SwayColliderSet path is
/// resolved directly, but the structure is kept for offset-for-offset parity.
/// </summary>
public struct SwayColliderIndexParams
{
    public const int MAX_COLLIDERS = 16;

    public int numOfColliders;                 // 0x00
    public int[] index;                        // 0x04, fixed int[16]

    public static SwayColliderIndexParams Create()
    {
        var p = new SwayColliderIndexParams();
        p.index = new int[MAX_COLLIDERS];
        return p;
    }
}

/// <summary>
/// Native `SwayCollider.SIDE_LINE_R = 0.9f` (dump.cs). Used as the side-line
/// effective radius scale (research §3.3.1 / SwayCollider.CapsuleSideLineHit
/// 0x1C74EC4).
/// </summary>
public static class SwayConstants
{
    public const float FIXED_DELTA = 0.016666668f;   // SwayManager.FIXED_DELTA
    public const float MAX_DELTA = 0.025000002f;     // SwayManager.MAX_DELTA
    public const float WING_SPEED = 4f;              // SwayBone.WING_SPEED, degrees/frame
    public const float DEFAULT_RESOLVE_DEPTH_FACTOR = 0.9f;
    public const float SIDE_LINE_R = 0.9f;           // SwayCollider.SIDE_LINE_R
    public const int WIND_MAX = 4;                   // SwayManager.WIND_MAX
}

/// <summary>
/// Small helpers shared by the serial port. Math is kept in Unity types but
/// written in the same order as the native scalar code so cross-checking
/// against the decompile stays mechanical.
/// </summary>
public static class SwayNativeMath
{
    /// <summary>Native `Vector3.Normalize` with the game's 1e-5f guard.</summary>
    public static Vector3 NormalizeOrZero(Vector3 v, float epsilon = 0.00001f)
    {
        var sq = v.x * v.x + v.y * v.y + v.z * v.z;
        if (sq <= epsilon * epsilon) return Vector3.zero;
        var inv = 1f / Mathf.Sqrt(sq);
        return new Vector3(v.x * inv, v.y * inv, v.z * inv);
    }

    /// <summary>Native `Quaternion.Inverse(rot) * v`.</summary>
    public static Vector3 InverseTransformDirection(Quaternion rotation, Vector3 dir)
    {
        return Quaternion.Inverse(rotation) * dir;
    }

    /// <summary>Native TransformPoint(translation, rotation, scale, pos) (0x1C6A964).</summary>
    public static Vector3 TransformPoint(Vector3 translation, Quaternion rotation, Vector3 scale, Vector3 pos)
    {
        var scaled = new Vector3(pos.x * scale.x, pos.y * scale.y, pos.z * scale.z);
        return translation + rotation * scaled;
    }

    /// <summary>Native TransformDirection(rotation, dir) (0x1C6A9D8).</summary>
    public static Vector3 TransformDirection(Quaternion rotation, Vector3 dir)
    {
        return rotation * dir;
    }

    /// <summary>
    /// Native `Mathf.MoveTowards`-like wing transition used by SwayBoneMT.SwayMove
    /// (0x1C6867C, ±WING_SPEED per frame, exact clamp at target).
    /// </summary>
    public static float WingMoveTowards(float current, float target, float maxDelta)
    {
        if (current <= target)
        {
            if (current >= target) return target;
            var next = current + maxDelta;
            return next <= target ? next : target;
        }
        var down = current - maxDelta;
        return down >= target ? down : target;
    }
}
