import Foundation

final class CWDecoder {
    static let analysisStep = 0.0025
    private static let alphabet: [String: String] = {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let codes = ".- -... -.-. -.. . ..-. --. .... .. .--- -.- .-.. -- -. --- .--. --.- .-. ... - ..- ...- .-- -..- -.-- --.. ----- .---- ..--- ...-- ....- ..... -.... --... ---.. ----."
        let symbols = [
            ".-.-.-": ".", "--..--": ",", "---...": ":", "..--..": "?", ".----.": "'",
            "-....-": "-", "-..-.": "/", "-.--.": "(", "-.--.-": ")", ".-..-.": "\"",
            "-...-": "=", ".-.-.": "+", ".--.-.": "@", "..-..": "É",
            "..--.-": "_", "-.-.--": "!", "-.-.-.": ";", ".-...": "&", "...-..-": "$",
            "..-.-": "¿", "--...-": "¡",
            ".-.-": "Ä", ".--.-": "Å", "-.-..": "Ç", "--.--": "Ñ", "---.": "Ö", "..--": "Ü",
            "...-.": "⟨VE⟩", "........": "⟨HH⟩", "...-.-": "⟨SK⟩", "-.-.-": "⟨KA⟩",
            "-...-.-": "⟨BK⟩", "...---...": "⟨SOS⟩"
        ]
        return Dictionary(uniqueKeysWithValues: zip(codes.split(separator: " ").map(String.init), letters.map(String.init)))
            .merging(symbols) { _, symbol in symbol }
    }()

    private let sampleRate: Double
    private var coefficients: [Double] = []
    private let window: [Double]
    private let initialDit: Double
    private let suppressIsolatedDots: Bool
    private let fixedThreshold: Double?
    private var dit: Double
    private var samples: [Double] = []
    private var offset = 0
    private var peak = 0.0
    private var noiseSamples = [Double](repeating: 0, count: 400)
    private var noiseIndex = 0
    private var noiseCount = 0
    private var noiseFloor = 0.0
    private var noiseCeiling = 0.0
    private var automaticThreshold = 0.00025
    private var thresholdHold = 0.0
    private(set) var pitch: Double
    private var keyDown = false
    private var consecutive = 0
    private var duration = 0.0
    private var marks: [(duration: Double, level: Double)] = []
    private var markLevel = 0.0
    private var previousMark: Double?
    private var proposedDit: Double?
    private var letterGap: Double?
    private var pendingSpace = false
    private var hasText = false
    private var tentative = ""
    private var confirmedWord = false
    private var measuredDit: Double?
    private var measuredMarks = 0
    private(set) var toneLevel = 0.0
    var estimatedWPM: Double? {
        guard measuredMarks >= 3, let measuredDit else { return nil }
        return 1.2 / measuredDit
    }

