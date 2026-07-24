//
//  RemoteView.swift
//  HyperVibe (settings UI — Layout tab)
//
//  A drawn 3rd-gen aluminum Siri Remote in pure SwiftUI. Reusable: bind `highlightedKey`
//  to a control-identifier string (e.g. "button.back", "ring.up", "touch", "select") and the
//  matching element draws a blue focus ring. Geometry mirrors the approved mockup at a 150×512
//  canvas (aspect ~1:3.4): buttons clustered up top, a large blank aluminum area below.
//

import SwiftUI

// MARK: - Color hex helper (shared with LayoutView; defined once here)

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Physical remote colors (fixed — a remote is silver / near-black in both light and dark UI).
enum RemotePalette {
    static let aluHi   = Color(hex: 0xF3F4F6)
    static let alu     = Color(hex: 0xE4E6EA)
    static let aluLo   = Color(hex: 0xCFD2D8)
    static let aluEdge = Color(hex: 0xB4B9C0)
    static let btnHi   = Color(hex: 0x3A3B40)
    static let btn     = Color(hex: 0x2A2B2F)
    static let btnLo   = Color(hex: 0x1B1C20)
    static let padHi   = Color(hex: 0x1A1B1E)
    static let pad     = Color(hex: 0x0E0F11)
    static let glyph   = Color(hex: 0xB7BBC2)
    static let mic     = Color(hex: 0x9298A0)
    static let power   = Color(hex: 0x7A808A)
    static let btnEdge = Color(hex: 0x0E0F12)
}

// MARK: - Focus ring

private struct FocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    let lit: Bool
    func body(content: Content) -> some View {
        content.overlay {
            if lit {
                shape.stroke(Color.accentColor, lineWidth: 3)
                    .padding(-3)   // like CSS outline-offset: ring sits just outside the element
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 4)
            }
        }
    }
}

private extension View {
    func focusRing<S: InsettableShape>(_ shape: S, lit: Bool) -> some View {
        modifier(FocusRing(shape: shape, lit: lit))
    }
    /// Make an element clickable: tapping it reports its control-identifier `key` (bidirectional
    /// selection — click a remote button to jump to its row in the editor).
    func selectable(_ key: String, _ onSelect: ((String) -> Void)?) -> some View {
        contentShape(Rectangle()).onTapGesture { onSelect?(key) }
    }
}

// MARK: - Remote

