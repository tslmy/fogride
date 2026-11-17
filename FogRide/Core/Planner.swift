import Foundation

struct PlannedRoute: Identifiable, Sendable {
    struct Run: Identifiable, Sendable {
        let id: Int
        /// True when this stretch is still under fog (and not a repeat within the route).
        let isNew: Bool
        let coords: [Coord]
    }

    var id: Int
    var name: String
    var coords: [Coord]
    var runs: [Run]
    /// All in meters.
    var length: Double
    var newMeters: Double
    var repeatMeters: Double
    var bikeMeters: Double
    var turns: Int
    var score: Double
    /// Segment -> length, for measuring overlap between candidates.
    var edgeLengths: [Int32: Float]

    var newFraction: Double { length > 0 ? newMeters / length : 0 }
    var bikeFraction: Double { length > 0 ? bikeMeters / length : 0 }

    /// Riding time in seconds at the given cruising speed, allowing a few seconds per turn.
    func duration(speedKmh: Double) -> TimeInterval {
        length / (max(5, speedKmh) / 3.6) + Double(turns) * 5
    }

    func overlap(with other: PlannedRoute) -> Double {
        var shared: Float = 0
        for (e, len) in edgeLengths where other.edgeLengths[e] != nil { shared += len }
        return Double(shared) / max(1, min(length, other.length))
    }
}

/// Tuning knobs. Costs are expressed in "equivalent meters".
struct PlannerWeights: Sendable {
    /// Extra cost per meter on road already uncovered in Fog of World.
    var visited: Float = 1.5
    /// Extra cost per meter on the least bike-friendly roads.
    var unfriendly: Float = 1.2
    /// Cost multiplier for riding a segment a second time within the same route.
    var repeatMultiplier: Float = 3
    var turn: Float = 70
    var sharpTurn: Float = 100
    var uTurn: Float = 400
}

private struct MinHeap {
    private var items: [(Float, Int32)] = []
    var isEmpty: Bool { items.isEmpty }
    mutating func removeAll() { items.removeAll(keepingCapacity: true) }
    mutating func push(_ key: Float, _ value: Int32) {
        items.append((key, value))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if items[p].0 <= items[i].0 { break }
            items.swapAt(p, i)
            i = p
        }
    }
    mutating func pop() -> (Float, Int32)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l].0 < items[m].0 { m = l }
                if r < items.count, items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(m, i)
                i = m
            }
        }
        return top
    }
}

/// Cheapest-path search over directed arcs, so that turn costs can depend on the previous arc.
private struct Searcher {
    let g: RoadGraph
    let w: PlannerWeights
    var dist: [Float]
    var prev: [Int32]
    var stamp: [UInt32]
    var run: UInt32 = 0
    var heap = MinHeap()
    /// How many times the route under construction already uses each segment.
    var used: [UInt8]
    /// How many times the route under construction already passes through each exposure cell.
    var covered: [UInt8]
    /// Share of each segment that would still be new, cached until the route changes.
    var freshCache: [Float]
    var freshStamp: [UInt32]
    var routeVersion: UInt32 = 1

    init(_ g: RoadGraph, _ w: PlannerWeights) {
        self.g = g
        self.w = w
        dist = [Float](repeating: 0, count: g.edges.count * 2)
        prev = [Int32](repeating: -1, count: g.edges.count * 2)
        stamp = [UInt32](repeating: 0, count: g.edges.count * 2)
        used = [UInt8](repeating: 0, count: g.edges.count)
        covered = [UInt8](repeating: 0, count: g.cellFogged.count)
        freshCache = [Float](repeating: 0, count: g.edges.count)
        freshStamp = [UInt32](repeating: 0, count: g.edges.count)
    }

    /// Starts a new, empty route.
    mutating func reset() {
        for i in used.indices { used[i] = 0 }
        for i in covered.indices { covered[i] = 0 }
        routeVersion &+= 1
    }

    /// Adds (`delta` = 1) or removes (-1) arcs from the route under construction.
    mutating func mark(_ arcs: [Int32], _ delta: Int) {
        for a in arcs {
            let e = g.edges[Int(a >> 1)]
            if delta > 0 { used[Int(a >> 1)] &+= 1 } else { used[Int(a >> 1)] &-= 1 }
            for i in Int(e.cellStart)..<Int(e.cellStart + e.cellCount) {
                let c = Int(g.edgeCells[i])
                if delta > 0 { covered[c] &+= 1 } else { covered[c] &-= 1 }
            }
        }
        routeVersion &+= 1
    }

