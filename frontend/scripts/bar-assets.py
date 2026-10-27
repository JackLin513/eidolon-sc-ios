"""酒吧画面的图（规格「酒吧的店面」的「素材和素材脚本」）：从本机的原版提取目录生成 `public/bar/img/` 下的每张图。

提取目录里有些图被裁掉了透明边，切出尺寸比游戏里的逻辑尺寸小。这里把它们贴回逻辑尺寸的透明画布，偏移照调研笔记
（research/bar-screen 分支 `.scratch/bar/research/screen.md` 5.1 节，TPAG 的 TargetX/Y）记在下面的 PAD 里；没写偏移的照原样拷。
外框右上角原版的 logo 文字抹成底色，再贴上脚本旁边的 `bar-logo.png`（票 04 的「VA-283」，187x63、透明底、只有外框的两种粉；
小字和「VA-」取自原版，「283」照原版大字的斜度和扫描线手画）。
图保持 PNG。输出目录里不在清单上的 PNG 会删掉，所以再跑一次结果不变。

提取目录当不可信数据：只读里面的图，不执行任何东西；用 `-I` 跑，不从脚本目录和当前目录载入模块。

    uv run --no-project --with pillow python -I frontend/scripts/bar-assets.py <原版提取目录>
"""

import shutil
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "public" / "bar" / "img"
LOGO = HERE / "bar-logo.png"

# 外框里 logo 那一块黑底（不含边框）：左上 (436,27)，188x63 的框里面 187x63
LOGO_BOX = (436, 27, 623, 90)

