// fanmon — temperature & fan menu bar monitor for Apple Silicon (M-series) Macs
//
// Fans   → read from the SMC (IOKit AppleSMC user client), keys F<n>Ac/Mn/Mx/Tg.
// Temps  → read from the IOKitHID thermal sensors (the way M-series exposes
//          on-die temperatures; classic SMC "T…" keys are absent on Apple Silicon).
// Neither path needs sudo or special entitlements.

import Cocoa
import IOKit

// MARK: - SMC (fans)

final class SMC {
    private var conn: io_connect_t = 0
    private let KERNEL_INDEX_SMC: UInt32 = 2      // kSMCHandleYPCEvent
    private let CMD_READ_BYTES: Int8 = 5          // kSMCReadKey
    private let CMD_READ_KEYINFO: Int8 = 9        // kSMCGetKeyInfo

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }

    private func fourCCToString(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return (String(bytes: b, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func call(_ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
        var outSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC,
                                         &input, MemoryLayout<SMCKeyData_t>.stride,
                                         &output, &outSize)
    }

    /// Read a raw key: returns its data bytes and 4-char type code (e.g. "flt", "fpe2", "ui8").
    private func read(_ key: String) -> (bytes: [UInt8], type: String)? {
        let k = fourCC(key)

        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = k
        input.data8 = CMD_READ_KEYINFO
        guard call(&input, &output) == kIOReturnSuccess else { return nil }

        let size = output.keyInfo.dataSize
        let type = output.keyInfo.dataType
        guard size > 0 else { return nil }

        input = SMCKeyData_t()
        output = SMCKeyData_t()
        input.key = k
        input.keyInfo.dataSize = size
        input.keyInfo.dataType = type
        input.data8 = CMD_READ_BYTES
        guard call(&input, &output) == kIOReturnSuccess else { return nil }

        let arr = withUnsafeBytes(of: output.bytes) { Array($0) }
        return (arr, fourCCToString(type))
    }

    /// Read a key as a numeric value, decoding the SMC data type.
    func readNumber(_ key: String) -> Double? {
        guard let (a, type) = read(key), a.count >= 1 else { return nil }
        switch type {
        case "flt":
            guard a.count >= 4 else { return nil }
            let bits = UInt32(a[0]) | (UInt32(a[1]) << 8) | (UInt32(a[2]) << 16) | (UInt32(a[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard a.count >= 2 else { return nil }
            return Double((UInt16(a[0]) << 8) | UInt16(a[1])) / 4.0
        case "fp1f":
            guard a.count >= 2 else { return nil }
            return Double((UInt16(a[0]) << 8) | UInt16(a[1])) / 32768.0
        case "ui8":
            return Double(a[0])
        case "ui16":
            guard a.count >= 2 else { return nil }
            return Double((UInt16(a[0]) << 8) | UInt16(a[1]))
        case "ui32":
            guard a.count >= 4 else { return nil }
            return Double((UInt32(a[0]) << 24) | (UInt32(a[1]) << 16) | (UInt32(a[2]) << 8) | UInt32(a[3]))
        default:
            return nil
        }
    }

    struct Fan { let index: Int; let rpm: Int; let min: Int?; let max: Int?; let target: Int? }

    func fans() -> [Fan] {
        guard let count = readNumber("FNum"), count > 0 else { return [] }
        var result: [Fan] = []
        for i in 0..<Int(count) {
            let rpm = readNumber("F\(i)Ac").map { Int($0.rounded()) } ?? 0
            let mn  = readNumber("F\(i)Mn").map { Int($0.rounded()) }
            let mx  = readNumber("F\(i)Mx").map { Int($0.rounded()) }
            let tg  = readNumber("F\(i)Tg").map { Int($0.rounded()) }
            result.append(Fan(index: i, rpm: rpm, min: mn, max: mx, target: tg))
        }
        return result
    }
}

// MARK: - Thermal sensors (temperatures)

struct TempSensor { let name: String; let celsius: Double }

func readThermalSensors() -> [TempSensor] {
    // Match Apple-vendor temperature sensors: usage page 0xff00, usage 0x05.
    let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005]
    guard let clientRef = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return [] }
    let client = clientRef.takeRetainedValue()
    IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
    guard let services = IOHIDEventSystemClientCopyServices(client) else { return [] }

    let TEMPERATURE_EVENT: Int64 = 15                 // kIOHIDEventTypeTemperature
    let TEMPERATURE_FIELD: Int32 = 15 << 16           // IOHIDEventFieldBase(kIOHIDEventTypeTemperature)

    var out: [TempSensor] = []
    for i in 0..<CFArrayGetCount(services) {
        guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
        let service = unsafeBitCast(raw, to: IOHIDServiceClient.self)
        guard let eventRef = IOHIDServiceClientCopyEvent(service, TEMPERATURE_EVENT, 0, 0) else { continue }
        let t = IOHIDEventGetFloatValue(eventRef.takeRetainedValue(), TEMPERATURE_FIELD)
        guard t > 0, t < 120 else { continue }        // drop unpopulated / bogus channels
        var name = "Sensor \(i)"
        if let p = IOHIDServiceClientCopyProperty(service, "Product" as CFString), let s = p as? String, !s.isEmpty {
            name = s
        }
        out.append(TempSensor(name: name, celsius: t))
    }
    return out
}

/// Collapse duplicate sensor names (the M-series exposes many `tdie` instances)
/// into one averaged reading per name.
func aggregate(_ sensors: [TempSensor]) -> [TempSensor] {
    var groups: [String: (sum: Double, n: Int)] = [:]
    var order: [String] = []
    for s in sensors {
        if groups[s.name] == nil { order.append(s.name) }
        let g = groups[s.name] ?? (0, 0)
        groups[s.name] = (g.sum + s.celsius, g.n + 1)
    }
    return order.map { TempSensor(name: $0, celsius: groups[$0]!.sum / Double(groups[$0]!.n)) }
}

/// Die/compute sensors (the `tdie` channels) — the ones that track CPU/GPU load.
func dieSensors(_ sensors: [TempSensor]) -> [TempSensor] {
    sensors.filter { $0.name.lowercased().contains("tdie") }
}

struct ThermalSummary {
    let hottestDie: Double?
    let averageDie: Double?
    let battery: Double?
    let nand: Double?         // SSD/NAND temperature
    let hottest: Double?      // hottest of any sensor
    let dies: [TempSensor]    // aggregated die sensors, hottest first
    let others: [TempSensor]  // aggregated non-die sensors, hottest first

    /// Headline temperature: the hottest of the die / battery / NAND components.
    var headline: Double? { [hottestDie, battery, nand].compactMap { $0 }.max() }
}

func summarize(_ raw: [TempSensor]) -> ThermalSummary {
    let agg = aggregate(raw)
    let dies = dieSensors(agg).sorted { $0.celsius > $1.celsius }
    let others = agg.filter { !$0.name.lowercased().contains("tdie") }
                    .sorted { $0.celsius > $1.celsius }
    let dieVals = dies.map(\.celsius)
    func maxWhere(_ needles: [String]) -> Double? {
        agg.filter { s in needles.contains { s.name.lowercased().contains($0) } }.map(\.celsius).max()
    }
    return ThermalSummary(
        hottestDie: dieVals.max(),
        averageDie: dieVals.isEmpty ? nil : dieVals.reduce(0, +) / Double(dieVals.count),
        battery: maxWhere(["batt", "gas gauge"]),
        nand: maxWhere(["nand", "ssd"]),
        hottest: agg.map(\.celsius).max(),
        dies: dies, others: others)
}

// MARK: - Heat state (menu bar colour)

enum HeatState {
    case cool, warm, hot
    init(_ c: Double?) {
        switch c ?? 0 {
        case ..<70:  self = .cool
        case ..<90:  self = .warm
        default:     self = .hot
        }
    }
    var color: NSColor {
        switch self {
        case .cool: return .labelColor        // passive / neutral when cool
        case .warm: return .systemOrange
        case .hot:  return .systemRed
        }
    }
    var thermometerSymbol: String {
        switch self {
        case .cool: return "thermometer.low"
        case .warm: return "thermometer.medium"
        case .hot:  return "thermometer.high"
        }
    }
}

/// The menu bar title: coloured thermometer + headline temp, then a fan glyph + max RPM.
func menuBarTitle(headline: Double?, maxRPM: Int?) -> NSAttributedString {
    let state = HeatState(headline)
    let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    let t = NSMutableAttributedString()
    t.append(symbolAttachment(state.thermometerSymbol, color: state.color))
    t.append(NSAttributedString(string: headline.map { " \(Int($0.rounded()))°" } ?? " --°",
                                attributes: [.foregroundColor: state.color, .font: mono]))
    if let rpm = maxRPM {
        t.append(NSAttributedString(string: "  ", attributes: [.font: mono]))
        t.append(symbolAttachment("fanblades", color: .secondaryLabelColor))
        t.append(NSAttributedString(string: " \(rpm)",
                                    attributes: [.foregroundColor: NSColor.labelColor, .font: mono]))
    }
    return t
}

/// A coloured SF Symbol wrapped as a text attachment, for use in an attributed string.
func symbolAttachment(_ name: String, color: NSColor, pointSize: CGFloat = 12) -> NSAttributedString {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        return NSAttributedString(string: "")
    }
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    let img = base.withSymbolConfiguration(cfg) ?? base
    img.isTemplate = false
    let att = NSTextAttachment()
    att.image = img
    att.bounds = CGRect(x: 0, y: (pointSize - img.size.height) / 2 - 1,
                        width: img.size.width, height: img.size.height)
    return NSAttributedString(attachment: att)
}

/// A coloured SF Symbol as a plain NSImage, for direct drawing (e.g. on the graph).
func symbolImage(_ name: String, color: NSColor, pointSize: CGFloat = 12) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    let img = base.withSymbolConfiguration(cfg) ?? base
    img.isTemplate = false
    return img
}

