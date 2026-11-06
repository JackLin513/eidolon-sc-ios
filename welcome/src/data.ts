// 把随 App 打包的名册（welcome.json）翻成落地页认识的角色列表（spec #118）。
// 名册和招呼语音都通过 App 的自定义 scheme 读，页面自己不联网。
import type { Character, LandingAssets } from "./shims/api";

type Idol = {
  id: string;
  number: string;
  name: string;
  nameZh: string | null;
  official: string;
  ink: string;
  halo: string;
  greeting: string | null;
  greetingJa: string | null;
  subtitle: string | null;
};

type Roster = {
  version: number;
  units: { name: string; idols: Idol[] }[];
  callOpener: string | null;
  callOpenerJa: string | null;
  callOpenerSubtitle: string | null;
  callPoster: string | null;
  speaker: string;
};

export type WelcomeData = { characters: Character[]; assets: LandingAssets };

// 素材在 App 的另一个 host 上（`eidolon-welcome://media/…` → Resources/Welcome）。
// 用绝对地址：页面自己是 `…://app/index.html`，写成 `/media/…` 会落到页面那个 host 下。
const media = (path: string) => `eidolon-welcome://media/${path}`;

export async function loadWelcome(): Promise<WelcomeData> {
  const response = await fetch(media("welcome.json"));
  if (!response.ok) throw new Error(`welcome.json: ${response.status}`);
  const roster: Roster = await response.json();

  const characters = roster.units.flatMap((unit, order) =>
    unit.idols.map((idol): Character => {
      const speaks = idol.id === roster.speaker;
      return {
        id: idol.id,
        name: idol.name,
        color: idol.official,
        idol_id: Number(idol.number) || null,
        unit: unit.name,
        unit_order: order,
        name_zh: idol.nameZh,
        greeting:
          idol.greeting && idol.greetingJa
            ? {
                ja: idol.greetingJa,
                subtitle: idol.subtitle ?? "",
                audio_url: media(`greetings/${idol.greeting}`),
              }
            : null,
        call_opener:
          speaks && roster.callOpenerJa
            ? {
                ja: roster.callOpenerJa,
                subtitle: roster.callOpenerSubtitle ?? "",
                audio_url: roster.callOpener ? media(`greetings/${roster.callOpener}`) : null,
              }
            : null,
        call_poster_url: speaks && roster.callPoster ? media(`stills/${roster.callPoster}`) : null,
        voxels_url: null,
        stand: null,
      };
    }),
  );

  return { characters, assets: { memory_still_url: media("stills/welcome-memory.webp") } };
}
