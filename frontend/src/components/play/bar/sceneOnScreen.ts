import { loadPixelFont, measurePixelText } from "@/components/play/bar/PixelText";
import { copy } from "@/i18n";
import type { Character } from "@/lib/api";
import type { BarMixerAction } from "@/lib/barMixer";
import type { BarSceneState } from "@/lib/barScene";
import { paginate, type TextLine, type TextPage } from "@/lib/barText";

/**
 * 画面上的「当前场景」（lib/barScene）：光顾（useBarVisit）和教程（useBarTutorial）都交出这个形状，画面那一层只挑一次用哪个。
 * `guest` 是店里这一位（`key` 换人时换新，立绘从头画）；`now` 是文本框的时钟（useTypingClock）。
 */
export type CurrentScene = {
  scene: BarSceneState;
  now: number;
  guest: { key: string; characterId: string } | null;
  tap: () => void;
  mix: (action: BarMixerAction) => void;
  serve: () => void;
};

/** 按 `her` 给一句分页：她的名字写短名，没有短名写全名。 */
export type SceneLayout = (line: TextLine, her: Character | null) => TextPage[];

/** 先载入像素字，再交出分页的函数。量字要用像素字：没载入就量，退回的字体宽度不一样，分页会错。 */
export async function loadSceneLayout(): Promise<SceneLayout> {
  await loadPixelFont().catch(() => {});
  return (line, her) => {
    const names = { her: her ? (her.short_name ?? her.name) : "", producer: copy.bar.producer };
    return paginate(line, { names, measure: measurePixelText });
  };
}
