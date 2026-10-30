# 全幅画布（full-bleed canvas）在 SwiftUI 里的正确做法

研究日期：2026-10-30。目标平台：iOS 26 / Xcode 26，SwiftUI，iPhone Air 横屏（window 912×420 pt）。

本文件只把 Apple 一手来源（developer.apple.com 文档、WWDC 文稿、Apple 自己的 sample/框架文档）当作事实依据。
每条结论都标了来源 URL；**凡是文档没说、只能靠我们自己的日志推出来的，都明确标成「实测推断」，不冒充官方结论**。

标记约定：

- 【文档明确】= Apple 文档/文稿里有对应原话（附 URL + 原文）
- 【实测推断】= 文档没写，从真机日志的数字反推出来的
- 【文档未覆盖】= 查过 Apple 文档，没有说明

---

## 0. 一句话结论

`ignoresSafeArea` 改的是**提案尺寸（proposal）**，不是"绘制区域"；`GeometryProxy.safeAreaInsets` 报的是"这个视图自己 bounds 里还剩多少没被它吞掉的安全区"。所以**不要拿 insets 去做补偿**——正确做法是让**画布所在的容器本身**拿到扩展后的 proposal，然后用 `.topLeading` 对齐，一个 inset 都不用算。
推荐实现见 §5（一个 `GeometryReader` + 外层 `.ignoresSafeArea()`，`GeometryReader` 只用来算 scale，不用来定尺寸）。

---

## 1. 问题 1：各手段的确切语义

### 1.1 `.ignoresSafeArea(_:edges:)` —— 改的是 layout 提案，不是画布

【文档明确】摘要就是 "Expands the safe area of a view."，正文原话：

> "By default, the SwiftUI layout system sizes and positions views to avoid certain safe areas. This ensures that system content like the software keyboard or edges of the device don't obstruct your views. To extend your content into these regions, you can ignore safe areas on specific edges by applying this modifier.
> **When expanding the safe area, the SwiftUI layout system proposes the expanded size to the view.** If your view has a fixed size, the alignment of the view may not be what you expect."

来源：<https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:)>

这句话是全部问题的关键：**它把"扩展后的尺寸"作为 proposal 传给这个视图**。视图接不接受，取决于视图自己（固定尺寸的视图不接受，就会"对齐不是你期望的样子"）。
同一条文档的 `alignment:` 版本说得更直白：

> "When expanding the safe area, the SwiftUI layout system proposes the expanded size to the view. If your view has a fixed size, you can use the alignment property to determine how the fixed size view should be aligned in the expanded bounds."

来源：<https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:alignment:)>

被它取代的旧 API（`edgesIgnoringSafeArea`）文档把机制写得最清楚：

> "Use `edgesIgnoringSafeArea(_:)` to change the area proposed for this view so that — **were the proposal accepted** — this view could extend outside the safe area to the bounds of the screen for the specified edges."

来源：<https://developer.apple.com/documentation/swiftui/view/edgesignoringsafearea(_:)>

结论【文档明确】：`ignoresSafeArea` **既不是**"只改绘制区域、不改布局"，**也不是**"无条件铺满屏幕"。它 = "把扩展后的 proposal 给你，你要接住"。所以它到底把视图撑到多大，取决于被修饰的那一层是否接受 proposal，以及**它的父层把它的 frame 放在哪儿**。

### 1.2 `regions`：`.container` 与 `.keyboard` 的区别

【文档明确】

- `SafeAreaRegions.all` — "All safe area regions."
- `.container` — "The safe area defined by the device and containers within the user interface, including elements such as top and bottom bars."
- `.keyboard` — "The safe area matching the current extent of any software keyboard displayed over the view content."

来源：<https://developer.apple.com/documentation/swiftui/safearearegions>、<https://developer.apple.com/documentation/swiftui/safearearegions/container>、<https://developer.apple.com/documentation/swiftui/safearearegions/keyboard>

对我们的用途：**只关心 `.container`**（设备硬件 + 导航栏这类容器）。文档明确 `.container` 包含"top and bottom bars"，所以"把导航栏那一块也算进去"是 `.container` 的语义，不用另外处理。
默认值 `.all` 会把键盘区域也忽略掉——酒吧页没有键盘，所以默认值无害，但写成 `.container` 语义更贴合。

一个官方例子（背景层 ignoresSafeArea，内容层不动）：

> "To get the contents of the vertical stack to respect the safe areas and adjust to the keyboard, move the modifier to only apply to the background view."

来源：<https://developer.apple.com/documentation/swiftui/adding-a-background-to-your-view>

