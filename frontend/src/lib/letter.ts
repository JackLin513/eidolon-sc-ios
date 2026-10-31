// 信（GLOSSARY.md「信」）：她在特别的日子写给制作人的一封信。这里管接口上的信长什么样、页首信封键有没有点、
// 拆开以后每个字什么时候写出来（时间轴）。时间轴的常量沿用停服前「她的信」。

/** 写信的场合（后端 letter_prompt.Occasion）。几个场合合在一封时按这个顺序列出。 */
export type Occasion =
  | "intimate"
  | "close"
  | "complete"
  | "her_birthday"
  | "producer_birthday"
  | "anniversary";

/** 所有的信列表里的一封：读没读过、弹没弹过在每台设备上都一样。 */
export type LetterSummary = {
  id: number;
  character_id: string;
  occasions: Occasion[];
  /** 写信那天（制作人那边的日期），`YYYY-MM-DD`。 */
  day: string;
  read: boolean;
  popped: boolean;
};

/** 读一封：抬头和各段（日语已去掉语气提示）、信末的签名、每块语音的地址；没有语音、配乐时为 null。 */
export type Letter = {
  id: number;
  character_id: string;
  occasions: Occasion[];
  day: string;
  salutation: string;
  paragraphs: { ja: string; zh: string }[];
  /** 她手写的签名图（透明底），没有时 `image` 为 null，照 `text` 用信上的字体写出来。 */
  signature: { image: string | null; text: string };
  /** 她念这封信的 mp3，一块一个：第 0 块是抬头，之后每段一块。部署者没有语音合成、合成失败时为 null。 */
  voice: string[] | null;
  music: null;
};

/** 页首的信封键：部署者开着信，或者用户已经有信时才出现。 */
export function showsLetterButton(lettersOn: boolean, letters: LetterSummary[] | null): boolean {
  return lettersOn || (letters?.length ?? 0) > 0;
}

/** 页首的信封键带不带点：有没读过的信。 */
export function hasUnread(letters: LetterSummary[] | null): boolean {
  return letters?.some((l) => !l.read) ?? false;
}

/** 信封上的日期：「10月31日」，不是今年的带上年份。 */
export function letterDay(day: string, thisYear: number): string {
  const [year, month, date] = day.split("-").map(Number);
  return year === thisYear ? `${month}月${date}日` : `${year}年${month}月${date}日`;
}

/** 信纸展开后，留多久才开始写（秒）：她这时还没开口。 */
export const LEAD_IN = 1.2;

/** 抬头之后、段与段之间停多久（秒）。 */
export const PAUSES = { afterSalutation: 0.6, betweenParagraphs: 0.9 };

/** 最后一块写完以后隔多久签名（秒），和签名从左到右写出来要多久。 */
export const SIGNATURE_DELAY = 0.8;
export const SIGNATURE_SECONDS = 1.6;

/** 没有语音时，估一个字念多久（秒）。 */
export const SECONDS_PER_CHAR = 0.15;

/** 信上的一块：抬头或一段正文（带字幕），和它在时间轴上从几秒写到几秒。 */
export type Part = {
  kind: "salutation" | "paragraph";
  /** 一个字一项（按码点拆，不拆坏代理对）。 */
  chars: string[];
  zh: string | null;
  start: number;
  end: number;
  /** 每个字从第几秒起显出来，和 `chars` 一一对应，单调不减。 */
  at: number[];
};

/** 写完一个字之后，下一个字要多等的份量（一个字算 1）：念到标点时停一下。 */
function pauseAfter(char: string): number {
  if ("。！？!?".includes(char)) return 3;
  if ("、，,".includes(char)) return 1.5;
  if ("…‥".includes(char)) return 0.8;
  return 0;
}

/** 把一块字摊到 [start, end] 上：每个字占 1 份，标点后面多停几份，最后一个字在 end 之前写出来。 */
function spread(chars: string[], start: number, end: number): number[] {
  const offsets: number[] = [];
  let total = 0;
  for (const char of chars) {
    offsets.push(total);
    total += 1 + pauseAfter(char);
  }
  const span = Math.max(0, end - start);
  return offsets.map((o) => start + (total > 0 ? (span * o) / total : 0));
}

