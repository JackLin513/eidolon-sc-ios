# 全量立绘运行时调研：`ディメンション凸ラバース!!`（2026-11-12）

> 范围：只回答「能不能把游戏里**真实的全身立绘**搬进 Eidolon、怎么搬、代价是什么」。
> 结论基于对 `st.pac` / `face.pac` / `patch.pac` / LL 立绘组的二进制实测与端到端解码，
> 不改 app 代码；原型脚本都在 `/tmp/eidolon-re-stand/`（不进仓库）。
> 上一份全量迁移报告见 `docs/research/galgame-full-migration-2026-11-12.md`；本文第 13 节修正了它的 5 处细节。

---

## 0. 摘要（结论先行）

1. **能做，而且不需要在手机上跑解码器。** `.PGD` 的两条编码链（`GE ` 完整图 + `PGD3` 矩形 XOR 差分）已经**完整解出并端到端验证**：Sakura 的 `ST01A_A010` 解出 2400×2048 BGRA（19,662,856 B，与头部声明逐字节相等），叠加表情补丁 `ST01A_A020` 后得到正确的换表情全身图。
2. **上一份报告有几处关键细节需要修正**：解压后 `h` 字节不是「行表」，而是**逐行 PNG 风格的滤波器标志**（0/1/2/4），像素是**滤波后的差分**，必须重建；且通道序是 **BGRA**。不做这一步只能解出乱码（见 §3.4、§4）。
3. **`LIST_STAND.TXT` 不是表情表，是姿态表**：`st01a_a..i` 的 `a..i` 是**姿态/身体角度**（与文件里的 `_A010.._I010` 一一对应），坐标是「漫符（表情符号）定位用的鼻尖坐标」。表情另有轴：**每个（角色, 衣装, 姿态）底图上的编号补丁 `020..231`**。上一份报告 §2.4/§5.3 的「每姿态 9 个表情」是误读。
4. **「表情 = 底图 + 恰好一张 PGD3」**，不是多层叠加：每个补丁都是相对同一底图的整脸 XOR 差分；对 2563 张补丁逐一验证了 base 名与矩形都在底图内。表情编号**没有全局语义**（同一编号在 Sakura 是微笑、在 Katan 是惊讶），所以编号→情绪必须**按角色人工标定**（或将来解脚本 VM 拿真值）。
5. **四女主「主姿态 × 全部表情」的体量是可控的**：S 与 LL 两套立绘按编号取并集后共 **115 张**（含底图），按 1500 px 高输出约 **84 MB**，按 2048 px 高约 **129 MB**（PNG，alpha 直通）。
6. **现有 Sakura 静态立绘包的图与 LL（4096×4096）立绘同画同表情；按尺寸与命名判断是 LL 的裁切**，不是 `st01` 的 S 尺寸；14 张旧 PNG 全是 1316×1376 的半身裁切，且当前映射只有 6 个情绪（**缺 `happy`**）。
7. **推荐方案 a) 预合成 PNG + manifest v2（多姿态 + 全表情目录 + 情绪映射）**，并新增一个 `UIImageView` 版的 `CharacterRenderer` 接进通话页。理由：包最小、运行时零解码、内存可控、可测试；runtime PGD 的包更大（压缩资产比 PNG 还大）、内存更差（LL 单张解码 67 MB）、还要在 Swift 里重写 LZSS/滤波/XOR；Spine 不可行（这游戏没有骨骼数据，只有栅格分层）。
8. **app 必须改代码，不能只换包**：当前静态立绘只有 Settings 里的一个 7 表情预览，连用户导入入口都没有（只有 DEBUG 环境变量），也没有接进通话页。最少改动：manifest v2 + installer 版本范围、registry 目录读取、`StaticStandRenderer`、`CallView.loadStand()` 的静态兜底、导入 UI/全表情预览。
9. 估算：生成器 2–3 d、情绪标定 1–1.5 d、Core 1–1.5 d、iOS 渲染/接线 3–4 d、预览/导入 1.5–2 d、真机 QA 1–2 d，合计 **9–14 工程师日**（主姿态全表情）；「全部姿态/衣装」再加 3–5 d 并需要分包（总量约 1000+ 张、1 GB 级）。

---

## 1. 方法与证据等级

| 等级 | 本报告的使用 |
|---|---|
| 实测二进制 | PAC/GE/PGD3 头解析、LZSS 解压、滤波重建、XOR 合成、PNG 输出、像素/尺寸/alpha 统计（脚本见 §1.1） |
| 反编译对照 | `Pal.dll` 的 `sub_100C5820`（LZSS）、`sub_100C6630`/`sub_100C68D0`（行滤波重建）、`sub_100C72E0`（格式分派）——用于确认「符号方向」和参数，不靠猜 |
| 结构推断（明示） | 角色↔槽位（st01..st04 ↔ 公开 cast 表前 4 人）、表情编号→情绪（人工看图） |
| 不采用 | 运行游戏、插件调用引擎导出、绕过保护、把游戏资产或译文写进仓库 |

### 1.1 原型脚本（只在 /tmp，可复跑）

| 脚本 | 作用 |
|---|---|
| `/tmp/eidolon-re-stand/inv.py` | PAC 索引解析 + 每个条目的 magic 分类 |
| `/tmp/eidolon-re-stand/pgd.py` | LZSS 解压 + GE/PGD3 头解析（未滤波） |
| `/tmp/eidolon-re-stand/decode_np.py` | 行滤波重建（numpy）+ XOR 合成 + BGRA→RGBA + PNG 输出 |
| `/tmp/eidolon-re-stand/stats.py` / `stats_ll.py` / `catalog.py` | 四女主 S / LL / 并集目录的尺寸、bbox、PNG 体积统计 |
| `/tmp/eidolon-re-stand/*.png` | 目视验证用的拼图/对比图（不进仓库） |

依赖：仓库自带 Python 运行时的 `numpy` + `Pillow`（§"load_workspace_dependencies" 里的 python3）。

---

## 2. 归档与命名模型

### 2.1 PAC 容器

`st.pac` 实测头：

```
0x0000  "PAC "                       magic
0x0004  u32 0
0x0008  u32 2732                     条目数
0x0804  索引区，0x28 B/条
        每条: char name[32]（NUL 填充，cp932/ASCII，8.3 大写）
              u32 size
              u32 file_offset
```

最后一个条目的 `offset+size == 文件大小-8`（`st.pac`：369,258,708 = 369,258,716-8），索引无越界（脚本 `inv.py` 全量校验通过）。

### 2.2 清单（实测）

| 归档 | 大小(B) | 条目 | GE（完整图） | PGD3（差分补丁） | 说明 |
|---|---|---|---|---|---|
| `st.pac` | 369,258,716 | 2,732 | **169** | **2,563** | 全部立绘（S 尺寸 + LL 尺寸） |
| `face.pac` | 26,440,973 | 1,244 | 94 | 1,150 | 头像/表情（500×410 裁切），同构 |
| `patch.pac` | 84,374,007 | 510 | — | — | **221 个 ST 条目与 `st.pac` 逐字节相同**，对立绘内容无影响 |