/// Tidy a raw sensor name for display (e.g. "PMU tdie6" -> "tdie6").
func displayName(_ name: String) -> String {
    name.hasPrefix("PMU ") ? String(name.dropFirst(4)) : name
}

// MARK: - History log (last 30 min, one sample per minute, persisted)

struct HistorySample { let t: Date; let die: Double?; let battery: Double?; let nand: Double?; let fan: Double? }

final class HistoryStore {
    private(set) var samples: [HistorySample] = []
    private let window: TimeInterval = 30 * 60
    private let minInterval: TimeInterval = 60
    private let url: URL
    private var lastLog: Date?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fanmon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.csv")
        load()
    }

    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-window)
        samples = text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let epoch = Double(f[0]) else { return nil }
            let t = Date(timeIntervalSince1970: epoch)
            guard t >= cutoff else { return nil }
            return HistorySample(t: t, die: Double(f[1]), battery: Double(f[2]), nand: Double(f[3]),
                                 fan: f.count > 4 ? Double(f[4]) : nil)   // 4-col rows predate fan logging
        }
        lastLog = samples.last?.t
    }

    /// Record a sample, but no more than once per minute.
    func maybeRecord(die: Double?, battery: Double?, nand: Double?, fan: Double?, now: Date = Date()) {
        if let last = lastLog, now.timeIntervalSince(last) < minInterval { return }
        lastLog = now
        samples.append(HistorySample(t: now, die: die, battery: battery, nand: nand, fan: fan))
        samples.removeAll { $0.t < now.addingTimeInterval(-window) }
        persist()
    }

    private func persist() {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        let text = samples
            .map { "\(Int($0.t.timeIntervalSince1970)),\(f($0.die)),\(f($0.battery)),\(f($0.nand)),\(f($0.fan))" }
            .joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Panel view (custom-drawn menu contents + trend graph)

final class PanelView: NSView {
    struct Data {
        let fans: [SMC.Fan]
        let summary: ThermalSummary
        let history: [HistorySample]
    }

    private let data: Data
    private let now = Date()
    private let width: CGFloat = 340
    private let padX: CGFloat = 16
    private let headerH: CGFloat = 24
    private let rowH: CGFloat = 22
    private let graphH: CGFloat = 116
    private let legendH: CGFloat = 20
    private let gap: CGFloat = 8

    private let dieColor = NSColor.systemBlue
    private let batteryColor = NSColor.systemGreen
    private let nandColor = NSColor.systemPurple

    init(data: Data) {
        self.data = data
        super.init(frame: .zero)
        frame = NSRect(x: 0, y: 0, width: width, height: contentHeight())
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override var isFlipped: Bool { true }   // top-down layout

    private func contentHeight() -> CGFloat {
        let fanRows = max(data.fans.count, 1)
        var h: CGFloat = 10
        h += headerH + CGFloat(fanRows) * rowH + gap        // fans
        h += headerH + 4 * rowH + gap                        // temperatures (4 rows)
        h += headerH + graphH + legendH                      // trend
        h += 12
        return h
    }

    // MARK: drawing helpers
    private func draw(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }
    private func drawRight(_ s: String, _ font: NSFont, _ color: NSColor, rightX: CGFloat, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let w = (s as NSString).size(withAttributes: attrs).width
        (s as NSString).draw(at: NSPoint(x: rightX - w, y: y), withAttributes: attrs)
    }
    /// Draw an image upright inside this flipped view.
    private func drawImage(_ img: NSImage, in r: NSRect) {
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let rightX = width - padX
        var y: CGFloat = 10

        func header(_ s: String) {
            draw(s.uppercased(), headerFont, .secondaryLabelColor, at: NSPoint(x: padX, y: y + 5))
            y += headerH
        }
        func row(_ label: String, _ value: String, color: NSColor = .labelColor) {
            draw(label, labelFont, .labelColor, at: NSPoint(x: padX, y: y + 3))
            drawRight(value, valueFont, color, rightX: rightX, y: y + 3)
            y += rowH
        }
        func temp(_ v: Double?) -> String { v.map { String(format: "%.1f °C", $0) } ?? "—" }

        // FANS
        header("Fans")
        if data.fans.isEmpty {
            row("No fans detected", "")
        } else {
            for f in data.fans {
                let pct = f.max.flatMap { $0 > 0 ? Int((Double(f.rpm) / Double($0) * 100).rounded()) : nil }
                let note = f.rpm == 0 ? "idle" : (pct.map { "\($0)%" } ?? "")
                row("Fan \(f.index + 1)", "\(f.rpm) rpm   \(note)")
            }
        }
        y += gap

        // TEMPERATURES
        header("Temperatures")
        row("Hottest die", temp(data.summary.hottestDie), color: HeatState(data.summary.hottestDie).color)
        row("Average die", temp(data.summary.averageDie))
        row("Battery",     temp(data.summary.battery))
        row("NAND (SSD)",  temp(data.summary.nand))
        y += gap

        // TREND (header carries a right-aligned "fan on" key)
        let trendY = y
        draw("TREND · LAST 30 MIN", headerFont, .secondaryLabelColor, at: NSPoint(x: padX, y: trendY + 5))
        if let icon = symbolImage("fanblades", color: .systemOrange, pointSize: 11) {
            let keyFont = NSFont.systemFont(ofSize: 11, weight: .regular)
            let keyText = "fan on"
            let tw = (keyText as NSString).size(withAttributes: [.font: keyFont]).width
            let ix = rightX - tw - icon.size.width - 4
            drawImage(icon, in: NSRect(x: ix, y: trendY + 4, width: icon.size.width, height: icon.size.height))
            draw(keyText, keyFont, .secondaryLabelColor, at: NSPoint(x: ix + icon.size.width + 4, y: trendY + 5))
        }
        y += headerH
        drawGraph(in: NSRect(x: padX, y: y, width: width - 2 * padX, height: graphH))
        y += graphH
        drawLegend(at: y)
    }

    private func drawGraph(in rect: NSRect) {
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let values = data.history.flatMap { [$0.die, $0.battery, $0.nand].compactMap { $0 } }

        guard values.count >= 2 else {
            draw("collecting data… (one sample per minute)", NSFont.systemFont(ofSize: 11),
                 .tertiaryLabelColor, at: NSPoint(x: rect.minX, y: rect.midY - 6))
            return
        }

        // Y range, padded and snapped to 5°.
        let lo = (floor((values.min()! - 2) / 5)) * 5
        var hi = (ceil((values.max()! + 2) / 5)) * 5
        if hi - lo < 10 { hi = lo + 10 }

        let gutter: CGFloat = 30
        let plot = NSRect(x: rect.minX + gutter, y: rect.minY + 4,
                          width: rect.width - gutter - 4, height: rect.height - 20)
        let start = now.addingTimeInterval(-historyWindow)

        func x(_ t: Date) -> CGFloat {
            let f = max(0, min(1, t.timeIntervalSince(start) / historyWindow))
            return plot.minX + CGFloat(f) * plot.width
        }
        func yFor(_ v: Double) -> CGFloat {
            let f = (v - lo) / (hi - lo)
            return plot.maxY - CGFloat(f) * plot.height   // flipped: high temp near top
        }

        // Gridlines + y labels.
        for gv in [lo, (lo + hi) / 2, hi] {
            let gy = yFor(gv)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: gy))
            line.line(to: NSPoint(x: plot.maxX, y: gy))
            NSColor.separatorColor.setStroke()
            line.lineWidth = 1
            line.stroke()
            drawRight(String(format: "%.0f°", gv), smallFont, .tertiaryLabelColor,
                      rightX: plot.minX - 5, y: gy - 6)
        }

        // Fan-on periods: faint orange band behind the series; icon drawn after.
        let fanColor = NSColor.systemOrange
        var fanIconCenters: [CGFloat] = []
        var spanStart: Date?
        var spanEnd: Date?
        func closeFanSpan() {
            guard let s0 = spanStart, let s1 = spanEnd else { return }
            let x0 = x(s0), x1 = max(x(s1), x0 + 3)
            fanColor.withAlphaComponent(0.13).setFill()
            NSBezierPath(rect: NSRect(x: x0, y: plot.minY, width: x1 - x0, height: plot.height)).fill()
            fanIconCenters.append((x0 + x1) / 2)
            spanStart = nil; spanEnd = nil
        }
        for s in data.history {
            if (s.fan ?? 0) > 0 { if spanStart == nil { spanStart = s.t }; spanEnd = s.t }
            else { closeFanSpan() }
        }
        closeFanSpan()

        // Time labels (30m ago … now).
        draw("30m", smallFont, .tertiaryLabelColor, at: NSPoint(x: plot.minX, y: plot.maxY + 4))
        drawRight("now", smallFont, .tertiaryLabelColor, rightX: plot.maxX, y: plot.maxY + 4)

        // Series.
        func line(_ pick: (HistorySample) -> Double?, _ color: NSColor) {
            let pts = data.history.compactMap { s -> NSPoint? in pick(s).map { NSPoint(x: x(s.t), y: yFor($0)) } }
            guard pts.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.line(to: p) }
            color.setStroke()
            path.lineWidth = 1.75
            path.lineJoinStyle = .round
            path.stroke()
        }
        line({ $0.die }, dieColor)
        line({ $0.battery }, batteryColor)
        line({ $0.nand }, nandColor)

        // Fan icon centred over each on-period (drawn last, on top).
        if let icon = symbolImage("fanblades", color: fanColor, pointSize: 11) {
            for cx in fanIconCenters {
                drawImage(icon, in: NSRect(x: cx - icon.size.width / 2, y: plot.minY + 2,
                                           width: icon.size.width, height: icon.size.height))
            }
        }
    }

    private func drawLegend(at yTop: CGFloat) {
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        var x = padX
        let y = yTop + 4
        func entry(_ color: NSColor, _ label: String, _ value: Double?) {
            let dot = NSBezierPath(ovalIn: NSRect(x: x, y: y + 2, width: 8, height: 8))
            color.setFill(); dot.fill()
            x += 12
            let text = value.map { "\(label) \(Int($0.rounded()))°" } ?? label
            draw(text, font, .labelColor, at: NSPoint(x: x, y: y))
            x += (text as NSString).size(withAttributes: [.font: font]).width + 14
        }
        entry(dieColor, "Die", data.summary.averageDie)
        entry(batteryColor, "Battery", data.summary.battery)
        entry(nandColor, "NAND", data.summary.nand)
    }

    private let historyWindow: TimeInterval = 30 * 60
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let smc = SMC()
    private let history = HistoryStore()
    private var titleTimer: Timer?
    private var logTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Persist the item's position so it returns to where you put it after every
        // relaunch/rebuild (instead of defaulting back to the notch-adjacent slot).
        statusItem.autosaveName = "com.modulo17.fanmon"

        let menu = NSMenu()
        menu.delegate = self          // contents rebuilt on demand in menuNeedsUpdate(_:)
        statusItem.menu = menu

        updateTitle()
        recordSample()                // seed the history log immediately

        let tt = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateTitle() }
        RunLoop.main.add(tt, forMode: .common); titleTimer = tt

        let lt = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.recordSample() }
        RunLoop.main.add(lt, forMode: .common); logTimer = lt
    }

    private func recordSample() {
        let s = summarize(readThermalSensors())
        let fanRPM = (smc?.fans() ?? []).map(\.rpm).max().map(Double.init)
        history.maybeRecord(die: s.averageDie, battery: s.battery, nand: s.nand, fan: fanRPM)
    }

    /// Lightweight tick: refresh only the menu bar title (safe while the menu is open).
    /// Title is temperature-only to stay compact; fan speeds live in the dropdown panel.
    private func updateTitle() {
        let s = summarize(readThermalSensors())
        statusItem.button?.attributedTitle = menuBarTitle(headline: s.headline, maxRPM: nil)
    }

    /// Called by AppKit right before the menu opens — rebuild its contents from a fresh reading.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        recordSample()   // capture the current moment so the graph is up to date on open
        let s = summarize(readThermalSensors())
        let fans = smc?.fans() ?? []

        let panel = NSMenuItem()
        panel.view = PanelView(data: .init(fans: fans, summary: s, history: history.samples))
        menu.addItem(panel)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit fanmon",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

