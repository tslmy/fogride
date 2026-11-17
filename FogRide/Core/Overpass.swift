import Foundation

/// A road ("way") from OpenStreetMap.
struct OSMWay: Decodable, Sendable {
    struct Point: Decodable, Sendable {
        let lat: Double
        let lon: Double
    }
    let id: Int64
    /// One stable key per vertex. Overpass is asked for geometry only (much smaller than node
    /// ids + geometry), and OSM nodes shared between ways have identical coordinates.
    let nodes: [Int64]
    let geometry: [Point]
    let tags: [String: String]

    enum CodingKeys: String, CodingKey { case id, geometry, tags }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        geometry = (try c.decodeIfPresent([Point?].self, forKey: .geometry) ?? []).compactMap { $0 }
        nodes = geometry.map {
            (Int64(($0.lat * 1e7).rounded()) + 900_000_000) << 32 | (Int64(($0.lon * 1e7).rounded()) + 1_800_000_000)
        }
        tags = try c.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
    }
}

private struct OverpassResponse: Decodable {
    let elements: [OSMWay]
}

/// Downloads rideable roads around a point from the Overpass API, with an on-disk cache.
enum Overpass {
    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]
    /// Radii we fetch, so that small changes in the distance slider reuse the cache.
    /// The public servers take 40-50 s to answer whether the area is tiny or large (the time is
    /// spent queuing), so one generous area is fetched: it covers every ride length and lets the
    /// start move several kilometers before anything has to be downloaded again.
    static let fetchRadius: Double = 14_000
    /// Largest radius a plan may ask for.
    static let maxPlanRadius: Double = 12_000
    /// Cached roads older than this are still used, but refreshed in the background.
    static let refreshAge: TimeInterval = 30 * 24 * 3600

    struct Area: Sendable {
        let center: Coord
        let radius: Double
        /// The area is the square of half-side `radius` around `center` (what is downloaded).
        func covers(_ c: Coord, radius r: Double) -> Bool {
            let north = abs(c.lat - center.lat) * 111_320
            let east = abs(c.lon - center.lon) * 111_320 * cos(center.lat * .pi / 180)
            return max(north, east) + r <= radius
        }
    }

    enum OverpassError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return "Couldn't download road data from OpenStreetMap (\(why))."
            }
        }
    }

    /// Bounding-box query (far cheaper for the servers than a radius query) for the square
    /// that encloses the circle of `radius` around `center`.
    static func query(center: Coord, radius: Double) -> String {
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * max(0.1, cos(center.lat * .pi / 180)))
        let bbox = String(format: "%.5f,%.5f,%.5f,%.5f",
                          center.lat - dLat, center.lon - dLon, center.lat + dLat, center.lon + dLon)
        return """
        [out:json][timeout:120][bbox:\(bbox)];(\
        way["highway"~"^(cycleway|residential|living_street|unclassified|tertiary|tertiary_link|secondary|secondary_link|primary|primary_link|trunk|trunk_link|track|road)$"];\
        way["highway"="service"]["service"!~"^(parking_aisle|driveway|drive-through)$"];\
        way["highway"~"^(path|footway|pedestrian|bridleway)$"]["bicycle"~"^(yes|designated|permissive)$"];\
        );out tags geom qt;
        """
    }

    private static var cacheDir: URL {
        // Application Support rather than Caches, so iOS doesn't purge it when storage is low.
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("osm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    private static func cacheURL(_ area: Area) -> URL {
        cacheDir.appendingPathComponent(
            String(format: "%.5f_%.5f_%.0f.json", area.center.lat, area.center.lon, area.radius))
    }

    private static func cachedAreas() -> [(area: Area, url: URL, age: TimeInterval)] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let age = Date().timeIntervalSince(date)
            if age > 12 * refreshAge {
                try? fm.removeItem(at: url)
                return nil
            }
            return (Area(center: Coord(lat: parts[0], lon: parts[1]), radius: parts[2]), url, age)
        }
    }

    static func decode(_ data: Data) throws -> [OSMWay] {
        try JSONDecoder().decode(OverpassResponse.self, from: data).elements
    }

    /// Roads covering at least `radius` meters around `center`. Cached roads are returned
    /// immediately whatever their age; old ones are refreshed in the background for next time.
    static func roads(around center: Coord, radius: Double,
                      progress: @Sendable (String) -> Void = { _ in }) async throws -> (ways: [OSMWay], area: Area) {
        // Freshest cached area that covers the request.
        let hits = cachedAreas().filter { $0.area.covers(center, radius: radius) }.sorted { $0.age < $1.age }
        for hit in hits {
            if let data = try? Data(contentsOf: hit.url), let ways = try? decode(data), !ways.isEmpty {
                if hit.age > refreshAge {
                    Task.detached(priority: .utility) { _ = try? await download(Area(center: center, radius: fetchRadius)) }
                }
                return (ways, hit.area)
            }
        }
        progress("Downloading roads (about a minute, first time only)…")
        let area = Area(center: center, radius: fetchRadius)
        return (try await download(area), area)
    }

    /// Fetches and caches the roads of `area`.
    private static func download(_ area: Area) async throws -> [OSMWay] {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let encoded = query(center: area.center, radius: area.radius)
            .addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        let payload = Data(("data=" + encoded).utf8)

        // The public servers are often busy, so ask all of them at once and take the first answer.
        enum Outcome: Sendable {
            case success(Data, [OSMWay])
            case failure(String)
        }
        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    var problem = "no response"
                    for attempt in 0..<4 {
                        if Task.isCancelled { break }
                        var req = URLRequest(url: URL(string: endpoint)!)
                        req.httpMethod = "POST"
                        req.httpBody = payload
                        req.timeoutInterval = 150
                        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                        req.setValue("FogRide/1.0", forHTTPHeaderField: "User-Agent")
                        do {
                            let (data, response) = try await URLSession.shared.data(for: req)
                            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                            if code == 200, let ways = try? decode(data), !ways.isEmpty {
                                return .success(data, ways)
                            }
                            problem = code == 200 ? "no roads found here" : "the road servers are busy"
                        } catch {
                            problem = error.localizedDescription
                        }
                        try? await Task.sleep(nanoseconds: UInt64(3 << attempt) * 1_000_000_000)
                    }
                    return .failure(problem)
                }
            }
            var last = Outcome.failure("no response")
            for await result in group {
                last = result
                if case .success = result {
                    group.cancelAll()
                    break
                }
            }
            return last
        }
        try Task.checkCancellation()
        switch outcome {
        case .success(let data, let ways):
            // Drop older downloads that this one makes redundant.
            for old in cachedAreas() where area.covers(old.area.center, radius: old.area.radius) {
                try? FileManager.default.removeItem(at: old.url)
            }
            try? data.write(to: cacheURL(area), options: .atomic)
            return ways
        case .failure(let problem):
            throw OverpassError.unavailable(problem)
        }
    }
}
