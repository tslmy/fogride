import MapKit
import SwiftUI
import UniformTypeIdentifiers

extension Coord {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

final class MapCenter {
    var value: CLLocationCoordinate2D?
}

enum Palette {
    /// Stretches that are still under fog.
    static let fresh = Color(red: 0.36, green: 0.25, blue: 0.95)
    /// Stretches already uncovered, or ridden twice within the loop.
    static let seen = Color(red: 0.45, green: 0.47, blue: 0.52)
    static let alternative = Color(red: 0.0, green: 0.55, blue: 0.6)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// Held in a reference box so that panning the map doesn't re-render the screen.
    @State private var mapCenter = MapCenter()
    @State private var panelHeight: CGFloat = 0
    @AppStorage("showFog") private var showFog = true
    @State private var pickingFolder = false
    @State private var showingSettings = false
    /// Which leg of the selected loop the Apple Maps button opens next.
    @State private var appleLeg = 0

    var body: some View {
        Group {
            if model.phase == .needsFog {
                WelcomeView(pickFolder: { pickingFolder = true })
            } else {
                mapScreen
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.useFogFolder(url) }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(pickFolder: {
                showingSettings = false
                pickingFolder = true
            })
            .presentationDetents([.medium])
        }
        .onAppear { model.startLocation() }
    }

    private var mapScreen: some View {
        ZStack(alignment: .bottom) {
            RouteMapView(routes: model.routes, selectedID: model.selectedID, start: model.plannedStart,
                         fog: model.fog, showFog: showFog, bottomInset: panelHeight,
                         onCenterChange: { [mapCenter] in mapCenter.value = $0 })
                .ignoresSafeArea()
            panel
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        }
        .overlay(alignment: .topTrailing) { mapButtons }
        .onChange(of: model.selectedID) { appleLeg = 0 }
        .onChange(of: model.routes.first?.length) { appleLeg = 0 }
    }

