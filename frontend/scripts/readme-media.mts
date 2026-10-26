/**
 * README 里的截图和动图：在 Chromium 里打开本地跑着的网站，拍下各页，压成 WebP 写到仓库的 `docs/images/`。
 * 界面改了以后重跑一遍，README 的图就跟上了。
 *
 *   npm run readme-media -- [--origin <网址>] [--user <名字>] [--only <名字,…>] [--reseed all|<角色,…>] [--database <路径>]
 *
 * 连的是本地真实的后端和开发库：先起后端（.env 里 EIDOLON_DEV_LOGIN=1，配好对话模型、语音合成、语音识别、
 * 向量化和判断模型），再 `npm run build` 后带上和 .env 一样的 EIDOLON_STAND_ASSETS_URL `npm run start`
 * （没有它就拍不到立绘）。默认网址 http://localhost:3000。
 *
 * 用开发登录按 `--user`（默认 readme-demo）登录。这位用户还没有对话时，先照 SEED 和几位角色真的聊几句
 * （花对话模型和后台模型的额度），之后重跑直接拿现成的对话来拍；`--reseed all`（或几位角色的标识，
 * 用逗号隔开）给她们开新对话重聊一遍。
 * 通话那几张真的打电话：假麦克风播一段 Windows 语音合成（System.Speech，要装中文语音）念的中文，她听写下来、
 * 用 Fish Audio 的声音回答；每通电话都在她的对话里记下一个回合，所以先拍手机的对话页再打电话。
 * 玩法页那张（gifts）不真抽奖：直接往开发库（`--database`，默认 backend/data/eidolon.db）里写下固定的背包、一张重置卡、
 * 几次抽奖次数和合起来的成就，每次重跑都一样；后端要配判断模型，「好感度和礼物」开着。
 * 日程那张（schedule）也直接写库：把这一周的工作排进演示用户的日程（周一到周五保存过，周末留几项草稿、几项待排），
 * 页面的时钟停在这一周的周三下午，做完的、进行中的、保存过的和草稿都拍得到；后端的日程要开着。
 * 周期那张（cycles）经接口给演示用户记几次经期：先删掉这位用户记过的，再按今天往前倒推着记，每次重跑都一样（日子跟着今天走）；
 * 后端的周期要开着。
 * 酒吧那张（bar）真的进一次门：后端的酒吧要开着、配好对话模型，花一次光顾的额度（连着重拍几次会碰上每小时的限额）；
 * 立绘和点唱机的小播放器要 EIDOLON_STAND_ASSETS_URL，存储桶里要有 `eidolon bar upload` 传上去的音频。
 * 照片那张要她真发一张：后端要配判断模型和生图（NOVELAI_API_KEY），第一次准备演示对话时花一张图的额度。
 * `--only` 只拍列出的几项，例如 `--only landing,app`；落地页的滚动动图（landing-tour）一步一拍，要十几分钟。
 *
 * 需要 Playwright 的 Chromium 和 PATH 里的 ffmpeg（带 libwebp）。退出码：0 成功；1 参数或登录有误；
 * 2 有几项没拍成，其余照常写出；3 打不开 Chromium 或没有 ffmpeg。
 */
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import { parseArgs, promisify } from "node:util";

import { chromium, type Browser, type BrowserContext, type Page } from "playwright";


// 落地页的时间线和页面同一个出处。Node 要带 .ts 扩展名才找得到它，tsc 又不许静态导入带扩展名，所以动态导入。
type TimelineModule = typeof import("../src/app/(landing)/model/timeline");
const timelineFile = pathToFileURL(path.resolve(import.meta.dirname, "../src/app/(landing)/model/timeline.ts")).href;
const { holdAt, spanOf, timelineOf } = (await import(timelineFile)) as TimelineModule;
const run = promisify(execFile);

const frontend = path.resolve(import.meta.dirname, "..");
const outDir = path.resolve(frontend, "..", "docs", "images");

const { values: args } = parseArgs({
  options: {
    origin: { type: "string", default: "http://localhost:3000" },
    user: { type: "string", default: "readme-demo" },
    only: { type: "string" },
    reseed: { type: "string" },
    database: { type: "string", default: path.resolve(frontend, "..", "backend", "data", "eidolon.db") },
  },
});
const origin = args.origin.replace(/\/$/, "");
const listOf = (value: string | undefined) => (value ? new Set(value.split(",").map((s) => s.trim())) : null);
const only = listOf(args.only);
/** `--reseed all` 或几位角色的标识。 */
const reseed = listOf(args.reseed);

const DESKTOP = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 };
const PHONE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };

/**
 * 演示用的对话，按顺序聊：列表按最近往来排，最后聊的排最上面。先对灯織说的事，恋鐘会以「听灯織说」的口吻提起
 * （跨角色共享的记忆）；真乃的第二句问的是原作剧情（回顾剧情）。
 */
