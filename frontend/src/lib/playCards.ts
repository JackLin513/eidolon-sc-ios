// The cards of the play page's first level (.scratch/play-hub spec「卡片注册表」): for each card, its
// name, where it goes (its subpage), when it is shown, what its status line says and whether a dot
// sits by its name. A card is one entry of `CARDS`; the page lays them out (the first across a
// whole row, the rest in a grid) and only asks what is on them. The data all comes from the gift
// state, which the first level and the subpages read alike.

import { copy } from "@/i18n";
import { unseenStages } from "@/lib/achievements";
import type { GiftState } from "@/lib/gifts";
import { playHref, type PlaySubpage } from "@/lib/playRoute";

const t = copy.play;

/** What the cards are made of: the gift state (null until it has been read), whether draw chances
 * have come that are not yet seen (`newRewards`, the nav's dot), and the latest unlock of the
 * combined achievements seen on this device (`achievementsSeenAt`). */
export type PlayContext = { state: GiftState | null; newRewards: boolean; achievementsSeenAt: string | null };

/** A card as the page shows it: `status` is empty until the state has been read. */
export type PlayCard = {
  id: PlaySubpage;
  name: string;
  href: string;
  status: string;
  hasDot: boolean;
  /** What a screen reader says of the dot. */
  dotLabel: string;
};

type Definition = {
  id: PlaySubpage;
  name: string;
  isShown: (context: PlayContext) => boolean;
  status: (state: GiftState, context: PlayContext) => string;
  hasDot: (context: PlayContext) => boolean;
  dotLabel: string;
};

/** Gifts and the daily tasks and achievements are there while affinity and gifts are open; until
 * the state has been read nothing says they are not. */
const isGiftsOpen = ({ state }: PlayContext) => state === null || state.open;

function join(parts: (string | null)[]): string {
  return parts.filter((part) => part !== null).join(t.separator);
}

const CARDS: Definition[] = [
  {
    id: "gifts",
    name: t.cards.gifts.name,
    isShown: isGiftsOpen,
    status: (state) => {
      const items = state.backpack.reduce((n, held) => n + held.count, 0);
      return join([
        t.cards.gifts.draws(state.draws),
        items > 0 ? t.cards.gifts.backpack(items) : null,
        state.reset_cards > 0 ? t.cards.gifts.resetCards(state.reset_cards) : null,
      ]);
    },
    hasDot: ({ newRewards }) => newRewards,
    dotLabel: t.cards.gifts.dot,
  },
  {
    id: "tasks",
    name: t.cards.tasks.name,
    isShown: isGiftsOpen,
    status: (state, context) => {
      const tasks = state.daily_tasks?.tasks ?? [];
      const done = tasks.filter((task) => task.done).length;
      const unlocked = unlockedCount(state, context);
      return join([
        tasks.length === 0
          ? null
          : done === tasks.length
            ? t.cards.tasks.allDone
            : t.cards.tasks.daily(done, tasks.length),
        unlocked > 0 ? t.cards.tasks.unlocked(unlocked) : null,
      ]);
    },
    hasDot: (context) => context.state !== null && unlockedCount(context.state, context) > 0,
    dotLabel: t.cards.tasks.dot,
  },
];

/** How many stages of the combined achievements were unlocked since the last seen on this device. */
function unlockedCount(state: GiftState, { achievementsSeenAt }: PlayContext): number {
  return state.achievements ? unseenStages(state.achievements, achievementsSeenAt) : 0;
}

/** The cards to show, top to bottom: none where affinity and gifts are closed. */
export function playCards(context: PlayContext): PlayCard[] {
  const { state } = context;
  return CARDS.filter((card) => card.isShown(context)).map((card) => ({
    id: card.id,
    name: card.name,
    href: playHref(card.id),
    status: state ? card.status(state, context) : "",
    hasDot: card.hasDot(context),
    dotLabel: card.dotLabel,
  }));
}

/** A card's name, which is also the title of its subpage. */
export function playTitle(id: PlaySubpage): string {
  return CARDS.find((card) => card.id === id)?.name ?? id;
}
