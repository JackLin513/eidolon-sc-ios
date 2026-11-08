import { mixOklab } from "./model/oklab";
import { describeScene, type Band, type BandLight, type Scene, type Viewport } from "./model/scene";

/** 横屏和竖屏各画一张，样式表按画面比例选一张（和模型里竖屏的界线一样）。 */
const VIEWS: { viewport: Viewport; className: string }[] = [
  { viewport: { w: 1600, h: 900 }, className: "lp-static-light lp-static-landscape" },
  { viewport: { w: 900, h: 1600 }, className: "lp-static-light lp-static-portrait" },
];

/**
 * 静态档（省流量、不支持 WebGL，或者没有 JS）的第 1 幕：SVG 画的第 1 幕完成态，几何和着色器版同一套，
 * 都来自落地页模型：白光、棱镜、出口附近的连续色散和一道道光。服务端渲染，不带客户端 JS。定格档里它先顶着，
 * 着色器那一帧画好就让开。
 */
export function StaticLight({ lights }: { lights: BandLight[] }) {
  return VIEWS.map(({ viewport, className }) => {
    const { beam, prism, fan, bands } = describeScene({ lights, scroll: 1, viewport, tier: "static" });
    const id = `${viewport.w}x${viewport.h}`;
    const glow = `lp-glow-${id}`;
    const bandStart = bands[0]?.start ?? 0;
    return (
      <svg
        key={className}
        className={className}
        viewBox={`0 0 ${viewport.w} ${viewport.h}`}
        preserveAspectRatio="xMidYMid slice"
        aria-hidden
      >
        <defs>
          <filter id={glow} x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="7" />
          </filter>
          <DispersionDefs id={id} fan={fan} />
          {/* 一道道光离开连续色散的地方慢慢亮起来（着色器里沿光线 smoothstep(start, start + 90)），不是一刀切。 */}
          <radialGradient id={`lp-band-in-g-${id}`} gradientUnits="userSpaceOnUse" cx={round(fan.x)} cy={round(fan.y)} r={round(bandStart + 90)}>
            <stop offset={(bandStart / (bandStart + 90)).toFixed(3)} stopColor="#000" />
            <stop offset="1" stopColor="#fff" />
          </radialGradient>
          <mask id={`lp-band-in-${id}`} maskUnits="userSpaceOnUse" x="0" y="0" width={viewport.w} height={viewport.h}>
            <rect width={viewport.w} height={viewport.h} fill={`url(#lp-band-in-g-${id})`} />
          </mask>
        </defs>
        <line x1={round(beam.x0)} y1={round(beam.y0)} x2={round(beam.x1)} y2={round(beam.y1)} stroke="#fff" strokeOpacity="0.35" strokeWidth="12" filter={`url(#${glow})`} />
        <line x1={round(beam.x0)} y1={round(beam.y0)} x2={round(beam.x1)} y2={round(beam.y1)} stroke="#fff" strokeWidth="2" />
        <polygon
          points={[prism.apex, prism.left, prism.right].map((p) => p.map(round).join(",")).join(" ")}
          fill="#fff"
          fillOpacity="0.03"
          stroke="#e8eeff"
          strokeOpacity="0.6"
          strokeWidth="1.2"
        />
        {/* 棱镜里的一段光路：从入射点到出射点。 */}
        <line x1={round(beam.x1)} y1={round(beam.y1)} x2={round(prism.exit[0])} y2={round(prism.exit[1])} stroke="#fff" strokeOpacity="0.7" strokeWidth="1.5" />
        <Dispersion id={id} fan={fan} bands={bands} />
        <g mask={`url(#lp-band-in-${id})`}>
          {bands.map((b) => {
            const from = [b.x + b.dx * b.start, b.y + b.dy * b.start].map(round);
            const to = [b.x + b.dx * b.length, b.y + b.dy * b.length].map(round);
            return (
              <g key={b.id} opacity={round(Math.min(1, b.intensity * 1.6))}>
                <line x1={from[0]} y1={from[1]} x2={to[0]} y2={to[1]} stroke={b.color} strokeWidth="10" strokeOpacity="0.55" filter={`url(#${glow})`} />
                <line x1={from[0]} y1={from[1]} x2={to[0]} y2={to[1]} stroke="#fff" strokeOpacity="0.85" strokeWidth="1.2" />
              </g>
            );
          })}
        </g>
      </svg>
    );
  });
}

