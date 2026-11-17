import Foundation

/// A routable bike network: intersections joined by road segments, each annotated with how
/// much of it is still under fog and how bike-friendly it is.
///
/// Each undirected `Edge` yields two directed "arcs": arc `2e` runs a -> b, arc `2e + 1` runs b -> a.
struct RoadGraph: Sendable {
    struct Edge: Sendable {
        var a: Int32
        var b: Int32
        var length: Float
        /// Meters of this segment that are still fogged.
        var newMeters: Float
        /// 1 = dedicated bike path ... 0 = busy road without bike infrastructure.
        var bike: Float
        /// 0 = both ways, 1 = only a -> b, -1 = only b -> a.
        var oneway: Int8
        var geomStart: Int32
        var geomCount: Int32
        var name: Int32
        /// The exposure cells this segment passes through are
        /// `edgeCells[cellStart ..< cellStart + cellCount]`.
        var cellStart: Int32
        var cellCount: Int32
    }

    /// Fog is judged on "exposure cells" of 3 x 3 Fog of World cells (about 23 m at 37 degrees
    /// latitude). A cell counts as seen if any part of it is uncovered, and riding through a cell
    /// clears it for every road that shares it, so parallel carriageways and a road next to a
    /// path you've already ridden don't count as new twice.
    static let exposure = 3
    /// Ids of exposure cells, per segment (see `Edge.cellStart`).
    var edgeCells: [Int32] = []
    /// For each exposure cell id, whether it is still entirely under fog.
    var cellFogged: [Bool] = []

    var nodes: [Coord] = []
    var edges: [Edge] = []
    var geom: [Coord] = []
    var names: [String] = [""]

    /// Outgoing arcs of node `n` are `adjArcs[adjStart[n] ..< adjStart[n + 1]]`.
    var adjStart: [Int32] = []
    var adjArcs: [Int32] = []
    /// Compass bearing when leaving the arc's tail / arriving at the arc's head.
    var arcOutBearing: [Float] = []
    var arcInBearing: [Float] = []
    /// Number of distinct segments meeting at each node.
    var degree: [UInt8] = []
    /// False for nodes on dead-end branches; waypoints are only placed on core nodes.
    var core: [Bool] = []
    var component: [Int32] = []

    // Spatial grid for nearest-node lookups and fog density.
    var gridOrigin = Coord(lat: 0, lon: 0)
    var gridCellLat = 0.0
    var gridCellLon = 0.0
    var gridW = 0
    var gridH = 0
    var gridNodes: [[Int32]] = []
    /// Fogged meters of road per grid cell, smoothed over neighbors.
    var gridFog: [Float] = []

    @inline(__always) func arcEdge(_ arc: Int32) -> Int { Int(arc >> 1) }
    @inline(__always) func arcTail(_ arc: Int32) -> Int32 {
        arc & 1 == 0 ? edges[Int(arc >> 1)].a : edges[Int(arc >> 1)].b
    }
    @inline(__always) func arcHead(_ arc: Int32) -> Int32 {
        arc & 1 == 0 ? edges[Int(arc >> 1)].b : edges[Int(arc >> 1)].a
    }

    func coords(ofArc arc: Int32) -> [Coord] {
        let e = edges[arcEdge(arc)]
        let slice = geom[Int(e.geomStart)..<Int(e.geomStart + e.geomCount)]
        return arc & 1 == 0 ? Array(slice) : slice.reversed()
    }

    // MARK: - Classification

