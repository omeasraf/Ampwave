//
//  EqualizerView.swift
//  Ampwave
//

internal import SwiftUI

// MARK: - Layout constants

private let yPad: CGFloat = 18
private let xPad: CGFloat = 16
private let maxGainDB: CGFloat = 12

// MARK: - Geometry helpers

/// Canvas point for a given band index and gain value.
private func bandPoint(band: Int, gain: Float, in size: CGSize) -> CGPoint {
    let count = EQManager.bandFrequencies.count
    let w = size.width - 2 * xPad
    let h = size.height - 2 * yPad
    let x = xPad + CGFloat(band) / CGFloat(count - 1) * w
    let y = (yPad + h / 2 * (1 - CGFloat(gain) / maxGainDB))
        .clamped(to: yPad...(size.height - yPad))
    return CGPoint(x: x, y: y)
}

/// Convert a canvas Y position back to a gain value.
private func yToGain(_ y: CGFloat, height: CGFloat) -> Float {
    let h = height - 2 * yPad
    guard h > 0 else { return 0 }
    let normalized = (y - yPad) / h           // 0 → top (+12 dB), 1 → bottom (−12 dB)
    let raw = Float(maxGainDB) * (1 - Float(normalized) * 2)
    return min(max(raw, -Float(maxGainDB)), Float(maxGainDB))
}

/// Catmull-Rom spline through points (with clamped phantom boundary points).
private func catmullRomPath(through pts: [CGPoint]) -> Path {
    guard pts.count >= 2 else { return Path() }
    let all = [pts[0]] + pts + [pts[pts.count - 1]]
    var path = Path()
    path.move(to: all[1])
    for i in 1..<all.count - 2 {
        let p0 = all[i - 1], p1 = all[i], p2 = all[i + 1], p3 = all[i + 2]
        let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: cp1, control2: cp2)
    }
    return path
}

private extension CGFloat {
    func clamped(to r: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

private func gainLabel(_ g: Float) -> String {
    if g == 0 { return "0 dB" }
    return g > 0 ? "+\(Int(g.rounded())) dB" : "\(Int(g.rounded())) dB"
}

// MARK: - EQ Curve Canvas

private struct EQCurveCanvas: View {
    let gains: [Float]
    let accentColor: Color
    let isEnabled: Bool

    var body: some View {
        Canvas { ctx, size in
            let pts = (0..<gains.count).map { bandPoint(band: $0, gain: gains[$0], in: size) }
            let curve = catmullRomPath(through: pts)

            // ── Grid lines ──
            let gridLines: [(CGFloat, CGFloat)] = [(12, 0.14), (6, 0.08), (0, 0.22), (-6, 0.08), (-12, 0.14)]
            for (db, opacity) in gridLines {
                let h = size.height - 2 * yPad
                let y = yPad + h / 2 * (1 - db / maxGainDB)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(.white.opacity(opacity)),
                           style: StrokeStyle(lineWidth: db == 0 ? 1.2 : 0.7, dash: db == 0 ? [] : [4, 5]))
            }

            // ── Gradient fill below curve ──
            var fill = curve
            fill.addLine(to: CGPoint(x: pts.last!.x, y: size.height + 4))
            fill.addLine(to: CGPoint(x: pts.first!.x, y: size.height + 4))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [accentColor.opacity(isEnabled ? 0.28 : 0.08), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))

            // ── Curve stroke ──
            ctx.stroke(curve,
                       with: .color(accentColor.opacity(isEnabled ? 1 : 0.3)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - EQ Handles

private struct EQHandlesView: View {
    @Binding var gains: [Float]
    @Binding var draggingBand: Int?
    let accentColor: Color
    let isEnabled: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<EQManager.bandFrequencies.count, id: \.self) { i in
                    let pos = bandPoint(band: i, gain: gains[i], in: geo.size)
                    let active = draggingBand == i

                    ZStack {
                        // Tooltip
                        if active {
                            Text(gainLabel(gains[i]))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(white: 0.06))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(accentColor, in: RoundedRectangle(cornerRadius: 6))
                                .offset(y: pos.y < 40 ? 36 : -36)
                                .zIndex(10)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }

                        // Handle
                        Circle()
                            .fill(active ? accentColor : Color(white: 0.92))
                            .overlay(Circle().strokeBorder(accentColor.opacity(active ? 0 : 0.55), lineWidth: 1.5))
                            .frame(width: active ? 22 : 16, height: active ? 22 : 16)
                            .shadow(color: accentColor.opacity(active ? 0.7 : 0.25), radius: active ? 10 : 4)
                            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: active)
                    }
                    // Touch target larger than visible handle
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .position(pos)
                    .opacity(isEnabled ? 1 : 0.45)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("eqCanvas"))
                            .onChanged { drag in
                                withAnimation(.interactiveSpring(response: 0.15)) { draggingBand = i }
                                var raw = yToGain(drag.location.y, height: geo.size.height)
                                if abs(raw) < 0.55 { raw = 0 }   // snap to 0 dB
                                gains[i] = raw
                                VocalIsolator.shared.setEQGain(raw, atBand: i)
                                EQManager.shared.currentPresetName = "Custom"
                            }
                            .onEnded { _ in
                                withAnimation(.spring(response: 0.25)) { draggingBand = nil }
                                EQManager.shared.persist()
                            }
                    )
                }
            }
            .coordinateSpace(name: "eqCanvas")
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.85), value: gains)
        }
    }
}

