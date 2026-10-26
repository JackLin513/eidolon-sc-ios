"use client";

import { notFound, useRouter } from "next/navigation";
import { useEffect } from "react";

import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { BarCounter, useBarCounter } from "@/components/play/bar/BarCounter";
import { BarDoor } from "@/components/play/bar/BarDoor";
import { BarGuest } from "@/components/play/bar/BarGuest";
import { BarRecipeBook } from "@/components/play/bar/BarRecipeBook";
import { BarRoom } from "@/components/play/bar/BarRoom";
import { BarScreen, SideMenu } from "@/components/play/bar/BarScreen";
import { BarTextBox } from "@/components/play/bar/BarTextBox";
import { BAR_INK } from "@/components/play/bar/ink";
import { PortraitGuard } from "@/components/play/bar/PortraitGuard";
import { useBarSound } from "@/components/play/bar/useBarSound";
import { useBarVisit } from "@/components/play/bar/useBarVisit";
import { useBar } from "@/components/play/useBar";
import { copy } from "@/i18n";
import { isArrowShown, isSpeaking, shownText, typingVoice } from "@/lib/barVisit";
import { playHref } from "@/lib/playRoute";

/** 句子打字时循环的打字音效。 */
const TYPING_SOUND = { her: "bleep_high", producer: "bleep_low" } as const;

/**
 * 酒吧（`/play/bar`，.scratch/bar-room spec「入口、路由和外壳」「一次营业的流程」）：在导航外壳里（通话不挂断，ADR-0018），
 * 画面盖住导航栏和 dock，正在通话时通话条照旧在最上面。先读 `GET /api/bar`：读到关着时当作没有这一页（not-found）；
 * 读到之前只有一层底色；读不到时照样画画面，「离开」能用。
 * 进来先到店门口，点一下进门，她进来和制作人说话，点单后备忘出来、调酒台打开（useBarVisit、lib/barVisit），
 * 照原版调好上酒（BarCounter、lib/barMixer），调酒时配方书盖住她（BarRecipeBook），她接着反应、点下一单。
 * 「离开」离开这次光顾、回玩法页，浏览器返回也是（从玩法页的卡进来）。界面上哪里都不写她的口味、醉意和档位。
 * 声音（useBarSound）：`audioBase` 是存储桶里 `bar/` 的地址，部署没给就是 null，一声不出。进门响门声、放曲目，一直放到离开；
 * 句子打字时循环打字音效，她是 `bleep_high`，制作人是 `bleep_low`。
 */
export function BarSubpage({ audioBase }: { audioBase: string | null }) {
  const router = useRouter();
  const { bar, failed } = useBar();
  const { account, characters } = useDirectory();
  const sound = useBarSound(audioBase);
  const { state, now, enter, tap, leave, mix, serve } = useBarVisit({ userId: account?.id ?? null, characters, sound });
  const isCounterOpen = state.isMixing && !state.isServing;
  const drinks = bar?.enabled ? bar.drinks : [];
  const counter = useBarCounter({
    mixer: state.mixer,
    isCounterOpen,
    drinks,
    sound,
    onMix: mix,
    serve: () => void serve(),
  });

  const voice = typingVoice(state, now);
  const { loop } = sound;
  useEffect(() => {
    loop(voice && TYPING_SOUND[voice]);
  }, [voice, loop]);

  if (bar && !bar.enabled) notFound();
  if (!bar && !failed) return <div className="bar-layer absolute inset-0" style={{ background: BAR_INK.ground }} />;
  const her = characters?.find((c) => c.id === state.visit?.characterId) ?? null;
  return (
    <BarScreen
      room={<BarRoom />}
      guest={her && <BarGuest key={state.visit?.id} character={her} mood={state.mood} speaking={isSpeaking(state, now)} />}
      book={
        state.stage === "visit" &&
        state.isMixing && <BarRecipeBook drinks={drinks} isCounterOpen={isCounterOpen} counter={counter} sound={sound} />
      }
      portrait={<PortraitGuard />}
    >
      {state.stage === "visit" ? (
        <>
          <BarCounter mixer={state.mixer} isCounterOpen={isCounterOpen} counter={counter} />
          <BarTextBox
            text={shownText(state, now)}
            herColor={her?.color ?? BAR_INK.text}
            isArrowShown={isArrowShown(state, now)}
            isNextCursor={state.shown !== null && !state.isMixing}
            onTap={tap}
          />
        </>
      ) : (
        <BarDoor notice={state.notice} isEntering={state.stage === "entering"} onEnter={() => void enter()} />
      )}
      <SideMenu
        memo={state.memo}
        leave={copy.bar.leave}
        onLeave={() => {
          leave();
          router.push(playHref());
        }}
      />
    </BarScreen>
  );
}