/**
 * 信上的各块，按写的顺序，带时间轴：信纸展开后留 `LEAD_IN`，一块接一块，抬头之后、段与段之间各停一下。
 * 每块写多久：给了 `durations`（每块语音的实际时长，秒，和块数一样多）就照它，没给时按字数估。
 */
export function partsOf(letter: Pick<Letter, "salutation" | "paragraphs">, durations?: number[] | null): Part[] {
  const blocks: Omit<Part, "start" | "end" | "at">[] = [
    { kind: "salutation", chars: Array.from(letter.salutation), zh: null },
    ...letter.paragraphs.map((p) => ({ kind: "paragraph" as const, chars: Array.from(p.ja), zh: p.zh })),
  ];
  const lengths =
    durations?.length === blocks.length
      ? durations
      : blocks.map((b) => Math.max(1, b.chars.length * SECONDS_PER_CHAR));
  let at = LEAD_IN;
  return blocks.map((block, i) => {
    const start = at;
    const end = start + lengths[i];
    at = end + (i === 0 ? PAUSES.afterSalutation : PAUSES.betweenParagraphs);
    return { ...block, start, end, at: spread(block.chars, start, end) };
  });
}

/** 到第 `t` 秒，这一块写出了几个字。 */
export function written(part: Part, t: number): number {
  let n = 0;
  while (n < part.at.length && part.at[n] <= t) n++;
  return n;
}

/** 第几秒开始签名：最后一块写完之后。 */
export function signsAt(parts: Part[]): number {
  return (parts.length > 0 ? parts[parts.length - 1].end : 0) + SIGNATURE_DELAY;
}

/** 整封信在第几秒写完：签名写完。 */
export function finishesAt(parts: Part[]): number {
  return signsAt(parts) + SIGNATURE_SECONDS;
}

/** 拆开以后，语音最多等这么久取下、解码好（毫秒）；等的时候信纸上的字停着，等她开口再写。等不到就不要声音，按字数估。 */
export const VOICE_WAIT_MS = 10000;

/** 跟着声音写时，音频的时钟这么久没往前走（被系统打断、挂起）就改按时钟写，并且停掉声音，免得声音和字对不上（毫秒）。 */
export const STALL_MS = 4000;

/**
 * 写到第几秒怎么算。跟着声音：音频时钟上 `base` 是开口算起的第 0 秒，`heard` 是上一次读到的音频时钟，
 * `movedAt` 是它上一次往前走的时刻（毫秒，performance.now）。按时钟：从第 `from` 秒、`since` 毫秒时接着走。
 */
export type LetterClock =
  | { by: "voice"; base: number; heard: number; movedAt: number }
  | { by: "timer"; from: number; since: number };

/** 跟着声音写，开口那一刻在音频时钟的 `base` 秒，现在是 `now` 毫秒。 */
export function voiceClock(base: number, now: number): LetterClock {
  return { by: "voice", base, heard: Number.NaN, movedAt: now };
}

/** 按时钟写，从第 0 秒、现在（`now` 毫秒）起。 */
export function timerClock(now: number): LetterClock {
  return { by: "timer", from: 0, since: now };
}

/**
 * 到 `now` 毫秒写到第几秒；跟着声音时 `audioTime` 是这时的音频时钟（秒）。音频时钟超过 `STALL_MS` 没往前走，
 * 就改成按时钟、从停下的那一秒接着走（返回的 `clock.by` 变成 "timer"，调用的一方据此停掉声音）。
 */
export function tick(clock: LetterClock, now: number, audioTime: number): { clock: LetterClock; at: number } {
  if (clock.by === "timer") return { clock, at: clock.from + (now - clock.since) / 1000 };
  const at = Math.max(0, audioTime - clock.base);
  if (audioTime !== clock.heard) return { clock: { ...clock, heard: audioTime, movedAt: now }, at };
  if (now - clock.movedAt > STALL_MS) return { clock: { by: "timer", from: at, since: now }, at };
  return { clock, at };
}