struct RemoteView: View {
    @Binding var highlightedKey: String?
    /// Optional: tapping a remote element reports its control-identifier (for bidirectional select).
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        ZStack {
            bodyShape
            micPinhole
            powerButton
            siriNub
            clickpad

            // Face buttons — LEFT column: Back, Play/Pause, Mute; RIGHT column: TV, then Volume pill.
            Group {
                FaceButton(systemName: "chevron.backward", key: "button.menu",
                           iconSize: 15, weight: .semibold, highlightedKey: highlightedKey, onSelect: onSelect)
                    .position(x: 40.5, y: 199)
                FaceButton(systemName: "tv", key: "button.tv",
                           iconSize: 16, highlightedKey: highlightedKey, onSelect: onSelect)
                    .position(x: 109.5, y: 199)
                FaceButton(systemName: "playpause", key: "button.playPause",
                           iconSize: 15, highlightedKey: highlightedKey, onSelect: onSelect)
                    .position(x: 40.5, y: 265)
                FaceButton(systemName: "speaker.slash", key: "button.mute",
                           iconSize: 14, highlightedKey: highlightedKey, onSelect: onSelect)
                    .position(x: 40.5, y: 331)
                volumePill
                    .position(x: 109.5, y: 298)
            }
        }
        .frame(width: 150, height: 512)
    }

    // MARK: Body

    private var bodyShape: some View {
        let r = RoundedRectangle(cornerRadius: 34, style: .continuous)
        return r
            .fill(LinearGradient(gradient: Gradient(stops: [
                    .init(color: RemotePalette.aluHi, location: 0),
                    .init(color: RemotePalette.alu,   location: 0.44),
                    .init(color: RemotePalette.aluLo, location: 1)]),
                startPoint: UnitPoint(x: 0.35, y: 0), endPoint: UnitPoint(x: 0.65, y: 1)))
            .overlay(   // inner shadow toward the bottom
                r.fill(LinearGradient(colors: [.clear, Color(hex: 0x78808C, opacity: 0.24)],
                                      startPoint: .center, endPoint: .bottom)))
            .overlay(r.stroke(RemotePalette.aluEdge, lineWidth: 1))
            .overlay(   // subtle inner top highlight
                r.stroke(Color.white.opacity(0.6), lineWidth: 1)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
            .shadow(color: Color(hex: 0x1C222C, opacity: 0.22), radius: 20, y: 16)
    }

    // MARK: Top details

    private var micPinhole: some View {
        Image(systemName: "mic")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(RemotePalette.mic)
            .position(x: 75, y: 22)
    }

    private var powerButton: some View {
        Image(systemName: "power")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(RemotePalette.power)
            .frame(width: 19, height: 19)
            .focusRing(Circle(), lit: highlightedKey == "button.power")
            .selectable("button.power", onSelect)
            .position(x: 124.5, y: 29.5)
    }

    private var siriNub: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LinearGradient(colors: [RemotePalette.aluLo, RemotePalette.aluEdge],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 6, height: 62)
            .shadow(color: .black.opacity(0.16), radius: 1, x: 1)
            .focusRing(RoundedRectangle(cornerRadius: 3), lit: highlightedKey == "button.siri")
            .selectable("button.siri", onSelect)
            .position(x: 149, y: 181)
    }

    // MARK: Clickpad

    private var clickpad: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(gradient: Gradient(colors: [RemotePalette.padHi, RemotePalette.pad]),
                                     center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 90))
                .overlay(Circle().stroke(Color(hex: 0x060607), lineWidth: 1))
                .focusRing(Circle(), lit: highlightedKey == "touch")
                .selectable("touch", onSelect)

            Circle().stroke(Color.white.opacity(0.045), lineWidth: 1).padding(20)   // faint inner ring

            // Four touch dots at the diagonals.
            Group {
                touchDot.position(x: 35.5, y: 23.5)
                touchDot.position(x: 86.5, y: 23.5)
                touchDot.position(x: 35.5, y: 98.5)
                touchDot.position(x: 86.5, y: 98.5)
            }

            // Four faint direction glyphs near the edges (the ring hotspots).
            dirGlyph("▲", "ring.up").position(x: 61, y: 14)
            dirGlyph("▼", "ring.down").position(x: 61, y: 108)
            dirGlyph("◀", "ring.left").position(x: 14, y: 61)
            dirGlyph("▶", "ring.right").position(x: 108, y: 61)

            // Darker center circle = select (center click).
            Circle()
                .fill(RadialGradient(gradient: Gradient(colors: [Color(hex: 0x191A1D), Color(hex: 0x0F1012)]),
                                     center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 30))
                .overlay(Circle().stroke(Color.white.opacity(0.04), lineWidth: 1))
                .frame(width: 52, height: 52)
                .focusRing(Circle(), lit: highlightedKey == "select")
                .selectable("select", onSelect)
        }
        .frame(width: 122, height: 122)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 3)
        .position(x: 75, y: 97)
    }

    private var touchDot: some View {
        Circle().fill(Color.white.opacity(0.3)).frame(width: 3, height: 3)
    }

    private func dirGlyph(_ ch: String, _ key: String) -> some View {
        Text(ch)
            .font(.system(size: 9))
            .foregroundStyle(RemotePalette.glyph.opacity(0.55))
            .frame(width: 22, height: 22)   // slightly larger tap target than the glyph
            .focusRing(Circle(), lit: highlightedKey == key)
            .selectable(key, onSelect)
    }

    // MARK: Volume pill

    private var volumePill: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(LinearGradient(gradient: Gradient(stops: [
                        .init(color: RemotePalette.btnHi, location: 0),
                        .init(color: RemotePalette.btn,   location: 0.5),
                        .init(color: RemotePalette.btnLo, location: 1)]),
                    startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 23).stroke(RemotePalette.btnEdge, lineWidth: 1))

            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)   // divider

            Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RemotePalette.glyph)
                .frame(width: 46, height: 56).offset(y: -28)
                .focusRing(RoundedRectangle(cornerRadius: 20), lit: highlightedKey == "button.volumeUp")
                .selectable("button.volumeUp", onSelect)
            Image(systemName: "minus").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RemotePalette.glyph)
                .frame(width: 46, height: 56).offset(y: 28)
                .focusRing(RoundedRectangle(cornerRadius: 20), lit: highlightedKey == "button.volumeDown")
                .selectable("button.volumeDown", onSelect)
        }
        .frame(width: 46, height: 112)
        .shadow(color: .black.opacity(0.22), radius: 2, y: 2)
    }
}

// MARK: - Face button

private struct FaceButton: View {
    let systemName: String
    let key: String
    var iconSize: CGFloat = 16
    var weight: Font.Weight = .medium
    let highlightedKey: String?
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        Circle()
            .fill(RadialGradient(gradient: Gradient(colors: [RemotePalette.btnHi, RemotePalette.btn, RemotePalette.btnLo]),
                                 center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0, endRadius: 30))
            .overlay(Circle().stroke(RemotePalette.btnEdge, lineWidth: 1))
            .overlay(Image(systemName: systemName)
                        .font(.system(size: iconSize, weight: weight))
                        .foregroundStyle(RemotePalette.glyph))
            .frame(width: 46, height: 46)
            .shadow(color: .black.opacity(0.22), radius: 2, y: 2)
            .focusRing(Circle(), lit: highlightedKey == key)
            .selectable(key, onSelect)
    }
}
