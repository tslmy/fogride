import MapKit
import SwiftUI

/// The map: fog veil, candidate loops, direction arrows, start flag and the user's location.
/// MKMapView is used directly because SwiftUI's `Map` cannot show custom tile overlays.
struct RouteMapView: UIViewRepresentable {
    var routes: [PlannedRoute]
    var selectedID: Int?
    var start: Coord?
    var fog: FogMap?
    var showFog: Bool
    /// Height of the panel covering the bottom of the map.
    var bottomInset: CGFloat
    var onCenterChange: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.setUserTrackingMode(.follow, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.onCenterChange = onCenterChange
        map.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)

        // Fog veil.
        let wantFog = showFog ? fog : nil
        if c.fogSource !== wantFog {
            if let old = c.fogOverlay { map.removeOverlay(old) }
            c.fogOverlay = nil
            if let wantFog {
                let overlay = FogTileOverlay(fog: wantFog)
                map.addOverlay(overlay, level: .aboveRoads)
                c.fogOverlay = overlay
            }
            c.fogSource = wantFog
        }

        // Routes.
        let signature = routes.map { "\($0.id):\(Int($0.length))" }.joined(separator: ",") + "|\(selectedID ?? -1)"
        if signature != c.signature {
            c.signature = signature
            map.removeOverlays(c.lines)
            map.removeAnnotations(c.marks)
            c.lines = []
            c.marks = []
            for route in routes where route.id != selectedID {
                c.lines.append(StyledLine(route.coords, .alternative))
            }
            if let route = routes.first(where: { $0.id == selectedID }) {
                let outline = StyledLine(route.coords, .casing)
                c.lines.append(outline)
                for run in route.runs { c.lines.append(StyledLine(run.coords, run.isNew ? .fresh : .seen)) }
                c.marks = Self.directionMarks(route).map { ArrowMark(coordinate: $0.0.cl, bearing: $0.1) }
                map.setVisibleMapRect(outline.boundingMapRect,
                                      edgePadding: UIEdgeInsets(top: 90, left: 40, bottom: 40, right: 70),
                                      animated: true)
            }
            map.addOverlays(c.lines, level: .aboveLabels)
            map.addAnnotations(c.marks)
        }

        // Start flag.
        if c.startMark?.coordinate.latitude != start?.lat || c.startMark?.coordinate.longitude != start?.lon {
            if let old = c.startMark { map.removeAnnotation(old) }
            c.startMark = nil
            if let start {
                let mark = StartMark(coordinate: start.cl)
                map.addAnnotation(mark)
                c.startMark = mark
            }
        }
    }

    /// A handful of arrows along the route showing which way round to ride it.
    static func directionMarks(_ route: PlannedRoute) -> [(Coord, Double)] {
        let pts = route.coords
        guard pts.count > 2 else { return [] }
        let spacing = route.length / 8
        var marks: [(Coord, Double)] = []
        var travelled = 0.0
        var next = spacing / 2
        for i in 1..<pts.count {
            let d = Geo.distance(pts[i - 1], pts[i])
            if d > 0, travelled + d >= next {
                marks.append((Geo.lerp(pts[i - 1], pts[i], (next - travelled) / d), Geo.bearing(pts[i - 1], pts[i])))
                next += spacing
            }
            travelled += d
        }
        return marks
    }

    final class StyledLine: MKPolyline {
        enum Style { case fresh, seen, alternative, casing }
        var style = Style.fresh
        convenience init(_ coords: [Coord], _ style: Style) {
            let cl = coords.map(\.cl)
            self.init(coordinates: cl, count: cl.count)
            self.style = style
        }
    }

    final class ArrowMark: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let bearing: Double
        init(coordinate: CLLocationCoordinate2D, bearing: Double) {
            self.coordinate = coordinate
            self.bearing = bearing
        }
    }

    final class StartMark: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let title: String? = "Start"
        init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onCenterChange: (CLLocationCoordinate2D) -> Void = { _ in }
        var fogOverlay: FogTileOverlay?
        var fogSource: FogMap?
        var signature = ""
        var lines: [StyledLine] = []
        var marks: [ArrowMark] = []
        var startMark: StartMark?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            guard let line = overlay as? StyledLine else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.lineCap = .round
            r.lineJoin = .round
            switch line.style {
            case .fresh: r.strokeColor = UIColor(Palette.fresh); r.lineWidth = 6
            case .seen: r.strokeColor = UIColor(Palette.seen); r.lineWidth = 6
            case .casing: r.strokeColor = .white; r.lineWidth = 9
            case .alternative: r.strokeColor = UIColor(Palette.alternative).withAlphaComponent(0.6); r.lineWidth = 3
            }
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let arrow = annotation as? ArrowMark {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "arrow")
                    ?? MKAnnotationView(annotation: arrow, reuseIdentifier: "arrow")
                view.annotation = arrow
                let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
                    .applying(UIImage.SymbolConfiguration(paletteColors: [.white, UIColor(Palette.fresh)]))
                view.image = UIImage(systemName: "arrow.up.circle.fill", withConfiguration: config)
                view.isAccessibilityElement = false
                view.transform = CGAffineTransform(rotationAngle: (arrow.bearing - mapView.camera.heading) * .pi / 180)
                return view
            }
            if annotation is StartMark {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "start") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "start")
                view.annotation = annotation
                view.glyphImage = UIImage(systemName: "flag.checkered")
                view.markerTintColor = .black
                view.displayPriority = .required
                return view
            }
            return nil
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            onCenterChange(mapView.centerCoordinate)
            let heading = mapView.camera.heading
            for mark in marks {
                mapView.view(for: mark)?.transform = CGAffineTransform(rotationAngle: (mark.bearing - heading) * .pi / 180)
            }
        }
    }
}
