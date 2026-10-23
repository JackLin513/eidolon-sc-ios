"use client";

import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";

import { FailureNotice } from "@/components/app/FailureNotice";
import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { SectionHeading } from "@/components/app/SubpageHeader";
import { useDirectory, useWide } from "@/components/conversations/ConversationDirectory";
import { useProducerTimezone } from "@/components/conversations/useProducerTimezone";
import { DrawDialog, type Drawing } from "@/components/gifts/DrawDialog";
import { GivenToast, type GivenNotice } from "@/components/gifts/GivenToast";
import { GivePanel, type Giving } from "@/components/gifts/GivePanel";
import { MY_GIFTS_ID, MyGifts } from "@/components/gifts/MyGifts";
import { ResetCards } from "@/components/gifts/ResetCards";
import { PlayClosed, PlayShell, PlaySubpageHeader } from "@/components/play/PlayShell";
import { usePlayState } from "@/components/play/usePlayState";
import { Button } from "@/components/ui/button";
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty";
import { useMediaQuery } from "@/hooks/useMediaQuery";
import { copy } from "@/i18n";
import { ApiError, type Character } from "@/lib/api";
import { arrange } from "@/lib/conversationList";
import { toFailure } from "@/lib/failure";
import {
  chosenFirst,
  drawDots,
  drawGifts,
  drawNote,
  emptyNote,
  nextDrawText,
  getGiftState,
  giveGift,
  givenNote,
  spendResetCard,
  type DrawResult,
  type GiftInfo,
  type GiftsFor,
  type GiftState,
  type Given,
} from "@/lib/gifts";
import { playTitle } from "@/lib/playCards";
import { playHref } from "@/lib/playRoute";
import { later } from "@/lib/seenOnDevice";
import { cn } from "@/lib/utils";
import { CloseIcon, DrawIcon, GiftIcon } from "@/theme/icons";

const t = copy.gifts;

/** 礼物盒揭晓前跳多久，和 `animate-hop` 一样长。 */
const OPENING_MS = 900;

/** 送出后的提示留多久。 */
const NOTICE_MS = 8000;

/**
 * 礼物子页（`/play/gifts`，DESIGN.md「玩法页」）：玩法页「礼物」卡点进来的二级页面，页首返回键回玩法页，内容最宽 `max-w-3xl`、居中。
 * 上面是抽奖台，有重置卡时下面一条重置卡条，最后「我的礼物」；点一件（或单抽结果上的「送给谁…」）拉出送礼面板，
 * 送出后面板收起、底部出提示，页面不跳走。好感度和礼物没开放时页首下面是「玩法暂时没有开放」，「玩法」照样留在导航里；
 * 抽奖、送礼或用重置卡时才知道没开放（收到「没开放」的 409）也切成这样。
 * 从对话页跳来（`pick`）时页首下面一条「给{角色名}挑一件礼物」：点哪件礼物，面板里都已选好她、排在第一个，
 * 送出的礼物和别处送的一样记进她的当前对话；点 ✕ 取消预选，地址里的也去掉。地址里的角色不存在时当作没有预选。
 * 地址带着 `#my-gifts`（每日任务里的「挑一件」）时，礼物读到以后滚到「我的礼物」。
 * 进了这个子页（且没被通话层盖住）就把新到的抽奖次数记成看过，在这个子页上到账的当场也记成看过，所以导航和「礼物」卡上都不出点。
 */
