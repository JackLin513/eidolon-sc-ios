/**
 * 第 4 幕的手机（.scratch/landing-call-phone 票 03）：一张单独的 three.js 画布（WebGL 渲染器，不用 WebGPU，见
 * ADR-0016 的修订），叠在光层上面，把落地页模型给的手机（model/phone.ts 的 PhoneState）画出来。three.js 和模型
 * 只在运动档、滚到第 3 幕附近时才由 phoneStage.ts 动态 import、下载，不进首屏的包。
 *
 * - 模型是 public/landing/phone/（scripts/landing-phone.mjs 压出来的 glTF：网格量化，贴图是 WebP；不用要 WebAssembly
 *   解码的压缩，CSP 不放行）。下载、解析一次，记在模块里：手机上离开这一段释放了上下文，回来时重建渲染器，不重新下载。
 * - 相机按落地页模型的屏幕矩形摆：一个世界单位就是一个 CSS 像素，手机停稳、正面朝着访客时，屏幕在画布上正好落在
 *   模型给的矩形里，DOM 上的来电界面也摆在那里。透视会让离相机近的屏幕平面显得大一点，这里把缩放和位置折算回去。
 * - 屏幕亮度：模型里叫「Screen」的材质发她的光，亮度跟着模型走。
 * - 只在画面有变化时画（位置、转角、缩放、亮度、尺寸）；振动由 DOM 容器的平移做，不用重画。
 * - 档位：DPR 按档位封顶；简化档和 basic 档藏起前玻璃和相机镜片上那几层半透明的反光。
 */

import {
  Box3,
  Color,
  DirectionalLight,
  Group,
  type Material,
  type Mesh,
  type MeshStandardMaterial,
  NeutralToneMapping,
  type Object3D,
  PerspectiveCamera,
  PMREMGenerator,
  Scene,
  Vector3,
  WebGLRenderer,
} from "three";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";

import type { CanvasLayer } from "./canvasStage";
import { idle } from "./idle";
import { PHONE_MM, type PhoneState } from "./model/phone";
import type { Quality } from "./model/tier";

/** 手机模型的地址（public/landing/phone/）。 */
export const PHONE_URL = "/landing/phone/phone.gltf";

/** 相机的竖直视角（度）：小一点，转身时透视不夸张。 */
const FOV = 24;
/** 简化档和 basic 档藏起来的反光层（模型里的材质名）。 */
const REFLECTIONS = ["Glass", "Camera_sapphire_miror"];
/** 屏幕亮起时发的光：她的颜色乘这么多。 */
const SCREEN_GLOW = 0.2;

let model: Promise<Object3D> | null = null;

/** 下载、解析手机模型；同一页里只做一次。 */
export function loadPhoneModel(): Promise<Object3D> {
  model ??= new GLTFLoader()
    .loadAsync(PHONE_URL)
    .then((gltf) => gltf.scene)
    .catch((e: unknown) => {
      model = null;
      throw e;
    });
  return model;
}

export type PhoneLayer = CanvasLayer & {
  /** 画这一刻的手机；和上一次画的一样时不画。`glow` 是屏幕亮起时的颜色（`#rrggbb`）。 */
  render(phone: PhoneState, glow: string): void;
};

/**
 * 在 `canvas` 上建手机这一层。分几批做，每批之间让出主线程：建上下文、准备环境光、编译着色器各占一批。
 * 建不起来时 reject，调用方换成事先渲染好的手机图。
 */