- `st.pac` 全部 GE 的 `type` 都是 3（LZSS）、全部 PGD3 的 bpp 都是 32；没有 24bpp/raw 变体需要兼容。
- GE 画布尺寸分布：`(2400,2048)×22`、`(2048,2048)×77`、`(2048,2572)×3`、`(2800,2800)×2`、`(1024,1024)×1`、**`(4096,4096)×64`**（LL 组）。
- `patch.pac` 的 221 个 ST 文件与 `st.pac` **SHA-256 全同**（实测 221/221 same、0 diff）。所以「打不打 patch.pac」对立绘字节没有影响。
- CHS v1.1 补丁（`totsulover_CHS_v1.1/Mod本体/totsulover.dll` 的 RCDATA `RPCK`，486 条）只有 472 PGD + 9 JPG + 2 CSV + 1 TGA + 1 INI + `STRINGS.JSON`；**没有任何 `ST01A_*`/`ST31A_*` 立绘覆盖**（唯一的 ST 字样是活动 CG `ROLL_07_ST01..04.PGD`）。→ 汉化补丁与立绘无关。

### 2.3 命名模型（本文的核心结构）

文件名：`ST<CC><Outfit>_<Pose><Slot>.PGD`

| 段 | 含义 | 实测例 |
|---|---|---|
| `CC` | 角色槽位号 | `01..20`（S 尺寸）、`31..35`（LL，女主 5 人）、`41..45`（LL 战斗） |
| `Outfit` | 衣装组 | `ST01A` 校服、`ST01B` 白色和服风；`ST02A/B/C`、`ST03A/B`… |
| `Pose` | 姿态/身体角度 | `A..I`（正立、侧身、举武器…）；`LIST_STAND.TXT` 的 `a..i` 就是它 |
| `Slot` | 图块槽位 | **`010` = 底图（GE）**；`020..231` = 表情补丁（PGD3） |

- 底图名在补丁头里以**小写**写死：`ST01A_A020.PGD` 的 `base = "st01a_a010.pgd"`；2563/2563 全部与同组同姿态 `010` 完全对应。
- 同一姿态的补丁数量**因角色/姿态而异**（`010` 之外 1–45 张）；编号 `xx0` 与 `xx1`（如 `060/061`）是**两个不同的表情状态**，不是「开眼/闭眼」图层，也不是可叠加的层。
- `STAND.CSV`（`/tmp/eidolon-re-full/out/csv/STAND.CSV`）把 `st01..st20` 对到 `vo01..vo20`，并给屏幕坐标/高度补正；LL `st31..35` 回指 `vo01..05`。

### 2.4 两套立绘：S 与 LL（关键发现）

| | S 尺寸 | LL 尺寸 |
|---|---|---|
| 槽位 | `ST01..ST20` | `ST31..ST35`（主线 5 人） |
| 底图画布 | 1024–2800（主用 2048/2400） | **4096×4096** |
| 解码后单张 RGBA | 16.8–19.7 MB | **67.1 MB** |
| 表情/姿态覆盖 | 01/02/03/04 各有 1–3 套衣装、6–9 个姿态 | 同样有 A..I 姿态与多衣装，但每姿态的补丁子集不同 |
| `LIST_STAND.TXT` | ✔ 有（鼻尖坐标按 S 画布） | ✘ 没有（LL 不参与漫符定位） |

**现有 `Galgame support/sakura/portraits/*.png` 与 LL 立绘同画同表情，按尺寸（1316×1376 半身）与命名（`A020`/`I180`/`B180` = 姿态+编号）判断是 LL 的裁切**，不是 `st01` 的 S 图：把 LL `ST31A_A010 + A020` 解出来后做同样的上半身裁切，与旧图**同画、同表情、同衣装**（对比图 `/tmp/eidolon-re-stand/png/old_vs_ll.png`；逐像素比对需要先精确对齐裁切区与缩放，视觉上一致）。所以「旧包很糊/只半身」不是提取方法的问题，是当时只裁了上半身、并且只做了 14 张。

---

## 3. 文件格式规范（可直接照此实现）

### 3.1 `GE ` 完整图头（169/169 实测）

```
0x00  char[2] 'G','E'      + 0x02 u16 payload_off = 32
0x04..0x0B  0
0x0C  u32 width
0x10  u32 height
0x14  u32 width（重复）
0x18  u32 height（重复）
0x1C  u32 type            0=raw, 1/2=24/32bpp 直拷变体, 3=LZSS
0x20  u32 raw_size        解压后字节数（实测 == 8 + h + w*h*4，169/169）
0x24  u32 comp_size       LZSS 载荷字节数
0x28  LZSS 流（payload_off + 8）
```

解压后的结构（**这是上一份报告漏掉的部分**）：

```
0x00  u16 7        版本/标记（实测恒为 7）
0x02  u16 bpp      32
0x04  u16 width
0x06  u16 height
0x08  u8  filters[h]       逐行滤波标志，取值 0/1/2/4
0x08+h  u8 pixels[w*h*4]   滤波后的像素，BGRA
```

### 3.2 `PGD3` 差分补丁头（2563/2563 实测）

```
0x00  "PGD3"
0x04  u16 x
0x06  u16 y
0x08  u16 w
0x0A  u16 h
0x0C  u16 bpp             32
0x0E  char base[32]       底图文件名（小写，如 "st01a_a010.pgd"）
0x2E  u16 0               对齐填充
0x30  u32 raw_size        实测恒 == h + w*h*4
0x34  u32 comp_size
0x38  LZSS 流
```

解压后：`filters[h]` + `pixels[w*h*4]`（**没有** 8 字节子头）。

### 3.3 LZSS 参数与伪代码

来自 `Pal.dll` 的 `sub_100C5820`（0x100c5820）完整反编译；§4.4 的抽样（≥16 张 GE、40 张 PGD3）上验证 `consumed == comp_size`、`out == raw_size` 逐字节成立。全部 2,732 个条目的头公式（raw/comp/矩形/base 名）是另做全量校验的。

- 没有单独的 ring buffer：**历史窗口就是输出缓冲本身**，距离 `dist` 直接回指已输出区域（可重叠 → RLE）。
- 标志位按 **LSB-first** 消费：一个 flag 字节管 8 次选择，8 次后从流里取下一个 flag。
- 两种匹配形式：
  - **2 字节形式**：`dist = v >> 4`（0..4095），`len = (v & 7) + 4`（4..11），**逐字节**从 `dst-dist` 前向拷贝 `len` 字节；
  - **3 字节形式**：`v3 = (v << 8) | byte`，`dist = v3 >> 12`（0..4095），`len = ((v3 & 0xFFC) >> 2) + 1`（1..1024），`extra = v3 & 3`；从 `dst-dist` **前向**拷贝 `4*len + extra` 字节。

```
flag = next(); bits = 8
while dst_len < raw_size:
    if (flag & 1) == 0:
        b = next()
        n = (b & 0xFC) >> 2        # 0..63
        extra = b & 3
        copy_from_input(4*n + extra)          # 全部字面量
    else:
        v = u16le(next2)
        if v & 8:
            dist = v >> 4; n = (v & 7) + 4
            copy_from_output(dist, n)          # 注意：n 字节，不是 4n
        else:
            v3 = (v << 8) | next()
            dist = v3 >> 12
            n = ((v3 & 0xFFC) >> 2) + 1
            extra = v3 & 3
            copy_from_output(dist, 4*n + extra)
    flag >>= 1; bits -= 1
    if bits == 0: flag = next(); bits = 8
```