    /// Bike-friendliness in 0...1, or nil when bikes can't or shouldn't use the way.
    static func bikeScore(_ t: [String: String]) -> Float? {
        guard let highway = t["highway"] else { return nil }
        let bicycle = t["bicycle"] ?? ""
        if bicycle == "no" || bicycle == "private" || bicycle == "dismount" { return nil }
        let access = t["access"] ?? ""
        if (access == "no" || access == "private") && !["yes", "designated", "permissive"].contains(bicycle) {
            return nil
        }
        if t["area"] == "yes" { return nil }

        let cyclewayTags = ["cycleway", "cycleway:both", "cycleway:left", "cycleway:right"].compactMap { t[$0] }
        var infra: Float = 0
        for v in cyclewayTags {
            switch v {
            case "track", "separate", "opposite_track": infra = max(infra, 0.95)
            case "lane", "opposite_lane", "buffered_lane": infra = max(infra, 0.85)
            case "shared_lane", "share_busway", "shoulder", "opposite": infra = max(infra, 0.55)
            default: break
            }
        }
        if bicycle == "designated" { infra = max(infra, 0.8) }
        if t["bicycle_road"] == "yes" || t["cyclestreet"] == "yes" { infra = max(infra, 0.9) }

        let base: Float
        switch highway {
        case "cycleway": base = 1.0
        case "path", "footway", "pedestrian", "bridleway":
            guard ["yes", "designated", "permissive"].contains(bicycle) else { return nil }
            base = bicycle == "designated" ? 1.0 : 0.7
        case "living_street": base = 0.6
        case "residential": base = 0.5
        case "unclassified", "road": base = 0.4
        case "service":
            if let s = t["service"], ["parking_aisle", "driveway", "drive-through"].contains(s) { return nil }
            base = 0.3
        case "track":
            if let g = t["tracktype"], ["grade4", "grade5"].contains(g) { return nil }
            base = 0.35
        case "tertiary", "tertiary_link": base = 0.3
        case "secondary", "secondary_link": base = 0.15
        case "primary", "primary_link": base = 0.05
        case "trunk", "trunk_link":
            guard infra > 0 || bicycle == "yes" else { return nil }
            base = 0.0
        default: return nil
        }
        if let surface = t["surface"], ["sand", "mud", "grass", "ground", "dirt", "earth"].contains(surface) {
            return max(0.1, max(base, infra) - 0.4)
        }
        return max(base, infra)
    }

    static func onewayDirection(_ t: [String: String]) -> Int8 {
        if t["oneway:bicycle"] == "no" { return 0 }
        if (t["cycleway"] ?? "").hasPrefix("opposite") { return 0 }
        if ["cycleway:left", "cycleway:right", "cycleway:both"].contains(where: { (t[$0] ?? "").hasPrefix("opposite") }) {
            return 0
        }
        switch t["oneway"] {
        case "yes", "true", "1": return 1
        case "-1", "reverse": return -1
        default: return t["junction"] == "roundabout" ? 1 : 0
        }
    }

    // MARK: - Construction

    init(ways: [OSMWay], fog: FogMap?) {
        struct Usable {
            let way: OSMWay
            let bike: Float
            let oneway: Int8
        }
        let usable: [Usable] = ways.compactMap { w in
            guard w.nodes.count >= 2, w.nodes.count == w.geometry.count,
                  let score = Self.bikeScore(w.tags) else { return nil }
            return Usable(way: w, bike: score, oneway: Self.onewayDirection(w.tags))
        }

        // A node is a graph vertex if it ends a way or is shared between ways.
        var uses: [Int64: Int] = [:]
        uses.reserveCapacity(usable.count * 8)
        for u in usable {
            let n = u.way.nodes
            for (i, id) in n.enumerated() {
                uses[id, default: 0] += (i == 0 || i == n.count - 1) ? 2 : 1
            }
        }

        var nodeIndex: [Int64: Int32] = [:]
        var nameIndex: [String: Int32] = [:]
        func vertex(_ id: Int64, _ p: OSMWay.Point) -> Int32 {
            if let i = nodeIndex[id] { return i }
            let i = Int32(nodes.count)
            nodes.append(Coord(lat: p.lat, lon: p.lon))
            nodeIndex[id] = i
            return i
        }

        var cellIDs: [Int64: Int32] = [:]
        func exposureCell(_ key: Int64) -> Int32 {
            if let id = cellIDs[key] { return id }
            let x0 = Int(key >> 32) * Self.exposure, y0 = Int(key & 0xFFFF_FFFF) * Self.exposure
            var seen = false
            for dy in 0..<Self.exposure where !seen {
                for dx in 0..<Self.exposure where fog?.isVisited(cellX: x0 + dx, cellY: y0 + dy) == true {
                    seen = true
                    break
                }
            }
            let id = Int32(cellFogged.count)
            cellFogged.append(!seen)
            cellIDs[key] = id
            return id
        }

        for u in usable {
            let w = u.way
            var nameID: Int32 = 0
            if let name = w.tags["name"] {
                if let i = nameIndex[name] { nameID = i } else {
                    nameID = Int32(names.count)
                    names.append(name)
                    nameIndex[name] = nameID
                }
            }
            var segStart = 0
            for i in 1..<w.nodes.count where (uses[w.nodes[i]] ?? 0) > 1 {
                let a = vertex(w.nodes[segStart], w.geometry[segStart])
                let b = vertex(w.nodes[i], w.geometry[i])
                let pts = w.geometry[segStart...i].map { Coord(lat: $0.lat, lon: $0.lon) }
                segStart = i
                guard a != b else { continue }
                var length = 0.0
                var passed: [Int64] = []
                var cells: [Int32] = []
                var fogged = 0
                for j in 1..<pts.count {
                    let d = Geo.distance(pts[j - 1], pts[j])
                    length += d
                    guard fog != nil else { continue }
                    // Sample a little finer than one fog cell (about 8 m).
                    let steps = max(1, Int((d / 6).rounded(.up)))
                    for s in 0...steps {
                        guard let cell = FogMap.cell(of: Geo.lerp(pts[j - 1], pts[j], Double(s) / Double(steps))) else { continue }
                        let key = Int64(cell.x / Self.exposure) << 32 | Int64(cell.y / Self.exposure)
                        if passed.contains(key) { continue }
                        passed.append(key)
                        let id = exposureCell(key)
                        cells.append(id)
                        if cellFogged[Int(id)] { fogged += 1 }
                    }
                }
                guard length > 0.5 else { continue }
                edges.append(Edge(a: a, b: b, length: Float(length),
                                  newMeters: Float(length) * Float(fogged) / Float(max(1, cells.count)),
                                  bike: u.bike, oneway: u.oneway,
                                  geomStart: Int32(geom.count), geomCount: Int32(pts.count), name: nameID,
                                  cellStart: Int32(edgeCells.count), cellCount: Int32(cells.count)))
                edgeCells.append(contentsOf: cells)
                geom.append(contentsOf: pts)
            }
        }

        buildAdjacency()
        buildBearings()
        buildTopology()
        buildGrid()
    }

