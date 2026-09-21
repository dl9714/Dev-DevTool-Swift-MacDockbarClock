import Foundation

let suiteName = "WeatherCalendarTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
let home = WeatherParser(location: .home, defaults: defaults)
let losAngeles = WeatherLocation(name: "Los Angeles", detail: "USA", latitude: 34.05, longitude: -118.24, timeZoneIdentifier: "America/Los_Angeles")
let travel = WeatherParser(location: losAngeles, defaults: defaults)
let fixture: [String: Any] = [
    "current": ["temp": 27, "cap": "맑음"],
    "forecast": ["days": [[
        "daily": ["valid": "2026-09-21T00:00:00+09:00", "tempHi": 30, "tempLo": 18, "precip": 10, "pvdrCap": "맑음"],
        "hourly": [["valid": "2026-09-21T00:00:00+09:00", "temp": 20, "precip": 5, "cap": "맑음"]]
    ]]]
]
let homeDays = home.parseForecastDays(from: fixture)
let travelDays = travel.parseForecastDays(from: fixture)
precondition(homeDays.first?.dateKey == "2026-09-21", "Home date must use Seoul time")
precondition(travelDays.first?.dateKey == "2026-09-20", "Travel date must use local time across date boundaries")
precondition(homeDays.first?.hours[0].temperature == 20)
precondition(travelDays.first?.hours[8].temperature == 20, "Travel hours must use local time")
precondition(travelDays.first?.hours[0].temperature == nil, "Missing hours must not be reported as observations")
precondition(WeatherLocation.home.cacheKey == "DockClockWeatherHourlyCacheV1", "Existing home history must be retained")
precondition(WeatherLocation.home.cacheKey != losAngeles.cacheKey)
home.saveCachedHours(days: homeDays, existingCache: [:])
precondition(!home.loadCachedHours().isEmpty)
precondition(travel.loadCachedHours().isEmpty, "A new travel location must not read home weather")
let savedHome = home.loadCachedHours()
travel.saveCachedHours(days: travelDays, existingCache: [:])
precondition(!travel.loadCachedHours().isEmpty)
precondition(home.loadCachedHours() == savedHome, "Saving travel weather must not change home history")
precondition(travel.prependYesterday(to: travelDays, cache: [:]) == travelDays, "New locations must not fabricate yesterday from today's forecast")
precondition(travel.snapshot(from: [:]) == nil, "Malformed weather must produce an error")
precondition(travel.snapshot(from: ["current": ["temp": 27]]) == nil, "Missing daily forecasts must produce an error")
let encoded = try JSONEncoder().encode(losAngeles)
let decoded = try JSONDecoder().decode(WeatherLocation.self, from: encoded)
precondition(decoded == losAngeles)
precondition(travel.weatherIcon(for: "폭우") == "🌧️", "Heavy rain must have a rain icon")
print("PASS: local dates/hours, home cache compatibility, location isolation, missing data, recent-location persistence")