    /// Share of the segment's cells that are fogged and not yet cleared by the route so far.
    @inline(__always) mutating func fresh(_ edge: Int) -> Float {
        if freshStamp[edge] == routeVersion { return freshCache[edge] }
        let e = g.edges[edge]
        var n = 0
        for i in Int(e.cellStart)..<Int(e.cellStart + e.cellCount) {
            let c = Int(g.edgeCells[i])
            if g.cellFogged[c], covered[c] == 0 { n += 1 }
        }
        let f = e.cellCount > 0 ? Float(n) / Float(e.cellCount) : 0
        freshCache[edge] = f
        freshStamp[edge] = routeVersion
        return f
    }

    @inline(__always) mutating func cost(_ arc: Int32, after prevArc: Int32) -> Float {
        let e = g.edges[Int(arc >> 1)]
        var mult = 1 + w.unfriendly * (1 - e.bike)
        if used[Int(arc >> 1)] > 0 {
            mult = (mult + w.visited) * w.repeatMultiplier
        } else {
            mult += w.visited * (1 - fresh(Int(arc >> 1)))
        }
        var c = e.length * mult
        if prevArc >= 0 {
            if prevArc == arc ^ 1 {
                c += w.uTurn
            } else if let diff = g.turnAngle(from: prevArc, to: arc) {
                c += diff > 100 ? w.sharpTurn : w.turn
            }
        }
        return c
    }

    /// Arcs of the cheapest path from node `s` to node `t`, continuing on from `after` (or -1).
    mutating func path(from s: Int32, to t: Int32, after: Int32) -> [Int32]? {
        guard s != t else { return [] }
        run &+= 1
        heap.removeAll()
        for i in Int(g.adjStart[Int(s)])..<Int(g.adjStart[Int(s) + 1]) {
            let arc = g.adjArcs[i]
            let c = cost(arc, after: after)
            dist[Int(arc)] = c
            prev[Int(arc)] = -1
            stamp[Int(arc)] = run
            heap.push(c, arc)
        }
        while let (d, arc) = heap.pop() {
            if d > dist[Int(arc)] { continue }
            let head = g.arcHead(arc)
            if head == t {
                var out: [Int32] = []
                var cur = arc
                while cur >= 0 {
                    out.append(cur)
                    cur = prev[Int(cur)]
                }
                return out.reversed()
            }
            for i in Int(g.adjStart[Int(head)])..<Int(g.adjStart[Int(head) + 1]) {
                let next = g.adjArcs[i]
                let nd = d + cost(next, after: arc)
                if stamp[Int(next)] != run || nd < dist[Int(next)] {
                    stamp[Int(next)] = run
                    dist[Int(next)] = nd
                    prev[Int(next)] = arc
                    heap.push(nd, next)
                }
            }
        }
        return nil
    }
}

extension RoadGraph {
    /// Angle turned through when going from arc `a` onto arc `b` at a junction, if it is more
    /// than a gentle bend. Curves along a single road don't count.
    @inline(__always) func turnAngle(from a: Int32, to b: Int32) -> Double? {
        guard degree[Int(arcTail(b))] >= 3 else { return nil }
        let diff = Geo.angleDiff(Double(arcInBearing[Int(a)]), Double(arcOutBearing[Int(b)]))
        return diff > 45 ? diff : nil
    }
}

struct Planner: Sendable {
    let g: RoadGraph
    var weights = PlannerWeights()
    var maxRoutes = 4

    /// Node where routes start and end: the closest junction in the main network.
    func startNode(near c: Coord) -> Int32? {
        guard let comp = g.largestComponent() else { return nil }
        return g.nearestNode(to: c) { g.component[Int($0)] == comp && g.adjStart[Int($0) + 1] > g.adjStart[Int($0)] }
    }

    /// Loops of about `target` meters that start and end near `start`, best first.
    func plan(start: Coord, target: Double) async -> [PlannedRoute] {
        guard let s = startNode(near: start) else { return [] }
        struct Shape: Sendable {
            let bearing: Double
            let waypoints: Int
            let clockwise: Bool
        }
        var shapes: [Shape] = []
        for i in 0..<16 {
            let bearing = Double(i) * 22.5
            shapes.append(Shape(bearing: bearing, waypoints: 2, clockwise: i % 2 == 0))
            shapes.append(Shape(bearing: bearing + 11.25, waypoints: 3, clockwise: i % 2 == 1))
            shapes.append(Shape(bearing: bearing, waypoints: 4, clockwise: i % 2 == 1))
        }

        let candidates: [PlannedRoute] = await withTaskGroup(of: PlannedRoute?.self) { group in
            for (i, shape) in shapes.enumerated() {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    var searcher = Searcher(g, weights)
                    return bestLoop(id: i, start: s, target: target, bearing: shape.bearing,
                                    waypoints: shape.waypoints, clockwise: shape.clockwise, searcher: &searcher)
                }
            }
            var out: [PlannedRoute] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }

