/**
 * 第 5 幕 3D 场景的布景（.scratch/landing-memory-3d/spec.md「场景内容」）：memoryLayer.ts 建场景时搭上去，每帧按这一刻的
 * 那件事（model/memoryStory.ts 的 storyAt）和时间让它动。位置和配色照原型（prototype/landing-memory-3d 的 world.ts）。
 *
 * - 闪耀色彩的东西是主体：远处 283 事务所的楼（窗灯、「283 PRODUCTION」的字，楼顶什么都不放）；每座岛两根她印象色的
 *   应援棒路灯；真乃的樱花树和飘落的花瓣；果穗身后的拱门；冬优子的尖塔和自拍补光灯；雾子的小房子和花箱。不用任何官方
 *   logo、组合 logo（ADR-0016）。
 * - AI 的梗只作点缀，压暗、缩小：背景稀疏的 embedding 星图（发送那一位收进记忆时多亮一颗她颜色的点）；果穗拱门里低不透明度
 *   滚动的 token；转台旁一闪而过的「temperature 0.7」；远处刻着「ATTENTION IS ALL YOU NEED」的石碑；少量上飘的 token 粒子。
 * - 夜色里缓慢转动的云、漂浮的小方块。
 * - 滚动停下时只有花瓣、粒子、云这类轻微的动，都按时间算（不按帧累加），帧率高低不改变快慢。
 *
 * 画布上的字（楼牌、石碑、token、temperature）用系统字体：落地页的字体子集只收文案里的字。
 */

import {
  AdditiveBlending,
  BoxGeometry,
  BufferAttribute,
  BufferGeometry,
  Color,
  ConeGeometry,
  CylinderGeometry,
  DoubleSide,
  Group,
  InstancedMesh,
  LineBasicMaterial,
  LineSegments,
  Matrix4,
  Mesh,
  NearestFilter,
  PlaneGeometry,
  Points,
  PointsMaterial,
  RepeatWrapping,
  TorusGeometry,
  Vector3,
} from "three";

import { canvasTexture, type Kit, PILLAR_FOOT, pillarGeometry, pillSprite, seeded } from "./memoryKit";
import { ISLANDS, type Actor, type Vec3 } from "./model/memory";
import { EMBEDDING_STAR, TURNTABLE, type MemoryStory } from "./model/memoryStory";

/** 每座岛上两根应援棒路灯的 (x, z)，按岛的顺序。 */
const LAMPS: readonly (readonly [number, number])[][] = [
  [[1.3, 1.3], [-1.3, 1.3]],
  [[6.3, 1.3], [3.7, 1.3]],
  [[6.3, 6.3], [6.3, 3.7]],
  [[11.3, 1.3], [8.7, -1.3]],
];
/** 岛上没有人时路灯的颜色：没有她的印象色，用柱顶的淡紫。 */
const LAMP_IDLE = "#e6dbf2";
/** 真乃的樱花树的 (x, z)。 */
const TREE = [-1.05, -1.05] as const;
/** 283 事务所那栋楼：中心的 (x, z)、边长、楼顶的高度。 */
const TOWER = { x: -1.6, z: -5.4, w: 2.2, top: 1.0 };
/** embedding 星图：围着这一点的一团，半径这么大，只留浮岛后面离镜头远的那一半（x + z 小的那边）。 */
const STARS = { center: [4, -3, 1] as Vec3, radius: 26, count: 260 };
/** 星图上她那颗点亮起来时，光团多大（世界单位）、连向近邻的线多不透明：AI 的梗，压暗缩小。 */
const SENDER_GLOW = 0.7;
const SENDER_LINES = 0.25;
/** 花瓣、上飘的 token 粒子全量时多少颗。 */
const PETALS = 50;
const TOKENS = 140;
/** 上飘的 token 在这一段高度里循环。 */
const TOKEN_FLOOR = -9;
const TOKEN_SPAN = 17;
/** 写 token、temperature 这些字的字体。 */
const MONO = "ui-monospace, Menlo, Consolas, monospace";

