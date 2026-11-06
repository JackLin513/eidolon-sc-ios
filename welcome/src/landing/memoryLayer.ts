/**
 * 第 5 幕「记忆」的 3D 场景（.scratch/landing-memory-3d）：一张单独的 three.js 画布（WebGL 渲染器，ADR-0016 的修订），
 * 固定铺满视口、叠在光层上面，把落地页模型给的第 5 幕场景状态（model/memory.ts 的 MemoryScene，和
 * model/memoryStory.ts 按进度算出的那件事）画出来。three.js 和这个模块只在运动档、滚到第 5 幕前约一屏时才由
 * LightStage 动态 import（three.js 和第 4 幕的手机共用一个包，这里的场景代码单独一个包），不进首屏。
 *
 * - 相机照模型摆：正交相机，注视点、取景半高、方位角都是模型给的，和 DOM 上按 project 摆的东西同一个出处。
 * - 场景：夜空渐变和星星（铺在画面上，不随镜头转）；四座浮岛的柱子，顶面亮、两侧一明一暗、往下渐隐进夜色；
 *   演员脚下她印象色的地砖。布景（283 事务所的楼、应援棒路灯、各人岛上的东西、AI 的梗、云和粒子）在 memoryDressing.ts。
 * - 体素小人：从角色接口给的地址下载体素文件（scripts/glb-voxelize.mts 的格式，不等它：布景先画），每人露在外面的面合成一份网格，
 *   顶点色，顶面、底面压到 0.86、0.78 留住方块感；按 `front` 缩放到场景里的身高，轻轻起伏。跳动、后仰、朝向照模型的
 *   动作摆。地址没有、下载或解析失败时，站着的是她印象色的小方块，上面写她的名字。下载、合成一次，记在模块里：
 *   手机上离开这一段释放了上下文，回来时重建渲染器，不重新下载。
 * - 一件事传开（model/memoryStory.ts 的 storyAt，跟这个模块一起晚加载；LightStage 每帧算一次交给 render，DOM 上的几句话
 *   也按它摆）：天上的手机、制作人的消息（深蓝气泡，变成方块）、每座岛的记忆柱（三层圆盘、一排小灯，收进时闪成发送
 *   那一位的颜色）、转台（把手）、台阶、副本、走过时亮起的桥面、收尾的连线，都照模型摆。记忆方块、柱灯、桥面、台阶、连线一律用发送那一位（真乃）的印象色：传到谁那里都是她的
 *   颜色（来源角色）。
 * - 档位（画质表 model/tier.ts）：DPR 按档位封顶；完整档有主光投下的阴影和泛光（UnrealBloomPass，原型的参数），简化档、
 *   basic 档没有，花瓣和 token 粒子减半。按帧降档时就地关掉，场景照常。
 */

import {
  AdditiveBlending,
  BoxGeometry,
  BufferAttribute,
  BufferGeometry,
  type Camera,
  type CanvasTexture,
  Color,
  CylinderGeometry,
  DirectionalLight,
  Group,
  HalfFloatType,
  HemisphereLight,
  type Material,
  Mesh,
  MeshBasicMaterial,
  MeshLambertMaterial,
  type Object3D,
  OrthographicCamera,
  PlaneGeometry,
  QuadraticBezierCurve3,
  Scene,
  Sprite,
  SpriteMaterial,
  SRGBColorSpace,
  type Texture,
  TubeGeometry,
  Vector2,
  Vector3,
  WebGLRenderer,
  WebGLRenderTarget,
} from "three";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";

import type { CanvasLayer } from "./canvasStage";
import { idle } from "./idle";
import { dressScene } from "./memoryDressing";
import { canvasTexture, fadeIntoNight, glowTexture, type Kit, NIGHT, PILLAR_FOOT, pillarGeometry, pillSprite, seeded } from "./memoryKit";
import { cameraBasis, FIGURE_HEIGHT, ISLAND_SIZE, ISLANDS, type Actor, type MemoryScene } from "./model/memory";
import {
  BLOCK,
  BRIDGE,
  MEMORY_PILLAR_HEIGHT,
  MEMORY_PILLARS,
  memoryTop,
  type MemoryStory,
  PHONE,
  STANDS,
  STEPS,
  THREADS,
  TURNTABLE,
} from "./model/memoryStory";
import type { Quality } from "./model/tier";

/** 体素文件（scripts/glb-voxelize.mts 的 Voxels）。 */
type Voxels = {
  size: [w: number, h: number, d: number];
  front: number;
  palette: string[];
  voxels: number[];
};

