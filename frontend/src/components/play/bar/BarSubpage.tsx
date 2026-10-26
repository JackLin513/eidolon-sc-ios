"use client";

import { notFound, useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";

import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { BarCounter, useBarCounter } from "@/components/play/bar/BarCounter";
import { BarDoor } from "@/components/play/bar/BarDoor";
import { BarEndCard } from "@/components/play/bar/BarEndCard";
import { BarGuest } from "@/components/play/bar/BarGuest";
import { BarJukeboxPlayer, BarJukeboxSetup } from "@/components/play/bar/BarJukebox";
import { BarRecipeBook } from "@/components/play/bar/BarRecipeBook";
import { BarRoom } from "@/components/play/bar/BarRoom";
import { BarScreen, SideMenu } from "@/components/play/bar/BarScreen";
import { BarTextBox } from "@/components/play/bar/BarTextBox";
import { BAR_INK } from "@/components/play/bar/ink";
import { PortraitGuard } from "@/components/play/bar/PortraitGuard";
import { useBarJukebox } from "@/components/play/bar/useBarJukebox";
import { useBarSound } from "@/components/play/bar/useBarSound";
import { useBarVisit } from "@/components/play/bar/useBarVisit";
import { useBar } from "@/components/play/useBar";
import { copy } from "@/i18n";
import { endCard, isArrowShown, isSpeaking, shownText, typingVoice } from "@/lib/barVisit";
import { getGiftState } from "@/lib/gifts";
import { playHref } from "@/lib/playRoute";

/** 句子打字时循环的打字音效。 */
const TYPING_SOUND = { her: "bleep_high", producer: "bleep_low" } as const;

/**
 * 酒吧（`/play/bar`，.scratch/bar-room spec「入口、路由和外壳」「一次营业的流程」）：在导航外壳里（通话不挂断，ADR-0018），
 * 画面盖住导航栏和 dock，正在通话时通话条照旧在最上面。先读 `GET /api/bar`：读到关着时当作没有这一页（not-found）；
 * 读到之前只有一层底色；读不到时照样画画面，「离开」能用。
 * 进来先到店门口，点一下进门，她进来和制作人说话，点单后备忘出来、调酒台打开（useBarVisit、lib/barVisit），
 * 照原版调好上酒（BarCounter、lib/barMixer），调酒时配方书盖住她（BarRecipeBook），她接着反应、点下一单。
 * 她告别、最后一页点过以后出结束卡（BarEndCard），「再营业」直接迎下一位；模型出错时文本框写出错的话和「再试一次」。
 * 得了抽奖时重读一次礼物状态告诉外壳，导航「玩法」上的点随之亮起（离开玩法页以后看得到）。
 * 「离开」离开这次光顾、回玩法页，浏览器返回也是（从玩法页的卡进来）。界面上哪里都不写她的口味、醉意和档位。
 * 声音（useBarSound）：`audioBase` 是存储桶里 `bar/` 的地址，部署没给就是 null，一声不出。进门响门声；
 * 句子打字时循环打字音效，她是 `bleep_high`，制作人是 `bleep_low`。
 * 点唱机（useBarJukebox）：manifest 读完以后先过选曲界面（BarJukeboxSetup，填好上次的），Ready! 到店门口；进门从第 1 首放起，
 * 一直放到离开。店里侧边菜单「点唱机」开关右上角的小播放器（BarJukeboxPlayer）。没有曲目时跳过选曲界面，「点唱机」是灰的。
 */
export function BarSubpage({ audioBase }: { audioBase: string | null }) {
  const router = useRouter();
  const { bar, failed } = useBar();
  const { account, characters, giftsRead } = useDirectory();
  const sound = useBarSound(audioBase);
  const jukebox = useBarJukebox({ userId: account?.id ?? null, audio: sound.audio, base: audioBase });
  const [isChoosing, setChoosing] = useState(true);
  const { start: startSound, play } = sound;
  const { start: startMusic } = jukebox;
  // 进门那一下：建 AudioContext，点唱机从第 1 首放起。
  const visitSound = useMemo(
    () => ({
      start: () => {
        startSound();
        startMusic();
      },
      play,
    }),
    [startSound, startMusic, play],
  );
  const onDraws = useCallback(() => {
    getGiftState().then(giftsRead, () => {});
  }, [giftsRead]);
  const { state, now, enter, again, tap, leave, mix, serve, retry } = useBarVisit({
    userId: account?.id ?? null,
    characters,
    sound: visitSound,
    onDraws,
  });
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
  // manifest 还在读、或者有曲目但还不知道是谁（记着的选择按用户分开）时，先盖一层黑的，不让店门口闪一下又换成选曲界面。
  const isReading = sound.audio === null || (jukebox.isAvailable && !jukebox.jukebox);
  const isInside = state.stage === "visit" || state.stage === "next";
  const her = characters?.find((c) => c.id === state.visit?.characterId) ?? null;
  const card = endCard(state);
  const leaveBar = () => {
    leave();
    router.push(playHref());
  };
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
      {isInside ? (
        <>
          <BarCounter mixer={state.mixer} isCounterOpen={isCounterOpen} counter={counter} />
          <BarTextBox
            text={shownText(state, now)}
            herColor={her?.color ?? BAR_INK.text}
            isArrowShown={isArrowShown(state, now)}
            isNextCursor={state.shown !== null && !state.isMixing}
            onTap={tap}
            failure={state.failure === null ? null : { message: state.failure, isRetrying: state.isRetrying, onRetry: () => void retry() }}
          />
        </>
      ) : (
        <BarDoor notice={state.notice} isEntering={state.stage === "entering"} onEnter={() => void enter()} />
      )}
      <SideMenu
        memo={state.memo}
        jukebox={
          isInside
            ? {
                state: !jukebox.isAvailable ? "none" : jukebox.isOpen ? "open" : "closed",
                onToggle: () => {
                  play(jukebox.isOpen ? "buttonnoclick" : "mixdone");
                  jukebox.toggleOpen();
                },
              }
            : null
        }
        leave={copy.bar.leave}
        onLeave={leaveBar}
      />
      {isInside && jukebox.isOpen && <BarJukeboxPlayer jukebox={jukebox} sound={sound} />}
      {card && (
        <BarEndCard
          {...card}
          herName={her && (her.short_name ?? her.name)}
          herColor={her?.color ?? BAR_INK.text}
          onAgain={() => void again()}
          onLeave={leaveBar}
        />
      )}
      {isReading ? (
        <div className="absolute inset-0" style={{ background: BAR_INK.black }} />
      ) : (
        isChoosing &&
        jukebox.isAvailable &&
        jukebox.jukebox && (
          <BarJukeboxSetup
            tracks={sound.audio?.tracks ?? []}
            slots={jukebox.jukebox.slots}
            jukebox={jukebox}
            sound={sound}
            onReady={(slots) => {
              jukebox.choose(slots);
              setChoosing(false);
            }}
          />
        )
      )}
    </BarScreen>
  );
}