export type Dressing = {
  /** 这一刻的布景：`time` 是秒。 */
  update(story: MemoryStory, time: number): void;
  /** 花瓣、token 粒子画全部的几分之几（画质表的 particles）。 */
  setParticles(share: number): void;
};

/** 在 `kit.scene` 里搭上布景。`actors` 给路灯、粒子上色，`memory` 是记忆的颜色（发送那一位的印象色）。 */
export function dressScene(kit: Kit, actors: readonly Actor[], memory: Color): Dressing {
  const { scene, own, lambert, basic, glow, place, pillarMat } = kit;
  const pillar = (spec: Parameters<typeof pillarGeometry>[0]) => place(new Mesh(own(pillarGeometry(spec)), pillarMat), scene);
  const colorOf = (island: number) => actors.find((a) => a.island === island)?.color ?? LAMP_IDLE;

  // —— 每座岛两根她印象色的应援棒路灯。
  const poleGeo = own(new BoxGeometry(0.05, 0.75, 0.05));
  const stickGeo = own(new CylinderGeometry(0.065, 0.065, 0.34, 10));
  const poleMat = lambert({ color: "#3b3350" });
  ISLANDS.forEach(([, y], k) => {
    const stickMat = basic({ color: colorOf(k) });
    for (const [x, z] of LAMPS[k]) {
      place(new Mesh(poleGeo, poleMat), scene, x, y + 0.375, z);
      place(new Mesh(stickGeo, stickMat), scene, x, y + 0.92, z);
      glow(colorOf(k), 0.9, scene).position.set(x, y + 0.95, z);
    }
  });

  // —— 真乃：樱花树（一份网格画满树冠的小方块）和飘落的花瓣。
  const [tx, tz] = TREE;
  pillar({ w: 0.22, top: 1.1, depth: 1.1, x: tx, z: tz, color: "#7a5244", topColor: "#8e6050" });
  place(new Mesh(own(new BoxGeometry(0.12, 0.5, 0.12)), lambert({ color: "#7a5244" })), scene, tx + 0.2, 1.05, tz).rotation.z = -0.6;
  {
    const BLOSSOMS = 46;
    const shades = ["#ffc7dc", "#ffb0cc", "#ffe0ec", "#f7a1c0"].map((c) => new Color(c));
    const crown = place(
      own(new InstancedMesh(own(new BoxGeometry(1, 1, 1)), lambert({ color: "#ffffff", emissive: "#ff9cc0", emissiveIntensity: 0.12 }), BLOSSOMS)),
      scene,
    );
    const rnd = seeded(3);
    const m = new Matrix4();
    for (let i = 0; i < BLOSSOMS; i++) {
      const a = rnd() * Math.PI * 2;
      const r = Math.sqrt(rnd()) * 0.8;
      const y = 1.45 + (rnd() - 0.4) * 0.6;
      const s = 0.18 + rnd() * 0.16;
      crown.setMatrixAt(i, m.makeScale(s, s, s).setPosition(tx + Math.cos(a) * r, y, tz + Math.sin(a) * r));
      crown.setColorAt(i, shades[i % shades.length]);
    }
  }
  const petalRnd = seeded(5);
  const petalSeeds = Array.from({ length: PETALS }, () => petalRnd() * 100);
  const petals = points(own, PETALS, own(new PointsMaterial({ color: "#ffc2d8", size: 4, sizeAttenuation: false, transparent: true, opacity: 0.9 })));
  scene.add(petals.points);

  // —— 果穗：身后的拱门，里面低不透明度地滚着分词器那样一块块上色的 token。
  pillar({ w: 0.35, top: 2.15, depth: 2.15, x: 4, z: -1.1, color: "#9a86c0" });
  pillar({ w: 0.35, top: 2.15, depth: 2.15, x: 6, z: -1.1, color: "#9a86c0" });
  pillar({ w: 2.35, d: 0.35, top: 2.32, depth: 0.35, x: 5, z: -1.1, color: "#b39ad6", topColor: "#efe4fa" });
  const tokens = own(tokenTexture());
  tokens.wrapT = RepeatWrapping;
  place(new Mesh(own(new PlaneGeometry(1.62, 1.95)), basic({ map: tokens, transparent: true, opacity: 0.32, side: DoubleSide, depthWrite: false })), scene, 5, 0.99, -1.1);

  // —— 冬优子：尖塔和一盏自拍用的环形补光灯。
  pillar({ w: 0.8, top: -1.2, depth: 0.8, x: 3.95, z: 4, color: "#9a86c0" });
  place(new Mesh(own(new ConeGeometry(0.42, 1.4, 4)), lambert({ color: "#7ee6c0" })), scene, 3.95, -0.5, 4).rotation.y = Math.PI / 4;
  {
    const ring = place(new Group(), scene, 3.85, -2, 5.95);
    ring.rotation.y = 0.9;
    place(new Mesh(own(new BoxGeometry(0.05, 0.95, 0.05)), lambert({ color: "#2b2633" })), ring, 0, 0.47, 0);
    place(new Mesh(own(new TorusGeometry(0.3, 0.045, 10, 36)), basic({ color: "#fff6ea" })), ring, 0, 1.2, 0);
    place(new Mesh(own(new BoxGeometry(0.13, 0.24, 0.02)), lambert({ color: "#1b1a22" })), ring, 0, 1.2, 0);
    glow("#fff1dc", 1.4, ring).position.set(0, 1.2, 0);
  }

  // —— 雾子：小房子（门里亮着灯）和一排花箱。
  pillar({ w: 1, top: 2.9, depth: 0.9, x: 10.95, z: -1, color: "#9a86c0" });
  place(new Mesh(own(new ConeGeometry(0.85, 0.55, 4)), lambert({ color: "#bfe4f7" })), scene, 10.95, 3.17, -1).rotation.y = Math.PI / 4;
  place(new Mesh(own(new BoxGeometry(0.3, 0.5, 0.02)), basic({ color: "#ffd99a" })), scene, 10.95, 2.3, -0.49);
  place(new Mesh(own(new BoxGeometry(1.2, 0.24, 0.34)), lambert({ color: "#efe7f7" })), scene, 9, 2.12, 1.25);
  {
    const stemGeo = own(new BoxGeometry(0.03, 0.2, 0.03));
    const headGeo = own(new BoxGeometry(0.1, 0.1, 0.1));
    const stemMat = lambert({ color: "#6fbf73" });
    ["#ffffff", "#ffe27a", "#bfe0ff", "#ffc4d8", "#ffffff"].forEach((c, i) => {
      const x = 8.55 + i * 0.22;
      place(new Mesh(stemGeo, stemMat), scene, x, 2.33, 1.25);
      place(new Mesh(headGeo, lambert({ color: c, emissive: c, emissiveIntensity: 0.2 })), scene, x, 2.46, 1.25);
    });
  }

  // —— 转台旁一闪而过的「temperature 0.7」：总画在最上面，不被转台挡住。
  const temperature = place(pillSprite(own, "temperature 0.7", { font: `600 44px ${MONO}`, bg: "rgba(20,16,40,0.35)", fg: "rgba(243,238,255,0.6)" }, 0.16), scene, TURNTABLE[0], TURNTABLE[1] + 0.75, TURNTABLE[2] + 0.35);
  temperature.material.depthTest = false;
  temperature.renderOrder = 10;

  // —— 远处 283 事务所的楼：两面窗灯，正面「283 PRODUCTION」的牌子，楼顶什么都不放。
  pillar({ w: TOWER.w, top: TOWER.top, depth: TOWER.top - PILLAR_FOOT, fade: 12, x: TOWER.x, z: TOWER.z, color: "#6f5d99", topColor: "#cfc0e6" });
  const windows = own(windowsTexture());
  const windowMat = basic({ map: windows, transparent: true, depthWrite: false });
  const windowGeo = own(new PlaneGeometry(TOWER.w - 0.2, 8));
  const face = TOWER.w / 2 + 0.011;
  place(new Mesh(windowGeo, windowMat), scene, TOWER.x, TOWER.top - 4.3, TOWER.z + face);
  place(new Mesh(windowGeo, windowMat), scene, TOWER.x + face, TOWER.top - 4.3, TOWER.z).rotation.y = Math.PI / 2;
  place(new Mesh(own(new PlaneGeometry(1.5, 0.75)), basic({ map: own(signTexture()) })), scene, TOWER.x, TOWER.top - 0.22, TOWER.z + face + 0.01);

  // —— 浮空的石碑：ATTENTION IS ALL YOU NEED。
  const tablet = place(new Group(), scene, -4.4, -3, 4.2);
  tablet.scale.setScalar(0.8);
  tablet.rotation.y = Math.PI / 4;
  place(new Mesh(own(new BoxGeometry(1.5, 2.1, 0.28)), lambert({ color: "#8a7fa6" })), tablet);
  place(new Mesh(own(new BoxGeometry(1.7, 0.2, 0.4)), lambert({ color: "#a497c0" })), tablet, 0, 1.12, 0);
  const rubble = lambert({ color: "#6c6088" });
  place(new Mesh(own(new BoxGeometry(0.6, 0.4, 0.5)), rubble), tablet, 0.2, -1.3, 0.05);
  place(new Mesh(own(new BoxGeometry(0.3, 0.3, 0.3)), rubble), tablet, -0.35, -1.75, 0);
  place(new Mesh(own(new PlaneGeometry(1.36, 1.9)), basic({ map: own(engravingTexture()), transparent: true })), tablet, 0, 0, 0.145);

  // —— embedding 星图：背后稀疏的一团点，近邻连着淡淡的线；收进记忆时多亮一颗她颜色的点（模型定的位置），连向离它最近的几颗。
  const stars = starPoints();
  /** 离 `at` 最近的 `k` 颗（不算它自己）。 */
  const near = (at: Vector3, k: number) =>
    stars
      .filter((q) => q !== at)
      .sort((a, b) => a.distanceToSquared(at) - b.distanceToSquared(at))
      .slice(0, k);
  const edges = stars.flatMap((s) => near(s, 2).flatMap((q) => (s.distanceTo(q) < 5 ? [s, q] : [])));
  scene.add(new Points(own(new BufferGeometry().setFromPoints(stars)), own(new PointsMaterial({ color: "#d8d0ff", size: 2.2, sizeAttenuation: false, transparent: true, opacity: 0.45 }))));
  scene.add(new LineSegments(own(new BufferGeometry().setFromPoints(edges)), own(new LineBasicMaterial({ color: "#8f84c9", transparent: true, opacity: 0.05 }))));
  const senderStar = new Vector3(...EMBEDDING_STAR);
  const senderLines = own(new LineBasicMaterial({ color: memory, transparent: true, opacity: 0 }));
  scene.add(new LineSegments(own(new BufferGeometry().setFromPoints(near(senderStar, 5).flatMap((q) => [senderStar, q]))), senderLines));
  const senderGlow = glow(memory, 0, scene);
  senderGlow.position.copy(senderStar);

  // —— 少量上飘的 token 粒子（几位的颜色和白、淡紫）。
  const palette = [...actors.map((a) => a.color), "#ffffff", "#bcb2ff"].map((c) => new Color(c));
  const rnd = seeded(29);
  const drift = Array.from({ length: TOKENS }, (_, i) => ({
    x: -6 + rnd() * 22,
    y: rnd() * TOKEN_SPAN,
    z: -6 + rnd() * 15,
    speed: 0.12 + rnd() * 0.3,
    color: palette[i % palette.length],
  }));
  const rising = points(own, TOKENS, own(new PointsMaterial({ size: 2.5, sizeAttenuation: false, vertexColors: true, transparent: true, opacity: 0.35, blending: AdditiveBlending, depthWrite: false })));
  const tint = new Float32Array(TOKENS * 3);
  drift.forEach((d, i) => tint.set(d.color.toArray(), i * 3));
  rising.points.geometry.setAttribute("color", new BufferAttribute(tint, 3));
  scene.add(rising.points);

  // —— 底下缓慢转动的两层云。
  const cloud = own(cloudTexture());
  const cloudGeo = own(new PlaneGeometry(30, 30));
  const clouds = [
    { y: -5.2, color: "#7d6fb8", opacity: 0.45, spin: 0.01 },
    { y: -6.6, color: "#4a3d80", opacity: 0.7, spin: -0.006 },
  ].map((c) => {
    const m = place(new Mesh(cloudGeo, basic({ map: cloud, color: c.color, transparent: true, opacity: c.opacity, depthWrite: false })), scene, 5, c.y, 1);
    m.rotation.x = -Math.PI / 2;
    return { m, spin: c.spin };
  });

  // —— 漂浮的小方块。
  const floatGeo = own(new BoxGeometry(0.35, 0.35, 0.35));
  const floaters = (
    [
      [-2.6, 1.4, 2.4, "#f1c9d9"],
      [7.7, 2.8, -2.4, "#bfe4f7"],
      [8.4, -1.6, 4.2, "#c7f0b3"],
      [1.6, 2.6, -2.6, "#ffd2bf"],
      [2.2, -2.2, 3.4, "#b39ad6"],
      [12.6, 0.2, 3.2, "#ffd59a"],
    ] as const
  ).map(([x, y, z, c], k) => ({ m: place(new Mesh(floatGeo, lambert({ color: c })), scene, x, y, z), y, phase: k * 1.7 }));

  return {
    update(story, time) {
      tokens.offset.y = (time * 0.04) % 1;
      temperature.visible = story.temperature > 0;
      temperature.material.opacity = story.temperature;
      senderGlow.scale.setScalar(SENDER_GLOW * story.embedding * (1 + Math.sin(time * 2) * 0.15));
      senderLines.opacity = SENDER_LINES * story.embedding;

      petalSeeds.forEach((sd, i) => {
        const t = (time * 0.12 + sd) % 1;
        petals.position.set([tx + Math.sin(sd * 3) * 0.9 + t * 1.6 + Math.sin(time + sd) * 0.15, 1.6 - t * 2.4, tz + Math.cos(sd * 5) * 0.9 + t * 0.8], i * 3);
      });
      petals.changed();
      drift.forEach((d, i) => rising.position.set([d.x, TOKEN_FLOOR + ((d.y + d.speed * time) % TOKEN_SPAN), d.z], i * 3));
      rising.changed();

      for (const c of clouds) c.m.rotation.z = time * c.spin;
      tablet.position.y = -3 + Math.sin(time * 0.7) * 0.1;
      for (const f of floaters) f.m.position.y = f.y + Math.sin(time * 0.8 + f.phase) * 0.15;
    },
    setParticles(share) {
      petals.points.geometry.setDrawRange(0, Math.round(PETALS * share));
      rising.points.geometry.setDrawRange(0, Math.round(TOKENS * share));
    },
  };
}