> 极易踩的坑：2 字节形式拷的是 `len` 字节（不是 `4*len`）。我第一版按「4 字节步进」实现，`ST01A_A010` 多产出 1,010 B（19,663,866 ≠ 19,662,856），`consumed` 也对不上；改成逐字节后 169/169 精确。

### 3.4 逐行滤波重建（**上一份报告写错的地方**）

`h` 字节不是「行表」，而是**每行的滤波类型**，取值 `0/1/2/4`（= PNG 的 None/Sub/Up/Average，但**符号方向是减法**）。来自 `Pal.dll` 的 `sub_100C6630`（0x100c6630，C 版）与 `sub_100C68D0`（0x100c68d0，SSE 版）：

- `f & 1`：`recon[x] = recon[x-1] - filtered[x]`（首像素直接取 filtered）
- `f & 2`：`recon[x] = recon_prev_row[x] - filtered[x]`
- `f & 4`：`recon[x] = ((recon[x-1] + recon_prev_row[x]) >> 1) - filtered[x]`（首像素直接取 filtered）
- `f == 0`：直接取 filtered

全部按**字节**、mod 256、对 B/G/R/A 四通道独立。SSE 版逐字对应 `_mm_psubb(prev, filtered)`，所以是**减法**而不是 PNG 的加法。

```
prev = nil
for y in 0..<h:
    f = filters[y]
    if f == 0:            row = src[y]
    elif f & 1:           row[0] = src[y][0]; row[x][c] = (row[x-1][c] - src[y][x][c]) & 0xFF
    elif f & 2:           row[x][c] = (prev[x][c] - src[y][x][c]) & 0xFF
    elif f & 4:           row[0] = src[y][0]; row[x][c] = (((row[x-1][c] + prev[x][c]) >> 1) - src[y][x][c]) & 0xFF
    prev = row
```

实测滤波分布（证明这一步不是可省的）：`ST01A_A010` = 826 行 Sub / 1,217 行 Up / 5 行 Average；`ST31A_A010` = 1528 / 2548 / 20；`ST02A_A010` = 851 / 1145 / 52。**不做滤波重建 = 乱码**（我最初的「未滤波」输出 alpha 直方图是 201,138/205,000 全 0，明显错误）。

### 3.5 通道序与 alpha

- 像素是 **BGRA**（小端 4 字节，Windows D3D 习惯）。按 BGRA→RGBA 交换后肤色/头发才自然（不交换时肤色发青）。
- **直通 alpha（非 premultiplied）**：透明像素仍保留原始 RGB——40 张补丁抽样里「RGB 非零但 A=0」的像素有 430,709 个（共 6,053,864 px），「A 非零但 RGB=0」1,443 个。所以合成/裁切必须按 **BGRA 原样**处理，不能先乘 alpha。
- 行序**自上而下**，行 stride = `w*4`，无行填充。

### 3.6 XOR 合成（矩形差分）

```
for each (px, py) in patch rect (x..x+w, y..y+h):
    base[(py, px)][c] ^= patch[(py-y, px-x)][c]     # c = 0..3，含 alpha，无条件
```

- 因为 `x ^ 0 = x`，「补丁像素为 0 则不改」与「无条件 XOR」**完全等价**；实现上直接对整块 XOR 最简单。
- 补丁 alpha 也参与 XOR（alpha=0 的补丁像素不改变底图 alpha），所以换表情不会把人物挖空。
- 实测：`ST01A_A020`（rect 1138,499,138,93；raw 51,429 = 93 + 138*93*4；comp 2,404）只有 514 个非零像素，合成后变化的也正好是 514 个——典型「只改脸」。

---

### 3.7 参考实现骨架（语言无关伪代码）

```python
def decode_entry(blob):                      # blob = PAC 里一段 entry 字节
    kind, base = ('GE', None) if blob[0:2] == b'GE' else ('PGD3', None)
    if kind == 'GE':
        w, h  = u32(blob, 0x0C), u32(blob, 0x10)
        typ   = u32(blob, 0x1C); raw = u32(blob, 0x20); comp = u32(blob, 0x24)
        assert typ == 3
        data  = lzss(blob[0x28:], raw)       # 见 §3.3
        assert len(data) == raw == 8 + h + w*h*4
        bpp   = u16(data, 2); assert bpp == 32
        w2,h2 = u16(data,4), u16(data,6);    assert (w2,h2) == (w,h)
        filters, pixels = data[8:8+h], data[8+h:]
    else:                                    # PGD3
        x,y,w,h,bpp = u16(blob,4),u16(blob,6),u16(blob,8),u16(blob,0x0A),u16(blob,0x0C)
        assert blob[0:4] == b'PGD3' and bpp == 32
        base  = cstr(blob, 0x0E, 32)         # 小写，例如 "st01a_a010.pgd"
        raw, comp = u32(blob,0x30), u32(blob,0x34)
        data  = lzss(blob[0x38:], raw);      assert len(data) == raw == h + w*h*4
        filters, pixels = data[:h], data[h:]
    return dict(kind=kind, w=w, h=h, base=base,
                filters=filters, pixels=unfilter(filters, pixels, w, h))   # BGRA

def compose(base, patch):                    # 结果 = 底图 ⊕ 矩形补丁
    out = bytearray(base.pixels)
    for row in range(patch.h):
        dy, sx = patch.y + row, patch.x
        do = (dy*base.w + sx)*4
        so = row*patch.w*4
        for i in range(patch.w*4):
            out[do+i] ^= patch.pixels[so+i]          # 含 alpha；XOR 0 = 不变
    return out

def to_png_rgba(bgra, w, h):                 # 通道交换 + 直通 alpha + 可选缩放
    rgba = bytearray(bgra)
    rgba[0::4], rgba[2::4] = bgra[2::4], bgra[0::4]
    return encode_png(rgba, w, h)            # 行序 top-down，stride = w*4
```

---

## 4. 端到端验证（Sakura）

### 4.1 底图 `ST01A_A010.PGD`

| 项 | 值 |
|---|---|
| PAC 条目 | size 1,089,924 B，offset 0x1B2E4 |
| GE 头 | w=2400, h=2048, type=3, raw=19,662,856, comp=1,089,884 |
| LZSS | 输出 19,662,856 B，**恰好读完 1,089,884 B 载荷** |
| 解压结构 | `07 00 20 00 60 09 00 08`（v7/bpp32/w2400/h2048）+ 2048 B 滤波 + 19,660,800 B 像素 |
| 滤波 | 826×Sub / 1217×Up / 5×Avg |
| alpha 统计 | 90.2% 全透明、9.3% 不透明（其余为边缘抗锯齿） |
| 内容 bbox | x 755..1673、y 348..1755 → **919×1408** |

### 4.2 表情补丁 `ST01A_A020.PGD`

| 项 | 值 |
|---|---|
| 头 | rect=(1138,499,138,93), bpp=32, base=`st01a_a010.pgd` |
| 尺寸 | raw 51,429 = 93 + 138×93×4；comp 2,404 |
| 合成 | base 在 (1138,499) 处 XOR 后，514 个像素变化；输出仍是 2400×2048 BGRA，alpha 分布不变 |

