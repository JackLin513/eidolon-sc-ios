"use client";

import NextLink from "next/link";
import { useEffect, useState } from "react";

import { AppLink } from "@/components/app/AppLink";
import { FailureNotice } from "@/components/app/FailureNotice";
import { AdminPage } from "@/components/app/admin/AdminPage";
import { Timestamp } from "@/components/app/admin/Timestamp";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/components/ui/empty";
import { Spinner } from "@/components/ui/spinner";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { copy } from "@/i18n";
import {
  NEW_ANNOUNCEMENT,
  announcementHref,
  excerpt,
  listAdminAnnouncements,
  type AdminAnnouncement,
  type AnnouncementStatus,
} from "@/lib/announcements";
import { toFailure, type Failure } from "@/lib/failure";

const t = copy.admin.announcements;

/**
 * 后台的「公告」页：草稿在前（后写的在上），然后是已发布的（置顶的在最上，其余后发布的在上）；右上角「写公告」。
 * 公告没有标题，每行用正文开头的一段认出来，点了进编辑页。宽屏（≥ 1024px）是装在 Card 里的表格：
 * 正文、状态、发布时间、最后修改；更窄时换成 divide-y 的行，正文在上，状态、发布时间和最后修改在副行
 * （DESIGN.md「Layout · 后台 · 公告」）。
 */
export function AdminAnnouncementList() {
  const [announcements, setAnnouncements] = useState<AdminAnnouncement[] | null>(null);
  const [failure, setFailure] = useState<Failure | null>(null);

  useEffect(() => {
    listAdminAnnouncements().then(setAnnouncements, (e) => setFailure(toFailure(e)));
  }, []);

  return (
    <AdminPage
      width="narrow"
      title={copy.admin.pages.announcements}
      intro={t.intro}
      end={
        <Button variant="outline" nativeButton={false} render={<NextLink href={announcementHref(NEW_ANNOUNCEMENT)} />}>
          {t.write}
        </Button>
      }
    >
      {failure && <FailureNotice failure={failure} />}

      {!announcements && !failure && (
        <p role="status" className="flex items-center gap-2 text-sm text-muted-foreground">
          <Spinner />
          {t.loading}
        </p>
      )}

      {announcements && announcements.length === 0 && (
        <Empty>
          <EmptyHeader>
            <EmptyTitle>{t.empty}</EmptyTitle>
            <EmptyDescription>{t.emptyHint}</EmptyDescription>
          </EmptyHeader>
        </Empty>
      )}

      {announcements && announcements.length > 0 && (
        <Card>
          <CardContent>
            <Table className="hidden lg:table">
              <TableHeader>
                <TableRow>
                  <TableHead>{t.columns.body}</TableHead>
                  <TableHead>{t.columns.status}</TableHead>
                  <TableHead>{t.columns.publishedAt}</TableHead>
                  <TableHead>{t.columns.updatedAt}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {announcements.map((a) => (
                  <TableRow key={a.id}>
                    <TableCell className="whitespace-normal">
                      <AppLink href={announcementHref(a.id)} isStandalone>
                        {excerpt(a.body)}
                      </AppLink>
                    </TableCell>
                    <TableCell>
                      <span className="flex items-center gap-2">
                        <StatusBadge status={a.status} />
                        {a.pinned && <PinnedBadge />}
                      </span>
                    </TableCell>
                    <TableCell>
                      <PublishedAt announcement={a} />
                    </TableCell>
                    <TableCell>
                      <Timestamp value={a.updated_at} />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>

            <ul className="divide-y lg:hidden">
              {announcements.map((a) => (
                <li key={a.id} className="py-3 first:pt-0 last:pb-0">
                  <NextLink
                    href={announcementHref(a.id)}
                    className="group flex flex-col items-start gap-1 rounded-sm outline-none focus-visible:ring-3 focus-visible:ring-ring/50"
                  >
                    <span className="font-medium break-words group-hover:underline">{excerpt(a.body)}</span>
                    <span className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                      <StatusBadge status={a.status} />
                      {a.pinned && <PinnedBadge />}
                      {a.published_at && (
                        <span>
                          {t.editor.publishedAt} <Timestamp value={a.published_at} />
                        </span>
                      )}
                      <span>
                        {t.editor.updatedAt} <Timestamp value={a.updated_at} />
                      </span>
                    </span>
                  </NextLink>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}
    </AdminPage>
  );
}

/** 「已发布」secondary Badge，「草稿」outline Badge（DESIGN.md「Admin status & charts」）。 */
export function StatusBadge({ status }: { status: AnnouncementStatus }) {
  return <Badge variant={status === "published" ? "secondary" : "outline"}>{t.status[status]}</Badge>;
}

/** 置顶的那条在状态后面再跟一个 outline Badge「置顶」。 */
export function PinnedBadge() {
  return <Badge variant="outline">{t.pinned}</Badge>;
}

function PublishedAt({ announcement }: { announcement: AdminAnnouncement }) {
  return announcement.published_at ? (
    <Timestamp value={announcement.published_at} />
  ) : (
    <span className="text-muted-foreground">{t.notPublished}</span>
  );
}