export function GiftsSubpage({ pick }: { pick: GiftsFor | null }) {
  const { state, setState, catalog, failure, setFailure, applyGiftState } = usePlayState({ withCatalog: true });
  const [drawing, setDrawing] = useState<Drawing | null>(null);
  // 收起面板时留着上一次送的，收起的动画里内容不消失。
  const [giving, setGiving] = useState<Giving | null>(null);
  const [isGiveOpen, setGiveOpen] = useState(false);
  const [isSending, setSending] = useState(false);
  const [notice, setNotice] = useState<GivenNotice | null>(null);
  const isReducedMotion = useMediaQuery("(prefers-reduced-motion: reduce)", false);
  const isWide = useWide();
  const timeZone = useProducerTimezone();
  const { characters, latest, preferences, go, refresh, giftsRead } = useDirectory();
  const router = useRouter();
  // 点过 ✕ 的预选：地址换掉以前（重新渲染要等一下）就不再显示。地址换回 /play/gifts 以后忘掉，
  // 这一页没卸下又从结束卡带着她跳来时（通话层由外壳画在礼物子页上）照样预选。
  const [dropped, setDropped] = useState<string | null>(null);
  if (!pick && dropped !== null) setDropped(null);
  const chosen = pick && pick.to !== dropped ? characters?.find((c) => c.id === pick.to) : undefined;
  const giftsById = useMemo(() => new Map((catalog ?? []).map((g) => [g.id, g])), [catalog]);
  // 所有角色（隐藏了的也在），顺序和对话列表一样：重置卡确认框照这个顺序列，送给谁时预选的她排第一。
  const arranged = useMemo(() => {
    const all = characters ?? [];
    return arrange(all, latest, { preferences, keep: all.map((c) => c.id) }).rows.map((row) => row.character);
  }, [characters, latest, preferences]);
  const recipients = useMemo(() => chosenFirst(arranged, chosen?.id ?? null), [arranged, chosen]);
  const statuses = useMemo(() => new Map((state?.characters ?? []).map((c) => [c.id, c])), [state]);

  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(null), NOTICE_MS);
    return () => clearTimeout(timer);
  }, [notice]);

  // 每日任务里的「挑一件」带着 #my-gifts 跳来：「我的礼物」一出来就滚过去，只滚一次。
  const [hasScrolled, setScrolled] = useState(false);
  useEffect(() => {
    if (hasScrolled || !state?.open || catalog === null || window.location.hash !== `#${MY_GIFTS_ID}`) return;
    setScrolled(true);
    document
      .getElementById(MY_GIFTS_ID)
      ?.scrollIntoView({ behavior: isReducedMotion ? "auto" : "smooth", block: "start" });
  }, [hasScrolled, state, catalog, isReducedMotion]);

  async function draw(all: boolean) {
    setFailure(null);
    setDrawing({ all, result: null });
    try {
      const [result] = await Promise.all([
        drawGifts(all),
        new Promise((resolve) => setTimeout(resolve, isReducedMotion ? 0 : OPENING_MS)),
      ]);
      setDrawing({ all, result });
      // 先按抽到的把背包补上，「送给谁…」马上打开时件数就是对的；随后再整个读一遍。
      setState((s) => s && withDrawn(s, result, catalog ?? []));
      getGiftState().then(applyGiftState, (e) => setFailure(toFailure(e)));
    } catch (e) {
      setDrawing(null);
      failed(e);
    }
  }

  /** 收到「没开放」的 409 时整页切成未开放，别的失败在页上方说。 */
  function failed(e: unknown) {
    if (e instanceof ApiError && e.giftsClosed) {
      setState((s) => s && { ...s, open: false });
      giftsRead({ open: false, rewarded_at: null });
    }
    else setFailure(toFailure(e));
  }

  /** 拉出这件的送礼面板；还有几件按背包里的算。 */
  function startGiving(gift: GiftInfo) {
    const left = state?.backpack.find((b) => b.gift_id === gift.id)?.count ?? 0;
    setDrawing(null);
    setGiving({ gift, left, to: chosen?.id ?? null });
    setGiveOpen(true);
  }

  async function send() {
    const to = recipients.find((c) => c.id === giving?.to);
    if (!giving || !to) return;
    setFailure(null);
    setSending(true);
    try {
      const given = await giveGift(to.id, giving.gift.id);
      setGiveOpen(false);
      setState((s) => s && afterGiving(s, giving.gift.id, to.id, given));
      // 做完了任务的到账就在这一页上：重读回来记成看过，不出点。
      setNotice({
        key: Date.now(),
        character: to,
        note: givenNote(given, to.name, new Date(), timeZone),
      });
      refresh();
      getGiftState().then(applyGiftState, () => {});
    } catch (e) {
      setGiveOpen(false);
      failed(e);
      // 另一个标签页可能刚送掉了最后一件：重新读一遍背包。
      getGiftState().then(applyGiftState, () => {});
    } finally {
      setSending(false);
    }
  }

  /** 用一张重置卡；拉回了谁、还剩几张都从重新读的状态里来，抽奖台、重置卡条和送礼面板里的档位一起刷新。 */
  async function spendCard() {
    setFailure(null);
    try {
      await spendResetCard();
    } catch (e) {
      // 没开放切成未开放；没有卡了、确认框打开期间她们自己回到了信任，在页上方说，卡没有扣。
      failed(e);
    }
    getGiftState().then(applyGiftState, (e) => setFailure(toFailure(e)));
  }

  // 没开放时没有下次，抽奖台和「还没有礼物」也不显示。
  const nextDraw = state?.next_draw_at ? nextDrawText(state.next_draw_at, new Date(), timeZone) : "";

  return (
    <PlayShell
      header={<PlaySubpageHeader title={playTitle("gifts")} />}
      overlays={
        <>
          <DrawDialog
            drawing={drawing}
            catalog={giftsById}
            onGive={startGiving}
            onAgain={() => draw(false)}
            onClose={() => setDrawing(null)}
          />
          <GivePanel
            giving={giving}
            isOpen={isGiveOpen}
            isWide={isWide}
            isSending={isSending}
            characters={recipients}
            statuses={statuses}
            onChoose={(to) => setGiving((g) => g && { ...g, to })}
            onSend={send}
            onClose={() => setGiveOpen(false)}
          />
          {/* 「去对话」去她的对话页，那里打开的就是记录放进的那段；通话中去别的角色时先问会不会挂断。 */}
          <GivenToast notice={notice} onGo={(n) => go(`/conversation/${encodeURIComponent(n.character.id)}`)} />
        </>
      }
    >
      {failure && <FailureNotice failure={failure} />}
      {state === null || catalog === null ? (
        !failure && <p className="text-body text-muted-foreground">{copy.play.loading}</p>
      ) : !state.open ? (
        <PlayClosed />
      ) : (
        <>
          {chosen && (
            <PickedFor
              character={chosen}
              onCancel={() => {
                setDropped(chosen.id);
                router.replace(playHref("gifts"), { scroll: false });
              }}
            />
          )}
          <DrawDesk
            draws={state.draws}
            max={state.max_draws}
            next={nextDraw}
            isDrawing={drawing !== null}
            onDraw={draw}
          />
          {state.reset_cards > 0 && (
            <ResetCards
              count={state.reset_cards}
              resettable={state.resettable}
              characters={arranged}
              onUse={spendCard}
            />
          )}
          {state.backpack.length > 0 ? (
            <MyGifts backpack={state.backpack} catalog={catalog} onGive={(held) => startGiving(held.gift)} />
          ) : (
            <>
              <SectionHeading>{t.mine}</SectionHeading>
              <GiftsEmpty title={t.empty.title} description={emptyNote(state.draws, nextDraw)} />
            </>
          )}
        </>
      )}
    </PlayShell>
  );
}