/** `count` 个点，位置每帧改写：改完调 `changed`。包围球按建的时候的位置算，跟不上，不做视锥裁剪。 */
function points(own: Kit["own"], count: number, material: PointsMaterial) {
  const position = new Float32Array(count * 3);
  const geometry = own(new BufferGeometry());
  geometry.setAttribute("position", new BufferAttribute(position, 3));
  const points = new Points(geometry, material);
  points.frustumCulled = false;
  return {
    points,
    position,
    changed: () => (geometry.getAttribute("position").needsUpdate = true),
  };
}

/** embedding 星图的点：球里均匀撒，只留镜头那一侧的后面。 */
function starPoints(): Vector3[] {
  const { center, radius, count } = STARS;
  const rnd = seeded(17);
  const stars: Vector3[] = [];
  while (stars.length < count) {
    const v = new Vector3(rnd() * 2 - 1, rnd() * 2 - 1, rnd() * 2 - 1);
    if (v.lengthSq() > 1) continue;
    v.multiplyScalar(radius).add(new Vector3(...center));
    if (v.x + v.z - (center[0] + center[2]) > -9) continue;
    stars.push(v);
  }
  return stars;
}

/** 拱门里滚的 token：分词器那样一块块上色的词，竖着能接上，循环滚。 */
function tokenTexture() {
  const words = ["<bos>", "下周", "考试", "了", "，", "有点", "紧张", "。", "加油", "ファイト", "です", "！", "真乃", "说", "<eos>", "▁mem", "ory", "▁you", "了解", "…"];
  const chips = ["#ffbad6", "#ffd59a", "#b9f0c6", "#bfe0ff", "#e2c8ff", "#ffcbb8"];
  return canvasTexture(256, 512, (g) => {
    g.fillStyle = "rgba(170,200,255,0.12)";
    g.fillRect(0, 0, 256, 512);
    g.font = `600 22px ${MONO}, sans-serif`;
    g.textBaseline = "middle";
    let k = 0;
    for (let y = 10; y < 512; y += 34) {
      let x = 10;
      while (x < 240) {
        const w = words[k % words.length];
        const tw = g.measureText(w).width + 12;
        if (x + tw > 248) break;
        g.fillStyle = chips[(k * 7) % chips.length];
        g.globalAlpha = 0.85;
        g.beginPath();
        g.roundRect(x, y, tw, 26, 5);
        g.fill();
        g.globalAlpha = 1;
        g.fillStyle = "#1e1838";
        g.fillText(w, x + 6, y + 14);
        x += tw + 5;
        k++;
      }
      k += 3;
    }
  });
}

