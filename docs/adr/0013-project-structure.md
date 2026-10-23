# 一个 EidolonCore 包加 App target

模型、存储（GRDB）、对话引擎、检索和 provider 协议放在本地 Swift Package `EidolonCore` 里，不依赖 SwiftUI 和 AVFoundation；App target 只负责界面与音频设备。

**考虑过的选项**：单 target 分目录（引擎无法脱离 UI 测试，ADR-0012 的对照就做不了）；拆成多个包（自用规模下只是互相加依赖）。
