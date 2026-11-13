#!/usr/bin/env python3
"""Rewrite an existing Totsulover full package's user identity.

The story importer now writes the corrected identity. This tool patches a package that
was exported before that change, without needing the original game data: it replaces the
franchise prompt, rewrites sheets/facts, fixes the story speaker sentinel, refreshes the
manifest file hashes and writes a new zip.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import tempfile
import zipfile
import zlib
from pathlib import Path

USER_SECTION = """# 和你对话的人
正在和你对话的是崩月槐（くずつき かい），男性，崩月家的魔术师，也是转入「学园」的转学生。
请按你在原作中对他的称呼叫他：
- 夜乃桜、ソフィア・ランカスター：「槐くん」
- 海漫華淡：「槐さん」
- 崩月水仙：「槐お兄ちゃん」
不要用身份标签或泛称代替这些称呼，也不要给他套用其他作品的职业称呼。"""
ADULT_BOUNDARY = """# 亲密边界
不要进入成人亲密、婚姻承诺、强烈占有、病态依赖、控制欲或现实接触幻想。"""
WORLD_PROMPT = """# 世界设定
《ディメンション凸ラバース！！》的舞台是横滨的「学园」。学园既是学校，也是对抗怪兽的组织；学生会是学生一侧的核心。
- 学园：以学生会为核心，夜乃桜担任学生会长，海漫華淡与ソフィア・ランカスター也在学生会。
- 魔术师：研究反现实与魔术的势力，崩月家所属。
- 崩月家：研究反现实与魔术的家族，崩月槐与妹妹崩月水仙出身于此。
主要人物：夜乃桜、海漫華淡、ソフィア・ランカスター、崩月水仙；崩月槐是本校学生，也是故事的中心人物。"""
VOCABULARY = {"283 事务所": "学园", "制作人": "槐", "偶像": "角色", "事务所": "学园"}
SAKURA_ADULT_CLAUSE = "但不要进入成人亲密、婚姻承诺、强烈占有、病态依赖、控制欲或现实接触幻想。"
LORA = "Yoruno_sakura-noobai_v1.0.safetensors"


def as_user(text: str) -> str:
    text = text.replace(SAKURA_ADULT_CLAUSE, "").replace(SAKURA_ADULT_CLAUSE.rstrip("。"), "")
    for old, new in [
        ("283 事务所", "学园"),
        ("制作人", "你"),
        ("偶像", "角色"),
        ("事务所", "学园"),
    ]:
        text = text.replace(old, new)
    return text


def franchise_json() -> bytes:
    value = {
        "work_name": "ディメンション凸ラバース！！",
        "organization": "学园",
        "producer_role": "主人公",
        "language": "ja",
        "judge_scene": "角色扮演对话中，角色是《ディメンション凸ラバース！！》中学园的一员，正在和崩月槐对话。",
        "call_scene": "角色扮演的通话中，角色是《ディメンション凸ラバース！！》中学园的一员，正在和崩月槐通话。",
        "producer_line": "正在和你对话的是崩月槐。请按原作中你与他的关系称呼他。",
        "memory_instructions": "你负责替《ディメンション凸ラバース！！》中学园的角色们记住关于崩月槐的事。崩月槐就是正在和她们对话的用户。",
        "title_instructions": "你负责给崩月槐和一位角色（《ディメンション凸ラバース！！》中学园的一员）的一段对话起标题，好让崩月槐以后在历史对话里一眼认出这段聊了什么。崩月槐就是正在和她对话的用户。",
        "photo_series": "",
        "protagonist_term": "槐",
        "user_section": USER_SECTION,
        "adult_boundary": ADULT_BOUNDARY,
        "world_prompt": WORLD_PROMPT,
        "vocabulary": VOCABULARY,
    }
    return json.dumps(value, ensure_ascii=False, indent=2).encode()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"refusing to overwrite {args.output}")

    with zipfile.ZipFile(args.input) as source, tempfile.TemporaryDirectory() as tmp:
        names = source.namelist()
        if "manifest.json" not in names:
            raise SystemExit("not an Eidolon content package: missing manifest.json")
        manifest = json.loads(source.read("manifest.json"))
        changed: dict[str, bytes] = {}
        for name in names:
            if name in {"manifest.json", "characters/franchise.json"}:
                continue
            data = source.read(name)
            if name.startswith(("characters/sheets/", "characters/facts/")) and name.endswith(".md"):
                changed[name] = as_user(data.decode()).encode()
            elif name == "characters/world.json":
                world = json.loads(data)
                if isinstance(world.get("protagonist"), dict):
                    world["protagonist"]["note"] = "崩月家的魔术师，也是故事的中心人物。"
                changed[name] = json.dumps(world, ensure_ascii=False, indent=2).encode()
            elif name == "characters/characters.json":
                characters = json.loads(data)
                for character in characters:
                    if character.get("id") == "sakura" and character.get("photo_lora"):
                        character["photo_lora"] = LORA
                changed[name] = json.dumps(characters, ensure_ascii=False, indent=2).encode()
            elif name == "content/eidolon.db":
                db_path = Path(tmp) / "eidolon.db"
                db_path.write_bytes(data)
                con = sqlite3.connect(db_path)
                with con:
                    con.execute(
                        "UPDATE episode_lines SET speaker = '槐' WHERE speaker IN ('__producer__', '男主角')"
                    )
                con.close()
                changed[name] = db_path.read_bytes()

        changed["characters/franchise.json"] = franchise_json()
        for name, data in changed.items():
            manifest["files"][name] = {
                "size": len(data),
                "crc32": f"{zlib.crc32(data) & 0xFFFFFFFF:08x}",
            }
        manifest["files"].pop("manifest.json", None)
        manifest_bytes = json.dumps(manifest, ensure_ascii=False, indent=2).encode()

        with zipfile.ZipFile(args.output, "w") as target:
            for info in source.infolist():
                if info.filename == "manifest.json":
                    continue
                target.writestr(info, changed.get(info.filename, source.read(info.filename)))
            manifest_info = zipfile.ZipInfo("manifest.json")
            manifest_info.compress_type = zipfile.ZIP_DEFLATED
            target.writestr(manifest_info, manifest_bytes)

    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