# 提取目录的文件 → (输出名, 逻辑宽, 逻辑高, 偏移 x, 偏移 y)。
# 原版的材料按 a–e 编号，输出名换成材料的首字母：a Adelhyde、b Bronson、c→d Delta、d→f Flanergide、e→k Karmotrine。
PAD: dict[str, tuple[str, int, int, int, int]] = {
    "139_scanrines.png": ("scanlines", 640, 360, 0, 0),
    "072_icesprite.png": ("ice", 33, 57, 3, 23),
    "071_agesprite.png": ("age", 33, 57, 4, 25),
    "044_shaker_spr.png": ("shaker", 72, 68, 20, 6),
    "047_shake_hover_spr.png": ("shaker_hover", 72, 68, 20, 3),
    "046_shaker_nohit.png": ("shaker_shake", 72, 68, 20, 6),
    # 加料时从摇酒器放大淡出的光圈，和摇酒器同一块画布
    "049_shakerpulse_red.png": ("pulse_a", 72, 68, 20, 6),
    "050_shakerpulse_yellow.png": ("pulse_b", 72, 68, 20, 6),
    "051_shakerpulse_blue.png": ("pulse_d", 72, 68, 20, 6),
    "052_shakerpulse_green.png": ("pulse_f", 72, 68, 20, 6),
    "053_shakerpulse_cyan.png": ("pulse_k", 72, 68, 20, 6),
    "073_resetsprite.png": ("reset", 71, 25, 1, 1),
    "074_resetsprite_hover.png": ("reset_hover", 71, 25, 1, 1),
    "075_mixspriteno.png": ("mix_no", 71, 25, 1, 1),
    "076_mixspriteno_hover.png": ("mix_no_hover", 71, 25, 1, 1),
    "077_mixspriteyes.png": ("mix_yes", 71, 25, 1, 1),
    "078_mixspriteyes_hover.png": ("mix_yes_hover", 71, 25, 1, 1),
    "079_slotsprite.png": ("slot", 71, 25, 1, 1),
    "085_slotout.png": ("slot_out", 71, 25, 2, 1),
    "063_abig_on.png": ("big_a", 8, 17, 2, 2),
    "064_bbig_on.png": ("big_b", 8, 17, 2, 2),
    "065_cbig_on.png": ("big_d", 8, 17, 2, 2),
    "066_dbig_on.png": ("big_f", 8, 17, 2, 2),
    "067_ebig_on.png": ("big_k", 8, 17, 2, 2),
    "068_slot_n.png": ("gauge_on", 10, 5, 0, 0),
    "069_slot_b.png": ("gauge_big", 10, 5, 3, 2),
    "070_marcodefault.png": ("gauge", 70, 17, 0, 1),
    "057_successtext_cn_00.png": ("success", 59, 12, 12, 0),
    "055_failtext_cn_00.png": ("fail", 102, 15, 0, 3),
    # 饮品成品图：逻辑 35x53，原点 (17,26)
    "020_sugar_sush_spr.png": ("drink_srush", 35, 53, 11, 15),
    "037_mercuryblast_spr.png": ("drink_meblast", 35, 53, 11, 15),
    "021_sparkle_star_spr.png": ("drink_sstar", 35, 53, 7, 5),
    "023_fluffy_dream_spr.png": ("drink_fdream", 35, 53, 5, 5),
    "024_sunshine_cloud_spr.png": ("drink_scloud", 35, 53, 6, 6),
    "040_zen_star_spr.png": ("drink_zstar", 35, 53, 6, 6),
    "026_gut_punch_spr.png": ("drink_gpunch", 35, 53, 6, 17),
    "031_beer_spr.png": ("drink_beer", 35, 53, 3, 4),
    "043_glitchbottle.png": ("drink_glitch", 35, 53, 3, 9),
    # 瓶装：原版 25x40、原点 (12,20)，这里放进饮品的 35x53 画布、原点挪到 (17,26)，偏移各加 (5,6)；tea 本来就是 35x53
    "182_abs_spr.png": ("drink_abs", 35, 53, 7, 11),
    "181_rum_spr.png": ("drink_rum", 35, 53, 7, 9),
    "180_tea_spr.png": ("drink_tea", 35, 53, 12, 6),
    "183_fed_spr.png": ("drink_fed", 35, 53, 6, 20),
    # 点唱机小播放器的高亮按钮：整块 188x63 上的一小块
    "692_shuffle_small_spr.png": ("juke_shuffle", 188, 63, 107, 22),
    "694_backmusic_small_spr.png": ("juke_back", 188, 63, 7, 26),
    "695_loop_small_spr.png": ("juke_loop", 188, 63, 144, 25),
    "696_nextmusic_small_spr.png": ("juke_next", 188, 63, 66, 26),
}
# 文本打完后右下角上下跳的倒三角 arrow_text_2，8x8，每帧的偏移不同
for i, (x, y) in enumerate([(0, 1), (0, 2), (0, 1), (0, 0)]):
    PAD[f"138_arrow_text_2_{i:02d}.png"] = (f"arrow_{i}", 8, 8, x, y)