/** 抽完以后的礼物状态：剩下的次数，抽到的礼物叠进背包（按目录的顺序），重置卡另计。 */
function withDrawn(state: GiftState, result: DrawResult, catalog: GiftInfo[]): GiftState {
  const counts = new Map(state.backpack.map((b) => [b.gift_id, b.count]));
  let cards = state.reset_cards;
  for (const d of result.drawn) {
    if (d.kind === "gift") counts.set(d.gift_id, (counts.get(d.gift_id) ?? 0) + 1);
    else cards += 1;
  }
  const backpack = catalog.flatMap((g) => {
    const count = counts.get(g.id);
    return count ? [{ gift_id: g.id, count }] : [];
  });
  return {
    ...state,
    draws: result.draws,
    backpack,
    reset_cards: cards,
  };
}

/** 送出一件以后的礼物状态：这件按接口给的件数（送完的不再列），她的好感度换成现在的，这次到账的次数加上。 */
function afterGiving(state: GiftState, giftId: string, characterId: string, given: Given): GiftState {
  const { rewarded } = given;
  return {
    ...state,
    draws: state.draws + (rewarded?.draws ?? 0),
    rewarded_at: later(state.rewarded_at, rewarded?.rewarded_at ?? null),
    backpack: state.backpack
      .map((b) => (b.gift_id === giftId ? { ...b, count: given.left } : b))
      .filter((b) => b.count > 0),
    characters: state.characters.map((c) => (c.id === characterId ? { id: c.id, ...given.affinity } : c)),
  };
}

