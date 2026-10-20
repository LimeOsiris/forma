import AppKit
import FormaCore
import SwiftUI

/// Callbacks from the wheel to its controller.
@MainActor
struct RadialMenuActions {
    var select: (Int) -> Void
    var dismiss: () -> Void
    var cancelWork: () -> Void
    var confirmOptions: () -> Void
    var cancelOptions: () -> Void
    var done: (DoneChoice) -> Void

    enum DoneChoice { case open, edit, reveal, close }
}

struct RadialMenuView: View {
    @Bindable var model: RadialMenuModel
    let actions: RadialMenuActions
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    static let margin: CGFloat = 36

    private var outer: CGFloat { model.diameter / 2 }
    private var inner: CGFloat { model.diameter * 0.215 }
    private var geometry: RadialGeometry { RadialGeometry(count: model.actions.count, outerRadius: outer, innerRadius: inner) }
    private var accent: Color { Color(nsColor: model.accent) }
    private var highContrast: Bool { contrast == .increased }
    private var canvas: CGFloat { model.diameter + Self.margin * 2 }

    var body: some View {
        ZStack {
            switch model.phase {
            case .done(let info):
                DoneCard(info: info, accent: accent, highContrast: highContrast, choose: actions.done)
                    .transition(transition)
            case .failed(let title, let message):
                FailureCard(title: title, message: message, close: actions.dismiss)
                    .transition(transition)
            default:
                wheel
                    .transition(transition)
                if case .options(let action) = model.phase {
                    OptionsCard(model: model, action: action, accent: accent, confirm: actions.confirmOptions, cancel: actions.cancelOptions)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
        .frame(width: canvas, height: canvas)
        .scaleEffect(model.appeared || model.reduceMotion ? 1 : 0.86)
        .opacity(model.appeared ? 1 : 0)
        .animation(model.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.82), value: model.appeared)
        .animation(model.reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.26, dampingFraction: 0.86), value: phaseKey)
    }

    private var transition: AnyTransition {
        model.reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity)
    }

    private var phaseKey: Int {
        switch model.phase {
        case .choosing: 0
        case .options: 1
        case .working: 2
        case .done: 3
        case .failed: 4
        }
    }

    // MARK: Wheel

    private var wheel: some View {
        ZStack {
            // Frosted disc with a soft shadow.
            Circle()
                .fill(.clear)
                .background(VisualEffectBackground(material: .menu, emphasized: highContrast).clipShape(Circle()))
                .overlay(Circle().strokeBorder(Color.primary.opacity(highContrast ? 0.5 : 0.12), lineWidth: highContrast ? 1 : 0.5))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 22, y: 10)
                .frame(width: model.diameter, height: model.diameter)

            segments
                .opacity(model.busy || model.phase != .choosing ? 0.35 : 1)
                .animation(.easeOut(duration: 0.15), value: model.busy)
                .id(model.stage) // crossfade between primary and overflow rings
                .transition(.opacity)

            hub
        }
        .frame(width: canvas, height: canvas)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard model.phase == .choosing, !model.busy else { return }
            switch phase {
            case .active(let p):
                let region = geometry.region(dx: p.x - canvas / 2, dy: p.y - canvas / 2)
                if case .segment(let i) = region { if model.hovered != i { model.hovered = i } } else if model.hovered != nil { model.hovered = nil }
            case .ended:
                model.hovered = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Forma conversion wheel for \(model.hubTitle)")
    }

