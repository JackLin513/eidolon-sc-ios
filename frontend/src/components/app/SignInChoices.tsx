"use client";

import { AppLink } from "@/components/app/AppLink";
import { Button } from "@/components/ui/button";
import { copy } from "@/i18n";
import { interpolate } from "@/i18n/interpolate";
import type { SignInOptions } from "@/lib/api";
import { cn } from "@/lib/utils";
import { PROVIDER_LABELS, signInUrl } from "@/lib/signIn";

const t = copy.login;

/**
 * 登录组件：后端提供的登录方式（第一种是主按钮）、登录即同意的说明，部署者一种都没配时的提示。
 * 登录页和落地页的登录面板共用它；`options` 还没取到时只有同意说明。从邀请链接打开的登录页传来 `invite`，
 * 随登录带给后端（GLOSSARY.md「邀请链接」），页面上不另加说明。
 */
export function SignInChoices({
  options,
  invite,
  className,
}: {
  options: SignInOptions | null;
  invite?: string | null;
  className?: string;
}) {
  return (
    <section aria-label={t.signInRegion} className={cn("flex flex-col gap-3", className)}>
      {options?.providers.map((provider, i) => (
        // 登录要整页跳到后端的 OAuth 入口，用普通的 <a>，不走客户端路由。
        <Button
          key={provider}
          variant={i === 0 ? "default" : "outline"}
          size="lg"
          nativeButton={false}
          render={<a href={signInUrl(provider, invite)} />}
          className="w-full"
        >
          {t.signInWith(PROVIDER_LABELS[provider])}
        </Button>
      ))}
      {options && options.providers.length === 0 && !options.dev_login && (
        <p className="text-body text-muted-foreground">{t.noProviders}</p>
      )}
      <p className="text-sm text-muted-foreground">
        {interpolate(t.agreement, {
          privacy: (
            <AppLink key="privacy" href="/privacy">
              {copy.legal.privacy}
            </AppLink>
          ),
          terms: (
            <AppLink key="terms" href="/terms">
              {copy.legal.terms}
            </AppLink>
          ),
        })}
      </p>
    </section>
  );
}
