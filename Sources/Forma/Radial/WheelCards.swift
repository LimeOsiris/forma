import AppKit
import FormaCore
import SwiftUI

/// Compact confirmation shown in place of the wheel after a conversion.
struct DoneCard: View {
    let info: RadialMenuModel.DoneInfo
    let accent: Color
    let highContrast: Bool
    let choose: (RadialMenuActions.DoneChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: info.primaryURL.path))
                        .resizable().interpolation(.high)
                        .frame(width: 38, height: 38)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, accent)
                        .offset(x: 4, y: 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(info.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let e = info.editability, e != .full {
                Label(e.label, systemImage: icon(for: e))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(e.detail)
            }
            ForEach(info.notes.prefix(2), id: \.self) { note in
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                CardButton(title: "Open", key: "o") { choose(.open) }
                if info.editable { CardButton(title: "Edit", key: "e") { choose(.edit) } }
                CardButton(title: "Reveal", key: "r") { choose(.reveal) }
                Spacer(minLength: 4)
                CardButton(title: "Done", key: .return, prominent: true, accent: accent) { choose(.close) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(VisualEffectBackground(material: .menu, emphasized: highContrast))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(highContrast ? 0.5 : 0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversion finished. \(info.title)")
    }

    func icon(for e: Editability) -> String {
        switch e {
        case .full: "pencil"
        case .limited: "pencil.and.outline"
        case .annotationOnly: "pencil.tip.crop.circle"
        case .rasterized: "photo"
        case .viewOnly: "eye"
        }
    }
}

struct CardButton: View {
    let title: String
    let key: KeyEquivalent
    var prominent = false
    var accent: Color = .accentColor
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? accent : Color.primary.opacity(hover ? 0.12 : 0.07))
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .onHover { hover = $0 }
    }
}

struct FailureCard: View {
    let title: String
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 16))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                CardButton(title: "OK", key: .return, prominent: true, action: close)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(VisualEffectBackground(material: .menu))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
    }
}

/// Format-aware options and confirmations, shown over the wheel's center.
struct OptionsCard: View {
    @Bindable var model: RadialMenuModel
    let action: WheelAction
    let accent: Color
    let confirm: () -> Void
    let cancel: () -> Void

    private var output: FileFormat? {
        switch action {
        case .convert(let f): f
        case .extractText: .txt
        case .combinePDF: .pdf
        default: nil
        }
    }

    private var confirmations: [Caveat] {
        (model.caveatCache[action] ?? []).filter { $0.severity == .requiresConfirmation }
    }

    private var showsQuality: Bool { output?.isLossyByNature == true && output?.category == .image }
    private var showsSize: Bool { output?.category == .image && model.files.contains { $0.format.category == .image } }
    private var showsDPI: Bool { output?.category == .image && model.files.contains { $0.format == .pdf } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(output.map { "Convert to \($0.displayName)" } ?? action.title)
                .font(.system(size: 12.5, weight: .semibold))
            ForEach(confirmations, id: \.self) { c in
                Label(c.message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsQuality {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Quality").font(.system(size: 11))
                        Spacer()
                        Text("\(Int(model.options.quality * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $model.options.quality, in: 0.3...1).controlSize(.small).tint(accent)
                        .accessibilityLabel("Quality")
                }
            }
            if showsSize {
                HStack {
                    Text("Max size").font(.system(size: 11))
                    Spacer()
                    Picker("", selection: Binding(get: { model.options.maxPixelSize ?? 0 }, set: { model.options.maxPixelSize = $0 == 0 ? nil : $0 })) {
                        Text("Original").tag(0)
                        Text("4096 px").tag(4096)
                        Text("2048 px").tag(2048)
                        Text("1024 px").tag(1024)
                        Text("512 px").tag(512)
                    }
                    .labelsHidden().controlSize(.small).frame(width: 110)
                    .accessibilityLabel("Maximum size")
                }
            }
            if showsDPI {
                HStack {
                    Text("Resolution").font(.system(size: 11))
                    Spacer()
                    Picker("", selection: $model.options.pdfRenderDPI) {
                        Text("72 dpi").tag(72.0)
                        Text("150 dpi").tag(150.0)
                        Text("300 dpi").tag(300.0)
                        Text("600 dpi").tag(600.0)
                    }
                    .labelsHidden().controlSize(.small).frame(width: 110)
                    .accessibilityLabel("Resolution")
                }
            }
            HStack {
                Spacer()
                CardButton(title: "Cancel", key: .escape, action: cancel)
                CardButton(title: confirmations.isEmpty ? "Convert" : "Continue", key: .return, prominent: true, accent: accent, action: confirm)
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}
