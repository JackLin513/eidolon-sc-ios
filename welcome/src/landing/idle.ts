/** 让出主线程，等浏览器空闲时再接着做下一批；不支持 requestIdleCallback 的（Safari）用定时器顶上。
 * 单独一个模块：LightStage 要先等到空闲再去 import 光层，光层建的时候也分批等，两边共用它。 */
export const idle = () =>
  new Promise<void>((resolve) => {
    const ric = window.requestIdleCallback as Window["requestIdleCallback"] | undefined;
    if (ric) ric.call(window, () => resolve(), { timeout: 1500 });
    else setTimeout(resolve, 50);
  });
