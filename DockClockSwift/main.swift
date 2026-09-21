import Cocoa

private let defaultWidgetWidth: CGFloat = 238
private let defaultWidgetHeight: CGFloat = 62
private let minWidgetWidth: CGFloat = 220
private let minWidgetHeight: CGFloat = 56
private let maxWidgetWidth: CGFloat = 360
private let maxWidgetHeight: CGFloat = 120
private let marginRight: CGFloat = 18
private let marginAboveDock: CGFloat = 2
private let savedFrameKey = "DockClockWindowFrame"
private let savedCustomSizeKey = "DockClockUserSized"
private let showSecondsKey = "DockClockShowSeconds"

enum AutostartManager {
    private static let label = "local.mac.dockbar.clock.loginitem"

    private static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
    }

    private static var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else if isEnabled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private struct TextAttributesKey: Hashable {
    let font: ObjectIdentifier
    let color: ObjectIdentifier
    let alignment: Int
}

private struct ForecastHourDisplay {
    let hour: Int
    let timeText: String
    let icon: String
    let temperatureText: String
    let precipitationText: String
    let isAvailable: Bool
}

private struct ForecastDayDisplay {
    let day: ForecastDay
    let dateWeekdayText: String
    let relativeLabel: String?
    let precipitationText: String
}

private struct CalendarDayCell {
    let dayText: String
    let monthOffset: Int
    let dayToken: Int
    let isWeekend: Bool
}

private struct TimeDateRects {
    let time: NSRect
    let date: NSRect
    let timeRedraw: NSRect
    let redraw: NSRect
}

private struct TimeDateLayoutCache {
    let boundsSize: NSSize
    let dividerX: CGFloat
    let rects: TimeDateRects
}

final class ClockView: NSView {
    private enum InteractionMode {
        case none
        case resizing
        case moving
    }

