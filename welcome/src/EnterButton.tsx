import { finish } from "./bridge";

/**
 * 右上角的入口（spec #118）：这一页看完（或者不想看了）从这里进 App。
 * 页面自己不导航——只通过 `window.webkit` 回调给 App，由它决定去主界面还是去导入。
 */
export function EnterButton({ label }: { label: string }) {
  return (
    <button type="button" className="lp-enter" onClick={() => finish("done")}>
      {label}
    </button>
  );
}
