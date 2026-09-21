import Foundation

struct ForecastDay: Equatable {
    let dateKey: String
    let dateText: String
    let weekdayText: String
    let hourlyTitle: String
    let icon: String
    let condition: String
    let highTemp: Int
    let lowTemp: Int
    let precipitation: Int
    let summary: String
    let hours: [ForecastHour]
}

extension ForecastDay {
    func replacingHours(_ hours: [ForecastHour]) -> ForecastDay {
        ForecastDay(
            dateKey: dateKey,
            dateText: dateText,
            weekdayText: weekdayText,
            hourlyTitle: hourlyTitle,
            icon: icon,
            condition: condition,
            highTemp: highTemp,
            lowTemp: lowTemp,
            precipitation: precipitation,
            summary: summary,
            hours: hours
        )
    }
}

struct ForecastHour: Codable, Equatable {
    let hour: Int
    let timeText: String
    let icon: String
    let temperature: Int?
    let precipitation: Int?
    let condition: String
}

struct WeatherLocation: Codable, Equatable {
    let name: String
    let detail: String
    let latitude: Double
    let longitude: Double
    let timeZoneIdentifier: String

    static let home = WeatherLocation(name: "수원 인계동", detail: "기본 지역", latitude: 37.2596985, longitude: 127.0270274, timeZoneIdentifier: "Asia/Seoul")
    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "Asia/Seoul")! }
    var id: String { String(format: "%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude) }
    var isHome: Bool { id == Self.home.id }
    var cacheKey: String { isHome ? "DockClockWeatherHourlyCacheV1" : "DockClockWeatherHourlyCacheV2.\(id).\(timeZoneIdentifier)" }
}

struct WeatherSnapshot {
    let temperature: Int
    let icon: String
    let hours: [ForecastHour]
    let days: [ForecastDay]
}

enum WeatherLoadError: LocalizedError {
    case missingKey, unavailable
    var errorDescription: String? {
        switch self {
        case .missingKey: return "날씨 연결 설정을 확인해 주세요."
        case .unavailable: return "예보를 불러오지 못했습니다. 잠시 후 다시 시도해 주세요."
        }
    }
}

enum WeatherService {
    @discardableResult
    static func load(location: WeatherLocation, completion: @escaping (Result<WeatherSnapshot, Error>) -> Void) -> URLSessionDataTask? {
        let key = ProcessInfo.processInfo.environment["MSN_WEATHER_API_KEY"] ?? UserDefaults.standard.string(forKey: "MSNWeatherAPIKey")
        guard let key, !key.isEmpty else {
            DispatchQueue.main.async { completion(.failure(WeatherLoadError.missingKey)) }
            return nil
        }
        var components = URLComponents(string: "https://api.msn.com/weather/overview")!
        components.queryItems = [
            "appId": "9e21380c-ff19-4c78-b4ea-19558e93a5d3", "apiKey": key,
            "ocid": "superapp-hp-weather", "wrapOData": "false", "feature": "lifeday",
            "lifeDays": "15", "lifeModes": "2", "locale": "ko-kr", "units": "C", "days": "15",
            "lat": String(location.latitude), "lon": String(location.longitude)
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        let request = URLRequest(url: components.url!, timeoutInterval: 20)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<WeatherSnapshot, Error>
            if error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
               let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let responses = json["responses"] as? [[String: Any]],
               let weather = (responses.first?["weather"] as? [[String: Any]])?.first,
               let snapshot = WeatherParser(location: location).snapshot(from: weather) {
                result = .success(snapshot)
            } else {
                result = .failure(WeatherLoadError.unavailable)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }
}

final class WeatherParser {
    func snapshot(from weather: [String: Any]) -> WeatherSnapshot? {
        guard let current = weather["current"] as? [String: Any], let temperature = intValue(current["temp"]) else { return nil }
        let condition = stringValue(current["cap"]) ?? stringValue(current["pvdrCap"]) ?? ""
        let icon = weatherIcon(for: condition)
        let currentHour = weatherCalendar.component(.hour, from: Date())
        let now = ForecastHour(hour: currentHour, timeText: hourLabel(for: currentHour), icon: icon, temperature: temperature, precipitation: intValue(current["precip"]) ?? 0, condition: condition)
        let cache = loadCachedHours()
        let parsed = parseForecastDays(from: weather)
        guard !parsed.isEmpty else { return nil }
        let history = prependCachedHistory(to: prependYesterday(to: parsed, cache: cache), cache: cache)
        let merged = mergeCachedHours(in: history, currentHour: now, cache: cache)
        saveCachedHours(days: merged, existingCache: cache)
        let days = fillMissingHours(in: merged)
        let hours = days.first(where: { $0.dateKey == dateKey(for: Date()) })?.hours ?? days.first?.hours ?? []
        return WeatherSnapshot(temperature: temperature, icon: icon, hours: hours, days: days)
    }
    func parseForecastHours(from weather: [String: Any]) -> [ForecastHour] {
        guard
            let forecast = weather["forecast"] as? [String: Any],
            let days = forecast["days"] as? [[String: Any]],
            let firstDay = days.first
        else {
            return []
        }

        return parseForecastHours(fromDay: firstDay)
    }

    func parseForecastHours(fromDay dayData: [String: Any]) -> [ForecastHour] {
        guard let hourly = dayData["hourly"] as? [[String: Any]] else {
            return []
        }

        let calendar = weatherCalendar

        let parsed = hourly.compactMap { hourData -> (Int, ForecastHour)? in
            guard
                let validText = stringValue(hourData["valid"]),
                let date = weatherISOFormatter.date(from: validText)
            else {
                return nil
            }

            let hour = calendar.component(.hour, from: date)
            let condition = stringValue(hourData["cap"]) ?? stringValue(hourData["pvdrCap"]) ?? "예보 없음"
            return (
                hour,
                ForecastHour(
                    hour: hour,
                    timeText: hourLabel(for: hour),
                    icon: weatherIcon(for: condition),
                    temperature: intValue(hourData["temp"]) ?? 0,
                    precipitation: intValue(hourData["precip"]) ?? 0,
                    condition: condition
                )
            )
        }

        var byHour: [Int: ForecastHour] = [:]
        for (hour, forecast) in parsed {
            byHour[hour] = forecast
        }
        return (0..<24).map { hour in
            byHour[hour] ?? ForecastHour(
                hour: hour,
                timeText: hourLabel(for: hour),
                icon: "·",
                temperature: nil,
                precipitation: nil,
                condition: "예보 없음"
            )
        }
    }

    func hourLabel(for hour: Int) -> String {
        if hour < 12 {
            return "오전 \(hour)시"
        }
        if hour == 12 {
            return "오후 12시"
        }
        return "오후 \(hour - 12)시"
    }

    func parseForecastDays(from weather: [String: Any]) -> [ForecastDay] {
        guard
            let forecast = weather["forecast"] as? [String: Any],
            let days = forecast["days"] as? [[String: Any]]
        else {
            return []
        }

        return days.compactMap { dayData in
            guard let daily = dayData["daily"] as? [String: Any] else { return nil }
            let day = daily["day"] as? [String: Any]
            let night = daily["night"] as? [String: Any]

            let condition = stringValue(daily["pvdrCap"])
                ?? stringValue(day?["cap"])
                ?? stringValue(night?["cap"])
                ?? "예보 없음"
            let summary = stringValue(day?["summary"])
                ?? stringValue(night?["summary"])
                ?? condition
            let validText = stringValue(daily["valid"])
            let date = validText.flatMap { weatherISOFormatter.date(from: $0) }
            let dateText = date.map { weatherShortDateFormatter.string(from: $0) } ?? ""
            let dateKey = date.map { self.dateKey(for: $0) } ?? dateText
            let weekdayText = date.map { weatherWeekdayFormatter.string(from: $0) } ?? ""
            let hourlyTitle = date.map { weatherHourlyTitleFormatter.string(from: $0) } ?? dateText
            let hours = parseForecastHours(fromDay: dayData)

            return ForecastDay(
                dateKey: dateKey,
                dateText: dateText,
                weekdayText: weekdayText,
                hourlyTitle: hourlyTitle,
                icon: weatherIcon(for: condition),
                condition: condition,
                highTemp: intValue(daily["tempHi"]) ?? 0,
                lowTemp: intValue(daily["tempLo"]) ?? 0,
                precipitation: intValue(daily["precip"]) ?? 0,
                summary: summary,
                hours: hours
            )
        }
    }

    func prependYesterday(to days: [ForecastDay], cache: [String: ForecastHour]) -> [ForecastDay] {
        guard let firstDay = days.first else { return days }
        guard let yesterday = weatherCalendar.date(byAdding: .day, value: -1, to: Date()) else {
            return days
        }

        let yesterdayKey = dateKey(for: yesterday)
        if firstDay.dateKey == yesterdayKey {
            return days
        }

        let cachedHours = cachedHours(for: yesterdayKey, cache: cache)
        let availableHours = cachedHours.filter { $0.temperature != nil }
        guard !availableHours.isEmpty else { return days }
        let highTemp = availableHours.compactMap(\.temperature).max() ?? firstDay.highTemp
        let lowTemp = availableHours.compactMap(\.temperature).min() ?? firstDay.lowTemp
        let representativeHour = availableHours.last ?? availableHours.first
        let precipitation = availableHours.compactMap(\.precipitation).max() ?? firstDay.precipitation
        let yesterdayDay = ForecastDay(
            dateKey: yesterdayKey,
            dateText: formattedDate(yesterday, format: "M.d"),
            weekdayText: formattedDate(yesterday, format: "E"),
            hourlyTitle: formattedDate(yesterday, format: "M.d E"),
            icon: representativeHour?.icon ?? firstDay.icon,
            condition: representativeHour?.condition ?? firstDay.condition,
            highTemp: highTemp,
            lowTemp: lowTemp,
            precipitation: precipitation,
            summary: representativeHour?.condition ?? firstDay.summary,
            hours: cachedHours
        )

        return [yesterdayDay] + days
    }

    func prependCachedHistory(to days: [ForecastDay], cache: [String: ForecastHour]) -> [ForecastDay] {
        guard let firstDay = days.first else { return days }
        let existingDateKeys = Set(days.map(\.dateKey))
        let cachedDateKeys = Set(cache.keys.compactMap { key -> String? in
            guard key.count >= 10 else { return nil }
            return String(key.prefix(10))
        })

        let previousDays = cachedDateKeys
            .filter { dateKey in
                dateKey < firstDay.dateKey && !existingDateKeys.contains(dateKey)
            }
            .sorted()
            .suffix(14)
            .compactMap { cachedDay(from: $0, fallback: firstDay, cache: cache) }

        return previousDays + days
    }

    func cachedDay(from dateKey: String, fallback: ForecastDay, cache: [String: ForecastHour]) -> ForecastDay? {
        let hours = (0..<24).map { hour in
            cache[hourCacheKey(dateKey: dateKey, hour: hour)] ?? ForecastHour(
                hour: hour,
                timeText: hourLabel(for: hour),
                icon: "·",
                temperature: nil,
                precipitation: nil,
                condition: "예보 없음"
            )
        }
        let availableHours = hours.filter { $0.temperature != nil }
        guard !availableHours.isEmpty else { return nil }

        let date = date(fromKey: dateKey) ?? Date()
        let representativeHour = availableHours.last ?? availableHours.first
        return ForecastDay(
            dateKey: dateKey,
            dateText: formattedDate(date, format: "M.d"),
            weekdayText: formattedDate(date, format: "E"),
            hourlyTitle: formattedDate(date, format: "M.d E"),
            icon: representativeHour?.icon ?? fallback.icon,
            condition: representativeHour?.condition ?? fallback.condition,
            highTemp: availableHours.compactMap(\.temperature).max() ?? fallback.highTemp,
            lowTemp: availableHours.compactMap(\.temperature).min() ?? fallback.lowTemp,
            precipitation: availableHours.compactMap(\.precipitation).max() ?? fallback.precipitation,
            summary: representativeHour?.condition ?? fallback.summary,
            hours: hours
        )
    }

    func cachedHours(for dateKey: String, cache: [String: ForecastHour]) -> [ForecastHour] {
        return (0..<24).map { hour in
            cache[hourCacheKey(dateKey: dateKey, hour: hour)] ?? ForecastHour(
                hour: hour,
                timeText: hourLabel(for: hour),
                icon: "·",
                temperature: nil,
                precipitation: nil,
                condition: "예보 없음"
            )
        }
    }

    func formattedDate(_ date: Date, format: String) -> String {
        switch format {
        case "M.d":
            return weatherShortDateFormatter.string(from: date)
        case "E":
            return weatherWeekdayFormatter.string(from: date)
        case "M.d E":
            return weatherHourlyTitleFormatter.string(from: date)
        default:
            let formatter = DateFormatter()
            formatter.locale = weatherKoreanLocale
            formatter.timeZone = weatherTimeZone
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
    }

    let weatherTimeZone: TimeZone
    let cacheKey: String
    private let defaults: UserDefaults

    init(location: WeatherLocation, defaults: UserDefaults = .standard) {
        weatherTimeZone = location.timeZone
        cacheKey = location.cacheKey
        self.defaults = defaults
    }
    private let weatherKoreanLocale = Locale(identifier: "ko_KR")
    private let weatherPOSIXLocale = Locale(identifier: "en_US_POSIX")
    private let weatherISOFormatter = ISO8601DateFormatter()
    private lazy var weatherShortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = weatherKoreanLocale
        formatter.timeZone = weatherTimeZone
        formatter.dateFormat = "M.d"
        return formatter
    }()
    private lazy var weatherWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = weatherKoreanLocale
        formatter.timeZone = weatherTimeZone
        formatter.dateFormat = "E"
        return formatter
    }()
    private lazy var weatherHourlyTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = weatherKoreanLocale
        formatter.timeZone = weatherTimeZone
        formatter.dateFormat = "M.d E"
        return formatter
    }()
    private lazy var weatherKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = weatherPOSIXLocale
        formatter.timeZone = weatherTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private lazy var weatherCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = weatherTimeZone
        return calendar
    }()

    func dateKey(for date: Date) -> String {
        weatherKeyFormatter.string(from: date)
    }

    func date(fromKey dateKey: String) -> Date? {
        weatherKeyFormatter.date(from: dateKey)
    }

    func hourCacheKey(dateKey: String, hour: Int) -> String {
        "\(dateKey)-\(String(format: "%02d", hour))"
    }

    func loadCachedHours() -> [String: ForecastHour] {
        guard
            let data = defaults.data(forKey: cacheKey),
            let decoded = try? JSONDecoder().decode([String: ForecastHour].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    func saveCachedHours(days: [ForecastDay], existingCache: [String: ForecastHour]) {
        var cache = existingCache
        for day in days {
            for hour in day.hours where hour.temperature != nil {
                cache[hourCacheKey(dateKey: day.dateKey, hour: hour.hour)] = hour
            }
        }

        if cache.count > 720 {
            for key in cache.keys.sorted().dropLast(720) {
                cache.removeValue(forKey: key)
            }
        }

        guard cache != existingCache else { return }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    func mergeCachedHours(in days: [ForecastDay], currentHour: ForecastHour, cache: [String: ForecastHour]) -> [ForecastDay] {
        let todayKey = dateKey(for: Date())

        return days.map { day in
            var merged = day.hours.map { hour -> ForecastHour in
                if hour.temperature != nil {
                    return hour
                }
                return cache[hourCacheKey(dateKey: day.dateKey, hour: hour.hour)] ?? hour
            }

            if day.dateKey == todayKey, merged.indices.contains(currentHour.hour), merged[currentHour.hour].temperature == nil {
                merged[currentHour.hour] = currentHour
            }

            return day.replacingHours(merged)
        }
    }

    func fillMissingHours(in days: [ForecastDay]) -> [ForecastDay] {
        days.map { day in
            day.replacingHours(fillMissingHours(day.hours, for: day))
        }
    }

    func fillMissingHours(_ hours: [ForecastHour], for day: ForecastDay) -> [ForecastHour] {
        guard !hours.isEmpty else { return hours }
        let available = hours.filter { $0.temperature != nil }

        return hours.map { hour in
            guard hour.temperature == nil else { return hour }

            let previous = available.last { $0.hour < hour.hour }
            let next = available.first { $0.hour > hour.hour }
            let reference = nearestReference(for: hour.hour, previous: previous, next: next)
            let temperature = estimatedTemperature(for: hour.hour, day: day, previous: previous, next: next)

            return ForecastHour(
                hour: hour.hour,
                timeText: hour.timeText,
                icon: reference?.icon ?? day.icon,
                temperature: temperature,
                precipitation: reference?.precipitation ?? day.precipitation,
                condition: reference?.condition ?? day.condition
            )
        }
    }

    func nearestReference(for hour: Int, previous: ForecastHour?, next: ForecastHour?) -> ForecastHour? {
        guard let previous else { return next }
        guard let next else { return previous }
        return hour - previous.hour <= next.hour - hour ? previous : next
    }

    func estimatedTemperature(for hour: Int, day: ForecastDay, previous: ForecastHour?, next: ForecastHour?) -> Int {
        if
            let previous,
            let next,
            let previousTemp = previous.temperature,
            let nextTemp = next.temperature
        {
            let span = max(1, next.hour - previous.hour)
            let progress = Double(hour - previous.hour) / Double(span)
            return Int((Double(previousTemp) + (Double(nextTemp - previousTemp) * progress)).rounded())
        }

        if let next, let nextTemp = next.temperature {
            let anchorHour = min(6, max(0, next.hour - 4))
            let span = max(1, next.hour - anchorHour)
            let progress = min(1, max(0, Double(hour - anchorHour) / Double(span)))
            return Int((Double(day.lowTemp) + (Double(nextTemp - day.lowTemp) * progress)).rounded())
        }

        if let previous, let previousTemp = previous.temperature {
            let span = max(1, 23 - previous.hour)
            let progress = min(1, max(0, Double(hour - previous.hour) / Double(span)))
            return Int((Double(previousTemp) + (Double(day.lowTemp - previousTemp) * progress)).rounded())
        }

        return day.lowTemp
    }

    func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value.rounded())
        }
        if let value = value as? NSNumber {
            return Int(truncating: value)
        }
        if let value = value as? String, let doubleValue = Double(value) {
            return Int(doubleValue.rounded())
        }
        return nil
    }

    func weatherIcon(for condition: String) -> String {
        if condition.contains("뇌우") || condition.contains("천둥") {
            return "⛈️"
        }
        if condition.contains("눈") {
            return "🌨️"
        }
        if condition.contains("비") || condition.contains("소나기") || condition.contains("폭우") || condition.contains("호우") || condition.contains("강우") {
            return "🌧️"
        }
        if condition.contains("안개") {
            return "🌫️"
        }
        if condition.contains("흐림") || condition.contains("흐린") {
            return "☁️"
        }
        if condition.contains("구름") || condition.contains("부분") {
            return "🌤️"
        }
        if condition.contains("맑") {
            return "☀️"
        }
        return "⛅"
    }

}
