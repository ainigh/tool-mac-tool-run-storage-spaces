import Foundation

/// Where each node goes in a picture of the mind: a force layout (linked nodes pull together,
/// every pair pushes apart), started from places taken from the names, so the same mind is
/// drawn the same way every time. Positions are in 0…1 both ways.
public enum MindLayout {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The nodes' places. `fixed` are where they stay (a node the person dragged); `iterations`
    /// defaults to fewer for big minds.
    public static func positions(_ g: MindGraph, fixed: [MindNodeID: Point] = [:], iterations: Int? = nil) -> [MindNodeID: Point] {
        let ids = g.nodeList.map(\.id)
        let n = ids.count
        guard n > 0 else { return [:] }
        if n == 1 { return [ids[0]: fixed[ids[0]] ?? Point(x: 0.5, y: 0.5)] }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var x = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        for (k, id) in ids.enumerated() {
            if let f = fixed[id] {
                x[k] = f.x
                y[k] = f.y
            } else {
                let h = hash(id.description)
                x[k] = Double(h & 0xFFFF) / 65535.0
                y[k] = Double((h >> 16) & 0xFFFF) / 65535.0
            }
        }
        let pairs = g.edgeList.compactMap { e -> (Int, Int)? in
            guard let a = index[e.a], let b = index[e.b], a != b else { return nil }
            return (a, b)
        }
        let isFixed = ids.map { fixed[$0] != nil }
        let k = sqrt(1.0 / Double(n)) * 0.9
        let rounds = iterations ?? (n > 400 ? 60 : n > 150 ? 150 : 300)
        var t = 0.1
        for _ in 0..<rounds {
            var dx = [Double](repeating: 0, count: n)
            var dy = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ddx = x[i] - x[j], ddy = y[i] - y[j]
                    var d2 = ddx * ddx + ddy * ddy
                    if d2 < 1e-9 {
                        ddx = 0.001 * Double((i * 7 + j * 13) % 11 - 5)
                        ddy = 0.001 * Double((i * 11 + j * 3) % 7 - 3)
                        d2 = ddx * ddx + ddy * ddy + 1e-9
                    }
                    let f = k * k / d2
                    dx[i] += ddx * f; dy[i] += ddy * f
                    dx[j] -= ddx * f; dy[j] -= ddy * f
                }
            }
            for (a, b) in pairs {
                let ddx = x[a] - x[b], ddy = y[a] - y[b]
                let d = max(1e-6, sqrt(ddx * ddx + ddy * ddy))
                let f = d / k
                dx[a] -= ddx * f; dy[a] -= ddy * f
                dx[b] += ddx * f; dy[b] += ddy * f
            }
            // A pull to the middle, so pieces that aren't linked stay in sight.
            for i in 0..<n {
                dx[i] += (0.5 - x[i]) * 0.05
                dy[i] += (0.5 - y[i]) * 0.05
            }
            for i in 0..<n where !isFixed[i] {
                let d = max(1e-9, sqrt(dx[i] * dx[i] + dy[i] * dy[i]))
                x[i] += dx[i] / d * min(d, t)
                y[i] += dy[i] / d * min(d, t)
            }
            t = max(0.002, t * 0.97)
        }
        // Into 0…1, keeping the shape (the fixed ones are where they were put).
        let free = (0..<n).filter { !isFixed[$0] }
        var out: [MindNodeID: Point] = [:]
        if let minX = free.map({ x[$0] }).min(), let maxX = free.map({ x[$0] }).max(),
           let minY = free.map({ y[$0] }).min(), let maxY = free.map({ y[$0] }).max() {
            let span = max(maxX - minX, maxY - minY, 1e-6)
            let ox = (1 - (maxX - minX) / span) / 2, oy = (1 - (maxY - minY) / span) / 2
            for i in free {
                out[ids[i]] = Point(x: 0.05 + 0.9 * ((x[i] - minX) / span + ox), y: 0.05 + 0.9 * ((y[i] - minY) / span + oy))
            }
        }
        for (k, id) in ids.enumerated() where isFixed[k] { out[id] = fixed[id] }
        return out
    }

    /// FNV-1a: the same number for the same text, on every run (Swift's own hash changes).
    public static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}
