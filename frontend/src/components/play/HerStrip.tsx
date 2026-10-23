import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { Button } from "@/components/ui/button";
import type { Character } from "@/lib/api";
import { CloseIcon } from "@/theme/icons";

/**
 * 玩法子页页首下面那一条，带着她跳来时出现：她的 24px 头像、一句话和右端的 ✕。礼物子页的预选（「给〇〇挑一件礼物」）
 * 和日历子页的「只看〇〇的日程」都是它（DESIGN.md「玩法页」）。
 */
export function HerStrip({
  character,
  text,
  closeLabel,
  onClose,
}: {
  character: Character;
  text: string;
  /** ✕ 的读屏名字。 */
  closeLabel: string;
  onClose: () => void;
}) {
  return (
    <div className="flex items-center gap-2 rounded-2xl border py-1 pr-1 pl-3">
      <MarkedAvatar name={character.name} src={character.avatar_url} size="sm" />
      <p className="min-w-0 flex-1 truncate text-sm">{text}</p>
      {/* 手机上触控目标不小于 44px */}
      <Button variant="ghost" size="icon-lg" className="max-md:size-11" aria-label={closeLabel} onClick={onClose}>
        <CloseIcon />
      </Button>
    </div>
  );
}
