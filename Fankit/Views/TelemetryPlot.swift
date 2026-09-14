import SwiftUI

/// Draw only the current bounded sample snapshot; no per-sample chart subgraphs.
struct TelemetryPlot: View {
    struct Point {
        let time: Double
        let value: Double
    }

    struct Series {
        let points: [Point]
        let color: Color
    }

    let series: [Series]
    let domain: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let points = series.flatMap(\.points).filter { $0.time.isFinite && $0.value.isFinite }
            guard let firstTime = points.map(\.time).min(),
                  let lastTime = points.map(\.time).max(),
                  domain.lowerBound.isFinite, domain.upperBound.isFinite
            else { return }
            let timeSpan = max(lastTime - firstTime, 1)
            let valueSpan = max(domain.upperBound - domain.lowerBound, 1)
            let inset = 3.0
            let width = max(size.width - 2 * inset, 0)
            let height = max(size.height - 2 * inset, 0)
            for line in series {
                var path = Path()
                var last: CGPoint?
                for point in line.points {
                    guard point.time.isFinite, point.value.isFinite else {
                        last = nil
                        continue
                    }
                    let x = inset + (point.time - firstTime) / timeSpan * width
                    let fraction = min(max((point.value - domain.lowerBound) / valueSpan, 0), 1)
                    let position = CGPoint(x: x, y: inset + (1 - fraction) * height)
                    if last == nil { path.move(to: position) } else { path.addLine(to: position) }
                    last = position
                }
                context.stroke(path, with: .color(line.color), lineWidth: 1.5)
                if let last {
                    context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
                                 with: .color(line.color))
                }
            }
        }
        .accessibilityHidden(true) // The enclosing telemetry card provides the current readings.
    }
}