export async function createPhoneLayer(canvas: HTMLCanvasElement, quality: Quality): Promise<PhoneLayer> {
  const source = await loadPhoneModel();
  const dprOf = (q: Quality) => Math.min(window.devicePixelRatio || 1, q.dprCap);
  const renderer = new WebGLRenderer({ canvas, alpha: true, antialias: true, powerPreference: "low-power" });
  renderer.setClearColor(0x000000, 0);
  renderer.toneMapping = NeutralToneMapping;
  await idle();

  const scene = new Scene();
  const pmrem = new PMREMGenerator(renderer);
  const room = new RoomEnvironment();
  const env = pmrem.fromScene(room, 0.04).texture;
  room.dispose();
  pmrem.dispose();
  scene.environment = env;
  scene.environmentIntensity = 0.9;
  // 一盏从左上方打来的光，转身时在铝框上扫过一道高光。
  const key = new DirectionalLight(0xffffff, 1.6);
  key.position.set(-1, 1.4, 2);
  scene.add(key);
  await idle();

  // 模型绕机身中心转：包围盒的中心挪到原点（相机那一条凸出来，包围盒的中心比机身中心靠后一点，按机身算）。
  const phone = source.clone(true);
  const box = new Box3().setFromObject(phone);
  const center = box.getCenter(new Vector3());
  phone.position.set(-center.x, -center.y, 0);
  const pivot = new Group();
  pivot.add(phone);
  scene.add(pivot);

  let screen: MeshStandardMaterial | null = null;
  const reflections: Object3D[] = [];
  phone.traverse((o) => {
    const mesh = o as Mesh;
    if (!mesh.isMesh) return;
    const mat = mesh.material as Material;
    if (mat.name === "Screen") {
      // 每一层自己一份，亮度改的是这一份。
      screen = (mat as MeshStandardMaterial).clone();
      mesh.material = screen;
    }
    if (REFLECTIONS.includes(mat.name)) reflections.push(mesh);
  });

  const camera = new PerspectiveCamera(FOV, 1, 1, 100000);
  let q = quality;
  let size = { w: 1, h: 1 };
  let drawn = "";
  const glowColor = new Color();

  const applyQuality = () => {
    renderer.setPixelRatio(dprOf(q));
    for (const o of reflections) o.visible = q.reflections;
    drawn = "";
  };
  applyQuality();

  // 先编一遍着色器，第一次转身时不顿：支持 KHR_parallel_shader_compile 的浏览器异步编，不卡主线程。
  if (renderer.extensions.has("KHR_parallel_shader_compile")) await renderer.compileAsync(scene, camera);
  else renderer.compile(scene, camera);
  await idle();

  const layer: PhoneLayer = {
    resize(w, h) {
      size = { w, h };
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
      camera.position.set(0, 0, distance(h));
      camera.near = distance(h) * 0.2;
      camera.far = distance(h) * 5;
      camera.updateProjectionMatrix();
      drawn = "";
    },
    setQuality(next) {
      q = next;
      applyQuality();
    },
    render(state, glow) {
      if (state.opacity <= 0) return;
      const key = [state.x, state.y, state.height, state.yaw, state.screen, size.w, size.h, glow].join(" ");
      if (key === drawn) return;
      drawn = key;
      const D = distance(size.h);
      // 每米多少像素；屏幕平面在机身中心前面 z 米，透视下显得大一点：缩放和位置都折算回去，
      // 正面朝着访客时屏幕正好落在模型给的矩形里。
      const k = state.height / (PHONE_MM.h / 1000);
      const z = PHONE_MM.screen.z / 1000;
      const scale = (k * D) / (D + z * k);
      const shrink = (D - z * scale) / D;
      pivot.scale.setScalar(scale);
      pivot.rotation.y = state.yaw + Math.PI;
      pivot.position.set((state.x - size.w / 2) * shrink, (size.h / 2 - state.y) * shrink, 0);
      if (screen) {
        const s = screen as MeshStandardMaterial;
        s.emissive.copy(glowColor.set(glow)).multiplyScalar(SCREEN_GLOW * state.screen);
      }
      renderer.render(scene, camera);
    },
    destroy() {
      env.dispose();
      renderer.dispose();
      // 上下文已经丢了的时候（phoneStage 收到 webglcontextlost 才来收起）不用、也放不了。
      if (!renderer.getContext().isContextLost()) renderer.forceContextLoss();
    },
  };
  return layer;
}

/** 相机离 z = 0 平面多远时，这个平面上一个世界单位正好是一个 CSS 像素。 */
const distance = (h: number) => h / 2 / Math.tan(((FOV / 2) * Math.PI) / 180);
