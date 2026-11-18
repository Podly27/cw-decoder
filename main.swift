import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio

struct AudioInput {
    let id: AudioDeviceID
    let name: String

    static func list() -> [AudioInput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }
            var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout.size(ofValue: name))
            let result = withUnsafeMutablePointer(to: &name) {
                AudioObjectGetPropertyData(id, &property, 0, nil, &nameSize, $0)
            }
            guard result == noErr, let name else { return nil }
            return AudioInput(id: id, name: name.takeRetainedValue() as String)
        }
    }
}

final class App: NSObject, NSApplicationDelegate {
    private let inputs = NSPopUpButton()
    private let channel = NSPopUpButton()
    private let pitch = NSTextField(string: "600")
    private let filterMode = NSPopUpButton()
    private let thresholdMode = NSPopUpButton()
    private let threshold = NSTextField(string: "-55")
    private let speed = NSTextField(string: "18")
    private let spectrum = AudioSpectrumView()
    private let waveform = ToneWaveformView()
    private let measuredSpeed = NSTextField(labelWithString: "Estimated: — WPM")
    private let noiseFilter = NSButton(checkboxWithTitle: "Suppress isolated E/I", target: nil, action: nil)
    private let output = NSTextView.scrollableTextView()
    private let status = NSTextField(labelWithString: "Select a radio input or open an audio recording.")
    private let level = NSLevelIndicator()
    private let start = NSButton(title: "Start Receiving", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh Inputs", target: nil, action: nil)
    private let file = NSButton(title: "Open Recording…", target: nil, action: nil)
    private var devices: [AudioInput] = []
    private var engine: AVAudioEngine?
    private var generation = UUID()
    private var busy = false
    private var window: NSWindow!
    private var observer: NSObjectProtocol?

    private var transcript: NSTextView { output.documentView as! NSTextView }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 610),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "CW Decoder · USB Audio"
        window.minSize = NSSize(width: 650, height: 510)
        window.center()
        channel.addItems(withTitles: ["1 · Left", "2 · Right"])
        filterMode.addItems(withTitles: ["AUTO", "FIX"])
        thresholdMode.addItems(withTitles: ["AUTO", "MANUAL"])
        for selector in [filterMode, thresholdMode] {
            selector.target = self
            selector.action = #selector(updateSettings)
        }
        pitch.widthAnchor.constraint(equalToConstant: 64).isActive = true
        speed.widthAnchor.constraint(equalToConstant: 52).isActive = true
        threshold.widthAnchor.constraint(equalToConstant: 56).isActive = true
        level.minValue = 0
        level.maxValue = 60
        level.levelIndicatorStyle = .continuousCapacity
        level.widthAnchor.constraint(equalToConstant: 110).isActive = true
        measuredSpeed.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        measuredSpeed.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        spectrum.heightAnchor.constraint(equalToConstant: 176).isActive = true
        noiseFilter.state = .on
        noiseFilter.toolTip = "Hides isolated groups made up of E and I, which can be caused by noise."
        transcript.isEditable = false
        transcript.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        transcript.textContainerInset = NSSize(width: 12, height: 12)

