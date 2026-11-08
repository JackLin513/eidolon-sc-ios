"use client";

import { useEffect, useRef, type CSSProperties, type ReactNode } from "react";

import { createCanvasStage, type CanvasStage } from "./canvasStage";
import type { MemoryLayer } from "./memoryLayer";
import { project, type Actor, type MemoryScene } from "./model/memory";
import type { MemoryStory } from "./model/memoryStory";
import { describeScene, slotX, standX, talkLineShown, unitCount, type BandLight, type Scene, type Viewport } from "./model/scene";
import { settleSpring, stepSpring } from "./model/spring";
import { qualityOf, tierReducer, TIERS, type Tier, type TierAction } from "./model/tier";
import { holdAt, restAt, spanOf, timelineOf, type Section } from "./model/timeline";
import { idle } from "./idle";
import { interactionStore } from "./interactionStore";
import type { Light } from "./light";
import { createPhoneStage, type PhoneStage } from "./phoneStage";
import { stageStore } from "./stageStore";

/** 按帧降档要攒够的样本：至少这么多帧、这么长时间才算一次平均（原型的做法）。 */
const MEASURE_FRAMES = 90;
const MEASURE_MS = 2500;
/** 不在光谱里时轨道停在哪儿（组合数）：第一个组合的右边一屏外。 */
const PARKED = -1;
/** 页面停下来这么久（毫秒）才算浏览器滚完了（页内查找把找到的字滚进画面）。 */
const SETTLE_MS = 120;
/** 聚焦淡入淡出的时间常数（秒）。 */
const FOCUS_EASE = 0.22;
/** 第 5 幕的气泡横向收进画面时离画面边（左边是幕名轨）至少这么远（像素）。 */
const LINE_INSET = 12;

/** 页面上的一段（Landing.tsx 里 `data-lp-section` 的元素），量好的位置。 */
type Measured = Section & { el: HTMLElement; top: number; height: number };

/**
 * 第 1、2 幕的舞台和整页的光层。一个 requestAnimationFrame 循环驱动一切：Lenis 推进滚动 → 落地页模型
 * 算出这一帧的画面 → 直接写 DOM 的样式变量（不走 React 状态）→ OGL 画光。档位由首屏前的内联脚本写在
 * <html> 上（tierScript.ts），这里读它：
 *
 * - 运动版式（完整、简化档）：页面分成几段（model/timeline.ts），钉住的一段是 `position: sticky` 的舞台，
 *   高度正好是它占的屏数。循环按每一段量好的位置把滚动位置换算成时间线上的屏数，交给落地页模型。
 *   原生滚动加 Lenis（lerp 0.1，触屏不做平滑）：Lenis 只把滚轮的位移平滑以后写回页面原生的滚动位置，
 *   不吸附、不分页、不改变滚动距离，键盘翻页、页内查找、浏览器后退都照常。Lenis 在首帧之后才加载，
 *   加载之前就是原生滚动。OGL 在浏览器空闲时才加载，画好第一帧才淡入，淡入时首屏 CSS 画的白光
 *   同时淡出；两束光的几何是同一套（model/scene.ts 的锚点就是 landing.css 里 .lp-beam 的尽头）。
 *   第 2 幕的名牌按模型的 slotX 摆到横滚轨道上，轨道的横移经弹簧平滑；名牌上名字的位置量好了传给模型，
 *   光芯在那里断开；立绘和招呼的字幕摆到她名牌外侧空间大的一边。第 3 幕的原文和字幕跟着模型一句句出来，
 *   第 4 幕她的光收成一台手机的侧边，three.js 画的手机（phoneStage.ts，滚到第 3 幕附近才加载）照模型转身、亮屏，
 *   屏幕矩形和振动写进样式，来电界面摆在屏幕上、和手机一起抖，光脉冲照样发光（Voice、Call）。第 5 幕是 three.js 画的
 *   夜空和浮岛（memoryLayer.ts，滚到第 5 幕前约一屏才加载，canvasStage.ts 管起落），镜头照模型推拉转，一件事从真乃传开
 *   （model/memoryStory.ts，和场景代码一起晚加载，每帧算一次：3D 层照它画，几个人说的话按它的锚点投影摆成 DOM 上的
 *   气泡，横向收进画面），画布、标题正文、几句话和最后一句跟着模型淡入淡出（画布出了问题时换成事先渲染好的全景图）；
 *   第 7 幕的文字和行动按钮跟着模型淡入。
 *   当前在哪一幕写进 stageStore，幕名轨、光谱和来电据此更新。
 *   页内查找：画面外的名牌由浏览器去滚光谱的舞台（它是个访客滚不动的滚动容器），这里接住、滚回去，再把
 *   页面滚到那个组合；跟着滚动淡入淡出的文字（`data-lp-find`）在访客查找时、看不见的那些是 `hidden="until-found"`，
 *   查找找到它时浏览器发 beforematch，这里把页面滚到它显示出来的地方。平时不藏：藏起来的字读屏器读不到。
 * - 定格档（减少动态效果）：不钉住、不加载 Lenis；OGL 只渲染一帧第 1 幕的完成态就停下，
 *   窗口尺寸变了才重画那一帧。画好之前，静态档的 SVG 先顶着。
 * - 静态档（省流量、不支持 WebGL）：什么都不加载，光由服务端渲染的 SVG（StaticLight）和 CSS 画。
 *
 * 光层建不起来或 WebGL 上下文丢了，就地退到静态档：收起画布，版式不变，各幕的 CSS 光重新露出来。
 */