/** 一位小人露在外面的面合成的网格，脚底在原点、正面朝 +z。 */
type FigureMesh = { position: Float32Array; normal: Int8Array; color: Float32Array; index: Uint32Array };

/** 体素文件下载多久没回来就当加载失败。 */
const VOXELS_TIMEOUT_MS = 30000;
/** 顶面、底面的颜色压到这么多：表面是一级级台阶，压得太狠每一级都成了一道横纹，不压顶面又迎着光成了亮线。 */
const TOP_SHADE = 0.86;
const BOTTOM_SHADE = 0.78;
/** 小人自己亮一点：夜色的紫光下肤色发灰，在自发光里加上一份自己的底色。 */
const FIGURE_LIFT = 0.18;
/** 相机退到注视点后面多远：正交投影，远近只管裁切。 */
const CAMERA_DISTANCE = 50;
/** 主光的阴影：贴图边长（像素），盖住整片布景的范围（主光的正交相机，世界单位）。 */
const SHADOW_MAP = 2048;
const SHADOW_REACH = 14;
/** 泛光（原型的参数）：强度、半径、亮到多少才泛光。 */
const BLOOM = { strength: 0.5, radius: 0.55, threshold: 0.94 };
/** 收到时跳起多高、身子压扁拉长多少；真乃接住时往后仰多少（弧度）。 */
const HOP_HEIGHT = 0.3;
const HOP_SQUASH = 0.05;
const HOP_STRETCH = 0.08;
const REACH_LEAN = 0.08;
/** 记忆柱的小灯平时的颜色：一明一暗地闪；收进以后刷成发送那一位的颜色这么多。 */
const LED_IDLE = "#6ff0d0";
const LED_STORED = 0.6;
/** 天上那台手机的屏幕乘上这个颜色：压在泛光的门槛下面。 */
const PHONE_SCREEN = "#e0e0e0";
/** 制作人的消息的颜色：深蓝气泡（和 DOM 上制作人的气泡同一个颜色）。 */
const PRODUCER_INK = "#1c2a4a";
/** 台阶没升起来时藏在下面多深。 */
const STEP_DROP = 7;
/** 连线中间拱起多高。 */
const THREAD_ARCH = 1.4;

const figures = new Map<string, Promise<FigureMesh>>();

/** 下载、合成一位小人的网格；同一页里同一个地址只做一次（失败了下次重试）。 */
function loadFigure(url: string): Promise<FigureMesh> {
  let mesh = figures.get(url);
  if (!mesh) {
    mesh = fetch(url, { signal: AbortSignal.timeout(VOXELS_TIMEOUT_MS) })
      .then((res) => {
        if (!res.ok) throw new Error(`体素文件 ${res.status}`);
        return res.json() as Promise<unknown>;
      })
      .then((data) => figureMesh(asVoxels(data)))
      .catch((e: unknown) => {
        figures.delete(url);
        throw e;
      });
    figures.set(url, mesh);
  }
  return mesh;
}

function asVoxels(data: unknown): Voxels {
  const v = data as Partial<Voxels> | null;
  const ok =
    !!v &&
    Array.isArray(v.size) &&
    v.size.length === 3 &&
    v.size.every((n) => Number.isInteger(n) && n > 0) &&
    typeof v.front === "number" &&
    v.front > 0 &&
    Array.isArray(v.palette) &&
    Array.isArray(v.voxels) &&
    v.voxels.length % 4 === 0;
  if (!ok) throw new Error("体素文件的格式不对");
  return v as Voxels;
}

/** 每个方向的面：法线和逆时针（从外面看）的四个角。 */
const FACES: readonly { n: [number, number, number]; corners: [number, number, number][]; shade: number }[] = [
  { n: [1, 0, 0], corners: [[1, 0, 0], [1, 1, 0], [1, 1, 1], [1, 0, 1]], shade: 1 },
  { n: [-1, 0, 0], corners: [[0, 0, 0], [0, 0, 1], [0, 1, 1], [0, 1, 0]], shade: 1 },
  { n: [0, 1, 0], corners: [[0, 1, 0], [0, 1, 1], [1, 1, 1], [1, 1, 0]], shade: TOP_SHADE },
  { n: [0, -1, 0], corners: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]], shade: BOTTOM_SHADE },
  { n: [0, 0, 1], corners: [[0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]], shade: 1 },
  { n: [0, 0, -1], corners: [[0, 0, 0], [0, 1, 0], [1, 1, 0], [1, 0, 0]], shade: 1 },
];

