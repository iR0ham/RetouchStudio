import SwiftUI

/// The report Smart Analyze produces, before anything is applied. Findings are
/// grouped by face so a photo with more than one person still reads as a list of
/// measured problems, not one global verdict.
struct SmartAnalyzeSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if let report = model.smartReport {
                        photoSection(report)
                        faceSections(report)
                        optionsSection(report)
                    } else {
                        Text(model.s.smartNothingFound)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(20)
            }
            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 540, height: 600)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.sky.opacity(0.14))
                    .frame(width: 32, height: 32)
                Icon(name: "sparkles", size: 17, emphasised: true)
                    .foregroundStyle(Theme.sky)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.s.smartSheetTitle)
                    .font(Theme.Font.face(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(model.s.smartSheetSubtitle)
                    .font(Theme.Font.face(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - Sections

    private func photoSection(_ report: SmartAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ReportLabel(model.s.smartPhotoSection)
            VStack(spacing: 0) {
                ForEach(report.photoFindings) { finding in
                    FindingRow(finding: finding, tint: Theme.sky, copy: model.s)
                    if finding.id != report.photoFindings.last?.id {
                        Hairline().padding(.leading, 30)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(card)
        }
    }

    @ViewBuilder
    private func faceSections(_ report: SmartAnalyzer.Report) -> some View {
        if report.faces.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ReportLabel(model.s.smartFaceSection)
                Text(model.s.smartNoFace)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(card)
            }
        } else {
            ForEach(report.faces) { face in
                VStack(alignment: .leading, spacing: 9) {
                    ReportLabel(model.s.smartFaceLabel(face.index),
                               trailing: frameShare(face))
                    HStack(alignment: .top, spacing: 10) {
                        if let preview = face.spotPreview {
                            SpotMap(image: preview, markers: face.spotMarkers)
                                .frame(width: 92,
                                       height: 92 * CGFloat(preview.height) / CGFloat(preview.width))
                        }
                        VStack(spacing: 0) {
                            ForEach(face.findings) { finding in
                                FindingRow(finding: finding, tint: Theme.accent, copy: model.s)
                                if finding.id != face.findings.last?.id {
                                    Hairline().padding(.leading, 30)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .background(card)
                    }
                }
            }
        }
    }

    private func frameShare(_ face: SmartAnalyzer.FaceReading) -> String {
        let short = min(face.area.squareRoot(), 1)
        return model.s.smartFrameShare(Int((short * 100).rounded()))
    }

    private func optionsSection(_ report: SmartAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ReportLabel(model.s.retouchMenu)
            VStack(spacing: 0) {
                ToggleRow(title: model.s.smartApplyRetouch,
                          detail: retouchSummary(report),
                          isOn: $model.smartApplyRetouch)
                Hairline().padding(.leading, 14)
                ToggleRow(title: model.s.smartApplyColor,
                          detail: colorSummary(report),
                          isOn: $model.smartApplyColorLight)
                Hairline().padding(.leading, 14)
                ToggleRow(title: model.s.smartApplyHeal,
                          detail: report.spots.isEmpty
                              ? model.s.smartNoSpots
                              : model.s.smartSpotCount(report.spots.count),
                          isOn: $model.smartApplyHealSpots,
                          enabled: !report.spots.isEmpty)
            }
            .background(card)
        }
    }

    /// The numbers the sliders will actually receive, after the owner's own
    /// strength setting — so the report can be checked instead of trusted.
    private func retouchSummary(_ report: SmartAnalyzer.Report) -> String {
        let scaled = report.retouch.scaledRetouch(by: model.autoRetouchStrength)
        var parts: [String] = []
        func add(_ name: String, _ value: Double) {
            let rounded = Int(value.rounded())
            guard rounded > 0 else { return }
            parts.append("\(name) \(Digits.num(rounded))")
        }
        add(model.s.smartShortSmooth, scaled.smooth)
        add(model.s.smartShortBlemish, scaled.blemish)
        add(model.s.smartShortLines, scaled.wrinkle)
        add(model.s.smartShortTone, scaled.skinToneEvens)
        add(model.s.smartShortUnderEye, scaled.darkCircles)
        add(model.s.smartShortShine, scaled.shine)
        add(model.s.smartShortBrighten, scaled.skinBrighten)
        add(model.s.smartShortTeeth, scaled.teethWhiten)
        add(model.s.smartShortEyes, max(scaled.eyeBrighten, scaled.eyeSharpen))
        return parts.isEmpty ? model.s.smartAlreadyZero : parts.joined(separator: " · ")
    }

    private func colorSummary(_ report: SmartAnalyzer.Report) -> String {
        let scaled = report.colorLight.scaledColorLight(by: model.autoColorStrength)
        var parts: [String] = []
        func add(_ name: String, _ value: Double) {
            let rounded = Int(value.rounded())
            guard rounded != 0 else { return }
            let sign = rounded > 0 ? "+" : "-"
            parts.append("\(name) \(sign)\(Digits.num(abs(rounded)))")
        }
        add(model.s.smartShortExposure, scaled.exposure)
        add(model.s.smartShortContrast, scaled.contrast)
        add(model.s.smartShortBlacks, scaled.blacks)
        add(model.s.smartShortWhites, scaled.whites)
        add(model.s.smartShortSaturation, scaled.saturation)
        add(model.s.smartShortVibrance, scaled.vibrance)
        add(model.s.smartShortWarmth, scaled.warmth)
        add(model.s.smartShortClarity, scaled.clarity)
        return parts.isEmpty ? model.s.smartAlreadyBalanced : parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.showSmartSheet = false
            } label: {
                Text(model.s.smartCancel)
                    .font(Theme.Font.face(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(height: 36)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.inset)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                model.applySmartReport()
            } label: {
                HStack(spacing: 7) {
                    Icon(name: "sparkles", size: 14, emphasised: true)
                    Text(model.s.smartApply)
                        .font(Theme.Font.button)
                }
                .foregroundStyle(canApply ? Theme.accentInk : Theme.faint)
                .frame(height: 36)
                .padding(.horizontal, 20)
                .background(
                    Capsule(style: .continuous)
                        .fill(canApply ? Theme.accent : Theme.inset)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle(dip: 0.96))
            // Deliberately not the sheet's default Return action. A report is
            // a measurement the owner approves; it must never be applied by a
            // stray Return while the sheet is coming up. ⌘↩ is explicit.
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canApply)
        }
        .padding(16)
    }

    private var canApply: Bool {
        model.smartReport != nil
            && (model.smartApplyRetouch || model.smartApplyColorLight || model.smartApplyHealSpots)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Theme.background)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.75)
            )
    }
}

// MARK: - Rows

private struct ReportLabel: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(Theme.Font.section)
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}

