"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

import { FailureNotice } from "@/components/app/FailureNotice";
import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { PageShell } from "@/components/app/PageShell";
import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { copy } from "@/i18n";
import { ApiError, getMoments, type Character, type Moment } from "@/lib/api";
import { toFailure, type Failure } from "@/lib/failure";
import { postedText } from "@/lib/moments";
import { Ja } from "@/theme/Ja";

const t = copy.moments;

const CONFLICT = 409;

/**
 * 朋友圈页（`/moments`，DESIGN.md「朋友圈页」）：页首「朋友圈」大标题，下面一栏时间线（最宽 `max-w-3xl`、居中，同玩法页），
 * 最新的在上面，一条一行，行与行之间一条细线。打开时读一次，不轮询。
 * 读到之前空着；没有动态时一行 muted 的「还没有动态」。朋友圈关着（409）时换成对话列表，不留这一页在历史里。
 * 她的名字和头像从对话目录的角色里按 id 取，取不到（角色已经下架）时名字写 id、头像是名字的头一个字。
 */
export function MomentsPage() {
  const router = useRouter();
  const { characters } = useDirectory();
  const [timeline, setTimeline] = useState<{ moments: Moment[]; readAt: Date } | null>(null);
  const [failure, setFailure] = useState<Failure | null>(null);

  useEffect(() => {
    let live = true;
    getMoments().then(
      (moments) => live && setTimeline({ moments, readAt: new Date() }),
      (e) => {
        if (!live) return;
        if (e instanceof ApiError && e.status === CONFLICT) router.replace("/conversations");
        else setFailure(toFailure(e));
      },
    );
    return () => {
      live = false;
    };
  }, [router]);

  const byId = new Map((characters ?? []).map((character) => [character.id, character]));
  return (
    <PageShell width="full" isInShell header={<h1 className="text-list-title">{t.title}</h1>}>
      <div className="mx-auto flex w-full max-w-3xl flex-1 flex-col px-4 py-2">
        {failure && (
          <div className="py-4">
            <FailureNotice failure={failure} />
          </div>
        )}
        {timeline &&
          (timeline.moments.length === 0 ? (
            <p className="py-4 text-body text-muted-foreground">{t.empty}</p>
          ) : (
            <div className="flex flex-col divide-y">
              {timeline.moments.map((moment) => (
                <MomentRow
                  key={moment.id}
                  moment={moment}
                  character={byId.get(moment.character_id)}
                  now={timeline.readAt}
                />
              ))}
            </div>
          ))}
      </div>
    </PageShell>
  );
}

/** 时间线的一行：左边她的头像；右边名字、日语正文、一行字幕（同对话气泡）、Meta 字号的时间。 */
function MomentRow({ moment, character, now }: { moment: Moment; character: Character | undefined; now: Date }) {
  const name = character?.name ?? moment.character_id;
  return (
    <article className="flex gap-3 py-4">
      <MarkedAvatar name={name} src={character?.avatar_url} size="lg" />
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <span className="text-row-name">{name}</span>
        <div className="flex flex-col gap-0.5">
          <p className="text-body whitespace-pre-wrap">
            <Ja>{moment.ja}</Ja>
          </p>
          {moment.zh && <p className="text-subtitle text-muted-foreground">{moment.zh}</p>}
        </div>
        <time dateTime={moment.posted_at} className="text-meta text-muted-foreground">
          {postedText(moment.posted_at, now)}
        </time>
      </div>
    </article>
  );
}
