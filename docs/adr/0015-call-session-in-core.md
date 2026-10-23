# 通话状态机在核心包里，音频与语音服务注入

通话的听 / 想 / 说状态机、回合记录、时限放在 `EidolonCore` 的 `CallSession` 里；麦克风采集、实时识别、语音合成走注入协议（音频输入输出、`SpeechRecognition`、`SpeechSynthesis`），App 层只提供 AVAudioEngine、Soniox WebSocket、Fish Audio 播放的实现和界面。

**考虑过的选项**：整个通话放在 App 层（离 AVAudioEngine 近、少一层抽象，但状态机无法在测试里跑，回合记录和引擎耦合）；用上游的 Pipecat 客户端（起止、打断由框架定，和 ADR-0007 自己实现的决策冲突，还得把回合引擎塞进它的管线）。

**后果**：通话状态机可以用假音频、假识别、假合成在测试里跑，模拟器上开发只需换 App 层的实现；回声消除、音频路由、重连这些平台细节留在 App 层；换识别或合成供应商只改 App 层实现。
