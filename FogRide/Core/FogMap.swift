import Foundation
import zlib

/// Read-only access to a Fog of World `Sync` folder.
///
/// The world is 512 x 512 tiles (Web Mercator). Each tile file is a zlib stream holding a
/// 128 x 128 table of UInt16 block indices followed by 515-byte blocks; each block is a
/// 64 x 64 bitmap of visited cells (about 7.6 m per cell at 37 degrees latitude).
final class FogMap: @unchecked Sendable {
    static let mapWidth = 512
    static let tileWidth = 128
    static let bitmapWidth = 64
    static let headerSize = tileWidth * tileWidth * 2
    static let blockSize = 515
    static let cellsPerAxis = Double(mapWidth * tileWidth * bitmapWidth)

    private static let mask1 = Array("olhwjsktri")

    let folder: URL
    /// Tile id (y * 512 + x) -> file.
    private let index: [Int: URL]
    private var tiles: [Int: [UInt8]?] = [:]
    private let lock = NSLock()

    var tileCount: Int { index.count }

    enum FogError: LocalizedError {
        case notASyncFolder
        var errorDescription: String? {
            "That folder doesn't look like Fog of World data. Pick the folder named “Sync” (or the folder that contains it)."
        }
    }

    /// `folder` may be the `Sync` folder itself or its parent.
    init(folder: URL) throws {
        let fm = FileManager.default
        var best: (URL, [Int: URL]) = (folder, [:])
        for candidate in [folder, folder.appendingPathComponent("Sync")] {
            guard let names = try? fm.contentsOfDirectory(atPath: candidate.path) else { continue }
            var idx: [Int: URL] = [:]
            for raw in names {
                // Not-yet-downloaded iCloud items can show up as ".name.icloud".
                var name = raw
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(7))
                }
                if let id = Self.tileID(fromFilename: name) {
                    idx[id] = candidate.appendingPathComponent(name)
                }
            }
            if idx.count > best.1.count { best = (candidate, idx) }
        }
        guard !best.1.isEmpty else { throw FogError.notASyncFolder }
        self.folder = best.0
        self.index = best.1
    }

    /// Filenames look like `<4 hex of md5><masked decimal id><2 check chars>`.
    static func tileID(fromFilename name: String) -> Int? {
        let chars = Array(name)
        guard chars.count >= 7, chars.count <= 14 else { return nil }
        var id = 0
        for c in chars[4..<(chars.count - 2)] {
            guard let d = mask1.firstIndex(of: c) else { return nil }
            id = id * 10 + d
        }
        guard id < mapWidth * mapWidth else { return nil }
        return id
    }

    /// Decompressed contents of one tile file, loaded on first use; nil if you've never been there.
    func tileData(_ id: Int) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = tiles[id] { return cached }
        var loaded: [UInt8]? = nil
        if let url = index[id] {
            var raw: Data?
            // Coordinated read so iCloud/Dropbox providers download the file on demand.
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
                raw = try? Data(contentsOf: u)
            }
            if let raw, let data = Self.inflate(raw), data.count >= Self.headerSize {
                loaded = data
            }
        }
        tiles[id] = .some(loaded)
        return loaded
    }

    /// Global cell coordinates (0 ..< 2^22 on each axis) of the fog cell containing `c`.
    static func cell(of c: Coord) -> (x: Int, y: Int)? {
        let lat = max(-85.05112878, min(85.05112878, c.lat))
        let n = cellsPerAxis
        let fx = (c.lon + 180) / 360 * n
        let rad = lat * .pi / 180
        let fy = (1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n
        guard fx >= 0, fy >= 0, fx < n, fy < n else { return nil }
        return (Int(fx), Int(fy))
    }

    func isVisited(cellX gx: Int, cellY gy: Int) -> Bool {
        guard gx >= 0, gy >= 0, gx < 1 << 22, gy < 1 << 22,
              let data = tileData((gy >> 13) * Self.mapWidth + (gx >> 13)) else { return false }
        let bx = (gx >> 6) & 127, by = (gy >> 6) & 127
        let h = (by * Self.tileWidth + bx) * 2
        let blockIndex = Int(data[h]) | (Int(data[h + 1]) << 8)
        guard blockIndex > 0 else { return false }
        let cx = gx & 63, cy = gy & 63
        let offset = Self.headerSize + (blockIndex - 1) * Self.blockSize + cy * 8 + (cx >> 3)
        guard offset < data.count else { return false }
        return data[offset] & (1 << UInt8(7 - (cx & 7))) != 0
    }

    /// Whether the cell containing this coordinate has been uncovered.
    func isVisited(_ c: Coord) -> Bool {
        guard let cell = Self.cell(of: c) else { return false }
        return isVisited(cellX: cell.x, cellY: cell.y)
    }

    private static func inflate(_ data: Data) -> [UInt8]? {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out: [UInt8] = []
        let chunk = 1 << 17
        var buffer = [UInt8](repeating: 0, count: chunk)
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> [UInt8]? in
            guard let base = src.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(src.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = uInt(chunk)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                out.append(contentsOf: buffer[0..<produced])
                if status == Z_STREAM_END { return out }
                if status != Z_OK || (produced == 0 && stream.avail_in == 0) { return nil }
            }
        }
    }
}
