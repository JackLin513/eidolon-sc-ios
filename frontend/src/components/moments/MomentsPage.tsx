"use client";

import { useRouter } from "next/navigation";
import { Fragment, useEffect, useState } from "react";

import { FailureNotice } from "@/components/app/FailureNotice";
import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { PageShell } from "@/components/app/PageShell";
import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { copy } from "@/i18n";
import { ApiError, getMoments, type Character, type Moment } from "@/lib/api";
import { toFailure, type Failure } from "@/lib/failure";
import { metaParts, reactions, type Reactions } from "@/lib/moments";
import { LikesIcon } from "@/theme/icons";
import { Ja } from "@/theme/Ja";

const t = copy.moments;

const CONFLICT = 409;

/**
 * 朋友圈页（`/moments`，DESIGN.md「朋友圈页」）：页首「朋友圈」大标题，下面一栏时间线（最宽 `max-w-3xl`、居中，同玩法页），
 * 最新的在上面，一条一行，行与行之间一条细线。打开时读一次，不轮询。
 * 时间线和对话目录的角色都读到之前空着（免得名字先显示成 id，目录读不到时照样显示）；没有动态时一行 muted 的「还没有动态」。朋友圈关着（409）时换成对话列表，不留这一页在历史里。
 * 她的名字和头像从对话目录的角色里按 id 取，取不到（角色已经下架）时名字写 id、头像是名字的头一个字。
 */
export function MomentsPage() {
  const router = useRouter();
  const { characters, failure: directoryFailure } = useDirectory();
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
        {timeline && (characters || directoryFailure) &&
          (timeline.moments.length === 0 ? (
            <p className="py-4 text-body text-muted-foreground">{t.empty}</p>
          ) : (
            <div className="flex flex-col divide-y">
              {timeline.moments.map((moment) => (
                <MomentRow
                  key={moment.id}
                  moment={moment}
                  character={byId.get(moment.character_id)}
                  nameOf={(id) => byId.get(id)?.name ?? id}
                  now={timeline.readAt}
                />
              ))}
            </div>
          ))}
      </div>
    </PageShell>
  );
}

/** 时间线的一行：左边她的头像；右边名字、日语正文、一行字幕（同对话气泡）、Meta 字号的「时间 · 地名 · 天气」，
 * 有赞或评论时再下面一块。地名点开在新标签页打开地图，不把本站地址带过去。别的偶像的名字从 `nameOf` 取。 */
function MomentRow({
  moment,
  character,
  nameOf,
  now,
}: {
  moment: Moment;
  character: Character | undefined;
  nameOf: (characterId: string) => string;
  now: Date;
}) {
  const name = character?.name ?? moment.character_id;
  const block = reactions(moment, nameOf);
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
        <p className="text-meta text-muted-foreground">
          {metaParts(moment, now).map((part, i) => (
            <Fragment key={i}>
              {i > 0 && " · "}
              {part.kind === "weather" ? (
                <span className="whitespace-nowrap">
                  <part.icon role="img" aria-label={part.label} className="mr-1 inline size-3.5 align-middle" />
                  {part.text}
                </span>
              ) : part.kind === "place" ? (
                <a
                  href={part.href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="rounded-sm underline-offset-2 outline-none hover:text-foreground hover:underline focus-visible:ring-3 focus-visible:ring-ring/50"
                >
                  {part.text}
                </a>
              ) : (
                <time dateTime={moment.posted_at}>{part.text}</time>
              )}
            </Fragment>
          ))}
        </p>
        {block && <ReactionsBlock reactions={block} />}
      </div>
    </article>
  );
}

/** 一条动态下面 `bg-muted` 圆角的一块：心形加赞的人；细线下面是评论，「名字：日语」下面一行字幕。 */
function ReactionsBlock({ reactions: { likers, comments } }: { reactions: Reactions }) {
  return (
    <div className="mt-1 flex flex-col gap-1 rounded-lg bg-muted px-3 py-2 text-sm">
      {likers && (
        <p className="flex gap-1.5">
          <LikesIcon role="img" aria-label={t.likedBy} className="mt-1 size-3.5 shrink-0" />
          <span className="font-medium">{likers}</span>
        </p>
      )}
      {likers && comments.length > 0 && <div className="h-px bg-foreground/10" />}
      {comments.map((comment, i) => (
        <div key={i} className="flex flex-col gap-0.5">
          <p>
            <span className="font-medium">{comment.by}</span>
            <Ja>{comment.ja}</Ja>
          </p>
          <p className="text-subtitle text-muted-foreground">{comment.zh}</p>
        </div>
      ))}
    </div>
  );
}