/** 体素合成一份网格：只要露在外面的面（旁边那一格是空的），一格一种颜色。按 `front` 缩放到场景里的身高。 */
function figureMesh(v: Voxels): FigureMesh {
  const [W, H, D] = v.size;
  const size = FIGURE_HEIGHT / v.front;
  const solid = new Uint8Array(W * H * D);
  const cells: number[] = [];
  const inside = (x: number, y: number, z: number) => x >= 0 && y >= 0 && z >= 0 && x < W && y < H && z < D;
  for (let i = 0; i < v.voxels.length; i += 4) {
    const [x, y, z, c] = [v.voxels[i], v.voxels[i + 1], v.voxels[i + 2], v.voxels[i + 3]];
    if (!inside(x, y, z) || !v.palette[c]) continue;
    solid[x + W * (y + H * z)] = 1;
    cells.push(x, y, z, c);
  }
  const filled = (x: number, y: number, z: number) => inside(x, y, z) && solid[x + W * (y + H * z)] === 1;
  // 调色板转成线性色（顶点色在线性空间里算光照）。
  const linear = v.palette.map((hex) => new Color(hex).toArray() as [number, number, number]);

  let faces = 0;
  for (let i = 0; i < cells.length; i += 4)
    for (const f of FACES) if (!filled(cells[i] + f.n[0], cells[i + 1] + f.n[1], cells[i + 2] + f.n[2])) faces++;
  const position = new Float32Array(faces * 12);
  const normal = new Int8Array(faces * 12);
  const color = new Float32Array(faces * 12);
  const index = new Uint32Array(faces * 6);
  let k = 0;
  for (let i = 0; i < cells.length; i += 4) {
    const [x, y, z, c] = [cells[i], cells[i + 1], cells[i + 2], cells[i + 3]];
    const rgb = linear[c];
    for (const f of FACES) {
      if (filled(x + f.n[0], y + f.n[1], z + f.n[2])) continue;
      f.corners.forEach(([cx, cy, cz], j) => {
        const o = (k * 4 + j) * 3;
        position[o] = (x + cx - W / 2) * size;
        position[o + 1] = (y + cy) * size;
        position[o + 2] = (z + cz - D / 2) * size;
        normal[o] = f.n[0] * 127;
        normal[o + 1] = f.n[1] * 127;
        normal[o + 2] = f.n[2] * 127;
        color[o] = rgb[0] * f.shade;
        color[o + 1] = rgb[1] * f.shade;
        color[o + 2] = rgb[2] * f.shade;
      });
      index.set([k * 4, k * 4 + 1, k * 4 + 2, k * 4, k * 4 + 2, k * 4 + 3], k * 6);
      k++;
    }
  }
  return { position, normal, color, index };
}

export type MemoryLayer = CanvasLayer & {
  /** 画这一刻的场景，`story` 是这一刻那件事传到了哪一步；`time` 是秒，给小人的起伏用。 */
  render(memory: MemoryScene, story: MemoryStory, time: number): void;
  /** 演员都站上去以后，体素文件加载不到、换成了方块的那几位。渲染静止图的脚本等它。 */
  standIns: Promise<Actor[]>;
};

/**
 * 在 `canvas` 上建第 5 幕的场景，分几批建：建上下文、搭布景、编译着色器各占一批，每批之间让出主线程。建不起来时
 * reject，调用方收起画布。演员的体素文件同时开始下载，不等它们：布景先画出来，她站的地方先空着，网格合成好了再站上去，
 * 加载不到就换成她印象色的方块和名字（`font` 是写名字的字体）。
 */