### 4.3 输出事实（四女主主姿态）

| 角色 | 底图 | 画布 | S 内容 bbox | S 主姿态补丁数 | LL 内容 bbox | LL 主姿态补丁数 |
|---|---|---|---|---|---|---|
| 夜乃桜 `st01`/`st31` | 2400×2048 | 2400×2048 | 755,348–1673,1755（919×1408） | 27 | 1110,621–3048,3591（1939×2971） | 25 |
| 海漫華淡 `st02`/`st32` | 2048×2048 | 2048×2048 | 691,282–1355,1815（665×1534） | 15 | 1331,549–2760,3754（1430×3206） | 7 |
| ソフィア `st03`/`st33` | 2048×2048 | 2048×2048 | 724,273–1333,1763（610×1491） | 33 | 1406,443–2708,3628（1303×3186） | 39 |
| 崩月水仙 `st04`/`st34` | 2048×2048 | 2048×2048 | 640,346–1472,1751（833×1406） | 18 | 1223,591–3013,3613（1791×3023） | 22 |

> `st02` 的 S 内容 bbox 跨补丁取并集后上边界到 y=282（主姿态底图是 327），说明个别表情会改动到头发上缘之外的一点点；裁切时应按**该角色所有表情的并集 bbox** 取，或统一按固定画布裁。

### 4.4 全量一致性抽查

| 检查 | 结果 |
|---|---|
| GE 头 `raw == 8 + h + w*h*4` | 169/169 |
| GE `type == 3`、PGD3 `bpp == 32` | 169/169、2563/2563 |
| PGD3 `raw == h + w*h*4` | 2563/2563 |
| PGD3 base 名 ↔ 同组 `010` | 2563/2563 |
| PGD3 矩形不越出底图 | 2563/2563 |
| LZSS 输出长度/消耗字节 | 抽样 GE 16 张 + PGD3 40 张全部精确 |
| PNG 目视 | Sakura/Katan/Sophia/Suisen 共 100+ 张合成图目视无破图、无错色、alpha 正确 |

目视样本（临时目录，勿引用为交付物）：`/tmp/eidolon-re-stand/png/st01a_a020_c_white.png`、`.../expr_sheet_0.png`、`.../char_02.png`。

---

## 5. `LIST_STAND.TXT` 与表情模型

### 5.1 它到底是什么

`/tmp/eidolon-re-full/out/csv/LIST_STAND.TXT`（从 `csv.pac` 提取，cp932）：

```
//漫符表示用数値 "File",x,y ※顔の中心辺り（鼻付近）
"st01a_a",1209,572
"st01a_b",1209,572
...
"st01a_d",1320,570
```

- 共 **188 条 / 49 组**，每组 1–9 条。
- 第三段 `a..i` = **姿态**（对应 `ST01A_A010..I010` 的 9 个底图）；坐标是给「漫符/表情符号」定位用的鼻尖。
- 证据：`st01a` 里 `a,b,c` = (1209,572)，`d,e,f` = (1320,570)，`g,h,i` = (1209,572)——正好对应「正面姿态」与「侧身姿态 D/E/F」的头部位置差；如果它是表情表，同一姿态的表情不该移动鼻尖。
- 反面证据：四个女主的**表情**数量是 27/15/33/18（主姿态），根本不是 9。

### 5.2 表情轴：编号补丁

- 每个 `(角色, 衣装, 姿态)` 有 1 张 GE 底图 + N 张 PGD3，N 随角色/姿态变化。
- 编号是**槽位 id**，不是全局情绪：同一 `030` 在 Sakura 是「开口笑」、在 Katan 是「惊讶 o 型嘴」、在 Sophia 是「半眯眼不悦」（见 `/tmp/eidolon-re-stand/png/cross_30.png`）。所以**不能写一张全局「编号→情绪」表**；必须按角色标定。
- 姿态/衣装的完整清单（四女主）：

| 角色 | S 组（衣装→姿态：文件数） | LL 组 |
|---|---|---|
| 01 / 31 | `01A` 9 姿态 138；`01B` 5 姿态 39 | `31A` 108；`31B` 40 |
| 02 / 32 | `02A` 6 姿态 150；`02B` 5 姿态 62；`02C` 4 姿态 22 | `32A` 141；`32B` 62；`32C` 13 |
| 03 / 33 | `03A` 6 姿态 167；`03B` 6 姿态 276 | `33A` 148；`33B` 276 |
| 04 / 34 | `04A` 6 姿态 126；`04B` 4 姿态 113；`04C` 4 姿态 23 | `34A` 116；`34B` 110；`34C` 28 |

### 5.3 主姿态的表情编号（S / LL 并集）

| 角色 | S `pose A` 独有 | LL `pose A` 独有 | 并集（本文建议的“全表情”目录） |
|---|---|---|---|
| 01 Sakura | `161,191,210,220` | `41,131` | 29 个编号 |
| 02 Katan | `20,31,40,80,120,140,150,180,200` | `151` | 16 个编号 |
| 03 Sophia | `41` | `21,31,121,141,171,181,201` | 40 个编号 |
| 04 Suisen | `20,50,100,180` | `71,81,91,101,130,131,201,221` | 26 个编号 |

> 结论：**同一姿态下 S 与 LL 的编号集合不同**；已对 Sakura A020 做 S/LL 逐图对比，确认是同一张画的不同分辨率版本（其余角色建议抽样确认）。要「尽量全」就把两边并集都产出来（每张按可用分辨率取源，统一缩放到目标高度）。跨姿态的并集更大（01:30、02:43、03:45、04:45），但那些姿态的身体角度不同，不能混进同一套立绘。

---

## 6. 四女主：表情清单与建议映射

### 6.1 角色↔槽位（推断，置信度中）

`STAND.CSV` 的 `st→vo` 与公开 cast 表前 4 位一致：`st01`=夜乃桜、`st02`=海漫華淡、`st03`=ソフィア・ランカスター、`st04`=崩月水仙。第 5 人 `st05`（崩月槐）也出现在 `STAND.CSV`，但本报告按需求只做 4 人。
**这条绑定是推断**：静态表没写名字（见上一份报告 §2.3「待解」）。上线前建议用公开宣传图/语音文件对一次，成本半天。

### 6.2 编号→情绪（人工标定，提议值）

置信度：H=高（五官明显）、M=中、L=低（差异细微/可能一义多号）。**这张表应该放进生成器的 `stand_expression_map.json`，允许人改**，不要硬编码在 Swift 里。

