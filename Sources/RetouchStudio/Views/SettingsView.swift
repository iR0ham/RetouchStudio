import SwiftUI

/// Preferences that survive a restart. Each control writes straight into the
/// open document *and* the saved defaults, so a change is visible immediately
/// and still there tomorrow.
struct SettingsView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var showModels = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                languageSection
                autoSection
                exportSection
                toolsSection
                modelsSection
                recoverySection
                developerSection
                footer
            }
            .padding(22)
        }
        .frame(width: 470, height: 560)
        .background(Theme.background)
        .background(SettingsWindowTitle(title: model.s.settingsWindowTitle))
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, model.language.layoutDirection)
        .sheet(isPresented: $showModels) {
            ModelManagerView(editor: model)
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(model.s.settingsLanguage, help: model.s.settingsLanguageHelp)

            HStack(spacing: 2) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    let active = model.language == language
                    Button {
                        model.language = language
                    } label: {
                        Text(language.title)
                            .font(Theme.Font.face(size: 11.5, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Theme.accentInk : Theme.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(active ? Theme.accent : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle(dip: 0.96))
                    .help(language.title)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.panel)
            )
        }
    }

    // MARK: - Auto

    private var autoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(model.s.settingsAuto, help: model.s.settingsAutoNote)
            Text(model.s.settingsAutoNote)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            percentRow(model.s.autoRetouch,
                       value: $model.autoRetouchStrength,
                       tint: Theme.sky)
                .help(model.s.autoRetouchHelp)
            percentRow(model.s.autoColorLight,
                       value: $model.autoColorStrength,
                       tint: Theme.accent)
                .help(model.s.autoColorLightHelp)
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(model.s.settingsExport, help: model.s.settingsExportHelp)

            HStack(spacing: 2) {
                ForEach(ExportFormat.allCases) { format in
                    let active = model.exportFormat == format
                    Button {
                        model.exportFormat = format
                    } label: {
                        Text(format.title)
                            .font(Theme.Font.face(size: 11.5, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Theme.accentInk : Theme.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(active ? Theme.accent : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle(dip: 0.96))
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.panel)
            )

            if model.exportFormat.supportsQuality {
                percentRow(model.s.quality,
                           value: Binding(get: { model.exportQuality * 100 },
                                          set: { model.exportQuality = $0 / 100 }),
                           tint: Theme.accent)
                    .help("\(model.s.quality) — \(model.s.sliderHint(.exportQuality))")
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.s.settingsStripMetadata)
                        .font(Theme.Font.face(size: 12.5))
                        .foregroundStyle(Theme.text)
                    Text(model.s.settingsStripMetadataNote)
                        .font(Theme.Font.face(size: 10.5))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $model.stripLocationMetadata)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .accessibilityLabel(model.s.settingsStripMetadata)
                    .help(model.s.settingsStripMetadataNote)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(model.s.settingsTools, help: model.s.settingsToolsHelp)

            row(model.s.settingsBrush,
                detail: "\(Digits.num(model.healBrushPixels)) px") {
                BipolarSlider(value: $model.healBrushPercent, range: 0.4...6, step: 0.2)
                    .help(model.s.brushShortcutHint)
            }

            HStack(spacing: 12) {
                Text(model.s.settingsFaceOverlay)
                    .font(Theme.Font.face(size: 12.5))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Toggle("", isOn: $model.showFaceOverlay)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .accessibilityLabel(model.s.settingsFaceOverlay)
                    .help(model.s.settingsFaceOverlay)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(model.s.settingsModels, help: model.s.settingsModelsNote)
            Text(model.s.settingsModelsNote)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showModels = true
            } label: {
                Text(model.s.settingsModelsManage)
                    .font(Theme.Font.face(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(Theme.inset)
                    )
                    .contentShape(Rectangle())
                    .help(model.s.settingsModelsNote)
            }
            .buttonStyle(PressableButtonStyle(dip: 0.95))
        }
    }

    // MARK: - Recovery

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(model.s.settingsRecovery, help: model.s.settingsRecoveryNote)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.s.settingsRecoveryToggle)
                        .font(Theme.Font.face(size: 12.5))
                        .foregroundStyle(Theme.text)
                    Text(model.s.settingsRecoveryNote)
                        .font(Theme.Font.face(size: 10.5))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $settings.recoveryEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .accessibilityLabel(model.s.settingsRecoveryToggle)
                    .help(model.s.settingsRecoveryNote)
            }
        }
    }

    // MARK: - Developer

    /// Identity and the running build. The blank fields in `DeveloperProfile`
    /// are simply left out, so the card stays honest until they are filled in.
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(model.s.settingsDeveloper, help: model.s.settingsDeveloperHelp)

            VStack(spacing: 0) {
                detailRow(model.s.aboutDeveloper, DeveloperProfile.name)
                if !DeveloperProfile.role.isEmpty {
                    Hairline()
                    detailRow(model.s.aboutDeveloperRole, DeveloperProfile.role)
                }
                if !DeveloperProfile.email.isEmpty {
                    Hairline()
                    detailRow(model.s.aboutContact, DeveloperProfile.email)
                }
                if !DeveloperProfile.website.isEmpty {
                    Hairline()
                    detailRow(model.s.aboutWebsite, DeveloperProfile.website)
                }
                Hairline()
                detailRow(model.s.aboutVersion, DeveloperProfile.versionLine)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.panel)
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.s.settingsResetNote)
                .font(Theme.Font.face(size: 10.5))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                model.resetPreferences()
            } label: {
                Text(model.s.settingsReset)
                    .font(Theme.Font.face(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(height: 30)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(Theme.inset)
                    )
                    .contentShape(Rectangle())
                    .help(model.s.settingsResetNote)
            }
            .buttonStyle(PressableButtonStyle(dip: 0.95))
        }
        .padding(.top, 4)
    }

    // MARK: - Pieces

    private func sectionTitle(_ text: String, help: String? = nil) -> some View {
        Text(text)
            .font(Theme.Font.section)
            .tracking(0.6)
            .foregroundStyle(Theme.faint)
            .help(help ?? text)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.Font.face(size: 11.5))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.Font.value)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 7)
    }

    private func percentRow(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                Text(Digits.percent(Int(value.wrappedValue.rounded())))
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: value.wrappedValue)
            }
            BipolarSlider(value: value, range: 0...100, tint: tint)
        }
    }

    private func row<Content: View>(_ title: String,
                                    detail: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                Text(detail)
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.muted)
            }
            content()
        }
    }
}

/// A SwiftUI `Settings` window is titled by the system, in the system language,
/// so it kept saying "Settings" after the app switched to Persian. This writes
/// the table's own wording over it, and again whenever the language changes.
private struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView {
        let view = TitleView()
        view.title = title
        return view
    }

    func updateNSView(_ view: TitleView, context: Context) {
        view.title = title
        view.apply()
    }

    final class TitleView: NSView {
        var title = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            window?.title = title
        }
    }
}