export async function createMemoryLayer(canvas: HTMLCanvasElement, quality: Quality, actors: readonly Actor[], font: string): Promise<MemoryLayer> {
  const loading = actors.map((a) => (a.voxels ? loadFigure(a.voxels) : Promise.reject(new Error("没有体素文件"))));
  // 还没下载完就放掉了上下文：之后到的不再往场景里放。
  let destroyed = false;
  const dprOf = (q: Quality) => Math.min(window.devicePixelRatio || 1, q.dprCap);
  const renderer = new WebGLRenderer({ canvas, antialias: true });
  renderer.outputColorSpace = SRGBColorSpace;
  await idle();

  const owned: { dispose(): void }[] = [];
  const own = <T extends { dispose(): void }>(x: T) => (owned.push(x), x);
  const scene = new Scene();
  const glowMap = own(glowTexture());
  const kit: Kit = {
    scene,
    own,
    lambert: (params) => own(new MeshLambertMaterial(params)),
    basic: (params) => own(new MeshBasicMaterial(params)),
    glow(color, size, parent) {
      const s = new Sprite(own(new SpriteMaterial({ map: glowMap, color, blending: AdditiveBlending, depthWrite: false, transparent: true })));
      s.scale.setScalar(size);
      parent.add(s);
      return s;
    },
    place(o, parent, x = 0, y = 0, z = 0) {
      o.position.set(x, y, z);
      parent.add(o);
      return o;
    },
    pillarMat: fadeIntoNight(own(new MeshLambertMaterial({ vertexColors: true }))),
  };
  const { lambert, basic, glow, place, pillarMat } = kit;

  // —— 光：天光从上往下、偏紫；一盏暖色的主光从右前上方打来，柱子两侧一明一暗；一盏紫色的补光从背面。
  scene.add(new HemisphereLight(0xc9c2ff, 0x2a1f3d, 1.5));
  const sun = new DirectionalLight(0xffe2cc, 2.2);
  sun.position.set(2, 10, 7);
  sun.target.position.set(5, 0, 1);
  sun.shadow.mapSize.set(SHADOW_MAP, SHADOW_MAP);
  Object.assign(sun.shadow.camera, { left: -SHADOW_REACH, right: SHADOW_REACH, top: SHADOW_REACH, bottom: -SHADOW_REACH, near: 0.5, far: 50 });
  sun.shadow.bias = -0.0005;
  sun.shadow.normalBias = 0.02;
  scene.add(sun, sun.target);
  const fill = new DirectionalLight(0x8a7cff, 0.6);
  fill.position.set(8, 2, -2);
  scene.add(fill);

  // —— 夜空：渐变和星星，按画面的宽高比画，星星不被拉成椭圆。
  let skyAspect = 0;
  let sky: Texture | null = null;
  const paintSky = (aspect: number) => {
    sky?.dispose();
    sky = skyTexture(aspect);
    scene.background = sky;
    skyAspect = aspect;
  };

  // —— 四座浮岛：柱子和一圈沿，往下渐隐进夜色。
  ISLANDS.forEach(([x, y, z]) => {
    scene.add(new Mesh(own(pillarGeometry({ w: ISLAND_SIZE, top: y, depth: y - PILLAR_FOOT, fade: 10 + y, x, z })), pillarMat));
    scene.add(new Mesh(own(pillarGeometry({ w: ISLAND_SIZE + 0.12, top: y - 0.12, depth: 0.35, x, z, color: "#a893c9", topColor: "#cdbde6" })), pillarMat));
  });

  // —— 演员：脚下她印象色的地砖，站着她的体素小人（加载不到时是她印象色的方块和名字）。
  const tileGeo = own(new BoxGeometry(0.9, 0.04, 0.9));
  const blob = own(shadowTexture());
  const blobGeo = own(new PlaneGeometry(0.84, 0.84));
  const blobMat = own(new MeshBasicMaterial({ map: blob, transparent: true, depthWrite: false }));
  const figureMat = lift(lambert({ vertexColors: true }));
  const cubeGeo = own(new BoxGeometry(0.55, 0.55, 0.55));
  // 站的地方（脚下的影子不跟着跳）里一层身子：跳起来、压扁拉长，先往后仰、再转朝向（YXZ：仰的是她自己的前后）。
  const bodies = new Map<number, Group>();
  // 小人投下阴影（完整档），自己身上不接：一级级的体素表面接阴影会起条纹。
  const stand = (body: Group) => (mesh: FigureMesh) => {
    if (destroyed) return null;
    const figure = new Mesh(own(figureGeometry(mesh)), figureMat);
    figure.castShadow = true;
    body.add(figure);
    return null;
  };
  const standIn = (actor: Actor, body: Group) => () => {
    if (destroyed) return actor;
    const cube = new Mesh(cubeGeo, lambert({ color: actor.color, emissive: actor.color, emissiveIntensity: 0.25 }));
    cube.castShadow = true;
    cube.position.y = 0.275;
    body.add(cube);
    const label = pillSprite(own, actor.name, { font: `600 44px ${font}`, bg: "rgba(20,16,40,0.78)", fg: "#f3eeff" }, 0.22);
    label.position.y = 0.95;
    body.add(label);
    return actor;
  };
  const standing = actors.map((actor, k) => {
    const [x, y, z] = STANDS[actor.island];
    const tile = new Mesh(tileGeo, lambert({ color: actor.color, emissive: actor.color, emissiveIntensity: 0.3 }));
    tile.position.set(x, y + 0.02, z);
    scene.add(tile);
    const group = new Group();
    group.position.set(x, y + 0.04, z);
    scene.add(group);
    const body = new Group();
    body.rotation.order = "YXZ";
    group.add(body);
    bodies.set(actor.island, body);
    const shadow = new Mesh(blobGeo, blobMat);
    shadow.rotation.x = -Math.PI / 2;
    shadow.position.y = 0.005;
    group.add(shadow);
    return loading[k].then(stand(body), standIn(actor, body));
  });
  await idle();

  // —— 一件事传开。记忆的颜色是发送那一位（第 0 座岛）的印象色；她不在时模型什么都不传，这些东西都不显出来。
  const memoryColor = new Color(actors.find((a) => a.island === 0)?.color ?? "#ffffff");

  // 天上那台制作人的手机：屏幕上是一段对话（只画气泡，不写字），消息发出来时亮一下。屏幕压暗一点：白屏本身过了泛光的
  // 门槛会被吹成一块白，要等亮起时叠上光晕才泛光。
  const phone = place(new Group(), scene, ...PHONE);
  phone.rotation.set(-0.12, Math.PI / 4, 0);
  place(new Mesh(own(new BoxGeometry(1.05, 2.05, 0.12)), lambert({ color: "#d9d6e2" })), phone);
  place(new Mesh(own(new PlaneGeometry(0.95, 1.92)), basic({ map: own(phoneScreenTexture(memoryColor)), color: PHONE_SCREEN })), phone, 0, 0, 0.065);
  const phoneGlow = glow("#ffd6e8", 3.2, phone);

  // 记忆方块：她颜色的一块，外面一圈光。
  const blockGeo = own(new BoxGeometry(BLOCK, BLOCK, BLOCK));
  const blockMat = basic({ color: memoryColor });
  const memoryBlock = (parent: Object3D) => {
    const g = place(new Group(), parent);
    const cube = place(new Mesh(blockGeo, blockMat), g);
    return { g, cube, glow: glow(memoryColor, 1.3, g) };
  };

  // 制作人的消息：深蓝的气泡（三个白点），落到她那里变成记忆方块。
  const message = place(new Group(), scene);
  const bubble = place(new Group(), message);
  const ink = lambert({ color: PRODUCER_INK, emissive: PRODUCER_INK, emissiveIntensity: 0.6 });
  place(new Mesh(own(new BoxGeometry(0.56, 0.34, 0.12)), ink), bubble);
  place(new Mesh(own(new BoxGeometry(0.12, 0.12, 0.12)), ink), bubble, 0.16, -0.2, 0);
  const dotGeo = own(new BoxGeometry(0.07, 0.07, 0.04));
  const dotMat = basic({ color: "#ffffff" });
  for (const x of [-0.14, 0, 0.14]) place(new Mesh(dotGeo, dotMat), bubble, x, 0, 0.07);
  glow("#a9c6f5", 1.4, bubble);
  const core = memoryBlock(message);

  // 记忆柱：数据库图标那样三层圆盘，前面一排小灯，柱顶收进来的那一块。
  const discGeo = own(new CylinderGeometry(0.25, 0.25, 0.14, 28));
  const capGeo = own(new CylinderGeometry(0.27, 0.27, 0.04, 28));
  const ledGeo = own(new BoxGeometry(0.06, 0.035, 0.02));
  const discMat = lambert({ color: "#cdbde6" });
  const capMat = lambert({ color: "#efe6fa" });
  const ledIdle = new Color(LED_IDLE);
  const pillars = MEMORY_PILLARS.map((at, k) => {
    const g = place(new Group(), scene, ...at);
    const leds = [0, 1, 2].map((j) => {
      const y = 0.09 + j * 0.17;
      place(new Mesh(discGeo, discMat), g, 0, y, 0);
      const led = basic({ color: LED_IDLE });
      const m = place(new Mesh(ledGeo, led), g, Math.SQRT1_2 * 0.25, y, Math.SQRT1_2 * 0.25);
      m.rotation.y = Math.PI / 4;
      return led;
    });
    place(new Mesh(capGeo, capMat), g, 0, MEMORY_PILLAR_HEIGHT, 0);
    const block = memoryBlock(scene);
    block.g.position.set(...memoryTop(k));
    return { leds, block };
  });

  // 传出去的几份，按去的那座岛。
  const copies = new Map([1, 2, 3].map((to) => [to, memoryBlock(scene)]));

  // 转台：底下一根圆柱，上面两块桥面和一个把手；转过 90° 接上两边。走过的桥面亮起她的颜色。
  place(new Mesh(own(new CylinderGeometry(0.7, 0.7, 6, 32)), lambert({ color: "#6f5f96" })), scene, TURNTABLE[0], TURNTABLE[1] - 3.25, TURNTABLE[2]);
  const turntable = place(new Group(), scene, ...TURNTABLE);
  const tileMat = () => lambert({ color: "#d9cbe8", emissive: memoryColor, emissiveIntensity: 0 });
  const walkGeo = own(new BoxGeometry(0.98, 0.25, 0.98));
  const bridge = BRIDGE.map((x) => {
    const m = tileMat();
    place(new Mesh(walkGeo, m), turntable, x, -0.125, 0);
    return m;
  });
  const knob = place(new Mesh(own(new CylinderGeometry(0.2, 0.22, 0.14, 24)), lambert({ color: "#ffd88a", emissive: "#ffb24a", emissiveIntensity: 0.35 })), turntable, 0, 0.07, 0);
  place(new Mesh(own(new BoxGeometry(0.05, 0.05, 0.2)), lambert({ color: "#5a3d10" })), knob, 0, 0.01, 0.1);

  // 台阶：升起来之前藏在下面，一级级升上来；走过的亮起她的颜色。
  const steps = STEPS.map((s) => {
    const m = tileMat();
    return { mesh: place(new Mesh(own(new BoxGeometry(...s.size)), m), scene, ...s.center), mat: m };
  });

  // 收尾的连线：柱顶到柱顶拱起的一根细光。
  const threadMat = () => basic({ color: memoryColor, transparent: true, opacity: 0, blending: AdditiveBlending, depthWrite: false });
  const threads = new Map(
    THREADS.map(([a, b]) => {
      const [pa, pb] = [new Vector3(...memoryTop(a)), new Vector3(...memoryTop(b))];
      const mid = pa.clone().lerp(pb, 0.5).add(new Vector3(0, THREAD_ARCH, 0));
      const m = place(new Mesh(own(new TubeGeometry(new QuadraticBezierCurve3(pa, mid, pb), 40, 0.022, 6)), threadMat()), scene);
      return [`${a}-${b}`, m];
    }),
  );
  await idle();

  // —— 布景：楼、路灯、各人岛上的东西、AI 的梗、云和粒子。
  const dressing = dressScene(kit, actors, memoryColor);
  // 不透明的东西投下、接住阴影（完整档）；之后才站上去的小人自己设。
  scene.traverse((o) => {
    if (o instanceof Mesh && !(o.material as Material).transparent) o.castShadow = o.receiveShadow = true;
  });
  await idle();

  const camera = new OrthographicCamera(-1, 1, 1, -1, 1, CAMERA_DISTANCE * 3);
  let q = quality;
  let size = { w: 1, h: 1 };
  /** 泛光的后期处理：完整档才有，降档时放掉。 */
  let bloom: Bloom | null = null;
  const applyQuality = () => {
    const dpr = dprOf(q);
    renderer.setPixelRatio(dpr);
    // 主光不投阴影时，用到阴影的着色器换成不带阴影的那一版（three.js 按灯光的状态自己重编）。
    renderer.shadowMap.enabled = sun.castShadow = q.shadowsAndBloom;
    if (q.shadowsAndBloom) bloom ??= createBloom(renderer, scene, camera);
    else {
      bloom?.dispose();
      bloom = null;
      // 阴影贴图也放掉：要用时 three.js 会重建。
      sun.shadow.map?.dispose();
      sun.shadow.map = null;
    }
    bloom?.resize(size.w, size.h, dpr);
    dressing.setParticles(q.particles);
  };
  applyQuality();

  // 先编一遍着色器，第一次显出来时不顿：支持 KHR_parallel_shader_compile 的浏览器异步编，不卡主线程。
  paintSky(1);
  if (renderer.extensions.has("KHR_parallel_shader_compile")) await renderer.compileAsync(scene, camera);
  else renderer.compile(scene, camera);
  await idle();

  return {
    standIns: Promise.all(standing).then((all) => all.filter((a) => a !== null)),
    resize(w, h) {
      size = { w, h };
      renderer.setSize(w, h, false);
      bloom?.resize(w, h, dprOf(q));
      // 宽高比变得多了才重画夜空：手机上地址栏收起放下只差一点，不重画。
      if (Math.abs(Math.log(w / h / skyAspect)) > 0.15) paintSky(w / h);
    },
    setQuality(next) {
      q = next;
      applyQuality();
    },
    render(memory, story, time) {
      const cam = memory.camera;
      const aspect = size.w / size.h;
      camera.left = -cam.half * aspect;
      camera.right = cam.half * aspect;
      camera.top = cam.half;
      camera.bottom = -cam.half;
      const [tx, ty, tz] = cam.target;
      const { back } = cameraBasis(cam);
      camera.position.set(tx + back[0] * CAMERA_DISTANCE, ty + back[1] * CAMERA_DISTANCE, tz + back[2] * CAMERA_DISTANCE);
      camera.lookAt(tx, ty, tz);
      camera.updateProjectionMatrix();
      // 小人：模型给的跳动、后仰、朝向，平时轻轻起伏（各人错开）。
      for (const pose of story.figures) {
        const body = bodies.get(pose.island);
        if (!body) continue;
        body.position.y = pose.hop * HOP_HEIGHT;
        body.rotation.set(-pose.reach * REACH_LEAN, pose.yaw, 0);
        const squash = 1 - pose.hop * HOP_SQUASH;
        body.scale.set(squash, 1 + pose.hop * HOP_STRETCH + Math.sin(time * 1.8 + pose.island * 1.3) * 0.006, squash);
      }

      // 手机亮起；消息从气泡变成方块（气泡总是正对镜头），方块慢慢转。
      (phoneGlow.material as SpriteMaterial).opacity = 0.25 + 0.75 * story.phone;
      message.visible = story.message !== null;
      if (story.message) {
        message.position.set(...story.message.position);
        bubble.scale.setScalar(Math.max(0.001, 1 - story.message.morph));
        bubble.rotation.y = cam.azimuth;
        core.g.scale.setScalar(Math.max(0.001, story.message.morph));
      }
      const spin = (cube: Mesh) => cube.rotation.set(time * 1.3, time * 0.9, 0);
      spin(core.cube);

      // 记忆柱：收进来的那块留在柱顶、轻轻浮着；小灯平时一明一暗，收进时闪成她的颜色，之后带着她的颜色。
      pillars.forEach((pillar, k) => {
        const stored = story.stored.find((s) => s.island === k);
        pillar.block.g.visible = !!stored;
        pillar.block.g.position.y = memoryTop(k)[1] + Math.sin(time * 1.6 + k) * 0.03;
        pillar.block.cube.rotation.y = time * 0.6;
        pillar.block.glow.scale.setScalar(1.1 + 0.9 * (stored?.flash ?? 0));
        pillar.leds.forEach((led, j) => {
          const blink = 0.5 + 0.5 * Math.sin(time * (3 + j) + k * 2);
          led.color.copy(ledIdle).multiplyScalar(0.4 + 0.6 * blink).lerp(memoryColor, stored ? Math.max(stored.flash, LED_STORED) : 0);
        });
      });
      copies.forEach((copy, to) => {
        const on = story.copies.find((c) => c.to === to);
        copy.g.visible = !!on;
        if (on) copy.g.position.set(...on.position);
        spin(copy.cube);
      });

      // 转台（把手跟着转三圈的四分之三）、桥面、台阶。
      turntable.rotation.y = story.turntable;
      knob.rotation.y = (Math.PI / 2 - story.turntable) * 3;
      bridge.forEach((m, k) => (m.emissiveIntensity = 0.55 * story.bridge[k]));
      steps.forEach((s, i) => {
        const { rise, lit } = story.steps[i];
        s.mesh.visible = rise > 0.001;
        s.mesh.position.y = STEPS[i].center[1] - STEP_DROP * (1 - rise);
        s.mat.emissiveIntensity = 0.4 * lit;
      });

      threads.forEach((m) => (m.visible = false));
      for (const t of story.threads) {
        const m = threads.get(`${t.from}-${t.to}`);
        if (!m) continue;
        m.visible = t.opacity > 0;
        m.material.opacity = t.opacity;
      }
      dressing.update(story, time);
      if (bloom) bloom.render();
      else renderer.render(scene, camera);
    },
    destroy() {
      destroyed = true;
      bloom?.dispose();
      owned.forEach((x) => x.dispose());
      sky?.dispose();
      renderer.dispose();
      // 上下文已经丢了的时候（收到 webglcontextlost 才来收起）不用、也放不了。
      if (!renderer.getContext().isContextLost()) renderer.forceContextLoss();
    },
  };
}

