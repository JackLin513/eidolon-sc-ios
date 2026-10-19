// Announcements (GLOSSARY.md「公告」): what admins write in the admin console for every user
// to see. Only a body, in Markdown, with no title and no author; written as a draft, then
// published, withdrawn or deleted. Editing a published one keeps when it was published;
// withdrawing it and publishing it again makes it new. One published may be pinned: users see it
// first, however old; pinning another unpins it, withdrawing it unpins it.

import { api, expectNoContent, json } from "@/lib/api";

/** The most characters a body may have, as the backend allows. */
export const MAX_BODY = 5000;

export type AnnouncementStatus = "draft" | "published";

/** An announcement as admins see it. `published_at` is null while a draft. */
export type AdminAnnouncement = {
  id: string;
  body: string;
  status: AnnouncementStatus;
  published_at: string | null;
  created_at: string;
  /** When its body was last written. */
  updated_at: string;
  /** Whether it is the one users see first. */
  pinned: boolean;
};

/** An announcement as users see it: published, and nothing of who wrote it. */
export type Announcement = { id: string; body: string; published_at: string; pinned: boolean };

/** The admin console's list of announcements. */
export const ANNOUNCEMENTS_HREF = "/admin/announcements";

/** The id in the editor's address that stands for writing a new one, which has no id until
 * first saved. */
export const NEW_ANNOUNCEMENT = "new";

/** Where an announcement is edited in the admin console; `NEW_ANNOUNCEMENT` for a new one. */
export function announcementHref(id: string): string {
  return `${ANNOUNCEMENTS_HREF}/${encodeURIComponent(id)}`;
}

/** Every announcement, drafts first (last written first), then those published (the one pinned
 * first, then the latest). */
export async function listAdminAnnouncements(): Promise<AdminAnnouncement[]> {
  return json(await api("/api/admin/announcements"));
}

export async function getAdminAnnouncement(id: string): Promise<AdminAnnouncement> {
  return json(await api(`/api/admin/announcements/${encodeURIComponent(id)}`));
}

/** A new draft of `body`; refused if it is empty or too long. */
export async function writeAnnouncement(body: string): Promise<AdminAnnouncement> {
  return json(
    await api("/api/admin/announcements", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ body }),
    }),
  );
}

/** Replace its body; a published one stays published as of when it was. */
export async function editAnnouncement(id: string, body: string): Promise<AdminAnnouncement> {
  return json(
    await api(`/api/admin/announcements/${encodeURIComponent(id)}`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ body }),
    }),
  );
}

/** Publish it now, for every user to see. */
export async function publishAnnouncement(id: string): Promise<AdminAnnouncement> {
  return json(await api(`/api/admin/announcements/${encodeURIComponent(id)}/publish`, { method: "POST" }));
}

/** Make it a draft again; published again later, it is new. */
export async function withdrawAnnouncement(id: string): Promise<AdminAnnouncement> {
  return json(await api(`/api/admin/announcements/${encodeURIComponent(id)}/publish`, { method: "DELETE" }));
}

/** Make it the one users see first, unpinning the one that was; refused for a draft. */
export async function pinAnnouncement(id: string): Promise<AdminAnnouncement> {
  return json(await api(`/api/admin/announcements/${encodeURIComponent(id)}/pin`, { method: "POST" }));
}

export async function unpinAnnouncement(id: string): Promise<AdminAnnouncement> {
  return json(await api(`/api/admin/announcements/${encodeURIComponent(id)}/pin`, { method: "DELETE" }));
}

export async function deleteAnnouncement(id: string): Promise<void> {
  await expectNoContent(await api(`/api/admin/announcements/${encodeURIComponent(id)}`, { method: "DELETE" }));
}

/** The one pinned, if any, then the latest announcements published, newest first. */
export async function listAnnouncements(): Promise<Announcement[]> {
  return json(await api("/api/announcements"));
}

/** How many characters of a body the admin console's list shows. */
export const EXCERPT_LENGTH = 40;

/**
 * The start of a body as plain text, for telling announcements apart where they have no
 * title: the Markdown marks and HTML tags dropped (the words of links, images, code and
 * tags kept; underscores within a word too, which mark no emphasis), every run of
 * whitespace one space, and cut at `EXCERPT_LENGTH` characters with an ellipsis.
 */
export function excerpt(body: string): string {
  const text = body
    .replace(/^[ \t]*(?:[-*+]|\d+[.)]|#{1,6}|>)[ \t]+/gm, "")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/<[^>]*>/g, "")
    .replace(/[*`]/g, "")
    .replace(/(?<![\p{L}\p{N}])_+|_+(?![\p{L}\p{N}])/gu, "")
    .replace(/\s+/g, " ")
    .trim();
  const chars = Array.from(text);
  return chars.length > EXCERPT_LENGTH ? `${chars.slice(0, EXCERPT_LENGTH).join("")}…` : text;
}

// What a user has read (GLOSSARY.md「未读公告」) is kept on this device only, like hiding and
// pinning: in localStorage, apart for each user (eidolon.announcementsRead.<user id>), as the time
// the newest announcement read was published. Its id is not kept, so deleting one changes nothing,
// and one withdrawn and published again is new. What cannot be read or makes no sense is nothing
// read; what cannot be stored (private browsing) stays for this page.

function readKey(userId: string): string {
  return `eidolon.announcementsRead.${userId}`;
}

/** Kept for this page too, for when storage cannot be used. */
const readThisPage = new Map<string, string>();

/** When the newest announcement this user has read on this device was published; null if none. */
export function readUpTo(userId: string): string | null {
  let stored: unknown = null;
  try {
    stored = JSON.parse(localStorage.getItem(readKey(userId)) ?? "null");
  } catch {
    // Unreadable or broken: nothing read, but for what this page kept.
  }
  const kept = typeof stored === "string" && !Number.isNaN(Date.parse(stored)) ? stored : null;
  return later(kept, readThisPage.get(userId) ?? null);
}

/** Keep that this user has read every announcement published up to `at`. */
export function keepReadUpTo(userId: string, at: string): void {
  readThisPage.set(userId, at);
  try {
    localStorage.setItem(readKey(userId), JSON.stringify(at));
  } catch {
    // Storage cannot be used: kept for this page only.
  }
}

/** The ids of those published after `readAt`; every one when nothing has been read. */
export function unread(announcements: readonly Announcement[], readAt: string | null): Set<string> {
  const since = readAt === null ? -Infinity : Date.parse(readAt);
  return new Set(announcements.filter((a) => Date.parse(a.published_at) > since).map((a) => a.id));
}

/** What 「已读」 keeps: when the newest of these was published, so any published later is new. */
export function newestPublished(announcements: readonly Announcement[]): string | null {
  return announcements.reduce<string | null>((newest, a) => later(newest, a.published_at), null);
}

function later(a: string | null, b: string | null): string | null {
  if (a === null) return b;
  if (b === null) return a;
  return Date.parse(b) > Date.parse(a) ? b : a;
}
