import Foundation

/// Tokyo's weather at a moment, from Open-Meteo: no key, no account, and no proxy of its
/// own (spec #98). One reading is kept for three hours; after a failure the client waits
/// ten minutes before asking again, and a moment without weather simply shows none.
public actor OpenMeteoWeatherClient: MomentWeatherProviding {
    public struct Coordinates: Sendable, Hashable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        public static let tokyo = Coordinates(latitude: 35.6812, longitude: 139.7671)
    }

    private struct Entry {
        var weather: MomentWeather
        var at: Date
    }

    private let coordinates: Coordinates
    private let session: URLSession
    private let cacheLifetime: TimeInterval = 3 * 3600
    private let retryAfter: TimeInterval = 10 * 60
    private var cached: Entry?
    private var lastFailure: Date?

    public init(
        coordinates: Coordinates = .tokyo,
        session: URLSession = URLSession(configuration: .default)
    ) {
        self.coordinates = coordinates
        self.session = session
    }

    public func weather(at date: Date) async -> MomentWeather? {
        if let cached, abs(date.timeIntervalSince(cached.at)) < cacheLifetime {
            return cached.weather
        }
        if let lastFailure, date.timeIntervalSince(lastFailure) < retryAfter {
            return nil
        }
        guard let url = URL(string: """
            https://api.open-meteo.com/v1/forecast?latitude=\(coordinates.latitude)\
            &longitude=\(coordinates.longitude)&current=temperature_2m,weather_code\
            &timezone=Asia%2FTokyo
            """) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { throw URLError(.badServerResponse) }
            struct Answer: Decodable {
                struct Current: Decodable {
                    var temperature_2m: Double
                    var weather_code: Int
                }
                var current: Current
            }
            let answer = try JSONDecoder().decode(Answer.self, from: data)
            let weather = MomentWeather(
                kind: MomentWeather.Kind.from(wmo: answer.current.weather_code),
                temperature: Int(answer.current.temperature_2m.rounded())
            )
            cached = Entry(weather: weather, at: date)
            lastFailure = nil
            return weather
        } catch {
            lastFailure = date
            return nil
        }
    }
}