    init(sampleRate: Double, pitch: Double, wpm: Double, suppressIsolatedDots: Bool = false,
         thresholdDB: Double? = nil) {
        self.sampleRate = sampleRate
        self.pitch = pitch
        self.suppressIsolatedDots = suppressIsolatedDots
        fixedThreshold = thresholdDB.map { pow(10, $0 / 20) }
        initialDit = 1.2 / wpm
        dit = initialDit
        let size = Int(sampleRate * 0.010)
        window = (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(size - 1)) }
        coefficients = toneCoefficients(for: pitch)
    }

    private func toneCoefficients(for frequency: Double) -> [Double] {
        [frequency, max(50, frequency - 275), frequency + 275].map { 2 * cos(2 * .pi * $0 / sampleRate) }
    }

    func tune(to frequency: Double) {
        let distance = abs(frequency - pitch)
        guard distance >= 1 else { return }
        pitch = frequency
        coefficients = toneCoefficients(for: frequency)
        if distance >= 50 {
            keyDown = false
            consecutive = 0
            duration = 0
            marks.removeAll()
            markLevel = 0
            previousMark = nil
            proposedDit = nil
            letterGap = nil
            dit = initialDit
            measuredDit = nil
            measuredMarks = 0
            tentative = ""
            confirmedWord = false
            pendingSpace = hasText
            peak = 0
            noiseIndex = 0
            noiseCount = 0
            noiseFloor = 0
            noiseCeiling = 0
            automaticThreshold = 0.00025
            thresholdHold = 0
            toneLevel = 0
        }
    }

    private var wordGap: Double { max(4.7 * dit, (letterGap ?? 0) * 1.6) }

    private func learnElementSpacing(_ gap: Double) {
        guard let mark = previousMark, (0.015...0.165).contains(gap), gap <= dit * 1.35 else { return }
        let ratio = mark / gap
        let wasDash = (2.4...3.75).contains(ratio)
        guard wasDash || (0.75...1.45).contains(ratio) else { return }
        let estimate = (gap + mark / (wasDash ? 3 : 1)) / 2
        let matchesPrevious = proposedDit.map { abs(estimate - $0) < $0 * 0.20 } ?? false
        proposedDit = estimate
        if abs(estimate - dit) < dit * 0.27 {
            dit = dit * 0.85 + estimate * 0.15
        } else if matchesPrevious || (wasDash && gap < dit * 0.62) {
            dit = estimate
            letterGap = nil
            measuredDit = estimate
            measuredMarks = 3
        }
    }

    private func decodeCharacter() -> String {
        let strongest = marks.map(\.level).max() ?? 0
        let valid = marks.filter { $0.duration >= dit * 0.50 && $0.level >= strongest * 0.28 }
        guard !valid.isEmpty else { return "" }
        let code = String(valid.map { $0.duration >= dit * 2 ? Character("-") : Character(".") })
        if (code == "..--.." || code == "..--.-"), let last = valid.last,
           (1.55...2.40).contains(last.duration / dit) { return "_" }
        return Self.alphabet[code] ?? "_"
    }

    func consume(_ input: UnsafeBufferPointer<Float>,
                 observeTone: ((Double, Double) -> Void)? = nil) -> String {
        samples.append(contentsOf: input.lazy.map(Double.init))
        let hop = Int((sampleRate * Self.analysisStep).rounded())
        let step = Double(hop) / sampleRate
        let peakDecay = pow(0.997, step / 0.005)
        let meterDecay = pow(0.97, step / 0.005)
        let attack = 1 - exp(-step / 0.09)
        let release = 1 - exp(-step / 2.2)
        var output = ""
        while offset + window.count <= samples.count {
            let powers = coefficients.map { coefficient in
                var previous = 0.0
                var before = 0.0
                for index in window.indices {
                    let current = samples[offset + index] * window[index] + coefficient * previous - before
                    before = previous
                    previous = current
                }
                return max(0, previous * previous + before * before - coefficient * previous * before)
            }
            let level = sqrt(powers[0]) * 4 / Double(window.count)
            let nearby = sqrt((powers[1] + powers[2]) / 2) * 4 / Double(window.count)
            peak = max(level, peak * peakDecay)
            toneLevel = max(level, toneLevel * meterDecay)
            let noiseGuard = max(noiseFloor * 3.2, noiseCeiling * 1.26)
            let target = max(0.00025, peak * 0.20, noiseGuard,
                             min(nearby * 2.1, max(peak * 0.50, noiseGuard)))
            if target > automaticThreshold {
                automaticThreshold += (target - automaticThreshold) * attack
            } else if thresholdHold == 0 {
                automaticThreshold += (target - automaticThreshold) * release
            }
            let threshold = fixedThreshold ?? automaticThreshold
            let aboveSidebands = fixedThreshold != nil || level > nearby * (keyDown ? 1.5 : 2.1)
            let gate = fixedThreshold == nil
                ? max(threshold * (keyDown ? 0.65 : 1), peak * (keyDown ? 0.19 : 0.20))
                : threshold * (keyDown ? 0.65 : 1)
            let candidate = level > gate && aboveSidebands
            thresholdHold = candidate && keyDown ? 0.55 : max(0, thresholdHold - step)
            observeTone?(level, threshold)
            if !candidate, !keyDown {
                noiseSamples[noiseIndex] = level
                noiseIndex = (noiseIndex + 1) % noiseSamples.count
                noiseCount = min(noiseSamples.count, noiseCount + 1)
                if noiseCount >= 40, noiseIndex.isMultiple(of: 20) {
                    let background = noiseSamples.prefix(noiseCount).sorted()
                    noiseFloor = background[noiseCount / 5]
                    noiseCeiling = background[(noiseCount - 1) * 85 / 100]
                }
            }
            duration += step
            if candidate { markLevel = max(markLevel, level) }
            consecutive = candidate == keyDown ? 0 : consecutive + 1
            if consecutive == 3 {
                let interval = duration - step * 2
                if keyDown {
                    previousMark = nil
                    if interval >= 0.012, interval <= dit * 6 {
                        if marks.count < 10 { marks.append((interval, markLevel)) }
                        previousMark = interval
                        let estimate = interval / (interval >= dit * 2 ? 3 : 1)
                        if (dit * 0.72...dit * 1.30).contains(estimate) {
                            dit = dit * 0.92 + estimate * 0.08
                            measuredDit = measuredDit.map { $0 * 0.85 + estimate * 0.15 } ?? estimate
                            measuredMarks = min(3, measuredMarks + 1)
                        }
                    }
                    markLevel = 0
                } else {
                    if interval >= wordGap {
                        pendingSpace = hasText
                        tentative = ""
                        confirmedWord = false
                    } else if interval >= dit * 2.05 {
                        letterGap = letterGap.map { $0 * 0.8 + interval * 0.2 } ?? interval
                    } else {
                        learnElementSpacing(interval)
                    }
                }
                keyDown = candidate
                duration = step * 2
                consecutive = 0
            }
            if !keyDown, consecutive == 0 {
                if duration >= dit * 2.05, !marks.isEmpty {
                    let letter = decodeCharacter()
                    marks.removeAll(keepingCapacity: true)
                    if !letter.isEmpty {
                        if suppressIsolatedDots, !confirmedWord, ["E", "I"].contains(letter) {
                            tentative += letter
                        } else {
                            if pendingSpace { output += " " }
                            output += tentative + letter
                            tentative = ""
                            pendingSpace = false
                            confirmedWord = true
                            hasText = true
                        }
                    }
                }
                if hasText, duration >= max(1.5, dit * 12) {
                    output += "\n"
                    hasText = false
                    pendingSpace = false
                    tentative = ""
                    confirmedWord = false
                    proposedDit = nil
                    letterGap = nil
                    dit = initialDit
                    measuredDit = nil
                    measuredMarks = 0
                }
            }
            offset += hop
        }
        samples.removeFirst(offset)
        offset = 0
        return output
    }
}
