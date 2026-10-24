"use client";

import { useRouter } from "next/navigation";
import { useEffect, useId, useState } from "react";

import { FailureNotice } from "@/components/app/FailureNotice";
import { SettingsSection } from "@/components/app/SettingsSection";
import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { Field, FieldContent, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field";
import { Switch } from "@/components/ui/switch";
import { copy } from "@/i18n";
import { switchCycles } from "@/lib/api";
import { toFailure, type Failure } from "@/lib/failure";

const t = copy.settings.cycles;

/**
 * 设置「周期」（GLOSSARY.md「周期」）：一个开关加一行说明，关了所有角色都不受周期影响，周期本身照走。存在服务器上，一拨马上存，
 * 别的设备上也生效；存不上就拨回去，照原话说明。值在导航外壳持有的账号里，一级「周期」的摘要跟着变。
 * 部署者没开周期时账号里这一项为空，没有这一类：直接打开这个网址时回到设置页。
 */
export function CyclesSettings() {
  const { account, accountChanged } = useDirectory();
  const router = useRouter();
  const id = useId();
  const [saving, setSaving] = useState(false);
  const [failure, setFailure] = useState<Failure | null>(null);
  const on = account?.cycles ?? null;

  useEffect(() => {
    if (account && on === null) router.replace("/settings");
  }, [account, on, router]);

  if (!account || on === null) return null;

  const change = (next: boolean) => {
    setFailure(null);
    setSaving(true);
    accountChanged((current) => ({ ...current, cycles: next }));
    switchCycles(next).then(
      () => setSaving(false),
      (e) => {
        accountChanged((current) => ({ ...current, cycles: on }));
        setFailure(toFailure(e));
        setSaving(false);
      },
    );
  };

  return (
    <SettingsSection>
      <FieldGroup>
        <Field orientation="horizontal">
          <FieldContent>
            <FieldLabel htmlFor={`${id}-on`}>{t.on}</FieldLabel>
            <FieldDescription>{t.hint}</FieldDescription>
          </FieldContent>
          <Switch id={`${id}-on`} checked={on} disabled={saving} onCheckedChange={change} />
        </Field>
        {failure && <FailureNotice failure={failure} />}
      </FieldGroup>
    </SettingsSection>
  );
}
