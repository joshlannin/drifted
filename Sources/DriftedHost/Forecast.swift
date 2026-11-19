import DriftedKit
import Foundation
import Security
#if canImport(WeatherKit)
import CoreLocation
import WeatherKit
#endif

/// Today's forecast for the weather picture: WeatherKit when this build is entitled to it (a Developer ID build
/// made with DRIFTED_PROVISIONING_PROFILE, see scripts/build-host-app.sh), else Open-Meteo (free, no key).
struct Forecast {
    var source: String          // "weatherkit" or "open-meteo"
    var raw: String             // the source's own condition (WeatherKit name or WMO code)
    var condition: WeatherPicture.Condition
    var high: Int               // today's high, in the schedule's units

    var json: [String: Any] { ["source": source, "raw": raw, "condition": condition.rawValue, "high": high] }

    /// True when the running app carries the WeatherKit entitlement (only an app bundle signed with a profile can).
    static var weatherKitAvailable: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, "com.apple.developer.weatherkit" as CFString, nil) as? Bool) == true
    }

    /// Tries WeatherKit (if entitled), then Open-Meteo. `log` hears why a source was skipped.
    static func today(latitude: Double, longitude: Double, fahrenheit: Bool, log: (String) -> Void) async throws -> Forecast {
        #if canImport(WeatherKit)
        if weatherKitAvailable {
            do { return try await weatherKit(latitude: latitude, longitude: longitude, fahrenheit: fahrenheit) }
            catch { log("schedule: WeatherKit failed (\(error.localizedDescription)); trying Open-Meteo") }
        }
        #endif
        return try await openMeteo(latitude: latitude, longitude: longitude, fahrenheit: fahrenheit)
    }

    #if canImport(WeatherKit)
    static func weatherKit(latitude: Double, longitude: Double, fahrenheit: Bool) async throws -> Forecast {
        let daily = try await withTimeout(30) {
            try await WeatherService.shared.weather(for: CLLocation(latitude: latitude, longitude: longitude), including: .daily)
        }
        let now = Date()
        guard let day = daily.forecast.first(where: { $0.date <= now && now < $0.date.addingTimeInterval(86400) }) ?? daily.forecast.first
        else { throw ForecastError("WeatherKit returned no days") }
        let high = day.highTemperature.converted(to: fahrenheit ? .fahrenheit : .celsius).value
        return Forecast(source: "weatherkit", raw: day.condition.rawValue,
                        condition: WeatherPicture.Condition(weatherKit: day.condition.rawValue), high: Int(high.rounded()))
    }
    #endif

    /// https://open-meteo.com — today's WMO weather code (the day's most significant weather) and maximum.
    static func openMeteo(latitude: Double, longitude: Double, fahrenheit: Bool) async throws -> Forecast {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ForecastError("Open-Meteo answered \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return try parseOpenMeteo(data)
    }

    static func parseOpenMeteo(_ data: Data) throws -> Forecast {
        struct Body: Decodable {
            struct Daily: Decodable { var weather_code: [Int?]; var temperature_2m_max: [Double?] }
            var daily: Daily
        }
        let d = try JSONDecoder().decode(Body.self, from: data).daily
        guard let code = d.weather_code.first ?? nil, let high = d.temperature_2m_max.first ?? nil else {
            throw ForecastError("Open-Meteo returned no forecast for today")
        }
        return Forecast(source: "open-meteo", raw: "wmo \(code)", condition: WeatherPicture.Condition(wmo: code), high: Int(high.rounded()))
    }

    private static func withTimeout<T>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                throw ForecastError("no answer in \(Int(seconds)) s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

struct ForecastError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