const SEED: { character: string; turns: string[] }[] = [
  // 最先聊，排在列表最下面，不挤掉上面三位。
  { character: "meguru", turns: ["めぐる，你现在在干嘛呀？", "拍张照片给我看看吧！"] },
  { character: "hiori", turns: ["灯織，跟你说件事：我前几天领养了一只小猫，取名叫小白。"] },
  {
    character: "kogane",
    turns: ["恋鐘，你猜我家最近多了什么新成员？", "猜对了！它特别黏人，每天早上都跳到床上把我踩醒。"],
  },
  {
    character: "mano",
    turns: ["真乃，今天的练习辛苦啦！", "还记得我们第一次见面那天吗？"],
  },
];
/** 截图里打开的那位：她的对话最能说明「跨角色共享记忆」。 */
const FEATURED = "kogane";
/** 通话那几张打给谁。 */
const CALLEE = "mano";
/** 照片那张打开谁的对话：她在 SEED 里被要了一张照片。 */
const PHOTOGRAPHER = "meguru";
/** 通话里对她说的话（假麦克风念出来）。 */
const CALL_LINE = "真乃，最近有没有遇到什么开心的事？";
/** 背包里的礼物（目录 characters/gifts.toml 的 id 和件数）：几类、几档都有，礼物子页上两行正好排满；玩法页「礼物」卡写的件数是它们的和。 */
const BACKPACK: Record<string, number> = {
  cake: 1,
  pudding: 2,
  "meat-bun": 1,
  "black-tea": 3,
  cocoa: 1,
  bouquet: 1,
  book: 1,
  "music-cd": 2,
  plush: 1,
  "preserved-flower": 1,
};
/** 抽奖次数和重置卡张数（「礼物」卡的状态）。 */
const DRAWS = 3;
const RESET_CARDS = 1;
/**
 * 「成就」里合起来的两项各到第 1 阶段：来过的天数、抽过的奖（往来过几位由演示对话推出来）。键是后端的成就 id，
 * 数值要落在 backend/src/eidolon/achievements.py `ALL_CHARACTERS` 的第 1、2 阶段门槛之间，改门槛时跟着改。
 */
const ACHIEVEMENTS_OF_ALL = { days: 12, draws: 16 };
/** 日程那张页面上的「此刻」：这一周的周三（周一是 0）下午 2 点半，按演示用户的时区。 */
const SCHEDULE_NOW = { day: 2, hour: 14, minute: 30 };
/** 留在待排里的项数；其余的从周一上午起依次排下去。 */
const SCHEDULE_PENDING = 4;
/** 从这天（周一是 0）起排的是草稿，之前的是保存过的。 */
const SCHEDULE_DRAFTS_FROM = 5;

/** 周期页那张选中的她。 */
const CYCLES_FEATURED = "mano";
/**
 * 周期页那张记下的经期：角色、第一天离今天几天、天数。主角（CYCLES_FEATURED）记了四次，间隔 28、29、28 天，
 * 推算出的下一次在四天后，今天落在推算的经前，月历上记下的、推算的经期和经前都看得到；另外两位让卡片和筛选有数。
 */
const CYCLE_RECORDS: { character: string; daysAgo: number; days: number }[] = [
  { character: CYCLES_FEATURED, daysAgo: 109, days: 5 },
  { character: CYCLES_FEATURED, daysAgo: 81, days: 6 },
  { character: CYCLES_FEATURED, daysAgo: 52, days: 5 },
  { character: CYCLES_FEATURED, daysAgo: 24, days: 5 },
  { character: "kogane", daysAgo: 40, days: 6 },
  { character: "kogane", daysAgo: 11, days: 6 },
  { character: "hiori", daysAgo: 3, days: 5 },
];

/** 一项要拍的东西：`name` 给 `--only` 用。 */
type Item = { name: string; take: (browser: Browser) => Promise<void> };

const ITEMS: Item[] = [
  { name: "landing", take: landing },
  { name: "landing-tour", take: landingTour },
  { name: "app", take: app },
  { name: "phone", take: phone },
  { name: "outfits", take: outfits },
  { name: "gifts", take: gifts },
  { name: "schedule", take: schedule },
  { name: "cycles", take: cycles },
  { name: "photo", take: photo },
  { name: "bar", take: bar },
  { name: "call", take: call },
];