这个例子本身的抽象是 "Compose a background behind your view and extend it beyond the safe area insets."——Apple 只示范了"背景层铺出去"，**没有示范"整页都是游戏画面"这种全幅内容**，这是我们的场景比文档更极端的地方。

### 1.3 `GeometryProxy.size` 与 `safeAreaInsets`

【文档明确】两条都只有一句抽象，没有 Discussion：

- `size` — "The size of the container view."
  <https://developer.apple.com/documentation/swiftui/geometryproxy/size>
- `safeAreaInsets` — "The safe area inset of the container view."
  <https://developer.apple.com/documentation/swiftui/geometryproxy/safeareainsets>
- `frame(in:)` — "Returns the container view's bounds rectangle, converted to a defined coordinate space."
  <https://developer.apple.com/documentation/swiftui/geometryproxy/frame(in:)>
- `CoordinateSpace.global` — "The global coordinate space at the root of the view hierarchy."
  <https://developer.apple.com/documentation/swiftui/coordinatespace/global>

【文档未覆盖】以下三个问题 Apple 一个字都没写：

1. "the container" 具体是哪一层（父视图？最近的布局容器？窗口？）；
2. 在被 `ignoresSafeArea` 扩展之后，`size` / `safeAreaInsets` 各报什么；
3. `.global` 是否等于"窗口坐标"（文档只说"root of the view hierarchy"，而我们的日志显示它恰好等于窗口坐标——那是**实测推断**，不是保证）。

**所以不能假设 `size + insets` 等于窗口尺寸。** 我们代码里 `BarFit.window` 的那段加法（`size.width + insets.leading + insets.trailing`）在文档层面没有依据；它只在"insets 就是设备真实安全区"时成立，而真机日志证明这个前提不成立。

### 1.4 `safeAreaInset(edge:)` / `safeAreaPadding` / `containerRelativeFrame` / `GeometryReader`

| API | 官方语义（原文） | 对我们的用途 |
|---|---|---|
| `safeAreaInset(edge:alignment:spacing:content:)` iOS 15+ | "The modified view is inset by the width of `content`, from `edge`, **with its safe area increased by the same amount**." | 是"加一条 bar，把内容挤开"，方向相反，用不上 |
| `safeAreaPadding(_:)` iOS 17+ | "Adds the provided insets into the safe area of this view." / "Use this modifier when you would like to add a fixed amount of space to the safe area a view sees." | 只增不减，用不上 |
| `containerRelativeFrame(_:alignment:_:)` iOS 17+ | "**The size provided to this modifier is the size of a container like the ones listed above subtracting any safe area insets that might be applied to that container.**" | **反例**：它明确**减掉**安全区，给的是"安全区内的尺寸"，天生做不出全幅 |
| `GeometryReader` iOS 13+ | "A container view that defines its content as a function of its own size and coordinate space." + "**This view returns a flexible preferred size to its parent layout.**" | 关键：它的尺寸来自 proposal，**不受内容影响**——这正是"不会产生反馈环"的原因 |

来源：
<https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)>
<https://developer.apple.com/documentation/swiftui/view/safeareapadding(_:)>
<https://developer.apple.com/documentation/swiftui/view/containerrelativeframe(_:alignment:_:)>
<https://developer.apple.com/documentation/swiftui/geometryreader>

Note【文档明确】`containerRelativeFrame` 里列出的"container"包括 "The window presenting a view on iPadOS or macOS, or the screen of a device on iOS."——也就是说在 iOS 上它可以相对"屏幕"取尺寸，但取完还要**减去安全区**。这一条足以否定"用 containerRelativeFrame 做全幅"的想法。

### 1.5 `UIHostingController` / `UIWindow` / `UIScreen` / 场景

- `UIHostingController` 【文档明确】："A UIKit view controller that manages a SwiftUI view hierarchy."，只说明了怎么嵌进 UIKit，**没有任何关于 safe area 如何传递的说明**。
  <https://developer.apple.com/documentation/swiftui/uihostingcontroller>
- `UIView.safeAreaInsets` 【文档明确】这是 UIKit 侧唯一把规则写清楚的地方：

  > "The safe area of a view reflects the area not covered by navigation bars, tab bars, toolbars, and other ancestors that obscure a view controller's view. … **For the view controller's root view, the insets account for the status bar, other visible bars, and any additional insets that you specified using the `additionalSafeAreaInsets` property of your view controller. For other views in the view hierarchy, the insets reflect only the portion of the view that is covered.** For example, if a view is entirely within the safe area of its superview, the edge insets in this property are `0`."

  <https://developer.apple.com/documentation/uikit/uiview/safeareainsets>
