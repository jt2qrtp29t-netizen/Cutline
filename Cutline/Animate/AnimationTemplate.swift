import Foundation

/// The ready-made animations (Animate tab, Templates): each is drawn by Cutline's own
/// Manim program from these settings, handed over as data.
nonisolated enum AnimationTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case title, lowerThird, scoreBug, counter, quote, equation, countdown, callToAction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "Title"
        case .lowerThird: "Lower Third"
        case .scoreBug: "Score Bug"
        case .counter: "Counter"
        case .quote: "Quote"
        case .equation: "Equation"
        case .countdown: "Countdown"
        case .callToAction: "Call to Action"
        }
    }

    var symbolName: String {
        switch self {
        case .title: "textformat.size"
        case .lowerThird: "rectangle.bottomthird.inset.filled"
        case .scoreBug: "sportscourt"
        case .counter: "number"
        case .quote: "quote.opening"
        case .equation: "function"
        case .countdown: "timer"
        case .callToAction: "hand.tap"
        }
    }

    /// What each text field is for in this template (nil: not used).
    var labels: (text: String, secondary: String?, extra: String?) {
        switch self {
        case .title: ("Title", "Subtitle", nil)
        case .lowerThird: ("Name", "Role", nil)
        case .scoreBug: ("Home", "Away", "Score")
        case .counter: ("Label", nil, nil)
        case .quote: ("Quote", "Who said it", nil)
        case .equation: ("LaTeX", nil, nil)
        case .countdown: ("Last word", nil, nil)
        case .callToAction: ("Button", "Line under it", nil)
        }
    }

    /// Settings that look right for the template out of the box.
    var defaults: AnimationSettings {
        var s = AnimationSettings(template: self)
        switch self {
        case .title:
            s.text = "GOAL!"; s.secondary = ""; s.size = 160; s.animationIn = .pop; s.during = .pulse
        case .lowerThird:
            s.text = "Your Name"; s.secondary = "Commentator"; s.size = 64; s.x = 0.3; s.y = 0.84
            s.panel = true; s.animationIn = .slideRight; s.animationOut = .slideLeft; s.letterDelay = 0
        case .scoreBug:
            s.text = "HOME"; s.secondary = "AWAY"; s.extra = "2 – 1"; s.size = 56; s.x = 0.2; s.y = 0.1
            s.panel = true; s.animationIn = .slideDown; s.animationOut = .fade; s.hold = 4
        case .counter:
            s.text = "Goals"; s.size = 120; s.countFrom = 0; s.countTo = 25; s.animationIn = .fade
        case .quote:
            s.text = "Football is a simple game."; s.secondary = "Johan Cruyff"; s.size = 72; s.italic = true
            s.animationIn = .fade; s.letterDelay = 0.3
        case .equation:
            s.text = #"e^{i\pi} + 1 = 0"#; s.size = 140; s.animationIn = .write
        case .countdown:
            s.text = "GO!"; s.size = 220; s.countdownFrom = 3; s.animationIn = .pop; s.animationOut = .fade
        case .callToAction:
            s.text = "SUBSCRIBE"; s.secondary = ""; s.size = 84; s.panel = true
            s.panelColor = RGBAColor(red: 0.85, green: 0.1, blue: 0.12, alpha: 1); s.panelOpacity = 1
            s.animationIn = .pop; s.during = .pulse; s.y = 0.78
        }
        return s
    }
}

/// How a template's text arrives, behaves while it's on screen, and leaves.
nonisolated enum AnimationIn: String, Codable, CaseIterable, Identifiable, Sendable {
    case write, typewriter, fade, slideRight, slideLeft, slideUp, slideDown, grow, pop, spin, draw
    var id: String { rawValue }
    var title: String {
        switch self {
        case .write: "Write"
        case .typewriter: "Typewriter"
        case .fade: "Fade"
        case .slideRight: "Slide from Left"
        case .slideLeft: "Slide from Right"
        case .slideUp: "Slide Up"
        case .slideDown: "Slide Down"
        case .grow: "Grow"
        case .pop: "Pop"
        case .spin: "Spin"
        case .draw: "Draw Outline, Then Fill"
        }
    }
}

nonisolated enum AnimationDuring: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, pulse, wiggle, wave, flash
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Nothing"
        case .pulse: "Pulse"
        case .wiggle: "Wiggle"
        case .wave: "Wave"
        case .flash: "Flash Color"
        }
    }
}

nonisolated enum AnimationOut: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, fade, slideLeft, slideRight, slideUp, slideDown, shrink, unwrite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Stay"
        case .fade: "Fade"
        case .slideLeft: "Slide Left"
        case .slideRight: "Slide Right"
        case .slideUp: "Slide Up"
        case .slideDown: "Slide Down"
        case .shrink: "Shrink"
        case .unwrite: "Unwrite"
        }
    }
}

/// Everything a template animation is made from.
nonisolated struct AnimationSettings: Codable, Hashable, Sendable {
    var template: AnimationTemplate
    var text = "Title"
    var secondary = ""
    var extra = ""
    /// PostScript name of the typeface (like the rest of Cutline's text).
    var fontName = "Helvetica-Bold"
    var italic = false
    var color = RGBAColor.white
    /// A second color for a gradient across the text, if set.
    var gradient: RGBAColor?
    /// Outline in pixels at 1080p (0: none).
    var outlineWidth: Double = 4
    var outlineColor = RGBAColor.black
    var panel = false
    var panelColor = RGBAColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
    var panelOpacity = 0.75
    /// Font size in pixels at 1080p, like captions and text clips.
    var size: Double = 120
    /// Where its center sits on the frame, 0…1 (top left is 0, 0).
    var x = 0.5
    var y = 0.5
    var animationIn = AnimationIn.write
    var during = AnimationDuring.none
    var animationOut = AnimationOut.fade
    /// Seconds.
    var inTime = 0.8
    var hold = 2.0
    var outTime = 0.5
    /// Stagger between letters, 0 (all together) … 1 (one after another).
    var letterDelay = 0.2
    var countFrom = 0.0
    var countTo = 100.0
    var decimals = 0
    var countdownFrom = 3

    init(template: AnimationTemplate) { self.template = template }

    /// How long the animation lasts: in, hold, out (a countdown adds a second per number).
    var duration: Double {
        let base = inTime + hold + (animationOut == .none ? 0 : outTime)
        return template == .countdown ? base + Double(max(countdownFrom, 0)) : base
    }

    static let sizeRange = 16.0...400.0
    static let timeRange = 0.1...10.0
}

extension AnimationSettings {
    /// The settings as the template program reads them (plain values: family and weight
    /// for Pango, colors as hex).
    func parameters(family: String, weight: String) -> [String: String] {
        func hex(_ c: RGBAColor) -> String {
            String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
        }
        let values: [String: Any] = [
            "template": template.rawValue, "text": text, "secondary": secondary, "extra": extra,
            "family": family, "weight": weight, "italic": italic,
            "color": hex(color), "gradient": gradient.map(hex) ?? "", "outlineWidth": outlineWidth, "outlineColor": hex(outlineColor),
            "panel": panel, "panelColor": hex(panelColor), "panelOpacity": panelOpacity,
            "size": size, "x": x, "y": y,
            "in": animationIn.rawValue, "during": during.rawValue, "out": animationOut.rawValue,
            "inTime": inTime, "hold": hold, "outTime": outTime, "lag": letterDelay,
            "countFrom": countFrom, "countTo": countTo, "decimals": decimals, "countdownFrom": countdownFrom,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ["settings": json]
    }
}
