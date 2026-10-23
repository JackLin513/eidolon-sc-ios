import { AchievementLine } from "@/components/app/AchievementLine";
import { copy } from "@/i18n";
import type { Achievement } from "@/lib/achievements";

const t = copy.achievements;

/**
 * 「成就」子页里那一小节「成就」（DESIGN.md「玩法页」）：描边圆角块，标题下面合起来的四个成就一行一个，写法同她的对话页的成就面板（`AchievementLine`）。新解锁的那几行（`unseen`，成就 id）名字旁一个点。
 */
export function AchievementsSection({
  achievements,
  unseen,
}: {
  achievements: Achievement[];
  unseen: ReadonlySet<string>;
}) {
  return (
    <section aria-label={t.title} className="flex flex-col gap-1 rounded-2xl border px-5 py-3">
      <p className="text-header">{t.title}</p>
      <ul>
        {achievements.map((achievement) => (
          <AchievementLine key={achievement.id} achievement={achievement} isUnseen={unseen.has(achievement.id)} />
        ))}
      </ul>
    </section>
  );
}