    private mutating func buildAdjacency() {
        var counts = [Int32](repeating: 0, count: nodes.count + 1)
        for e in edges {
            if e.oneway >= 0 { counts[Int(e.a) + 1] += 1 }
            if e.oneway <= 0 { counts[Int(e.b) + 1] += 1 }
        }
        for i in 1...max(1, nodes.count) where i < counts.count { counts[i] += counts[i - 1] }
        adjStart = counts
        adjArcs = [Int32](repeating: 0, count: Int(counts.last ?? 0))
        var fill = Array(counts.dropLast())
        for (i, e) in edges.enumerated() {
            if e.oneway >= 0 { adjArcs[Int(fill[Int(e.a)])] = Int32(i * 2); fill[Int(e.a)] += 1 }
            if e.oneway <= 0 { adjArcs[Int(fill[Int(e.b)])] = Int32(i * 2 + 1); fill[Int(e.b)] += 1 }
        }
    }

    /// Bearing measured ~20 m into the segment so that tiny kinks at junctions don't count as turns.
    private mutating func buildBearings() {
        arcOutBearing = [Float](repeating: 0, count: edges.count * 2)
        arcInBearing = [Float](repeating: 0, count: edges.count * 2)
        func headingFromStart(_ pts: [Coord]) -> Float {
            var travelled = 0.0
            var target = pts[pts.count - 1]
            for j in 1..<pts.count {
                travelled += Geo.distance(pts[j - 1], pts[j])
                if travelled >= 20 { target = pts[j]; break }
            }
            return Float(Geo.bearing(pts[0], target))
        }
        for i in edges.indices {
            let e = edges[i]
            let pts = Array(geom[Int(e.geomStart)..<Int(e.geomStart + e.geomCount)])
            let rev = Array(pts.reversed())
            let startHeading = headingFromStart(pts)
            let endHeading = headingFromStart(rev)
            arcOutBearing[i * 2] = startHeading
            arcInBearing[i * 2] = (endHeading + 180).truncatingRemainder(dividingBy: 360)
            arcOutBearing[i * 2 + 1] = endHeading
            arcInBearing[i * 2 + 1] = (startHeading + 180).truncatingRemainder(dividingBy: 360)
        }
    }

