import Cocoa
import MapKit

final class LocationSearchView: NSView, NSSearchFieldDelegate {
    private let onSelect: (WeatherLocation) -> Void
    private let onDismiss: () -> Void
    private let searchField = NSSearchField()
    private let message = NSTextField(labelWithString: "")
    private var resultButtons: [NSButton] = []
    private var removeButtons: [NSButton] = []
    private var locations: [WeatherLocation] = []
    private var showingRecentLocations = false
    private var search: MKLocalSearch?
    private var requestID = UUID()
    private static let recentKey = "DockClockRecentWeatherLocationsV1"

    init(frame: NSRect, onSelect: @escaping (WeatherLocation) -> Void, onDismiss: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1).cgColor
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.4, alpha: 1).cgColor
        appearance = NSAppearance(named: .darkAqua)

        let title = NSTextField(labelWithString: "여행지 날씨 찾기")
        title.font = .systemFont(ofSize: 21, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 22, y: 386, width: 320, height: 30)
        addSubview(title)
        let hint = NSTextField(labelWithString: "도시·동네·여행지 이름으로 검색하세요")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 22, y: 363, width: 390, height: 18)
        addSubview(hint)
        let close = NSButton(title: "닫기", target: self, action: #selector(dismiss))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 382, y: 387, width: 60, height: 28)
        addSubview(close)

        searchField.frame = NSRect(x: 22, y: 317, width: 342, height: 30)
        searchField.placeholderString = "예: 부산, 강릉, 제주, 도쿄"
        searchField.font = .systemFont(ofSize: 14)
        searchField.target = self
        searchField.action = #selector(startSearch)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.setAccessibilityLabel("여행지 검색")
        addSubview(searchField)
        let submit = NSButton(title: "검색", target: self, action: #selector(startSearch))
        submit.bezelStyle = .rounded
        submit.frame = NSRect(x: 372, y: 317, width: 68, height: 30)
        addSubview(submit)

        message.frame = NSRect(x: 23, y: 284, width: 414, height: 22)
        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .secondaryLabelColor
        addSubview(message)
        showRecentLocations()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { search?.cancel() }
    override var acceptsFirstResponder: Bool { true }

    func focusSearch() { window?.makeFirstResponder(searchField) }

    @objc private func dismiss() {
        cancelSearch()
        onDismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        cancelSearch()
        if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showRecentLocations()
        } else {
            showLocations([])
            message.stringValue = "Enter 또는 검색 버튼을 눌러 주세요"
        }
    }

    private func cancelSearch() {
        requestID = UUID()
        search?.cancel()
        search = nil
    }

    @objc private func startSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearch()
        guard !query.isEmpty else { showRecentLocations(); return }
        let token = requestID
        message.stringValue = "‘\(query)’ 검색 중…"
        showLocations([])
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: WeatherLocation.home.latitude, longitude: WeatherLocation.home.longitude), latitudinalMeters: 700_000, longitudinalMeters: 700_000)
        let task = MKLocalSearch(request: request)
        search = task
        task.start { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self, self.requestID == token else { return }
                self.search = nil
                guard error == nil, let response else {
                    self.message.stringValue = "검색 결과가 없거나 연결할 수 없습니다. 다른 이름으로 다시 검색해 주세요."
                    return
                }
                var seen = Set<String>()
                let found = response.mapItems.compactMap { item -> WeatherLocation? in
                    let coordinate = item.placemark.coordinate
                    guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                    let parts = [item.placemark.country, item.placemark.administrativeArea, item.placemark.locality, item.placemark.subLocality]
                    var used = Set<String>()
                    let detail = parts.compactMap { $0 }.filter { used.insert($0).inserted }.joined(separator: " · ")
                    let location = WeatherLocation(name: item.name ?? query, detail: detail, latitude: coordinate.latitude, longitude: coordinate.longitude, timeZoneIdentifier: item.timeZone?.identifier ?? "")
                    guard seen.insert(location.id).inserted else { return nil }
                    return location
                }
                self.showLocations(Array(found.prefix(5)))
                self.message.stringValue = found.isEmpty ? "일치하는 지역이 없습니다. 도시나 동네 이름으로 검색해 주세요." : "검색 결과 · 주소를 확인하고 선택하세요"
            }
        }
    }

    private func showRecentLocations() {
        let recent = Self.recentLocations().filter { !$0.isHome }
        message.stringValue = recent.isEmpty ? "기본 지역 · 여행지 검색은 기본 지역을 바꾸지 않습니다" : "기본 지역 · 최근 검색"
        showLocations([.home] + Array(recent.prefix(4)), allowsRemoval: true)
    }

    private func showLocations(_ locations: [WeatherLocation], allowsRemoval: Bool = false) {
        self.locations = locations
        showingRecentLocations = allowsRemoval
        resultButtons.forEach { $0.removeFromSuperview() }
        removeButtons.forEach { $0.removeFromSuperview() }
        removeButtons = []
        resultButtons = locations.enumerated().map { index, location in
            let canRemove = allowsRemoval && !location.isHome
            let rowY = 228 - CGFloat(index) * 52
            let button = NSButton(title: "", target: self, action: #selector(selectResult(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.22, alpha: 1).cgColor
            button.layer?.cornerRadius = 9
            button.frame = NSRect(x: 22, y: rowY, width: canRemove ? 376 : 416, height: 46)
            let title = NSMutableAttributedString(string: "  \(location.name)\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
            title.append(NSAttributedString(string: "  \(location.detail)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)]))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
            button.attributedTitle = title
            button.setAccessibilityLabel("\(location.name), \(location.detail) 날씨 보기")
            button.toolTip = "\(location.name) · \(location.detail)"
            addSubview(button)
            if canRemove {
                let remove = NSButton(title: "×", target: self, action: #selector(removeRecentLocation(_:)))
                remove.tag = index
                remove.frame = NSRect(x: 406, y: rowY + 8, width: 32, height: 30)
                remove.isBordered = false
                remove.font = .systemFont(ofSize: 20, weight: .regular)
                remove.contentTintColor = .secondaryLabelColor
                remove.wantsLayer = true
                remove.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
                remove.layer?.cornerRadius = 8
                let label = "\(location.name) 최근 기록 삭제"
                remove.toolTip = label
                remove.setAccessibilityLabel(label)
                addSubview(remove)
                removeButtons.append(remove)
            }
            return button
        }
    }

    @objc private func removeRecentLocation(_ sender: NSButton) {
        guard showingRecentLocations, locations.indices.contains(sender.tag) else { return }
        let location = locations[sender.tag]
        guard !location.isHome else { return }
        let remaining = Self.recentLocations().filter { $0.id != location.id }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentKey)
        showRecentLocations()
    }

    @objc private func selectResult(_ sender: NSButton) {
        guard locations.indices.contains(sender.tag) else { return }
        let location = locations[sender.tag]
        if !location.isHome {
            var recent = Self.recentLocations().filter { $0.id != location.id }
            recent.insert(location, at: 0)
            if let data = try? JSONEncoder().encode(Array(recent.prefix(4))) {
                UserDefaults.standard.set(data, forKey: Self.recentKey)
            }
        }
        cancelSearch()
        onSelect(location)
    }

    private static func recentLocations() -> [WeatherLocation] {
        guard let data = UserDefaults.standard.data(forKey: recentKey), let locations = try? JSONDecoder().decode([WeatherLocation].self, from: data) else { return [] }
        return locations
    }
}
