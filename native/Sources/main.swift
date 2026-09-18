import AppKit
import CoreGraphics
import Sparkle
import Security

// Pure accounting: unknown, paused, and idle time never enter the ratio.
struct AppUsage: Codable {
    var name: String
    var seconds: Double = 0
    var unclassified: Double? = 0
    var createSeconds: Double?
    var consumeSeconds: Double?
    var lastUsed: Double?
}

struct Ledger: Codable {
    var day: String
    var consume: Double = 0
    var create: Double = 0
    var apps: [String: AppUsage]? = [:] // Optional preserves totals saved by v0.1.
    mutating func record(_ seconds: Double, mode: String?, appID: String = "", appName: String = "") {
        guard seconds > 0, seconds <= 3 else { return }
        if !appID.isEmpty {
            var usage = apps ?? [:]
            var entry = usage[appID] ?? AppUsage(name: appName)
            if entry.createSeconds == nil || entry.consumeSeconds == nil {
                let classified = max(0, entry.seconds - (entry.unclassified ?? 0))
                entry.createSeconds = mode == "create" ? classified : 0
                entry.consumeSeconds = mode == "consume" ? classified : 0
            }
            entry.name = appName; entry.seconds += seconds; entry.lastUsed = Date().timeIntervalSince1970
            if mode == "create" { entry.createSeconds = (entry.createSeconds ?? 0) + seconds }
            if mode == "consume" { entry.consumeSeconds = (entry.consumeSeconds ?? 0) + seconds }
            if mode == nil { entry.unclassified = (entry.unclassified ?? 0) + seconds }
            usage[appID] = entry; apps = usage
        }
        if mode == "create" { create += seconds }
        if mode == "consume" { consume += seconds }
    }
    mutating func classifyPending(_ id: String, mode: String, previousMode: String? = nil) {
        guard mode == "create" || mode == "consume" || mode == "neutral", var usage = apps?[id] else { return }
        let classified = max(0, usage.seconds - (usage.unclassified ?? 0))
        let oldCreate = usage.createSeconds ?? (previousMode == "create" ? classified : 0)
        let oldConsume = usage.consumeSeconds ?? (previousMode == "consume" ? classified : 0)
        create = max(0, create - oldCreate)
        consume = max(0, consume - oldConsume)
        usage.createSeconds = mode == "create" ? usage.seconds : 0
        usage.consumeSeconds = mode == "consume" ? usage.seconds : 0
        create += usage.createSeconds ?? 0
        consume += usage.consumeSeconds ?? 0
        usage.unclassified = 0; apps?[id] = usage
    }


}

struct DaySummary: Codable {
    var day: String
    var create: Double
    var consume: Double
}
struct ResetSnapshot {
    var ledger: Ledger
    var rules: [String: String]
    var activeSeconds: Double
    var paused: Bool
    var prompted: Set<String>
    var chromeSessionSites: Set<String>
    var mode: String?
}
func dayKey(_ date: Date = Date()) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
}

// One type scale throughout the interface; only the ratio is enlarged.
let interfaceFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
var lightMode = UserDefaults.standard.bool(forKey: "lightMode")
var panelBackground: NSColor { NSColor(white: lightMode ? 0.97 : 0.06, alpha: 1) }
var panelText: NSColor { lightMode ? .black : .white }
var selectionBackground: NSColor { NSColor(white: lightMode ? 0.91 : 0.075, alpha: 1) }
let createColor = NSColor(srgbRed: 40/255, green: 205/255, blue: 65/255, alpha: 1)
let consumeColor = NSColor(srgbRed: 1, green: 59/255, blue: 48/255, alpha: 1)
let unclassifiedColor = NSColor(srgbRed: 1, green: 159/255, blue: 10/255, alpha: 1)
var gridColor: NSColor { NSColor(white: lightMode ? 0.8 : 0.14, alpha: 1) }
func hairline(_ rect: NSRect) { gridColor.setFill(); NSBezierPath(rect: rect).fill() }

// Lucide Moon geometry, matching the web icon (ISC license).
func drawWebMoon(in bounds: NSRect, color: NSColor, flipped: Bool) {
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(translationByX: bounds.midX - 7, byY: bounds.midY + (flipped ? -7 : 7))
    var scaled = transform
    scaled.scale(x: 14 / 24, y: (flipped ? 14.0 : -14.0) / 24)
    (scaled as NSAffineTransform).concat()
    let p = NSBezierPath()
    p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: 20.985000000, y: 12.486000000))
    p.curve(to: NSPoint(x: 11.836619803, y: 20.999415324), controlPoint1: NSPoint(x: 20.723859872, y: 17.323495733), controlPoint2: NSPoint(x: 16.680379204, y: 21.086329102))
    p.curve(to: NSPoint(x: 2.999550507, y: 12.163278897), controlPoint1: NSPoint(x: 6.992860402, y: 20.912501545), controlPoint2: NSPoint(x: 3.086975635, y: 17.007029095))
    p.curve(to: NSPoint(x: 11.512000000, y: 3.014000000), controlPoint1: NSPoint(x: 2.912125379, y: 7.319528698), controlPoint2: NSPoint(x: 6.674531862, y: 3.275650815))
    p.curve(to: NSPoint(x: 11.914000000, y: 3.817000000), controlPoint1: NSPoint(x: 11.917000000, y: 2.992000000), controlPoint2: NSPoint(x: 12.129000000, y: 3.474000000))
    p.curve(to: NSPoint(x: 12.759321576, y: 11.239678424), controlPoint1: NSPoint(x: 10.433186096, y: 6.186256558), controlPoint2: NSPoint(x: 10.783696807, y: 9.264053655))
    p.curve(to: NSPoint(x: 20.182000000, y: 12.085000000), controlPoint1: NSPoint(x: 14.734946345, y: 13.215303193), controlPoint2: NSPoint(x: 17.812743442, y: 13.565813904))
    p.curve(to: NSPoint(x: 20.985000000, y: 12.486000000), controlPoint1: NSPoint(x: 20.526000000, y: 11.870000000), controlPoint2: NSPoint(x: 21.007000000, y: 12.081000000))
    color.setStroke(); p.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func drawHistoryClock(in bounds: NSRect, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(translationByX: bounds.midX - 7, byY: bounds.midY - 7)
    var scaled = transform
    scaled.scale(x: 14 / 24, y: 14 / 24)
    (scaled as NSAffineTransform).concat()
    let p = NSBezierPath()
    p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: 3, y: 12))
    p.curve(to: NSPoint(x: 12, y: 21), controlPoint1: NSPoint(x: 3, y: 16.97), controlPoint2: NSPoint(x: 7.03, y: 21))
    p.curve(to: NSPoint(x: 21, y: 12), controlPoint1: NSPoint(x: 16.97, y: 21), controlPoint2: NSPoint(x: 21, y: 16.97))
    p.curve(to: NSPoint(x: 12, y: 3), controlPoint1: NSPoint(x: 21, y: 7.03), controlPoint2: NSPoint(x: 16.97, y: 3))
    p.curve(to: NSPoint(x: 5.26, y: 5.74), controlPoint1: NSPoint(x: 9.47, y: 3), controlPoint2: NSPoint(x: 7.04, y: 4.04))
    p.line(to: NSPoint(x: 3, y: 8))
    p.move(to: NSPoint(x: 3, y: 3)); p.line(to: NSPoint(x: 3, y: 8)); p.line(to: NSPoint(x: 8, y: 8))
    p.move(to: NSPoint(x: 12, y: 7)); p.line(to: NSPoint(x: 12, y: 12)); p.line(to: NSPoint(x: 16, y: 14))
    color.setStroke(); p.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func drawBackArrow(in bounds: NSRect, color: NSColor) {
    let p = NSBezierPath()
    p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: bounds.midX + 6, y: bounds.midY)); p.line(to: NSPoint(x: bounds.midX - 6, y: bounds.midY))
    p.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY)); p.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 6))
    p.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY)); p.line(to: NSPoint(x: bounds.midX, y: bounds.midY - 6))
    color.setStroke(); p.stroke()
}

