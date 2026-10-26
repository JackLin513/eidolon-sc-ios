"use client";

import { notFound, useRouter } from "next/navigation";

import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { BarDoor } from "@/components/play/bar/BarDoor";
import { BarGuest } from "@/components/play/bar/BarGuest";
import { BarRoom } from "@/components/play/bar/BarRoom";
import { BarScreen, SideMenu } from "@/components/play/bar/BarScreen";
import { BarTextBox } from "@/components/play/bar/BarTextBox";
import { BAR_INK } from "@/components/play/bar/ink";
import { PortraitGuard } from "@/components/play/bar/PortraitGuard";
import { useBarVisit } from "@/components/play/bar/useBarVisit";
import { useBar } from "@/components/play/useBar";
import { copy } from "@/i18n";
import { isArrowShown, isSpeaking, shownText } from "@/lib/barVisit";
import { playHref } from "@/lib/playRoute";

/**
 * 酒吧（`/play/bar`，.scratch/bar-room spec「入口、路由和外壳」「一次营业的流程」）：在导航外壳里（通话不挂断，ADR-0018），
 * 画面盖住导航栏和 dock，正在通话时通话条照旧在最上面。先读 `GET /api/bar`：读到关着时当作没有这一页（not-found）；
 * 读到之前只有一层底色；读不到时照样画画面，「离开」能用。
 * 进来先到店门口，点一下进门，她进来和制作人说话，点单后备忘出来（useBarVisit、lib/barVisit）。
 * 「离开」离开这次光顾、回玩法页，浏览器返回也是（从玩法页的卡进来）。界面上哪里都不写她的口味、醉意和档位。
 */
export function BarSubpage() {
  const router = useRouter();
  const { bar, failed } = useBar();
  const { account, characters } = useDirectory();
  const { state, now, enter, tap, leave } = useBarVisit({ userId: account?.id ?? null, characters });

  if (bar && !bar.enabled) notFound();
  if (!bar && !failed) return <div className="bar-layer absolute inset-0" style={{ background: BAR_INK.ground }} />;
  const her = characters?.find((c) => c.id === state.visit?.characterId) ?? null;
  return (
    <BarScreen
      room={<BarRoom />}
      guest={her && <BarGuest key={state.visit?.id} character={her} mood={state.mood} speaking={isSpeaking(state, now)} />}
      portrait={<PortraitGuard />}
    >
      {state.stage === "visit" ? (
        <BarTextBox
          text={shownText(state, now)}
          herColor={her?.color ?? BAR_INK.text}
          isArrowShown={isArrowShown(state, now)}
          onTap={tap}
        />
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
