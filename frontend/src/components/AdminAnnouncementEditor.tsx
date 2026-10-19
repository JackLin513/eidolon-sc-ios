"use client";

import { useRouter } from "next/navigation";
import { useEffect, useId, useState } from "react";

import { PinnedBadge, StatusBadge } from "@/components/AdminAnnouncementList";
import { AnnouncementBody } from "@/components/app/AnnouncementBody";
import { AppLink } from "@/components/app/AppLink";
import { FailureNotice } from "@/components/app/FailureNotice";
import { AdminPage } from "@/components/app/admin/AdminPage";
import { AdminTrail } from "@/components/app/admin/AdminTrail";
import { Notice } from "@/components/app/admin/Notice";
import { Timestamp } from "@/components/app/admin/Timestamp";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Card, CardAction, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card";
import { Field, FieldDescription, FieldError, FieldLabel } from "@/components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { copy } from "@/i18n";
import {
  ANNOUNCEMENTS_HREF,
  MAX_BODY,
  NEW_ANNOUNCEMENT,
  announcementHref,
  deleteAnnouncement,
  editAnnouncement,
  excerpt,
  getAdminAnnouncement,
  pinAnnouncement,
  publishAnnouncement,
  unpinAnnouncement,
  withdrawAnnouncement,
  writeAnnouncement,
  type AdminAnnouncement,
} from "@/lib/announcements";
import { toFailure, type Failure } from "@/lib/failure";
import { BackIcon } from "@/theme/icons";

const t = copy.admin.announcements;

type Busy = "save" | "publish" | "withdraw" | "pin" | "delete";

/**
 * 一条公告的编辑页，新写的也是这一页（地址 `/admin/announcements/new`，第一次保存后换成它自己的地址）。
 * 只有正文：Card 里一个 Textarea，用 Tabs 切换「编辑 / 预览」，预览和用户看到的一模一样（AnnouncementBody）。
 * 草稿的按钮是「发布」（default）和「保存草稿」，已发布的是「保存」（default）、「撤回」和「置顶 / 取消置顶」。
 * 发布时先存下没存的修改；置顶不存，没存的修改留在框里。
 * 删除单独一张 Card，按钮在 CardAction，确认框里执行的那一下用 destructive，删完回到列表
 * （DESIGN.md「Layout · 后台 · 公告」）。
 */