| 情绪 | Sakura（01/31，主姿态） | Katan（02/32） | Sophia（03/33） | Suisen（04/34） |
|---|---|---|---|---|
| calm | `020`（H；alt `010/060/230`） | `020`（H） | `170`（M；alt `030`） | `030`（M；alt `210`） |
| happy | `030`（H；alt `050`） | `050`（H；alt `051`） | `050`（H；alt `051`） | `050`（H；alt `020/150`） |
| shy | `140`（M；alt `061/141`） | `031`（H；alt `140`） | `041`（H；alt `131/211`） | `160`（L；alt `180`） |
| surprised | `150`（H；alt `040/130/220`） | `030`（H；alt `070`） | `070`（H） | `070`（H） |
| sad | `080`（M；alt `160/180/200`） | `200`（M；alt `150/170/220`） | `160`（M；alt `150`） | `140`（M；alt `220`） |
| angry | `120`（H；alt `170/110`） | `120`（H；alt `070`） | `120`（H；alt `190`） | `090`（M；alt `100`） |
| thinking | `100`（L；alt `090`） | `040`（L；alt `180`） | `130`（L；alt `100/140`） | `100`（L；alt `120`） |

**为什么有多处 L/M**：表情补丁是「整脸 XOR」，没有元数据，也没有可静态读取的脚本→表情表；不同角色的同一编号语义不同（§5.2）。上表来自对 4 个角色逐张合成图的人工判读（拼图在 `/tmp/eidolon-re-stand/png/`）。`thinking` 这一类在游戏里可能根本不存在对应表情，属于「给 7 情绪模型凑数」的语义映射，建议在 app 里标注为可配置、并允许回退到 `calm`。

### 6.3 尚未分类的编号

- 四主姿态并集里，上表没覆盖的编号（如 Sakura `061/081/141/161/191/200/210`、Sophia `21/31/71/81/91/101/121/131/141/171/181/201/211/221`、Suisen `71/81/91/101/130/131/201/221` 等）已经**能产出图**，但语义未标定。
- 游戏里这些多半是「更细的差分」（害羞/半眯/汗/哭/喊叫/得意…）。**这正是“适配全部表情”的价值**：app 不必把它们硬塞进 7 情绪，而是作为「额外表情」目录暴露出来（见 §9），由将来的剧情/事件层按编号或标签选用。
- 唯一可靠的“真值”来源是脚本 VM：解出立绘/表情命令的操作数后，就能知道每个编号在剧情里被用来表达什么。上一份报告 §3.3 的 S-a/R-a 路线仍然适用，但**不再是立绘落地的阻塞项**。

---

## 7. 现有静态立绘链路评估（app 侧）

| 环节 | 现状 | 位置 |
|---|---|---|
| 数据模型 | `format_version=1`、`kind=stand`、`mode=full\|delta`、`renderer=static`、`characters[].expressions[emotion:path]`、`files[size,crc32]` | `EidolonCore/Sources/EidolonCore/StaticStandManifest.swift:6-114` |
| 安装/校验 | 只收 v1 / `mode == .full` / `renderer == "static"`；逐文件 size+crc32；表情文件必须存在 | `EidolonCore/Sources/EidolonCore/StaticStandBundleInstaller.swift:75-128` |
| 内容绑定 | `installStaticStand`：franchise 必须一致；两边都有 `contentSetID` 且不等 → 报错 | `EidolonCore/Sources/EidolonCore/ContentRegistry+Eidolon.swift:215-243` |
| 读取 | `installedStaticStandInfo` / `staticStandExpressions(characterID:)` | `ContentRegistry+Eidolon.swift:245-274` |
| 导入 | **只有 DEBUG 环境变量** `EIDOLON_IMPORT_STATIC_STAND_BUNDLE`，没有 UI 入口 | `EidolonIOS/App/AppModel.swift:1809-1831` |
| 预览 | Settings →「静态立绘预览」，硬编码 7 情绪顺序、一次只显示一张 | `EidolonIOS/Features/Settings/SettingsView.swift:128-129,433-440`、`EidolonIOS/Features/Stand/StaticStandPreviewView.swift:7-120` |
| 通话页 | **完全没接**：`CallView.loadStand()` 只找 Spine `stand(for:)` 或 3D，找不到就不画 | `EidolonIOS/Features/Call/CallView.swift:236-317` |
| 渲染抽象 | `CharacterRenderer`（`view: UIView` + `present(PresentationFrame)` + snapshot） | `EidolonIOS/Runtime/Runtime.swift:35-54` |
| 情绪枚举 | `StandEmotion{calm,happy,shy,surprised,sad,angry,thinking}`（7 个，核心 API 到处在用） | `EidolonCore/Sources/EidolonCore/StandRender.swift:96-104` |
| 现有 Sakura 包 | `tools/build_sakura_pack.py`：从 `Galgame support/sakura/portraits` 取 14 张 **LL 半身裁切**；映射只有 6 个情绪（calm/angry/shy/thinking/sad/surprised）——**缺 happy** | `tools/build_sakura_pack.py:23,245-255` |
| 测试 | 只测 install/绑定/路径解析，不测图像 | `EidolonCore/Tests/EidolonCoreTests/StaticStandTests.swift` |

**结论**：现在的静态立绘是“证明 binding 能跑”的 demo，不是产品路径。要满足「全量真实立绘」，必须扩 manifest + 加渲染器 + 接通话页 + 加导入/浏览 UI。

---

## 8. 三种方案对比

| | a) 预合成 PNG（推荐） | b) 端上 runtime PGD | c) Spine/Unity |
|---|---|---|---|
| 需要搬运的源资产 | 只需生成器读 `st.pac`/`patch.pac` | 要把用到的 `GE`/`PGD3` 原样打进包（或整个 `st.pac` 369 MB） | 无骨骼/atlas 数据可用 |
| 包体 | 主姿态全表情 84–129 MB；全部姿态约 1.0–1.5 GB | ≈ 源字节：四女主全部 S 组约 **63 MB**、LL 组约 **198 MB**（`st.pac` 内压缩体量）+ 需按需解码 | 需要手工绑定骨骼（每角色 20–40 h） |
| 运行时解码 | 0（只 PNG 解码） | LZSS + 滤波 + XOR，Swift 重写约 400–600 行 | 现成 |
| 内存峰值 | 单张 cropped RGBA 5–11 MB（2048 高） | LL 底图 67 MB + 补丁 + 目标 surface，峰值 100 MB+ | 中 |
| CPU | 0 | 4096² 解码+滤波，估计 100–300 ms/张（需实测） | 中 |
| 表情覆盖 | 想产多少产多少（全姿态/全编号都行） | 同样可以，但每张都要带 base+patch，包更大 | 只能表达绑定过的动作 |
| 与现有 app 契合 | `StaticStandManifest` 直接扩展 | 需要新 runtime + 资产协议 + 缓存层 | 与 `feat/mltd-3d-stand` 类似的大工程 |
| 风险 | 表情语义靠人工标定 | 解码正确性/内存/卡顿/包体；收益低 | 这游戏没有 Spine 资产，等于重做美术 |
| 工作量 | 生成器 2–3 d + app 6–9 d | +5–8 d，且性能不确定 | 20–40 h/角色起，且不可行 |

**推荐 a)**。b) 只有在「源资产必须逐字节保真、且不想离线生成」时才考虑，而本项目的约束恰恰相反（本地生成、要小、要稳）。c) 不成立：这游戏的立绘是**分层栅格 + 表情差分**，不是骨骼动画；没有 Spine 的 `data.json/atlas`。

---

## 9. 推荐架构：预合成 PNG + manifest v2 + 静态渲染器

### 9.1 包布局

