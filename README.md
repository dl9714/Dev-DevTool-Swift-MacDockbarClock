# Mac-dockbar clock

Small always-on-top clock, weather, date, and calendar widget positioned above the bottom-right Dock area.

- Click the weather area to open or close the forecast panel. Date forecasts appear at the top, and the selected date's 24-hour forecast appears below.
- The date list shows seven dates at a time. Scroll or use the arrow buttons to see more dates; click a date to update the hourly forecast, or click "오늘" to return to today.
- Blue and orange temperatures indicate the daily low and high. Range bars share a common scale, and precipitation values are probabilities.
- Close the forecast with its close button, Escape, or a right-click.
- The widget always shows the default location, **수원 인계동**. The forecast also opens at this location every time.
- Click **지역 검색** to find a city, neighborhood, or travel destination, then select the matching address. Press Enter or click **검색** to submit a query. **기본 지역** returns to 수원 인계동 immediately.
- The search window keeps four recently selected destinations. Searching a destination does not change the default location or request access to the device's current location.
- Travel forecasts use the destination's time zone when available; the subtitle explicitly says **한국 시간** if it is unavailable. Cached forecasts are separated by location, preserving existing Suwon history.
- Click the time/date area to open or close the calendar.
- Right-click the widget to open a context menu with "세부 설정..." and "종료".
- In "세부 설정...", toggle seconds display and launch at login.
- In the calendar, click the arrow buttons to move between months and click "오늘" to return to the current month.
- Drag the widget to move it.

## Weather configuration

Weather requests use a local preference instead of a credential committed to source control:

```bash
defaults write local.mac.dockbar.clock MSNWeatherAPIKey "YOUR_API_KEY"
```

For development runs, `MSN_WEATHER_API_KEY` can be supplied as an environment variable instead.

## Build

The app is native Swift/AppKit. On an Apple Silicon Mac with Xcode Command Line Tools, run `./build_app.sh` to compile and ad-hoc sign a staged app in `build/` and create `dist/WeatherCalendar-macOS.zip`. The build script does not replace the installed app.

Current build: **2026.09.21.008**. The build number is visible in the forecast footer.

Location search uses Apple's [MKLocalSearch](https://developer.apple.com/documentation/mapkit/mklocalsearch). It requires an internet connection, without an additional API key. Weather continues to use the existing local MSN key.

To run the focused data regression checks:

```bash
mkdir -p build/tests
xcrun swiftc DockClockSwift/WeatherService.swift tests/main.swift -o build/tests/weather-tests
build/tests/weather-tests
```

The checks cover local dates and hours, separate location caches, compatibility with existing home history, missing forecast data, and recent-location serialization. They use an isolated preferences suite.