# 提取目录的文件 → 输出名，照原样拷。
COPY: dict[str, str] = {
    "002_barground.png": "barground",
    "141_fan_spr.png": "fan",
    "166_recipe_introcn.png": "recipe_intro",
    "172_recipe_bg.png": "recipe_bg",
    "617_shop_arrow_spr.png": "arrow",
    "004_adelhyde.png": "ing_a",
    "007_bronson.png": "ing_b",
    "010_delta.png": "ing_d",
    "013_flanergide.png": "ing_f",
    "016_karmotrine.png": "ing_k",
    "005_adelhyde_hover.png": "ing_a_hover",
    "008_bronson_hover.png": "ing_b_hover",
    "011_delta_hover.png": "ing_d_hover",
    "014_flanergide_hover.png": "ing_f_hover",
    "017_karmotrine_hover.png": "ing_k_hover",
    "006_adelhyde_off.png": "ing_a_off",
    "009_bronson_off.png": "ing_b_off",
    "012_delta_off.png": "ing_d_off",
    "015_flanergide_off.png": "ing_f_off",
    "018_karmotrine_off.png": "ing_k_off",
    "058_a_on.png": "cell_a",
    "059_b_on.png": "cell_b",
    "060_c_on.png": "cell_d",
    "061_d_on.png": "cell_f",
    "062_e_on.png": "cell_k",
    "022_blue_fairy_spr.png": "drink_bfairy",
    "025_moonblast_spr.png": "drink_moblast",
    "027_piledriver_spr.png": "drink_pdriver",
    "028_suplex_spr.png": "drink_splex",
    "029_marsblast_spr.png": "drink_mablast",
    "030_crevice_spike_spr.png": "drink_cspike",
    "032_bleeding_jane_spr.png": "drink_bjane",
    "033_badtouch_spr.png": "drink_btouch",
    "034_brandtini_spr.png": "drink_btini",
    "035_cobalt_velvet_spr.png": "drink_cvelvet",
    "036_fringe_weaver_spr.png": "drink_fweaver",
    "038_grizzly_temple_spr.png": "drink_gtemple",
    "039_bloom_light_spr.png": "drink_blight",
    "041_piano_man_spr.png": "drink_pman",
    "042_piano_woman_spr.png": "drink_pwman",
    # 点唱机选曲界面和小播放器
    "699_new_jukeframe.png": "juke_frame",
    "698_startup_juke.png": "juke_startup",
    "620_musicslot_spr.png": "juke_slot_blue",
    "621_playlistslot_spr.png": "juke_slot_red",
    "622_playlistslotselect_spr.png": "juke_slot_yellow",
    "701_ready_red.png": "juke_ready_red",
    "702_ready_green.png": "juke_ready_green",
    "691_small_jukebox_spr.png": "juke_small_paused",
    "697_small_jukebox_pause_spr.png": "juke_small_playing",
    # 设置框（票 14）：框本身由 settings_frame 裁；背景音乐、音效的字和滑条（两头带 −/+），滑块，扫描线 On/Off 的平时和
    # 悬停（悬停是黑字，叠在白条上）
    "719_bgm_txt_sprcn.png": "set_bgm",
    "721_sfx_txt_sprcn.png": "set_sfx",
    "722_bgm_slide_spr.png": "set_bgm_slide",
    "723_sfx_slide_spr.png": "set_sfx_slide",
    "749_slide_slider_spr.png": "set_knob",
    "729_scanlinebutton_spr.png": "set_hover",
    "739_filteron_idlecn.png": "set_scan_on",
    "742_filteron_hovercn.png": "set_scan_on_hover",
    "745_filteroff_idlecn.png": "set_scan_off",
    "748_filteroff_hovercn.png": "set_scan_off_hover",
}
for i in range(4):
    COPY[f"717_previewload_spr_{i:02d}.png"] = f"juke_preview_{i}"
# 店门口的霓虹招牌三帧
for i in range(3):
    COPY[f"495_barintro_spr_{i:02d}.png"] = f"intro_{i}"
# 配方卡：第 0 页是空白，1–24 页是有卡的 24 款
for i in range(1, 25):
    COPY[f"170_recipes_cn_{i:02d}.png"] = f"recipe_{i}"
# 电视：9 个有画面的台（第 10 台是关着，不用图），帧数照原版
CHANNELS = {"145_burrito": 3, "146_wk": 7, "147_dollar": 2, "148_news": 6, "150_yiik": 3, "151_toku": 3, "152_mwj": 4, "154_ramen": 3}
for prefix, frames in CHANNELS.items():
    name = prefix.split("_", 1)[1]
    for i in range(frames):
        COPY[f"{prefix}_channel_spr_{i:02d}.png"] = f"ch_{name}_{i}"
COPY["153_hassy_channel_spr.png"] = "ch_hassy_0"

