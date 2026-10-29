"use client";

import { Fragment, type FormEvent, useEffect, useId, useRef, useState } from "react";

import { AppLink } from "@/components/app/AppLink";
import { FailureNotice } from "@/components/app/FailureNotice";
import { Notice } from "@/components/app/admin/Notice";
import { NumberInput } from "@/components/app/admin/NumberInput";
import { Timestamp } from "@/components/app/admin/Timestamp";
import { useOpenForm } from "@/components/admin/OpenForm";
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
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel, FieldTitle } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Spinner } from "@/components/ui/spinner";
import { copy } from "@/i18n";
import {
  createInvite,
  deleteInvite,
  INVITE_LIFETIMES,
  listInvites,
  MAX_INVITE_USES,
  type Invite,
  type InviteLifetime,
  type NewInvite,
} from "@/lib/adminInvites";
import { toFailure, type Failure } from "@/lib/failure";

const t = copy.admin.config.invites;

/** 「已复制」留多久，毫秒。 */
const COPIED_FOR = 2000;

/**
 * 配置页「注册」标签里，注册方式下面的那张卡（GLOSSARY.md「邀请链接」，DESIGN.md「Layout · 后台 · 配置」）。
 * 右上角 outline 的「生成邀请链接」，点了在卡里展开表单（备注、可用次数、有效期），和配置项的「修改」一样全页只开一张。
 * 下面每条链接一行（`divide-y`），新生成的在上：备注（没有时 muted 的「没有备注」），用完、过期的跟一个 outline Badge；
 * 下面是 0.75rem、muted 的副行：次数和到期时间；有人经它注册时再一行「经它注册：」加名字，链到用户详情。行尾 ghost 的「复制链接」
 * （复制后两秒内写「已复制」）和「删除」，删除先弹 AlertDialog。
 */