- `UIViewController.additionalSafeAreaInsets` 【文档明确】："The safe area defines the portion of your view controller's visible area that is guaranteed to be unobscured by the system status bar **or by an ancestor-provided view such as the navigation bar**."
  <https://developer.apple.com/documentation/uikit/uiviewcontroller/additionalsafeareainsets>

  这两条合起来，是"导航栏参与安全区计算"的官方依据——但是 **UIKit 的**依据。SwiftUI 的 `GeometryProxy.safeAreaInsets` 是否沿用同一套规则，【文档未覆盖】。

- `UIScreen.main` 【文档明确】在 iOS 26.0 已废弃：

  > "Apple discourages the use of this symbol. Use a `UIScreen` instance found through context instead. For example, reference the screen that displays a view through the `screen` property on the window scene managing the window containing the view."
  > 平台数据：`deprecatedAt: 26.0`，message: "Use a UIScreen instance found through context instead (i.e, view.window.windowScene.screen)…"

  <https://developer.apple.com/documentation/uikit/uiscreen/main>

  即：**iOS 26 起，取屏幕/窗口信息应该走 `UIWindowScene`**，不是 `UIScreen.main`，更不是把 `UIScreen.bounds` 当成"内容区"。`UIScreen.bounds` 的文档只说它是"the bounding rectangle of the screen, measured in points"，并且"may change when the device rotates"。
  <https://developer.apple.com/documentation/uikit/uiscreen/bounds>

- `UIWindowScene` 【文档明确】："A scene that manages one or more windows for your app."；`keyWindow`，`windows`，`screen` 都在 "Getting the active windows" 一节下。
  <https://developer.apple.com/documentation/uikit/uiwindowscene>

  我们代码里 `connectedScenes → first UIWindowScene → keyWindow?.bounds.size` 这条路，在 iOS 26 下是**官方推荐的方向**（相对 `UIScreen.main` 而言）。它的问题是另一回事：`UIWindow.bounds` 是**窗口**的 bounds，不含任何 SwiftUI 布局信息，只能当"事实来源"，不能当"布局容器"。

### 1.6 iOS 26 有什么新东西（以及网上常被误传的两个）

【文档明确】iOS 26.0 新增、与安全区直接相关的：

- `safeAreaBar(edge:alignment:spacing:content:)` iOS **26.0** — "Similar to the `safeAreaInset(edge:alignment:spacing:content:)` modifier, the `content` view is anchored to the specified horizontal edge of the parent view and its width insets the safe area. Additionally, it extends the edge effect of any scroll views affected by the inset safe area."
  <https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:)>
  这是"加一条自定义 bar"，不是"铺满"。
- `backgroundExtensionEffect()` iOS **26.0** — "The view will be duplicated into mirrored copies which will be placed around the view on any edge with available safe area. Additionally, a blur effect will be applied on top to blur out the copies."
  <https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()>
  它解决的是"图片延伸出去后，边上的元件压住了重要内容"这个视觉问题（镜像+模糊填充），**不是**布局 API。HIG 也是这么定位它的：
  > "If scaling a background image to the full window edge results in components like sidebars or inspectors covering important parts of the image, you can use a background extension effect to flip and blur the image…"
  <https://developer.apple.com/design/human-interface-guidelines/layout>

- `windowResizeBehavior(_:)` —— **不是 iOS 的 API**。平台数据只有 macOS 15.0+。
  <https://developer.apple.com/documentation/swiftui/view/windowresizebehavior(_:)>
  它是"配置窗口能否被用户缩放"，跟画布铺满无关。

- `edgesIgnoringSafeArea(_:)` 的替代 **早就是** `ignoresSafeArea(_:edges:)`（iOS 14 起）。现在文档把 `edgesIgnoringSafeArea` 标成 `deprecatedAt: 27.2`，message："Use ignoresSafeArea(_:edges:) instead."
  <https://developer.apple.com/documentation/swiftui/view/edgesignoringsafearea(_:)>

- 【文档明确，但超出 iOS 26 目标】`toolbarMinimizationSafeAreaAdjustment(_:for:)` 是 iOS **27.0** 的 API，专门给"toolbar 收起时内容要不要跟着回流"用的，文档举例正是 "when displaying full-bleed media beneath a minimizing bar"。
  <https://developer.apple.com/documentation/swiftui/view/toolbarminimizationsafeareaadjustment(_:for:)>
  我们在 iOS 26 上**用不到**，记下即可。

- 【文档明确，值得记一笔】`.statusBarHidden(_:)` 在当前文档里 `deprecatedAt: 27.2`，message："Use .toolbarVisibility(_, for: .statusBar) instead"。替代品 `ToolbarPlacement.statusBar` 的文档也写着 "Use with `toolbarVisibility(_:for:)` to hide the status bar"。
  <https://developer.apple.com/documentation/swiftui/view/statusbarhidden(_:)>
  <https://developer.apple.com/documentation/swiftui/toolbarplacement/statusbar>
  iOS 26 上 `.statusBarHidden(true)` 仍然可用（iOS 13 起就有），只是下一个 SDK 会告警。