# 鼠标手套（cursor_obj）：提取目录的文件 → (名字, 逻辑宽, 逻辑高, 偏移 x, 偏移 y)；各出 1/2/3 倍，热点在前端按倍数算
CURSORS: dict[str, tuple[str, int, int, int, int]] = {
    "159_cursor_spr.png": ("spr", 17, 24, 0, 0),
    "163_cursor_clicked.png": ("clicked", 17, 24, 0, 1),
    "160_cursor_open.png": ("open", 17, 25, 0, 0),
    "161_cursor_closed.png": ("closed", 17, 21, 0, 0),
}
for i in range(4):
    CURSORS[f"164_cursor_next_{i:02d}.png"] = (f"next_{i}", 32, 20, 0, 0)


def pad(src: Path, w: int, h: int, x: int, y: int) -> Image.Image:
    img = Image.open(src).convert("RGBA")
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    canvas.paste(img, (x, y))
    return canvas


def frame(src: Path) -> Image.Image:
    """外框：左上的客人窗和下方的文本框原本就是透明洞。右上 logo 那一块的字（粉色）抹成黑底，有 `bar-logo.png` 就贴上去。"""
    img = Image.open(src).convert("RGBA")
    px = img.load()
    left, top, right, bottom = LOGO_BOX
    for x in range(left, right):
        for y in range(top, bottom):
            px[x, y] = (0, 0, 0, 255)
    if LOGO.exists():
        logo = Image.open(LOGO).convert("RGBA")
        img.alpha_composite(logo, (left, top))
    return img


# 原版中文的设置框 258x250：「声音」「图像」两个标题烤在框里，「图像」下面是「全屏」「窗口化」「扫描线 Off」三行。
# 「全屏」「窗口化」不做（票 14）：切掉这两行（第 156–205 行），「扫描线」那一行往上挪到「全屏」的位置，
# 它的字（原版另外叠一张 On/Off 的图）抹成黑底，由前端叠 `set_scan_on`/`set_scan_off`。
SETTINGS_CUT = (156, 206)
SETTINGS_SCAN_TEXT = (30, 210, 230, 228)


def settings_frame(src: Path) -> Image.Image:
    img = Image.open(src).convert("RGBA")
    w, h = img.size
    left, top, right, bottom = SETTINGS_SCAN_TEXT
    img.paste((0, 0, 0, 255), (left, top, right, bottom))
    cut, rest = SETTINGS_CUT
    out = Image.new("RGBA", (w, h - (rest - cut)), (0, 0, 0, 0))
    out.paste(img.crop((0, 0, w, cut)), (0, 0))
    out.paste(img.crop((0, rest, w, h)), (0, cut))
    return out


def main() -> None:
    sys.stderr.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    if len(sys.argv) != 2:
        sys.exit("用法：bar-assets.py <原版提取目录>")
    sprites = Path(sys.argv[1]) / "sprites"
    if not sprites.is_dir():
        sys.exit(f"找不到 {sprites}")
    OUT.mkdir(parents=True, exist_ok=True)
    written: set[str] = set()

    def save(img: Image.Image | Path, name: str) -> None:
        if isinstance(img, Path):
            shutil.copyfile(img, OUT / f"{name}.png")
        else:
            img.save(OUT / f"{name}.png")
        written.add(f"{name}.png")

    save(frame(sprites / "000_frame_sprite.png"), "frame")
    save(settings_frame(sprites / "726_configframe_spr_cn.png"), "set_frame")
    for file, (name, w, h, x, y) in PAD.items():
        save(pad(sprites / file, w, h, x, y), name)
    for file, name in COPY.items():
        save(sprites / file, name)
    for file, (name, w, h, x, y) in CURSORS.items():
        base = pad(sprites / file, w, h, x, y)
        for k in (1, 2, 3):
            save(base.resize((w * k, h * k), Image.Resampling.NEAREST), f"cur_{name}@{k}")
    for stale in OUT.glob("*.png"):
        if stale.name not in written:
            stale.unlink()
            print("删掉不在清单上的", stale.name, file=sys.stderr)
    total = sum((OUT / n).stat().st_size for n in written)
    print(f"{len(written)} 张图，{total / 1024:.0f} KB", file=sys.stderr)


if __name__ == "__main__":
    main()
