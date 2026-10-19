// 后台的赞赏（GLOSSARY.md「赞赏」）：管理者上传一张收款码、打开开关，用户才在设置里看到「赞赏」。
// 只有一张图；「清除」关掉开关、删掉图。图片就是请求体，后端重新编码成无损 PNG。

import { api, json } from "@/lib/api";

/** `image_at`：收款码上传的时刻（ISO），也是它的版本；没传过是 null。 */
export type AdminSponsor = { enabled: boolean; image_at: string | null };

/** 后端收的图片格式和大小。 */
export const SPONSOR_IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp"] as const;
export const MAX_SPONSOR_IMAGE_MB = 2;
export const MAX_SPONSOR_IMAGE_BYTES = MAX_SPONSOR_IMAGE_MB * 1024 * 1024;

export async function getAdminSponsor(): Promise<AdminSponsor> {
  return json(await api("/api/admin/sponsor"));
}

export async function switchSponsor(enabled: boolean): Promise<AdminSponsor> {
  return json(
    await api("/api/admin/sponsor", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled }),
    }),
  );
}

/** 换上 `file` 当收款码；不是 PNG、JPEG、WebP 或超过 2 MB 时后端拒绝，原来的图不变。 */
export async function uploadSponsorImage(file: Blob): Promise<AdminSponsor> {
  return json(
    await api("/api/admin/sponsor/image", {
      method: "PUT",
      headers: { "Content-Type": file.type || "application/octet-stream" },
      body: file,
    }),
  );
}

export async function clearSponsor(): Promise<AdminSponsor> {
  return json(await api("/api/admin/sponsor", { method: "DELETE" }));
}

/** 后台预览的收款码，开关关着也看得到；每传一张新的换一个地址。 */
export function adminSponsorImageUrl(version: string): string {
  return `/api/admin/sponsor/image?${new URLSearchParams({ v: version })}`;
}