        // Prefer loops close to the requested distance, then pick the best ones that differ.
        var pool = candidates.filter { abs($0.length - target) <= 0.15 * target }
        if pool.count < 2 { pool = candidates.filter { abs($0.length - target) <= 0.35 * target } }
        if pool.isEmpty { pool = candidates }
        pool.sort { $0.score > $1.score }
        var picked: [PlannedRoute] = []
        for limit in [0.45, 0.7] {
            for r in pool where picked.count < maxRoutes {
                if picked.contains(where: { $0.id == r.id }) { continue }
                if picked.allSatisfy({ $0.overlap(with: r) < limit }) { picked.append(r) }
            }
            if picked.count >= 3 { break }
        }
        return picked.sorted { $0.score > $1.score }
    }

    /// Tries a few loop sizes for one shape and keeps the one closest to the target length.
    private func bestLoop(id: Int, start: Int32, target: Double, bearing: Double, waypoints: Int,
                          clockwise: Bool, searcher: inout Searcher) -> PlannedRoute? {
        var radius = target / (2 * .pi * 1.5)
        var best: PlannedRoute?
        for _ in 0..<5 {
            guard !Task.isCancelled else { return nil }
            guard let arcs = loop(start: start, bearing: bearing, radius: radius, waypoints: waypoints,
                                  clockwise: clockwise, searcher: &searcher) else {
                radius *= 0.8
                continue
            }
            let route = makeRoute(id: id, arcs: arcs, target: target)
            if best == nil || abs(route.length - target) < abs(best!.length - target) { best = route }
            if abs(route.length - target) < 0.04 * target { break }
            radius *= max(0.6, min(1.6, target / max(1, route.length)))
        }
        return best
    }

    /// One loop: start -> waypoints placed around a circle through the start -> start.
    private func loop(start: Int32, bearing: Double, radius: Double, waypoints: Int, clockwise: Bool,
                      searcher: inout Searcher) -> [Int32]? {
        let origin = g.nodes[Int(start)]
        let center = Geo.destination(from: origin, bearing: bearing, meters: radius)
        let comp = g.component[Int(start)]
        var stops: [Int32] = []
        for i in 1...waypoints {
            let step = 360.0 / Double(waypoints + 1) * Double(i) * (clockwise ? 1 : -1)
            let point = Geo.destination(from: center, bearing: bearing + 180 + step, meters: radius)
            guard let wp = waypoint(near: point, searchRadius: max(250, radius * 0.3), component: comp,
                                    excluding: stops + [start]) else { return nil }
            stops.append(wp)
        }
        stops.append(start)

        searcher.reset()
        var arcs: [Int32] = []
        var at = start
        for stop in stops {
            guard let leg = searcher.path(from: at, to: stop, after: arcs.last ?? -1) else { return nil }
            searcher.mark(leg, 1)
            arcs.append(contentsOf: leg)
            at = stop
        }

        // Waypoints only steer the loop; having to touch one exactly can force a hairpin (out one
        // street, back along the next). Wherever the route returns close to where it was a short
        // while ago, try the direct connection and keep it if it is much shorter.
        let maxSpan = Float(min(1_500, max(600, radius)))
        var i = 0
        var budget = 40
        while i < arcs.count, budget > 0 {
            let from = g.arcTail(arcs[i])
            var along: Float = 0
            var cut: (end: Int, along: Float)?
            var j = i
            while j < arcs.count, along <= maxSpan {
                along += g.edges[Int(arcs[j] >> 1)].length
                j += 1
                let gap = Float(Geo.distance(g.nodes[Int(from)], g.nodes[Int(g.arcHead(arcs[j - 1]))]))
                if along > 200, along <= maxSpan, gap < 0.3 * along, j - i < arcs.count { cut = (j, along) }
            }
            guard let cut else { i += 1; continue }
            budget -= 1
            let old = Array(arcs[i..<cut.end])
            let to = g.arcHead(arcs[cut.end - 1])
            searcher.mark(old, -1)
            if from != to, let direct = searcher.path(from: from, to: to, after: i > 0 ? arcs[i - 1] : -1),
               direct.reduce(Float(0), { $0 + g.edges[Int($1 >> 1)].length }) < 0.45 * cut.along {
                arcs.replaceSubrange(i..<cut.end, with: direct)
                searcher.mark(direct, 1)
            } else if from == to {
                arcs.removeSubrange(i..<cut.end)
            } else {
                searcher.mark(old, 1)
                i += 1
            }
        }

        // Drop out-and-back spurs (riding a segment and immediately coming straight back).
        var trimmed: [Int32] = []
        for a in arcs {
            if let last = trimmed.last, last == a ^ 1 { trimmed.removeLast() } else { trimmed.append(a) }
        }
        return trimmed.count >= 3 ? trimmed : nil
    }

    /// A junction near `point`, biased toward neighborhoods with the most fogged road.
    private func waypoint(near point: Coord, searchRadius: Double, component: Int32, excluding: [Int32]) -> Int32? {
        var best: Int32?
        var bestScore = -Double.infinity
        g.forEachNode(near: point, radius: searchRadius) { n in
            guard g.core[Int(n)], g.component[Int(n)] == component, !excluding.contains(n) else { return }
            let c = g.nodes[Int(n)]
            let d = Geo.distance(point, c)
            guard d <= searchRadius else { return }
            let (x, y) = g.cellXY(c)
            let fog = Double(g.gridFog[y * g.gridW + x])
            let score = fog * (1 - 0.5 * d / searchRadius) - d * 0.001
            if score > bestScore { bestScore = score; best = n }
        }
        if best != nil { return best }
        return g.nearestNode(to: point, maxRadius: searchRadius * 3) {
            g.core[Int($0)] && g.component[Int($0)] == component && !excluding.contains($0)
        }
    }

    private func makeRoute(id: Int, arcs: [Int32], target: Double) -> PlannedRoute {
        var counts: [Int32: Int] = [:]
        var edgeLengths: [Int32: Float] = [:]
        var length = 0.0, new = 0.0, repeated = 0.0, bike = 0.0
        var turns = 0
        var coords: [Coord] = []
        var runs: [PlannedRoute.Run] = []
        var runCoords: [Coord] = []
        var runIsNew = false
        var nameMeters: [Int32: Double] = [:]
        var passed = Set<Int32>()
        var passedFogged = 0
        let total = arcs.reduce(0.0) { $0 + Double(g.edges[Int($1 >> 1)].length) }
        var visitedNodes = Set<Int32>()
        var crossings = 0

        for (i, arc) in arcs.enumerated() {
            let ei = arc >> 1
            let e = g.edges[Int(ei)]
            let len = Double(e.length)
            let seen = counts[ei, default: 0]
            counts[ei] = seen + 1
            edgeLengths[ei] = e.length
            length += len
            // Cells this segment adds to the loop, and how many of those are still fogged.
            var added = 0, addedFogged = 0
            for c in Int(e.cellStart)..<Int(e.cellStart + e.cellCount) where passed.insert(g.edgeCells[c]).inserted {
                added += 1
                if g.cellFogged[Int(g.edgeCells[c])] { addedFogged += 1 }
            }
            passedFogged += addedFogged
            if seen > 0 { repeated += len }
            if e.bike >= 0.8 { bike += len }
            if e.name != 0 { nameMeters[e.name, default: 0] += len }
            if i > 0, g.turnAngle(from: arcs[i - 1], to: arc) != nil { turns += 1 }
            // The route crossing itself (a figure-eight) away from the shared start/finish stretch.
            if !visitedNodes.insert(g.arcHead(arc)).inserted, length > 300, length < total - 300 { crossings += 1 }

            let pts = g.coords(ofArc: arc)
            coords.append(contentsOf: coords.isEmpty ? pts : Array(pts.dropFirst()))
            let isNew = added > 0 && addedFogged * 2 > added
            if runCoords.isEmpty {
                runIsNew = isNew
                runCoords = pts
            } else if isNew == runIsNew {
                runCoords.append(contentsOf: pts.dropFirst())
            } else {
                runs.append(.init(id: runs.count, isNew: runIsNew, coords: runCoords))
                runIsNew = isNew
                runCoords = pts
            }
        }
        if !runCoords.isEmpty { runs.append(.init(id: runs.count, isNew: runIsNew, coords: runCoords)) }

        // Share of the distinct ground covered that is still fogged, applied to the non-repeated distance.
        new = (length - repeated) * Double(passedFogged) / Double(max(1, passed.count))
        let old = max(0, length - new - repeated)
        let score = new - repeated - 0.25 * old - 40 * Double(turns) - 300 * Double(crossings) + 0.3 * bike
            - 3 * max(0, abs(length - target) - 0.05 * target)

        // Name the loop after where it heads and the street it spends the most time on.
        var name = "Loop"
        if let origin = coords.first, !coords.isEmpty {
            let lat = coords.reduce(0) { $0 + $1.lat } / Double(coords.count)
            let lon = coords.reduce(0) { $0 + $1.lon } / Double(coords.count)
            name = Geo.compassName(Geo.bearing(origin, Coord(lat: lat, lon: lon)))
            if let top = nameMeters.max(by: { $0.value < $1.value }) {
                name += " via " + g.names[Int(top.key)]
            }
        }
        return PlannedRoute(id: id, name: name, coords: coords, runs: runs, length: length, newMeters: new,
                            repeatMeters: repeated, bikeMeters: bike, turns: turns, score: score,
                            edgeLengths: edgeLengths)
    }
}