// MARK: - Entry point

// `fanmon --dump` prints a one-shot reading to stdout and exits — no menu bar.
if CommandLine.arguments.contains("--dump") {
    let summary = summarize(readThermalSensors())
    let fans = SMC()?.fans() ?? []
    print("FANS (\(fans.count)):")
    if fans.isEmpty { print("  none detected") }
    for f in fans {
        let rng = (f.min != nil && f.max != nil) ? "  [\(f.min!)–\(f.max!) rpm]" : ""
        print(String(format: "  Fan %d: %5d rpm%@%@", f.index + 1, f.rpm, f.rpm == 0 ? "  (stopped)" : "", rng))
    }
    func t(_ v: Double?) -> String { v.map { String(format: "%.1f °C", $0) } ?? "—" }
    print(String(format: "\nHeadline: %@  (die %@ · battery %@ · NAND %@)",
                 t(summary.headline), t(summary.hottestDie), t(summary.battery), t(summary.nand)))
    if let avg = summary.averageDie { print("Average die: \(t(avg))") }
    let all = summary.dies + summary.others
    print("\nALL SENSORS (\(all.count)):")
    if all.isEmpty { print("  none detected") }
    for s in all { print(String(format: "  %-20@ %6.1f °C", displayName(s.name) as NSString, s.celsius)) }
    exit(0)
}

