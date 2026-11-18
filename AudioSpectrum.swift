import AppKit

final class AudioSpectrum {
    static let upperFrequency = 1500
    static let binWidth = 25
    private let window: [Float]
    private let coefficients: [Float]
    private var samples: [Float] = []
    private var smoothed: [Float] = []

    init(sampleRate: Double) {
        let count = Int(sampleRate / Double(Self.binWidth))
        window = (0..<count).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(count - 1))) }
        coefficients = stride(from: 0, through: Self.upperFrequency, by: Self.binWidth).map {
            Float(2 * cos(2 * .pi * Double($0) / sampleRate))
        }
        samples.reserveCapacity(count)
    }

    func consume(_ input: UnsafeBufferPointer<Float>,
                 observeFrame: (([Float]) -> Void)? = nil) -> [[Float]] {
        var frames: [[Float]] = []
        var index = 0
        while index < input.count {
            let count = min(window.count - samples.count, input.count - index)
            samples.append(contentsOf: input[index..<(index + count)])
            index += count
            if samples.count == window.count {
                let weighted = zip(samples, window).map(*)
                let frame = coefficients.map { coefficient in
                    var previous: Float = 0
                    var before: Float = 0
                    for sample in weighted {
                        let next = sample + coefficient * previous - before
                        before = previous
                        previous = next
                    }
                    let energy = max(0, previous * previous + before * before - coefficient * previous * before)
                    let amplitude = sqrt(energy) * 4 / Float(window.count)
                    let db = 20 * log10(max(amplitude, 0.0001))
                    return min(1, max(0, (db + 80) / 80))
                }
                observeFrame?(frame)
                smoothed = smoothed.isEmpty ? frame : zip(frame, smoothed).map { max($0, $1 - 0.10) }
                frames.append(smoothed)
                samples.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }
}

final class CWToneTracker {
    private(set) var pitch: Double
    private var locked = false
    private var pendingBin: Int?
    private var pendingFrames = 0
    private var framesWithoutCurrentTone = 0
    // Spectrum frames are 40 ms apart. Hold through ordinary CW gaps.
    private let holdFrames = 15

    init(pitch: Double) { self.pitch = pitch }

    func update(_ frame: [Float]) {
        let search = 8..<(frame.count - 2) // 200–1450 Hz, with room to evaluate both sides.
        let noise = search.map { frame[$0] }.sorted()[search.count / 2]
        let peaks = search.filter { bin in
            frame[bin] >= frame[bin - 1] && frame[bin] > frame[bin + 1]
                && frame[bin] > max(0.175, noise + 0.125, max(frame[bin - 2], frame[bin + 2]) + 0.075)
        }
        let binWidth = Double(AudioSpectrum.binWidth)
        let currentBin = Int((pitch / binWidth).rounded())
        let nearCurrent = peaks.filter { abs($0 - currentBin) <= 1 }
        let kept = nearCurrent.max { frame[$0] < frame[$1] }
        framesWithoutCurrentTone = kept == nil ? min(holdFrames, framesWithoutCurrentTone + 1) : 0
        guard let strongest = peaks.max(by: { frame[$0] < frame[$1] }) else {
            pendingFrames = max(0, pendingFrames - 1)
            return
        }
        let selected = kept.flatMap { frame[strongest] - frame[$0] < 0.035 ? $0 : nil } ?? strongest

        let changingTone = abs(selected - currentBin) > 1
        if locked {
            if let pendingBin, abs(pendingBin - selected) <= 1 {
                pendingFrames = min(6, pendingFrames + 1)
            } else {
                pendingFrames = 1
            }
            pendingBin = selected
            if changingTone {
                // A persistent stronger tone may take over even while both are audible.
                let requiredFrames = kept == nil ? 4 : 6
                guard pendingFrames >= requiredFrames,
                      kept != nil || framesWithoutCurrentTone >= holdFrames else { return }
            } else {
                guard pendingFrames >= 3 else { return }
            }
        }
        locked = true
        let center = Double(frame[selected])
        let left = Double(frame[selected - 1])
        let right = Double(frame[selected + 1])
        let curvature = left + right - 2 * center
        let offset = curvature < 0 ? min(0.5, max(-0.5, 0.5 * (left - right) / curvature)) : 0
        let measured = ((Double(selected) + offset) * binWidth / 5).rounded() * 5
        if abs(pitch - measured) >= 10 {
            pitch = measured
            if changingTone {
                framesWithoutCurrentTone = 0
                pendingFrames = 0
                pendingBin = nil
            }
        }
    }
}

final class AudioSpectrumView: NSView {
    private let displayedUpperFrequency = 900
    private var frames: [[Float]] = []
    private let historyLength = 60
    private let background = NSColor(srgbRed: 0.04, green: 0.09, blue: 0.14, alpha: 1)
    private let grid = NSColor(srgbRed: 0.19, green: 0.29, blue: 0.36, alpha: 1)
    private let trace = NSColor(srgbRed: 0.35, green: 0.87, blue: 1, alpha: 1)
    private let marker = NSColor(srgbRed: 1, green: 0.30, blue: 0.32, alpha: 1)
    private let axis = NSColor(srgbRed: 0.72, green: 0.83, blue: 0.9, alpha: 1)
    private lazy var palette = (0...20).map { index in
        let value = CGFloat(index) / 20
        return NSColor(srgbRed: max(0, value * 2 - 1), green: value * value,
                       blue: min(1, value * 2), alpha: 1)
    }

    var pitch = 600.0 { didSet { needsDisplay = true } }

    override var isOpaque: Bool { true }

    func update(_ newFrames: [[Float]]) {
        guard !newFrames.isEmpty else { return }
        frames.append(contentsOf: newFrames)
        if frames.count > historyLength { frames.removeFirst(frames.count - historyLength) }
        needsDisplay = true
    }

    func reset() {
        frames.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let left: CGFloat = 44
        let width = bounds.width - left - 24
        let bottom: CGFloat = 22
        let split = bottom + (bounds.height - bottom - 12) * 0.35
        let top = bounds.height - 12
        guard width > 0, top > split else { return }

        let upper = Double(displayedUpperFrequency)
        let visibleBinCount = displayedUpperFrequency / AudioSpectrum.binWidth + 1
        func x(_ hz: Double) -> CGFloat { left + width * hz / upper }
        let axisAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: axis
        ]
        func label(_ text: String, at point: NSPoint, centered: Bool = false) {
            let width = centered ? text.size(withAttributes: axisAttributes).width : 0
            text.draw(at: NSPoint(x: point.x - width / 2, y: point.y), withAttributes: axisAttributes)
        }
        for frequency in stride(from: 0, through: displayedUpperFrequency, by: 150) {
            grid.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x(Double(frequency)), y: bottom),
                                    to: NSPoint(x: x(Double(frequency)), y: top))
            label("\(frequency)", at: NSPoint(x: x(Double(frequency)), y: 5), centered: true)
        }
        label("Hz", at: NSPoint(x: 12, y: 5))
        for db in [-80, -40, 0] {
            let y = split + (top - split) * CGFloat(db + 80) / 80
            grid.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: left, y: y), to: NSPoint(x: left + width, y: y))
            label("\(db)", at: NSPoint(x: 9, y: y - 5))
        }

        let rowHeight = (split - bottom) / CGFloat(historyLength)
        for (index, frame) in frames.reversed().enumerated() {
            let y = split - CGFloat(index + 1) * rowHeight
            let halfBin = Double(AudioSpectrum.binWidth) / 2
            for (bin, value) in frame.prefix(visibleBinCount).enumerated() where value >= 0.05 {
                let hz = Double(bin * AudioSpectrum.binWidth)
                let minX = x(max(0, hz - halfBin))
                let maxX = x(min(upper, hz + halfBin))
                palette[Int(value * 20)].setFill()
                NSRect(x: minX, y: y, width: maxX - minX, height: rowHeight).fill()
            }
        }

        if let spectrum = frames.last {
            let line = NSBezierPath()
            line.lineWidth = 1.5
            for (bin, value) in spectrum.prefix(visibleBinCount).enumerated() {
                let point = NSPoint(x: x(Double(bin * AudioSpectrum.binWidth)),
                                    y: split + (top - split) * CGFloat(value))
                if bin == 0 { line.move(to: point) } else { line.line(to: point) }
            }
            trace.setStroke()
            line.stroke()
        }

        if (0...upper).contains(pitch) {
            marker.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x(pitch), y: bottom), to: NSPoint(x: x(pitch), y: top))
        }
    }
}

