"use client";

import { type ChangeEvent, useEffect, useId, useRef, useState } from "react";

import { FailureNotice } from "@/components/app/FailureNotice";
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
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card";
import { Field, FieldContent, FieldDescription, FieldLabel } from "@/components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";
import { copy } from "@/i18n";
import {
  adminSponsorImageUrl,
  clearSponsor,
  getAdminSponsor,
  MAX_SPONSOR_IMAGE_BYTES,
  MAX_SPONSOR_IMAGE_MB,
  SPONSOR_IMAGE_TYPES,
  switchSponsor,
  uploadSponsorImage,
  type AdminSponsor as Sponsor,
} from "@/lib/adminSponsor";
import { toFailure, type Failure } from "@/lib/failure";

const t = copy.admin.config.sponsor;

type Action = "switch" | "upload" | "clear";

/**
 * 配置页「赞赏」标签里的那张卡（GLOSSARY.md「赞赏」，DESIGN.md「Layout · 后台 · 配置」）：开关一拨就存；
 * 下面是收款码的预览（开关关着也看得到）和「上传收款码」／「换一张」（outline），选了文件立刻上传。
 * 开着但还没传图时一行 muted 的提示，用户这时看不到。CardFooter 里「清除」，先弹 `AlertDialog` 确认。
 * 格式和大小先在浏览器里挡一次，后端照样再查。
 */
export function AdminSponsor() {
  const [sponsor, setSponsor] = useState<Sponsor | null>(null);
  const [failure, setFailure] = useState<Failure | null>(null);
  const [busy, setBusy] = useState<Action | null>(null);
  const [isConfirming, setConfirming] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const switchId = useId();

  useEffect(() => {
    getAdminSponsor().then(setSponsor, (e) => setFailure(toFailure(e)));
  }, []);

  async function run(action: Action, request: () => Promise<Sponsor>) {
    setBusy(action);
    setFailure(null);
    try {
      setSponsor(await request());
    } catch (e) {
      setFailure(toFailure(e));
    } finally {
      setBusy(null);
      setConfirming(false);
    }
  }

  function pick(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = ""; // 同一个文件再选一次也算
    if (!file) return;
    if (!(SPONSOR_IMAGE_TYPES as readonly string[]).includes(file.type)) {
      setFailure({ message: t.notAPicture, signedOut: false });
      return;
    }
    if (file.size > MAX_SPONSOR_IMAGE_BYTES) {
      setFailure({ message: t.tooLarge(MAX_SPONSOR_IMAGE_MB), signedOut: false });
      return;
    }
    void run("upload", () => uploadSponsorImage(file));
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>{t.title}</h2>
        </CardTitle>
        <CardDescription>{t.hint}</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        {!sponsor && !failure && (
          <p className="text-muted-foreground" role="status">
            {t.loading}
          </p>
        )}
        {failure && <FailureNotice failure={failure} />}
        {sponsor && (
          <>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel htmlFor={switchId}>{t.switch}</FieldLabel>
                {sponsor.enabled && sponsor.image_at === null && <FieldDescription>{t.noImage}</FieldDescription>}
              </FieldContent>
              <Switch
                id={switchId}
                checked={sponsor.enabled}
                onCheckedChange={(on) => void run("switch", () => switchSponsor(on))}
                disabled={busy !== null}
              />
            </Field>
            {sponsor.image_at !== null && (
              <img
                src={adminSponsorImageUrl(sponsor.image_at)}
                alt={t.preview}
                className="size-40 rounded-lg border object-contain"
              />
            )}
            <div className="flex flex-col gap-2">
              <input
                ref={input}
                type="file"
                accept={SPONSOR_IMAGE_TYPES.join(",")}
                className="sr-only"
                tabIndex={-1}
                aria-hidden
                onChange={pick}
              />
              <div>
                <Button variant="outline" size="sm" disabled={busy !== null} onClick={() => input.current?.click()}>
                  {busy === "upload" && <Spinner data-icon="inline-start" />}
                  {busy === "upload" ? t.uploading : sponsor.image_at === null ? t.upload : t.replace}
                </Button>
              </div>
              <p className="text-muted-foreground">{t.formats(MAX_SPONSOR_IMAGE_MB)}</p>
            </div>
          </>
        )}
      </CardContent>
      {sponsor && (sponsor.enabled || sponsor.image_at !== null) && (
        <CardFooter>
          <Button variant="ghost" size="sm" disabled={busy !== null} onClick={() => setConfirming(true)}>
            {t.clear}
          </Button>
        </CardFooter>
      )}
      <AlertDialog open={isConfirming} onOpenChange={(open) => busy === null && setConfirming(open)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.dialog.title}</AlertDialogTitle>
            <AlertDialogDescription>{t.dialog.description}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy !== null}>{copy.common.cancel}</AlertDialogCancel>
            <AlertDialogAction variant="destructive" disabled={busy !== null} onClick={() => void run("clear", clearSponsor)}>
              {busy === "clear" && <Spinner data-icon="inline-start" />}
              {t.dialog.confirm}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Card>
  );
}