// `fanmon --render <png> [--dark]` draws the popover panel to an image (with a
// synthesized 30-min history) — a headless way to preview the menu layout/graph.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    let dark = CommandLine.arguments.contains("--dark")
    let s = summarize(readThermalSensors())
    let fans = SMC()?.fans() ?? []
    let now = Date()
    let baseDie = s.averageDie ?? 45, baseBat = s.battery ?? 34, baseNand = s.nand ?? 35
    var hist: [HistorySample] = []
    for k in stride(from: 30, through: 0, by: -1) {
        let w = Double(30 - k)
        let fanOn = (w >= 8 && w <= 14) || w >= 23   // two demo on-periods
        hist.append(HistorySample(t: now.addingTimeInterval(TimeInterval(-k * 60)),
                                  die: baseDie + sin(w / 3) * 6 + w * 0.25,
                                  battery: baseBat + sin(w / 5) * 1.5,
                                  nand: baseNand + cos(w / 4) * 1.2,
                                  fan: fanOn ? 1600 : 0))
    }
    let panel = PanelView(data: .init(fans: fans, summary: s, history: hist))
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    panel.appearance = appearance
    let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds)!
    appearance.performAsCurrentDrawingAppearance {   // resolve semantic colours correctly
        panel.cacheDisplay(in: panel.bounds, to: rep)
    }

    let out = NSImage(size: panel.bounds.size)
    out.lockFocus()
    (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.98, alpha: 1)).setFill()
    NSBezierPath(rect: panel.bounds).fill()
    rep.draw(in: panel.bounds)
    out.unlockFocus()
    if let tiff = out.tiffRepresentation, let b = NSBitmapImageRep(data: tiff),
       let png = b.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
    exit(0)
}

// `fanmon --render-title <png>` previews the menu bar title across cool/warm/hot.
if let i = CommandLine.arguments.firstIndex(of: "--render-title"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    let cases: [(String, Double)] = [("cool", 46), ("warm", 78), ("hot", 96)]
    let lineH: CGFloat = 26, labelW: CGFloat = 52, pad: CGFloat = 10
    let titles = cases.map { menuBarTitle(headline: $0.1, maxRPM: nil) }
    let width = labelW + pad + (titles.map { $0.size().width }.max() ?? 120) + pad * 2
    let size = NSSize(width: width, height: lineH * CGFloat(cases.count) + pad * 2)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(white: 0.95, alpha: 1).setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    let lblFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    for (idx, (name, _)) in cases.enumerated() {
        let y = size.height - pad - CGFloat(idx + 1) * lineH + 6
        (name as NSString).draw(at: NSPoint(x: pad, y: y),
                                withAttributes: [.font: lblFont, .foregroundColor: NSColor.gray])
        titles[idx].draw(at: NSPoint(x: labelW + pad, y: y))
    }
    img.unlockFocus()
    if let tiff = img.tiffRepresentation, let b = NSBitmapImageRep(data: tiff),
       let png = b.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
