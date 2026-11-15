#!/usr/bin/env python3
"""Build the in-app story theatre demo from the extracted MLTD story data.

Inputs come from the offline extraction pipeline (``~/mltd-work``):

* ``out/story-extract/scenes.json`` — one entry per story with the timed lines,
  the pose/facial/gesture events and the text key of every line (built by
  ``build_story_scenes.py``).
* ``out/story-extract/audio/<story>/<key>.m4a`` — decoded voices (one clip per
  text key, decoded by ``decode_story_voices.py`` with vgmstream).
* ``out/poses/com_<variant>_<pose>_<action>.motion.json`` — the decoded commu
  pose clips (``export_pose_library.py``).

Output goes to ``build/Unity3DContent/stories``:

    index.json                     story list + shared pose library
    motions/<clip>_<action>.tsv    flat 30 fps motion the Unity player reads
    <story>/story.json             timed playback script
    <story>/audio/<key>.m4a        voices

Usage::

    python3 tools/build_story_demo.py \
        --stories job_story_001har_3000,job_story_001har_4000

Nothing here is committed: ``build/`` is ignored.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPIKE = REPO / "spikes" / "porting-3d"
WORK = Path.home() / "mltd-work"

# Story scripts count frames at 60 fps (verified against the decoded voices:
# line 9002 ends at frame 643 and its voice is 10.73 s -> 59.9 fps).
STORY_FPS = 60
# The game prints the producer's own name through `{$PS}`; the app has no player-name
# macro, so the extracted lines substitute the neutral label the subtitle already uses.
PLAYER_NAME_MACROS = ("{$P$}", "$P$", "{$PS}", "$PS")

def replace_macros(text: str) -> str:
    for macro in PLAYER_NAME_MACROS:
        text = text.replace(macro, "制作人")
    return text


sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_mltd_3d_packages import NAMES  # noqa: E402  (character id -> Chinese name)

VARIANTS = ("cut", "col", "pas", "sit")
LOOP_ACTIONS = ("lop", "act")

# The game hardcodes five switch poses in `CharacterActorCommu.create_pose_infos`
# (`CreateSwitch("a10","p11")`, `("a12","p13")`, `("a14","p15")`, `("a16","p17")`,
# `("a21","p22")` — confirmed from the decompiled `CreateSwitch` call sites and the
# literal table in script.json); `PoseInfo.switch_from/switch_to` mark them, and
# `override_pose_clip` builds the clip name from the *source* pose, so the `_swt`
# clip is `com_<variant>_<source>_swt` (`a16` -> `com_cut_16a_swt`) and playback
# lands on the target pose's loop.
SWITCH_POSES = {"a10_p11", "a12_p13", "a14_p15", "a16_p17", "a21_p22"}
GESTURE_ACTIONS = ("yes", "noo")

# facialMenu index -> StandEmotion (the model3d manifest emotion map).
MENU_EMOTIONS = {
    0: "calm",
    5: "happy",
    4: "shy",
    13: "surprised",
    19: "sad",
    17: "angry",
    11: "thinking",
}


def log(message: str) -> None:
    print(message, flush=True)


def audio_duration(path: Path) -> float:
    """Duration in seconds; ffprobe is the only dependency we already have."""
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        return float(result.stdout.strip())
    except ValueError:
        return 0.0


def load_pose_sets(path: Path) -> dict[str, dict[str, str]]:
    """character -> {pose name -> letter variant} from the commu pose masterdata."""
    data = json.loads(path.read_text())
    names = data["sets"]["means"][2:]
    table: dict[str, dict[str, str]] = {}
    for row in data["sets"]["sets"]:
        values = row["vals"]
        idol = values[0].removeprefix("set_")
        table[idol] = {name: letter for name, letter in zip(names, values[2:]) if letter}
    return table


class PoseLibrary:
    """Resolves story pose names to the game's commu pose clips."""

    def __init__(self, poses_dir: Path, letters: dict[str, dict[str, str]]) -> None:
        self.poses_dir = poses_dir
        self.letters = letters
        self._available: dict[str, set[str]] = {}
        for file in poses_dir.glob("com_*_*.motion.json"):
            clip_name = file.name.removesuffix(".motion.json")
            match = re.match(r"com_(cut|col|pas|sit)_(\w+?)_(act|yes|noo|str|lop|end|swt)$", clip_name)
            if match:
                clip = f"{match.group(1)}_{match.group(2)}"
            else:
                # Per-idol clips (`com_001har_18y_act`) are the character's own standing
                # set. `p18_*` story poses resolve to this family: the commu pose
                # masterdata has no `p18` column, and the game's own pose list
                # (global-metadata) names `p18_a/p18_e…/p18_p/p18_s` as one family.
                match = re.match(r"com_([0-9a-z]+)_(18[a-z])_(act|yes|noo|str|lop|end|swt)$", clip_name)
                if not match:
                    continue
                clip = f"{match.group(1)}_{match.group(2)}"
            self._available.setdefault(clip, set()).add(match.group(3))
        self._cache: dict[tuple[str, str, str | None], str | None] = {}

    def _candidates(self, idol: str, pose: str, variant: str | None = None) -> list[str]:
        base = pose.split("_")[0]
        digits = re.sub(r"\D", "", base)
        if not digits:
            return []
        letters = self.letters.get(idol, {})
        preferred = letters.get(base, "")
        order = ([preferred] if preferred else []) + list("abcdz")
        seen: list[str] = []
        for letter in order:
            if not letter or letter in seen:
                continue
            seen.append(letter)
        numbers = f"{int(digits):02d}" if len(digits) <= 2 else digits
        ids: list[str] = []
        for letter in seen:
            ids.append(f"{numbers}{letter}")
        clip_ids: list[str] = []
        for variant in ([variant] if variant else VARIANTS):
            for pose_id in ids:
                clip = f"{variant}_{pose_id}"
                if clip in self._available and clip not in clip_ids:
                    clip_ids.append(clip)
        return clip_ids

    def resolve(self, idol: str, pose: str, variant: str | None = None) -> str | None:
        key = (idol, pose, variant)
        if key in self._cache:
            return self._cache[key]
        # `p18_*` is the character's own standing set, not a commu pose: the pose
        # masterdata has no `p18` column, and the metadata pose list names it as
        # `p18_a/p18_e/p18_p/p18_s` (one family, letter = body variant).
        if pose.split("_")[0].startswith("p18"):
            chosen = self.base_clip(idol)
            self._cache[key] = chosen
            return chosen
        candidates = self._candidates(idol, pose, variant)
        chosen = candidates[0] if candidates else None
        self._cache[key] = chosen
        return chosen

    def actions(self, clip: str) -> set[str]:
        return self._available.get(clip, set())

    def base_clip(self, idol: str) -> str | None:
        """The per-idol "private pose" (`p18*`) clip.

        Most idols ship `18y` with only `_str/_lop/_end/_yes/_noo`; a few also have
        `_act`. Either loop works, so accept both instead of dropping the event.
        """
        clip = f"{idol}_18y"
        actions = self.actions(clip)
        return clip if ("lop" in actions or "act" in actions) else None


