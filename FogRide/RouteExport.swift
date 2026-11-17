import Foundation
import MapKit

/// Hands a planned loop to navigation apps.
///
/// Neither Apple Maps nor Google Maps accepts an exact track, only stops, and each routes
/// between them its own way. Google Maps takes the whole loop as via-points in one link; Apple
/// Maps takes one leg at a time. GPX carries the exact track for apps that can follow one.
enum RouteExport {
    /// `count` points spread evenly along the route, excluding its start and end.
    static func viaPoints(_ route: PlannedRoute, count: Int) -> [Coord] {
        let pts = route.coords
        guard pts.count > 2, count > 0 else { return [] }
        var out: [Coord] = []
        let spacing = route.length / Double(count + 1)
        var travelled = 0.0
        var next = spacing
        for i in 1..<pts.count {
            let d = Geo.distance(pts[i - 1], pts[i])
            while d > 0, travelled + d >= next, out.count < count {
                out.append(Geo.lerp(pts[i - 1], pts[i], (next - travelled) / d))
                next += spacing
            }
            travelled += d
        }
        return out
    }

    /// Apple Maps only does multi-stop routes for driving, so a cycling loop is handed over one
    /// leg at a time: each leg is directions from where you are to the next point on the loop.
    static let appleLegCount = 6

    static func openInAppleMaps(_ route: PlannedRoute, leg: Int) {
        guard let start = route.coords.first else { return }
        let stops = viaPoints(route, count: appleLegCount - 1) + [start]
        let index = min(max(0, leg), stops.count - 1)
        let c = stops[index]
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)))
        item.name = index == stops.count - 1 ? "Finish" : "Leg \(index + 1) of \(stops.count)"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeCycling])
    }

    static func googleMapsURL(_ route: PlannedRoute) -> URL? {
        guard let start = route.coords.first else { return nil }
        func text(_ c: Coord) -> String { String(format: "%.6f,%.6f", c.lat, c.lon) }
        var comps = URLComponents(string: "https://www.google.com/maps/dir/")!
        comps.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: text(start)),
            URLQueryItem(name: "destination", value: text(start)),
            URLQueryItem(name: "waypoints", value: viaPoints(route, count: 9).map(text).joined(separator: "|")),
            URLQueryItem(name: "travelmode", value: "bicycling"),
        ]
        return comps.url
    }

    /// Writes the exact track to a temporary GPX file for sharing.
    static func gpxFile(_ route: PlannedRoute) -> URL? {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="FogRide" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(xmlEscape(route.name))</name><trkseg>

        """
        for c in route.coords {
            xml += String(format: "<trkpt lat=\"%.6f\" lon=\"%.6f\"/>\n", c.lat, c.lon)
        }
        xml += "</trkseg></trk>\n</gpx>\n"
        let km = String(format: "%.0f", route.length / 1000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FogRide \(km) km loop.gpx")
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