/** 楼上的窗：一格格，少数亮着暖色的灯。放大时不糊，一格是一格。 */
function windowsTexture() {
  const t = canvasTexture(64, 256, (g) => {
    const rnd = seeded(5);
    for (let y = 6; y < 256; y += 14)
      for (let x = 5; x < 60; x += 11) {
        const lit = rnd() < 0.28;
        g.fillStyle = lit ? `rgba(255,${200 + Math.floor(rnd() * 40)},150,${0.35 + rnd() * 0.3})` : "rgba(40,32,72,0.45)";
        g.fillRect(x, y, 7, 8);
      }
  });
  t.magFilter = NearestFilter;
  return t;
}

/** 楼的牌子：深蓝底上白字「283」，下面一行「PRODUCTION」。只是字，不是官方 logo。 */
function signTexture() {
  return canvasTexture(256, 128, (g) => {
    g.fillStyle = "#1c2a4a";
    g.beginPath();
    g.roundRect(0, 0, 256, 128, 14);
    g.fill();
    g.fillStyle = "#ffffff";
    g.textAlign = "center";
    g.font = "800 70px Georgia, 'Times New Roman', serif";
    g.fillText("283", 128, 78);
    g.font = "600 18px ui-sans-serif, system-ui, sans-serif";
    g.fillStyle = "#cfe0ff";
    g.fillText("P R O D U C T I O N", 128, 110);
  });
}

