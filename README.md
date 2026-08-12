# Mac-dockbar clock

Small always-on-top clock, weather, date, and calendar widget positioned above the bottom-right Dock area.

- Click the weather area to open or close the forecast panel with today's hourly forecast and a 7-day forecast.
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