function figureGeometry(mesh: FigureMesh): BufferGeometry {
  const g = new BufferGeometry();
  g.setAttribute("position", new BufferAttribute(mesh.position, 3));
  g.setAttribute("normal", new BufferAttribute(mesh.normal, 3, true));
  g.setAttribute("color", new BufferAttribute(mesh.color, 3));
  g.setIndex(new BufferAttribute(mesh.index, 1));
  return g;
}

/** 在自发光里加上一份自己的底色。 */
function lift<M extends Material>(m: M): M {
  m.onBeforeCompile = (shader) => {
    shader.fragmentShader = shader.fragmentShader.replace(
      "#include <emissivemap_fragment>",
      `#include <emissivemap_fragment>
  totalEmissiveRadiance += diffuseColor.rgb * ${FIGURE_LIFT.toFixed(2)};`,
    );
  };
  return m;
}

/** 夜空：上方偏紫的径向渐变，撒一层星星（固定的种子，每次一样）。长边 1024 像素。 */
function skyTexture(aspect: number): CanvasTexture {
  const w = Math.round(aspect >= 1 ? 1024 : 1024 * aspect);
  const h = Math.round(aspect >= 1 ? 1024 / aspect : 1024);
  return canvasTexture(w, h, (g) => {
    const grad = g.createRadialGradient(w / 2, h * 0.3, 50, w / 2, h * 0.42, Math.max(w, h) * 0.9);
    grad.addColorStop(0, "#2d2152");
    grad.addColorStop(0.55, NIGHT);
    grad.addColorStop(1, "#090716");
    g.fillStyle = grad;
    g.fillRect(0, 0, w, h);
    const rnd = seeded(11);
    const count = Math.round((380 * w * h) / (1024 * 1024));
    for (let i = 0; i < count; i++) {
      g.fillStyle = `rgba(230,225,255,${0.12 + rnd() * 0.5})`;
      g.beginPath();
      g.arc(rnd() * w, rnd() * h, rnd() * 1.4, 0, Math.PI * 2);
      g.fill();
    }
  });
}

