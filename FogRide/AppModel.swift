import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case needsFog
        case locating
        case working(String)
        case ready
        case failed(String)
    }

    static let distanceRange: ClosedRange<Double> = 5...40

    var phase: Phase = .needsFog
    var routes: [PlannedRoute] = []
    var selectedID: Int?
    var userLocation: Coord?
    /// A start point chosen on the map; nil means "start where I am".
    var customStart: Coord?
    var locationDenied = false
    var fogFolderName: String?
    var fogTileCount = 0
    /// Where the current routes actually start (the nearest junction to the requested start).
    var plannedStart: Coord?
    /// When the current road download began; nil when nothing is downloading.
    var downloadStarted: Date?
    /// How long the last road download took, used to pace the progress bar.
    var typicalDownloadSeconds: Double {
        UserDefaults.standard.object(forKey: "downloadSeconds") as? Double ?? 45
    }

    var targetKm: Double = UserDefaults.standard.object(forKey: "targetKm") as? Double ?? 15 {
        didSet { UserDefaults.standard.set(targetKm, forKey: "targetKm") }
    }
    var speedKmh: Double = UserDefaults.standard.object(forKey: "speedKmh") as? Double ?? 18 {
        didSet { UserDefaults.standard.set(speedKmh, forKey: "speedKmh") }
    }

    var start: Coord? { customStart ?? userLocation }
    var selected: PlannedRoute? { routes.first { $0.id == selectedID } }

    private(set) var fog: FogMap?
    @ObservationIgnored private var scopedFolder: URL?
    @ObservationIgnored private var graph: RoadGraph?
    @ObservationIgnored private var graphArea: Overpass.Area?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    @ObservationIgnored private let locationManager = CLLocationManager()

    private static let bookmarkKey = "fogFolderBookmark"

    init() {
        restoreFogFolder()
    }

    // MARK: - Fog of World folder

    /// Folder the user can drop a copy of `Sync` into via the Files app or Finder.
    private static var documentsSync: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sync")
    }

    private func restoreFogFolder() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale), adopt(folder: url) {
                if stale, let fresh = try? url.bookmarkData() {
                    UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                }
                return
            }
        }
        _ = adopt(folder: Self.documentsSync)
    }

    @discardableResult
    private func adopt(folder url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        guard let map = try? FogMap(folder: url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return false
        }
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = scoped ? url : nil
        fog = map
        fogFolderName = map.folder.lastPathComponent
        fogTileCount = map.tileCount
        graph = nil
        graphArea = nil
        if phase == .needsFog { phase = .locating }
        return true
    }

    /// Called with the folder chosen in the system folder picker.
    func useFogFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData()
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard adopt(folder: url) else {
            phase = fog == nil ? .needsFog : phase
            pickerError = FogMap.FogError.notASyncFolder.localizedDescription
            return
        }
        pickerError = nil
        if let bookmark { UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey) }
        startLocation()
        plan()
    }

    var pickerError: String?

    // MARK: - Location

    func startLocation() {
        guard fog != nil, locationTask == nil else { return }
        locationManager.requestWhenInUseAuthorization()
        locationTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        self.locationDenied = true
                    }
                    guard let loc = update.location, loc.horizontalAccuracy >= 0 else { continue }
                    self.locationDenied = false
                    let first = self.userLocation == nil
                    self.userLocation = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
                    if first, self.customStart == nil { self.plan() }
                }
            } catch {}
        }
    }

    func startFromMyLocation() {
        customStart = nil
        plan()
    }

    func startFrom(_ c: Coord) {
        customStart = c
        plan()
    }

    // MARK: - Planning

    /// Re-plans straight away when the roads already in memory cover the chosen distance, so the
    /// loops follow the slider while it is being dragged. Otherwise planning waits for release.
    func planIfRoadsLoaded() {
        guard let start, graph != nil, graphArea?.covers(start, radius: neededRadius) == true else { return }
        plan()
    }

    private var neededRadius: Double {
        min(Overpass.maxPlanRadius, max(2_000, targetKm * 1000 * 0.3))
    }

    func plan() {
        planTask?.cancel()
        downloadStarted = nil
        guard let fog else { phase = .needsFog; return }
        guard let start else { phase = .locating; return }
        let target = targetKm * 1000
        let needRadius = neededRadius
        let existing = (graphArea?.covers(start, radius: needRadius) ?? false) ? graph : nil

        phase = .working(existing == nil ? "Loading roads…" : "Finding loops…")
        planTask = Task { [weak self] in
            do {
                var g = existing
                if g == nil {
                    let (ways, area) = try await Overpass.roads(around: start, radius: needRadius) { message in
                        Task { @MainActor in
                            guard let self, !Task.isCancelled else { return }
                            self.phase = .working(message)
                            self.downloadStarted = Date()
                        }
                    }
                    try Task.checkCancellation()
                    if let began = self?.downloadStarted {
                        UserDefaults.standard.set(Date().timeIntervalSince(began), forKey: "downloadSeconds")
                        self?.downloadStarted = nil
                    }
                    self?.phase = .working("Checking roads against your fog…")
                    let built = await Task.detached(priority: .userInitiated) { RoadGraph(ways: ways, fog: fog) }.value
                    try Task.checkCancellation()
                    self?.graph = built
                    self?.graphArea = area
                    g = built
                }
                guard let g else { return }
                self?.phase = .working("Finding loops…")
                let planner = Planner(g: g)
                let found = await planner.plan(start: start, target: target)
                try Task.checkCancellation()
                guard let self else { return }
                self.routes = found
                self.selectedID = found.first?.id
                self.plannedStart = found.first?.coords.first
                self.phase = found.isEmpty
                    ? .failed("No rideable loop found from here. Try a different start or distance.")
                    : .ready
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.downloadStarted = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
    }
}
