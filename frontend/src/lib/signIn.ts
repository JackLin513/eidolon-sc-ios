// Signing in with Google or GitHub happens by navigating to the backend, which sends the
// browser to the provider and back; when it cannot sign the browser in, it comes back
// to the sign-in page with `?error=<reason>`. Linking another identity goes the same
// way, back to the settings page. An invite link (GLOSSARY.md「邀请链接」) opens the sign-in
// page with `?invite=<code>`, which goes along to the backend for a new user to sign up with.

export type Provider = "github" | "google";

export const PROVIDER_LABELS: Record<Provider, string> = { github: "GitHub", google: "Google" };

/** Where the browser goes to sign in with `provider`, through the invite link with the code `invite` if given. */
export function signInUrl(provider: Provider, invite?: string | null): string {
  const start = `/api/auth/${provider}/start`;
  return invite ? `${start}?${new URLSearchParams({ invite })}` : start;
}

/** Where the browser goes to link the user's identity at `provider`. */
export function linkUrl(provider: Provider): string {
  return `/api/auth/${provider}/start?link=1`;
}

const REASONS: Record<string, string> = {
  too_new: "GitHub 账号注册满一年后才能用来登录。",
  email_unverified: "这个 Google 账号的邮箱还没有验证，验证后才能用来登录。",
  banned: "这位用户已被封禁，无法登录。",
  not_invited: "这里只接受受邀的人注册，请向部署者要一条邀请链接。",
  invite_invalid: "这条邀请链接已经失效，请向部署者要一条新的。",
  state: "登录请求已失效，请重新登录。",
  cancelled: "已取消登录。",
  provider: "暂时无法向登录服务确认你的身份，请稍后再试。",
  taken: "这个身份已经属于另一位用户。请先用这个身份登录，删除那位用户的全部数据，再回来绑定。",
  already_linked: "你已经绑定了这种登录方式的另一个身份，请先解绑它。",
};

/** What leads to how to reach the deployer, for the reasons that come with it. */
const CONTACT_LEADS: Record<string, string> = {
  banned: "如有疑问，请联系：",
  not_invited: "部署者的联系方式：",
  invite_invalid: "部署者的联系方式：",
};

/** What to tell the user about the reason the backend gave for not signing them in; a
 * banned user, and one who needs an invite link, is also told how to reach the deployer,
 * if the deployer says how. */
export function signInFailure(reason: string | null, contact?: string | null): string | null {
  if (!reason) return null;
  const said = REASONS[reason] ?? "登录失败，请重新登录。";
  const lead = CONTACT_LEADS[reason];
  return lead && contact ? `${said}${lead}${contact}` : said;
}