/** 脚下一团淡淡的影子。 */
function shadowTexture(): CanvasTexture {
  return canvasTexture(64, 64, (g) => {
    const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    grad.addColorStop(0, "rgba(10,6,24,0.55)");
    grad.addColorStop(1, "rgba(10,6,24,0)");
    g.fillStyle = grad;
    g.fillRect(0, 0, 64, 64);
  });
}

/** 手机屏幕：和她的一段对话，底色带一点她的颜色；只画气泡和一行行字的样子，不写字。 */
function phoneScreenTexture(her: Color): CanvasTexture {
  return canvasTexture(240, 480, (g) => {
    g.fillStyle = "#ffffff";
    g.fillRect(0, 0, 240, 480);
    g.globalAlpha = 0.22;
    g.fillStyle = `#${her.getHexString()}`;
    g.fillRect(0, 56, 240, 374);
    g.globalAlpha = 1;
    const bubble = (x: number, y: number, w: number, h: number, fill: string, line: string, lines: number[]) => {
      g.fillStyle = fill;
      g.beginPath();
      g.roundRect(x, y, w, h, 18);
      g.fill();
      g.fillStyle = line;
      lines.forEach((lw, i) => g.fillRect(x + 14, y + 14 + i * 14, lw, 6));
    };
    // 标题栏：她的头像和名字的位置。
    g.fillStyle = `#${her.getHexString()}`;
    g.beginPath();
    g.arc(40, 28, 14, 0, Math.PI * 2);
    g.fill();
    g.fillStyle = "#d8d3e2";
    g.fillRect(64, 24, 60, 8);
    bubble(14, 84, 150, 44, "#ffffff", "#d8d3e2", [110, 70]);
    bubble(70, 150, 156, 30, PRODUCER_INK, "#5d6c8f", [100]);
    bubble(14, 200, 130, 44, "#ffffff", "#d8d3e2", [96, 60]);
    // 刚发出去的那一句。
    bubble(60, 360, 166, 44, PRODUCER_INK, "#8b9bc0", [120, 80]);
    g.fillStyle = "#f1eff5";
    g.fillRect(0, 430, 240, 50);
  });
}

type Bloom = {
  render(): void;
  /** 画布的 CSS 尺寸和 DPR。 */
  resize(w: number, h: number, dpr: number): void;
  dispose(): void;
};

/** 泛光：先画到一张多重采样（抗锯齿）的半浮点贴图上，亮处泛光，再转成 sRGB 画到画布上。 */
function createBloom(renderer: WebGLRenderer, scene: Scene, camera: Camera): Bloom {
  const composer = new EffectComposer(renderer, new WebGLRenderTarget(1, 1, { type: HalfFloatType, samples: 4 }));
  const passes = [new RenderPass(scene, camera), new UnrealBloomPass(new Vector2(1, 1), BLOOM.strength, BLOOM.radius, BLOOM.threshold), new OutputPass()];
  passes.forEach((pass) => composer.addPass(pass));
  return {
    render: () => composer.render(),
    resize(w, h, dpr) {
      composer.setPixelRatio(dpr);
      composer.setSize(w, h);
    },
    dispose() {
      passes.forEach((pass) => pass.dispose());
      composer.dispose();
    },
  };
}