def write_flat(dest: Path, packed_path: Path) -> None:
    sys.path.insert(0, str(SPIKE))
    import export_daily_motions  # noqa: PLC0415

    packed = json.loads(packed_path.read_text())
    export_daily_motions.write_flat(dest, packed)


LIP_FPS = 30


def safe_int(value, default: int = 0) -> int:
    """Parse a script argument that may be None, "" or a non-numeric label."""
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def sample_lip(points: list[dict[str, object]] | None) -> list[float]:
    """Resample the game's 60 fps mouth envelope to 30 fps for the web of TSV-era
    players; `t` is a frame index from the start of the voice clip and `v` is the
    authored mouth opening (0..1)."""
    if not points:
        return []
    samples: list[float] = []
    for index in range(0, len(points), STORY_FPS // LIP_FPS):
        samples.append(round(float(points[index].get("v") or 0.0), 3))
    return samples



def copy_backgrounds(args: argparse.Namespace, story_ids: list[str], out: Path) -> int:
    """Copy every referenced `adv_bg2d_*` JPEG next to the stories, plus the index."""
    source: Path = args.backgrounds
    if not source.is_dir():
        return 0
    wanted: set[str] = set()
    for story_id in story_ids:
        story_path = out / story_id / "story.json"
        if not story_path.exists():
            continue
        story = json.loads(story_path.read_text())
        for line in story.get("lines", []):
            for event in line.get("backgrounds", []) or []:
                identifier = str(event.get("id") or "")
                if identifier:
                    wanted.add(identifier)
    target = out / "backgrounds"
    target.mkdir(parents=True, exist_ok=True)
    copied = 0
    for identifier in sorted(wanted):
        source_file = source / f"{identifier}.jpg"
        if not source_file.exists():
            continue
        destination = target / source_file.name
        if not destination.exists() or destination.stat().st_size != source_file.stat().st_size:
            shutil.copyfile(source_file, destination)
            copied += 1
    index = source / "index.json"
    if index.exists():
        shutil.copyfile(index, target / "index.json")
    return copied

def build(args: argparse.Namespace) -> int:
    scenes = json.loads(args.scenes.read_text())
    lips = json.loads(args.lips.read_text()).get("stories", {}) if args.lips.exists() else {}
    letters = load_pose_sets(args.pose_set)
    library = PoseLibrary(args.poses, letters)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    motions = out / "motions"
    motions.mkdir(exist_ok=True)

    story_ids = [piece.strip() for piece in args.stories.split(",") if piece.strip()]
    if not story_ids:
        story_ids = sorted(scenes)

    index: dict[str, object] = {"version": 1, "format": "eidolon.story/1", "fps": STORY_FPS, "stories": []}
    written: dict[str, str] = {}
    missing_loops = 0

    def ship(clip: str, action: str) -> str | None:
        """Write `com_<clip>_<action>.motion.json` as a 30 fps TSV once, return its name."""
        name = f"{clip}_{action}"
        if name in written:
            return name
        source = args.poses / f"com_{clip}_{action}.motion.json"
        if not source.exists():
            return None
        write_flat(motions / f"{name}.tsv", source)
        written[name] = f"motions/{name}.tsv"
        return name

    for story_id in story_ids:
        scene = scenes.get(story_id)
        if scene is None:
            log(f"{story_id}: not in {args.scenes}; skipping")
            continue
        idol = scene["character"]
        base = library.base_clip(idol)
        story_dir = out / story_id
        (story_dir / "audio").mkdir(parents=True, exist_ok=True)

        story_lips = lips.get(story_id, {})
        lines: list[dict[str, object]] = []
        for line in scene["lines"]:
            key = line["key"]
            line_speaker = line.get("speaker") or ""
            speaker_name = "制作人" if line_speaker == "p" else NAMES.get(line_speaker, line_speaker)
            voice_src = args.audio / story_id / f"{key}.m4a"
            voice_rel = None
            duration = 0.0
            if voice_src.exists():
                shutil.copy2(voice_src, story_dir / "audio" / f"{key}.m4a")
                voice_rel = f"{story_id}/audio/{key}.m4a"
                duration = audio_duration(voice_src)

            poses: list[dict[str, object]] = []
            for event in line.get("poses", []):
                pose_name = str(event["pose"])
                enter: str | None = None
                if pose_name in SWITCH_POSES:
                    # A switch pose is a transition, not a stance: the authored clip is
                    # the source pose's `_swt`, and it lands on the target's `_lop`.
                    source_name, target_name = pose_name.split("_")
                    source_clip = library.resolve(idol, source_name)
                    target_clip = library.resolve(idol, target_name)
                    clip = target_clip or source_clip or base
                    if source_clip and "swt" in library.actions(source_clip) and ship(source_clip, "swt"):
                        enter = f"swt:{source_clip}"
                    else:
                        log(f"{story_id}: switch {pose_name} has no _swt for {source_clip}; using {clip}")
                elif pose_name.startswith("p18_e"):
                    # `p18_e01..08` are the private `priv_etc` slots. Their clips live in
                    # the character-specific UniqueMotionSet (`chr_anim_com_umset_*`),
                    # which only exists for the special 101kot/102mis actors.
                    log(f"{story_id}: {pose_name} needs a umset bundle; standing in {base}")
                    clip = base
                elif pose_name.startswith("p18_s"):
                    clip = base
                    if base and "swt" in library.actions(base) and ship(base, "swt"):
                        enter = f"swt:{base}"
                elif pose_name.startswith("p18_a"):
                    clip = base
                    if base and "act" in library.actions(base) and ship(base, "act"):
                        enter = "act"
                else:
                    clip = library.resolve(idol, pose_name)
                if clip is None:
                    missing_loops += 1
                    log(f"{story_id}: pose {pose_name} unresolved; falling back to {base}")
                    clip = base
                if clip is None:
                    continue
                actions = library.actions(clip)
                loop_action = next((action for action in LOOP_ACTIONS if action in actions), None)
                if loop_action is None:
                    # No `lop`: the only clip is a one-shot `act` gesture. It is still
                    # shipped, and the player freezes it on the pose instead of looping
                    # the raise-and-drop.
                    loop_action = "act"
                loop_name = ship(clip, loop_action)
                if loop_name is None:
                    log(f"{story_id}: {clip}_{loop_action} missing; using {base}")
                    if base is None:
                        continue
                    clip = base
                    actions = library.actions(clip)
                    loop_action = next((action for action in LOOP_ACTIONS if action in actions), None) or "act"
                    loop_name = ship(clip, loop_action)
                    if loop_name is None:
                        continue
                # The game enters a pose through an authored clip and then loops it:
                # `_start` (`str`) normally, `_switch` (`swt`) for switch poses and
                # `_action` (`act`) for private actions. `_end` is the pose's authored
                # exit; shipping it lets the player leave the pose the way the game does.
                if enter is None and "str" in actions:
                    ship(clip, "str")
                if "end" in actions:
                    ship(clip, "end")
                for gesture in GESTURE_ACTIONS:
                    if gesture in actions:
                        ship(clip, gesture)
                ms = round(event["start"] * 1000 / STORY_FPS)
                poses.append({
                    "ms": ms,
                    "clip": loop_name,
                    "pose": pose_name,
                    # ADV pose type: the game calls SetPose(name, loopDirect: true)
                    # and skips the `_start` clip for these (ADVPoseLogic.Execute).
                    "loopDirect": bool(event.get("direct")),
                    "enter": enter,
                })

            faces: list[dict[str, object]] = []
            for event in line.get("faces", []):
                menu = int(event.get("menu", -1))
                # The script names the native facialMenu row (0..27). Pass it through
                # untouched — mapping down to seven moods dropped every other authored
                # expression and left the previous face on screen.
                if not 0 <= menu < 28:
                    continue
                faces.append({
                    "ms": round(event["frame"] * 1000 / STORY_FPS),
                    "emotion": MENU_EMOTIONS.get(menu),
                    "menu": menu,
                })
            gestures: list[dict[str, object]] = []
            for event in line.get("gestures", []):
                # The scene script writes the gesture as `type` (yes/no); the older
                # extractor named it `kind`. Accept both.
                raw = event.get("type") or event.get("kind") or ""
                kind = "yes" if raw == "yes" else "noo"
                gestures.append({"ms": round(event["start"] * 1000 / STORY_FPS), "kind": kind})
            cheeks: list[dict[str, object]] = []
            for event in line.get("cheeks", []):
                cheeks.append({"ms": round(event["frame"] * 1000 / STORY_FPS), "level": int(event.get("level", 0))})
            # The ADV script drives the eyes explicitly (EyeblinkActor ->
            # CharacterActorBase.SetEyeMode) and the gaze (EyeDirectionActor ->
            # SetEyeDirectionByRate). Only `close`/`open`/`blink` are valid modes.
            eyes: list[dict[str, object]] = []
            for event in line.get("eyes", []):
                mode = str(event.get("mode") or "")
                if mode not in ("close", "open", "blink"):
                    continue
                eyes.append({"ms": round(event["frame"] * 1000 / STORY_FPS), "mode": mode})
            gazes: list[dict[str, object]] = []
            for event in line.get("gazes", []):
                try:
                    h = int(event.get("h"))
                    v = int(event.get("v"))
                except (TypeError, ValueError):
                    continue
                gazes.append({"ms": round(event["frame"] * 1000 / STORY_FPS), "h": h, "v": v})

            def at(frame):
                return round(safe_int(frame) * 1000 / STORY_FPS)

            def span(start, end):
                return at(start), at(end)

            # Scene staging commands.  Each list is a small typed event record the
            # host replays on the same clock as poses/faces (`ms` in story ms).
            visibility: list[dict[str, object]] = []
            for event in line.get("visibility", []):
                state = str(event.get("on") or "").lower()
                if state not in ("on", "off", "true", "false", "1", "0"):
                    continue
                visibility.append(
                    {
                        "ms": at(event.get("start")),
                        "idol": str(event.get("idol") or ""),
                        "on": state in ("on", "true", "1"),
                    }
                )
            cameras = [
                {"ms": at(event.get("frame")), "preset": str(event.get("preset") or "")}
                for event in line.get("cameras", [])
                if event.get("preset")
            ]
            places = [
                {
                    "ms": at(event.get("frame")),
                    "idol": str(event.get("idol") or ""),
                    "preset": str(event.get("preset") or ""),
                    "location": safe_int(event.get("location")),
                }
                for event in line.get("places", [])
                if event.get("preset")
            ]
            backgrounds: list[dict[str, object]] = []
            for event in line.get("backgrounds", []):
                bgid = str(event.get("id") or "")
                if not bgid:
                    continue
                backgrounds.append(
                    {
                        "ms": at(event.get("frame")),
                        "id": bgid,
                        "fadeIn": str(event.get("fadeIn") or "").lower() in ("on", "1", "true"),
                        "fadeOut": str(event.get("fadeOut") or "").lower() in ("on", "1", "true"),
                    }
                )
            loads = [
                {
                    "ms": at(event.get("start")),
                    "idol": str(event.get("idol") or ""),
                    "model": str(event.get("model") or ""),
                    "costume": str(event.get("costume") or ""),
                    "setId": safe_int(event.get("setId")),
                }
                for event in line.get("loads", [])
            ]
            costumes = [
                {
                    "ms": at(event.get("start")),
                    "idol": str(event.get("idol") or ""),
                    "setId": safe_int(event.get("setId")),
                }
                for event in line.get("costumes", [])
            ]
            rotations: list[dict[str, object]] = []
            for event in line.get("rotations", []):
                start_ms, end_ms = span(event.get("start"), event.get("end"))
                rotations.append(
                    {
                        "ms": start_ms,
                        "endMs": end_ms,
                        "idol": str(event.get("idol") or ""),
                        "x": float(event.get("x") or 0.0),
                        "y": float(event.get("y") or 0.0),
                        "z": float(event.get("z") or 0.0),
                        "ease": str(event.get("ease") or ""),
                        "mode": str(event.get("mode") or ""),
                    }
                )
            offsets: list[dict[str, object]] = []
            for event in line.get("offsets", []):
                start_ms, end_ms = span(event.get("start"), event.get("end"))
                offsets.append(
                    {
                        "ms": start_ms,
                        "endMs": end_ms,
                        "idol": str(event.get("idol") or ""),
                        "x": float(event.get("x") or 0.0),
                        "y": float(event.get("y") or 0.0),
                        "z": float(event.get("z") or 0.0),
                    }
                )
            fades: list[dict[str, object]] = []
            for event in line.get("fades", []):
                start_ms, end_ms = span(event.get("start"), event.get("end"))
                kind = str(event.get("type") or "")
                if not kind:
                    continue
                fades.append({"ms": start_ms, "endMs": end_ms, "type": kind})
            inouts: list[dict[str, object]] = []
            for event in line.get("inouts", []):
                start_ms, end_ms = span(event.get("start"), event.get("end"))
                inouts.append(
                    {
                        "ms": start_ms,
                        "endMs": end_ms,
                        "idol": str(event.get("idol") or ""),
                        "name": str(event.get("name") or ""),
                        "speed": float(event.get("speed") or 0.0),
                    }
                )
            sits: list[dict[str, object]] = []
            for event in line.get("sits", []):
                start_ms, end_ms = span(event.get("start"), event.get("end"))
                pose = str(event.get("pose") or "")
                # `actor_sit_pose` puts the character into the seated variant of that
                # pose (`sit` in the pose masterdata). The seated clips are shared by
                # every idol and keyed `sit_<number><letter>` (01z, 02a..17c), so pick
                # the first shipped variation of that pose instead of clamping it.
                sit_clip = None
                head = pose.split("_")[0]
                sit_number = re.sub(r"^[pa]", "", head)
                # The seated variants are keyed by the idol's own letter in
                # `set_sit_<idol>`; guessing a letter bends the wrong body type and
                # the hands end up inside the skirt.
                sit_idol = str(event.get("idol") or scene.get("character") or "")
                sit_table = library.letters.get(f"sit_{sit_idol}") or {}
                preferred = sit_table.get(pose) or sit_table.get(head) or ""
                order = ([preferred] if preferred else []) + ["a", "b", "c", "d", "z"]
                if sit_number.isdigit():
                    for letter in dict.fromkeys(order):
                        candidate = f"sit_{int(sit_number):02d}{letter}"
                        if "lop" in library.actions(candidate) or "act" in library.actions(candidate):
                            sit_clip = candidate
                            break
                if sit_clip is None:
                    sit_clip = library.resolve(sit_idol, "p01", variant="sit")
                if sit_clip:
                    sit_loop = ship(sit_clip, "lop") or ship(sit_clip, "act")
                    if sit_loop:
                        poses.append(
                            {
                                "ms": start_ms,
                                "clip": sit_loop,
                                "pose": f"sit:{pose}",
                                "loopDirect": False,
                                "enter": "str" if ship(sit_clip, "str") else None,
                            }
                        )
                sits.append(
                    {
                        "ms": start_ms,
                        "endMs": end_ms,
                        "idol": str(event.get("idol") or ""),
                        "pose": pose,
                        "direct": str(event.get("direct") or "0") == "1",
                    }
                )
            lip_events: list[dict[str, object]] = []
            for event in line.get("lips", []):
                mode = str(event.get("mode") or "")
                if mode not in ("Close", "Fomalhout"):
                    continue
                lip_events.append({"ms": at(event.get("start")), "mode": mode})
            sounds = [
                {
                    "ms": at(event.get("frame")),
                    "kind": str(event.get("kind") or ""),
                    "op": str(event.get("op") or ""),
                    "sheet": str(event.get("sheet") or ""),
                    "name": str(event.get("name") or ""),
                }
                for event in line.get("sounds", [])
            ]

            lines.append(
                {
                    "cut": line["cut"],
                    "speaker": line["speaker"],
                    "speakerName": speaker_name,
                    "key": key,
                    "ja": replace_macros(line["ja"]),
                    "startFrame": line["start"],
                    "endFrame": line["end"],
                    "scriptMs": round((line["end"] - line["start"]) * 1000 / STORY_FPS),
                    "voiceMs": round(duration * 1000),
                    "voice": voice_rel,
                    "lipFps": LIP_FPS,
                    "lip": sample_lip(story_lips.get(key)),
                    "poses": poses,
                    "faces": faces,
                    "gestures": gestures,
                    "cheeks": cheeks,
                    "eyes": eyes,
                    "gazes": gazes,
                    "visibility": visibility,
                    "cameras": cameras,
                    "places": places,
                    "backgrounds": backgrounds,
                    "loads": loads,
                    "costumes": costumes,
                    "rotations": rotations,
                    "offsets": offsets,
                    "fades": fades,
                    "inouts": inouts,
                    "sits": sits,
                    "lips": lip_events,
                    "sounds": sounds,
                }
            )

        story = {
            "id": story_id,
            "character": idol,
            "situation": scene.get("situation") or "",
            "place": scene.get("place") or "",
            "fps": STORY_FPS,
            "lipFps": LIP_FPS,
            "lines": lines,
        }
        (story_dir / "story.json").write_text(json.dumps(story, ensure_ascii=False, indent=1))
        index["stories"].append(
            {
                "id": story_id,
                "character": idol,
                "situation": story["situation"],
                "lines": len(lines),
                "durationMs": sum(max(line["voiceMs"], line["scriptMs"]) for line in lines),
                "story": f"{story_id}/story.json",
            }
        )
        log(f"{story_id}: {len(lines)} lines, {len({pose['clip'] for line in lines for pose in line['poses']})} clips")

    (out / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=1))
    total = sum(path.stat().st_size for path in motions.glob("*.tsv"))
    copied = copy_backgrounds(args, story_ids, out)
    log(f"wrote {out} — {len(written)} motion files ({total / 1e6:.1f} MB), {missing_loops} pose fallbacks")
    if copied:
        log(f"copied {copied} adv backgrounds into {out / 'backgrounds'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenes", type=Path, default=WORK / "out" / "story-extract" / "scenes.json")
    parser.add_argument("--audio", type=Path, default=WORK / "out" / "story-extract" / "audio")
    parser.add_argument("--poses", type=Path, default=WORK / "out" / "poses")
    parser.add_argument("--pose-set", type=Path, default=WORK / "chara_commu_pose_set.json")
    parser.add_argument("--lips", type=Path, default=WORK / "out" / "story-extract" / "lips.json")
    parser.add_argument(
        "--backgrounds",
        type=Path,
        default=WORK / "out" / "backgrounds",
        help="exported adv_bg2d_* JPEGs (see ~/mltd-work/export_backgrounds.py)",
    )
    parser.add_argument("--out", type=Path, default=REPO / "build" / "Unity3DContent" / "stories")
    parser.add_argument("--stories", default="")
    args = parser.parse_args(argv)
    return build(args)


if __name__ == "__main__":
    raise SystemExit(main())