func drawSortArrows(in bounds: NSRect, color: NSColor) {
    let p = NSBezierPath()
    p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
    let x = bounds.midX
    p.move(to: NSPoint(x: x, y: bounds.midY + 1.5)); p.line(to: NSPoint(x: x, y: bounds.midY + 8))
    p.move(to: NSPoint(x: x - 4.5, y: bounds.midY + 3.5)); p.line(to: NSPoint(x: x, y: bounds.midY + 8)); p.line(to: NSPoint(x: x + 4.5, y: bounds.midY + 3.5))
    p.move(to: NSPoint(x: x, y: bounds.midY - 1.5)); p.line(to: NSPoint(x: x, y: bounds.midY - 8))
    p.move(to: NSPoint(x: x - 4.5, y: bounds.midY - 3.5)); p.line(to: NSPoint(x: x, y: bounds.midY - 8)); p.line(to: NSPoint(x: x + 4.5, y: bounds.midY - 3.5))
    color.setStroke(); p.stroke()
}

class GridButton: NSButton {
    var drawsGridEdges = true
    var drawsBottomEdge = true
    var invertsWhenHighlighted = true
    var needsAttention = false
    override func draw(_ dirtyRect: NSRect) {
        let selected = (state == .on || isHighlighted) && !needsAttention
        (selected ? (invertsWhenHighlighted ? panelText : selectionBackground) : panelBackground).setFill()
        NSBezierPath(rect: bounds).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: selected && invertsWhenHighlighted ? panelBackground : panelText]
        let text = title.uppercased() as NSString
        let size = text.size(withAttributes: attrs)
        if needsAttention {
            let count = title.split(separator: " ").last.map(String.init) ?? ""
            let countText = count as NSString
            let diameter: CGFloat = 19
            let circle = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            unclassifiedColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let badgeAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor(white: 0.12, alpha: 1)]
            let badge = countText
            let badgeSize = badge.size(withAttributes: badgeAttrs)
            badge.draw(at: NSPoint(x: circle.midX - badgeSize.width / 2, y: circle.midY - badgeSize.height / 2), withAttributes: badgeAttrs)
        } else if title == "☾" {
            drawWebMoon(in: bounds, color: attrs[.foregroundColor] as! NSColor, flipped: isFlipped)
        } else if title == "◷" {
            drawHistoryClock(in: bounds, color: attrs[.foregroundColor] as! NSColor)
        } else if title == "←" {
            drawBackArrow(in: bounds, color: attrs[.foregroundColor] as! NSColor)
        } else if title == "↑↓" {
            drawSortArrows(in: bounds, color: attrs[.foregroundColor] as! NSColor)
        } else {
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        if drawsGridEdges {
            hairline(NSRect(x: bounds.width - pixel, y: 0, width: pixel, height: bounds.height))
            if drawsBottomEdge { hairline(NSRect(x: 0, y: 0, width: bounds.width, height: pixel)) }
        }
    }
}

final class AppListView: NSView {
    weak var owner: AppDelegate?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        panelBackground.setFill(); NSBezierPath(rect: bounds).fill()
        guard let owner = owner else { return }
        let rows = owner.sortedUsage(owner.ledger.apps ?? [:])
        let total = rows.reduce(0) { $0 + $1.value.seconds }
        let attrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: panelText]
        if rows.isEmpty {
            ("APP USE WILL APPEAR HERE" as NSString).draw(at: NSPoint(x: 16, y: 20), withAttributes: attrs)
        }
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        for (index, row) in rows.enumerated() {
            let y = CGFloat(index * 56)
            let name = row.value.name + (row.key == owner.activeID ? " ·" : "")
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            var nameAttrs = attrs; nameAttrs[.paragraphStyle] = style
            (name as NSString).draw(in: NSRect(x: 16, y: y + 12, width: 230, height: 18), withAttributes: nameAttrs)
            let duration = owner.duration(row.value.seconds) as NSString
            duration.draw(at: NSPoint(x: 344 - duration.size(withAttributes: attrs).width, y: y + 12), withAttributes: attrs)
            NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 16, y: y + 39, width: total > 0 ? 232 * min(1, max(0, row.value.seconds / total)) : 0, height: pixel)).fill()
            hairline(NSRect(x: 264, y: y, width: pixel, height: 56))
            hairline(NSRect(x: 0, y: y + 56 - pixel, width: bounds.width, height: pixel))
        }
    }
}

final class ReviewButton: GridButton {
    var hasCategory = false
    var siteID = ""
    var mode = ""
    override func draw(_ dirtyRect: NSRect) {
        (state == .on || isHighlighted ? selectionBackground : panelBackground).setFill()
        NSBezierPath(rect: bounds).fill()
        let color: NSColor = hasCategory && state != .on ? NSColor(white: 0.4, alpha: 1) : (mode == "create" ? createColor : mode == "consume" ? consumeColor : state == .on ? panelText : NSColor(white: 0.55, alpha: 1))
        let attrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: color]
        let text = title as NSString; let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attrs)
        if state == .on { text.draw(at: NSPoint(x: origin.x + 0.35, y: origin.y), withAttributes: attrs) }
        // Row separators belong to the list; each control owns only its left edge.
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        hairline(NSRect(x: 0, y: 0, width: pixel, height: bounds.height))
    }
}
final class ReviewListView: NSView {
    override var isFlipped: Bool { true }
}

final class HistoryListView: NSView {
    weak var owner: AppDelegate?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        panelBackground.setFill(); NSBezierPath(rect: bounds).fill()
        guard let owner = owner else { return }
        let entries = owner.historyEntries()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: NSColor.gray]
        if entries.isEmpty { ("NO HISTORY YET" as NSString).draw(at: NSPoint(x: 16, y: 14), withAttributes: labelAttrs) }
        for (index, entry) in entries.enumerated() {
            let y = CGFloat(index * 44)
            (owner.shortDay(entry.day) as NSString).draw(at: NSPoint(x: 16, y: y + 13), withAttributes: labelAttrs)
            let total = entry.create + entry.consume
            let fraction = total > 0 ? entry.create / total : 0.5
            consumeColor.setFill(); NSBezierPath(rect: NSRect(x: 84, y: y + 21, width: 164, height: 2)).fill()
            createColor.setFill(); NSBezierPath(rect: NSRect(x: 84, y: y + 21, width: 164 * fraction, height: 2)).fill()
            let create = total > 0 ? Int((fraction * 100).rounded()) : 0
            let ratio = total > 0 ? "\(create)/\(100 - create)" : "—/—"
            let ratioColor = total == 0 ? panelText : (create > 50 ? createColor : (create < 50 ? consumeColor : panelText))
            let ratioAttrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: ratioColor]
            let text = ratio as NSString
            text.draw(at: NSPoint(x: 344 - text.size(withAttributes: ratioAttrs).width, y: y + 13), withAttributes: ratioAttrs)
            hairline(NSRect(x: 0, y: y + 44 - pixel, width: bounds.width, height: pixel))
        }
    }
}

final class CaretDividerView: NSView {
    weak var panel: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let panel = panel else { return }
        let content = convert(panel.bounds, from: panel)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let bottom = content.maxY
        let height: CGFloat = 9
        let tip = bottom + height - pixel
        let edge = content.insetBy(dx: pixel / 2, dy: pixel / 2)
        let radius: CGFloat = 10
        let tangent = radius * (1 - 0.5522847498)
        let x = content.midX
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: x - height, y: edge.maxY))
        outline.line(to: NSPoint(x: edge.minX + radius, y: edge.maxY))
        outline.curve(to: NSPoint(x: edge.minX, y: edge.maxY - radius), controlPoint1: NSPoint(x: edge.minX + tangent, y: edge.maxY), controlPoint2: NSPoint(x: edge.minX, y: edge.maxY - tangent))
        outline.line(to: NSPoint(x: edge.minX, y: edge.minY + radius))
        outline.curve(to: NSPoint(x: edge.minX + radius, y: edge.minY), controlPoint1: NSPoint(x: edge.minX, y: edge.minY + tangent), controlPoint2: NSPoint(x: edge.minX + tangent, y: edge.minY))
        outline.line(to: NSPoint(x: edge.maxX - radius, y: edge.minY))
        outline.curve(to: NSPoint(x: edge.maxX, y: edge.minY + radius), controlPoint1: NSPoint(x: edge.maxX - tangent, y: edge.minY), controlPoint2: NSPoint(x: edge.maxX, y: edge.minY + tangent))
        outline.line(to: NSPoint(x: edge.maxX, y: edge.maxY - radius))
        outline.curve(to: NSPoint(x: edge.maxX - radius, y: edge.maxY), controlPoint1: NSPoint(x: edge.maxX, y: edge.maxY - tangent), controlPoint2: NSPoint(x: edge.maxX - tangent, y: edge.maxY))
        outline.line(to: NSPoint(x: x + height, y: edge.maxY))
        outline.curve(to: NSPoint(x: x, y: tip),
                      controlPoint1: NSPoint(x: x + height * 0.55, y: edge.maxY),
                      controlPoint2: NSPoint(x: x + height * 0.45, y: tip))
        outline.curve(to: NSPoint(x: x - height, y: edge.maxY),
                      controlPoint1: NSPoint(x: x - height * 0.45, y: tip),
                      controlPoint2: NSPoint(x: x - height * 0.55, y: edge.maxY))
        outline.close()
        // Fill only the caret area from the exact outline used for its stroke.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: content.minX, y: bottom, width: content.width, height: height + 1)).addClip()
        panelBackground.setFill(); outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        gridColor.setStroke(); outline.lineWidth = pixel; outline.stroke()
    }
}

