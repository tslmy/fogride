import MapKit
import UIKit

extension FogMap {
    /// Calls `body` with the global cell coordinates of every uncovered cell inside the square
    /// of `size` cells whose top-left cell is (`x0`, `y0`). The world is 2^22 cells per axis.
    func forEachVisitedCell(x0: Int, y0: Int, size: Int, _ body: (Int, Int) -> Void) {
        let x1 = x0 + size - 1, y1 = y0 + size - 1
        for tileY in (y0 >> 13)...(y1 >> 13) {
            for tileX in (x0 >> 13)...(x1 >> 13) {
                guard tileX >= 0, tileY >= 0, tileX < Self.mapWidth, tileY < Self.mapWidth,
                      let data = tileData(tileY * Self.mapWidth + tileX) else { continue }
                let originX = tileX << 13, originY = tileY << 13
                let bx0 = max(0, (x0 - originX) >> 6), bx1 = min(127, (x1 - originX) >> 6)
                let by0 = max(0, (y0 - originY) >> 6), by1 = min(127, (y1 - originY) >> 6)
                guard bx0 <= bx1, by0 <= by1 else { continue }
                data.withUnsafeBufferPointer { bytes in
                    for by in by0...by1 {
                        for bx in bx0...bx1 {
                            let h = (by * Self.tileWidth + bx) * 2
                            let index = Int(bytes[h]) | (Int(bytes[h + 1]) << 8)
                            guard index > 0 else { continue }
                            let offset = Self.headerSize + (index - 1) * Self.blockSize
                            guard offset + 512 <= bytes.count else { continue }
                            let gx0 = originX + (bx << 6), gy0 = originY + (by << 6)
                            for i in 0..<512 {
                                let byte = bytes[offset + i]
                                guard byte != 0 else { continue }
                                let gy = gy0 + (i >> 3)
                                guard gy >= y0, gy <= y1 else { continue }
                                let gx = gx0 + ((i & 7) << 3)
                                for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                                    let x = gx + bit
                                    if x >= x0, x <= x1 { body(x, gy) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Draws the Fog of World fog over the map: a dark veil with holes where you have been.
final class FogTileOverlay: MKTileOverlay {
    private let fog: FogMap
    private let queue = DispatchQueue(label: "fog-tiles", qos: .userInitiated, attributes: .concurrent)
    private let cache = NSCache<NSString, NSData>()
    /// Premultiplied RGBA of the veil.
    private static let veil: (UInt8, UInt8, UInt8, UInt8) = (10, 13, 22, 125)

    init(fog: FogMap) {
        self.fog = fog
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        // Below zoom 8 one map tile spans many Fog of World files; skip the fog there.
        minimumZ = 8
        maximumZ = 21
        cache.countLimit = 300
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = "\(path.z)/\(path.x)/\(path.y)@\(path.contentScaleFactor)" as NSString
        if let hit = cache.object(forKey: key) { return result(hit as Data, nil) }
        queue.async { [self] in
            let data = render(path)
            if let data { cache.setObject(data as NSData, forKey: key) }
            result(data, nil)
        }
    }

    private func render(_ path: MKTileOverlayPath) -> Data? {
        let side = path.contentScaleFactor > 1 ? 512 : 256
        let shift = 22 - path.z
        guard shift >= 0 else { return nil }
        let cells = 1 << shift
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let v = Self.veil
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = v.0; pixels[i + 1] = v.1; pixels[i + 2] = v.2; pixels[i + 3] = v.3
        }
        let x0 = path.x << shift, y0 = path.y << shift
        pixels.withUnsafeMutableBufferPointer { buf in
            if cells >= side {
                // Zoomed out: several cells per pixel; a pixel is clear if any of its cells is.
                let down = (cells / side).trailingZeroBitCount
                fog.forEachVisitedCell(x0: x0, y0: y0, size: cells) { gx, gy in
                    // Widen tracks by a pixel each way so they stay visible from afar.
                    let px = (gx - x0) >> down, py = (gy - y0) >> down
                    for row in max(0, py - 1)...min(side - 1, py + 1) {
                        for col in max(0, px - 1)...min(side - 1, px + 1) {
                            let p = (row * side + col) * 4
                            buf[p] = 0; buf[p + 1] = 0; buf[p + 2] = 0; buf[p + 3] = 0
                        }
                    }
                }
            } else {
                // Zoomed in: each cell is a square of pixels.
                let k = side / cells
                fog.forEachVisitedCell(x0: x0, y0: y0, size: cells) { gx, gy in
                    let px = (gx - x0) * k, py = (gy - y0) * k
                    for row in py..<(py + k) {
                        let start = (row * side + px) * 4
                        for p in start..<(start + k * 4) { buf[p] = 0 }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}
