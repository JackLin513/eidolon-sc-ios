import { GiftsSubpage } from "@/components/play/GiftsSubpage";
import { TasksSubpage } from "@/components/play/TasksSubpage";
import { giftsFor } from "@/lib/gifts";
import { PLAY_SUBPAGES, type PlaySubpage } from "@/lib/playRoute";

// 只有这几个子页；不认识的 `/play/<xxx>` 在 proxy 里就换成了 `/play`，到不了这里。
export const dynamicParams = false;

export function generateStaticParams() {
  return PLAY_SUBPAGES.map((subpage) => ({ subpage }));
}

/**
 * 玩法的子页（`/play/<子页>`）：礼物在 `/play/gifts`，从对话页跳来时地址里带着预选的她；
 * 每日任务与成就在 `/play/tasks`。页首返回键回玩法页（DESIGN.md「玩法页」）。
 */
export default async function PlaySubpageRoute({
  params,
  searchParams,
}: {
  params: Promise<{ subpage: string }>;
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>;
}) {
  const { subpage } = (await params) as { subpage: PlaySubpage };
  if (subpage === "tasks") return <TasksSubpage />;
  return <GiftsSubpage pick={giftsFor(await searchParams)} />;
}
