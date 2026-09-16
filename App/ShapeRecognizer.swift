import PencilKit
import UIKit

/// Turns a roughly drawn line, arrow, triangle, rectangle or ellipse into a clean stroke with the same ink.
/// Anything it does not recognise is left as drawn.
enum ShapeRecognizer {
    static func perfected(_ stroke: PKStroke) -> PKStroke? {
        let samples = Array(stroke.path.interpolatedPoints(by: .distance(3)))
        guard samples.count >= 6 else { return nil }
        let points = samples.map { $0.location.applying(stroke.transform) }
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 30 else { return nil }
        let width = max(1, samples.map { $0.size.width }.reduce(0, +) / CGFloat(samples.count))
        let length = pathLength(points)
        let closed = distance(points[0], points[points.count - 1]) < diagonal * 0.2 && length > diagonal * 1.8
        let outline = closed ? closedShape(points, box: box, diagonal: diagonal) : openShape(points, diagonal: diagonal, length: length)
        guard let outline, outline.count >= 2 else { return nil }
        return makeStroke(outline, ink: stroke.ink, width: width)
    }

    private static func openShape(_ points: [CGPoint], diagonal: CGFloat, length: CGFloat) -> [CGPoint]? {
        let simplified = simplify(points, epsilon: diagonal * 0.06)
        if simplified.count == 2 { return densify([points[0], points[points.count - 1]]) }
        // An arrow: a dominant shaft, then a short head drawn around its end.
        guard simplified.count >= 3 else { return nil }
        let start = simplified[0], tip = simplified[1]
        let shaft = distance(start, tip)
        guard shaft > length * 0.55, simplified.dropFirst(2).allSatisfy({ distance($0, tip) < shaft * 0.4 }) else { return nil }
        let angle = atan2(tip.y - start.y, tip.x - start.x)
        let barb = shaft * 0.18
        let left = CGPoint(x: tip.x - barb * cos(angle - .pi / 7), y: tip.y - barb * sin(angle - .pi / 7))
        let right = CGPoint(x: tip.x - barb * cos(angle + .pi / 7), y: tip.y - barb * sin(angle + .pi / 7))
        return densify([start, tip, left, tip, right])
    }

    private static func closedShape(_ points: [CGPoint], box: CGRect, diagonal: CGFloat) -> [CGPoint]? {
        var corners = simplify(points, epsilon: diagonal * 0.07)
        if corners.count > 1 { corners.removeLast() }
        corners = removeStraightCorners(corners, maxTurn: .pi / 7)
        if corners.count == 3 { return densify(corners + [corners[0]]) }
        if corners.count == 4, rightAngled(corners) {
            let axisAligned = corners.indices.allSatisfy { i in
                let a = corners[i], b = corners[(i + 1) % 4]
                let angle = abs(atan2(b.y - a.y, b.x - a.x)).truncatingRemainder(dividingBy: .pi / 2)
                return angle < 0.2 || angle > .pi / 2 - 0.2
            }
            if axisAligned {
                let r = boundingBox(corners)
                return densify([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)])
            }
            return densify(corners + [corners[0]])
        }
        return isEllipse(points, box: box) ? ellipse(in: box) : nil
    }

    private static func isEllipse(_ points: [CGPoint], box: CGRect) -> Bool {
        let rx = box.width / 2, ry = box.height / 2
        guard rx > 8, ry > 8 else { return false }
        let total = points.reduce(CGFloat(0)) { sum, p in
            let dx = (p.x - box.midX) / rx, dy = (p.y - box.midY) / ry
            return sum + abs(sqrt(dx * dx + dy * dy) - 1)
        }
        return total / CGFloat(points.count) < 0.11
    }

    private static func ellipse(in box: CGRect) -> [CGPoint] {
        var rx = box.width / 2, ry = box.height / 2
        if abs(rx - ry) < max(rx, ry) * 0.12 {
            let r = (rx + ry) / 2
            rx = r
            ry = r
        }
        return (0...96).map { i in
            let t = CGFloat(i) / 96 * 2 * .pi
            return CGPoint(x: box.midX + rx * cos(t), y: box.midY + ry * sin(t))
        }
    }

    private static func rightAngled(_ c: [CGPoint]) -> Bool {
        c.indices.allSatisfy { i in
            let a = c[(i + 3) % 4], b = c[i], d = c[(i + 1) % 4]
            let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: d.x - b.x, y: d.y - b.y)
            let cosine = (v1.x * v2.x + v1.y * v2.y) / max(0.001, hypot(v1.x, v1.y) * hypot(v2.x, v2.y))
            return abs(cosine) < 0.5
        }
    }

    private static func removeStraightCorners(_ corners: [CGPoint], maxTurn: CGFloat) -> [CGPoint] {
        var result = corners
        var changed = true
        while changed && result.count > 3 {
            changed = false
            for i in result.indices {
                let a = result[(i + result.count - 1) % result.count], b = result[i], c = result[(i + 1) % result.count]
                let u = CGPoint(x: b.x - a.x, y: b.y - a.y), v = CGPoint(x: c.x - b.x, y: c.y - b.y)
                let turn = abs(atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y))
                if turn < maxTurn {
                    result.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return result
    }

    /// Ramer–Douglas–Peucker.
    private static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points[0], last = points[points.count - 1]
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = segmentDistance(points[i], first, last)
            if d > maxDistance {
                maxDistance = d
                index = i
            }
        }
        guard maxDistance > epsilon else { return [first, last] }
        let left = simplify(Array(points[0...index]), epsilon: epsilon)
        let right = simplify(Array(points[index...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let length = distance(a, b)
        guard length > 0.001 else { return distance(p, a) }
        return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
    }

    /// PencilKit smooths between control points; dense points keep edges straight and corners sharp.
    private static func densify(_ outline: [CGPoint], step: CGFloat = 3) -> [CGPoint] {
        var result: [CGPoint] = []
        for i in 0..<(outline.count - 1) {
            let a = outline[i], b = outline[i + 1]
            let n = max(1, Int(distance(a, b) / step))
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = outline.last { result.append(last) }
        return result
    }

    private static func makeStroke(_ outline: [CGPoint], ink: PKInk, width: CGFloat) -> PKStroke {
        let points = outline.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: TimeInterval(index) * 0.004,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: .identity, mask: nil)
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}