    private var mapButtons: some View {
        VStack(spacing: 10) {
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
            Button { showFog.toggle() } label: {
                Image(systemName: showFog ? "cloud.fog.fill" : "cloud.fog").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Show fog")
            .accessibilityAddTraits(showFog ? .isSelected : [])
            Menu {
                Button("Start from my location", systemImage: "location.fill") { model.startFromMyLocation() }
                    .disabled(model.userLocation == nil)
                Button("Start from map center", systemImage: "scope") {
                    if let c = mapCenter.value { model.startFrom(Coord(lat: c.latitude, lon: c.longitude)) }
                }
            } label: {
                Image(systemName: model.customStart == nil ? "location.fill" : "scope").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Start point")
        }
        .font(.system(size: 17, weight: .semibold))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.trailing, 12)
        .padding(.top, 60)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow
            if !model.routes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.routes) { route in
                            RouteCard(route: route, selected: route.id == model.selectedID, speedKmh: model.speedKmh)
                                .onTapGesture { model.selectedID = route.id }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            DistanceSlider()
            if let route = model.selected {
                HStack(spacing: 10) {
                    Button {
                        if let url = RouteExport.googleMapsURL(route) { openURL(url) }
                    } label: {
                        Text("Google Maps").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        RouteExport.openInAppleMaps(route, leg: appleLeg)
                        appleLeg = (appleLeg + 1) % RouteExport.appleLegCount
                    } label: {
                        VStack(spacing: 0) {
                            Text("Apple Maps")
                            Text("leg \(appleLeg + 1) of \(RouteExport.appleLegCount)").font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Apple Maps, leg \(appleLeg + 1) of \(RouteExport.appleLegCount)")
                    if let gpx = RouteExport.gpxFile(route) {
                        ShareLink(item: gpx) {
                            Image(systemName: "square.and.arrow.up").frame(height: 20)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Share GPX track")
                    }
                }
                .controlSize(.large)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var statusRow: some View {
        switch model.phase {
        case .working(let message):
            if let started = model.downloadStarted {
                // The road servers don't report progress while a request is queued, so the bar
                // is paced by how long the last download took and creeps once past that.
                TimelineView(.periodic(from: started, by: 0.25)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(started))
                    let typical = max(10, model.typicalDownloadSeconds)
                    let fraction = elapsed < typical
                        ? 0.9 * elapsed / typical
                        : 0.9 + 0.09 * (1 - exp(-(elapsed - typical) / typical))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Downloading roads").font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int(elapsed)) s of about \(Int(typical.rounded()))")
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ProgressView(value: fraction)
                        Text("Only needed the first time in an area.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Downloading roads, \(Int(fraction * 100)) percent")
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        case .locating:
            HStack(spacing: 8) {
                if !model.locationDenied { ProgressView() }
                Text(model.locationDenied
                     ? "Location is off. Move the map to where you'll start, then choose “Start from map center”."
                     : "Finding where you are…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.subheadline)
                Spacer()
                Button("Retry") { model.plan() }.font(.subheadline.weight(.semibold))
            }
        case .ready, .needsFog:
            EmptyView()
        }
    }
}

private struct DistanceSlider: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 2) {
            HStack {
                Text("Distance").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.targetKm)) km").font(.headline).monospacedDigit()
            }
            Slider(value: $model.targetKm, in: AppModel.distanceRange, step: 1) { editing in
                if !editing { model.plan() }
            }
            .onChange(of: model.targetKm) { model.planIfRoadsLoaded() }
            .accessibilityLabel("Ride distance")
            .accessibilityValue("\(Int(model.targetKm)) kilometers")
        }
    }
}

private struct RouteCard: View {
    let route: PlannedRoute
    let selected: Bool
    let speedKmh: Double

    private var time: String {
        let minutes = Int((route.duration(speedKmh: speedKmh) / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f km", route.length / 1000)).font(.title3.weight(.semibold))
                Text(time).font(.subheadline).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            Text(route.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 10) {
                stat("sparkles", "\(Int((route.newFraction * 100).rounded()))% new", Palette.fresh)
                stat("bicycle", "\(Int((route.bikeFraction * 100).rounded()))%", .secondary)
                stat("arrow.triangle.turn.up.right.diamond", "\(route.turns)", .secondary)
            }
            .font(.caption.weight(.medium))
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Palette.fresh : .clear, lineWidth: 2.5))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "%.1f kilometers, %@, %d percent new, %d percent on bike lanes, %d turns, %@",
                                   route.length / 1000, time, Int(route.newFraction * 100),
                                   Int(route.bikeFraction * 100), route.turns, route.name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func stat(_ symbol: String, _ text: String, _ color: some ShapeStyle) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(color)
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let pickFolder: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "cloud.fog.fill").font(.system(size: 64)).foregroundStyle(Palette.fresh)
            Text("Connect Fog of World").font(.title2.weight(.bold))
            Text("FogRide plans loops through places you haven't uncovered yet. Choose the “Sync” folder that Fog of World keeps in iCloud Drive or Dropbox. It's only read, never changed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let error = model.pickerError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button(action: pickFolder) {
                Text("Choose Sync Folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .padding(28)
    }
}

private struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pickFolder: () -> Void

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $model.speedKmh, in: 8...40, step: 1) {
                        LabeledContent("Cruising speed", value: "\(Int(model.speedKmh)) km/h")
                    }
                } footer: {
                    Text("Used for the time estimate, plus a few seconds for every turn.")
                }
                Section {
                    LabeledContent("Folder", value: model.fogFolderName ?? "None")
                    LabeledContent("Map tiles", value: "\(model.fogTileCount)")
                    Button("Choose a Different Folder…", action: pickFolder)
                } header: {
                    Text("Fog of World data")
                } footer: {
                    Text("Road data © OpenStreetMap contributors.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