    private mutating func buildTopology() {
        // Connected components (ignoring one-way restrictions).
        var parent = Array(0..<Int32(nodes.count))
        func find(_ x: Int32) -> Int32 {
            var r = x
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = x
            while parent[Int(c)] != r { let next = parent[Int(c)]; parent[Int(c)] = r; c = next }
            return r
        }
        var deg = [Int](repeating: 0, count: nodes.count)
        for e in edges {
            let ra = find(e.a), rb = find(e.b)
            if ra != rb { parent[Int(ra)] = rb }
            deg[Int(e.a)] += 1
            deg[Int(e.b)] += 1
        }
        component = (0..<Int32(nodes.count)).map { find($0) }
        degree = deg.map { UInt8(min(255, $0)) }

        // Strip dead-end branches: repeatedly remove nodes with a single remaining segment.
        var incident = [[Int32]](repeating: [], count: nodes.count)
        for (i, e) in edges.enumerated() {
            incident[Int(e.a)].append(Int32(i))
            incident[Int(e.b)].append(Int32(i))
        }
        var removed = [Bool](repeating: false, count: edges.count)
        var live = deg
        var stack = (0..<nodes.count).filter { live[$0] == 1 }
        core = [Bool](repeating: true, count: nodes.count)
        while let n = stack.popLast() {
            guard live[n] == 1 else { continue }
            core[n] = false
            guard let ei = incident[n].first(where: { !removed[Int($0)] }) else { continue }
            removed[Int(ei)] = true
            let e = edges[Int(ei)]
            let other = Int(e.a) == n ? Int(e.b) : Int(e.a)
            live[n] = 0
            live[other] -= 1
            if live[other] == 1 { stack.append(other) }
        }
        for n in 0..<nodes.count where live[n] == 0 { core[n] = false }
    }

    private mutating func buildGrid() {
        guard let first = nodes.first else { return }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for n in nodes {
            minLat = min(minLat, n.lat); maxLat = max(maxLat, n.lat)
            minLon = min(minLon, n.lon); maxLon = max(maxLon, n.lon)
        }
        let cell = 200.0
        gridCellLat = cell / 111_320
        gridCellLon = cell / (111_320 * max(0.1, cos(first.lat * .pi / 180)))
        gridOrigin = Coord(lat: minLat, lon: minLon)
        gridW = Int((maxLon - minLon) / gridCellLon) + 1
        gridH = Int((maxLat - minLat) / gridCellLat) + 1
        gridNodes = [[Int32]](repeating: [], count: gridW * gridH)
        for (i, n) in nodes.enumerated() {
            let (x, y) = cellXY(n)
            gridNodes[y * gridW + x].append(Int32(i))
        }
        var raw = [Float](repeating: 0, count: gridW * gridH)
        for e in edges {
            let mid = geom[Int(e.geomStart) + Int(e.geomCount) / 2]
            let (x, y) = cellXY(mid)
            raw[y * gridW + x] += e.newMeters
        }
        gridFog = [Float](repeating: 0, count: gridW * gridH)
        for y in 0..<gridH {
            for x in 0..<gridW {
                var sum: Float = 0
                for dy in -2...2 where y + dy >= 0 && y + dy < gridH {
                    for dx in -2...2 where x + dx >= 0 && x + dx < gridW {
                        sum += raw[(y + dy) * gridW + x + dx]
                    }
                }
                gridFog[y * gridW + x] = sum
            }
        }
    }

    func cellXY(_ c: Coord) -> (Int, Int) {
        let x = Int((c.lon - gridOrigin.lon) / gridCellLon)
        let y = Int((c.lat - gridOrigin.lat) / gridCellLat)
        return (max(0, min(gridW - 1, x)), max(0, min(gridH - 1, y)))
    }

    /// Visits nodes in grid cells within `radius` meters of `c`.
    func forEachNode(near c: Coord, radius: Double, _ body: (Int32) -> Void) {
        guard gridW > 0 else { return }
        let r = Int((radius / 200).rounded(.up))
        let (cx, cy) = cellXY(c)
        for y in max(0, cy - r)...min(gridH - 1, cy + r) {
            for x in max(0, cx - r)...min(gridW - 1, cx + r) {
                for n in gridNodes[y * gridW + x] { body(n) }
            }
        }
    }

    /// Nearest node to `c`, optionally restricted by a predicate.
    func nearestNode(to c: Coord, maxRadius: Double = 3_000, where ok: (Int32) -> Bool = { _ in true }) -> Int32? {
        var radius = 200.0
        while radius <= maxRadius {
            var best: Int32? = nil
            var bestD = Double.infinity
            forEachNode(near: c, radius: radius) { n in
                guard ok(n) else { return }
                let d = Geo.distance(c, nodes[Int(n)])
                if d < bestD { bestD = d; best = n }
            }
            if let best, bestD <= radius { return best }
            radius *= 2
        }
        return nil
    }

    /// The component with the most nodes; routes are planned inside it.
    func largestComponent() -> Int32? {
        var counts: [Int32: Int] = [:]
        for c in component { counts[c, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
}
