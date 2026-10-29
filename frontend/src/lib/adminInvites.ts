// 后台的邀请链接（GLOSSARY.md「邀请链接」）：只让受邀的人注册时（「注册方式」），新用户要从邀请链接登录才能注册。
// 每条可以用几次、多久内有效、一句备注；删了立刻失效，经它注册的用户照常使用。

import { api, expectNoContent, json } from "@/lib/api";

/** 还能用；用完了；过期了。 */
export type InviteState = "usable" | "used_up" | "expired";

/** `expires_at`：到期的时刻（ISO），不过期是 null。`invited`：经它注册、现在还在的用户，先注册的在前。 */
export type Invite = {
  id: number;
  link: string;
  note: string | null;
  max_uses: number;
  used: number;
  expires_at: string | null;
  created_at: string;
  state: InviteState;
  invited: { id: string; name: string }[];
};

/** 一条链接最多能用几次，和后端的 `MAX_USES` 一样。 */
export const MAX_INVITE_USES = 100;

/** 有效期的几种选法：几天，或者不过期。 */
export const INVITE_LIFETIMES = ["1", "7", "30", "never"] as const;

export type InviteLifetime = (typeof INVITE_LIFETIMES)[number];

export type NewInvite = { note: string; maxUses: number; lifetime: InviteLifetime };

/** 所有邀请链接，新生成的在前。 */
export async function listInvites(): Promise<Invite[]> {
  return (await json<{ invites: Invite[] }>(await api("/api/admin/invites"))).invites;
}

export async function createInvite({ note, maxUses, lifetime }: NewInvite): Promise<Invite> {
  return json(
    await api("/api/admin/invites", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        note: note.trim() || null,
        max_uses: maxUses,
        lifetime_days: lifetime === "never" ? null : Number(lifetime),
      }),
    }),
  );
}

export async function deleteInvite(id: number): Promise<void> {
  await expectNoContent(await api(`/api/admin/invites/${id}`, { method: "DELETE" }));
}