/** 石碑上刻的字。 */
function engravingTexture() {
  return canvasTexture(300, 420, (g) => {
    g.fillStyle = "#6e6390";
    g.textAlign = "center";
    g.font = "700 40px Georgia, 'Times New Roman', serif";
    ["ATTENTION", "IS ALL", "YOU NEED"].forEach((l, i) => g.fillText(l, 150, 110 + i * 62));
    g.font = "italic 22px Georgia, serif";
    g.fillText("— 1706.03762 —", 150, 330);
    g.strokeStyle = "#7a6f9c";
    g.lineWidth = 3;
    g.strokeRect(18, 18, 264, 384);
  });
}

/** 云：一团团白色的径向渐变叠起来，越往外越淡；按材质的颜色上色。 */
function cloudTexture() {
  return canvasTexture(512, 512, (g) => {
    const rnd = seeded(23);
    for (let i = 0; i < 120; i++) {
      const a = rnd() * Math.PI * 2;
      const d = Math.sqrt(rnd()) * 200;
      const x = 256 + Math.cos(a) * d;
      const y = 256 + Math.sin(a) * d;
      const r = 30 + rnd() * 70;
      const grad = g.createRadialGradient(x, y, 0, x, y, r);
      grad.addColorStop(0, `rgba(255,255,255,${(0.22 * (1 - d / 220)).toFixed(3)})`);
      grad.addColorStop(1, "rgba(255,255,255,0)");
      g.fillStyle = grad;
      g.fillRect(x - r, y - r, r * 2, r * 2);
    }
  });
}