```
totsulover-stand.eidolonpkg (zip)
├── manifest.json
└── images/
    ├── sakura/
    │   ├── a010.png            # 底图（= calm 的 fallback）
    │   ├── a020.png … a231.png # 该姿态全部表情（编号即目录 id）
    ├── katan/…
    ├── sophia/…
    └── suisen/…
```

- 每张图：**按该角色所有表情的并集 alpha bbox 裁切** → 统一缩放到目标高度（建议 2048）→ PNG（BGRA→RGBA，直通 alpha）。
- 编号沿用游戏槽位（`020`…`231`），这样将来对脚本/事件时还能对回原文件；情绪只是**标签**。
- 文件命名用 `<pose><slot>.png`（如 `a020.png`），便于多姿态扩展。

### 9.2 manifest v2（向后兼容 v1）

```json
{
  "format_version": 2,
  "kind": "stand",
  "mode": "full",
  "renderer": "static",
  "franchise": "totsulover",
  "contentSetID": "totsulover.main.v1",
  "created_at": "2026-11-12T00:00:00Z",
  "source": { "archive": "st.pac", "resolution": "S|LL|mixed", "height": 2048 },
  "characters": [
    {
      "id": "sakura",
      "characterKey": "totsulover:sakura",
      "defaultPose": "a",
      "poses": [
        {
          "id": "a",
          "label": "默认",
          "base": "images/sakura/a010.png",
          "expressions": [
            { "id": "010", "path": "images/sakura/a010.png" },
            { "id": "020", "path": "images/sakura/a020.png", "emotion": "calm" },
            { "id": "030", "path": "images/sakura/a030.png", "emotion": "happy" },
            { "id": "140", "path": "images/sakura/a140.png", "emotion": "shy" }
          ]
        }
      ],
      "emotions": {
        "calm": "a.020", "happy": "a.030", "shy": "a.140",
        "surprised": "a.150", "sad": "a.080", "angry": "a.120", "thinking": "a.100"
      }
    }
  ],
  "files": { "images/sakura/a020.png": { "size": 0, "crc32": "…" } }
}
```

兼容策略：

- `StaticStandManifest` 增加**可选** `poses`、`source`、`Character.emotions`、`Character.defaultPose`；`format_version` 接受 `1...2`。
- 只有 v1 时，行为与现在完全一致（`expressions` 字典 → 7 情绪）。
- v2 时，`staticStandExpressions(characterID:)` 仍返回 7 条 URL（由 `emotions` + `defaultPose` 解析），**旧调用方零改动**；新增 `staticStandCatalog(characterID:)` 返回 `[(pose, id, emotion?, URL)]` 供目录 UI / 未来事件层使用。
- 安装校验：v2 先校验 `poses[].expressions[].path` 都在 `files` 里；`emotions` 的键若不是 7 情绪之一，允许但忽略（记录 warning）——为将来扩情绪留余地。

### 9.3 app 侧必须改 vs 生成器侧

**必须改 app（Core）**

| 文件 | 改动 | 量 |
|---|---|---|
| `EidolonCore/Sources/EidolonCore/StaticStandManifest.swift` | 加 `poses/source/emotions/defaultPose`；版本 1...2 | S |
| `EidolonCore/Sources/EidolonCore/StaticStandBundleInstaller.swift:75-128` | 版本范围、v2 校验、目录 id 去重 | S |
| `EidolonCore/Sources/EidolonCore/ContentRegistry+Eidolon.swift:245-274` | 新增 `staticStandCatalog`；`staticStandExpressions` 支持 v2 映射 | S |
| `EidolonCore/Tests/EidolonCoreTests/StaticStandTests.swift` | v2 fixture/安装/目录/回退测试 | S |

**必须改 app（iOS）**

| 文件 | 改动 | 量 |
|---|---|---|
| 新增 `EidolonIOS/Features/Stand/StaticCharacterRenderer.swift` | `CharacterRenderer` 的 UIImageView 实现：`present(frame)` 按 `StandEmotion→expression` 换图；`setViewport` 做 `scaleAspectFit`；`snapshot()` 返回当前图；`setPaused` 忽略 | M |
| `EidolonIOS/Features/Call/CallView.swift:236-317` | `loadStand()` 末尾加静态兜底：`app.staticStandExpressions(character.id)` 非空则创建 `StaticCharacterRenderer`；`showStand` 的 failure 分支保持 | M |
| `EidolonIOS/App/AppModel.swift:2004-2022` | renderer 工厂加静态分支（或复用 RuntimeRegistry 的 fallback 顺序） | S |
| `EidolonIOS/Features/Stand/StaticStandPreviewView.swift:7-120` | 全表情网格（按姿态分组）+ 7 情绪快捷键 + 大图；显示 `source/resolution/height` | M |
| `EidolonIOS/Features/Settings/SettingsView.swift:128-129,433-440,793-820` | 加「导入静态立绘包」文件选择；展示目录统计（角色/姿态/表情数） | S |
| `EidolonIOS/Features/Call/CallView.swift:376-410` | 静态路径复用现有 stage 高度/淡入/结束 40% 逻辑；`fullBleed` 保持 false | S |

**可以只留在生成器（不进 app）**

- PAC/LZSS/滤波/XOR/PNG 编码、裁切/缩放、表情编号→情绪标定表、包体积统计、LL/S 选择、姿态筛选、去重。
- 这符合仓库硬约束：资产和处理逻辑在本机，仓库里只有工具与 id 级元数据（`tools/stand_expression_map.json` 只含编号和标签，不含画面）。

### 9.4 生成器形态

新增 `tools/build_totsulover_stand.py`（可参考 `tools/build_sakura_pack.py` 的输入约束/拒绝逻辑）：

```
usage:
  python3 tools/build_totsulover_stand.py \
    --game-root "$HOME/Developer/IdeaProjects/Galgame support/ディメンション凸ラバース!!/totsulover_dl" \
    --characters sakura,katan,sophia,suisen \
    --pose a --resolution auto --height 2048 \
    --content-set-id totsulover.main.v1 \
    --out build/totsulover-stand.eidolonpkg
```

- `--resolution auto`：同一姿态同一编号，LL 有就用 LL，否则 S（见 §5.3）；统一缩放到 `--height`。混源（同一角色的表情来自 S 和 LL 两个分辨率）必须**逐角色目视过一遍**：缩放后线宽/发丝可能有细微差异；若观感不一致就退回单源（表达式会少 1–9 个）。
- 安全：`--game-root` 必须在 `$HOME` 下（沿用 `build_sakura_pack.py:306-307` 的拒绝逻辑）；只读打开 `.pac`；输出固定在 `build/`（已 gitignore）。
- 校验：每个输出图 `raw==h+w*h*4`、滤波参数合法、合成后 alpha bbox 非空；manifest `files` 逐张 size+crc32（安装器会复查）。
- 可复现：记录每个输出对应的 `(archive, entry, size, sha256)`；同参数重复运行字节一致（Pillow PNG 参数固定、不写时间戳）。
- 测试：`tools/tests/` 里放**合成 GE/PGD3 fixture**（自造 8×8/16×16 图 + 三种滤波 + 两种 LZSS 匹配形式），断言解码器输出；不依赖游戏文件、不进仓库大资产。

### 9.5 尺寸 / 内存 / 缓存