    private var showSeconds = true
    private var weatherIconText = "⛅"
    private var weatherPlaceText = "수원"
    private var weatherTempText = "--°C"
    private var interactionMode = InteractionMode.none
    private var resizeStartMouse = NSPoint.zero
    private var resizeStartFrame = NSRect.zero
    private var moveStartMouse = NSPoint.zero
    private var moveStartFrame = NSRect.zero
    private var didMoveWindow = false
    private var calendarPanel: NSPanel?
    private var forecastPanel: NSPanel?
    private var forecastHours: [ForecastHour] = []
    private var forecastDays: [ForecastDay] = []
    private var weatherRequestInFlight = false
    private var weatherError: String?
    private let timeFontWithSeconds = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .bold)
    private let timeFontWithoutSeconds = NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .bold)
    private let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 10.8, weight: .medium)
    private let weatherIconFont = NSFont.systemFont(ofSize: 21, weight: .regular)
    private let weatherPlaceFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let weatherTempFont = NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .bold)
    private var cachedLayout = (dividerX: CGFloat(72), desiredWidth: CGFloat(defaultWidgetWidth))
    private var cachedTimeDateLayout: TimeDateLayoutCache?
    private var layoutDirty = true
    private let clockBackgroundColor = NSColor(calibratedRed: 0.045, green: 0.050, blue: 0.060, alpha: 0.985)
    private let clockBorderColor = NSColor(calibratedRed: 0.28, green: 0.32, blue: 0.38, alpha: 1)
    private let clockDividerColor = NSColor(calibratedRed: 0.28, green: 0.32, blue: 0.38, alpha: 0.75)
    private let clockGripColor = NSColor(calibratedRed: 0.46, green: 0.52, blue: 0.60, alpha: 0.8)
    private let clockPrimaryTextColor = NSColor(calibratedWhite: 0.98, alpha: 1)
    private let clockSecondaryTextColor = NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.88, alpha: 1)
    private lazy var weatherIconAttributes = leftTextAttributes(font: weatherIconFont, color: NSColor(calibratedWhite: 0.97, alpha: 1))
    private lazy var weatherPlaceAttributes = leftTextAttributes(font: weatherPlaceFont, color: clockSecondaryTextColor)
    private lazy var weatherTempAttributes = leftTextAttributes(font: weatherTempFont, color: clockPrimaryTextColor)
    private lazy var timeAttributesWithSeconds = leftTextAttributes(font: timeFontWithSeconds, color: .white)
    private lazy var timeAttributesWithoutSeconds = leftTextAttributes(font: timeFontWithoutSeconds, color: .white)
    private lazy var dateAttributes = leftTextAttributes(font: dateFont, color: clockSecondaryTextColor)
    private var currentTimeText = ""
    private var currentDateText = ""
    private var cachedClockMinuteToken: Int?
    private var cachedClockMinuteText = ""
    private var cachedClockSecondPrefix = ""
    private var cachedClockDateToken: Int?
    private var cachedClockDateText = ""
    private var clockDateChangedOnLastUpdate = true
    var showSecondsDidChange: ((Bool) -> Void)?

    private var timeFont: NSFont {
        showSeconds ? timeFontWithSeconds : timeFontWithoutSeconds
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        if UserDefaults.standard.object(forKey: showSecondsKey) != nil {
            showSeconds = UserDefaults.standard.bool(forKey: showSecondsKey)
        }
        updateTimeFormat()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        NSGraphicsContext.current?.shouldAntialias = true
        if currentTimeText.isEmpty || currentDateText.isEmpty {
            updateClockText()
        }

        if shouldDrawTimeDateOnly(dirtyRect) {
            let rects = timeDateRects()
            drawTimeDateArea(
                clearBackground: true,
                includeDate: dirtyRect.intersects(rects.date),
                rects: rects
            )
            return
        }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        clockBackgroundColor.setFill()
        path.fill()
        clockBorderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        drawResizeGrip(in: bounds)

        clockDividerColor.setStroke()
        let contentBaseY = max(6, (bounds.height - 44) / 2)
        let metrics = layoutMetrics()
        let dividerX = metrics.dividerX

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: contentBaseY + 2))
        divider.line(to: NSPoint(x: dividerX, y: bounds.height - contentBaseY - 2))
        divider.lineWidth = 1
        divider.stroke()

        drawLeftAligned(
            weatherIconText,
            in: NSRect(x: 10, y: contentBaseY + 11, width: 24, height: 28),
            attributes: weatherIconAttributes
        )

        drawLeftAligned(
            weatherPlaceText,
            in: NSRect(x: 36, y: contentBaseY + 26, width: dividerX - 39, height: 14),
            attributes: weatherPlaceAttributes
        )

        drawLeftAligned(
            weatherTempText,
            in: NSRect(x: 36, y: contentBaseY + 9, width: dividerX - 39, height: 18),
            attributes: weatherTempAttributes
        )

        drawTimeDateArea(clearBackground: false, includeDate: true)
    }

    private func drawResizeGrip(in bounds: NSRect) {
        clockGripColor.setStroke()

        for offset in stride(from: CGFloat(0), through: 8, by: 4) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 8 + offset, y: 6))
            line.line(to: NSPoint(x: 6, y: 8 + offset))
            line.lineWidth = 1
            line.stroke()
        }
    }

    private func drawLeftAligned(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        text.draw(in: rect, withAttributes: attributes)
    }

    private func leftTextAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    private func drawTimeDateArea(clearBackground: Bool, includeDate: Bool, rects providedRects: TimeDateRects? = nil) {
        let rects = providedRects ?? timeDateRects()
        if clearBackground {
            clockBackgroundColor.setFill()
            (includeDate ? rects.redraw : rects.timeRedraw).fill()
        }

        drawLeftAligned(
            currentTimeText,
            in: rects.time,
            attributes: showSeconds ? timeAttributesWithSeconds : timeAttributesWithoutSeconds
        )

        if includeDate {
            drawLeftAligned(
                currentDateText,
                in: rects.date,
                attributes: dateAttributes
            )
        }
    }

    private func shouldDrawTimeDateOnly(_ dirtyRect: NSRect) -> Bool {
        guard !layoutDirty else { return false }
        let redraw = timeDateRects().redraw
        return dirtyRect.minX >= redraw.minX - 1
            && dirtyRect.maxX <= redraw.maxX + 1
            && dirtyRect.minY >= redraw.minY - 1
            && dirtyRect.maxY <= redraw.maxY + 1
    }

    private func timeDateRects() -> TimeDateRects {
        let metrics = layoutMetrics()
        if
            let cachedTimeDateLayout,
            cachedTimeDateLayout.boundsSize == bounds.size,
            cachedTimeDateLayout.dividerX == metrics.dividerX
        {
            return cachedTimeDateLayout.rects
        }

        let contentBaseY = max(6, (bounds.height - 44) / 2)
        let dividerX = metrics.dividerX
        let timeX = dividerX + 10
        let timeRect = NSRect(x: timeX, y: contentBaseY + 20, width: bounds.width - timeX - 5, height: 24)
        let dateRect = NSRect(x: timeX + 1, y: contentBaseY + 4, width: bounds.width - timeX - 5, height: 14)
        let timeRedrawRect = timeRect.insetBy(dx: -3, dy: -2)
        let redrawRect = timeRect.union(dateRect).insetBy(dx: -3, dy: -2)
        let rects = TimeDateRects(time: timeRect, date: dateRect, timeRedraw: timeRedrawRect, redraw: redrawRect)
        cachedTimeDateLayout = TimeDateLayoutCache(boundsSize: bounds.size, dividerX: dividerX, rects: rects)
        return rects
    }

    private func layoutMetrics() -> (dividerX: CGFloat, desiredWidth: CGFloat) {
        if !layoutDirty {
            return cachedLayout
        }

        let clockText = currentTimeText.isEmpty || currentDateText.isEmpty ? clockStrings(for: Date()) : (time: currentTimeText, date: currentDateText)

        let iconWidth = textWidth(weatherIconText, font: weatherIconFont)
        let weatherTextWidth = max(
            textWidth(weatherPlaceText, font: weatherPlaceFont),
            textWidth(weatherTempText, font: weatherTempFont)
        )
        let weatherBlockWidth = CGFloat(10) + max(24, iconWidth) + 2 + weatherTextWidth + 5
        let dividerX = ceil(max(64, weatherBlockWidth))
        let timeX = dividerX + 10
        let timeBlockWidth = max(
            textWidth(clockText.time, font: timeFont),
            textWidth(clockText.date, font: dateFont)
        )
        let desiredWidth = ceil(max(defaultWidgetWidth, timeX + timeBlockWidth + 2))
        cachedLayout = (dividerX, desiredWidth)
        layoutDirty = false
        return cachedLayout
    }

    private func markLayoutDirty() {
        layoutDirty = true
        cachedTimeDateLayout = nil
    }

    private func updateTimeFormat() {
        markLayoutDirty()
        currentTimeText = ""
        currentDateText = ""
        cachedClockMinuteToken = nil
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    func fitWindowToContent(force: Bool = false) {
        if UserDefaults.standard.bool(forKey: savedCustomSizeKey) && !force {
            return
        }
        guard let window else { return }

        let desiredWidth = min(maxWidgetWidth, max(minWidgetWidth, layoutMetrics().desiredWidth))
        let frame = window.frame
        guard abs(frame.width - desiredWidth) > 1 else { return }

        let newFrame = NSRect(
            x: frame.maxX - desiredWidth,
            y: frame.origin.y,
            width: desiredWidth,
            height: frame.height
        )
        window.setFrame(newFrame, display: true)
        needsDisplay = true
    }

    func refreshClockIfNeeded() {
        guard updateClockText() else { return }
        if layoutDirty {
            needsDisplay = true
        } else {
            let rects = timeDateRects()
            setNeedsDisplay(clockDateChangedOnLastUpdate ? rects.redraw : rects.timeRedraw)
        }
    }

    @discardableResult
    private func updateClockText(for date: Date = Date()) -> Bool {
        let clockText = clockStrings(for: date)
        let nextTimeText = clockText.time
        let nextDateText = clockText.date
        guard nextTimeText != currentTimeText || nextDateText != currentDateText else { return false }
        clockDateChangedOnLastUpdate = nextDateText != currentDateText
        currentTimeText = nextTimeText
        currentDateText = nextDateText
        return true
    }

    private func clockStrings(for date: Date) -> (time: String, date: String) {
        let localSecondCount = Int(date.timeIntervalSince1970) + Self.clockCalendar.timeZone.secondsFromGMT(for: date)
        let secondOfDay = ((localSecondCount % Self.secondsPerDay) + Self.secondsPerDay) % Self.secondsPerDay
        let hour24 = secondOfDay / 3600
        let minuteValue = (secondOfDay % 3600) / 60
        let secondValue = secondOfDay % 60
        let minuteToken = localSecondCount / 60
        if cachedClockMinuteToken != minuteToken {
            let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
            let period = hour24 < 12 ? "오전" : "오후"
            let minute = Self.twoDigit(minuteValue)
            cachedClockMinuteToken = minuteToken
            cachedClockMinuteText = "\(period) \(hour12):\(minute)"
            cachedClockSecondPrefix = "\(cachedClockMinuteText):"
        }
        let timeText = showSeconds ? cachedClockSecondPrefix + Self.twoDigit(secondValue) : cachedClockMinuteText

        let dateToken = localSecondCount / Self.secondsPerDay
        if cachedClockDateToken != dateToken {
            cachedClockDateToken = dateToken
            cachedClockDateText = Self.formattedClockDate(for: date)
        }
        return (timeText, cachedClockDateText)
    }

    private static let clockCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = .current
        return calendar
    }()
    private static let secondsPerDay = 86_400
    private static let koreanWeekdays = ["일", "월", "화", "수", "목", "금", "토"]
    private static let twoDigitNumbers = (0...59).map { value in
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func twoDigit(_ value: Int) -> String {
        if twoDigitNumbers.indices.contains(value) {
            return twoDigitNumbers[value]
        }
        return value < 10 ? "0\(value)" : "\(value)"
    }

    private static func formattedClockDate(for date: Date) -> String {
        let components = clockCalendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekdayIndex = min(max((components.weekday ?? 1) - 1, 0), koreanWeekdays.count - 1)
        return "\(components.year ?? 0).\(twoDigit(components.month ?? 1)).\(twoDigit(components.day ?? 1)) (\(koreanWeekdays[weekdayIndex]))"
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if isInResizeGrip(point) {
            interactionMode = .resizing
            resizeStartMouse = NSEvent.mouseLocation
            resizeStartFrame = window?.frame ?? .zero
            UserDefaults.standard.set(true, forKey: savedCustomSizeKey)
            return
        }

        interactionMode = .moving
        moveStartMouse = NSEvent.mouseLocation
        moveStartFrame = window?.frame ?? .zero
        didMoveWindow = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }

        switch interactionMode {
        case .resizing:
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - resizeStartMouse.x
            let dy = mouse.y - resizeStartMouse.y
            let newWidth = min(maxWidgetWidth, max(minWidgetWidth, resizeStartFrame.width - dx))
            let newHeight = min(maxWidgetHeight, max(minWidgetHeight, resizeStartFrame.height - dy))
            let right = resizeStartFrame.maxX
            let top = resizeStartFrame.maxY

            let frame = NSRect(
                x: right - newWidth,
                y: top - newHeight,
                width: newWidth,
                height: newHeight
            )
            window.setFrame(frame, display: true)
            needsDisplay = true

        case .moving:
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - moveStartMouse.x
            let dy = mouse.y - moveStartMouse.y
            if abs(dx) > 3 || abs(dy) > 3 {
                didMoveWindow = true
            }
            window.setFrameOrigin(NSPoint(x: moveStartFrame.origin.x + dx, y: moveStartFrame.origin.y + dy))

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if interactionMode == .resizing {
            let frame = window?.frame ?? .zero
            let didResize = abs(frame.width - resizeStartFrame.width) > 1 || abs(frame.height - resizeStartFrame.height) > 1
            saveWindowFrame()
            if !didResize {
                closePopupPanels()
            }
        }
        if interactionMode == .moving {
            if didMoveWindow {
                saveWindowFrame()
            } else {
                let point = convert(event.locationInWindow, from: nil)
                if isInWeatherArea(point) {
                    toggleForecastPanel()
                } else if isInTimeDateArea(point) {
                    toggleCalendarPanel()
                } else {
                    closePopupPanels()
                }
            }
        }
        interactionMode = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu()
    }

    private func isInResizeGrip(_ point: NSPoint) -> Bool {
        point.x <= 28 && point.y <= 28
    }

    private func isInWeatherArea(_ point: NSPoint) -> Bool {
        let dividerX = layoutMetrics().dividerX
        return NSRect(x: 0, y: 0, width: dividerX + 5, height: bounds.height).contains(point)
    }

    private func isInTimeDateArea(_ point: NSPoint) -> Bool {
        let dividerX = layoutMetrics().dividerX
        let x = dividerX + 5
        return NSRect(x: x, y: 6, width: bounds.width - x - 6, height: bounds.height - 12).contains(point)
    }

    func currentShowSeconds() -> Bool {
        showSeconds
    }

    func setShowSeconds(_ enabled: Bool) {
        guard showSeconds != enabled else { return }
        showSeconds = enabled
        updateTimeFormat()
        UserDefaults.standard.set(enabled, forKey: showSecondsKey)
        fitWindowToContent()
        needsDisplay = true
        showSecondsDidChange?(enabled)
    }

    private func showContextMenu(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        contextMenu().popUp(positioning: nil, at: point, in: self)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let secondsItem = NSMenuItem(title: "시간에 초 표시", action: #selector(toggleSecondsFromMenu(_:)), keyEquivalent: "")
        secondsItem.target = self
        secondsItem.state = showSeconds ? .on : .off
        menu.addItem(secondsItem)
        let autostartItem = NSMenuItem(title: "맥 시작 시 자동 실행", action: #selector(toggleAutostartFromMenu(_:)), keyEquivalent: "")
        autostartItem.target = self
        autostartItem.state = AutostartManager.isEnabled ? .on : .off
        menu.addItem(autostartItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "종료", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func toggleSecondsFromMenu(_ sender: NSMenuItem) {
        setShowSeconds(!showSeconds)
        sender.state = showSeconds ? .on : .off
    }

    @objc private func toggleAutostartFromMenu(_ sender: NSMenuItem) {
        do {
            try AutostartManager.setEnabled(!AutostartManager.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "자동 실행 설정을 저장하지 못했습니다."
            alert.informativeText = "권한 또는 파일 경로 문제일 수 있습니다."
            alert.alertStyle = .warning
            alert.runModal()
        }
        sender.state = AutostartManager.isEnabled ? .on : .off
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func toggleForecastPanel() {
        if let forecastPanel, forecastPanel.isVisible {
            closePopupPanels()
            return
        }

        dismissCalendarPanel()
        let panel = makeForecastPanel()
        forecastPanel = panel
        updateForecastPanel()
        positionForecastPanel(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(panel.contentView)
    }

    private func makeForecastPanel() -> NSPanel {
        let forecastSize = NSSize(width: 500, height: 700)
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: forecastSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = ForecastView(
            frame: NSRect(origin: .zero, size: forecastSize),
            hours: forecastHours,
            days: forecastDays,
            onDismiss: { [weak self] in self?.dismissForecastPanel() }
        )
        panel.title = "날씨 예보"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }

    private func updateForecastPanel() {
        guard let forecastView = forecastPanel?.contentView as? ForecastView else { return }
        forecastView.update(hours: forecastHours, days: forecastDays)
        if forecastDays.isEmpty, let weatherError { forecastView.showHomeError(weatherError) }
    }

    private func toggleCalendarPanel() {
        if let calendarPanel, calendarPanel.isVisible {
            closePopupPanels()
            return
        }

        dismissForecastPanel()
        let panel = makeCalendarPanel()
        calendarPanel = panel
        positionCalendarPanel(panel)
        panel.orderFrontRegardless()
    }

    private func closePopupPanels() {
        dismissCalendarPanel()
        dismissForecastPanel()
    }

    private func dismissCalendarPanel() {
        calendarPanel?.orderOut(nil)
        calendarPanel?.contentView = nil
        calendarPanel = nil
    }

    private func dismissForecastPanel() {
        (forecastPanel?.contentView as? ForecastView)?.prepareForDismissal()
        forecastPanel?.orderOut(nil)
        forecastPanel?.contentView = nil
        forecastPanel = nil
    }

    private func makeCalendarPanel() -> NSPanel {
        let calendarSize = NSSize(width: 320, height: 360)
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: calendarSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = CalendarView(
            frame: NSRect(origin: .zero, size: calendarSize),
            onDismiss: { [weak self] in self?.dismissCalendarPanel() }
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }

    private func positionCalendarPanel(_ panel: NSPanel) {
        positionPopupPanel(panel, preferredAbove: true)
    }

    private func positionForecastPanel(_ panel: NSPanel) {
        positionPopupPanel(panel, preferredAbove: true)
    }

    private func positionPopupPanel(_ panel: NSPanel, preferredAbove: Bool) {
        guard let widgetWindow = window, let screen = widgetWindow.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        let gap: CGFloat = 8
        let panelSize = panel.frame.size
        var x = widgetWindow.frame.maxX - panelSize.width
        var y = preferredAbove ? widgetWindow.frame.maxY + gap : widgetWindow.frame.minY - panelSize.height - gap

        if preferredAbove && y + panelSize.height > visibleFrame.maxY {
            y = widgetWindow.frame.minY - panelSize.height - gap
        }
        if !preferredAbove && y < visibleFrame.minY {
            y = widgetWindow.frame.maxY + gap
        }
        x = min(max(visibleFrame.minX + 8, x), visibleFrame.maxX - panelSize.width - 8)
        y = min(max(visibleFrame.minY + 8, y), visibleFrame.maxY - panelSize.height - 8)

        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true)
    }

    func saveWindowFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(
            [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.width,
                "height": frame.height,
            ],
            forKey: savedFrameKey
        )
    }

    func fetchWeather() {
        guard !weatherRequestInFlight else { return }
        weatherRequestInFlight = true
        WeatherService.load(location: .home) { [weak self] result in
            guard let self else { return }
            self.weatherRequestInFlight = false
            switch result {
            case .success(let snapshot):
                self.weatherError = nil
                self.weatherIconText = snapshot.icon
                self.weatherPlaceText = "수원"
                self.weatherTempText = "\(snapshot.temperature)°C"
                self.forecastHours = snapshot.hours
                self.forecastDays = snapshot.days
                self.updateForecastPanel()
                self.markLayoutDirty()
                self.fitWindowToContent()
                self.needsDisplay = true
            case .failure(let error):
                self.weatherError = error.localizedDescription
                if self.forecastDays.isEmpty {
                    self.weatherTempText = "--°C"
                    (self.forecastPanel?.contentView as? ForecastView)?.showHomeError(error.localizedDescription)
                    self.needsDisplay = true
                }
            }
        }
    }

}

final class ForecastView: NSView {
    private var hours: [ForecastHour]
    private var days: [ForecastDay]
    private var hourDisplayRows: [ForecastHourDisplay] = []
    private var dayDisplayRows: [ForecastDayDisplay] = []
    private let onDismiss: () -> Void
    private var location = WeatherLocation.home
    private var homeHours: [ForecastHour]
    private var homeDays: [ForecastDay]
    private var forecastStatus = "예보를 불러오는 중…"
    private var travelTask: URLSessionDataTask?
    private var travelRequestID = UUID()
    private var locationSearchPanel: NSPanel?
    private let searchButton = NSButton()
    private let homeButton = NSButton()
    private let retryButton = NSButton()
    private var subtitle: String {
        if location.isHome { return "수원 인계동 · 기본 지역" }
        return "\(location.name) · \(location.timeZoneIdentifier.isEmpty ? "한국 시간" : "현지 시간")"
    }
    private var selectedDayIndex = 0
    private var dailyRowRects: [Int: NSRect] = [:]
    private let visibleDailyRowCount = 7
    private var dailyListOffset = 0
    private var dailyUpButtonRect = NSRect.zero
    private var dailyDownButtonRect = NSRect.zero
    private var dailyForecastScrollRect = NSRect.zero
    private var currentButtonRect = NSRect.zero
    private var closeButtonRect = NSRect.zero
    private var todayDateKey = ""
    private var yesterdayDateKey = ""
    private var relativeDayLabels: [String: String] = [:]
    private var textAttributesCache: [TextAttributesKey: [NSAttributedString.Key: Any]] = [:]
    private let panelBackgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.115, alpha: 1)
    private let panelBorderColor = NSColor(calibratedRed: 0.25, green: 0.32, blue: 0.43, alpha: 1)
    private let headerTitleFont = NSFont.systemFont(ofSize: 23, weight: .bold)
    private let headerSubtitleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let sectionTitleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let captionFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private let versionFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
    private let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "개발"
    private let loadingFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    private let pagerFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private let closeIconFont = NSFont.systemFont(ofSize: 18, weight: .regular)
    private let hourlyEmptyFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let hourlyTimeFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
    private let hourlyTimeCurrentFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    private let hourlyIconFont = NSFont.systemFont(ofSize: 20, weight: .regular)
    private let hourlyTempFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    private let hourlyPrecipFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let dailyDateFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let dailyDateCompactFont = NSFont.systemFont(ofSize: 11.4, weight: .semibold)
    private let dailyRelativeFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let dailyIconFont = NSFont.systemFont(ofSize: 20, weight: .regular)
    private let dailyConditionFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let dailyTempFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private let dailyPrecipFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private let currentButtonFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let whiteColor = NSColor.white
    private let headerSubtitleColor = NSColor(calibratedRed: 0.68, green: 0.73, blue: 0.80, alpha: 1)
    private let sectionTitleColor = NSColor(calibratedRed: 0.82, green: 0.86, blue: 0.92, alpha: 1)
    private let loadingTextColor = NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.88, alpha: 1)
    private let hourlyPanelColor = NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.175, alpha: 1)
    private let hourlyEmptyTextColor = NSColor(calibratedRed: 0.66, green: 0.71, blue: 0.78, alpha: 1)
    private let currentHighlightFillColor = NSColor(calibratedRed: 0.25, green: 0.65, blue: 0.95, alpha: 0.22)
    private let selectedFillColor = NSColor(calibratedRed: 0.14, green: 0.27, blue: 0.39, alpha: 1)
    private let highlightStrokeColor = NSColor(calibratedRed: 0.43, green: 0.77, blue: 0.98, alpha: 0.9)
    private let alternatingCellFill = NSColor(calibratedWhite: 1, alpha: 0.025)
    private let dimAlternatingCellFill = NSColor(calibratedWhite: 1, alpha: 0.01)
    private let currentHourTextColor = NSColor(calibratedRed: 0.68, green: 0.87, blue: 1, alpha: 1)
    private let availableHourTextColor = NSColor(calibratedRed: 0.68, green: 0.73, blue: 0.80, alpha: 1)
    private let unavailableHourTextColor = NSColor(calibratedRed: 0.68, green: 0.73, blue: 0.80, alpha: 0.42)
    private let availableWhiteColor = NSColor(calibratedWhite: 1, alpha: 1)
    private let unavailableIconColor = NSColor(calibratedWhite: 1, alpha: 0.35)
    private let unavailableTempColor = NSColor(calibratedWhite: 1, alpha: 0.38)
    private let availablePrecipColor = NSColor(calibratedRed: 0.62, green: 0.75, blue: 0.94, alpha: 1)
    private let unavailablePrecipColor = NSColor(calibratedRed: 0.62, green: 0.75, blue: 0.94, alpha: 0.35)
    private let selectedDayTextColor = NSColor(calibratedRed: 0.85, green: 0.95, blue: 1, alpha: 1)
    private let relativeSelectedColor = NSColor(calibratedRed: 0.55, green: 0.82, blue: 1, alpha: 1)
    private let relativeDefaultColor = NSColor(calibratedRed: 0.64, green: 0.70, blue: 0.78, alpha: 1)
    private let conditionColor = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.96, alpha: 1)
    private let lowTempColor = NSColor(calibratedRed: 0.56, green: 0.77, blue: 0.98, alpha: 1)
    private let highTempColor = NSColor(calibratedRed: 1, green: 0.74, blue: 0.52, alpha: 1)
    private let pagerEnabledFillColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1)
    private let pagerDisabledFillColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 0.7)
    private let pagerBorderColor = NSColor(calibratedRed: 0.34, green: 0.39, blue: 0.48, alpha: 1)
    private let pagerDisabledTextColor = NSColor(calibratedWhite: 1, alpha: 0.28)

    init(frame frameRect: NSRect, hours: [ForecastHour], days: [ForecastDay], onDismiss: @escaping () -> Void) {
        self.hours = hours
        self.days = days
        self.homeHours = hours
        self.homeDays = days
        self.onDismiss = onDismiss
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        refreshRelativeDayLabels()
        selectedDayIndex = todayIndex(in: days) ?? 0
        dailyListOffset = preferredDailyListOffset(around: selectedDayIndex)
        if days.indices.contains(selectedDayIndex) {
            self.hours = days[selectedDayIndex].hours
        }
        rebuildDisplayRows()
        configureLocationControls()
    }

    deinit {
        travelTask?.cancel()
        locationSearchPanel?.orderOut(nil)
    }

    private func configureLocationControls() {
        for (button, title, action, frame) in [
            (searchButton, "지역 검색", #selector(openLocationSearch), NSRect(x: 292, y: bounds.height - 81, width: 88, height: 26)),
            (homeButton, "기본 지역", #selector(showHomeLocation), NSRect(x: 384, y: bounds.height - 81, width: 98, height: 26)),
            (retryButton, "다시 불러오기", #selector(retryForecast), NSRect(x: bounds.midX - 64, y: bounds.midY - 48, width: 128, height: 30))
        ] {
            button.title = title
            button.target = self
            button.action = action
            button.frame = frame
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.appearance = NSAppearance(named: .darkAqua)
            addSubview(button)
        }
        homeButton.isEnabled = false
        retryButton.isHidden = true
        homeButton.toolTip = "수원 인계동 날씨로 돌아가기"
    }

    @objc private func openLocationSearch() {
        if let panel = locationSearchPanel { panel.makeKeyAndOrderFront(nil); return }
        guard let parent = window else { return }
        let size = NSSize(width: 460, height: 440)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let searchView = LocationSearchView(frame: NSRect(origin: .zero, size: size), onSelect: { [weak self] location in
            self?.dismissLocationSearch()
            self?.selectLocation(location)
        }, onDismiss: { [weak self] in self?.dismissLocationSearch() })
        panel.title = "여행지 날씨 찾기"
        panel.contentView = searchView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2))
        locationSearchPanel = panel
        parent.addChildWindow(panel, ordered: .above)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        searchView.focusSearch()
    }

    private func dismissLocationSearch() {
        guard let panel = locationSearchPanel else { return }
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        locationSearchPanel = nil
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    func prepareForDismissal() {
        travelRequestID = UUID()
        travelTask?.cancel()
        dismissLocationSearch()
    }

    @objc private func showHomeLocation() { selectLocation(.home) }
    @objc private func retryForecast() { selectLocation(location, forceReload: true) }

    private func selectLocation(_ location: WeatherLocation, forceReload: Bool = false) {
        travelTask?.cancel()
        travelRequestID = UUID()
        let token = travelRequestID
        self.location = location
        homeButton.isEnabled = !location.isHome
        retryButton.isHidden = true
        selectedDayIndex = 0
        dailyListOffset = 0
        applyForecast(hours: [], days: [])
        forecastStatus = "\(location.name) 예보를 불러오는 중…"
        if location.isHome && !forceReload && !homeDays.isEmpty {
            applyForecast(hours: homeHours, days: homeDays)
            return
        }
        travelTask = WeatherService.load(location: location) { [weak self] result in
            guard let self, self.travelRequestID == token else { return }
            self.travelTask = nil
            switch result {
            case .success(let snapshot):
                if location.isHome {
                    self.homeHours = snapshot.hours
                    self.homeDays = snapshot.days
                }
                self.applyForecast(hours: snapshot.hours, days: snapshot.days)
            case .failure(let error):
                self.forecastStatus = error.localizedDescription
                self.retryButton.isHidden = false
                self.needsDisplay = true
            }
        }
    }

    func showHomeError(_ message: String) {
        guard location.isHome, days.isEmpty else { return }
        forecastStatus = message
        retryButton.isHidden = false
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func update(hours: [ForecastHour], days: [ForecastDay]) {
        homeHours = hours
        homeDays = days
        guard location.isHome else { return }
        applyForecast(hours: hours, days: days)
    }

    private func applyForecast(hours: [ForecastHour], days: [ForecastDay]) {
        dailyRowRects = [:]
        dailyUpButtonRect = .zero
        dailyDownButtonRect = .zero
        dailyForecastScrollRect = .zero
        retryButton.isHidden = true
        let hadNoDays = self.days.isEmpty
        let selectedDateKey = self.days.indices.contains(selectedDayIndex) ? self.days[selectedDayIndex].dateKey : nil
        self.days = days
        refreshRelativeDayLabels()
        if let selectedDateKey, let preservedIndex = days.firstIndex(where: { $0.dateKey == selectedDateKey }) {
            selectedDayIndex = preservedIndex
        } else {
            selectedDayIndex = todayIndex(in: days) ?? 0
        }
        if days.indices.contains(selectedDayIndex) {
            self.hours = days[selectedDayIndex].hours
        } else {
            self.hours = hours
        }
        if hadNoDays {
            dailyListOffset = preferredDailyListOffset(around: selectedDayIndex)
        } else {
            clampDailyListOffset()
        }
        rebuildDisplayRows()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.current?.shouldAntialias = true
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        panelBackgroundColor.setFill()
        path.fill()
        panelBorderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        drawHeader(in: bounds)

        if hours.isEmpty && days.isEmpty {
            drawText(
                forecastStatus,
                in: NSRect(x: 18, y: bounds.midY - 12, width: bounds.width - 36, height: 24),
                font: hourlyEmptyFont,
                color: loadingTextColor,
                alignment: .center
            )
            return
        }

        drawSectionTitle("날짜 예보", y: bounds.height - 122)
        drawDailyPagerButtons(in: bounds)
        dailyRowRects = [:]
        let rowHeight: CGFloat = 40
        let startY = bounds.height - 172
        dailyForecastScrollRect = NSRect(x: 18, y: startY - 6 * rowHeight, width: bounds.width - 36, height: 7 * rowHeight)
        for rowIndex in 0..<visibleDailyRowCount {
            let actualIndex = dailyListOffset + rowIndex
            guard dayDisplayRows.indices.contains(actualIndex) else { continue }
            let rowY = startY - CGFloat(rowIndex) * rowHeight
            let rowRect = NSRect(x: 18, y: rowY, width: bounds.width - 36, height: rowHeight - 4)
            dailyRowRects[actualIndex] = rowRect
            drawDailyRow(dayDisplayRows[actualIndex], in: rowRect, selected: actualIndex == selectedDayIndex)
        }
        drawSectionTitle(hourlySectionTitle(), y: 252)
        drawText("24시간 · 강수 확률", in: NSRect(x: bounds.width - 162, y: 254, width: 140, height: 15), font: captionFont, color: headerSubtitleColor, alignment: .right)
        drawHourlyForecast(in: NSRect(x: 18, y: 38, width: bounds.width - 36, height: 204))
        drawText("날짜를 누르면 아래 시간별 예보가 바뀝니다", in: NSRect(x: 22, y: 13, width: 310, height: 14), font: captionFont, color: headerSubtitleColor, alignment: .left)
        drawText(buildVersion, in: NSRect(x: bounds.width - 132, y: 14, width: 110, height: 12), font: versionFont, color: headerSubtitleColor, alignment: .right)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in dailyRowRects.values {
            addCursorRect(rect, cursor: .pointingHand)
        }
        for rect in [currentButtonRect, closeButtonRect, dailyUpButtonRect, dailyDownButtonRect] {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeButtonRect.contains(point) {
            onDismiss()
            return
        }
        if dailyUpButtonRect.contains(point) {
            shiftDailyList(by: -1)
            return
        }
        if dailyDownButtonRect.contains(point) {
            shiftDailyList(by: 1)
            return
        }
        if currentButtonRect.contains(point) {
            if let todayIndex = todayIndex(in: days) {
                selectedDayIndex = todayIndex
                hours = days[todayIndex].hours
                dailyListOffset = preferredDailyListOffset(around: todayIndex)
                rebuildHourDisplayRows()
            }
            needsDisplay = true
            return
        }

        for (index, rect) in dailyRowRects where rect.contains(point) {
            selectedDayIndex = index
            if days.indices.contains(index) {
                hours = days[index].hours
                rebuildHourDisplayRows()
            }
            needsDisplay = true
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onDismiss()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard dailyForecastScrollRect.contains(point) || dailyUpButtonRect.contains(point) || dailyDownButtonRect.contains(point) else {
            super.scrollWheel(with: event)
            return
        }

        let movement = event.scrollingDeltaY
        guard abs(movement) >= 0.2 else { return }
        shiftDailyList(by: movement < 0 ? 1 : -1)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss()
            return
        }
        super.keyDown(with: event)
    }

    private func drawHeader(in bounds: NSRect) {
        drawText(
            "날씨 예보",
            in: NSRect(x: 22, y: bounds.height - 51, width: 260, height: 30),
            font: headerTitleFont,
            color: whiteColor,
            alignment: .left
        )

        drawText(
            subtitle,
            in: NSRect(x: 23, y: bounds.height - 73, width: 263, height: 18),
            font: headerSubtitleFont,
            color: headerSubtitleColor,
            alignment: .left
        )
        panelBorderColor.withAlphaComponent(0.55).setFill()
        NSRect(x: 22, y: bounds.height - 91, width: bounds.width - 44, height: 1).fill()
        drawCurrentButton(in: bounds)
        closeButtonRect = NSRect(x: bounds.width - 48, y: bounds.height - 52, width: 28, height: 28)
        drawPagerButton("×", in: closeButtonRect, enabled: true)
    }

    private func drawSectionTitle(_ title: String, y: CGFloat) {
        drawText(
            title,
            in: NSRect(x: 22, y: y, width: bounds.width - 174, height: 21),
            font: sectionTitleFont,
            color: sectionTitleColor,
            alignment: .left
        )
    }

    private func drawDailyPagerButtons(in bounds: NSRect) {
        dailyUpButtonRect = NSRect(x: bounds.width - 82, y: bounds.height - 123, width: 28, height: 24)
        dailyDownButtonRect = NSRect(x: bounds.width - 48, y: bounds.height - 123, width: 28, height: 24)
        drawPagerButton("⌃", in: dailyUpButtonRect, enabled: dailyListOffset > 0)
        drawPagerButton("⌄", in: dailyDownButtonRect, enabled: dailyListOffset < maxDailyListOffset)
        let lastVisible = min(days.count, dailyListOffset + visibleDailyRowCount)
        let range = days.isEmpty ? "" : "\(dailyListOffset + 1)–\(lastVisible) / \(days.count)일"
        drawText(range, in: NSRect(x: 114, y: bounds.height - 119, width: 104, height: 15), font: captionFont, color: headerSubtitleColor, alignment: .left)
        drawText("최저 · 최고", in: NSRect(x: 259, y: bounds.height - 119, width: 137, height: 15), font: captionFont, color: headerSubtitleColor, alignment: .center)
    }

    private func drawPagerButton(_ text: String, in rect: NSRect, enabled: Bool) {
        let fill = enabled ? pagerEnabledFillColor : pagerDisabledFillColor
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()

        if enabled {
            pagerBorderColor.setStroke()
            let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            borderPath.lineWidth = 1
            borderPath.stroke()
        }

        let isCloseButton = text == "×"
        let textHeight: CGFloat = isCloseButton ? 24 : 16
        drawText(
            text,
            in: NSRect(x: rect.minX, y: rect.midY - textHeight / 2, width: rect.width, height: textHeight),
            font: isCloseButton ? closeIconFont : pagerFont,
            color: enabled ? whiteColor : pagerDisabledTextColor,
            alignment: .center
        )
    }

    private func hourlySectionTitle() -> String {
        guard days.indices.contains(selectedDayIndex) else {
            return "오늘 시간별"
        }
        if selectedDayIsToday {
            return "오늘 시간별"
        }
        if selectedDayIsYesterday {
            return "어제 시간별"
        }
        return "\(days[selectedDayIndex].hourlyTitle) 시간별"
    }

    private func drawHourlyForecast(in rect: NSRect) {
        hourlyPanelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()

        guard !hours.isEmpty else {
            drawText(
                "시간별 예보 없음",
                in: rect.insetBy(dx: 12, dy: 28),
                font: hourlyEmptyFont,
                color: hourlyEmptyTextColor,
                alignment: .center
            )
            return
        }

        let columns: CGFloat = 8
        let rows: CGFloat = 3
        let grid = rect.insetBy(dx: 6, dy: 6)
        let cellWidth = grid.width / columns
        let cellHeight = grid.height / rows
        let currentHour = calendar.component(.hour, from: Date())

        for (index, hour) in hourDisplayRows.enumerated() {
            let column = CGFloat(index % 8)
            let row = CGFloat(index / 8)
            let x = grid.minX + column * cellWidth
            let y = grid.maxY - CGFloat(row + 1) * cellHeight
            let cell = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
            let isCurrentHour = selectedDayIsToday && hour.hour == currentHour
            let isAvailable = hour.isAvailable
            let cellColor: NSColor
            if isCurrentHour {
                cellColor = currentHighlightFillColor
            } else {
                cellColor = index % 2 == 0 ? alternatingCellFill : dimAlternatingCellFill
            }
            cellColor.setFill()
            NSBezierPath(roundedRect: cell.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()

            if isCurrentHour {
                highlightStrokeColor.setStroke()
                let highlightPath = NSBezierPath(roundedRect: cell.insetBy(dx: 2.5, dy: 2.5), xRadius: 7, yRadius: 7)
                highlightPath.lineWidth = 1
                highlightPath.stroke()
            }

            drawText(
                isCurrentHour ? "지금" : hour.timeText,
                in: NSRect(x: cell.minX + 3, y: cell.maxY - 15, width: cell.width - 6, height: 12),
                font: isCurrentHour ? hourlyTimeCurrentFont : hourlyTimeFont,
                color: isCurrentHour ? currentHourTextColor : (isAvailable ? availableHourTextColor : unavailableHourTextColor),
                alignment: .center
            )
            drawText(
                hour.icon,
                in: NSRect(x: cell.minX + 3, y: cell.minY + 27, width: cell.width - 6, height: 22),
                font: hourlyIconFont,
                color: isAvailable ? availableWhiteColor : unavailableIconColor,
                alignment: .center
            )
            drawText(
                hour.temperatureText,
                in: NSRect(x: cell.minX + 3, y: cell.minY + 14, width: cell.width - 6, height: 15),
                font: hourlyTempFont,
                color: isAvailable ? availableWhiteColor : unavailableTempColor,
                alignment: .center
            )
            drawText(
                hour.precipitationText,
                in: NSRect(x: cell.minX + 3, y: cell.minY + 3, width: cell.width - 6, height: 12),
                font: hourlyPrecipFont,
                color: isAvailable ? availablePrecipColor : unavailablePrecipColor,
                alignment: .center
            )
        }
    }

    private func drawDailyRow(_ display: ForecastDayDisplay, in rect: NSRect, selected: Bool) {
        let day = display.day
        let rowColor = selected ? selectedFillColor : hourlyPanelColor
        rowColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()

        if selected {
            highlightStrokeColor.setStroke()
            let selectedPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            selectedPath.lineWidth = 1
            selectedPath.stroke()
        }

        let relativeLabel = display.relativeLabel
        drawText(
            display.dateWeekdayText,
            in: NSRect(x: rect.minX + 12, y: rect.minY + (relativeLabel == nil ? 10 : 17), width: 72, height: 15),
            font: relativeLabel == nil ? dailyDateFont : dailyDateCompactFont,
            color: selected ? selectedDayTextColor : whiteColor,
            alignment: .left
        )

        if let relativeLabel {
            drawText(
                relativeLabel,
                in: NSRect(x: rect.minX + 12, y: rect.minY + 5, width: 72, height: 12),
                font: dailyRelativeFont,
                color: selected ? relativeSelectedColor : relativeDefaultColor,
                alignment: .left
            )
        }

        drawText(
            day.icon,
            in: NSRect(x: rect.minX + 86, y: rect.minY + 7, width: 28, height: 24),
            font: dailyIconFont,
            color: whiteColor,
            alignment: .center
        )

        drawText(
            day.condition,
            in: NSRect(x: rect.minX + 120, y: rect.minY + 10, width: 112, height: 17),
            font: dailyConditionFont,
            color: conditionColor,
            alignment: .left
        )

        drawText(
            "\(day.lowTemp)°",
            in: NSRect(x: rect.minX + 242, y: rect.minY + 10, width: 34, height: 17),
            font: dailyTempFont,
            color: lowTempColor,
            alignment: .right
        )

        let track = NSRect(x: rect.minX + 286, y: rect.midY - 3, width: 60, height: 6)
        panelBorderColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        // Use the same scale across all dates so each temperature range is comparable.
        let minTemp = days.map(\.lowTemp).min() ?? day.lowTemp
        let maxTemp = max(minTemp + 1, days.map(\.highTemp).max() ?? day.highTemp)
        let scale = CGFloat(maxTemp - minTemp)
        let start = CGFloat(day.lowTemp - minTemp) / scale * (track.width - 4)
        let end = CGFloat(day.highTemp - minTemp) / scale * (track.width - 4) + 4
        let range = NSRect(x: track.minX + start, y: track.minY, width: max(4, end - start), height: track.height)
        NSGradient(starting: lowTempColor, ending: highTempColor)?.draw(in: NSBezierPath(roundedRect: range, xRadius: 3, yRadius: 3), angle: 0)
        drawText("\(day.highTemp)°", in: NSRect(x: rect.minX + 354, y: rect.minY + 10, width: 34, height: 17), font: dailyTempFont, color: highTempColor, alignment: .left)

        drawText(
            display.precipitationText,
            in: NSRect(x: rect.maxX - 68, y: rect.minY + 10, width: 56, height: 16),
            font: dailyPrecipFont,
            color: availablePrecipColor,
            alignment: .right
        )
    }

    private func rebuildDisplayRows() {
        rebuildDailyDisplayRows()
        rebuildHourDisplayRows()
    }

    private func rebuildDailyDisplayRows() {
        dayDisplayRows = days.map { day in
            ForecastDayDisplay(
                day: day,
                dateWeekdayText: "\(day.dateText) \(day.weekdayText)",
                relativeLabel: relativeDayLabel(for: day),
                precipitationText: "강수 \(day.precipitation)%"
            )
        }
    }

    private func rebuildHourDisplayRows() {
        hourDisplayRows = hours.map { hour in
            let isAvailable = hour.temperature != nil
            return ForecastHourDisplay(
                hour: hour.hour,
                timeText: hour.timeText,
                icon: hour.icon,
                temperatureText: hour.temperature.map { "\($0)°" } ?? "--",
                precipitationText: hour.precipitation.map { "\($0)%" } ?? "--",
                isAvailable: isAvailable
            )
        }
    }

    private func drawCurrentButton(in bounds: NSRect) {
        currentButtonRect = NSRect(x: bounds.width - 136, y: bounds.height - 53, width: 76, height: 30)
        let selected = selectedDayIsToday
        let fill = selected ? selectedFillColor : pagerEnabledFillColor
        fill.setFill()
        NSBezierPath(roundedRect: currentButtonRect, xRadius: 8, yRadius: 8).fill()

        if selected {
            highlightStrokeColor.setStroke()
            let path = NSBezierPath(roundedRect: currentButtonRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            path.lineWidth = 1
            path.stroke()
        }

        drawText(
            "오늘",
            in: currentButtonRect.insetBy(dx: 0, dy: 7),
            font: currentButtonFont,
            color: selected ? currentHourTextColor : whiteColor,
            alignment: .center
        )
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let key = TextAttributesKey(font: ObjectIdentifier(font), color: ObjectIdentifier(color), alignment: alignment.rawValue)
        let attributes: [NSAttributedString.Key: Any]
        if let cached = textAttributesCache[key] {
            attributes = cached
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byTruncatingTail
            let made: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            textAttributesCache[key] = made
            attributes = made
        }
        text.draw(in: rect, withAttributes: attributes)
    }

    private var selectedDayIsToday: Bool {
        guard days.indices.contains(selectedDayIndex) else { return false }
        return days[selectedDayIndex].dateKey == todayDateKey
    }

    private var selectedDayIsYesterday: Bool {
        guard days.indices.contains(selectedDayIndex) else { return false }
        return days[selectedDayIndex].dateKey == yesterdayDateKey
    }

    private func todayIndex(in days: [ForecastDay]) -> Int? {
        days.firstIndex { $0.dateKey == todayDateKey }
    }

    private var maxDailyListOffset: Int {
        max(0, days.count - visibleDailyRowCount)
    }

    private func preferredDailyListOffset(around index: Int) -> Int {
        min(maxDailyListOffset, max(0, index - 1))
    }

    private func clampDailyListOffset() {
        dailyListOffset = min(maxDailyListOffset, max(0, dailyListOffset))
    }

    private func shiftDailyList(by delta: Int) {
        let nextOffset = min(maxDailyListOffset, max(0, dailyListOffset + delta))
        guard nextOffset != dailyListOffset else { return }
        dailyListOffset = nextOffset
        needsDisplay = true
    }

    private func relativeDayLabel(for day: ForecastDay) -> String? {
        relativeDayLabels[day.dateKey]
    }

    private func refreshRelativeDayLabels() {
        let now = Date()
        todayDateKey = dateKey(for: now)
        yesterdayDateKey = ""
        relativeDayLabels = [:]
        let labels = [(-1, "어제"), (0, "오늘"), (1, "내일"), (2, "모레")]
        for (offset, label) in labels {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else {
                continue
            }
            let key = dateKey(for: date)
            if offset == -1 {
                yesterdayDateKey = key
            }
            relativeDayLabels[key] = label
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = location.timeZone
        return calendar
    }

    private var dateKeyFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = location.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func dateKey(for date: Date) -> String {
        dateKeyFormatter.string(from: date)
    }
}

final class CalendarView: NSView {
    private let calendar = Calendar(identifier: .gregorian)
    private let titleFormatter = DateFormatter()
    private let fullDateFormatter = DateFormatter()
    private let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]
    private let onDismiss: () -> Void
    private var displayedMonth: Date
    private var previousMonthRect = NSRect.zero
    private var nextMonthRect = NSRect.zero
    private var todayRect = NSRect.zero
    private var cachedMonthStart: Date?
    private var cachedDayCells: [CalendarDayCell] = []
    private var monthTitleText = ""
    private var cachedFooterDateToken: Int?
    private var cachedFooterDateText = ""
    private var textAttributesCache: [TextAttributesKey: [NSAttributedString.Key: Any]] = [:]
    private let panelBackgroundColor = NSColor(calibratedRed: 0.045, green: 0.050, blue: 0.060, alpha: 0.985)
    private let panelBorderColor = NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.40, alpha: 1)
    private let dividerColor = NSColor(calibratedRed: 0.22, green: 0.25, blue: 0.31, alpha: 1)
    private let navButtonFillColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1)
    private let todayHighlightColor = NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.95, alpha: 1)
    private let weekdayTextColor = NSColor(calibratedRed: 0.66, green: 0.70, blue: 0.77, alpha: 1)
    private let outsideMonthTextColor = NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.45, alpha: 1)
    private let weekendTextColor = NSColor(calibratedRed: 0.94, green: 0.70, blue: 0.70, alpha: 1)
    private let weekdayDateTextColor = NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.96, alpha: 1)
    private let footerDateColor = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.96, alpha: 1)
    private let titleFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    private let weekdayFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let dayFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    private let todayFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
    private let footerDateFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private let navButtonFont = NSFont.systemFont(ofSize: 24, weight: .regular)
    private let todayButtonFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    init(frame frameRect: NSRect, onDismiss: @escaping () -> Void) {
        displayedMonth = CalendarView.startOfMonth(for: Date())
        self.onDismiss = onDismiss
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        titleFormatter.locale = Locale(identifier: "ko_KR")
        titleFormatter.dateFormat = "yyyy년 M월"
        fullDateFormatter.locale = Locale(identifier: "ko_KR")
        fullDateFormatter.dateFormat = "yyyy년 M월 d일 EEEE"
        monthTitleText = titleFormatter.string(from: displayedMonth)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.current?.shouldAntialias = true
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        panelBackgroundColor.setFill()
        path.fill()
        panelBorderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        drawHeader(in: bounds)
        drawWeekdays(in: bounds)
        drawDays(in: bounds)
        drawFooter(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if previousMonthRect.contains(point) {
            changeMonth(by: -1)
            return
        }

        if nextMonthRect.contains(point) {
            changeMonth(by: 1)
            return
        }

        if todayRect.contains(point) {
            displayedMonth = Self.startOfMonth(for: Date())
            monthTitleText = titleFormatter.string(from: displayedMonth)
            needsDisplay = true
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onDismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss()
            return
        }
        super.keyDown(with: event)
    }

    private func drawHeader(in bounds: NSRect) {
        drawText(
            monthTitleText,
            in: NSRect(x: 18, y: bounds.height - 50, width: 170, height: 28),
            font: titleFont,
            color: .white,
            alignment: .left
        )

        previousMonthRect = NSRect(x: bounds.width - 88, y: bounds.height - 50, width: 32, height: 30)
        nextMonthRect = NSRect(x: bounds.width - 48, y: bounds.height - 50, width: 32, height: 30)
        drawButton("‹", in: previousMonthRect)
        drawButton("›", in: nextMonthRect)
    }

    private func drawWeekdays(in bounds: NSRect) {
        let grid = gridRect(in: bounds)
        let cellWidth = grid.width / 7

        for index in 0..<7 {
            let rect = NSRect(x: grid.minX + CGFloat(index) * cellWidth, y: grid.maxY + 7, width: cellWidth, height: 18)
            drawText(weekdaySymbols[index], in: rect, font: weekdayFont, color: weekdayTextColor, alignment: .center)
        }
    }

    private func drawDays(in bounds: NSRect) {
        let grid = gridRect(in: bounds)
        let cellWidth = grid.width / 7
        let cellHeight = grid.height / 6
        let todayToken = Self.dayToken(for: Date())
        let cells = dayCells(for: displayedMonth)

        for (slot, dayCell) in cells.enumerated() {
            let row = slot / 7
            let column = slot % 7
            let x = grid.minX + CGFloat(column) * cellWidth
            let y = grid.maxY - CGFloat(row + 1) * cellHeight
            let cellRect = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)

            let isToday = dayCell.dayToken == todayToken
            if isToday {
                let highlightRect = cellRect.insetBy(dx: 5, dy: 4)
                todayHighlightColor.setFill()
                NSBezierPath(roundedRect: highlightRect, xRadius: 8, yRadius: 8).fill()
            }

            let color: NSColor
            if isToday {
                color = .white
            } else if dayCell.monthOffset != 0 {
                color = outsideMonthTextColor
            } else if dayCell.isWeekend {
                color = weekendTextColor
            } else {
                color = weekdayDateTextColor
            }

            drawText(
                dayCell.dayText,
                in: cellRect.insetBy(dx: 0, dy: 7),
                font: isToday ? todayFont : dayFont,
                color: color,
                alignment: .center
            )
        }
    }

    private func drawFooter(in bounds: NSRect) {
        let lineY: CGFloat = 54
        dividerColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 16, y: lineY))
        line.line(to: NSPoint(x: bounds.width - 16, y: lineY))
        line.lineWidth = 1
        line.stroke()

        drawText(
            footerDateText(),
            in: NSRect(x: 18, y: 20, width: bounds.width - 112, height: 22),
            font: footerDateFont,
            color: footerDateColor,
            alignment: .left
        )

        todayRect = NSRect(x: bounds.width - 88, y: 16, width: 70, height: 28)
        drawCapsule("오늘", in: todayRect)
    }

    private func drawButton(_ text: String, in rect: NSRect) {
        navButtonFillColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        drawText(text, in: rect.offsetBy(dx: 0, dy: -1), font: navButtonFont, color: .white, alignment: .center)
    }

    private func drawCapsule(_ text: String, in rect: NSRect) {
        navButtonFillColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        drawText(text, in: rect.insetBy(dx: 0, dy: 7), font: todayButtonFont, color: .white, alignment: .center)
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let key = TextAttributesKey(font: ObjectIdentifier(font), color: ObjectIdentifier(color), alignment: alignment.rawValue)
        let attributes: [NSAttributedString.Key: Any]
        if let cached = textAttributesCache[key] {
            attributes = cached
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byTruncatingTail
            let made: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            textAttributesCache[key] = made
            attributes = made
        }
        text.draw(in: rect, withAttributes: attributes)
    }

    private func dayCells(for monthStart: Date) -> [CalendarDayCell] {
        if cachedMonthStart == monthStart, !cachedDayCells.isEmpty {
            return cachedDayCells
        }

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = firstWeekday - 1
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let previousMonth = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let previousDays = calendar.range(of: .day, in: .month, for: previousMonth)?.count ?? 30
        var cells: [CalendarDayCell] = []
        cells.reserveCapacity(42)

        for slot in 0..<42 {
            let dayNumber: Int
            let monthOffset: Int
            let baseMonth: Date
            if slot < leadingDays {
                dayNumber = previousDays - leadingDays + slot + 1
                monthOffset = -1
                baseMonth = previousMonth
            } else if slot >= leadingDays + daysInMonth {
                dayNumber = slot - leadingDays - daysInMonth + 1
                monthOffset = 1
                baseMonth = nextMonth
            } else {
                dayNumber = slot - leadingDays + 1
                monthOffset = 0
                baseMonth = monthStart
            }

            guard let date = calendar.date(bySetting: .day, value: dayNumber, of: baseMonth) else {
                continue
            }
            let column = slot % 7
            cells.append(
                CalendarDayCell(
                    dayText: "\(dayNumber)",
                    monthOffset: monthOffset,
                    dayToken: Self.dayToken(for: date),
                    isWeekend: column == 0 || column == 6
                )
            )
        }

        cachedMonthStart = monthStart
        cachedDayCells = cells
        return cells
    }

    private func gridRect(in bounds: NSRect) -> NSRect {
        NSRect(x: 16, y: 68, width: bounds.width - 32, height: 216)
    }

    private func changeMonth(by value: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth
        monthTitleText = titleFormatter.string(from: displayedMonth)
        needsDisplay = true
    }

    private func footerDateText() -> String {
        let now = Date()
        let token = Self.dayToken(for: now)
        if cachedFooterDateToken != token {
            cachedFooterDateToken = token
            cachedFooterDateText = fullDateFormatter.string(from: now)
        }
        return cachedFooterDateText
    }

    private static func startOfMonth(for date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private static func dayToken(for date: Date) -> Int {
        let localSecondCount = Int(date.timeIntervalSince1970) + TimeZone.current.secondsFromGMT(for: date)
        return localSecondCount / 86_400
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSPanel?
    private var clockView: ClockView?
    private var timer: Timer?
    private var weatherTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTextEditingMenu()
        let initialFrame = Self.initialFrame()
        let view = ClockView(frame: NSRect(x: 0, y: 0, width: initialFrame.width, height: initialFrame.height))
        view.autoresizingMask = [.width, .height]
        view.showSecondsDidChange = { [weak self, weak view] _ in
            guard let view else { return }
            self?.scheduleClockTick(for: view)
        }
        self.clockView = view

        let panel = FloatingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: minWidgetWidth, height: minWidgetHeight)
        panel.maxSize = NSSize(width: maxWidgetWidth, height: maxWidgetHeight)

        panel.orderFrontRegardless()
        self.window = panel

        scheduleClockTick(for: view)
        view.fitWindowToContent(force: true)
        view.fetchWeather()
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            view.fetchWeather()
        }
        weatherTimer?.tolerance = 60
    }

    private func installTextEditingMenu() {
        // Native field editors route Command shortcuts through the application's menu.
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "편집")
        for (title, action, key) in [
            ("실행 취소", Selector(("undo:")), "z"),
            ("잘라내기", #selector(NSText.cut(_:)), "x"),
            ("복사", #selector(NSText.copy(_:)), "c"),
            ("붙여넣기", #selector(NSText.paste(_:)), "v"),
            ("전체 선택", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let redo = NSMenuItem(title: "다시 실행", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.insertItem(redo, at: 1)
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        clockView?.saveWindowFrame()
    }

    private func scheduleClockTick(for view: ClockView) {
        timer?.invalidate()
        let showsSeconds = view.currentShowSeconds()
        let initialDelay = showsSeconds ? Self.secondsUntilNextSecond() : Self.secondsUntilNextMinute()
        let nextTimer = Timer(
            fire: Date(timeIntervalSinceNow: initialDelay),
            interval: showsSeconds ? 1 : 60,
            repeats: true
        ) { [weak view] _ in
            guard let view else { return }
            view.refreshClockIfNeeded()
        }
        nextTimer.tolerance = showsSeconds ? 0.04 : 2.0
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    private static func secondsUntilNextSecond() -> TimeInterval {
        let now = Date().timeIntervalSinceReferenceDate
        return max(0.05, floor(now) + 1 - now)
    }

    private static func secondsUntilNextMinute() -> TimeInterval {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.second, .nanosecond], from: now)
        let second = Double(components.second ?? 0)
        let nanosecond = Double(components.nanosecond ?? 0) / 1_000_000_000
        return max(0.2, 60 - second - nanosecond)
    }

    private static func initialFrame() -> NSRect {
        if
            let saved = UserDefaults.standard.dictionary(forKey: savedFrameKey),
            let x = saved["x"] as? NSNumber,
            let y = saved["y"] as? NSNumber,
            let width = saved["width"] as? NSNumber,
            let height = saved["height"] as? NSNumber
        {
            let savedFrame = NSRect(
                x: CGFloat(truncating: x),
                y: CGFloat(truncating: y),
                width: min(maxWidgetWidth, max(minWidgetWidth, CGFloat(truncating: width))),
                height: min(maxWidgetHeight, max(minWidgetHeight, CGFloat(truncating: height)))
            )

            if let screen = NSScreen.main, savedFrame.intersects(screen.visibleFrame.insetBy(dx: -60, dy: -60)) {
                return savedFrame
            }
        }

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.maxX - defaultWidgetWidth - marginRight
            let y = frame.minY + marginAboveDock
            return NSRect(x: x, y: y, width: defaultWidgetWidth, height: defaultWidgetHeight)
        }

        return NSRect(x: 100, y: 100, width: defaultWidgetWidth, height: defaultWidgetHeight)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