private struct FindingRow: View {
    let finding: SmartAnalyzer.Finding
    let tint: Color
    let copy: L10n

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint.opacity(0.25 + 0.7 * finding.severity))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(copy.findingTitle(finding.kind))
                    .font(Theme.Font.face(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(copy.findingDetail(finding.detail))
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            severityBar
                .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var severityBar: some View {
        Capsule()
            .fill(Theme.inset)
            .frame(width: 40, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(2, 40 * finding.severity), height: 4)
            }
    }
}

/// The face crop the analyzer looked through, with every suggested spot drawn
/// where it was measured. A count in a sentence is easy to distrust; the exact
/// pixels are not.
private struct SpotMap: View {
    let image: CGImage
    let markers: [SmartAnalyzer.SpotMarker]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let shortSide = min(size.width, size.height)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay {
                    ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                        let diameter = max(6, marker.radius * 2 * shortSide + 5)
                        Circle()
                            .strokeBorder(Theme.accent, lineWidth: 1.1)
                            .background(Circle().fill(Theme.accent.opacity(0.12)))
                            .frame(width: diameter, height: diameter)
                            .position(x: marker.center.x * size.width,
                                      y: marker.center.y * size.height)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.75)
                )
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.face(size: 12.5, weight: .medium))
                    .foregroundStyle(enabled ? Theme.text : Theme.faint)
                Text(detail)
                    .font(Theme.Font.face(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .disabled(!enabled)
                // A focusable switch inside the ScrollView makes the sheet open
                // scrolled down to it, hiding the findings above.
                .focusable(false)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(enabled ? 1 : 0.5)
    }
}
