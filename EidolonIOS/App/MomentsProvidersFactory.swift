import EidolonCore

/// The one place a moments run's providers are assembled: the foreground loop and the
/// background task must see exactly the same models and switches.
enum MomentsProvidersFactory {
    static func make(
        chat: any ChatProvider,
        photo: PhotoTurnContext?,
        settings: ChatSettings,
        weather: any MomentWeatherProviding,
        debugMode: Bool
    ) -> MomentsProviders {
        let gpt = settings.gptImageSettings
        return MomentsProviders(
            chat: chat,
            photo: photo,
            weather: weather,
            gptImage: gpt.enabled ? RemoteGPTImageGenerator() : nil,
            gptSettings: gpt,
            adultMode: settings.adultMode,
            debugMode: debugMode
        )
    }
}