final class ToneWaveformView: NSView {
    struct Sample {
        let level: Double
        let threshold: Double
    }
    private let historyLength = Int(1.5 / CWDecoder.analysisStep)
    private var samples: [Sample] = []

    func update(_ newSamples: [Sample]) {
        guard !newSamples.isEmpty else { return }
        samples.append(contentsOf: newSamples)
        if samples.count > historyLength { samples.removeFirst(samples.count - historyLength) }
        needsDisplay = true
    }

    func reset() {
        samples.removeAll()
        needsDisplay = true
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.04, green: 0.09, blue: 0.14, alpha: 1).setFill()
        bounds.fill()
        let left: CGFloat = 44
        let right = bounds.width - 16
        let bottom: CGFloat = 22
        let top = bounds.height - 31
        guard right > left, top > bottom else { return }

        let axis = NSColor(srgbRed: 0.72, green: 0.83, blue: 0.9, alpha: 1)
        let grid = NSColor(srgbRed: 0.19, green: 0.29, blue: 0.36, alpha: 1)
        let signalColor = NSColor(srgbRed: 0.43, green: 0.91, blue: 0.58, alpha: 1)
        let thresholdColor = NSColor(srgbRed: 1, green: 0.68, blue: 0.32, alpha: 1)

        func label(_ text: String, at point: NSPoint, color: NSColor = .white) {
            text.draw(at: point, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                .foregroundColor: color])
        }
        func y(_ db: Double) -> CGFloat {
            bottom + (top - bottom) * min(1, max(0, (db + 80) / 80))
        }

        label("CW Amplitude", at: NSPoint(x: left, y: top + 10), color: signalColor)
        label("Threshold", at: NSPoint(x: right - 56, y: top + 10), color: thresholdColor)
        for db in [-80, -40, 0] {
            let position = y(Double(db))
            grid.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: left, y: position), to: NSPoint(x: right, y: position))
            label("\(db)", at: NSPoint(x: 9, y: position - 5), color: axis)
        }
        for tick in 0...3 {
            let x = left + (right - left) * CGFloat(tick) / 3
            grid.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: bottom), to: NSPoint(x: x, y: top))
            label(["−1.5 s", "−1 s", "−0.5 s", "0 s"][tick],
                  at: NSPoint(x: x - (tick == 3 ? 12 : 11), y: 5), color: axis)
        }

        func drawTrace(_ keyPath: KeyPath<Sample, Double>, color: NSColor, dashed: Bool) {
            let path = NSBezierPath()
            path.lineWidth = dashed ? 1 : 1.5
            if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
            let step = (right - left) / CGFloat(historyLength - 1)
            let start = right - step * CGFloat(samples.count - 1)
            for (index, sample) in samples.enumerated() {
                let point = NSPoint(x: start + step * CGFloat(index),
                                    y: y(20 * log10(max(0.0001, sample[keyPath: keyPath]))))
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            color.setStroke()
            path.stroke()
        }

        if !samples.isEmpty {
            drawTrace(\.threshold, color: thresholdColor, dashed: true)
            drawTrace(\.level, color: signalColor, dashed: false)
        }
    }
}