- 目标高度 **2048 px**：手机全屏 stage = `0.80 × 852 pt × 3 = 2045 px`（`EidolonIOS/App/ResponsiveLayout.swift:38-52`），iPad 全屏约 1912 px；2048 足够且不浪费。
- 单张 cropped RGBA（2048 高）：Sakura 1337×2048 ≈ **11.0 MB**、Suisen 1213×2048 ≈ **9.9 MB**、Katan 913×2048 ≈ **7.5 MB**、Sophia 838×2048 ≈ **6.9 MB**；若取 1500 高则为 5.9/5.3/4.0/3.7 MB。
- **必须懒加载**：`UIImage(contentsOfFile:)` 按需解码，一次只保留当前 1 张 + 预取下一张；`NSCache` 设 `totalCostLimit ≈ 32 MB`（约 4–5 张）。不要一次性 `[UIImage]` 全载入（115 张 × 7–11 MB ≈ 1 GB，会 OOM）。
- 预览网格用**包内小缩略图**（约 160×240，每张 ~10 KB，全角色 ~1 MB），避免为了列表解码 115 张大图。
- 包体（主姿态全表情，PNG `optimize=True`）：
  - 1500 px 高：Sakura 29.0 MB / Katan 9.4 MB / Sophia 25.4 MB / Suisen 20.3 MB = **84 MB（115 张）**
  - 2048 px 高：44.5 / 12.2 / 40.8 / 31.1 = **≈129 MB（115 张）**
- LL 原图不要直接进 app：4096² 解码 67 MB/张，即使只显示 1 张也浪费；离线缩放即可。
- `SYSTEM.INI:95` 的 `MAX_TEXTURE=4096` 只对 GPU 纹理路径有意义；`UIImageView` 路径不受它限制，但**我们仍应把资产控制在 ≤2048 高**以控内存。

### 9.6 fallback 行为

1. 没装静态立绘包 → 保持现状（Spine/3D/头像/背景），`CallView` 不显示立绘。
2. 装了但该角色没有目录项 → 用 `calm` → 底图（`a010`）→ 头像。
3. 某情绪在 `emotions` 里缺 → 回退 `calm`。
4. 单张文件读失败/解码失败 → 保持上一张图，不把舞台清空（记一条 debug 日志）。
5. `contentSetID` 不匹配 → 安装期就拒绝（现有行为），不引入运行时静默错配。

### 9.7 测试清单

- Core：v1 包仍可装/读；v2 包安装、目录读取、`emotions` 解析、坏 zip/坏 crc/越界路径/未知情绪键。
- 生成器：合成 fixture 解压 + 三种滤波 + XOR + 裁切 + 高度归一；同一输入重复生成哈希一致。
- iOS：预览页 115 张全部可点开（UI test 或 snapshot）；通话页无 Spine 时回退到静态；内存峰值 < 150 MB；表情切换 < 100 ms（缓存命中）/ < 300 ms（冷读）。
- 真机：iPhone（compact）与 iPad（regular）各一轮；后台/前台恢复；通话结束 40% 变暗仍工作。

---

## 10. 迁移计划（四女主）

| 阶段 | 内容 | 产出 | 估时 | 验收 |
|---|---|---|---|---|
| **P0 解码器** | 把 §3 的 LZSS/滤波/XOR/PNG 写成生成器模块 + fixtures 测试 | `tools/totsulover_stand/{pac,pgd,image}.py` | 1–1.5 d | fixtures 全绿；对 169 张 GE + 随机 40 张 PGD3 统计 `raw/comp` 精确 |
| **P1 目录+标定** | 产四女主主姿态全表情（S∪LL，115 张），生成接触表；人工标定 7 情绪映射 | `stand_expression_map.json` + 115 PNG | 1.5–2 d | 每角色 7 情绪肉眼可区分；未知编号列在 `unclassified` |
| **P2 打包** | manifest v2 + zip + `size/crc32` + 缩略图 | `build/totsulover-stand.eidolonpkg`（84 MB@1500 / 129 MB@2048） | 0.5 d | 安装器全量校验通过 |
| **P3 Core** | manifest v2/installer/registry/catalog + 测试 | EidolonCore 改动 | 1–1.5 d | `swift test --package-path EidolonCore` 全绿（含新 v2 用例） |
| **P4 iOS 渲染** | `StaticCharacterRenderer` + `CallView` 静态兜底 + AppModel 工厂 | 通话页能显示静态立绘并随情绪切换 | 2–3 d | 无 Spine 包时真机通话可见；切情绪正确；内存/帧率达标 |
| **P5 预览/导入** | 导入按钮 + 全表情网格 + 姿态/来源信息 | 设置页可用 | 1.5–2 d | 文件选择器可装包；预览可翻完 115 张；删除/重装正常 |
| **P6 扩展（可选）** | 其它姿态/衣装打包（按姿态分包，~1 GB 级） | 每包 10–40 MB | 3–5 d | app 目录能切姿态；包按需安装 |

**关键路径**：P0 → P1/P2 与 P3 并行 → P4/P5。总计 **9–14 工程师日** 到「主姿态全表情可玩」。

---

## 11. 风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| 表情编号无语义、按角色不同 | **高** | 生成器侧可编辑 `stand_expression_map.json`；预览页接触表人工过一遍；把未分类编号保留为「额外表情」；将来解脚本 VM 拿真值 |
| 角色↔槽位（尤其 st05+）未证实 | 中 | 四女主用公开 cast + voice 槽位交叉验证；真机前对公开图 |
| 全姿态打包 1 GB+ | 中 | 默认只装主姿态；其它姿态分包、按需安装；缩略图与懒加载 |
| 内存/解码卡顿（若误用 LL 原图） | 中 | 离线缩放到 2048 高；懒加载 + NSCache 上限；预览用缩略图 |
| 不同游戏版本/补丁导致字节差异 | 中 | 生成器记录源文件 sha256 并写进 manifest `source`；版本不符直接报错 |
| `contentSetID` 两端写不一致 | 低 | 两个生成器统一 `--content-set-id`；installer 已强制相等 |
| v2 破坏既有 v1 测试/包 | 低 | 版本范围 1...2，v1 走原路径 |
| 法务（公开仓库） | **高** | 见 §12：仓库只放工具与编号，资产只在本机 `build/` |

---

## 12. 法务与安全

1. **版权**：立绘是游戏美术，版权属于开发商/发行商；本仓库公开，**不得**提交任何 `.PGD`/PNG/裁切图/译文。生成器只写 `build/`（`.gitignore` 已忽略 `build/`），包只在本机与个人设备间流转。
2. **补丁无关**：`patch.pac` 的 221 个 ST 条目与 `st.pac` 逐字节相同；CHS v1.1 的 RPCK 不含任何立绘覆盖。→ **立绘不需要打任何汉化补丁**，不需要分发/引用补丁内容。
3. **不改游戏保护**：全程只读 `.pac` 字节、离线解码；不运行游戏、不注入 DLL/插件、不绕过 Steam/DRM。
4. **生成器边界**：输入根必须在 `$HOME` 下（沿用 `tools/build_sakura_pack.py:306-307` 的拒绝逻辑）；输出固定在 `build/`；不发网络；不把源路径写进 manifest（只写归档名与哈希）。
5. **包与分享**：包只用于个人本地实验；server 上传也只是自用；不做 App Store 发布（README 已声明不上架）。
6. **元数据可提交**：`tools/stand_expression_map.json` 仅含编号与情绪标签（我们的推断），不含画面；可进仓库。若担心，也可放本地 ignore 文件，默认值写进工具。