        let clear = NSButton(title: "Clear Text", target: self, action: #selector(clearText))
        for (button, action) in [(start, #selector(toggle)), (refresh, #selector(loadInputs)), (file, #selector(openRecording))] {
            button.target = self
            button.action = action
        }
        let source = row([NSTextField(labelWithString: "Input"), inputs, refresh])
        let settings = row([NSTextField(labelWithString: "Channel"), channel,
                            NSTextField(labelWithString: "Filter"), filterMode,
                            NSTextField(labelWithString: "Fixed Tone (Hz)"), pitch,
                            NSTextField(labelWithString: "Initial Speed (WPM)"), speed])
        let controls = row([start, file, clear])
        let meter = row([measuredSpeed, NSTextField(labelWithString: "Tone Level"), level,
                         NSTextField(labelWithString: "Threshold"), thresholdMode, threshold,
                         NSTextField(labelWithString: "dBFS")])
        let scopes = row([waveform, spectrum])
        scopes.distribution = .fillEqually
        let content = NSStackView(views: [source, settings, controls, scopes, meter, noiseFilter, output, status])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        let base = NSView()
        base.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: base.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: base.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: base.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: base.bottomAnchor, constant: -20),
            scopes.widthAnchor.constraint(equalTo: content.widthAnchor),
            waveform.heightAnchor.constraint(equalTo: spectrum.heightAnchor),
            output.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor)
        ])
        window.contentView = base

        let menu = NSMenu()
        let appMenu = NSMenu(title: "IC-9700 CW")
        appMenu.addItem(withTitle: "Quit IC-9700 CW", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        loadInputs()
        inputs.target = self
        inputs.action = #selector(rememberInput)
        setBusy(false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { stop() }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    @objc private func loadInputs() {
        let selected = selectedDevice?.id
        devices = AudioInput.list()
        inputs.removeAllItems()
        inputs.addItems(withTitles: ["Default macOS Input"])
        for device in devices {
            inputs.menu?.addItem(NSMenuItem(title: device.name, action: nil, keyEquivalent: ""))
        }
        let preferredName = UserDefaults.standard.string(forKey: "audioInputName")
        if let index = devices.firstIndex(where: { $0.id == selected })
            ?? devices.firstIndex(where: { $0.name == preferredName }) {
            inputs.selectItem(at: index + 1)
        }
    }

    @objc private func rememberInput() {
        UserDefaults.standard.set(selectedDevice?.name, forKey: "audioInputName")
    }

    private var selectedDevice: AudioInput? {
        let index = inputs.indexOfSelectedItem - 1
        return devices.indices.contains(index) ? devices[index] : nil
    }

    private struct Parameters {
        let pitch: Double
        let wpm: Double
        let channel: Int
        let automaticTuning: Bool
        let thresholdDB: Double?
    }

    private var parameters: Parameters? {
        guard let hz = Double(pitch.stringValue), (300...1200).contains(hz),
              let wpm = Double(speed.stringValue), (8...65).contains(wpm) else {
            status.stringValue = "Enter a tone from 300 to 1200 Hz and a speed from 8 to 65 WPM."
            return nil
        }
        var thresholdDB: Double?
        if thresholdMode.indexOfSelectedItem == 1 {
            guard let db = Double(threshold.stringValue), (-80...0).contains(db) else {
                status.stringValue = "Enter a manual threshold from −80 to 0 dBFS."
                return nil
            }
            thresholdDB = db
        }
        return Parameters(pitch: hz, wpm: wpm, channel: channel.indexOfSelectedItem,
                          automaticTuning: filterMode.indexOfSelectedItem == 0, thresholdDB: thresholdDB)
    }

    @objc private func clearText() { transcript.string = "" }

    @objc private func toggle() {
        if engine != nil { stop(); status.stringValue = "Reception stopped."; return }
        guard let params = parameters, !busy else { return }
        let device = selectedDevice
        setBusy(true)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.setBusy(false)
                guard granted else {
                    self.status.stringValue = "Allow microphone access for IC-9700 CW in macOS Privacy & Security settings."
                    return
                }
                self.receive(device, params)
            }
        }
    }

    private func receive(_ device: AudioInput?, _ params: Parameters) {
        let audio = AVAudioEngine()
        let input = audio.inputNode
        if let device {
            guard let unit = input.audioUnit else { status.stringValue = "The audio input is unavailable."; return }
            var id = device.id
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
            guard result == noErr else { status.stringValue = "Could not open the audio input (Core Audio \(result))."; return }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate >= 8000, Int(format.channelCount) > params.channel,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            status.stringValue = "The input or selected channel is unavailable. Try channel 1."
            return
        }
        let decoder = CWDecoder(sampleRate: format.sampleRate, pitch: params.pitch, wpm: params.wpm,
                                suppressIsolatedDots: noiseFilter.state == .on, thresholdDB: params.thresholdDB)
        let analyzer = AudioSpectrum(sampleRate: format.sampleRate)
        let tracker = params.automaticTuning ? CWToneTracker(pitch: params.pitch) : nil
        spectrum.pitch = params.pitch
        spectrum.reset()
        waveform.reset()
        generation = UUID()
        let run = generation
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard buffer.format.channelCount > params.channel, let data = buffer.floatChannelData else { return }
            let samples = UnsafeBufferPointer(start: data[params.channel], count: Int(buffer.frameLength))
            let frames = analyzer.consume(samples) { tracker?.update($0) }
            if let tracker { decoder.tune(to: tracker.pitch) }
            let trackedPitch = decoder.pitch
            var waveformSamples: [ToneWaveformView.Sample] = []
            let decoded = decoder.consume(samples) { level, threshold in
                waveformSamples.append(.init(level: level, threshold: threshold))
            }
            let amplitude = decoder.toneLevel
            let estimatedWPM = decoder.estimatedWPM
            DispatchQueue.main.async { [waveformSamples] in
                guard let self, self.generation == run else { return }
                self.level.doubleValue = max(0, 60 + 20 * log10(max(amplitude, 0.000001)))
                if let estimatedWPM { self.showSpeed(estimatedWPM) }
                self.spectrum.update(frames)
                if self.spectrum.pitch != trackedPitch {
                    self.spectrum.pitch = trackedPitch
                    self.showReceiveStatus(device, pitch: trackedPitch, automatic: params.automaticTuning)
                }
                self.waveform.update(waveformSamples)
                self.append(decoded)
            }
        }
        do {
            try audio.start()
            engine = audio
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: audio, queue: .main) { [weak self] _ in
                guard let self, self.generation == run else { return }
                self.stop()
                self.status.stringValue = "The audio input changed. Refresh the input list and start receiving again."
            }
            start.title = "Stop Receiving"
            setBusy(false)
            showReceiveStatus(device, pitch: params.pitch, automatic: params.automaticTuning)
        } catch {
            input.removeTap(onBus: 0)
            status.stringValue = error.localizedDescription
        }
    }

    private func stop() {
        generation = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        level.doubleValue = 0
        showSpeed(nil)
        spectrum.reset()
        waveform.reset()
        start.title = "Start Receiving"
        setBusy(false)
    }

    private func setBusy(_ value: Bool) {
        busy = value
        start.isEnabled = !value
        updateSettings()
    }

    @objc private func updateSettings() {
        let canConfigure = !busy && engine == nil
        [inputs, refresh, channel, speed, file, noiseFilter, filterMode, thresholdMode].forEach { $0.isEnabled = canConfigure }
        pitch.isEnabled = canConfigure && filterMode.indexOfSelectedItem == 1
        threshold.isEnabled = canConfigure && thresholdMode.indexOfSelectedItem == 1
    }

    private func showReceiveStatus(_ device: AudioInput?, pitch: Double, automatic: Bool) {
        status.stringValue = "Receiving · \(device?.name ?? "default macOS input") · \(automatic ? "AUTO" : "FIX") \(Int(pitch)) Hz"
    }

    private func showSpeed(_ value: Double?) {
        measuredSpeed.stringValue = "Estimated: \(value.map { String(Int($0.rounded())) } ?? "—") WPM"
    }

    private func append(_ text: String) {
        guard !text.isEmpty, let storage = transcript.textStorage else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: transcript.font ?? NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        storage.append(NSAttributedString(string: text, attributes: attributes))
        transcript.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    @objc private func openRecording() {
        guard let params = parameters else { return }
        let picker = NSOpenPanel()
        picker.title = "Open Audio Recording"
        picker.prompt = "Open"
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let suppressIsolatedDots = noiseFilter.state == .on
        setBusy(true)
        status.stringValue = "Decoding \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try decodeRecording(url, pitch: params.pitch, wpm: params.wpm, channel: params.channel,
                                    suppressIsolatedDots: suppressIsolatedDots, automaticTuning: params.automaticTuning,
                                    thresholdDB: params.thresholdDB)
            }
            DispatchQueue.main.async {
                self.setBusy(false)
                switch result {
                case .success(let recording):
                    if !self.transcript.string.isEmpty, !self.transcript.string.hasSuffix("\n"),
                       !recording.text.isEmpty { self.append("\n") }
                    self.append(recording.text)
                    self.showSpeed(recording.wpm)
                    self.status.stringValue = recording.text.isEmpty ? "No characters were decoded with these settings." : "Completed · \(url.lastPathComponent)"
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
}

func decodeRecording(_ url: URL, pitch: Double, wpm: Double, channel: Int,
                     suppressIsolatedDots: Bool = true, automaticTuning: Bool = false,
                     thresholdDB: Double? = nil) throws -> (text: String, wpm: Double?) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    guard format.channelCount > channel, format.sampleRate >= 8000,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
        throw NSError(domain: "IC9700CW", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The recording lacks the selected channel or has a sample rate below 8 kHz."])
    }
    let decoder = CWDecoder(sampleRate: format.sampleRate, pitch: pitch, wpm: wpm,
                            suppressIsolatedDots: suppressIsolatedDots, thresholdDB: thresholdDB)
    let tracker = automaticTuning ? CWToneTracker(pitch: pitch) : nil
    let analyzer = automaticTuning ? AudioSpectrum(sampleRate: format.sampleRate) : nil
    var result = ""
    var lastSpeed: Double?
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
        let samples = UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))
        if let tracker, let analyzer {
            _ = analyzer.consume(samples) { tracker.update($0) }
            decoder.tune(to: tracker.pitch)
        }
        result += decoder.consume(samples)
        lastSpeed = decoder.estimatedWPM ?? lastSpeed
    }
    let silence = [Float](repeating: 0, count: Int(format.sampleRate * 0.75))
    result += silence.withUnsafeBufferPointer { decoder.consume($0) }
    return (result, decoder.estimatedWPM ?? lastSpeed)
}

if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--decode",
   let pitch = Double(CommandLine.arguments[3]), (300...1200).contains(pitch),
   let wpm = Double(CommandLine.arguments[4]), (8...65).contains(wpm),
   let channel = Int(CommandLine.arguments[5]), (1...2).contains(channel) {
    do {
        print(try decodeRecording(URL(fileURLWithPath: CommandLine.arguments[2]), pitch: pitch, wpm: wpm, channel: channel - 1).text)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
} else if CommandLine.arguments.dropFirst().first == "--decode" {
    FileHandle.standardError.write(Data("Usage: IC9700CW --decode recording.wav tone_hz wpm channel\n".utf8))
    exit(2)
} else {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