final class RatioView: NSView {
    private var caretDivider: CaretDividerView?
    weak var owner: AppDelegate?
    var selectedTab = 0
    var reviewingPending = false
    let notifications = GridButton(title: "", target: nil, action: nil)
    let sortOrder = GridButton(title: "↑↓", target: nil, action: nil)
    let ratioTab = GridButton(title: "Ratio", target: nil, action: nil)
    let appsTab = GridButton(title: "Apps", target: nil, action: nil)
    let appScroll = NSScrollView()
    let appList = AppListView(frame: .zero)
    let reviewList = ReviewListView(frame: .zero)
    let reviewScroll = NSScrollView()
    let historyScroll = NSScrollView()
    let historyList = HistoryListView(frame: .zero)
    var showingHistory = false
    let reviewButton = GridButton(title: "Review sites", target: nil, action: nil)
    var reviewSignature = ""
    var showingApps: Bool { selectedTab == 1 }
    let title = NSTextField(labelWithString: "TODAY")
    let totals = NSTextField(labelWithString: "")
    let context = NSTextField(wrappingLabelWithString: "")
    let trackedTotal = NSTextField(labelWithString: "")
    let note = NSTextField(wrappingLabelWithString: "")
    let consume = GridButton(title: "↓ Consume", target: nil, action: #selector(AppDelegate.chooseConsume))
    let create = GridButton(title: "↑ Create", target: nil, action: #selector(AppDelegate.chooseCreate))
    let pause = GridButton(title: "Pause", target: nil, action: #selector(AppDelegate.togglePause))
    let history = GridButton(title: "◷", target: nil, action: nil)
    let forget = GridButton(title: "Reset", target: nil, action: #selector(AppDelegate.resetAll))
    let theme = GridButton(title: "☀", target: nil, action: #selector(toggleTheme))
    let quit = GridButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = panelBackground.cgColor
        for button in [ratioTab, appsTab, consume, create, pause, history, forget, quit, theme] {
            button.font = interfaceFont; button.isBordered = false; button.setButtonType(.momentaryPushIn); addSubview(button)
        }
        ratioTab.target = self; ratioTab.action = #selector(showRatio)
        appsTab.target = self; appsTab.action = #selector(showApps)
        ratioTab.frame = NSRect(x: 0, y: 396, width: 180, height: 44)
        appsTab.frame = NSRect(x: 180, y: 396, width: 180, height: 44)
        for label in [title, totals, context, note] { label.font = interfaceFont; label.textColor = panelText; addSubview(label) }
        totals.font = .monospacedSystemFont(ofSize: 48, weight: .regular)
        totals.alignment = .center
        title.frame = NSRect(x: 16, y: 365, width: 260, height: 18)
        let brand = NSTextField(labelWithString: "RATIO")
        brand.isHidden = true; title.isHidden = true
        brand.font = interfaceFont; brand.textColor = .gray; brand.alignment = .right
        brand.frame = NSRect(x: 276, y: 365, width: 68, height: 18); addSubview(brand)
        let notificationPixel = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        notifications.frame = NSRect(x: 272 + notificationPixel, y: 264 + notificationPixel, width: 44 - notificationPixel, height: 44 - notificationPixel)
        notifications.drawsGridEdges = false
        notifications.target = self; notifications.action = #selector(togglePending)
        notifications.font = interfaceFont; notifications.isBordered = false
        addSubview(notifications)
        sortOrder.frame = NSRect(x: 316 + notificationPixel, y: 264 + notificationPixel, width: 44 - notificationPixel, height: 44 - notificationPixel)
        sortOrder.drawsGridEdges = false
        sortOrder.invertsWhenHighlighted = false
        sortOrder.target = self; sortOrder.action = #selector(toggleSort)
        sortOrder.font = interfaceFont; sortOrder.isBordered = false
        addSubview(sortOrder)
        totals.frame = NSRect(x: 16, y: 269, width: 328, height: 65)
        context.frame = NSRect(x: 16, y: 277, width: 156, height: 18)
        context.textColor = .gray
        trackedTotal.font = interfaceFont; trackedTotal.textColor = .gray; trackedTotal.alignment = .right
        trackedTotal.frame = NSRect(x: 180, y: 277, width: 84, height: 18)
        addSubview(trackedTotal)
        note.frame = NSRect(x: 16, y: 53, width: 328, height: 46)
        create.frame = NSRect(x: 0, y: 108, width: 180, height: 44)
        consume.frame = NSRect(x: 180, y: 108, width: 180, height: 44)
        pause.frame = NSRect(x: 0, y: 0, width: 44, height: 44)
        history.frame = NSRect(x: 44, y: 0, width: 44, height: 44)
        history.target = self; history.action = #selector(toggleHistory)
        history.invertsWhenHighlighted = false
        history.toolTip = "History"; history.setAccessibilityLabel("Show history")
        forget.frame = NSRect(x: 88, y: 0, width: 114, height: 44)
        quit.frame = NSRect(x: 202, y: 0, width: 114, height: 44)
        theme.frame = NSRect(x: 316, y: 0, width: 44, height: 44)
        theme.target = self; theme.drawsGridEdges = false; theme.invertsWhenHighlighted = false
        pause.drawsBottomEdge = false; history.drawsBottomEdge = false; forget.drawsBottomEdge = false
        quit.drawsBottomEdge = false
        appScroll.frame = NSRect(x: 0, y: 108, width: 360, height: 244)
        appScroll.drawsBackground = false; appScroll.hasVerticalScroller = true; appScroll.scrollerStyle = .overlay
        appScroll.documentView = appList; addSubview(appScroll); appScroll.isHidden = true
        reviewScroll.frame = NSRect(x: 0, y: 44, width: 360, height: 220); reviewScroll.drawsBackground = false
        reviewScroll.hasVerticalScroller = true; reviewScroll.scrollerStyle = .overlay
        reviewScroll.documentView = reviewList; addSubview(reviewScroll); reviewScroll.isHidden = true
        historyScroll.frame = NSRect(x: 0, y: 44, width: 360, height: 220); historyScroll.drawsBackground = false
        historyScroll.hasVerticalScroller = true; historyScroll.scrollerStyle = .overlay
        historyList.owner = owner; historyScroll.documentView = historyList; addSubview(historyScroll); historyScroll.isHidden = true
        reviewButton.frame = NSRect(x: 0, y: 44, width: 360, height: 64)
        reviewButton.target = self; reviewButton.action = #selector(showReview); addSubview(reviewButton)
        reviewButton.isHidden = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The native popover draws its arrow outside our content view.
        // Color that backing surface too, so the arrow matches the panel.
        window?.backgroundColor = panelBackground
        window?.hasShadow = false
        var ancestor = superview
        while let view = ancestor {
            if let effect = view as? NSVisualEffectView {
                effect.state = .inactive
                effect.wantsLayer = true
                effect.layer?.backgroundColor = panelBackground.cgColor
            }
            ancestor = view.superview
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.window != nil else { return }
            self.window?.hasShadow = false
            self.window?.invalidateShadow()
            var surface: NSView = self
            while let parent = surface.superview { surface = parent }
            self.caretDivider?.removeFromSuperview()
            let divider = CaretDividerView(frame: surface.bounds)
            divider.panel = self
            divider.autoresizingMask = [.width, .height]
            surface.addSubview(divider, positioned: .above, relativeTo: nil)
            self.caretDivider = divider
        }
    }
    @objc func toggleTheme() {
        lightMode.toggle(); UserDefaults.standard.set(lightMode, forKey: "lightMode")
        applyTheme(); owner?.render()
    }
    func applyTheme() {
        layer?.backgroundColor = panelBackground.cgColor
        window?.backgroundColor = panelBackground
        var ancestor = superview
        while let view = ancestor {
            if view is NSVisualEffectView { view.layer?.backgroundColor = panelBackground.cgColor }
            ancestor = view.superview
        }
        theme.title = lightMode ? "☾" : "☀"
        theme.setAccessibilityLabel(lightMode ? "Switch to dark mode" : "Switch to light mode")
        theme.toolTip = lightMode ? "Dark mode" : "Light mode"
        reviewSignature = ""; caretDivider?.needsDisplay = true
        notifications.needsDisplay = true; sortOrder.needsDisplay = true; needsDisplay = true
    }
    @objc func togglePending() {
        reviewingPending.toggle()
        reviewScroll.contentView.scroll(to: .zero)
        owner?.render()
    }
    @objc func toggleSort() {
        guard let owner = owner, !showingHistory else { return }
        owner.sortNewest.toggle()
        owner.defaults.set(owner.sortNewest, forKey: "sortNewest")
        reviewSignature = ""
        reviewScroll.contentView.scroll(to: .zero)
        owner.render()
    }
    @objc func showReview() { selectedTab = 2; owner?.render() }
    @objc func showRatio() { selectedTab = 0; owner?.render() }
    @objc func showApps() { selectedTab = 1; owner?.render() }
    @objc func toggleHistory() {
        showingHistory.toggle()
        history.title = showingHistory ? "←" : "◷"
        history.setAccessibilityLabel(showingHistory ? "Back to activity" : "Show history")
        history.toolTip = showingHistory ? "Back to activity" : "History"
        owner?.render()
    }
    func refreshApps() {
        selectedTab = 0
        ratioTab.isHidden = true; appsTab.isHidden = true
        totals.isHidden = true; context.isHidden = false
        consume.isHidden = true; create.isHidden = true
        appScroll.isHidden = true; reviewScroll.isHidden = showingHistory
        historyScroll.isHidden = !showingHistory
        reviewButton.isHidden = true; note.isHidden = true
        history.state = showingHistory ? .on : .off
        if showingHistory {
            context.stringValue = "HISTORY"
            notifications.isHidden = true; sortOrder.isHidden = true
            historyList.owner = owner
            let count = owner?.historyEntries().count ?? 0
            trackedTotal.stringValue = "\(count) DAY\(count == 1 ? "" : "S")"
            trackedTotal.frame = NSRect(x: 180, y: 277, width: 164, height: 18)
            historyList.setFrameSize(NSSize(width: 360, height: max(220, count * 44)))
            historyList.needsDisplay = true
        } else {
            notifications.isHidden = false; sortOrder.isHidden = false
            trackedTotal.frame = NSRect(x: 180, y: 277, width: 84, height: 18)
            let appTotal = (owner?.ledger.apps ?? [:]).values.reduce(0) { $0 + $1.seconds }
            trackedTotal.stringValue = owner?.duration(appTotal) ?? ""
        }
        let count = owner?.pendingSites.count ?? 0
        notifications.title = count > 0 ? "! \(count)" : "✓"
        notifications.needsAttention = count > 0
        notifications.state = reviewingPending ? .on : .off
        notifications.toolTip = count > 0 ? "\(count) app\(count == 1 ? " needs" : "s need") categorizing" : "All apps categorized"
        notifications.setAccessibilityLabel(notifications.toolTip)
        notifications.needsDisplay = true
        let newest = owner?.sortNewest ?? true
        sortOrder.title = "↑↓"
        sortOrder.toolTip = newest ? "Sorted by newest" : "Sorted by time used"
        sortOrder.setAccessibilityLabel(sortOrder.toolTip)
        sortOrder.needsDisplay = true
        let visible = (owner?.ledger.apps ?? [:]).filter { !reviewingPending || ($0.value.unclassified ?? 0) >= 1 }
        let pending = owner?.sortedUsage(visible) ?? []
        func selectedMode(_ id: String) -> String? {
            guard let owner = owner else { return nil }
            if id == owner.activeID { return owner.mode }
            return owner.rules[id] ?? owner.builtIns[id] ?? (id.hasPrefix("site:") ? owner.siteMode(String(id.dropFirst(5))) : nil)
        }
        let signature = pending.map { $0.key + ":" + (selectedMode($0.key) ?? "?") }.joined(separator: "|") + (owner?.activeID ?? "") + String(reviewingPending) + String(newest)
        if signature != reviewSignature {
            reviewSignature = signature
            reviewList.subviews.forEach { $0.removeFromSuperview() }
            if pending.isEmpty {
                let empty = NSTextField(labelWithString: reviewingPending ? "All caught up." : "Activity will appear here.")
                empty.font = interfaceFont; empty.textColor = panelText
                empty.frame = NSRect(x: 16, y: 13, width: 328, height: 18)
                reviewList.addSubview(empty)
            }
            for (i, row) in pending.enumerated() {
                let y = CGFloat(i * 44)
                let label = NSTextField(labelWithString: row.value.name)
                label.font = interfaceFont; label.textColor = selectedMode(row.key) == nil ? unclassifiedColor : panelText
                label.lineBreakMode = .byTruncatingTail
                label.frame = NSRect(x: 16, y: y + 13, width: 140, height: 18)
                reviewList.addSubview(label)
                let time = NSTextField(labelWithString: owner?.duration(row.value.seconds) ?? "")
                time.identifier = NSUserInterfaceItemIdentifier(row.key)
                time.font = interfaceFont; time.textColor = panelText; time.alignment = .right
                time.frame = NSRect(x: 156, y: y + 13, width: 108, height: 18); reviewList.addSubview(time)
                for (j, mode) in ["create", "consume"].enumerated() {
                    let button = ReviewButton(title: mode == "consume" ? "↓" : "↑", target: owner, action: #selector(AppDelegate.reviewSite(_:)))
                    button.siteID = row.key; button.mode = mode; button.font = interfaceFont
                    button.state = selectedMode(row.key) == mode ? .on : .off
                    button.hasCategory = selectedMode(row.key) != nil
                    button.isBordered = false; button.contentTintColor = .white
                    button.toolTip = mode == "create" ? "Create" : "Consume"
                    button.setAccessibilityLabel((mode == "create" ? "Create: " : "Consume: ") + row.value.name)
                    button.frame = NSRect(x: 272 + CGFloat(j * 44), y: y, width: 44, height: 44)
                    reviewList.addSubview(button)
                }
                let pixel = 1 / (window?.backingScaleFactor ?? 2)
                let line = NSView(frame: NSRect(x: 0, y: y + 44 - pixel, width: 360, height: pixel))
                line.wantsLayer = true; line.layer?.backgroundColor = gridColor.cgColor; reviewList.addSubview(line)
            }
            reviewList.setFrameSize(NSSize(width: 360, height: max(220, pending.count * 44)))
        }
        for case let time as NSTextField in reviewList.subviews {
            if let id = time.identifier?.rawValue, let usage = owner?.ledger.apps?[id] {
                let active = id == owner?.activeID && owner?.paused == false && owner?.idle == false && owner?.sleeping == false
                let text = (active ? "● " : "") + (owner?.duration(usage.seconds) ?? "")
                let value = NSMutableAttributedString(string: text, attributes: [.font: interfaceFont, .foregroundColor: panelText])
                if active {
                    value.addAttributes([.foregroundColor: createColor, .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .baselineOffset: 2], range: NSRange(location: 0, length: 1))
                }
                let alignment = NSMutableParagraphStyle(); alignment.alignment = .right
                value.addAttribute(.paragraphStyle, value: alignment, range: NSRange(location: 0, length: value.length))
                time.attributedStringValue = value
            }
        }
        ratioTab.state = selectedTab == 0 ? .on : .off; appsTab.state = selectedTab == 0 ? .off : .on
        let height = max(244, (owner?.ledger.apps?.count ?? 0) * 56)
        appList.setFrameSize(NSSize(width: 360, height: height)); appList.needsDisplay = true
        for button in [ratioTab, appsTab, consume, create, pause, history, forget, quit, theme, sortOrder] { button.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        for y: CGFloat in [44, 264, 352] { hairline(NSRect(x: 0, y: y, width: 360, height: pixel)) }
        // Dividers are inset one physical pixel into adjacent cells to remain visible.
        if !showingHistory {
            hairline(NSRect(x: 272, y: 264, width: pixel, height: 44))
            hairline(NSRect(x: 316, y: 264, width: pixel, height: 44))
        }
        guard let o = owner, selectedTab == 0 else { return }
        for y: CGFloat in [308, 352] { hairline(NSRect(x: 0, y: y, width: 360, height: pixel)) }

        let total = o.ledger.consume + o.ledger.create
        let fraction = total > 0 ? o.ledger.create / total : 0.5
        consumeColor.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 308, width: 360, height: pixel)).fill()
        createColor.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 308, width: 360 * fraction, height: pixel)).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: panelText]
        let basisPoints = total > 0 ? Int((fraction * 10000).rounded()) : 0
        let consumeValue = total > 0 ? String(format: "%.2f%%", Double(10000 - basisPoints) / 100) : "—"
        let createValue = total > 0 ? String(format: "%.2f%%", Double(basisPoints) / 100) : "—"
        let consumeText = NSMutableAttributedString(string: "↓ " + consumeValue + " CONSUMING", attributes: attrs)
        consumeText.addAttribute(.foregroundColor, value: consumeColor, range: NSRange(location: 0, length: 2 + (consumeValue as NSString).length))
        consumeText.draw(at: NSPoint(x: 196, y: 323))
        let createText = NSMutableAttributedString(string: "↑ " + createValue + " CREATING", attributes: attrs)
        createText.addAttribute(.foregroundColor, value: createColor, range: NSRange(location: 0, length: 2 + (createValue as NSString).length))
        createText.draw(at: NSPoint(x: 16, y: 323))
    }
}

struct UpdateCredential: Codable {
    let token: String
    let email: String
    static let service = "com.visualizevalue.ratio.updates"
    static func load() -> UpdateCredential? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: "device", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as [CFString: Any] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func store() -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        let key = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: "device"] as [CFString: Any]
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = key; item[kSecValueData] = data; item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

final class CodeInputView: NSView, NSTextFieldDelegate {
    var fields: [NSTextField] = []
    var onSubmit: (() -> Void)?
    var stringValue: String { fields.map { $0.stringValue }.joined() }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for index in 0..<6 {
            let field = NSTextField(frame: NSRect(x: CGFloat(index) * 42, y: 5, width: 34, height: 20))
            field.isEditable = true; field.isSelectable = true
            field.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium); field.alignment = .center
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
            field.backgroundColor = selectionBackground; field.textColor = panelText
            field.focusRingType = .none; field.delegate = self
            field.setAccessibilityLabel("Code digit \(index + 1) of 6")
            fields.append(field); addSubview(field)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        selectionBackground.setFill()
        for index in 0..<6 {
            NSRect(x: CGFloat(index) * 42, y: 0, width: 34, height: 30).fill()
        }
    }
    func clear() { fields.forEach { $0.stringValue = "" } }
    func focus() { window?.makeFirstResponder(fields[0]) }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let index = fields.firstIndex(of: field) else { return }
        let digits = field.stringValue.filter { $0 >= "0" && $0 <= "9" }
        if digits.isEmpty { field.stringValue = ""; return }
        // A full pasted code fills every slot, regardless of the current focus.
        let start = digits.count >= 6 ? 0 : index
        let characters = Array(digits.prefix(6))
        for (offset, digit) in characters.enumerated() where start + offset < 6 {
            fields[start + offset].stringValue = String(digit)
        }
        let next = min(5, start + characters.count)
        window?.makeFirstResponder(fields[next]); fields[next].selectText(nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onSubmit?(); return true }
        if selector == #selector(NSResponder.deleteBackward(_:)),
           let field = control as? NSTextField, field.stringValue.isEmpty,
           let index = fields.firstIndex(of: field), index > 0 {
            fields[index - 1].stringValue = ""; window?.makeFirstResponder(fields[index - 1]); return true
        }
        return false
    }
}