/** 从对话页跳来时页首下面那一条：她的小头像、「给{角色名}挑一件礼物」和取消预选的 ✕。 */
function PickedFor({ character, onCancel }: { character: Character; onCancel: () => void }) {
  return (
    <div className="flex items-center gap-2 rounded-2xl border py-1 pr-1 pl-3">
      <MarkedAvatar name={character.name} src={character.avatar_url} size="sm" />
      <p className="min-w-0 flex-1 truncate text-sm">{t.pickFor(character.name)}</p>
      {/* 手机上触控目标不小于 44px */}
      <Button
        variant="ghost"
        size="icon-lg"
        className="max-md:size-11"
        aria-label={t.cancelPick(character.name)}
        onClick={onCancel}
      >
        <CloseIcon />
      </Button>
    </div>
  );
}

/**
 * 抽奖台：`bg-muted` 圆角块，「抽奖 还有 n 次」、7 个小点（攒了几次亮几个，每日任务给的超过 7 次时全亮、后面写「+n」）和一句说明；右边「抽一次」，
 * 攒了 2 次以上时旁边多一个「全部抽完」，次数为 0 时「抽一次」不可用。
 */
function DrawDesk({
  draws,
  max,
  next,
  isDrawing,
  onDraw,
}: {
  draws: number;
  max: number;
  /** 下次到账的「今天 / 明天 HH:MM」。 */
  next: string;
  isDrawing: boolean;
  onDraw: (all: boolean) => void;
}) {
  const dots = drawDots(draws, max);
  return (
    <section aria-label={t.draw.title} className="flex flex-wrap items-center gap-4 rounded-2xl bg-muted p-5">
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <p className="flex items-baseline gap-2">
          <span className="text-header">{t.draw.title}</span>
          <span className="text-sm text-muted-foreground tabular-nums">{t.draw.left(draws)}</span>
        </p>
        <span role="img" aria-label={dots.label} className="flex items-center gap-1">
          {Array.from({ length: max }, (_, i) => (
            <span key={i} className={cn("size-2 rounded-full", i < dots.lit ? "bg-foreground" : "bg-foreground/15")} />
          ))}
          {dots.more && (
            <span className="ml-0.5 text-meta leading-none text-muted-foreground tabular-nums">{dots.more}</span>
          )}
        </span>
        <p className="text-subtitle text-muted-foreground">{drawNote(draws, max, next)}</p>
      </div>
      <div className="flex gap-2">
        {draws >= 2 && (
          <Button variant="outline" disabled={isDrawing} onClick={() => onDraw(true)}>
            {t.draw.all}
          </Button>
        )}
        <Button disabled={draws === 0 || isDrawing} onClick={() => onDraw(false)}>
          <DrawIcon data-icon="inline-start" />
          {t.draw.once}
        </Button>
      </div>
    </section>
  );
}

/** 礼物图标加一句标题和说明的 `Empty`：「还没有礼物」，以及没开放时的整页。 */
function GiftsEmpty({ title, description }: { title: string; description: string }) {
  return (
    <Empty>
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <GiftIcon />
        </EmptyMedia>
        <EmptyTitle>{title}</EmptyTitle>
        <EmptyDescription>{description}</EmptyDescription>
      </EmptyHeader>
    </Empty>
  );
}