### 1.7 WWDC 文稿：查过哪些、找到了什么

我把 Apple 的 WWDC 年份索引页抓下来，把 SwiftUI/布局相关的场次逐篇文稿抓下来，全文搜 `safe area`：

| 场次 | 结果 |
|---|---|
| WWDC19 237 *Building Custom Views with SwiftUI* | **有**关键原话（见下） |
| WWDC19 216 *SwiftUI Essentials* | 全文无 "safe area" |
| WWDC20 10041 *What's new in SwiftUI* | 全文无 "safe area" |
| WWDC22 10072 *Use SwiftUI with UIKit* | 全文无 "safe area" |
| WWDC25 256 *What's new in SwiftUI* | 全文无 "safe area" |
| WWDC25 323 *Build a SwiftUI app with the new design* | 只提 `backgroundExtensionEffect`："views can extend outside the safe area, without clipping their content" |
| WWDC26 269 *What's new in SwiftUI* | 全文无 "safe area"（讲的是窗口/toolbar 自适应） |

WWDC19 237 里对"根视图 = 设备尺寸减安全区"的原话（这是整件事的起点）：

> "…the root view which in this case has **the dimensions of the device minus the safe area insets**. So if you see something like this at the top of your phone, for example, it's not included. Pro tip, you can still lay stuff out in that area by using this modifier, okay? But by default you're in the safety zone."

以及同一场里对"固定尺寸子视图如何被摆放"的解释：

> "See it's important to recognize that **the frame is not a constraint in SwiftUI**, it's just a view which you can think of like a picture frame. It proposes fixed dimensions for its child, but like every other view, **the child ultimately chooses its own size**."

来源：<https://developer.apple.com/videos/play/wwdc2019/237/>

【文档明确】结论：WWDC 讲清楚了"根视图从安全区尺寸起步"和"proposal 可以被拒绝"，但**没有任何一场 WWDC 讲"如何让一页内容真正铺满窗口"**。

---

## 2. 问题 2：为什么 destination 里报 size=(912,420) 却 insets=(0,10,0,0)，子层被放到 y=-10

先把三组数字摆在一起（真机，iPhone Air 横屏）：

```
page  size=(912.0, 420.0)  insets=(t0.0 b10.0 l0.0)
stage global=(0.0, -10.0, 912.0, 420.0)
设备安全区（正常时）: 左右 68、底 20  →  安全区内容 = 776 × 400
```

### 2.1 官方能提供到哪一步

【文档明确】

- 根视图默认是"设备尺寸减安全区"（WWDC19 237 原话，见上）。所以 776×400 是**起点**，不是异常。
- 导航栏会计入安全区（`additionalSafeAreaInsets` 文档："an ancestor-provided view such as the navigation bar"）。
- `.toolbar(.hidden, for: .navigationBar)` 只是"hides the navigation bar"（"The preferred visibility flows up to the nearest container that renders a bar."），文档**没有**承诺隐藏后安全区一定归零。
  <https://developer.apple.com/documentation/swiftui/view/toolbar(_:for:)>
- `NavigationStack` 的文档**整篇没有提到 safe area**（Overview 只讲 push/pop/path）。
  <https://developer.apple.com/documentation/swiftui/navigationstack>
- `onGeometryChange` 的文档只说 `GeometryProxy` → 自定义类型的转换，**没说 `proxy.safeAreaInsets` 相对哪一层**。
  <https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)>

【文档未覆盖】所以第 2 问的核心——"NavigationStack destination 里 `onGeometryChange` 的 `proxy.safeAreaInsets` 是相对哪一层的"——**Apple 没有说明**。下面是从数字反推的模型。

### 2.2 【实测推断】一个能对上全部三个数字的模型

1. 页面所在槽位 = 安全区内的 776×400，原点在窗口 (68, 0)。
2. 页面根 `ZStack` 里的 `BarInk.ground.ignoresSafeArea()` 让这个 ZStack **接受了扩展后的 proposal**（这正是 §1.1 文档说的行为），于是 ZStack 的 bounds 变成 **912×420**。
3. 但 ZStack 的**位置**仍由父层（776×400 的槽）决定。一个比槽大的子视图落进居中的槽里：`y = (400 − 420) / 2 = −10`，`x = 68 + (776 − 912) / 2 = 0`。→ 这与 `stage global=(0, -10, 912, 420)` **逐位吻合**。
4. 于是这一层实际覆盖窗口 y ∈ [−10, 410]：顶部 10pt 越界（被切），底部 10pt 露背景。
5. `proxy.safeAreaInsets` 报 (0, 10, 0, 0)，与"**已经吞掉的部分不再上报，剩下的按这个视图自己的 bounds 裁剪**"这个模型自洽：左右 68 已被扩展吃掉 → 0；底部 20 里只有 [400,410] 这 10pt 还落在这层的 bounds 内 → 10。

