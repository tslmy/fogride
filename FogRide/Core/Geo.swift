import Foundation

struct Coord: Hashable, Codable, Sendable {
    var lat: Double
    var lon: Double
}

enum Geo {
    static let earthRadius = 6_371_000.0

    /// Great-circle distance in meters.
    static func distance(_ a: Coord, _ b: Coord) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = p2 - p1
        let dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north in [0, 360).
    static func bearing(_ a: Coord, _ b: Coord) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dl = (b.lon - a.lon) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    static func destination(from a: Coord, bearing: Double, meters: Double) -> Coord {
        let d = meters / earthRadius
        let t = bearing * .pi / 180
        let p1 = a.lat * .pi / 180, l1 = a.lon * .pi / 180
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(t))
        let l2 = l1 + atan2(sin(t) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        return Coord(lat: p2 * 180 / .pi, lon: l2 * 180 / .pi)
    }

    /// Smallest absolute difference between two bearings, in [0, 180].
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    static func lerp(_ a: Coord, _ b: Coord, _ t: Double) -> Coord {
        Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
    }

    static func compassName(_ bearing: Double) -> String {
        let names = ["North", "North-east", "East", "South-east", "South", "South-west", "West", "North-west"]
        return names[Int((bearing + 22.5) / 45) % 8]
    }
}
