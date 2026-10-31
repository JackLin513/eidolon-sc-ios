import { api } from "@/lib/api";

/**
 * 她念信的声音（GLOSSARY.md「信」）：一块一个 mp3（第 0 块是抬头，之后每段一块）。信封一出来就开始取；拆开那一下
 * （`unlock`，要在点击里调，浏览器才让它出声）建 Web Audio 的上下文、解码，得到每块的时长，拿去排时间轴；
 * 信纸展开后按时间轴把每块排在音频时钟上（`play`），字跟着音频时钟写（lib/letter 的 `tick`）。
 * 整封信的声音都在内存里，放起来以后网络再卡也不会让声音停下；音频时钟停了（被系统打断）由拆信层改按时钟写、`stop`。
 */
export class LetterVoice {
  private readonly fetched: Promise<ArrayBuffer[] | null>;
  private context: AudioContext | null = null;
  private gain: GainNode | null = null;
  private buffers: AudioBuffer[] | null = null;
  private sources: AudioBufferSourceNode[] = [];
  private isClosed = false;

  constructor(urls: string[]) {
    this.fetched = Promise.all(
      urls.map(async (url) => {
        const res = await api(url);
        if (!res.ok) throw new Error(`voice ${res.status}`);
        return res.arrayBuffer();
      }),
    ).catch(() => null);
  }

  /**
   * 拆开：在这一下点击里建音频的上下文，等它跑起来、每块都解码好，给出每块的时长（秒）。取不到、解码失败、
   * 浏览器不让出声，或者 `waitMs` 毫秒内没好，给 null：不要声音了。
   */
  unlock(waitMs: number): Promise<number[] | null> {
    if (this.isClosed || typeof AudioContext === "undefined") return Promise.resolve(null);
    let context: AudioContext;
    try {
      context = new AudioContext();
    } catch {
      return Promise.resolve(null);
    }
    this.context = context;
    this.gain = context.createGain();
    this.gain.connect(context.destination);
    const ready = Promise.all([
      context.resume(),
      this.fetched.then((data) => (data ? Promise.all(data.map((d) => context.decodeAudioData(d))) : null)),
    ]).then(([, buffers]) => buffers);
    let timer = 0;
    const late = new Promise<null>((resolve) => {
      timer = window.setTimeout(() => resolve(null), waitMs);
    });
    return Promise.race([ready, late])
      .catch(() => null)
      .then((buffers) => {
        window.clearTimeout(timer);
        this.buffers = buffers;
        return buffers?.map((b) => b.duration) ?? null;
      });
  }

  /** 开口：第 i 块排在开口算起的第 `starts[i]` 秒放。给出开口那一刻的音频时钟（秒）；放不了时 null。 */
  play(starts: number[]): number | null {
    const { context, gain, buffers } = this;
    if (this.isClosed || !context || !gain || !buffers || context.state !== "running") return null;
    const base = context.currentTime;
    this.sources = buffers.map((buffer, i) => {
      const source = context.createBufferSource();
      source.buffer = buffer;
      source.connect(gain);
      source.start(base + (starts[i] ?? 0));
      return source;
    });
    return base;
  }

  /** 现在的音频时钟（秒）。 */
  time(): number {
    return this.context?.currentTime ?? 0;
  }

  setMuted(isMuted: boolean): void {
    if (this.gain) this.gain.gain.value = isMuted ? 0 : 1;
  }

  /** 停掉声音：排好的、在放的都停。 */
  stop(): void {
    for (const source of this.sources) {
      try {
        source.stop();
      } catch {
        // 还没 start 过的不会走到这里；已经停了的照样往下走。
      }
    }
    this.sources = [];
  }

  /** 在 `ms` 毫秒里淡出，然后关掉。 */
  fadeOut(ms: number): void {
    const { context, gain } = this;
    if (this.isClosed || !context || !gain || ms <= 0) {
      this.close();
      return;
    }
    const now = context.currentTime;
    gain.gain.cancelScheduledValues(now);
    gain.gain.setValueAtTime(gain.gain.value, now);
    gain.gain.linearRampToValueAtTime(0, now + ms / 1000);
    window.setTimeout(() => this.close(), ms);
  }

  /** 停掉声音，放掉音频的上下文。 */
  close(): void {
    if (this.isClosed) return;
    this.isClosed = true;
    this.stop();
    void this.context?.close().catch(() => {});
  }
}