// MARK: - Preset Chip

private struct PresetChip: View {
    let name: String
    let isSelected: Bool
    let isUserDefined: Bool
    let accentColor: Color
    let onTap: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color(white: 0.07) : .white)
                    .lineLimit(1)

                if isUserDefined, let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isSelected ? Color(white: 0.07).opacity(0.55) : .white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? AnyView(Capsule().fill(accentColor))
                    : AnyView(Capsule().fill(Color(white: 0.18)))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - dB scale labels (left side of curve)

private struct DBScaleView: View {
    var body: some View {
        VStack {
            Spacer()
            ForEach([12, 6, 0, -6, -12], id: \.self) { db in
                Text(db > 0 ? "+\(db)" : "\(db)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
            }
        }
        .frame(width: 24)
        .padding(.vertical, yPad - 4)
    }
}

// MARK: - Main Equalizer View

struct EqualizerView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Bindable private var eq: EQManager = .shared
    @State private var draggingBand: Int? = nil
    @State private var isSavingPreset = false
    @State private var newPresetName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

            presetScroll
                .padding(.bottom, 14)

            curveSection
                .padding(.horizontal, 12)

            freqLabels
                .padding(.top, 6)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            bottomActions
                .padding(.horizontal, 20)
                .padding(.bottom, isSavingPreset ? 8 : 20)

            if isSavingPreset {
                saveRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isSavingPreset)
        .animation(.spring(response: 0.3), value: eq.currentPresetName)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Equalizer")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(eq.currentPresetName)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .contentTransition(.numericText())
            }

            Spacer()

            Toggle("", isOn: $eq.isEnabled)
                .labelsHidden()
                .tint(themeManager.accentColor)
        }
    }

    // MARK: Preset scroll

    private var presetScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(EQPreset.builtIn) { preset in
                    PresetChip(
                        name: preset.name,
                        isSelected: eq.currentPresetName == preset.name,
                        isUserDefined: false,
                        accentColor: themeManager.accentColor,
                        onTap: { withAnimation(.spring(response: 0.28)) { eq.applyPreset(preset) } },
                        onDelete: nil
                    )
                }

                if !eq.userPresets.isEmpty {
                    Rectangle()
                        .fill(Color(white: 0.28))
                        .frame(width: 1, height: 18)
                        .padding(.horizontal, 2)
                }

                ForEach(eq.userPresets) { preset in
                    PresetChip(
                        name: preset.name,
                        isSelected: eq.currentPresetName == preset.name,
                        isUserDefined: true,
                        accentColor: themeManager.accentColor,
                        onTap: { withAnimation(.spring(response: 0.28)) { eq.applyPreset(preset) } },
                        onDelete: {
                            withAnimation {
                                if eq.currentPresetName == preset.name { eq.applyFlat() }
                                eq.deleteUserPreset(preset)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: Curve + scale

    private var curveSection: some View {
        HStack(spacing: 0) {
            DBScaleView()

            ZStack {
                EQCurveCanvas(
                    gains: eq.bands,
                    accentColor: themeManager.accentColor,
                    isEnabled: eq.isEnabled
                )
                EQHandlesView(
                    gains: $eq.bands,
                    draggingBand: $draggingBand,
                    accentColor: themeManager.accentColor,
                    isEnabled: eq.isEnabled
                )
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14))
        .opacity(eq.isEnabled ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.18), value: eq.isEnabled)
    }

    // MARK: Frequency labels

    private var freqLabels: some View {
        HStack(spacing: 0) {
            // offset to align with the curve (past the dB scale width)
            Color.clear.frame(width: 24)
            ForEach(0..<EQManager.bandLabels.count, id: \.self) { i in
                Text(EQManager.bandLabels[i])
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Bottom actions

    private var bottomActions: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3)) { eq.applyFlat() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Reset")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.17), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3)) {
                    isSavingPreset.toggle()
                    newPresetName = ""
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isSavingPreset ? "xmark" : "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text(isSavingPreset ? "Cancel" : "Save Preset")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.17), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Save row

    private var saveRow: some View {
        HStack(spacing: 10) {
            TextField("Name your preset…", text: $newPresetName)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(themeManager.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                .submitLabel(.done)
                .onSubmit { commitSave() }

            Button(action: commitSave) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(
                        newPresetName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Color(white: 0.3)
                            : themeManager.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func commitSave() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        withAnimation { isSavingPreset = false }
        eq.saveUserPreset(name: name)
        newPresetName = ""
    }
}

// MARK: - Sheet wrapper

struct EqualizerSheet: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        EqualizerView()
            .background(Color(white: 0.09).ignoresSafeArea())
            .presentationDetents([.fraction(0.62)])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(white: 0.09))
            .presentationCornerRadius(24)
    }
}

// MARK: - Settings full-page wrapper

struct EqualizerSettingsView: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        EqualizerView()
            .background(Color(white: 0.09).ignoresSafeArea())
            .navigationTitle("Equalizer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color(white: 0.09), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

#Preview {
    EqualizerView()
        .background(Color(white: 0.09).ignoresSafeArea())
        .environment(ThemeManager.shared)
}