final class UpdateSignInView: NSView {
    let heading = NSTextField(labelWithString: "SIGN IN FOR UPDATES")
    let detail = NSTextField(wrappingLabelWithString: "Use the email you purchased Ratio with.")
    let input = NSTextField()
    var emailBackground: NSView!
    let codeInput = CodeInputView(frame: NSRect(x: 24, y: 175, width: 244, height: 30))
    let message = NSTextField(wrappingLabelWithString: "")
    let submit = GridButton(title: "SEND CODE", target: nil, action: nil)
    let back = GridButton(title: "LATER", target: nil, action: nil)
    var onClose: (() -> Void)?
    var onVerified: ((UpdateCredential) -> Void)?
    var challenge: String?
    var busy = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: lightMode ? .aqua : .darkAqua)
        wantsLayer = true; layer?.backgroundColor = panelBackground.cgColor
        for label in [heading, detail, message] { label.font = interfaceFont; label.textColor = panelText; addSubview(label) }
        heading.frame = NSRect(x: 24, y: 287, width: 312, height: 22)
        detail.frame = NSRect(x: 24, y: 225, width: 312, height: 44)
        emailBackground = NSView(frame: NSRect(x: 24, y: 179, width: 312, height: 26))
        emailBackground.wantsLayer = true; emailBackground.layer?.backgroundColor = selectionBackground.cgColor
        addSubview(emailBackground)
        input.isEditable = true; input.isSelectable = true
        input.isBezeled = false; input.isBordered = false; input.drawsBackground = false
        input.frame = NSRect(x: 28, y: 182, width: 304, height: 20)
        input.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular); input.textColor = panelText; input.backgroundColor = selectionBackground
        input.placeholderAttributedString = NSAttributedString(string: "Purchase email", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor(calibratedWhite: lightMode ? 0.40 : 0.62, alpha: 1)]); input.focusRingType = .none
        input.target = self; input.action = #selector(send); addSubview(input)
        codeInput.isHidden = true; codeInput.onSubmit = { [weak self] in self?.send() }; addSubview(codeInput)
        message.frame = NSRect(x: 24, y: 65, width: 312, height: 76); message.textColor = .gray
        submit.frame = NSRect(x: 0, y: 0, width: 240, height: 44); back.frame = NSRect(x: 240, y: 0, width: 120, height: 44)
        for b in [submit, back] { b.isBordered = false; b.setButtonType(.momentaryPushIn); b.target = self; addSubview(b) }
        submit.action = #selector(send); back.action = #selector(goBack)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func goBack() {
        guard !busy else { return }
        if challenge != nil {
            challenge = nil; codeInput.isHidden = true; codeInput.clear(); input.isHidden = false; emailBackground.isHidden = false
            window?.makeFirstResponder(input)
            heading.stringValue = "SIGN IN FOR UPDATES"; detail.stringValue = "Use the email you purchased Ratio with."
            input.stringValue = ""; input.placeholderAttributedString = NSAttributedString(string: "Purchase email", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor(calibratedWhite: lightMode ? 0.40 : 0.62, alpha: 1)]); submit.title = "SEND CODE"; back.title = "LATER"; message.stringValue = ""
        } else { onClose?() }
    }
    @objc func send() {
        guard !busy else { return }
        let value = challenge == nil ? input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : codeInput.stringValue
        if challenge != nil && value.range(of: "^[0-9]{6}$", options: .regularExpression) == nil { message.stringValue = "Enter the six-digit code from your email."; return }
        if challenge == nil && (value.count > 254 || value.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) == nil) { message.stringValue = "Enter your purchase email."; return }
        let verifying = challenge != nil
        let body = verifying ? ["challengeId": challenge!, "code": value] : ["email": value]
        var req = URLRequest(url: URL(string: "https://visualizevalue.com/api/ratio/auth/" + (verifying ? "verify" : "request"))!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        busy = true; submit.isEnabled = false; back.isEnabled = false; message.stringValue = verifying ? "Checking code…" : "Sending code…"
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false; self.submit.isEnabled = true; self.back.isEnabled = true
                guard error == nil, let data = data, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.message.stringValue = "Couldn’t connect. Please try again."; return
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.message.stringValue = result["error"] as? String ?? "Please try again shortly."; return
                }
                if verifying {
                    guard let token = result["token"] as? String, let email = result["email"] as? String,
                        token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { self.message.stringValue = "Please request a new code."; return }
                    let credential = UpdateCredential(token: token, email: email)
                    guard credential.store() else { self.message.stringValue = "Couldn’t save your sign-in to Keychain. Please request a new code."; return }
                    self.onVerified?(credential)
                } else {
                    guard let id = result["challengeId"] as? String else { self.message.stringValue = "Please try again."; return }
                    self.challenge = id; self.heading.stringValue = "CHECK YOUR EMAIL"
                    self.detail.stringValue = "If this email has a Ratio purchase, a six-digit code is on its way."
                    self.input.isHidden = true; self.emailBackground.isHidden = true; self.codeInput.clear(); self.codeInput.isHidden = false; self.submit.title = "VERIFY CODE"; self.back.title = "BACK"
                    self.message.stringValue = "Code expires in 10 minutes. Check spam, or go back to request another code."
                    self.codeInput.focus()
                }
            }
        }.resume()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var updaterController: SPUStandardUpdaterController!
    var updaterStarted = false
    var signInView: UpdateSignInView?
    var ledger = Ledger(day: dayKey())
    var resetUndo: ResetSnapshot?
    var resetUndoTimer: Timer?
    var history: [DaySummary] = []
    var rules: [String: String] = [:]
    var status: NSStatusItem!
    let popover = NSPopover()
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    var panel: RatioView!
    var timer: Timer?
    var activeID = ""
    var activeName = "No active app"
    var browserID: String?
    var browserName = ""
    var checkingBrowser = false
    let browsers = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser"]
    let consumeSites = ["x.com", "twitter.com", "youtube.com", "reddit.com", "instagram.com", "tiktok.com", "netflix.com"]
    let createSites = ["figma.com", "docs.google.com", "canva.com"]
    var mode: String?
    var switched = Date()
    var lastTick = Date()
    var lastPrompt = Date.distantPast
    var prompted = Set<String>()
    var paused = false
    var sleeping = false
    var idle = false
    var ticks = 0
    var activeSeconds: Double = 0
    var telemetrySeconds: Double = 0
    var telemetryEnabled = true
    var telemetryInstallID = ""
    var lastTelemetryReport = Date.distantPast
    var chromeSessionSites = Set<String>()
    var reviewWork: DispatchWorkItem?
    var sortNewest = true
    func sortedUsage(_ apps: [String: AppUsage]) -> [(key: String, value: AppUsage)] {
        apps.sorted { lhs, rhs in
            if sortNewest {
                let left = lhs.value.lastUsed ?? 0, right = rhs.value.lastUsed ?? 0
                return left == right ? lhs.value.seconds > rhs.value.seconds : left > right
            }
            if lhs.value.seconds == rhs.value.seconds {
                return (lhs.value.lastUsed ?? 0) > (rhs.value.lastUsed ?? 0)
            }
            return lhs.value.seconds > rhs.value.seconds
        }
    }
    var pendingSites: [(key: String, value: AppUsage)] {
        sortedUsage((ledger.apps ?? [:]).filter { ($0.value.unclassified ?? 0) >= 1 })
    }
    @objc func reviewSite(_ button: ReviewButton) {
        tick()
        let previous = rules[button.siteID] ?? builtIns[button.siteID] ?? (button.siteID.hasPrefix("site:") ? siteMode(String(button.siteID.dropFirst(5))) : nil)
        ledger.classifyPending(button.siteID, mode: button.mode, previousMode: previous)
        rules[button.siteID] = button.mode
        if activeID == button.siteID { mode = button.mode }
        if pendingSites.isEmpty { panel.reviewingPending = false }
        save(); render()
    }
    let defaults = UserDefaults.standard
    let builtIns: [String: String] = [
        "com.apple.dt.Xcode": "create", "com.microsoft.VSCode": "create", "com.todesktop.230313mzl4w4u92": "create",
        "com.figma.Desktop": "create", "com.adobe.Photoshop": "create", "com.adobe.Illustrator": "create",
        "com.apple.iWork.Pages": "create", "com.apple.iWork.Keynote": "create", "com.apple.iWork.Numbers": "create",
        "com.apple.FinalCut": "create", "com.apple.garageband10": "create", "com.apple.Logic10": "create",
        "com.apple.TV": "consume", "com.apple.iBooksX": "consume", "com.apple.news": "consume"
    ]
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = defaults.data(forKey: "ledger"), let saved = try? JSONDecoder().decode(Ledger.self, from: data) { ledger = saved }
        if let data = defaults.data(forKey: "history"), let saved = try? JSONDecoder().decode([DaySummary].self, from: data) { history = saved }
        rules = (defaults.dictionary(forKey: "rules") as? [String: String] ?? [:]).filter { $0.value != "neutral" }
        sortNewest = defaults.object(forKey: "sortNewest") as? Bool ?? true
        telemetrySeconds = defaults.double(forKey: "anonymousTrackedSeconds")
        telemetryEnabled = defaults.object(forKey: "anonymousTotalsEnabled") == nil || defaults.bool(forKey: "anonymousTotalsEnabled")
        telemetryInstallID = defaults.string(forKey: "anonymousInstallID") ?? UUID().uuidString.lowercased()
        defaults.set(telemetryInstallID, forKey: "anonymousInstallID")
        // Migrate existing per-app history to explicit category contributions.
        if let history = ledger.apps, history.values.contains(where: { $0.createSeconds == nil || $0.consumeSeconds == nil }) {
            let attributed = history.values.reduce(0) { $0 + max(0, $1.seconds - ($1.unclassified ?? 0)) }
            let legacy = max(0, ledger.create + ledger.consume - attributed)
            let fraction = ledger.create + ledger.consume > 0 ? ledger.create / (ledger.create + ledger.consume) : 0
            ledger.create = legacy * fraction; ledger.consume = legacy * (1 - fraction)
            for (id, var usage) in history {
                let category = rules[id] ?? builtIns[id] ?? (id.hasPrefix("site:") ? siteMode(String(id.dropFirst(5))) : nil)
                let classified = max(0, usage.seconds - (usage.unclassified ?? 0))
                usage.createSeconds = usage.createSeconds ?? (category == "create" ? classified : 0)
                usage.consumeSeconds = usage.consumeSeconds ?? (category == "consume" ? classified : 0)
                ledger.create += usage.createSeconds ?? 0
                ledger.consume += usage.consumeSeconds ?? 0
                ledger.apps?[id] = usage
            }
        }

        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        if let credential = UpdateCredential.load() {
            updaterController.updater.httpHeaders = ["Authorization": "Bearer " + credential.token]
            do {
                try updaterController.updater.start(); updaterStarted = true
                enableAutomaticUpdates()
            } catch { NSLog("Ratio updater could not start") }
        }
        rollover()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self; status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status.button?.font = interfaceFont
        let controller = NSViewController()
        panel = RatioView(frame: NSRect(x: 0, y: 0, width: 360, height: 352)); panel.owner = self
        for button in [panel.consume, panel.create, panel.pause, panel.forget] { button.target = self }
        controller.view = panel; popover.contentViewController = controller; popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self = self, self.popover.isShown else { return event }
            if event.window !== self.panel.window && event.window !== self.status.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(activated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(sleepNow), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(sleepNow), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(wakeNow), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(wakeNow), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        updateApp(NSWorkspace.shared.frontmostApplication)
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        panel.applyTheme(); render(); showPopover(); checkBrowser()
        reportTelemetry()
        if UpdateCredential.load() == nil { showUpdateSignIn() }
    }
    func rollover() {
        let today = dayKey()
        if ledger.day != today {
            if ledger.create + ledger.consume > 0 {
                history.removeAll { $0.day == ledger.day }
                history.append(DaySummary(day: ledger.day, create: ledger.create, consume: ledger.consume))
                history = Array(history.sorted { $0.day > $1.day }.prefix(30))
            }
            ledger = Ledger(day: today); save()
        }
    }
    func save() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: "ledger") }
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "history") }
        defaults.set(rules, forKey: "rules")
        defaults.set(telemetrySeconds, forKey: "anonymousTrackedSeconds")
    }
    func historyEntries() -> [DaySummary] {
        var entries = history.filter { $0.day != ledger.day }
        if ledger.create + ledger.consume > 0 { entries.append(DaySummary(day: ledger.day, create: ledger.create, consume: ledger.consume)) }
        return Array(entries.sorted { $0.day > $1.day }.prefix(30))
    }
    func shortDay(_ value: String) -> String {
        let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: value) else { return value }
        let output = DateFormatter(); output.locale = Locale(identifier: "en_US_POSIX"); output.dateFormat = value == dayKey() ? "'TODAY'" : "MMM d"
        return output.string(from: date).uppercased()
    }
    func tick() {
        let now = Date(); let elapsed = now.timeIntervalSince(lastTick); lastTick = now
        let oldDay = ledger.day; rollover()
        idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) >= 60
        if !paused && !sleeping && !idle && oldDay == ledger.day {
            ledger.record(elapsed, mode: mode, appID: activeID, appName: activeName)
            if browserID == "com.google.Chrome" && activeID.hasPrefix("site:") && mode == nil { chromeSessionSites.insert(activeID) }
            if elapsed > 0 && elapsed <= 3 && !activeID.isEmpty {
                activeSeconds += elapsed; telemetrySeconds += elapsed
            }
        }
        ticks += 1; if ticks % 10 == 0 { save() }
        if ticks % 900 == 0 { reportTelemetry() }
        if ticks % 3 == 0 && !sleeping && !paused { checkBrowser() }
        render()
    }
    @objc func activated(_ n: Notification) {
        guard let next = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              next.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        tick()
        updateApp(next)
        render(); checkBrowser()
    }
    func updateApp(_ app: NSRunningApplication?) {
        guard let app = app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        activeSeconds = 0
        activeID = app.bundleIdentifier ?? "process:\(app.localizedName ?? "unknown")"
        activeName = app.localizedName ?? "Unknown app"
        browserID = browsers.contains(activeID) ? activeID : nil
        browserName = activeName
        mode = rules[activeID] ?? builtIns[activeID]; switched = Date(); lastTick = Date()
    }
    func siteMode(_ host: String) -> String? {
        if consumeSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return "consume" }
        if createSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return "create" }
        return nil
    }
    func checkBrowser() {
        guard let id = browserID, !checkingBrowser else { return }
        checkingBrowser = true
        // Read only the active tab URL. Store the hostname, never paths or queries.
        let command = id == "com.apple.Safari" ? "get URL of current tab of front window" : "get URL of active tab of front window"
        let source = "tell application id \"" + id + "\" to " + command
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var error: NSDictionary?
            let value = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            let host = value.flatMap { URL(string: $0)?.host?.lowercased() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingBrowser = false
                guard self.browserID == id else { return }
                let key = host.map { "site:" + $0 } ?? id
                guard key != self.activeID else { return }
                // Settle the previous context before applying the new website.
                self.tick()
                self.activeSeconds = 0
                self.activeID = key
                self.activeName = host ?? self.browserName
                self.mode = self.rules[key] ?? host.flatMap { self.siteMode($0) }
                self.switched = Date(); self.lastTick = Date(); self.render()
            }
        }
    }
    @objc func sleepNow() { tick(); sleeping = true; save(); render() }
    @objc func wakeNow() { sleeping = false; lastTick = Date(); updateApp(NSWorkspace.shared.frontmostApplication); render() }
    @objc func chooseConsume() { choose("consume") }
    @objc func chooseCreate() { choose("create") }
    func choose(_ value: String) {
        guard !activeID.isEmpty else { return }
        tick(); mode = value; rules[activeID] = value; save(); render()
    }
    @objc func resetAll() {
        if let snapshot = resetUndo {
            resetUndoTimer?.invalidate(); resetUndoTimer = nil
            ledger = snapshot.ledger; rules = snapshot.rules; activeSeconds = snapshot.activeSeconds
            paused = snapshot.paused; prompted = snapshot.prompted; chromeSessionSites = snapshot.chromeSessionSites
            mode = snapshot.mode; resetUndo = nil; lastTick = Date(); save(); render(); return
        }
        tick()
        resetUndo = ResetSnapshot(ledger: ledger, rules: rules, activeSeconds: activeSeconds, paused: paused, prompted: prompted, chromeSessionSites: chromeSessionSites, mode: mode)
        resetUndoTimer?.invalidate()
        resetUndoTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            self?.resetUndo = nil; self?.panel.forget.title = "RESET"; self?.panel.forget.needsDisplay = true
        }
        ledger = Ledger(day: dayKey())
        rules = [:]; activeSeconds = 0; paused = false
        prompted.removeAll(); chromeSessionSites.removeAll()
        panel.reviewingPending = false
        mode = builtIns[activeID] ?? (activeID.hasPrefix("site:") ? siteMode(String(activeID.dropFirst(5))) : nil)
        lastTick = Date(); save(); render()
    }
    @objc func forgetApp() { tick(); rules.removeValue(forKey: activeID); mode = nil; prompted.insert(activeID); save(); render() }
    @objc func togglePause() { tick(); paused.toggle(); lastTick = Date(); save(); render() }
    @objc func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            item.target = self; menu.addItem(item)
            let account = NSMenuItem(title: UpdateCredential.load() == nil ? "Sign In for Updates…" : "Update Account…", action: #selector(updateAccount), keyEquivalent: "")
            account.target = self; menu.addItem(account)
            let telemetry = NSMenuItem(title: "Share Anonymous Total", action: #selector(toggleTelemetry), keyEquivalent: "")
            telemetry.target = self; telemetry.state = telemetryEnabled ? .on : .off; menu.addItem(telemetry)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit Ratio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp; menu.addItem(quit)
            if let button = status.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
        } else { togglePopover() }
    }
    @objc func checkForUpdates() {
        save()
        guard UpdateCredential.load() != nil else { showUpdateSignIn(); return }
        updaterController.checkForUpdates(nil)
    }
    @objc func updateAccount() { showUpdateSignIn() }
    @objc func toggleTelemetry() {
        telemetryEnabled.toggle(); defaults.set(telemetryEnabled, forKey: "anonymousTotalsEnabled")
        if telemetryEnabled { reportTelemetry() }
    }
    func reportTelemetry() {
        guard telemetryEnabled, !telemetryInstallID.isEmpty,
              Date().timeIntervalSince(lastTelemetryReport) >= 60,
              let credential = UpdateCredential.load() else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let body: [String: Any] = ["install": telemetryInstallID, "totalSeconds": Int(telemetrySeconds), "version": version]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "https://visualizevalue.com/api/ratio/telemetry") else { return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization"); request.httpBody = data
        lastTelemetryReport = Date()
        URLSession.shared.dataTask(with: request).resume()
    }
    func enableAutomaticUpdates() {
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = true
    }
    func showUpdateSignIn() {
        showPopover()
        if signInView == nil {
            let view = UpdateSignInView(frame: panel.bounds)
            view.onClose = { [weak self] in self?.signInView?.removeFromSuperview(); self?.signInView = nil }
            view.onVerified = { [weak self] credential in
                guard let self = self else { return }
                self.updaterController.updater.httpHeaders = ["Authorization": "Bearer " + credential.token]
                if !self.updaterStarted {
                    do { try self.updaterController.updater.start(); self.updaterStarted = true } catch { return }
                }
                self.enableAutomaticUpdates()
                self.signInView?.removeFromSuperview(); self.signInView = nil
                self.popover.performClose(nil)
                self.updaterController.checkForUpdates(nil)
            }
            panel.addSubview(view, positioned: .above, relativeTo: nil); signInView = view
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.window?.makeKey(); panel.window?.makeFirstResponder(signInView?.input)
    }
    @objc func togglePopover() { if popover.isShown { popover.performClose(nil) } else { showPopover() } }
    func showPopover() {
        guard let button = status.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    func render() {
        panel.selectedTab = 0
        let total = ledger.consume + ledger.create
        let c = total > 0 ? Int((ledger.create / total * 100).rounded()) : 0
        let ratioText = total > 0 ? "\(c) / \(100 - c)" : "— / —"
        let styledRatio = NSMutableAttributedString(string: ratioText, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 48, weight: .regular), .foregroundColor: panelText])
        if let slash = ratioText.range(of: "/ ") {
            let range = NSRange(slash.upperBound..<ratioText.endIndex, in: ratioText)
            styledRatio.addAttribute(.foregroundColor, value: NSColor.darkGray, range: range)
        }
        let alignment = NSMutableParagraphStyle(); alignment.alignment = .center
        styledRatio.addAttribute(.paragraphStyle, value: alignment, range: NSRange(location: 0, length: styledRatio.length))
        panel.totals.attributedStringValue = styledRatio
        let state = paused ? "PAUSED" : sleeping || idle ? "AWAY" : mode == "create" ? "CREATING" : mode == "consume" ? "CONSUMING" : "UNCLASSIFIED"
        panel.title.stringValue = "CREATE:CONSUME"
        let tracking = !paused && !sleeping && !idle
        let liveStatus = tracking ? "TRACKING" : state
        panel.context.stringValue = liveStatus
        panel.note.stringValue = paused ? "Tracking paused. Click Resume to count." : sleeping || idle ? "Away · counting resumes with activity." : mode == nil ? "App time is counting. Choose a mode to include it in your ratio." : state + " · time updates every second.\nClick a mode to correct it."
        panel.pause.title = paused ? "▶" : "Ⅱ"
        panel.forget.title = resetUndo == nil ? "RESET" : "UNDO"
        panel.pause.setAccessibilityLabel(paused ? "Resume tracking" : "Pause tracking")
        panel.pause.toolTip = paused ? "Resume tracking" : "Pause tracking"
        panel.consume.state = mode == "consume" ? .on : .off; panel.create.state = mode == "create" ? .on : .off
        let symbol = paused || idle || sleeping ? "Ⅱ" : mode == "create" ? "↑" : mode == "consume" ? "↓" : "?"
        let statusTitle = total > 0 ? "\(symbol) \(c)/\(100-c)" : "\(symbol) Ratio"
        let statusColor: NSColor = !tracking ? .labelColor : mode == nil ? unclassifiedColor : mode == "create" ? createColor : consumeColor
        status.button?.attributedTitle = NSAttributedString(string: statusTitle, attributes: [.font: interfaceFont, .foregroundColor: statusColor])
        status.button?.toolTip = "Ratio · \(state.lowercased()) · \(activeName)"
        if panel.showingApps {
            let appTotal = (ledger.apps ?? [:]).values.reduce(0) { $0 + $1.seconds }
            panel.title.stringValue = (tracking ? "TRACKING · " : state + " · ") + duration(appTotal) + " TODAY"
            panel.note.stringValue = "App + website time. Includes unclassified use. Pauses after 60s idle."
        }
        if panel.selectedTab == 2 {
            panel.title.stringValue = "CATEGORIZE / ACTIVITY"
            panel.note.stringValue = "Applies to today's uncategorized time.\nUse Ratio or Apps to review later."
        }
        if panel.reviewingPending { panel.context.stringValue = "TO CATEGORIZE" }
        panel.refreshApps()
        panel.needsDisplay = true
    }
    func applicationWillTerminate(_ notification: Notification) { save(); reportTelemetry() }
}

