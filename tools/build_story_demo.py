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
        self._cache: dict[tuple[str, str], str | None] = {}

    def _candidates(self, idol: str, pose: str) -> list[str]:
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
        for variant in VARIANTS:
            for pose_id in ids:
                clip = f"{variant}_{pose_id}"
                if clip in self._available and clip not in clip_ids:
                    clip_ids.append(clip)
        return clip_ids

    def resolve(self, idol: str, pose: str) -> str | None:
        key = (idol, pose)
        if key in self._cache:
            return self._cache[key]
        # `p18_*` is the character's own standing set, not a commu pose: the pose
        # masterdata has no `p18` column, and the metadata pose list names it as
        # `p18_a/p18_e/p18_p/p18_s` (one family, letter = body variant).
        if pose.split("_")[0].startswith("p18"):
            chosen = self.base_clip(idol)
            self._cache[key] = chosen
            return chosen
        candidates = self._candidates(idol, pose)
        chosen = candidates[0] if candidates else None
        self._cache[key] = chosen
        return chosen

    def actions(self, clip: str) -> set[str]:
        return self._available.get(clip, set())

    def base_clip(self, idol: str) -> str | None:
        """The per-idol idle used when a story pose has no loop clip in the cache."""
        clip = f"{idol}_18y"
        return clip if "act" in self.actions(clip) else None


def write_flat(dest: Path, packed_path: Path) -> None:
    sys.path.insert(0, str(SPIKE))
    import export_daily_motions  # noqa: PLC0415

    packed = json.loads(packed_path.read_text())
    export_daily_motions.write_flat(dest, packed)


LIP_FPS = 30


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
                clip = library.resolve(idol, event["pose"])
                if clip is None:
                    missing_loops += 1
                    log(f"{story_id}: pose {event['pose']} unresolved; falling back to {base}")
                    clip = base
                if clip is None:
                    continue
                actions = library.actions(clip)
                # The character's own 18-year set uses `act` as its standing idle;
                # commu pose sets use `lop` for the pose loop.
                order = ("act", "lop") if clip.endswith("_18y") else LOOP_ACTIONS
                loop_action = next((action for action in order if action in actions), None)
                if loop_action is None:
                    loop_action = "act"
                clip_file = f"{clip}_{loop_action}"
                if clip not in written:
                    source = args.poses / f"com_{clip}_{loop_action}.motion.json"
                    if not source.exists():
                        log(f"{story_id}: {source.name} missing; using {base}")
                        clip = base or clip
                        clip_file = f"{clip}_act"
                        actions = library.actions(clip)
                        source = args.poses / f"com_{clip}_act.motion.json"
                    if source.exists():
                        write_flat(motions / f"{clip_file}.tsv", source)
                        written[clip_file] = f"motions/{clip_file}.tsv"
                        # The game enters a pose through its `str` clip and loops it
                        # with `lop`; shipping both lets the player cross-fade through
                        # the authored transition instead of snapping between loops.
                        if "str" in actions:
                            intro_source = args.poses / f"com_{clip}_str.motion.json"
                            intro_name = f"{clip}_str"
                            if intro_source.exists() and intro_name not in written:
                                write_flat(motions / f"{intro_name}.tsv", intro_source)
                                written[intro_name] = f"motions/{intro_name}.tsv"
                        for gesture in GESTURE_ACTIONS:
                            if gesture in actions:
                                gesture_source = args.poses / f"com_{clip}_{gesture}.motion.json"
                                if gesture_source.exists():
                                    name = f"{clip}_{gesture}"
                                    if name not in written:
                                        write_flat(motions / f"{name}.tsv", gesture_source)
                                        written[name] = f"motions/{name}.tsv"
                ms = round(event["start"] * 1000 / STORY_FPS)
                poses.append({"ms": ms, "clip": clip_file, "pose": event["pose"]})

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
    log(f"wrote {out} — {len(written)} motion files ({total / 1e6:.1f} MB), {missing_loops} pose fallbacks")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenes", type=Path, default=WORK / "out" / "story-extract" / "scenes.json")
    parser.add_argument("--audio", type=Path, default=WORK / "out" / "story-extract" / "audio")
    parser.add_argument("--poses", type=Path, default=WORK / "out" / "poses")
    parser.add_argument("--pose-set", type=Path, default=WORK / "chara_commu_pose_set.json")
    parser.add_argument("--lips", type=Path, default=WORK / "out" / "story-extract" / "lips.json")
    parser.add_argument("--out", type=Path, default=REPO / "build" / "Unity3DContent" / "stories")
    parser.add_argument("--stories", default="")
    args = parser.parse_args(argv)
    return build(args)


if __name__ == "__main__":
    raise SystemExit(main())
