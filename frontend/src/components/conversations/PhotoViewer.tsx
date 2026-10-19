"use client";

import { ImageViewer } from "@/components/app/ImageViewer";
import { copy } from "@/i18n";
import { photoImageUrl } from "@/lib/api";

const t = copy.conversation.photo;

/**
 * 点开放大的照片（DESIGN.md「Chat bubbles · 照片」）：整屏压 85% 黑，照片居中放到最大。
 * 对话记录里的照片块和通话层上的照片都用它。
 */
export function PhotoViewer({ id, open, onOpenChange }: { id: string; open: boolean; onOpenChange: (open: boolean) => void }) {
  return <ImageViewer src={photoImageUrl(id)} title={t.viewer} alt={t.sent} open={open} onOpenChange={onOpenChange} />;
}