---

## 13. 对既有报告的修正

针对 `docs/research/galgame-full-migration-2026-11-12.md`：

1. **§3.4 / E27「解压后 = 8 B 子头 + h 字节行表 + w*h*4 RGBA」→ 不准确。**
   `h` 字节是**逐行滤波器**（0/1/2/4），像素是滤波后的差分，必须按 §3.4 重建；通道是 **BGRA**、行序自上而下。不做滤波 = 乱码（实测 alpha 直方图异常）。
2. **§2.4 / §5.3「LIST_STAND 给每个姿态 9 个表情」→ 错误。**
   `a..i` 是**姿态**（对应 `_A010.._I010` 9 张底图，鼻尖坐标随姿态移动），不是表情。表情是每个姿态下的编号补丁，数量因角色而异（主姿态 7–40 个）。
3. **§5.3 / Q10「表情合成表未知」→ 结构已解。**
   表情 = 底图 + **恰好一张** PGD3（矩形 XOR），不存在「多补丁组合表」；未知的只是**编号→情绪语义**（需人工标定或将来解 VM）。
4. **§2.2 / §3.1 的 `patch.pac` 覆盖 → 对立绘无影响。**
   221 个 ST 条目与 `st.pac` 逐字节相同（实测 221/221）。立绘只依赖 `st.pac`。
5. **补充**：存在 **LL 立绘组 `ST31..ST35`（4096×4096）**，现有 `sakura/portraits` 正是 LL 裁切；「全量立绘」应按 LL 优先、S 兜底取源（§2.4、§9.4）。

---

## 14. 决策清单

- [ ] **D1 源分辨率**：LL 优先 + S 兜底（推荐，质量最好）／只用 S（生成器更简单、包更小）。
- [ ] **D2 输出高度**：2048（推荐，真机清晰，129 MB）／1500（84 MB，稍软）。
- [ ] **D3 范围**：先只做 4 女主主姿态全表情（推荐）／一步到位全部姿态+衣装（需分包，1 GB+）。
- [ ] **D4 情绪映射**：先按 §6.2 提议值（可编辑 JSON），真机前人工过一遍／等解 VM 拿真值（会阻塞进度）。
- [ ] **D5 manifest 版本**：v2（poses+catalog+emotions，推荐，向后兼容 v1）／v1 只塞 7 情绪（不满足“全表情”，不建议）。
- [ ] **D6 是否做「额外表情」浏览**：做（预览页全目录，推荐）／只显示 7 情绪。
- [ ] **D7 `contentSetID`**：`totsulover.main.v1`（与全量 content 包统一）／继续 `totsulover.sakura.v1`（只 Sakura 时）。
- [ ] **D8 是否做逐姿态分包**：P6 再做（推荐）／现在就先做。

---

## 15. 证据表

| ID | 事实 | 证据 |
|---|---|---|
| E1 | `st.pac` 2,732 条 = 169 GE + 2,563 PGD3；末条 `offset+size == size-8` | `inv.py` 全量；`/Users/.../totsulover_dl/st.pac` |
| E2 | `face.pac` 1,244 条 = 94 GE + 1,150 PGD3 | 同上 |
| E3 | `patch.pac` 221 个 ST 条目与 `st.pac` SHA-256 全同 | 逐条比对脚本（221 same / 0 diff） |
| E4 | CHS v1.1 RPCK 486 条，无 `ST01A_*` 等立绘覆盖 | `totsulover.dll` RCDATA 解析 + 文件名扫描 |
| E5 | GE 头：w@0x0C,h@0x10,type@0x1C,raw@0x20,comp@0x24,流@0x28 | `ST01A_A010.PGD` hexdump + `sub_100C72E0` 反编译 |
| E6 | `raw == 8+h+w*h*4`，169/169 | 全量检查 |
| E7 | 解压结构 = v7/bpp32/w/h + h 滤波字节 + 像素 | `ST01A_A010` 解压前 32 B = `07002000600900080101…` |
| E8 | PGD3 头：x@4,y@6,w@8,h@10,bpp@0x0C,name@0x0E,raw@0x30,comp@0x34,流@0x38 | `ST01A_A020.PGD` hexdump |
| E9 | PGD3 `raw == h+w*h*4`、base 名/矩形全对 | 2,563/2,563 |
| E10 | LZSS 语义（2/3 字节匹配、前向重叠拷贝） | `Pal.dll sub_100C5820` 反编译 + 抽样 16 GE/40 PGD3 的 `consumed==comp` |
| E11 | 滤波是「前值/上行 - filtered」，mod 256 | `sub_100C6630` / `sub_100C68D0`（`_mm_psubb(prev, filtered)`） |
| E12 | 通道 BGRA、直通 alpha、top-down | 目视 + 透明像素 RGB 保留统计（430,709/6,053,864） |
| E13 | XOR 合成：底图 ⊕ 补丁，零=不变 | `ST01A_A020` 合成 514 px 变化 |
| E14 | `ST01A_A010` 解出 19,662,856 B / 2400×2048；bbox 919×1408 | 端到端脚本 |
| E15 | 四女主主姿态表情数 S：27/15/33/18；LL：25/7/39/22 | `stats.py` / `stats_ll.py` |
| E16 | 主姿态 S∪LL 并集：29/16/40/26（115 张） | `catalog.py` |
| E17 | 包体 1500 px ≈ 84 MB；2048 px ≈ 129 MB | `catalog.py` / `catalog2048.py` |
| E18 | `LIST_STAND.TXT` 188 条/49 组，`a..i` = 姿态（鼻尖随姿态移动） | 提取文件 + 坐标分析 + 底图对照 |
| E19 | 编号语义按角色不同（同一 `030` 不同表情） | `/tmp/eidolon-re-stand/png/cross_30.png` |
| E20 | 旧 `sakura/portraits` 与 LL 同画同表情，按尺寸/命名判断为 LL 半身裁切（14 张 1316×1376） | `old_vs_ll.png` 对比 + 旧图尺寸/文件表 |
| E21 | 现有 Sakura 包只映射 6 情绪、缺 happy；导入只有 DEBUG env；通话页未接 | `tools/build_sakura_pack.py:245-255`、`AppModel.swift:1809-1831`、`CallView.swift:236-317` |
| E22 | 静态立绘 manifest/installer/绑定规则 | `StaticStandManifest.swift`、`StaticStandBundleInstaller.swift:75-128`、`ContentRegistry+Eidolon.swift:215-274` |
| E23 | 7 情绪枚举 + `CharacterRenderer` 抽象 | `StandRender.swift:96-104`、`Runtime.swift:35-54` |
| E24 | 舞台高度 0.80×viewport（compact phone） | `ResponsiveLayout.swift:38-52` |
| E25 | LL 画布 4096×4096；S 画布 2048/2400 | GE 头全量尺寸分布 |