export function LightStage({
  lights,
  section,
  speaker,
  actors,
  children,
}: {
  lights: BandLight[];
  section: Section;
  /** 第 3、4 幕说话、打来电话的那一位。 */
  speaker: string | null;
  /** 第 5 幕的演员。 */
  actors: Actor[];
  children: ReactNode;
}) {
  const wrap = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const html = document.documentElement;
    const stage = wrap.current!;
    const root = stage.closest<HTMLElement>(".lp-root")!;
    const target = canvas.current!;
    let tier = readTier(html);
    const touch = matchMedia("(hover: none)").matches;
    if (!qualityOf(tier, touch).canvas) return;

    let light: Light | null = null;
    /** 第 4 幕的手机、第 5 幕的场景（运动版式才有）。 */
    let phone: PhoneStage | null = null;
    let memory: CanvasStage<MemoryLayer> | null = null;
    /** 画布收起了：卸载，或者退到了静态档。之后不再建光层。 */
    let dropped = false;
    /** 画布淡入了：之前白光不随指针转，和首屏 CSS 画的那束对得上。 */
    let shown = false;
    const cleanups: (() => void)[] = [];
    const dispatch = (action: TierAction) => {
      const next = tierReducer(tier, action);
      if (next === tier) return;
      tier = next;
      // 版式（data-lp-layout）是首屏前定的，运行中不改：从运动版式退到静态档时舞台照样钉住、
      // 照样那么长，正在第 1 幕中间的人不会被一下甩到光谱。
      html.dataset.lpTier = tier;
      if (qualityOf(tier, touch).canvas) {
        light?.setQuality(qualityOf(tier, touch));
        phone?.setQuality(qualityOf(tier, touch));
        memory?.setQuality(qualityOf(tier, touch));
      } else drop();
    };
    // 收起画布：SVG 和 CSS 画的光重新露出来。运动版式的主循环不停，各幕的文字照样由它推进。
    const drop = () => {
      if (dropped) return;
      dropped = true;
      light?.destroy();
      light = null;
      root.classList.remove("lp-gl-on");
      phone?.drop();
      memory?.drop();
    };
    let unmounted = false;
    const unmount = () => {
      unmounted = true;
      cleanups.forEach((f) => f());
      drop();
    };
    const lost = (e: Event) => {
      e.preventDefault();
      dispatch({ type: "lost" });
    };
    target.addEventListener("webglcontextlost", lost);
    cleanups.push(() => target.removeEventListener("webglcontextlost", lost));

    // 光层的包也等到空闲才下载：不和首屏的字体、样式抢带宽。
    const loadLight = (onReady: (l: Light) => void) =>
      idle()
        .then(() => (dropped ? null : import("./light")))
        .then(async (mod) => {
          if (!mod) return;
          const l = await mod.createLight(target, qualityOf(tier, touch));
          if (dropped) return l.destroy();
          light = l;
          onReady(l);
          // 第一帧画好以后再淡入。
          requestAnimationFrame(() => {
            if (dropped) return;
            shown = true;
            root.classList.add("lp-gl-on");
          });
        })
        .catch(() => dispatch({ type: "lost" }));

    // —— 定格档：画一帧就停。
    if (!qualityOf(tier, touch).animate) {
      const draw = () => {
        if (!light) return;
        // 量第 1 幕那一屏（画布盖着它）：OGL 会把画布的宽高写成内联样式，不能量画布本身。
        const box = (stage.querySelector(".lp-act1") ?? target).getBoundingClientRect();
        light.resize(box.width, box.height);
        light.render(describeScene({ lights, scroll: 1, viewport: { w: box.width, h: box.height }, tier }), 0);
      };
      void loadLight(draw);
      window.addEventListener("resize", draw);
      cleanups.push(() => window.removeEventListener("resize", draw));
      return unmount;
    }

    // —— 运动版式。
    const timeline = timelineOf(unitCount(lights));
    const sections: Measured[] = [...root.querySelectorAll<HTMLElement>("[data-lp-section]")].map((el) => ({
      ...timeline.sections[Number(el.dataset.lpSection)],
      el,
      top: 0,
      height: 1,
    }));
    const plates = [...stage.querySelectorAll<HTMLElement>("[data-lp-id]")];
    const lightOf = new Map(lights.map((l) => [l.id, l]));
    // 立绘的框由 Spectrum 在知道版式以后才渲染，比这里晚一步，用到时再找。
    let standBoxEl: HTMLElement | null = null;
    const findStandBox = () => (standBoxEl ??= stage.querySelector<HTMLElement>(".lp-track > .lp-stand"));
    const greetingEl = stage.querySelector<HTMLElement>(".lp-greeting");
    const railEl = root.querySelector<HTMLElement>(".lp-rail");
    const track = stage.querySelector<HTMLElement>(".lp-track");
    const voiceEl = root.querySelector<HTMLElement>(".lp-voice");
    const stageBox = stage.querySelector<HTMLElement>(".lp-stage")!;
    /**
     * 跟着滚动淡入淡出的文字，和它们现在藏没藏起来。不支持 until-found 的浏览器里 hidden 就是不显示，不用它。
     * 每次开始查找时重新找一遍：第 4 幕的名字在手机画出来以后挪进了屏幕，是另一个元素。
     */
    const canFind = "onbeforematch" in document.body;
    const collectFindables = () => (canFind ? [...root.querySelectorAll<HTMLElement>("[data-lp-find]")] : []);
    let findables = collectFindables();
    const hidden = new Map<HTMLElement, boolean>();
    /**
     * 访客在查找：按了 Ctrl/⌘+F 或 F3，还没再碰页面（查找栏开着时按键都落在查找栏上，碰到页面多半是查完了）。
     * 只在这时把看不见的文字藏成 until-found：藏起来的字不在无障碍树上，平时藏着读屏器就读不到了。
     */
    let finding = false;
    const onKey = (e: KeyboardEvent) => {
      if (((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f") || e.key === "F3") {
        if (!finding) findables = collectFindables();
        finding = true;
      }
      else if (!["Control", "Meta", "Shift", "Alt"].includes(e.key)) finding = false;
    };
    const stopFinding = () => (finding = false);
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("pointerdown", stopFinding, true);
    window.addEventListener("wheel", stopFinding, { passive: true });
    window.addEventListener("touchstart", stopFinding, { passive: true });
    cleanups.push(() => {
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("pointerdown", stopFinding, true);
      window.removeEventListener("wheel", stopFinding);
      window.removeEventListener("touchstart", stopFinding);
    });
    // 第 4 幕的手机：画布放进来电的 .lp-phone，屏幕亮起时发打来电话的她的光。
    const phoneHost = root.querySelector<HTMLElement>(".lp-phone");
    const caller = lights.find((l) => l.id === speaker) ?? lights[0];
    if (phoneHost && caller) {
      phone = createPhoneStage({ root, host: phoneHost, timeline, touch, quality: qualityOf(tier, touch), glow: caller.color });
    }
    // 第 5 幕随进度讲的那件事：滚到这一幕附近（模型给出这一幕的场景状态）才下载，3D 层和 DOM 上的几句话共用。
    type StoryModule = typeof import("./model/memoryStory");
    let storyModule: StoryModule | null = null;
    let storyLoad: Promise<StoryModule> | null = null;
    const loadStory = () => (storyLoad ??= import("./model/memoryStory").then((m) => (storyModule = m)));
    const cast = actors.map((a) => a.island);
    // 第 5 幕的场景：画布放进这一幕的最前面。three.js 和第 4 幕的手机共用一个包，场景代码另一个包。画布丢了上下文、
    // 建不起来（或者落地页退到了静态档）时收起，换成事先渲染好的全景图，几句话收起来（Memory.tsx、landing.css）。
    const memoryEl = root.querySelector<HTMLElement>(".lp-memory");
    const memoryHost = memoryEl?.querySelector<HTMLElement>(".lp-act5");
    const act5 = spanOf(timeline, 5);
    if (memoryHost && act5) {
      const font = getComputedStyle(root).fontFamily;
      memory = createCanvasStage({
        host: memoryHost,
        className: "lp-memory-canvas",
        span: [act5.from, act5.to],
        touch,
        quality: qualityOf(tier, touch),
        load: async (c, q) => {
          const [mod] = await Promise.all([import("./memoryLayer"), loadStory()]);
          return mod.createMemoryLayer(c, q, actors, font);
        },
        onDrop: () => root.classList.add("lp-memory-lost"),
      });
    }
    // 第 5 幕的几句话（Memory.tsx 的 data-lp-line）和最后一句。
    const lineEls = [...(memoryEl?.querySelectorAll<HTMLElement>("[data-lp-line]") ?? [])];
    const closingEl = memoryEl?.querySelector<HTMLElement>(".lp-closing") ?? null;
    /** 每句话上一次写进样式的位置和不透明度，没变就不重写；气泡的宽度（横向收进画面要用），量过的记着。 */
    const lineKeys = new Map<HTMLElement, string>();
    const lineWidths = new Map<HTMLElement, number>();
    /** 这一刻每句话（Line 的 key）和最后一句（closing）显示了多少，页内查找按它藏起看不见的。 */
    let linesShown: Record<string, number> = {};
    let railWidth = 0;
    /** 上一次写进样式的屏幕矩形，没变就不重写。 */
    let rectKey = "";
    const startEl = root.querySelector<HTMLElement>(".lp-start");

    let vp: Viewport = { w: 1, h: 1 };
    let nameGaps: Record<string, readonly [number, number]> = {};
    /** 名牌上文字（编号、名字、色值）的竖直区间，从钉住的舞台（stageBox）顶算起：舞台钉住时它就是视口顶。不能从外层
     * 量：在光谱里刷新、改窗口大小时外层的顶在视口上方几屏，断口就跑到画面外了。字体晚到会改变名字的高度，到了要重新量。 */
    const measureGaps = () => {
      const top = stageBox.getBoundingClientRect().top;
      nameGaps = Object.fromEntries(
        plates.map((el) => {
          const r = el.querySelector(".lp-plate-body")!.getBoundingClientRect();
          return [el.dataset.lpId!, [r.top - top - 6, r.bottom - top + 6] as const];
        }),
      );
    };
    /** 光谱的舞台平时停在这么远的地方（像素），第 1、2 幕的内容往右挪同样远：浏览器往左、往右都滚得动它。 */
    let base = 0;
    /** 轨道现在的横移（组合数）：光谱里是模型给的，不在光谱里时停在 PARKED。 */
    let trackNow = 0;
    const measure = () => {
      vp = { w: html.clientWidth, h: window.innerHeight };
      root.style.setProperty("--lp-vh", `${vp.h}px`);
      base = unitCount(lights) * vp.w;
      stage.style.setProperty("--lp-base", `${base}px`);
      stageBox.scrollLeft = base;
      // 轨道停在画面外的距离按新的视口宽度重算（下一帧）。
      if (trackNow === PARKED) trackNow = Number.NaN;
      for (const s of sections) {
        s.top = s.el.getBoundingClientRect().top + window.scrollY;
        s.height = Math.max(1, s.el.offsetHeight);
      }
      for (const el of plates) {
        const l = lightOf.get(el.dataset.lpId!);
        if (l) el.style.left = `${slotX(vp, l.unit, l.slot, l.unitSize)}px`;
      }
      measureGaps();
      railWidth = railEl?.offsetWidth ?? 0;
      lineWidths.clear();
      placeStand();
      placeGreeting();
      light?.resize(vp.w, vp.h);
      phone?.resize(vp.w, vp.h);
      memory?.resize(vp.w, vp.h);
    };
    let standFor: string | undefined;
    const placeStand = () => {
      const standBox = findStandBox();
      const l = standBox && lightOf.get(standBox.dataset.lpStand ?? "");
      if (!standBox || !l) return;
      standBox.style.left = `${standX(vp, l, standBox.offsetWidth) - standBox.offsetWidth * 0.5}px`;
    };
    // 招呼的字幕跟着立绘居中（她没有立绘时，在立绘本来站的地方），但不出她那个组合的一屏，也不压着幕名轨。
    let greetingFor: string | undefined;
    const placeGreeting = () => {
      const l = greetingEl && lightOf.get(greetingEl.dataset.lpGreeting ?? "");
      if (!greetingEl || !l) return;
      const half = greetingEl.offsetWidth / 2 + 16;
      const page = l.unit * vp.w;
      const cx = Math.min(Math.max(standX(vp, l, findStandBox()?.offsetWidth ?? 0), page + (railEl?.offsetWidth ?? 0) + half), page + vp.w - half);
      greetingEl.style.left = `${cx - greetingEl.offsetWidth / 2}px`;
    };
    /** 把第 5 幕的几句话摆到模型给的锚点上：气泡的底边中点在锚点投影到画面上的地方，横向收进画面、不压着幕名轨。 */
    const placeLines = (scene: MemoryScene | null, story: MemoryStory | null) => {
      const shown: Record<string, number> = { closing: story?.closing ?? 0 };
      const at = new Map(story?.lines.map((l) => [l.key, l]));
      for (const el of lineEls) {
        const line = at.get(el.dataset.lpLine!);
        const opacity = line?.opacity ?? 0;
        shown[el.dataset.lpLine!] = opacity;
        let key = "0";
        let x = 0;
        let y = 0;
        if (scene && line && opacity > 0) {
          [x, y] = project(scene.camera, vp, line.anchor);
          // 量宽度要等它显出来：藏成 until-found 时量不到。
          let w = lineWidths.get(el);
          if (!w) {
            w = el.offsetWidth;
            if (w) lineWidths.set(el, w);
          }
          x = Math.min(Math.max(x, railWidth + LINE_INSET + w / 2), vp.w - LINE_INSET - w / 2);
          key = `${opacity} ${x.toFixed(1)} ${y.toFixed(1)}`;
        }
        if (lineKeys.get(el) === key) continue;
        lineKeys.set(el, key);
        el.style.setProperty("--lp-o", String(opacity));
        if (opacity > 0) {
          el.style.setProperty("--lp-x", `${x}px`);
          el.style.setProperty("--lp-y", `${y}px`);
        }
      }
      closingEl?.style.setProperty("--lp-o", String(shown.closing));
      linesShown = shown;
    };
    measure();
    window.addEventListener("resize", measure);
    document.fonts.addEventListener("loadingdone", measure);
    cleanups.push(() => {
      window.removeEventListener("resize", measure);
      document.fonts.removeEventListener("loadingdone", measure);
    });

    /**
     * 滚过的屏数（时间线的单位）。钉住的一段高度正好是它的屏数，一一对应；照常往上走的一段按比例换算，
     * 但最后一屏一一对应：那是下一段从下面进来的时候，和下一段的画面要对得上。
     */
    const scrollOf = (y: number) => {
      const s = sections.find((s) => y < s.top + s.height) ?? sections.at(-1)!;
      const into = Math.max(0, y - s.top);
      if (s.pinned || s.height <= vp.h) return s.from + Math.min(s.screens, (into / s.height) * s.screens);
      const body = s.height - vp.h;
      return into < body ? s.from + (into / body) * (s.screens - 1) : s.from + s.screens - 1 + Math.min(1, (into - body) / vp.h);
    };
    /** 时间线上第 `screens` 屏在页面上的位置（scrollOf 反过来，只用于钉住的段）。 */
    const yOf = (screens: number) => {
      const s = sections.find((s) => screens < s.from + s.screens) ?? sections.at(-1)!;
      return s.top + ((screens - s.from) / s.screens) * s.height;
    };

    // 指针（鼠标、笔）和手指：只影响第 0 幕白光的角度，经弹簧平滑。手指用 touch 事件：
    // 滑动时浏览器会接管 pointer 事件去滚动页面，touchmove 照样会来。
    const aim = { x: 0, y: 0 };
    const toward = (x: number, y: number) => {
      aim.x = (x / vp.w) * 2 - 1;
      aim.y = (y / vp.h) * 2 - 1;
    };
    const onPointer = (e: PointerEvent) => e.pointerType !== "touch" && toward(e.clientX, e.clientY);
    const onTouch = (e: TouchEvent) => e.touches[0] && toward(e.touches[0].clientX, e.touches[0].clientY);
    window.addEventListener("pointermove", onPointer, { passive: true });
    window.addEventListener("touchstart", onTouch, { passive: true });
    window.addEventListener("touchmove", onTouch, { passive: true });
    cleanups.push(() => {
      window.removeEventListener("pointermove", onPointer);
      window.removeEventListener("touchstart", onTouch);
      window.removeEventListener("touchmove", onTouch);
    });

    let lenis: { raf(time: number): void; scrollTo(y: number, o?: { duration?: number; immediate?: boolean }): void; destroy(): void } | null = null;
    requestAnimationFrame(() =>
      import("lenis").then(({ default: Lenis }) => {
        if (unmounted) return;
        lenis = new Lenis({ lerp: 0.1, syncTouch: false, autoRaf: false });
      }),
    );
    cleanups.push(() => lenis?.destroy());

    /** 滚到时间线上第 `screens` 屏：Lenis 加载了就交给它（它的平滑状态才对得上），不然用原生滚动。 */
    const scrollToScreens = (screens: number, instant: boolean) => {
      const y = yOf(screens);
      if (lenis) lenis.scrollTo(y, instant ? { immediate: true } : { duration: 1.2 });
      else window.scrollTo({ top: y, behavior: instant ? "instant" : "smooth" });
    };
    // 按组合跳转：滚到那个组合停稳的地方。
    stageStore.jump = (u, instant) => scrollToScreens(holdAt(timeline, u), !!instant);
    // 键盘聚焦到别的幕里的按钮、页内查找找到一段文字：立即滚到那一幕停稳的地方，或者幕内的某一处。
    stageStore.goto = (act, progress) => {
      const span = spanOf(timeline, act);
      const at = progress === undefined || !span ? restAt(timeline, act) : span.from + span.length * progress;
      if (at !== undefined) scrollToScreens(at, true);
    };
    cleanups.push(() => {
      stageStore.jump = null;
      stageStore.goto = null;
    });

    // 页内查找找到一段文字时，浏览器要把它滚进画面：它按文字在钉住的舞台里的位置滚，不一定是文字显示出来的
    // 地方。等浏览器滚完（页面停下来一会儿）再滚到该去的地方，不然又被它盖掉。
    let settling: { run: () => void; timer: number } | null = null;
    const afterScrollSettles = (run: () => void) => {
      if (settling) window.clearTimeout(settling.timer);
      settling = { run, timer: window.setTimeout(settled, SETTLE_MS) };
    };
    const settled = () => {
      const run = settling?.run;
      settling = null;
      run?.();
    };
    const onScroll = () => {
      if (!settling) return;
      window.clearTimeout(settling.timer);
      settling.timer = window.setTimeout(settled, SETTLE_MS);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    cleanups.push(() => {
      window.removeEventListener("scroll", onScroll);
      if (settling) window.clearTimeout(settling.timer);
    });

    // 页内查找找到画面外的名牌（键盘聚焦到它也一样）：浏览器为了让它露出来去滚光谱的舞台。滚回原处，把页面
    // 滚到那个组合：先看是哪块名牌（聚焦的、或者查找选中的），认不出来就按浏览器滚了多远估一个组合。
    // 舞台平时停在 base 处（见 measure），名牌在画面左边、右边都滚得到。
    const onStageScroll = () => {
      const dx = stageBox.scrollLeft - base;
      if (Math.abs(dx) < 1 && stageBox.scrollTop === 0) return;
      stageBox.scrollLeft = base;
      stageBox.scrollTop = 0;
      const plate = [document.activeElement, getSelection()?.anchorNode?.parentElement]
        .map((n) => n?.closest<HTMLElement>("[data-lp-id]"))
        .find((n) => n && stage.contains(n));
      const guess = Math.min(unitCount(lights) - 1, Math.max(0, Math.floor(trackNow + (dx + vp.w / 2) / vp.w)));
      const unit = lightOf.get(plate?.dataset.lpId ?? "")?.unit ?? guess;
      afterScrollSettles(() => stageStore.jump?.(unit, true));
    };
    stageBox.addEventListener("scroll", onStageScroll);
    // 查找找到藏起来的文字：滚到它显示出来的地方。
    const onMatch = (e: Event) => {
      const key = (e.target as HTMLElement).closest<HTMLElement>("[data-lp-find]")?.dataset.lpFind;
      if (!key) return;
      const found = findKeyOf(key);
      afterScrollSettles(() => {
        // 第 5 幕的一句话：它显出来的时刻在晚加载的那件事里。
        if (found.kind === "memory") void loadStory().then((m) => stageStore.goto?.(found.act, m.lineShownAt(found.line)));
        else stageStore.goto?.(found.act, found.kind === "sub" ? talkLineShown(found.line) : undefined);
      });
    };
    document.addEventListener("beforematch", onMatch);
    cleanups.push(() => {
      stageBox.removeEventListener("scroll", onStageScroll);
      document.removeEventListener("beforematch", onMatch);
    });

    void loadLight((l) => l.resize(vp.w, vp.h));

    let px = settleSpring(0);
    let py = settleSpring(0);
    let trackSpring: ReturnType<typeof settleSpring> | null = null;
    let trackTarget = 0;
    const focus: Record<string, number> = {};
    let speed = 0;
    let last = performance.now();
    let lastScroll = scrollOf(window.scrollY);
    let frames = { n: 0, ms: 0, since: last };
    let act = -1;
    let parked = false;
    let raf = 0;
    const loop = (now: number) => {
      raf = requestAnimationFrame(loop);
      lenis?.raf(now);
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      if (dt <= 0) return;

      const scroll = scrollOf(window.scrollY);
      // 滚动速度（屏/秒）：低通一下，色散不跟着每一帧的抖动闪。
      speed += ((scroll - lastScroll) / dt - speed) * (1 - Math.exp(-dt / 0.12));
      lastScroll = scroll;
      px = stepSpring(px, shown ? aim.x : 0, dt);
      py = stepSpring(py, shown ? aim.y : 0, dt);
      // 横移：弹簧追上一帧模型给的目标。不在第 2 幕时没有弹簧，进第 2 幕的那一帧直接落在目标上
      // （刷新后停在某个组合、从后面的幕滚回来，轨道都不会从头扫过几屏）。
      if (trackSpring) trackSpring = stepSpring(trackSpring, trackTarget, dt);
      // 聚焦：被聚焦的那位淡入，其余的淡出，淡完的拿掉。
      const ease = 1 - Math.exp(-dt / FOCUS_EASE);
      for (const id of new Set([...Object.keys(focus), ...(stageStore.focus ? [stageStore.focus] : [])])) {
        const w = (focus[id] ?? 0) + ((id === stageStore.focus ? 1 : 0) - (focus[id] ?? 0)) * ease;
        if (w < 0.002 && id !== stageStore.focus) delete focus[id];
        else focus[id] = w;
      }

      const scene: Scene = describeScene({
        lights,
        scroll,
        viewport: vp,
        tier,
        speed,
        pointer: { x: px.x, y: py.x },
        time: now / 1000,
        track: trackSpring?.x,
        focus,
        nameGaps,
        speaker: speaker ?? undefined,
        call: interactionStore.get().call,
      });
      stage.style.setProperty("--lp-act1-text", String(scene.text.act1));
      stage.style.setProperty("--lp-plates", String(scene.text.plates));
      // 名牌显出来以后才接指针：之前它们透明地盖在第 1 幕上面。
      stage.toggleAttribute("data-lp-plates", scene.text.plates > 0.5);
      if (!scene.spectrum) {
        trackSpring = null;
        // 不在光谱里时把轨道停到画面右边一屏外：名牌都在画面外，页内查找找到哪一块，浏览器都得去滚舞台，
        // 上面的 onStageScroll 才接得到。
        if (trackNow !== PARKED) {
          trackNow = PARKED;
          if (track) track.style.transform = `translate3d(${-PARKED * vp.w}px,0,0)`;
        }
      } else {
        trackTarget = scene.spectrum.trackTarget;
        trackNow = scene.spectrum.track;
        trackSpring ??= settleSpring(trackTarget);
        if (track) track.style.transform = `translate3d(${-scene.spectrum.track * vp.w}px,0,0)`;
        stageStore.set({ unit: scene.spectrum.unit, stand: scene.spectrum.stand });
        const standBox = findStandBox();
        if (standBox && standBox.dataset.lpStand !== standFor) {
          standFor = standBox.dataset.lpStand;
          placeStand();
        }
        if (greetingEl && greetingEl.dataset.lpGreeting !== greetingFor) {
          greetingFor = greetingEl.dataset.lpGreeting;
          placeGreeting();
        }
      }
      if (voiceEl) {
        voiceEl.style.setProperty("--lp-act3", String(scene.text.act3));
        voiceEl.style.setProperty("--lp-act4", String(scene.text.act4));
        voiceEl.toggleAttribute("data-lp-call", scene.text.act4 > 0.5);
        scene.talk?.lines.forEach((l, k) => {
          voiceEl.style.setProperty(`--lp-ja-${k}`, String(l.ja));
          voiceEl.style.setProperty(`--lp-sweep-${k}`, String(l.sweep));
          voiceEl.style.setProperty(`--lp-sub-${k}`, String(l.subtitle));
        });
        if (scene.call) voiceEl.style.setProperty("--lp-pulse", String(scene.call.pulse));
        if (scene.phone) {
          const { shake, rect, bounds } = scene.phone;
          voiceEl.style.setProperty("--lp-phone", String(scene.phone.opacity));
          voiceEl.style.setProperty("--lp-shake-x", `${shake.x}px`);
          voiceEl.style.setProperty("--lp-shake-y", `${shake.y}px`);
          const key = [rect.x, rect.y, rect.w, rect.h, rect.r, bounds.top, bounds.bottom].join(" ");
          if (key !== rectKey) {
            rectKey = key;
            for (const [name, v] of Object.entries({ x: rect.x, y: rect.y, w: rect.w, h: rect.h, r: rect.r }))
              voiceEl.style.setProperty(`--lp-screen-${name}`, `${v}px`);
            voiceEl.style.setProperty("--lp-phone-top", `${bounds.top}px`);
            voiceEl.style.setProperty("--lp-phone-bottom", `${bounds.bottom}px`);
          }
        } else voiceEl.style.setProperty("--lp-phone", "0");
      }
      // 第 5 幕：这一刻那件事传到了哪一步（模型给出这一幕的场景状态时才下载、才算）。
      if (scene.memory) void loadStory();
      const story = scene.memory && storyModule ? storyModule.storyAt(scene.memory.progress, scene.memory.camera, cast) : null;
      if (memoryEl) {
        memoryEl.style.setProperty("--lp-act5", String(scene.text.act5));
        memoryEl.style.setProperty("--lp-memory", String(scene.memory?.opacity ?? 0));
        placeLines(scene.memory, story);
      }
      for (const el of findables) {
        const hide = finding && shownOf(scene, findKeyOf(el.dataset.lpFind!), linesShown) < 0.02;
        if (hidden.get(el) === hide) continue;
        hidden.set(el, hide);
        if (hide) el.setAttribute("hidden", "until-found");
        else el.removeAttribute("hidden");
      }
      if (startEl) {
        startEl.style.setProperty("--lp-act7", String(scene.text.act7));
        startEl.toggleAttribute("data-lp-cta", scene.text.act7 > 0.5);
      }
      if (scene.act !== act) {
        act = scene.act;
        stageStore.set({ act });
      }

      phone?.frame(scroll, scene.phone);
      // 第 5 幕的场景：画布显出来的时候才画。
      let drewMemory = false;
      const layer = memory?.frame(scroll);
      if (layer && scene.memory && story && scene.memory.opacity > 0) {
        layer.render(scene.memory, story, now / 1000);
        drewMemory = true;
      }

      // 光层：画面里什么都没亮时（第 5 幕和第 6 幕最暗的那一段）画一帧就歇着。
      let drewLight = false;
      if (light) {
        const dark = isDark(scene);
        if (!dark || !parked) {
          light.render(scene, now / 1000);
          drewLight = true;
        }
        parked = dark;
      }

      // 按帧降档：只在画着的时候量（光层、第 5 幕的场景都算），攒够一段算一次平均。
      if (!drewLight && !drewMemory) return;
      frames.n += 1;
      frames.ms += dt * 1000;
      if (frames.n >= MEASURE_FRAMES && now - frames.since >= MEASURE_MS) {
        dispatch({ type: "frames", averageMs: frames.ms / frames.n });
        frames = { n: 0, ms: 0, since: now };
      }
    };
    raf = requestAnimationFrame(loop);
    // 标签页切到后台时 requestAnimationFrame 停了，回来的第一帧不算进帧耗时。
    const onVisible = () => {
      last = performance.now();
      frames = { n: 0, ms: 0, since: last };
    };
    document.addEventListener("visibilitychange", onVisible);
    cleanups.push(() => {
      cancelAnimationFrame(raf);
      document.removeEventListener("visibilitychange", onVisible);
    });
    return unmount;
  }, [lights, speaker, actors]);

  return (
    <div
      ref={wrap}
      className="lp-stage-wrap"
      data-lp-section={section.index}
      style={{ "--lp-screens": section.screens } as CSSProperties}
    >
      <div className="lp-stage lp-spectrum-stage">
        <canvas ref={canvas} className="lp-canvas" aria-hidden />
        {children}
      </div>
    </div>
  );
}

/** 一段跟着时间线淡入淡出的文字（`data-lp-find`）：第几幕的说明，第 3 幕第几句的原文、字幕，或者第 5 幕的一句话。 */
type FindKey =
  | { kind: "text"; act: 1 | 3 | 4 | 5 | 7 }
  | { kind: "ja" | "sub"; act: 3; line: number }
  | { kind: "memory"; act: 5; line: string };

/** `data-lp-find` 的写法：`act1`、`act3`、`act4`、`act5`、`act7` 是这几幕的说明，`ja-k`、`sub-k` 是第 3 幕第 k 句，
 * `memory-<key>` 是第 5 幕的一句话（model/memoryStory.ts 的 Line 的 key，最后一句是 `closing`）。 */
function findKeyOf(key: string): FindKey {
  if (key.startsWith("memory-")) return { kind: "memory", act: 5, line: key.slice("memory-".length) };
  const [kind, k] = key.split("-");
  if (kind === "ja" || kind === "sub") return { kind, act: 3, line: Number(k) };
  return { kind: "text", act: Number(kind.slice(3)) as 1 | 3 | 4 | 5 | 7 };
}

/** 这段文字这一刻显示了多少；`lines` 是第 5 幕每句话显示了多少。 */
function shownOf(scene: Scene, key: FindKey, lines: Record<string, number>): number {
  if (key.kind === "text") return scene.text[`act${key.act}`];
  if (key.kind === "memory") return (lines[key.line] ?? 0) * (scene.memory?.opacity ?? 0);
  const line = scene.talk?.lines[key.line];
  if (!line) return 0;
  return scene.text.act3 * (key.kind === "ja" ? line.ja : line.subtitle * line.sweep);
}

/** 画面里没有一处是亮的。 */
const isDark = (s: Scene) =>
  s.beam.intensity < 0.003 &&
  s.prism.intensity < 0.003 &&
  s.fan.intensity < 0.003 &&
  s.screen.intensity < 0.003 &&
  s.bands.every((b) => b.intensity < 0.004);

function readTier(html: HTMLElement): Tier {
  const t = html.dataset.lpTier as Tier | undefined;
  return t && TIERS.includes(t) ? t : "static";
}
