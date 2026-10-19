"use client";

import { useState } from "react";

import { ImageViewer } from "@/components/app/ImageViewer";
import { SettingsRow } from "@/components/settings/SettingsRow";
import { copy } from "@/i18n";
import { sponsorImageUrl } from "@/lib/api";
import { SponsorIcon } from "@/theme/icons";

const t = copy.settings.sponsor;

/**
 * 设置一级里「关于」上面的「赞赏」（GLOSSARY.md「赞赏」，DESIGN.md「设置页」）：样子同一级的行，没有摘要，
 * 点了不跳页，整屏放大部署者的收款码（`version` 是 `Account.sponsor`）。
 */
export function SponsorRow({ version }: { version: string }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <SettingsRow onSelect={() => setOpen(true)} label={t.label} Icon={SponsorIcon} />
      <ImageViewer src={sponsorImageUrl(version)} title={t.code} alt={t.code} open={open} onOpenChange={setOpen} />
    </>
  );
}