第 5 条与 UIKit 的规则**同类**（`UIView.safeAreaInsets`："For other views in the view hierarchy, the insets reflect only the portion of the view that is covered"），但它是 UIKit 的规则，SwiftUI 是否照搬【文档未覆盖】——所以标注为实测推断。

### 2.3 结论：这不是"safe area 被部分消费"的官方概念

Apple 文档里**没有** "consumed safe area" 这种说法；`ignoresSafeArea` 的官方描述只有 "Expands the safe area of a view"。我们能说的是：

- **当前 `size + insets` 的算术前提（"insets 就是设备真实安全区"）不成立**，这是日志直接证明的；
- 因此 `.offset(x: -insets.leading, y: -insets.top)` 这条补偿在真机上变成了 `(0, 0)`——**等于没补偿**，-10 的错位完全没被修掉；
- 更根本的：**只要画布是放在一个"安全区大小"的槽里，任何尺寸的补偿都会遇到"超尺寸子视图被父层居中"的问题**（§1.1 的 "the child ultimately chooses its own size" + 父层的 alignment）。补偏移只是和布局系统打架。

---

## 3. 目标语义拆开看

要的是：

```
canvasHeight = windowHeight
canvasWidth  = canvasHeight × 16/9
canvasX      = (windowWidth − canvasWidth) / 2
canvasY      = 0
```

这与 `BarScreen.placement(_:)` 在 `insets: .none, callBar: 0` 时的公式完全一致：

```
scale = min(W/640, H/360)
left  = (W − 640·scale)/2
top   = (H − 360·scale)/2
```

横屏 912×420 → `scale = 420/360 = 1.1666…`（高先顶满），`left = (912 − 746.67)/2 = 82.67`，`top = 0`。
**所以代码里真正需要的只是"窗口的 W、H"，一个 inset 都不需要。**

问题全部集中在：**怎么让 SwiftUI 把"窗口的 W、H"给到画布所在的那一层**。

---

## 4. 问题 4（先答，因为它是依据）：Apple 官方怎么描述"定比例的游戏画布"

### 4.1 SpriteKit 的 `aspectFit` 就是我们要的公式

【文档明确】`SKSceneScaleMode.aspectFit`：

> "The scaling factor of each dimension is calculated and the smaller of the two is chosen. Each axis of the scene is scaled by the same scaling factor. **This guarantees that the entire scene is visible but may require letterboxing in the view.**"

<https://developer.apple.com/documentation/spritekit/skscenescalemode/aspectfit>

`SKScene.scaleMode` 的文档补充：

> "It is possible for a scene's size to differ from the size of the view it is presented in. The scale mode determines how the visible portion of the scene is mapped to the view. … The default value is `.fill`."

<https://developer.apple.com/documentation/spritekit/skscene/scalemode>

Apple 的 `SpriteView`（SwiftUI 里的 SpriteKit 宿主）就是把这个 scaleMode 交给 SKScene 自己算——**宿主视图给多大，scene 自己缩**。这正是"画布不要参与宿主尺寸决策"的官方范式：
<https://developer.apple.com/documentation/spritekit/spriteview>

（至于 `SpriteView` 的文档本身，只有一句抽象，没有 full-bleed 的例子——【文档未覆盖】。）

### 4.2 HIG 对"游戏/背景铺满"的要求

【文档明确】Human Interface Guidelines → Layout：

> "**For full-screen background content, be sure to extend it underneath sidebars, toolbars, and tab bars to fit the entire screen or window.**"

> "Even if your app is locked to a certain orientation, **such as a landscape-only game**, it's still important to ensure your interface resizes well to provide the best experience across devices and window sizes."

> "When necessary, scale background artwork in response to display changes. Viewing your app or game in a different context — such as on a screen with a different aspect ratio — might make your artwork appear cropped, letterboxed, or pillarboxed. **If this happens, don't change the aspect ratio of the artwork; instead, scale it so that it fills the screen completely.**"

<https://developer.apple.com/design/human-interface-guidelines/layout>

注意最后一条是针对**背景美术**（要 `.fill`，可以裁），而**游戏可玩内容**要的是 `aspectFit`（不能裁掉画面元素）。我们的 640×360 是可玩画布，所以走 `aspectFit` + 两侧留底色，这与 HIG 并不冲突：两侧的底色本身就该 `.fill`。