async function main(): Promise<number> {
  const items = ITEMS.filter((item) => !only || only.has(item.name));
  if (items.length === 0) {
    console.error(`没有要拍的：--only 只认 ${ITEMS.map((i) => i.name).join("、")}`);
    return 1;
  }
  try {
    await run("ffmpeg", ["-hide_banner", "-version"]);
  } catch {
    console.error("PATH 里没有 ffmpeg");
    return 3;
  }
  let browser: Browser;
  try {
    browser = await chromium.launch({
      args: ["--autoplay-policy=no-user-gesture-required", "--force-color-profile=srgb", "--hide-scrollbars"],
    });
  } catch (error) {
    console.error(`打不开 Playwright 的 Chromium（先运行 npx playwright install chromium）：${messageOf(error)}`);
    return 3;
  }
  const failed: string[] = [];
  try {
    await mkdir(outDir, { recursive: true });
    if (items.some((i) => !i.name.startsWith("landing"))) {
      const seeded = await seed(browser);
      if (!seeded) return 1;
    }
    for (const item of items) {
      try {
        await item.take(browser);
      } catch (error) {
        failed.push(item.name);
        console.error(`${item.name} 没拍成：${messageOf(error)}`);
      }
    }
  } finally {
    await browser.close();
  }
  if (failed.length > 0) {
    console.error(`${failed.length} 项没拍成：${failed.join("、")}`);
    return 2;
  }
  console.log(`写在 ${outDir}`);
  return 0;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// —— 登录和演示数据

/** 开发登录、同意条款，返回登录好的浏览器上下文；失败时是 null。 */
async function signedIn(browser: Browser, options: Parameters<Browser["newContext"]>[0]): Promise<BrowserContext> {
  const context = await browser.newContext(options);
  const res = await context.request.post(`${origin}/api/auth/dev-login`, { data: { name: args.user }, headers: { origin } });
  if (!res.ok()) {
    await context.close();
    throw new Error(`开发登录失败（${res.status()}）：后端要开着 EIDOLON_DEV_LOGIN=1`);
  }
  const consent = await context.request.post(`${origin}/api/account/consent`, {
    data: { agree_to_terms: true, at_least_13: true },
    headers: { origin },
  });
  if (!consent.ok()) throw new Error(`同意条款失败（${consent.status()}）`);
  return context;
}

type Conversation = { id: string; character_id: string };

/** 演示用户每位角色最新的对话；还没有对话或 `--reseed` 时照 SEED 真聊一遍。返回是否就绪。 */
async function seed(browser: Browser): Promise<boolean> {
  let context: BrowserContext;
  try {
    context = await signedIn(browser, {});
  } catch (error) {
    console.error(messageOf(error));
    return false;
  }
  try {
    const ask = async (apiPath: string) => {
      const res = await context.request.get(`${origin}${apiPath}`);
      if (!res.ok()) throw new Error(`${apiPath} 返回 ${res.status()}`);
      return res.json();
    };
    await context.request.put(`${origin}/api/profile`, {
      data: { form_of_address: null, gender: null, timezone: "Asia/Shanghai" },
      headers: { origin },
    });
    for (const { character, turns } of SEED) {
      const latest = ((await ask(`/api/conversations?character_id=${character}`)) as Conversation[])[0];
      const messages = latest ? ((await ask(`/api/conversations/${latest.id}/messages`)) as unknown[]) : [];
      if (messages.length > 0 && !reseed?.has("all") && !reseed?.has(character)) continue;
      const created = await context.request.post(`${origin}/api/conversations`, {
        data: { character_id: character },
        headers: { origin },
      });
      if (!created.ok()) throw new Error(`给 ${character} 开对话失败（${created.status()}）`);
      const conversation = (await created.json()) as Conversation;
      for (const text of turns) {
        console.log(`对 ${character} 说：${text}`);
        const res = await context.request.post(`${origin}/api/conversations/${conversation.id}/turns`, {
          data: { text, own_llm: null },
          headers: { origin },
          timeout: 180_000,
        });
        const body = await res.text();
        if (!res.ok() || body.includes('"type": "error"') || body.includes('"type":"error"')) {
          throw new Error(`对 ${character} 的回合失败（${res.status()}）：${body.slice(0, 300)}`);
        }
      }
      // 记忆在回合结束后由后台模型写下，等它写完再聊下一位，她才想得起来。
      await sleep(12_000);
    }
    return true;
  } catch (error) {
    console.error(`准备演示对话失败：${messageOf(error)}`);
    return false;
  } finally {
    await context.close();
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// —— 拍摄和编码

/** 等字体和图片都好了再拍。 */
async function settle(page: Page, ms = 800): Promise<void> {
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all(
      [...document.images].map((image) =>
        Promise.race([image.decode().catch(() => undefined), new Promise((r) => setTimeout(r, 5000))]),
      ),
    );
  });
  await page.waitForTimeout(ms);
}

/** 截下这一页（或页上一个区域），存成 `docs/images/<name>.webp`。 */
async function still(page: Page, name: string, clip?: { x: number; y: number; width: number; height: number }) {
  const dir = await mkdtemp(path.join(tmpdir(), "readme-media-"));
  try {
    const png = path.join(dir, "shot.png");
    await page.screenshot({ path: png, clip, animations: "allow", caret: "hide" });
    await toWebp(png, name);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

async function toWebp(png: string, name: string): Promise<void> {
  const out = path.join(outDir, `${name}.webp`);
  await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", png, "-c:v", "libwebp", "-quality", "88", out]);
  console.log(`写出 ${path.relative(path.dirname(outDir), out)}`);
}

/**
 * 录一段动图：`act` 做完之前一直用 CDP 的 screencast 收帧，按收到的时刻排好，压成循环播放的动图 WebP，
 * 宽 `width` 像素、每秒 `fps` 帧。
 */
async function clip(page: Page, name: string, act: () => Promise<void>, { width = 960, fps = 15 } = {}) {
  const dir = await mkdtemp(path.join(tmpdir(), "readme-media-"));
  const cdp = await page.context().newCDPSession(page);
  const frames: { file: string; t: number }[] = [];
  const writes: Promise<void>[] = [];
  cdp.on("Page.screencastFrame", (frame) => {
    const file = path.join(dir, `${String(frames.length).padStart(5, "0")}.jpg`);
    frames.push({ file, t: frame.metadata.timestamp ?? Date.now() / 1000 });
    writes.push(writeFile(file, Buffer.from(frame.data, "base64")));
    void cdp.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => undefined);
  });
  try {
    await cdp.send("Page.startScreencast", { format: "jpeg", quality: 92, everyNthFrame: 1 });
    await act();
    await cdp.send("Page.stopScreencast");
    await Promise.all(writes);
    if (frames.length < 2) throw new Error(`只收到 ${frames.length} 帧`);
    // 画面不动时浏览器不发新帧，所以每帧按到下一帧的间隔停留；最后一帧停半秒。
    const list = frames
      .map((f, i) => {
        const next = frames[i + 1]?.t ?? f.t + 0.5;
        return `file '${f.file.replaceAll("\\", "/")}'\nduration ${Math.max(next - f.t, 0.001).toFixed(4)}`;
      })
      .join("\n");
    const listFile = path.join(dir, "frames.txt");
    await writeFile(listFile, `ffconcat version 1.0\n${list}\nfile '${frames.at(-1)!.file.replaceAll("\\", "/")}'\n`);
    const out = path.join(outDir, `${name}.webp`);
    await run(
      "ffmpeg",
      [
        ...["-hide_banner", "-loglevel", "error", "-y", "-safe", "0", "-f", "concat", "-i", listFile],
        ...["-vf", `fps=${fps},scale=${width}:-2:flags=lanczos`],
        ...["-c:v", "libwebp_anim", "-quality", "72", "-compression_level", "6", "-loop", "0", out],
      ],
      { maxBuffer: 1 << 24 },
    );
    console.log(`写出 ${path.relative(path.dirname(outDir), out)}（${frames.length} 帧）`);
  } finally {
    await cdp.detach().catch(() => undefined);
    await rm(dir, { recursive: true, force: true });
  }
}

/**
 * 一步一拍的动图：每一步先做 `step(i)`，再截一张图，按每秒 `fps` 帧连起来；头尾各停一秒多。
 * 适合滚动驱动的画面：录屏时滚得快，会拍到还没画完的图块。
 */
async function flipbook(
  page: Page,
  name: string,
  count: number,
  step: (i: number) => Promise<void>,
  { width = 960, fps = 15 } = {},
) {
  const dir = await mkdtemp(path.join(tmpdir(), "readme-media-"));
  try {
    const files: string[] = [];
    for (let i = 0; i < count; i++) {
      await step(i);
      const file = path.join(dir, `${String(i).padStart(5, "0")}.jpg`);
      await page.screenshot({ path: file, type: "jpeg", quality: 92, animations: "allow", caret: "hide" });
      files.push(file);
    }
    const hold = Math.round(fps * 1.2);
    const sequence = [...Array(hold).fill(files[0]), ...files, ...Array(hold).fill(files.at(-1))];
    const listFile = path.join(dir, "frames.txt");
    const frame = (1 / fps).toFixed(4);
    const list = sequence.map((file) => `file '${file.replaceAll("\\", "/")}'\nduration ${frame}`).join("\n");
    await writeFile(listFile, `ffconcat version 1.0\n${list}\n`);
    const out = path.join(outDir, `${name}.webp`);
    await run(
      "ffmpeg",
      [
        ...["-hide_banner", "-loglevel", "error", "-y", "-safe", "0", "-f", "concat", "-i", listFile],
        ...["-vf", `fps=${fps},scale=${width}:-2:flags=lanczos`],
        ...["-c:v", "libwebp_anim", "-quality", "72", "-compression_level", "6", "-loop", "0", out],
      ],
      { maxBuffer: 1 << 24 },
    );
    console.log(`写出 ${path.relative(path.dirname(outDir), out)}（${count} 步）`);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

// —— 落地页

/** 等光层淡入（LightStage 给 .lp-root 加上 lp-gl-on）。 */
async function glOn(page: Page): Promise<void> {
  await page
    .waitForFunction(() => document.querySelector(".lp-root")?.classList.contains("lp-gl-on"), null, { timeout: 20_000 })
    .catch(() => undefined);
}

/** 运动版式里滚到时间线上第 `screens` 屏（和 scripts/landing-check.mjs 的同名函数一样换算）。 */
async function toScreens(page: Page, screens: number, wait = 1600): Promise<void> {
  const { sections } = timelineOf(await page.locator(".lp-seg").count());
  await page.evaluate(
    ({ screens, sections }) => {
      const els = [...document.querySelectorAll<HTMLElement>("[data-lp-section]")];
      const s = sections.find((s) => screens < s.from + s.screens) ?? sections.at(-1)!;
      const el = els[s.index];
      const top = el.getBoundingClientRect().top + window.scrollY;
      const vh = window.innerHeight;
      const into = screens - s.from;
      let y;
      if (s.pinned || el.offsetHeight <= vh) y = top + (into / s.screens) * el.offsetHeight;
      else if (into < s.screens - 1) y = top + (into / (s.screens - 1)) * (el.offsetHeight - vh);
      else y = top + el.offsetHeight - vh + (into - s.screens + 1) * vh;
      window.scrollTo(0, y);
    },
    { screens, sections },
  );
  if (wait > 0) await page.waitForTimeout(wait);
}

/** 打开落地页的完整档，等光层淡入。 */
async function openLanding(browser: Browser): Promise<{ context: BrowserContext; page: Page }> {
  const context = await browser.newContext(DESKTOP);
  const page = await context.newPage();
  await page.goto(`${origin}/?tier=full`, { waitUntil: "load" });
  await glOn(page);
  await settle(page, 1500);
  return { context, page };
}

/** README 顶上的横幅：第 0 幕的标题和白光，裁掉右上角的登录、左边的幕名轨和底下的声明。 */
async function landing(browser: Browser): Promise<void> {
  const { context, page } = await openLanding(browser);
  try {
    await still(page, "landing", { x: 80, y: 110, width: 1360, height: 600 });
  } finally {
    await context.close();
  }
}

/** 动图：从标题一路滚过分光、光谱的头两个组合。滚动中录屏会拍到没画完的图块，所以一步一拍（要十几分钟）。 */
async function landingTour(browser: Browser): Promise<void> {
  const { context, page } = await openLanding(browser);
  try {
    const tl = timelineOf(await page.locator(".lp-seg").count());
    const end = spanOf(tl, 2) ? holdAt(tl, 1) : (spanOf(tl, 1)?.to ?? 3);
    const steps = 140;
    await flipbook(page, "landing-tour", steps + 1, async (i) => {
      // 两头慢、中间快地滚，停在第二个组合上。
      const x = i / steps;
      await toScreens(page, x * x * (3 - 2 * x) * end, 120);
    });
  } finally {
    await context.close();
  }
}

// —— 应用

async function app(browser: Browser): Promise<void> {
  for (const scheme of ["light", "dark"] as const) {
    const context = await signedIn(browser, { ...DESKTOP, colorScheme: scheme });
    try {
      const page = await context.newPage();
      await page.goto(`${origin}/conversation/${FEATURED}`, { waitUntil: "networkidle" });
      await settle(page);
      await still(page, `app-${scheme}`);
    } finally {
      await context.close();
    }
  }
}

async function phone(browser: Browser): Promise<void> {
  const context = await signedIn(browser, { ...PHONE, colorScheme: "light" });
  try {
    const page = await context.newPage();
    await page.goto(`${origin}/conversations`, { waitUntil: "networkidle" });
    await settle(page);
    await still(page, "phone-list");
    await page.goto(`${origin}/conversation/${CALLEE}`, { waitUntil: "networkidle" });
    await settle(page);
    await still(page, "phone-chat");
  } finally {
    await context.close();
  }
}

async function outfits(browser: Browser): Promise<void> {
  const context = await signedIn(browser, { ...DESKTOP, colorScheme: "light" });
  try {
    const page = await context.newPage();
    await page.goto(`${origin}/conversation/${CALLEE}`, { waitUntil: "networkidle" });
    await settle(page);
    // 列表和对话栏各有一个「更多操作」，要对话栏的那个。
    await page.getByTestId("content").getByRole("button", { name: "更多操作" }).click();
    await page.getByRole("menuitem", { name: "换衣装" }).click();
    const dialog = page.getByRole("dialog");
    await dialog.waitFor();
    await page.waitForLoadState("networkidle");
    await settle(page, 3000);
    await still(page, "outfits");
  } finally {
    await context.close();
  }
}

/**
 * 把演示用户的礼物换成固定的一套：背包只有 BACKPACK，抽奖次数 DRAWS，重置卡 RESET_CARDS，合起来的成就到
 * ACHIEVEMENTS_OF_ALL。
 * 先读一次礼物状态，让后端建好这位用户的行、把到今天为止的次数发完，今天再读就不会加了。
 */
async function stockGifts(context: BrowserContext): Promise<void> {
  const read = await context.request.get(`${origin}/api/gifts`);
  if (!read.ok()) throw new Error(`读礼物状态失败（${read.status()}）`);
  if (!((await read.json()) as { open: boolean }).open) {
    throw new Error("好感度和礼物没开放：后端要配判断模型，开关不能关着");
  }
  const { id } = (await (await context.request.get(`${origin}/api/account`)).json()) as { id: string };
  const db = new DatabaseSync(args.database);
  try {
    db.exec("PRAGMA busy_timeout = 5000");
    db.exec("BEGIN IMMEDIATE");
    try {
      db.prepare("DELETE FROM gift_backpacks WHERE user_id = ?").run(id);
      const put = db.prepare("INSERT INTO gift_backpacks (user_id, gift_id, count) VALUES (?, ?, ?)");
      for (const [gift, count] of Object.entries(BACKPACK)) put.run(id, gift, count);
      db.prepare("UPDATE gift_balances SET draws = ?, reset_cards = ? WHERE user_id = ?").run(DRAWS, RESET_CARDS, id);
      // 「来过几天」按北京时间划天。
      const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai" }).format(new Date());
      const progress = db.prepare(
        "INSERT OR REPLACE INTO achievement_progress (user_id, achievement, character_id, count, last_day)" +
          " VALUES (?, ?, '', ?, ?)",
      );
      progress.run(id, "days", ACHIEVEMENTS_OF_ALL.days, today);
      progress.run(id, "draws", ACHIEVEMENTS_OF_ALL.draws, null);
      const stage = db.prepare(
        "INSERT OR IGNORE INTO achievement_stages (user_id, achievement, character_id, stage, unlocked_at)" +
          " VALUES (?, ?, '', 1, ?)",
      );
      // 和后端写的时刻同一种写法（带 +00:00），按字符串比先后才对。
      const now = new Date().toISOString().replace("Z", "+00:00");
      for (const achievement of Object.keys(ACHIEVEMENTS_OF_ALL)) stage.run(id, achievement, now);
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  } finally {
    db.close();
  }
}

/** 玩法页第一级：「礼物」「成就」和「日历」三张卡。 */
async function gifts(browser: Browser): Promise<void> {
  const context = await signedIn(browser, { ...DESKTOP, colorScheme: "light" });
  try {
    await stockGifts(context);
    const page = await context.newPage();
    // 新到的抽奖次数在「礼物」卡上带点，进了礼物子页才记成看过；新解锁的成就在「成就」卡上带点、状态换成「n 个新解锁」，
    // 离开那个子页才记成看过：先把两个子页各进一趟再回玩法页，拍出来不带点。
    await page.goto(`${origin}/play/gifts`, { waitUntil: "networkidle" });
    await page.getByRole("region", { name: "抽奖" }).waitFor();
    await page.goto(`${origin}/play/achievements`, { waitUntil: "networkidle" });
    await page.getByRole("region", { name: "成就" }).waitFor();
    await page.getByRole("button", { name: "返回" }).click();
    await page.waitForURL("**/play");
    await page.getByRole("link", { name: /还有 \d+ 次抽奖/ }).waitFor();
    await page.getByRole("link", { name: /(下一个|今天)：/ }).waitFor();
    await settle(page);
    await still(page, "gifts");
  } finally {
    await context.close();
  }
}

// 下面几样照 src/lib/schedule.ts 抄（脚本不从 src 导入）：接口的形状、三个时间段的名字（`SLOTS`）、草稿在本机的键（`draftsKey`）。
type Job = { id: string; length: number; slots: ("morning" | "afternoon" | "evening")[] | null };
type Placement = { job_id: string; day: number; slot: number };
type WeekOfJobs = { id: string; published: boolean; jobs: Job[] };

const SLOT_NAMES = ["morning", "afternoon", "evening"] as const;
/** 一周的格子数：7 天 × 3 段。 */
const CELLS = 21;
/** 每 5 格空出第 5 格，周视图上留几格空着的。 */
const EVERY_FIFTH_EMPTY = 5;

/**
 * 把这一周的工作从周一上午起依次排下去，每隔几格空一格，最后 SCHEDULE_PENDING 项不排；`SCHEDULE_DRAFTS_FROM`
 * 之前的写进库（保存过的），之后的返回给页面当草稿。不经过保存接口，所以不管现在几点、排没排过，每次重跑都一样。
 */
async function stockSchedule(
  context: BrowserContext,
): Promise<{ userId: string; timezone: string; week: string; drafts: Placement[] }> {
  const read = await context.request.get(`${origin}/api/schedule`);
  if (!read.ok()) throw new Error(`读日程失败（${read.status()}）`);
  const got = (await read.json()) as { enabled: boolean; timezone: string; this_week: WeekOfJobs };
  if (!got.enabled) throw new Error("日程没开：后端的 EIDOLON_SCHEDULE 不能是 0");
  const week = got.this_week;
  if (!week.published) throw new Error("这一周的工作还没发布");
  const taken = new Set<string>();
  const placed: Placement[] = [];
  const left = [...week.jobs];
  for (let cell = 0; cell < CELLS && left.length > SCHEDULE_PENDING; cell++) {
    const day = Math.floor(cell / 3);
    const slot = cell % 3;
    if (cell % EVERY_FIFTH_EMPTY === EVERY_FIFTH_EMPTY - 1 || taken.has(`${day}.${slot}`)) continue;
    const fits = (job: Job) =>
      slot + job.length <= 3 &&
      Array.from({ length: job.length }, (_, k) => slot + k).every(
        (s) => !taken.has(`${day}.${s}`) && (!job.slots || job.slots.includes(SLOT_NAMES[s])),
      );
    const at = left.findIndex(fits);
    if (at < 0) continue;
    const [job] = left.splice(at, 1);
    for (let k = 0; k < job.length; k++) taken.add(`${day}.${slot + k}`);
    placed.push({ job_id: job.id, day, slot });
  }
  const { id } = (await (await context.request.get(`${origin}/api/account`)).json()) as { id: string };
  const db = new DatabaseSync(args.database);
  try {
    db.exec("PRAGMA busy_timeout = 5000");
    db.exec("BEGIN IMMEDIATE");
    try {
      db.prepare("DELETE FROM schedule_placements WHERE user_id = ? AND week = ?").run(id, week.id);
      // 算过好感度的时刻也写上，演示用户的好感度不因此变。
      const now = new Date().toISOString().replace("Z", "+00:00");
      const put = db.prepare(
        "INSERT INTO schedule_placements (user_id, week, job_id, day, slot, saved_at, counted_at)" +
          " VALUES (?, ?, ?, ?, ?, ?, ?)",
      );
      for (const p of placed) if (p.day < SCHEDULE_DRAFTS_FROM) put.run(id, week.id, p.job_id, p.day, p.slot, now, now);
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  } finally {
    db.close();
  }
  return { userId: id, timezone: got.timezone, week: week.id, drafts: placed.filter((p) => p.day >= SCHEDULE_DRAFTS_FROM) };
}

/** `timeZone` 里 `date`（YYYY-MM-DD）那天的 `hour:minute` 是哪一刻。 */
function instantIn(timeZone: string, date: string, hour: number, minute: number): Date {
  const wanted = Date.parse(`${date}T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:00Z`);
  const shown = (at: number) => {
    const p = Object.fromEntries(
      new Intl.DateTimeFormat("en-CA", { timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
        hour: "2-digit", minute: "2-digit" }).formatToParts(at).map((part) => [part.type, part.value]),
    );
    return Date.parse(`${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:00Z`);
  };
  return new Date(wanted - (shown(wanted) - wanted));
}

/** 日历子页的周视图：几项保存过的（做完的、进行中的、还没到的）、周末几项草稿，左边还有待排。 */
async function schedule(browser: Browser): Promise<void> {
  const context = await signedIn(browser, { ...DESKTOP, colorScheme: "light" });
  try {
    const { userId, timezone, week, drafts } = await stockSchedule(context);
    const monday = new Date(`${week}T00:00:00Z`);
    monday.setUTCDate(monday.getUTCDate() + SCHEDULE_NOW.day);
    const page = await context.newPage();
    await page.clock.setFixedTime(
      instantIn(timezone, monday.toISOString().slice(0, 10), SCHEDULE_NOW.hour, SCHEDULE_NOW.minute),
    );
    // 草稿只存在本机（lib/schedule 的 keepDrafts），页面打开前放进去。
    await page.addInitScript(
      ([key, value]) => localStorage.setItem(key, value),
      [`eidolon.scheduleDrafts.${userId}.${week}`, JSON.stringify(drafts)] as const,
    );
    await page.goto(`${origin}/play/calendar`, { waitUntil: "networkidle" });
    await page.getByText(/^草稿 \d+ 项/).waitFor();
    await settle(page);
    await still(page, "schedule");
  } finally {
    await context.close();
  }
}

// 下面照 src/lib/cycles.ts 抄（脚本不从 src 导入）：接口的形状。
type CyclesView = { enabled: false } | { enabled: true; today: string; characters: { records: { id: string }[] }[] };

/** 删掉演示用户记过的经期，照 CYCLE_RECORDS 按今天倒推着重记一遍。 */
async function stockCycles(context: BrowserContext): Promise<void> {
  const read = await context.request.get(`${origin}/api/cycles`);
  if (!read.ok()) throw new Error(`读周期失败（${read.status()}）`);
  const view = (await read.json()) as CyclesView;
  if (!view.enabled) throw new Error("周期没开：后端的 EIDOLON_CYCLES 不能是 0，演示用户也不能在设置里关掉");
  for (const { records } of view.characters) {
    for (const { id } of records) {
      const res = await context.request.delete(`${origin}/api/cycles/records/${id}`, { headers: { origin } });
      if (!res.ok()) throw new Error(`删记录失败（${res.status()}）`);
    }
  }
  const today = new Date(`${view.today}T00:00:00Z`);
  for (const { character, daysAgo, days } of CYCLE_RECORDS) {
    const first = new Date(today);
    first.setUTCDate(first.getUTCDate() - daysAgo);
    const res = await context.request.post(`${origin}/api/cycles/${character}/records`, {
      data: { first_day: first.toISOString().slice(0, 10), days },
      headers: { origin },
    });
    if (!res.ok()) throw new Error(`给 ${character} 记经期失败（${res.status()}）：${await res.text()}`);
  }
}

/** 周期页：头像条、主角的月历（记下的、推算的经期和经前）、右栏的数字和记过的经期。 */
async function cycles(browser: Browser): Promise<void> {
  const context = await signedIn(browser, { ...DESKTOP, colorScheme: "light" });
  try {
    await stockCycles(context);
    const page = await context.newPage();
    await page.goto(`${origin}/play/cycles?who=${CYCLES_FEATURED}`, { waitUntil: "networkidle" });
    await page.getByText("记过的经期").waitFor();
    await settle(page);
    await still(page, "cycles");
  } finally {
    await context.close();
  }
}

/** 她发来的照片在后台生成，回合结束后还要等一会儿；没等到就算没拍成。 */
async function photo(browser: Browser): Promise<void> {
  const context = await signedIn(browser, { ...DESKTOP, colorScheme: "light" });
  try {
    const page = await context.newPage();
    const sent = page.getByRole("img", { name: "她发来的照片" });
    for (let tries = 0; ; tries++) {
      await page.goto(`${origin}/conversation/${PHOTOGRAPHER}`, { waitUntil: "networkidle" });
      if ((await sent.count()) > 0) break;
      if (tries >= 18) throw new Error("等了三分钟她还没发来照片：后端要配判断模型和生图，或者用 --reseed meguru 再要一次");
      await sleep(10_000);
    }
    await sent.last().scrollIntoViewIfNeeded();
    await settle(page, 1500);
    await still(page, "photo");
  } finally {
    await context.close();
  }
}

// —— 酒吧

/** 酒吧那张：她在说话（文本框里是她的日语和字幕），右上角开着点唱机的小播放器，只截 640×360 的画面（电脑上放大 2 倍）。 */
async function bar(browser: Browser): Promise<void> {
  const context = await signedIn(browser, { ...DESKTOP, colorScheme: "light" });
  try {
    const state = await context.request.get(`${origin}/api/bar`);
    if (!state.ok() || !((await state.json()) as { enabled: boolean }).enabled) {
      throw new Error("酒吧没开：后端的 EIDOLON_BAR 不能是 0");
    }
    const { id } = (await (await context.request.get(`${origin}/api/account`)).json()) as { id: string };
    const page = await context.newPage();
    // 跳过第一次进来的教程（lib/barTutorial 的「看过」照 lib/seenOnDevice 存一个时刻）。
    await page.addInitScript(
      ([key, value]) => localStorage.setItem(key, value),
      [`eidolon.barTutorialSeen.${id}`, JSON.stringify(new Date().toISOString())] as const,
    );
    await page.goto(`${origin}/play/bar`, { waitUntil: "networkidle" });
    // 选曲界面先刷开，Ready! 才出来。
    await page.getByRole("button", { name: "Ready!" }).click({ timeout: 20_000 });
    await page.getByRole("button", { name: "点一下进门" }).click();
    const box = page.getByRole("button", { name: "继续" });
    await box.waitFor({ timeout: 120_000 });
    await page.getByRole("button", { name: "点唱机" }).click();
    // 文本框里写的是她的话（有假名）才拍；是制作人的就点过去，点到她点单了还没轮到她就算没拍成。
    const herLineShown = () =>
      page.evaluate(() =>
        [...document.querySelectorAll(".bar-stage canvas[aria-label]")].some((c) =>
          /[\u3040-\u30ff]/.test(c.getAttribute("aria-label") ?? ""),
        ),
      );
    for (let taps = 0; !(await herLineShown()); taps++) {
      if (taps >= 12 || (await box.count()) === 0) throw new Error("一直没轮到她说话");
      await box.click();
      await page.waitForTimeout(1500);
    }
    // 等这一页打完（每秒 30 字），立绘也换上了表情。
    await settle(page, 4000);
    const stage = await page.locator(".bar-stage:not(.bar-portrait-guard)").boundingBox();
    if (!stage) throw new Error("找不到酒吧的画面");
    await still(page, "bar", stage);
    await page.getByRole("button", { name: "离开" }).click();
    await page.waitForURL("**/play");
  } finally {
    await context.close();
  }
}

// —— 通话

/**
 * 假麦克风要播的录音：先静 6 秒（拨号到接通的工夫），再用 Windows 的中文语音念 CALL_LINE，后面再静 4 秒。
 * Chromium 只认 PCM 的 WAV。
 */
async function micRecording(dir: string): Promise<string> {
  const spoken = path.join(dir, "line.wav");
  const padded = path.join(dir, "mic.wav");
  const say = [
    "Add-Type -AssemblyName System.Speech",
    "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer",
    "$v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -eq 'zh-CN' } | Select-Object -First 1",
    "if (-not $v) { exit 4 }",
    "$s.SelectVoice($v.VoiceInfo.Name)",
    `$s.SetOutputToWaveFile('${spoken}')`,
    `$s.Speak('${CALL_LINE}')`,
    "$s.Dispose()",
  ].join("; ");
  try {
    await run("powershell.exe", ["-NoProfile", "-Command", say]);
  } catch {
    throw new Error("没能合成假麦克风的录音：要在装了中文语音（如 Microsoft Huihui）的 Windows 上运行");
  }
  await run("ffmpeg", [
    ...["-hide_banner", "-loglevel", "error", "-y", "-i", spoken],
    ...["-af", "adelay=6000,apad=pad_dur=4", "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", padded],
  ]);
  return padded;
}

/** 通话层上她这一句的日语（台词卡里第一行）；还没开口时是 null。 */
async function herLine(page: Page): Promise<string | null> {
  const card = page.locator("section[aria-label$='的通话'] .text-call-line").first();
  return (await card.count()) > 0 ? (await card.innerText()).trim() || null : null;
}

/**
 * 打一通电话，对她说 CALL_LINE，等她开口：电脑上录下从接通到她说完的动图、拍一张她说话时的图；手机上只拍图。
 * 每通电话都会在她的对话里记下一个回合。
 */
async function call(): Promise<void> {
  const dir = await mkdtemp(path.join(tmpdir(), "readme-media-"));
  const browser = await chromium.launch({
    args: [
      "--autoplay-policy=no-user-gesture-required",
      "--force-color-profile=srgb",
      "--hide-scrollbars",
      "--use-fake-ui-for-media-stream",
      "--use-fake-device-for-media-stream",
      `--use-file-for-fake-audio-capture=${await micRecording(dir)}%noloop`,
    ],
  });
  try {
    for (const [name, options] of [
      ["call", DESKTOP],
      ["phone-call", PHONE],
    ] as const) {
      const context = await signedIn(browser, { ...options, colorScheme: "light", permissions: ["microphone"] });
      try {
        const page = await context.newPage();
        await page.goto(`${origin}/conversation/${CALLEE}`, { waitUntil: "networkidle" });
        await settle(page);
        await page.getByRole("button", { name: /^和.+通话$/ }).click();
        // 接通后状态行换成计时。
        const layer = page.locator(`section[aria-label$='的通话']`);
        await layer.getByText(/^\d\d:\d\d$/).waitFor({ timeout: 30_000 });
        const speak = async () => {
          const before = await herLine(page);
          const deadline = Date.now() + 60_000;
          let line: string | null = null;
          while (Date.now() < deadline && (line === null || line === before)) {
            await page.waitForTimeout(250);
            line = await herLine(page);
          }
          if (line === null || line === before) throw new Error("她一直没开口：看看后端日志里的语音识别和对话模型");
          // 她开口一会儿再拍：嘴在动、表情换上了。
          await page.waitForTimeout(1500);
          await still(page, name);
          // 等到台词停下来不变（她说完了），最多再等 20 秒。
          let last = await herLine(page);
          for (let quiet = 0, n = 0; quiet < 12 && n < 80; n++) {
            await page.waitForTimeout(250);
            const now = await herLine(page);
            quiet = now === last ? quiet + 1 : 0;
            last = now;
          }
          await page.waitForTimeout(1500);
        };
        if (name === "call") await clip(page, "call-demo", speak, { width: 960, fps: 12 });
        else await speak();
        await page.getByRole("button", { name: "挂断" }).click();
        await page.waitForTimeout(1000);
      } finally {
        await context.close();
      }
    }
  } finally {
    await browser.close();
    await rm(dir, { recursive: true, force: true });
  }
}

try {
  process.exitCode = await main();
} catch (error) {
  console.error(`出错：${messageOf(error)}`);
  process.exitCode = 3;
}