    private var segments: some View {
        ZStack {
            ForEach(Array(model.actions.enumerated()), id: \.offset) { i, action in
                let isHot = model.highlighted == i && model.phase == .choosing
                let nudge = geometry.outward(i)
                let push: CGFloat = isHot && !model.reduceMotion ? 4 : 0
                ZStack {
                    AnnularSector(start: geometry.startAngle(i), end: geometry.endAngle(i), inner: inner + 4, outer: outer - 4)
                        .fill(isHot ? accent.opacity(highContrast ? 0.45 : 0.22) : Color.primary.opacity(highContrast ? 0.06 : 0.0001))
                    AnnularSector(start: geometry.startAngle(i), end: geometry.endAngle(i), inner: inner + 4, outer: outer - 4)
                        .stroke(isHot ? accent.opacity(0.55) : Color.primary.opacity(highContrast ? 0.35 : 0.07), lineWidth: isHot ? 1 : 0.5)
                    SegmentLabel(action: action, hot: isHot, accent: accent, highContrast: highContrast)
                        .position(x: canvas / 2 + geometry.labelPosition(i).x, y: canvas / 2 + geometry.labelPosition(i).y)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(action.accessibilityLabel)
                        .accessibilityHint(model.detail(for: action, caveats: model.caveatCache[action] ?? []))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { actions.select(i) }
                }
                .frame(width: canvas, height: canvas)
                .offset(x: nudge.dx * push, y: nudge.dy * push)
                .scaleEffect(isHot && !model.reduceMotion ? 1.015 : 1)
                .animation(model.reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.72), value: isHot)
            }
        }
    }

    // MARK: Hub

    private var hub: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(highContrast ? 0.1 : 0.035))
                .overlay(Circle().strokeBorder(Color.primary.opacity(highContrast ? 0.4 : 0.08), lineWidth: 0.5))
                .frame(width: inner * 2 - 4, height: inner * 2 - 4)

            if case .working(let progress, let label) = model.phase {
                WorkingHub(progress: progress, label: label, accent: accent, size: inner * 2 - 4, reduceMotion: model.reduceMotion)
            } else if let action = model.highlightedAction, model.phase == .choosing {
                VStack(spacing: 3) {
                    Text(action.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.detail(for: action, caveats: model.caveatCache[action] ?? []))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .frame(width: inner * 2 - 22)
                .transition(.opacity)
            } else {
                VStack(spacing: 3) {
                    FileIconView(url: model.files.first?.url, count: model.files.count)
                        .frame(width: 34, height: 34)
                    Text(model.hubTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.hubSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: inner * 2 - 18)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.1), value: model.highlighted)
    }
}

// MARK: - Pieces

struct AnnularSector: Shape {
    var start: CGFloat
    var end: CGFloat
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Our angles run clockwise from 12 o'clock; SwiftUI's run from 3 o'clock.
        let a0 = Angle(radians: Double(start) - .pi / 2)
        let a1 = Angle(radians: Double(end) - .pi / 2)
        // Keep the visual gap constant: the inner arc needs a slightly larger angular inset.
        let innerInset = Angle(radians: Double(0.035 * (outer / max(inner, 1)) - 0.035) / 2)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1 - innerInset, endAngle: a0 + innerInset, clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct SegmentLabel: View {
    let action: WheelAction
    let hot: Bool
    let accent: Color
    let highContrast: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: action.symbolName)
                .font(.system(size: 17, weight: hot ? .semibold : .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hot ? accent : (highContrast ? Color.primary : Color.primary.opacity(0.8)))
                .frame(height: 20)
            Text(action.title)
                .font(.system(size: 10.5, weight: hot ? .semibold : .medium))
                .foregroundStyle(hot || highContrast ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 64)
    }
}

private struct WorkingHub: View {
    let progress: Double?
    let label: String
    let accent: Color
    let size: CGFloat
    let reduceMotion: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 3)
                .frame(width: size - 10, height: size - 10)
            Circle()
                .trim(from: 0, to: progress.map { max(0.03, $0) } ?? 0.25)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90 + (progress == nil && spin ? 360 : 0)))
                .frame(width: size - 10, height: size - 10)
                .animation(progress == nil && !reduceMotion ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.15), value: spin)
                .animation(.easeOut(duration: 0.15), value: progress)
            VStack(spacing: 2) {
                if let progress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 15, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size - 34)
                Text("esc to cancel")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear { spin = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.map { "Converting, \(Int($0 * 100)) percent" } ?? "Converting")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct FileIconView: View {
    let url: URL?
    let count: Int

    var body: some View {
        ZStack {
            if let url {
                if count > 1 {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().interpolation(.high)
                        .offset(x: 4, y: -3).opacity(0.55)
                }
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().interpolation(.high)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Real vibrancy behind translucent panels. Offscreen snapshots can't sample what's
/// behind a window, so they fall back to a flat approximation of the material.
struct VisualEffectBackground: View {
    var material: NSVisualEffectView.Material
    var emphasized = false
    @MainActor static var snapshotMode = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if Self.snapshotMode {
            Rectangle().fill(scheme == .dark ? Color(white: 0.2).opacity(0.94) : Color(white: 0.985).opacity(0.94))
        } else {
            VisualEffectRepresentable(material: material, emphasized: emphasized)
        }
    }
}

private struct VisualEffectRepresentable: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var emphasized: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = emphasized
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.isEmphasized = emphasized
    }
}