### 4.3 Apple 有没有 official sample 演示"全幅定比例画布"

【文档未覆盖】我在 developer.apple.com 的 SwiftUI/布局文档、WWDC 文稿里没有找到 "full-bleed fixed-aspect canvas" 的 sample。最接近的官方素材只有：

- `Adding a background to your view`（背景层 ignoresSafeArea，内容层不动）；
- SpriteKit 的 `aspectFit` 语义；
- HIG 的"全屏背景要延伸到 bar 下面"。

也就是说：**这个场景 Apple 没有给现成范例，得自己拼。**

---

## 5. 问题 3：推荐的实现（2–3 个候选 + 风险）

### 方案 A（推荐）：`GeometryReader` 在外、`.ignoresSafeArea()` 在更外，只量一次、只算 scale

```swift
var body: some View {
    GeometryReader { proxy in            // ① 尺寸由 proposal 决定，不受内容影响
        ZStack(alignment: .topLeading) {
            BarInk.ground                 // ② 底色铺满（此时已经是整窗）
            if isLoaded {
                BarStage(placement: placement) { screen }
                    .environment(\.barImages, images)
                    .coordinateSpace(name: BarDrag.space)
                    .overlay { if upright.isUpright { BarPortraitGuard() } }
            } else {
                ProgressView().tint(BarInk.sub)
            }
        }
        .onGeometryChange(for: BarFit.self) { p in
            BarFit(size: p.size, insets: p.safeAreaInsets)
        } action: { page in
            fit(into: page)
        }
    }
    .ignoresSafeArea()                   // ③ 把扩展后的 proposal 交给 GeometryReader
    .navigationBarBackButtonHidden(true)
    .toolbar(.hidden, for: .navigationBar)
    .statusBarHidden(true)
    ...
}

private func fit(into page: BarFit) {
    // page.size 现在应当 == 窗口尺寸（912×420），page.insets 应当 == 0
    guard page.size.width > 0, page.size.height > 0 else { return }
    upright.isUpright = page.size.height > page.size.width
    // insets 一律不参与：目标是「画布高 = 窗口高」，本来就没有要避让的区域
    let placed = BarScreen.placement(BarScreen.Viewport(
        width: Double(page.size.width), height: Double(page.size.height),
        pointer: .coarse                       // insets 用默认 .none，callBar 用默认 0
    ))
    if placed != placement { placement = placed }
    if page.insets != EdgeInsets() {
        NSLog("[layout] unexpected insets \(page.insets) size \(page.size)")  // 验收用
    }
}
```

官方依据：

- `.ignoresSafeArea()` 会把扩展后的尺寸作为 proposal 传下去 ——【文档明确】<https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:)>
- `GeometryReader` "returns a flexible preferred size to its parent layout"（接受 proposal，所以**尺寸与内容无关**，不会有反馈环）——【文档明确】<https://developer.apple.com/documentation/swiftui/geometryreader>
- `ZStack(alignment: .topLeading)` + 整窗尺寸的容器 ⇒ 左上角就是窗口左上角，**不需要任何 offset**。

为什么不会形成反馈环（这是上一版翻车的点）：反馈环来自"用被测量视图的尺寸去决定被测量视图的尺寸"。这里 `GeometryReader` 的尺寸**只来自 proposal**，`placement` 只影响里面的 `frame/offset/scaleEffect`，不改变 `GeometryReader` 的大小——链条是单向的。

已知风险（必须真机验证）：

- ③ 的扩展是否真的能到窗口边缘，取决于 destination 外面那层（NavigationStack / hosting controller）有没有先吃掉安全区。**文档没承诺**。验收方法见 §6。
- 首帧 `proxy.size` 可能是 0，`fit` 里已 guard。
- 写 `@State` 会触发一次额外布局，但因为不影响尺寸，收敛。

### 方案 B（A 验证失败时的退路）：把"全窗"当成外部事实，且**在 NavigationStack 之上**忽略安全区

如果 §6 量到 `proxy.size == 776×400`（说明扩展被上层截住），说明 **destination 这一层拿不到窗口**。此时不要试图用 offset 补偿（会被父层居中抵消，见 §2.3），而是把扩展点往上挪：

- 在 `NavigationStack` 外层（或酒吧页专用的容器）上加 `.ignoresSafeArea()`，让整栈拿到扩展 proposal；
- 或者在酒吧页改用 `fullScreenCover` 呈现：文档说它 "covers as much of the screen as possible"，<https://developer.apple.com/documentation/swiftui/view/fullscreencover(item:ondismiss:content:)>——注意 "as much as possible" **不是**硬承诺，里面仍然要 `.ignoresSafeArea()`。

