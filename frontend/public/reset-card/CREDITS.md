# 重置卡插画的来源

`reset-card.webp` 是重置卡（`GLOSSARY.md`「重置卡」）的插画，抽奖结果和礼物子页的重置卡条里用它。由图像生成模型生成（gpt-image-2.5，2026-10-13），生成后抠掉背景、缩到 512×512、转成 WebP（质量 82），测试会检查尺寸和大小。

- 画的是一张斜放的卡片，卡面是 283 プロダクション的事务员七草はづき的半身像，歪着头露齿大笑。七草はづき是《偶像大师 闪耀色彩》的角色，版权归 ©Bandai Namco Entertainment Inc. 所有；这是非官方的粉丝创作，与版权方无关。
- 卡片本身是礼物插画的「柔和平涂」（见 `public/gifts/CREDITS.md`），卡面上的她接近游戏原画的画风。
- 生成时给了三张参考图：一张网上流传的露齿笑自拍（只取构图和表情），七草はづき的游戏立绘（取人物），礼物插画 `plush.webp`（取卡片的画风）。提示词：

  > Item illustration for a mobile game: a single trading-card-like "reset card", tilted slightly in three-quarter view, centered. The card itself (frame, edges, back-plate) is drawn in soft flat vector style matching the third reference image: gentle pastel colours (soft mint green and cream), subtle soft shading, no harsh outlines, simple rounded corners. On the card face is a head-and-shoulders portrait of the anime girl from the second reference image (Hazuki Nanakusa: olive-green hair tied up in a loose bun with side locks, brown eyes, white collared shirt, dark navy cardigan, green tie), drawn in her official anime game-art style like the second reference. Her pose and expression copy the first reference photo: head tilted slightly to the side, facing the viewer, a big warm open-mouthed toothy grin with squinting happy eyes, framed from chest up, plain warm beige wall behind her inside the card. Transparent background outside the card, no text or lettering anywhere, card fills about 75% of the frame.

- 模型没有给出透明底（棋盘格是画进去的），背景是从四周往里按「低饱和、很亮」抠掉的。