if CommandLine.arguments.contains("--preview") {
    _ = NSApplication.shared
    let owner = AppDelegate()
    owner.ledger = Ledger(day: dayKey(), consume: 3600, create: 1200)
    owner.history = [DaySummary(day: "2026-09-14", create: 61, consume: 39), DaySummary(day: "2026-09-13", create: 74, consume: 26), DaySummary(day: "2026-09-12", create: 48, consume: 52)]
    owner.ledger.apps = ["site:x.com": AppUsage(name: "x.com", seconds: 3600), "editor": AppUsage(name: "Xcode", seconds: 1200)]
    owner.activeName = "x.com"; owner.activeID = "site:x.com"; owner.mode = "consume"
    owner.status = NSStatusBar.system.statusItem(withLength: 0)
    let view = RatioView(frame: NSRect(x: 0, y: 0, width: 360, height: 352))
    owner.panel = view; view.owner = owner
    let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    owner.ledger.apps?["site:example.org"] = AppUsage(name: "example.org", seconds: 123, unclassified: 123)
    for tab in 0...2 {
        view.showingHistory = tab == 2; view.selectedTab = tab; owner.render(); view.display()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments.last! + "/ratio-preview-\(tab).png"))
    }
} else if CommandLine.arguments.contains("--self-test") {
    let classifier = AppDelegate()
    precondition(classifier.siteMode("x.com") == "consume")
    precondition(classifier.siteMode("www.youtube.com") == "consume")
    precondition(classifier.siteMode("docs.google.com") == "create")
    precondition(classifier.siteMode("notx.com") == nil)
    precondition(classifier.siteMode("x.com.example.org") == nil)
    print("PASS: website classification and hostname boundaries")
    let sorter = AppDelegate()
    sorter.ledger.apps = [
        "old-long": AppUsage(name: "Xcode", seconds: 50, lastUsed: 1),
        "new-short": AppUsage(name: "Calendar", seconds: 2, lastUsed: 3),
        "mid": AppUsage(name: "Safari", seconds: 20, lastUsed: 2)
    ]
    sorter.sortNewest = true
    precondition(sorter.sortedUsage(sorter.ledger.apps ?? [:]).map(\.key) == ["new-short", "mid", "old-long"])
    sorter.sortNewest = false
    precondition(sorter.sortedUsage(sorter.ledger.apps ?? [:]).map(\.key) == ["old-long", "mid", "new-short"])
    print("PASS: app list sort newest vs most used")
    var l = Ledger(day: "test")
    l.record(2, mode: "create"); l.record(1, mode: "consume"); l.record(2, mode: nil)
    l.record(100, mode: "create"); l.record(-1, mode: "consume")
    precondition(l.create == 2 && l.consume == 1, "Accounting must exclude gaps and unknown time")
    let data = try! JSONEncoder().encode(l)
    let restored = try! JSONDecoder().decode(Ledger.self, from: data)
    precondition(restored.create == 2 && restored.day == "test")
    let legacy = try! JSONDecoder().decode(Ledger.self, from: Data("{\"day\":\"test\",\"consume\":7,\"create\":9}".utf8))
    precondition(legacy.consume == 7 && legacy.create == 9 && legacy.apps == nil)
    var usage = legacy
    usage.record(2, mode: nil, appID: "browser", appName: "Browser")
    usage.record(1, mode: "create", appID: "editor", appName: "Editor")
    usage.record(100, mode: "create", appID: "editor", appName: "Editor")
    precondition(usage.apps?["browser"]?.seconds == 2 && usage.apps?["editor"]?.seconds == 1)
    precondition(usage.consume == 7 && usage.create == 10)
    let usageSaved = try! JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(usage))
    precondition(usageSaved.apps?["browser"]?.name == "Browser")
    precondition(Ledger(day: "tomorrow").apps?.isEmpty == true)
    usage.classifyPending("browser", mode: "consume")
    precondition(usage.consume == 9 && usage.apps?["browser"]?.unclassified == 0)
    usage.classifyPending("browser", mode: "consume")
    precondition(usage.consume == 9, "Review must not double count")
    print("PASS: retrospective categorization and duplicate review protection")
    print("PASS: app attribution, legacy migration, daily reset, app persistence")
    var reclassified = Ledger(day: "test")
    reclassified.record(3, mode: "create", appID: "editor", appName: "Editor")
    reclassified.record(2, mode: "consume", appID: "social", appName: "Social")
    reclassified.classifyPending("social", mode: "create")
    precondition(reclassified.create == 5 && reclassified.consume == 0)
    reclassified.classifyPending("editor", mode: "consume")
    reclassified.classifyPending("social", mode: "consume")
    precondition(reclassified.create == 0 && reclassified.consume == 5)
    reclassified.classifyPending("social", mode: "consume")
    precondition(reclassified.consume == 5)
    reclassified.classifyPending("social", mode: "neutral")
    precondition(reclassified.create == 0 && reclassified.consume == 3)
    reclassified.record(2, mode: "neutral", appID: "social", appName: "Social")
    precondition(reclassified.create == 0 && reclassified.consume == 3 && reclassified.apps?["social"]?.seconds == 4)
    reclassified.classifyPending("social", mode: "consume")
    precondition(reclassified.consume == 7)
    let roundtrip = try! JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(reclassified))
    precondition(roundtrip.apps?["social"]?.consumeSeconds == 4)
    print("PASS: recategorization moves all app time, neutral exclusion, idempotency and persistence")
    print("PASS: classified time, unknown exclusion, suspension gaps, persistence")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate
    app.setActivationPolicy(.accessory); app.run()
}