export function AdminInvites() {
  const [invites, setInvites] = useState<Invite[] | null>(null);
  const [failure, setFailure] = useState<Failure | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState<"create" | "delete" | null>(null);
  const [creating, setCreating] = useOpenForm("invites");
  const [toDelete, setToDelete] = useState<Invite | null>(null);
  const [copied, setCopied] = useState<number | null>(null);
  const copiedTimer = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => {
    listInvites().then(setInvites, (e) => setFailure(toFailure(e)));
    return () => clearTimeout(copiedTimer.current);
  }, []);

  async function create(made: NewInvite) {
    setBusy("create");
    setFailure(null);
    setNotice(null);
    try {
      const invite = await createInvite(made);
      setInvites((all) => [invite, ...(all ?? [])]);
      setCreating(false);
      setNotice(t.created);
    } catch (e) {
      setFailure(toFailure(e));
    } finally {
      setBusy(null);
    }
  }

  async function remove(invite: Invite) {
    setBusy("delete");
    setFailure(null);
    setNotice(null);
    try {
      await deleteInvite(invite.id);
      setInvites((all) => (all ?? []).filter((i) => i.id !== invite.id));
    } catch (e) {
      setFailure(toFailure(e));
    } finally {
      setBusy(null);
      setToDelete(null);
    }
  }

  async function copyLink(invite: Invite) {
    setFailure(null);
    try {
      await navigator.clipboard.writeText(invite.link);
      setCopied(invite.id);
      clearTimeout(copiedTimer.current);
      copiedTimer.current = setTimeout(() => setCopied(null), COPIED_FOR);
    } catch {
      setFailure({ message: t.copyFailed(invite.link), signedOut: false });
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>{t.title}</h2>
        </CardTitle>
        <CardDescription>{t.hint}</CardDescription>
        {!creating && (
          <CardAction>
            <Button variant="outline" size="sm" onClick={() => setCreating(true)} disabled={busy !== null || !invites}>
              {t.create}
            </Button>
          </CardAction>
        )}
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        {!invites && !failure && (
          <p className="text-muted-foreground" role="status">
            {t.loading}
          </p>
        )}
        {notice && <Notice text={notice} onDismiss={() => setNotice(null)} />}
        {failure && <FailureNotice failure={failure} />}
        {creating && <InviteForm busy={busy === "create"} onSubmit={create} onCancel={() => setCreating(false)} />}
        {invites && invites.length === 0 && !creating && <p className="text-muted-foreground">{t.empty}</p>}
        {invites && invites.length > 0 && (
          <ul className="flex flex-col divide-y">
            {invites.map((invite) => (
              <li key={invite.id} className="flex flex-wrap items-start justify-between gap-x-4 gap-y-2 py-3">
                <div className="flex min-w-0 flex-col gap-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className={invite.note ? "font-medium break-all" : "text-muted-foreground"}>{invite.note ?? t.noNote}</span>
                    {invite.state !== "usable" && <Badge variant="outline">{t.states[invite.state]}</Badge>}
                  </div>
                  <p className="text-xs text-muted-foreground tabular-nums">
                    {t.used(invite.used, invite.max_uses)} ·{" "}
                    {invite.expires_at ? (
                      <>
                        <Timestamp value={invite.expires_at} /> {t.expiresAt}
                      </>
                    ) : (
                      t.neverExpires
                    )}
                  </p>
                  {invite.invited.length > 0 && (
                    <p className="text-xs text-muted-foreground">
                      {t.invited}
                      {invite.invited.map((user, i) => (
                        <Fragment key={user.id}>
                          {i > 0 && t.nameSeparator}
                          <AppLink href={`/admin/users/${user.id}`}>{user.name}</AppLink>
                        </Fragment>
                      ))}
                    </p>
                  )}
                </div>
                <div className="flex gap-1">
                  <Button
                    variant="ghost"
                    size="sm"
                    aria-label={copy.admin.actionOn(t.copy, invite.note ?? t.noNote)}
                    onClick={() => void copyLink(invite)}
                  >
                    {copied === invite.id ? t.copied : t.copy}
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    aria-label={copy.admin.actionOn(t.delete, invite.note ?? t.noNote)}
                    disabled={busy !== null}
                    onClick={() => setToDelete(invite)}
                  >
                    {t.delete}
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
      <AlertDialog open={toDelete !== null} onOpenChange={(open) => !open && busy === null && setToDelete(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.dialog.title}</AlertDialogTitle>
            <AlertDialogDescription>{t.dialog.description}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy !== null}>{copy.common.cancel}</AlertDialogCancel>
            <AlertDialogAction
              variant="destructive"
              disabled={busy !== null}
              onClick={() => toDelete && void remove(toDelete)}
            >
              {busy === "delete" && <Spinner data-icon="inline-start" />}
              {t.dialog.confirm}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Card>
  );
}

/** 生成一条邀请链接的表单：备注（可选）、可用次数（默认 1）、有效期（默认 7 天）。打开时焦点落在备注上。 */
function InviteForm({
  busy,
  onSubmit,
  onCancel,
}: {
  busy: boolean;
  onSubmit: (made: NewInvite) => void;
  onCancel: () => void;
}) {
  const id = useId();
  const [note, setNote] = useState("");
  const [maxUses, setMaxUses] = useState<number | null>(1);
  const [lifetime, setLifetime] = useState<InviteLifetime>("7");
  const [checked, setChecked] = useState(false);
  const usesValid = maxUses !== null && Number.isInteger(maxUses) && maxUses >= 1 && maxUses <= MAX_INVITE_USES;
  const lifetimes = INVITE_LIFETIMES.map((value) => ({ value, label: t.form.lifetimes[value] }));

  function submit(event: FormEvent) {
    event.preventDefault();
    setChecked(true);
    if (usesValid) onSubmit({ note, maxUses, lifetime });
  }

  return (
    <form onSubmit={submit} noValidate className="flex max-w-md flex-col gap-6">
      <FieldGroup>
        <Field>
          <FieldLabel htmlFor={`${id}-note`}>
            {t.form.note}
            <span className="font-normal text-muted-foreground">{copy.common.optional}</span>
          </FieldLabel>
          <Input
            id={`${id}-note`}
            value={note}
            maxLength={100}
            onChange={(event) => setNote(event.target.value)}
            autoComplete="off"
            autoFocus
          />
          <FieldDescription>{t.form.noteHint}</FieldDescription>
        </Field>
        <Field data-invalid={checked && !usesValid ? true : undefined}>
          {/* NumberInput 自己带读屏名，没有能指的 id：标题用 FieldTitle，和配置项的数字一样。 */}
          <FieldTitle>{t.form.maxUses}</FieldTitle>
          <NumberInput
            label={t.form.maxUses}
            value={maxUses}
            onChange={setMaxUses}
            min={1}
            max={MAX_INVITE_USES}
            isIntegerOnly
            isInvalid={checked && !usesValid}
          />
          {checked && !usesValid && <FieldError>{t.form.maxUsesProblem(MAX_INVITE_USES)}</FieldError>}
        </Field>
        <Field>
          <FieldLabel htmlFor={`${id}-lifetime`}>{t.form.lifetime}</FieldLabel>
          <Select items={lifetimes} value={lifetime} onValueChange={(value) => value && setLifetime(value as InviteLifetime)}>
            <SelectTrigger id={`${id}-lifetime`} className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {lifetimes.map((option) => (
                <SelectItem key={option.value} value={option.value}>
                  {option.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
      </FieldGroup>
      <div className="flex flex-wrap gap-2">
        <Button type="submit" disabled={busy}>
          {busy && <Spinner data-icon="inline-start" />}
          {busy ? t.form.submitting : t.form.submit}
        </Button>
        <Button type="button" variant="ghost" onClick={onCancel} disabled={busy}>
          {copy.common.cancel}
        </Button>
      </div>
    </form>
  );
}
