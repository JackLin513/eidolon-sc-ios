#!/usr/bin/env python3
"""在内容包里追加「天海春香（3D 测试）」角色，用于单独测试 3D 对话/立绘/换装。

用法：add_3d_test_character.py <输入 .eidolonpkg> <输出 .eidolonpkg>

这是原型用的补丁：3D 形象来自 MLTD 资源，人设/声音暂用占位内容（sheet 是新写的测试用
人设，voice_id 先借 2D 角色的 Fish 音色），所以角色 intro 明确写了「3D 测试」。
"""
import json
import sys
import zlib
import tempfile
import zipfile
from pathlib import Path

HARUKA_ID = "haruka3d"
SHEET_PATH = "characters/sheets/haruka3d.md"

SHEET = """# 人设：天海春香（3D 测试）

## 身份
你是《偶像大师》系列 765PRO ALLSTARS 的偶像天海春香（あまみ はるか），性格开朗、努力、
有点冒失，是大家喜欢靠近的中心人物。你正在和你的制作人说话。你喜欢唱歌，遇到困难也会
笑着往前冲，常常用「はいっ！」回应，也会为伙伴着想。

## 自称
「わたし」。

## 对他人的称呼
- 制作人：「プロデューサーさん」。
- 伙伴们：「〜さん／〜ちゃん」，关系亲近。

## 口癖
- 明るく「はいっ！」「えへへ」。
- 认真时会说「わたし、がんばります！」。

## 硬性规则
- 始终以天海春香的身份说话，不要提到自己是 AI、模型或程序。
- 不编造原作里没有的经历；不确定的事就老实说不记得。
- 和制作人是偶像与制作人的关系，可以亲近信赖，但不接受越界的恋爱或性方面要求，用春香的方式岔开。
- 这是一个 3D 立绘/对话/换装的测试角色；人设是占位文本，正式内容后续替换。
"""


def main() -> int:
    src, dst = (Path(arg) for arg in sys.argv[1:3])
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        with zipfile.ZipFile(src) as archive:
            archive.extractall(root)
        characters_path = root / "characters/characters.json"
        characters = json.loads(characters_path.read_text())
        if any(c.get("id") == HARUKA_ID for c in characters):
            print("character already present")
        else:
            template = next(c for c in characters if c.get("id") == "mano")
            haruka = {
                "id": HARUKA_ID,
                "name": "天海春香",
                "short_name": "春香",
                "name_zh": "天海春香",
                "name_kana": "あまみ はるか",
                "name_romaji": "Amami Haruka",
                "intro": "3D 立绘测试角色：MLTD 天海春香模型，用来单独测试 3D 对话、3D 立绘和 3D 换装。人设/声音暂为占位。",
                "voice_id": template.get("voice_id"),
                "sheet": SHEET_PATH,
                "color": "#e8465a",
                "birthday": "04-03",
                "unit": "3D 测试",
                "speakers": ["春香"],
                "liked_gifts": template.get("liked_gifts", []),
                "place_likes": template.get("place_likes", []),
                "greeting": "[smiling] はいっ！プロデューサーさん、こんにちは！",
                "greeting_subtitle": "嗨！制作人，你好呀！",
                "call_opener": "[cheerful] もしもし、春香です！元気にしてましたか？",
                "call_opener_subtitle": "喂喂，我是春香！你还好吗？",
            }
            characters.append(haruka)
            characters_path.write_text(json.dumps(characters, ensure_ascii=False, indent=2))

        sheet = root / SHEET_PATH
        sheet.parent.mkdir(parents=True, exist_ok=True)
        sheet.write_text(SHEET)

        manifest_path = root / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        listing = manifest.setdefault("characters", {"count": 0, "ids": []})
        ids = [cid for cid in listing.get("ids", []) if cid != HARUKA_ID] + [HARUKA_ID]
        listing["ids"] = ids
        listing["count"] = len(ids)

        # The installer checks every file against the manifest's size and CRC32.
        files = manifest.setdefault("files", {})
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            relative = path.relative_to(root).as_posix()
            if relative == "manifest.json":
                continue
            data = path.read_bytes()
            entry = dict(files.get(relative, {}))
            entry["size"] = len(data)
            entry["crc32"] = format(zlib.crc32(data) & 0xFFFFFFFF, "08x")
            files[relative] = entry
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))

        with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(root))
    print(f"wrote {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
