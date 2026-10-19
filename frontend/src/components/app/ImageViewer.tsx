"use client";

import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog";

/**
 * 点开放大的一张图（DESIGN.md「Chat bubbles · 照片」「设置页 · 赞赏」）：整屏压 85% 黑，图居中放到最大，
 * 右上角白色 ✕。她发来的照片和设置里的赞赏收款码都用它；`title` 只给读屏。
 */
export function ImageViewer({
  src,
  title,
  alt,
  open,
  onOpenChange,
}: {
  src: string;
  title: string;
  alt: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent variant="viewer">
        <DialogTitle className="sr-only">{title}</DialogTitle>
        <img src={src} alt={alt} className="max-h-full max-w-full rounded-lg object-contain" />
      </DialogContent>
    </Dialog>
  );
}
