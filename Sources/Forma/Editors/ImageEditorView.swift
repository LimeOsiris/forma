import AppKit
import FormaCore
import SwiftUI

struct ImageEditorView: View {
    @Bindable var model: ImageEditorModel
    @State private var showResize = false
    @State private var aspect: CropAspect = .free

    enum CropAspect: String, CaseIterable, Identifiable {
        case free = "Freeform", original = "Original", square = "Square", fourThree = "4:3", sixteenNine = "16:9"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(title: model.url.lastPathComponent, badge: nil) { toolbar }
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    ImageCanvas(model: model)
                        .background(Color(nsColor: .underPageBackgroundColor))
                        .accessibilityLabel("Image canvas")
                    if model.tool == .crop { cropBar.padding(.bottom, 16) }
                }
                if model.showAdjustments {
                    Divider()
                    AdjustmentsPanel(model: model)
                        .frame(width: 240)
                        .transition(.move(edge: .trailing))
                }
            }
            statusBar
        }
        .animation(.easeOut(duration: 0.18), value: model.showAdjustments)
        .sheet(isPresented: $showResize) { ResizeSheet(model: model) }
    }

    // MARK: Toolbar

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 2) {
            ToolButton(symbol: "crop", help: "Crop", active: model.tool == .crop) { model.tool = model.tool == .crop ? .none : .crop }
            ToolButton(symbol: "rotate.left", help: "Rotate Left (⌘L)") { model.rotate(clockwise: false) }
                .keyboardShortcut("l", modifiers: .command)
            ToolButton(symbol: "rotate.right", help: "Rotate Right (⌘R)") { model.rotate(clockwise: true) }
                .keyboardShortcut("r", modifiers: .command)
            ToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal") { model.flip(horizontal: true) }
            ToolButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip Vertical") { model.flip(horizontal: false) }
        }
        Divider().frame(height: 20)
        HStack(spacing: 2) {
            ToolButton(symbol: "cursorarrow", help: "Select Markup", active: model.tool == .select) { model.tool = .select }
            ToolButton(symbol: "rectangle", help: "Rectangle", active: model.tool == .rectangle) { model.tool = .rectangle }
            ToolButton(symbol: "circle", help: "Oval", active: model.tool == .ellipse) { model.tool = .ellipse }
            ToolButton(symbol: "arrow.up.right", help: "Arrow", active: model.tool == .arrow) { model.tool = .arrow }
            ToolButton(symbol: "scribble", help: "Draw", active: model.tool == .pen) { model.tool = .pen }
            ToolButton(symbol: "highlighter", help: "Highlight", active: model.tool == .highlight) { model.tool = .highlight }
            ToolButton(symbol: "textformat", help: "Text", active: model.tool == .text) { model.tool = .text }
            ColorMenu(color: $model.color, lineWidth: $model.lineWidth, fontSize: $model.fontSize)
        }
        Divider().frame(height: 20)
        HStack(spacing: 2) {
            ToolButton(symbol: "slider.horizontal.3", help: "Adjust Color", active: model.showAdjustments) { model.showAdjustments.toggle() }
            ToolButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", help: "Resize…") { showResize = true }
        }
        Divider().frame(height: 20)
        SaveMenu(isDirty: model.isDirty)
    }

    private var cropBar: some View {
        HStack(spacing: 10) {
            Picker("Aspect", selection: $aspect) {
                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .onChange(of: aspect) { _, a in model.setCropAspect(ratio(a)) }
            Button("Cancel") { model.tool = .none }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Crop") { model.performCrop() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private func ratio(_ a: CropAspect) -> CGFloat? {
        switch a {
        case .free: nil
        case .original: model.canvasPixelSize.width / max(model.canvasPixelSize.height, 1)
        case .square: 1
        case .fourThree: 4.0 / 3
        case .sixteenNine: 16.0 / 9
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            let s = model.outputPixelSize
            Text("\(Int(s.width)) × \(Int(s.height)) px")
            if model.edits.resize != nil { Text("resized").foregroundStyle(.tertiary) }
            if !model.edits.annotations.isEmpty { Text("\(model.edits.annotations.count) markup") }
            Spacer()
            if model.isDirty { Text("Edited").foregroundStyle(.secondary) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension ImageEditorModel {
    /// Bridged to the canvas, which owns the in-progress crop rectangle.
    func performCrop() { cropBridge.apply?() }
    func setCropAspect(_ r: CGFloat?) { cropBridge.setAspect?(r) }
}

/// Lets SwiftUI buttons reach the AppKit canvas.
@MainActor
final class CropBridge {
    var apply: (() -> Void)?
    var setAspect: ((CGFloat?) -> Void)?
}

private struct AdjustmentsPanel: View {
    @Bindable var model: ImageEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Adjust").font(.system(size: 13, weight: .semibold))
                slider("Exposure", value: $model.edits.exposure, range: -2...2, format: "%+.1f EV")
                slider("Brightness", value: $model.edits.brightness, range: -0.5...0.5, format: "%+.2f")
                slider("Contrast", value: $model.edits.contrast, range: 0.5...1.5, format: "%.2f")
                slider("Saturation", value: $model.edits.saturation, range: 0...2, format: "%.2f")
                slider("Sharpness", value: $model.edits.sharpness, range: 0...2, format: "%.2f")
                HStack {
                    Button("Reset") { model.resetAdjustments() }
                        .disabled(!model.edits.hasAdjustments)
                    Spacer()
                    Button("Revert All") { model.revertAll() }
                        .disabled(model.edits == ImageEdits())
                }
                .controlSize(.small)
            }
            .padding(16)
        }
        .background(.background)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11.5))
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if editing { model.beginSlider() } else { model.endSlider(title) }
            }
            .controlSize(.small)
            .accessibilityLabel(title)
        }
    }
}