/** 连续色散里每两道色相相邻的光之间切几片扇形：片越多，颜色过渡越顺。 */
const SLICES = 3;

/**
 * 出口附近的连续色散，照着色器画（light.ts 的「出口附近的连续色散」）：以出口为圆心的一个扇面，颜色按
 * 扇面上的位置在色相相邻的两道光之间过渡，中心是白的，往外淡出，再往外就只剩一道道她们自己的颜色。
 * SVG 里用一片片细扇形拼出颜色的过渡，略微模糊掉接缝；中心的白和往外的淡出用两个径向渐变。
 */
function Dispersion({ id, fan, bands }: { id: string; fan: Scene["fan"]; bands: Band[] }) {
  const byHue = [...bands].sort((a, b) => a.hue - b.hue).map((b) => b.color);
  if (fan.intensity <= 0 || byHue.length === 0) return null;
  const n = byHue.length;
  const count = Math.max(1, (n - 1) * SLICES);
  const at = (u: number) => {
    const angle = fan.angle + (u - 0.5) * 2 * fan.spread;
    return [fan.x + Math.cos(angle) * fan.radius, fan.y + Math.sin(angle) * fan.radius].map(round).join(",");
  };
  const colorAt = (u: number) => {
    const x = u * (n - 1);
    const i = Math.min(n - 2, Math.floor(x));
    return n === 1 ? byHue[0] : mixOklab(byHue[i], byHue[i + 1], x - i);
  };
  const center = [fan.x, fan.y].map(round).join(",");
  const sector = Array.from({ length: count + 1 }, (_, k) => at(k / count)).join(" ");
  return (
    <g opacity={round(0.7 * fan.intensity)} mask={`url(#lp-fan-fade-${id})`}>
      <g filter={`url(#lp-fan-blur-${id})`}>
        {Array.from({ length: count }, (_, k) => (
          // 每片多盖一点到下一片，模糊以后看不出接缝。
          <polygon key={k} points={`${center} ${at(k / count)} ${at(Math.min(1, (k + 1.6) / count))}`} fill={colorAt((k + 0.5) / count)} />
        ))}
      </g>
      <polygon points={`${center} ${sector}`} fill={`url(#lp-fan-white-${id})`} />
    </g>
  );
}

/** 连续色散要的渐变、遮罩和模糊。 */
function DispersionDefs({ id, fan }: { id: string; fan: Scene["fan"] }) {
  const r = round(fan.radius);
  const [cx, cy] = [round(fan.x), round(fan.y)];
  return (
    <>
      {/* 往外淡出：着色器里是 1 − smoothstep(0.3R, R, r)。 */}
      <radialGradient id={`lp-fan-fade-g-${id}`} gradientUnits="userSpaceOnUse" cx={cx} cy={cy} r={r}>
        <stop offset="0.3" stopColor="#fff" />
        <stop offset="0.65" stopColor="#fff" stopOpacity="0.5" />
        <stop offset="1" stopColor="#fff" stopOpacity="0" />
      </radialGradient>
      <mask id={`lp-fan-fade-${id}`} maskUnits="userSpaceOnUse" x={cx - r} y={cy - r} width={2 * r} height={2 * r}>
        <circle cx={cx} cy={cy} r={r} fill={`url(#lp-fan-fade-g-${id})`} />
      </mask>
      {/* 中心是白的：着色器里是 mix(白, 颜色, smoothstep(0, 0.4R, r))。 */}
      <radialGradient id={`lp-fan-white-${id}`} gradientUnits="userSpaceOnUse" cx={cx} cy={cy} r={round(fan.radius * 0.4)}>
        <stop offset="0" stopColor="#fff" />
        <stop offset="1" stopColor="#fff" stopOpacity="0" />
      </radialGradient>
      <filter id={`lp-fan-blur-${id}`} x="-20%" y="-20%" width="140%" height="140%">
        <feGaussianBlur stdDeviation="2.5" />
      </filter>
    </>
  );
}

/** 坐标留一位小数，HTML 小一点。 */
const round = (x: number) => Math.round(x * 10) / 10;
