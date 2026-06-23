import SwiftUI

struct WaveformBarsCanvas: View, Equatable {
    let bars: [Float]
    var showsEmptyBaseline = true
    var baselineRanges: [ClosedRange<CGFloat>] = []
    var headerHeight: CGFloat = 0
    var fillColor: Color = Color.dawWaveformFill

    private let minBarHeight: CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            drawWaveform(in: &context, size: size)
        }
        .drawingGroup()
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        let bodyHeight = max(1, size.height - headerHeight)
        let midY = headerHeight + bodyHeight / 2

        if !bars.isEmpty {
            let barWidth = size.width / CGFloat(bars.count)
            let maxBarHeight = (bodyHeight / 2) * 0.92

            if baselineRanges.isEmpty {
                drawFilledWaveformSegment(
                    in: &context,
                    range: 0...(size.width),
                    bars: bars,
                    barWidth: barWidth,
                    midY: midY,
                    maxBarHeight: maxBarHeight,
                    fillColor: fillColor
                )
            } else {
                for range in baselineRanges {
                    drawFilledWaveformSegment(
                        in: &context,
                        range: range,
                        bars: bars,
                        barWidth: barWidth,
                        midY: midY,
                        maxBarHeight: maxBarHeight,
                        fillColor: fillColor
                    )
                }
            }
        } else if showsEmptyBaseline {
            let ranges = baselineRanges.isEmpty ? [0...(size.width)] : baselineRanges
            for range in ranges {
                let startX = max(0, range.lowerBound)
                let endX = min(size.width, range.upperBound)
                drawSilentSegment(in: &context, startX: startX, endX: endX, midY: midY, fillColor: fillColor)
            }
        }
    }

    private func drawFilledWaveformSegment(
        in context: inout GraphicsContext,
        range: ClosedRange<CGFloat>,
        bars: [Float],
        barWidth: CGFloat,
        midY: CGFloat,
        maxBarHeight: CGFloat,
        fillColor: Color
    ) {
        let startX = max(0, range.lowerBound)
        let endX = min(range.upperBound, CGFloat(bars.count) * barWidth)
        guard endX > startX else { return }

        let startIndex = max(0, Int(floor(startX / barWidth)))
        let endIndex = min(bars.count - 1, Int(floor((endX - 0.001) / barWidth)))
        guard startIndex <= endIndex else {
            drawSilentSegment(in: &context, startX: startX, endX: endX, midY: midY, fillColor: fillColor)
            return
        }

        func barHeight(at index: Int) -> CGFloat {
            max(minBarHeight, CGFloat(bars[index]) * maxBarHeight)
        }

        func barCenterX(at index: Int) -> CGFloat {
            CGFloat(index) * barWidth + barWidth * 0.5
        }

        var path = Path()
        path.move(to: CGPoint(x: startX, y: midY))

        for index in startIndex...endIndex {
            path.addLine(to: CGPoint(x: barCenterX(at: index), y: midY - barHeight(at: index)))
        }

        path.addLine(to: CGPoint(x: endX, y: midY))

        for index in stride(from: endIndex, through: startIndex, by: -1) {
            path.addLine(to: CGPoint(x: barCenterX(at: index), y: midY + barHeight(at: index)))
        }

        path.addLine(to: CGPoint(x: startX, y: midY))
        path.closeSubpath()
        context.fill(path, with: .color(fillColor))
    }

    private func drawSilentSegment(
        in context: inout GraphicsContext,
        startX: CGFloat,
        endX: CGFloat,
        midY: CGFloat,
        fillColor: Color
    ) {
        guard endX > startX else { return }

        let rect = CGRect(x: startX, y: midY - minBarHeight, width: endX - startX, height: minBarHeight * 2)
        context.fill(Path(rect), with: .color(fillColor))
    }
}