export function AdminAnnouncementEditor({ id }: { id: string }) {
  const isNew = id === NEW_ANNOUNCEMENT;
  const [saved, setSaved] = useState<AdminAnnouncement | null>(null);
  const [body, setBody] = useState("");
  const [mode, setMode] = useState<"edit" | "preview">("edit");
  const [busy, setBusy] = useState<Busy | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [failure, setFailure] = useState<Failure | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const router = useRouter();
  const bodyId = useId();
  const hintId = useId();

  useEffect(() => {
    if (isNew) return;
    getAdminAnnouncement(id).then(
      (found) => {
        setSaved(found);
        setBody(found.body);
      },
      (e) => setFailure(toFailure(e)),
    );
  }, [id, isNew]);

  const text = body.trim();
  const length = Array.from(text).length;
  const tooLong = length > MAX_BODY;
  const writable = text !== "" && !tooLong;
  const changed = saved ? text !== saved.body : text !== "";

  /** Run `act`, showing `done` when it succeeds and why when it fails. */
  async function run(what: Busy, act: () => Promise<void>, done?: string) {
    setBusy(what);
    setNotice(null);
    setFailure(null);
    try {
      await act();
      if (done) setNotice(done);
    } catch (e) {
      setFailure(toFailure(e));
    } finally {
      setBusy(null);
    }
  }

  /** Keep the body as typed, if changed; the announcement it is now. A new one gets its own
   * address, without loading the page again. */
  async function keep(): Promise<AdminAnnouncement> {
    if (saved && !changed) return saved;
    const kept = saved ? await editAnnouncement(saved.id, text) : await writeAnnouncement(text);
    setSaved(kept);
    setBody(kept.body);
    if (!saved) window.history.replaceState(null, "", announcementHref(kept.id));
    return kept;
  }

  const save = () => run("save", async () => void (await keep()), t.notices.saved);
  const publish = () =>
    run("publish", async () => setSaved(await publishAnnouncement((await keep()).id)), t.notices.published);
  const withdraw = () => saved && run("withdraw", async () => setSaved(await withdrawAnnouncement(saved.id)), t.notices.withdrawn);
  const pin = () =>
    saved &&
    (saved.pinned
      ? run("pin", async () => setSaved(await unpinAnnouncement(saved.id)), t.notices.unpinned)
      : run("pin", async () => setSaved(await pinAnnouncement(saved.id)), t.notices.pinned));
  const remove = () =>
    saved &&
    run("delete", async () => {
      try {
        await deleteAnnouncement(saved.id);
      } catch (e) {
        setConfirmingDelete(false);
        throw e;
      }
      router.replace(ANNOUNCEMENTS_HREF);
    });

  const back = (
    <AppLink href={ANNOUNCEMENTS_HREF} isStandalone className="inline-flex w-fit items-center gap-1">
      <BackIcon aria-hidden className="size-4" />
      {t.backToList}
    </AppLink>
  );

  if (!isNew && !saved) {
    // 还没拿到这条公告：只放转圈（或失败的原因）。
    return (
      <AdminPage width="narrow" above={back} title={t.editor.title}>
        {failure && <FailureNotice failure={failure} />}
        {!failure && (
          <p role="status" className="flex items-center gap-2 text-sm text-muted-foreground">
            <Spinner />
            {t.loading}
          </p>
        )}
      </AdminPage>
    );
  }

  const published = saved?.status === "published";
  const spinner = (what: Busy) => busy === what && <Spinner data-icon="inline-start" />;

  return (
    <AdminPage
      width="narrow"
      above={back}
      title={saved ? t.editor.title : t.editor.newTitle}
      meta={saved && <Meta announcement={saved} />}
    >
      <AdminTrail value={saved ? excerpt(saved.body) : t.editor.newTitle} />
      {notice && <Notice text={notice} onDismiss={() => setNotice(null)} />}
      {failure && <FailureNotice failure={failure} />}

      <Card>
        <CardContent>
          <Field data-invalid={tooLong || undefined}>
            <Tabs value={mode} onValueChange={(value) => setMode(value as "edit" | "preview")}>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <FieldLabel htmlFor={bodyId}>{t.editor.body}</FieldLabel>
                <TabsList aria-label={t.editor.modes}>
                  <TabsTrigger value="edit">{t.editor.edit}</TabsTrigger>
                  <TabsTrigger value="preview">{t.editor.preview}</TabsTrigger>
                </TabsList>
              </div>
              <TabsContent value="edit">
                <Textarea
                  id={bodyId}
                  value={body}
                  onChange={(e) => setBody(e.target.value)}
                  aria-invalid={tooLong || undefined}
                  aria-describedby={hintId}
                  className="min-h-60"
                />
              </TabsContent>
              <TabsContent value="preview">
                <div className="min-h-60 rounded-md border px-3 py-2">
                  {text ? (
                    <AnnouncementBody body={text} />
                  ) : (
                    <p className="text-sm text-muted-foreground">{t.editor.emptyPreview}</p>
                  )}
                </div>
              </TabsContent>
            </Tabs>
            <div className="flex items-start justify-between gap-4">
              <FieldDescription id={hintId}>{t.editor.bodyHint}</FieldDescription>
              <p className="shrink-0 text-xs text-muted-foreground tabular-nums">{t.editor.count(length, MAX_BODY)}</p>
            </div>
            {tooLong && <FieldError>{t.editor.tooLong(MAX_BODY)}</FieldError>}
            {published && <FieldDescription>{t.editor.publishedHint}</FieldDescription>}
          </Field>
        </CardContent>
        <CardFooter className="flex-wrap gap-2">
          {published ? (
            <>
              <Button onClick={save} disabled={busy !== null || !writable || !changed}>
                {spinner("save")}
                {t.actions.save}
              </Button>
              <Button variant="outline" onClick={withdraw} disabled={busy !== null}>
                {spinner("withdraw")}
                {t.actions.withdraw}
              </Button>
              <Button variant="outline" onClick={pin} disabled={busy !== null}>
                {spinner("pin")}
                {saved?.pinned ? t.actions.unpin : t.actions.pin}
              </Button>
            </>
          ) : (
            <>
              <Button onClick={publish} disabled={busy !== null || !writable}>
                {spinner("publish")}
                {t.actions.publish}
              </Button>
              <Button variant="outline" onClick={save} disabled={busy !== null || !writable || !changed}>
                {spinner("save")}
                {t.actions.saveDraft}
              </Button>
            </>
          )}
        </CardFooter>
      </Card>

      {saved && (
        <Card>
          <CardHeader>
            <CardTitle>{t.deleteSection.title}</CardTitle>
            <CardDescription>{t.deleteSection.hint}</CardDescription>
            <CardAction>
              <Button variant="outline" onClick={() => setConfirmingDelete(true)} disabled={busy !== null}>
                {t.deleteSection.action}
              </Button>
            </CardAction>
          </CardHeader>
        </Card>
      )}

      <AlertDialog open={confirmingDelete} onOpenChange={(open) => busy !== "delete" && setConfirmingDelete(open)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.deleteDialog.title}</AlertDialogTitle>
            <AlertDialogDescription>
              {t.deleteDialog.hint}
              {published && t.deleteDialog.published}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy === "delete"}>{copy.common.cancel}</AlertDialogCancel>
            <AlertDialogAction variant="destructive" disabled={busy === "delete"} onClick={remove}>
              {spinner("delete")}
              {t.deleteDialog.confirm}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </AdminPage>
  );
}

/** 标题下面一行：状态 Badge（置顶的再跟一个），和创建、发布、最后修改的时间。 */
function Meta({ announcement }: { announcement: AdminAnnouncement }) {
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted-foreground">
      <StatusBadge status={announcement.status} />
      {announcement.pinned && <PinnedBadge />}
      <span>
        {t.editor.createdAt} <Timestamp value={announcement.created_at} />
      </span>
      {announcement.published_at && (
        <span>
          {t.editor.publishedAt} <Timestamp value={announcement.published_at} />
        </span>
      )}
      <span>
        {t.editor.updatedAt} <Timestamp value={announcement.updated_at} />
      </span>
    </div>
  );
}