private struct ResizeSheet: View {
    let model: ImageEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var width: Double = 0
    @State private var height: Double = 0
    @State private var keepAspect = true

    var body: some View {
        let base = model.canvasPixelSize
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize Image").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Width")
                    TextField("", value: $width, format: .number).frame(width: 90)
                        .onChange(of: width) { _, w in if keepAspect, base.width > 0 { let h = (w * base.height / base.width).rounded(); if h != height { height = h } } }
                    Text("px").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Height")
                    TextField("", value: $height, format: .number).frame(width: 90)
                        .onChange(of: height) { _, h in if keepAspect, base.height > 0 { let w = (h * base.width / base.height).rounded(); if w != width { width = w } } }
                    Text("px").foregroundStyle(.secondary)
                }
            }
            Toggle("Keep proportions", isOn: $keepAspect)
            HStack(spacing: 6) {
                ForEach([25, 50, 75, 100], id: \.self) { pct in
                    Button("\(pct)%") { width = (base.width * Double(pct) / 100).rounded(); height = (base.height * Double(pct) / 100).rounded() }
                }
            }
            .controlSize(.small)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Resize") {
                    let w = max(1, min(width, 20_000)), h = max(1, min(height, 20_000))
                    model.commit("Resize") { $0.resize = (w == base.width && h == base.height) ? nil : CGSize(width: w, height: h) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width < 1 || height < 1)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            let s = model.outputPixelSize
            width = s.width; height = s.height
        }
    }
}

/// Color, line width and text size for markup.
struct ColorMenu: View {
    @Binding var color: RGBA
    @Binding var lineWidth: CGFloat
    @Binding var fontSize: CGFloat
    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]

    var body: some View {
        Menu {
            ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, c in
                Button { color = RGBA(c) } label: {
                    Label(c.accessibilityName.capitalized, systemImage: RGBA(c) == color ? "checkmark.circle.fill" : "circle.fill")
                }
            }
            Divider()
            Picker("Line", selection: $lineWidth) {
                Text("Thin").tag(CGFloat(0.003))
                Text("Medium").tag(CGFloat(0.006))
                Text("Thick").tag(CGFloat(0.012))
            }
            Picker("Text Size", selection: $fontSize) {
                Text("Small").tag(CGFloat(0.025))
                Text("Medium").tag(CGFloat(0.04))
                Text("Large").tag(CGFloat(0.07))
            }
        } label: {
            Circle().fill(Color(nsColor: color.nsColor)).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help("Markup color and size")
        .accessibilityLabel("Markup color and size")
    }
}

/// Save / Save a Copy, routed through the responder chain to the window controller.
struct SaveMenu: View {
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 2) {
            ToolButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            ToolButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            Menu {
                Button("Save (Replace Original)") { NSApp.sendAction(#selector(EditorWindowController.saveEdits(_:)), to: nil, from: nil) }
                Button("Save a Copy…") { NSApp.sendAction(#selector(EditorWindowController.saveCopy(_:)), to: nil, from: nil) }
                Button("Export as PDF…") { NSApp.sendAction(#selector(EditorWindowController.exportPDF(_:)), to: nil, from: nil) }
            } label: {
                Text("Save").font(.system(size: 12, weight: .medium))
            } primaryAction: {
                NSApp.sendAction(#selector(EditorWindowController.saveCopy(_:)), to: nil, from: nil)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help("Save a copy (click) or replace the original (menu)")
        }
    }
}