风险：改动面到 `RootView` 或呈现方式，其他页面可能受影响；`fullScreenCover` 的语义不保证等于窗口。

### 方案 C（旁路，零布局猜测）：把画布交给 UIKit 的 `view.window.bounds`

`BarStage` 外面包一层 `UIViewRepresentable` 容器，在里面 `view.window?.bounds` 直接把子视图 `frame` 设成窗口大小、`clipsToBounds = true`。窗口尺寸是"事实"，不经过 SwiftUI 的 proposal。

官方依据：`UIView.safeAreaInsets` 说明"根视图的 insets 才含状态栏与各 bar"，`UIScreen.main` 已被 `UIWindowScene` 取代（见 §1.5）。

风险：要处理旋转、`viewDidLayoutSubviews` 时序、hit-testing 与 `coordinateSpace` 的衔接（`BarDrag.space` 现在依赖 SwiftUI 坐标空间），工程量最大。**不建议**，除非 A、B 都不成立。

### 明确不要做的（反例清单）

| 做法 | 为什么不行（官方依据） |
|---|---|
| 用 `containerRelativeFrame` 铺满 | 文档明说它**减掉**安全区："…subtracting any safe area insets that might be applied to that container" |
| 用 `safeAreaPadding` / `safeAreaInset` | 只会**增加**安全区（"Adds the provided insets into the safe area of this view."），方向相反 |
| 硬编码 10 / 20 / 68pt 补偿 | 机型、方向、是否隐藏状态栏都会变；Apple 从未把任何 inset 数值写进文档 |
| 用 `size + insets` 反推窗口 | 前提是"insets = 设备真实安全区"，真机日志已证伪（§2.2） |
| 在 destination 里 offset 补偿 | 超尺寸子视图会被父槽居中，补偿被抵消（§2.3） |
| 用 `UIScreen.main.bounds` | iOS 26 起已废弃（§1.5） |
| 用 `backgroundExtensionEffect` 铺画布 | 它是"镜像+模糊"的视觉效果，不是布局扩展（§1.6） |

---

## 6. 验证方法：真机上应该量到什么数

在 `fit(into:)` 里打三条日志（**这三条一起看才能定位**）：

```swift
NSLog("[layout] proxy size=\(page.size) insets=\(page.insets)")      // SwiftUI 视角
NSLog("[layout] stage  \(stageRect)")                                 // 画布层的 .global frame
NSLog("[layout] window \(window.bounds) safe=\(window.safeAreaInsets)") // UIKit 视角
```

iPhone Air 横屏（912×420 pt、底 20 / 侧 68）的期望值：

| 量 | 期望 | 说明 |
|---|---|---|
| proxy `size` | `(912, 420)` | 等于窗口，**不是** 776×400 |
| proxy `insets` | `(0, 0, 0, 0)` | **方案 A 成立与否的唯一判据** |
| stage `.global` frame | `(0, 0, 912, 420)` | 左上角在 (0,0)，帧高 == 窗口高 |
| placement | `scale = 1.1666…, left = 82.67, top = 0` | `420/360 = 1.1667`；`(912 − 746.67)/2 = 82.67` |
| 画布实际占据 | x ∈ [82.67, 829.33]，y ∈ [0, 420] | 上下贴边，左右各留 82.67 底色 |

**如果 `insets` 不是 0**：说明扩展没走到窗口，方案 A 不成立 → 转方案 B，并把这条日志留在代码里当回归哨兵。
**如果 `size` 是 776×400**：同上。
**如果 `stage.global` 的 y 是负数**：说明画布层仍在"安全区大小的槽"里，父层在居中它——检查 `.ignoresSafeArea()` 是不是加在了画布层的**外面**（顺序错了就白加）。

竖屏（420×912）期望：`size = (420, 912)`，`scale = min(420/640, 912/360) = 0.65625`，画布 `420 × 236.25`，`left = 0`，`top = (912 − 236.25)/2 = 337.875`。

旋转时：`onGeometryChange` 会带着新的 `size` 回调一次，`placement` 重算；**不要**在旋转动画里额外做补偿（`GeometryReader` 会自己重报）。

---

## 7. 文档没写、但这次必须记住的三件事

1. 【文档未覆盖】`GeometryProxy.safeAreaInsets` 在 `ignoresSafeArea` 之后报什么——没有文档，只能实测。
2. 【文档未覆盖】`NavigationStack` / `toolbar(.hidden)` / `statusBarHidden` 如何分配安全区——SwiftUI 侧没有说明；UIKit 侧只有"导航栏算 ancestor-provided view"这一句可类推。
3. 【文档明确但容易被忽略】`ignoresSafeArea` 的语义是"**给一个更大的 proposal**"，不是"强制铺满"。只要上游某一层把 proposal 收回去，它就没有效果——这正是我们踩到的坑。

