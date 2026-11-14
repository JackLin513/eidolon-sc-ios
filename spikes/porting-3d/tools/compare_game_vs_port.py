#!/usr/bin/env python3
"""Compare the LIVE game's skirt-bone world rotations against the Unity port.

Inputs (both produced by the instrumented captures):
  game-rot.csv   columns: mgr,bone,qx,qy,qz,qw,px,py,pz,danceTime
                 captured from the running game via Frida by hooking
                 SwayManager.LateUpdate (0x1C817F0) and reading each bone
                 Transform's world rotation (the MT/Job physics result).
  unity-rot.csv  columns: motionT,mgr,bone,tipX..baseZ,qx,qy,qz,qw
                 produced by Assets/Scripts/SwayBoneLog.cs.

Usage:
  compare_game_vs_port.py <game-rot.csv> <unity-rot.csv> <gameMgrId> [--shift-search]

The game manager id is identified first by matching relative bone-position
trajectories (translation invariant); typically the median deviation drops to
~1 mm for the correct idol/position and stays >30 mm for the others.
"""
import bisect
import collections
import csv
import math
import sys


def load_game(path):
    out = collections.defaultdict(list)
    for r in csv.DictReader(open(path)):
        t = float(r["danceTime"])
        if t <= 0:
            continue
        out[(r["mgr"], int(r["bone"]))].append(
            (t,
             (float(r["qx"]), float(r["qy"]), float(r["qz"]), float(r["qw"])),
             (float(r["px"]), float(r["py"]), float(r["pz"]))))
    for k in out:
        out[k].sort()
    return out


def load_unity(path):
    out = collections.defaultdict(list)
    for r in csv.DictReader(open(path)):
        out[(r["mgr"], int(r["bone"]))].append(
            (float(r["motionT"]),
             (float(r["qx"]), float(r["qy"]), float(r["qz"]), float(r["qw"])),
             (float(r["baseX"]), float(r["baseY"]), float(r["baseZ"]))))
    for k in out:
        out[k].sort()
    return out


_TS_CACHE = {}


def at(seq, t, tol=0.03):
    if not seq:
        return None
    key = id(seq)
    ts = _TS_CACHE.get(key)
    if ts is None:
        ts = [x[0] for x in seq]
        _TS_CACHE[key] = ts
    i = bisect.bisect_left(ts, t)
    best = None
    for j in (i - 1, i):
        if 0 <= j < len(seq) and (best is None or abs(ts[j] - t) < abs(ts[best] - t)):
            best = j
    if best is None or abs(ts[best] - t) > tol:
        return None
    return seq[best]


def angle_deg(a, b):
    d = abs(sum(x * y for x, y in zip(a, b)))
    return math.degrees(2 * math.acos(min(1.0, d)))


def identify(game, unity, mgr):
    """Relative-position trajectory match (translation invariant)."""
    best = None
    for shift_i in range(-25, 26):
        shift = shift_i * 0.2
        devs = []
        for t in [x[0] for x in unity[("skirt_GP", 0)]][::5]:
            u0 = at(unity[("skirt_GP", 0)], t)
            g0 = at(game[(mgr, 0)], t + shift)
            if u0 is None or g0 is None:
                continue
            for b in range(1, 20):
                ub = at(unity[("skirt_GP", b)], t)
                gb = at(game[(mgr, b)], t + shift)
                if ub is None or gb is None:
                    continue
                du = (ub[2][0] - u0[2][0], ub[2][1] - u0[2][1], ub[2][2] - u0[2][2])
                dg = (gb[2][0] - g0[2][0], gb[2][1] - g0[2][1], gb[2][2] - g0[2][2])
                devs.append(math.dist(du, dg))
            if len(devs) > 200:
                break
        if len(devs) > 50:
            d = sorted(devs)[len(devs) // 2]
            if best is None or d < best[1]:
                best = (shift, d, len(devs))
    return best


def compare(game, unity, mgr, shift):
    per_bone = collections.defaultdict(list)
    per_time = collections.defaultdict(list)
    for b in range(20):
        for us in unity[("skirt_GP", b)][::2]:
            gs = at(game[(mgr, b)], us[0] + shift)
            if gs is None:
                continue
            a = angle_deg(gs[1], us[1])
            per_bone[b].append(a)
            per_time[round(us[0], 1)].append(a)
    return per_bone, per_time


def main():
    game_path, unity_path, mgr = sys.argv[1], sys.argv[2], sys.argv[3]
    game, unity = load_game(game_path), load_unity(unity_path)
    if len(sys.argv) > 4:                      # known shift: skip the slow identification
        shift = float(sys.argv[4])
        print(f"using known shift {shift:+.2f}s for game mgr {mgr}")
    else:
        ident = identify(game, unity, mgr)
        shift = ident[0]
        print(f"identity match for game mgr {mgr}: shift={shift:+.2f}s "
              f"median relative-position deviation={ident[1]*1000:.1f} mm")
    per_bone, per_time = compare(game, unity, mgr, shift)
    allv = sorted(v for vals in per_bone.values() for v in vals)
    n = len(allv)
    print(f"world-rotation deviation: n={n} median={allv[n//2]:.2f}° "
          f"p90={allv[int(n*0.9)]:.2f}° p99={allv[int(n*0.99)]:.2f}° max={allv[-1]:.2f}°")
    times = sorted(per_time)
    worst = sorted(times, key=lambda t: -sum(per_time[t]) / len(per_time[t]))[:10]
    print("worst moments:")
    for t in worst:
        v = per_time[t]
        print(f"  t={t:6.1f}s mean={sum(v)/len(v):6.2f}° max={max(v):6.2f}°")


if __name__ == "__main__":
    main()
