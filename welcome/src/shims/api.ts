// 落地页用到的那几个类型（上游 lib/api.ts 的子集）。只留这个页面真的会读的字段：
// 立绘（stand）和体素（voxels_url）在端上暂时没有，一律传 null，页面自己会降级成颜色和名字。
export type Provider = "github" | "google";

export type Greeting = {
  ja: string;
  subtitle: string;
  audio_url: string | null;
};

export type CallOpener = Greeting;

export type Outfit = { id: string; url: string };

export type Stand = { default_outfit: Outfit; outfits_url: string };

export type Character = {
  id: string;
  name: string;
  color: string;
  idol_id: number | null;
  unit: string | null;
  unit_order: number | null;
  name_zh: string | null;
  greeting: Greeting | null;
  call_opener: CallOpener | null;
  call_poster_url: string | null;
  voxels_url: string | null;
  stand: Stand | null;
};

export type SignInOptions = { providers: Provider[]; dev_login: boolean; contact: string | null };

export type LandingAssets = { memory_still_url: string | null };