---

## 8. 一手来源清单

文档（全部 developer.apple.com）：

- `ignoresSafeArea(_:edges:)` — /documentation/swiftui/view/ignoressafearea(_:edges:)
- `ignoresSafeArea(_:edges:alignment:)` — /documentation/swiftui/view/ignoressafearea(_:edges:alignment:)
- `edgesIgnoringSafeArea(_:)` — /documentation/swiftui/view/edgesignoringsafearea(_:)
- `SafeAreaRegions` / `.container` / `.keyboard` — /documentation/swiftui/safearearegions{,/container,/keyboard}
- `GeometryProxy.size` — /documentation/swiftui/geometryproxy/size
- `GeometryProxy.safeAreaInsets` — /documentation/swiftui/geometryproxy/safeareainsets
- `GeometryProxy.frame(in:)` — /documentation/swiftui/geometryproxy/frame(in:)
- `CoordinateSpace.global` — /documentation/swiftui/coordinatespace/global
- `GeometryReader` — /documentation/swiftui/geometryreader
- `onGeometryChange(for:of:action:)` — /documentation/swiftui/view/ongeometrychange(for:of:action:)
- `safeAreaInset(edge:alignment:spacing:content:)` — /documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)
- `safeAreaPadding(_:)` — /documentation/swiftui/view/safeareapadding(_:)
- `containerRelativeFrame(_:alignment:_:)` — /documentation/swiftui/view/containerrelativeframe(_:alignment:_:)
- `safeAreaBar(edge:alignment:spacing:content:)`（iOS 26）— /documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:)
- `backgroundExtensionEffect()`（iOS 26）— /documentation/swiftui/view/backgroundextensioneffect()
- `toolbarMinimizationSafeAreaAdjustment(_:for:)`（iOS 27）— /documentation/swiftui/view/toolbarminimizationsafeareaadjustment(_:for:)
- `windowResizeBehavior(_:)`（macOS 15）— /documentation/swiftui/view/windowresizebehavior(_:)
- `statusBarHidden(_:)` — /documentation/swiftui/view/statusbarhidden(_:)
- `ToolbarPlacement.statusBar` — /documentation/swiftui/toolbarplacement/statusbar
- `toolbarVisibility(_:for:)` — /documentation/swiftui/view/toolbarvisibility(_:for:)
- `persistentSystemOverlays(_:)`（隐藏 home indicator 的"偏好"）— /documentation/swiftui/view/persistentsystemoverlays(_:)
- `toolbar(_:for:)` — /documentation/swiftui/view/toolbar(_:for:)
- `NavigationStack` — /documentation/swiftui/navigationstack
- `fullScreenCover(item:onDismiss:content:)` — /documentation/swiftui/view/fullscreencover(item:ondismiss:content:)
- `Layout adjustments` — /documentation/swiftui/layout-adjustments
- `Adding a background to your view` — /documentation/swiftui/adding-a-background-to-your-view
- `UIView.safeAreaInsets` — /documentation/uikit/uiview/safeareainsets
- `UIViewController.additionalSafeAreaInsets` — /documentation/uikit/uiviewcontroller/additionalsafeareainsets
- `UIScreen.main`（iOS 26 废弃）— /documentation/uikit/uiscreen/main
- `UIScreen.bounds` — /documentation/uikit/uiscreen/bounds
- `UIWindowScene` — /documentation/uikit/uiwindowscene
- `UIHostingController` — /documentation/swiftui/uihostingcontroller
- `SKSceneScaleMode.aspectFit` — /documentation/spritekit/skscenescalemode/aspectfit
- `SKScene.scaleMode` — /documentation/spritekit/skscene/scalemode
- `SpriteView` — /documentation/spritekit/spriteview
- HIG Layout — <https://developer.apple.com/design/human-interface-guidelines/layout>

WWDC 文稿：

- WWDC19 237 *Building Custom Views with SwiftUI* — <https://developer.apple.com/videos/play/wwdc2019/237/>
- WWDC25 256 *What's new in SwiftUI* — <https://developer.apple.com/videos/play/wwdc2025/256/>（全文无 safe area）
- WWDC25 323 *Build a SwiftUI app with the new design* — <https://developer.apple.com/videos/play/wwdc2025/323/>
- WWDC26 269 *What's new in SwiftUI* — <https://developer.apple.com/videos/play/wwdc2026/269/>（全文无 safe area）
