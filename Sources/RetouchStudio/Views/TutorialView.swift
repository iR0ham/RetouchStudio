import SwiftUI

/// The full tutorial window: a grouped chapter list on one side, the selected
/// chapter on the other. It is a snapshot of `TutorialCopy.current`, rebuilt by
/// `InfoWindows` when the language changes.
struct TutorialView: View {
    private let copy = TutorialCopy.current
    @State private var selectedID: String
    @State private var query = ""
    @State private var hovered: String?

    init() {
        _selectedID = State(initialValue: TutorialCopy.current.sections.first?.id ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(width: 0.75)
                content
            }
            .frame(maxHeight: .infinity)
            Hairline()
            footer
        }
        .frame(width: 980, height: 720)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onChange(of: query) { _, _ in
            if !visibleSections.contains(where: { $0.id == selectedID }),
               let first = visibleSections.first {
                selectedID = first.id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 36, height: 36)
                    Icon(name: "sparkles", size: 18, emphasised: true)
                        .foregroundStyle(Theme.accent)
                }
                Text(copy.windowTitle)
                    .font(Theme.Font.face(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 12)
            }
            Text(copy.intro)
                .font(Theme.Font.face(size: 11.5))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2.5)
            HStack(spacing: 5) {
                Icon(name: "lock.fill", size: 9, emphasised: true)
                Text(copy.localNote)
                    .font(Theme.Font.face(size: 10, weight: .medium))
            }
            .foregroundStyle(Theme.sky)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Sidebar

    private var groups: [String] {
        var seen: [String] = []
        for section in visibleSections where !seen.contains(section.group) {
            seen.append(section.group)
        }
        return seen
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(groups, id: \.self) { group in
                        Text(group)
                            .font(Theme.Font.face(size: 9.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(visibleSections.filter { $0.group == group }) { section in
                            sidebarRow(section)
                        }
                    }

                    if visibleSections.isEmpty {
                        Text(copy.noResults)
                            .font(Theme.Font.face(size: 11))
                            .foregroundStyle(Theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 262)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Icon(name: "magnifyingglass", size: 12, emphasised: true)
                .foregroundStyle(Theme.faint)
            TextField(copy.searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.face(size: 11.5))
                .foregroundStyle(Theme.text)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Icon(name: "xmark.circle.fill", size: 11, emphasised: true)
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.75)
        )
    }

    private func sidebarRow(_ section: TutorialSection) -> some View {
        let selected = section.id == selectedID
        let isAI = section.badge != nil
        let tint = isAI ? Theme.sky : (selected ? Theme.accent : Theme.muted)

        return Button {
            selectedID = section.id
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(selected ? 0.16 : 0.09))
                        .frame(width: 26, height: 26)
                    Icon(name: section.icon, size: 13, emphasised: selected)
                        .foregroundStyle(tint)
                }

                Text(section.title)
                    .font(Theme.Font.face(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 2)

                if let badge = section.badge {
                    Text(badge)
                        .font(Theme.Font.face(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.sky)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(Theme.sky.opacity(0.13)))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.accentSoft
                          : (hovered == section.id ? Theme.bone.opacity(0.035) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = section.id
            } else if hovered == section.id {
                hovered = nil
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if let section = selectedSection {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader(section)
                    if section.id == "shortcuts" {
                        shortcutTable
                    } else {
                        stepList(section)
                    }
                    if let note = section.note {
                        noteCard(note)
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(selectedID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ section: TutorialSection) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 44, height: 44)
                Icon(name: section.icon, size: 21, emphasised: true)
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(section.title)
                        .font(Theme.Font.face(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge = section.badge {
                        Text(badge)
                            .font(Theme.Font.face(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.sky)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule(style: .continuous).fill(Theme.sky.opacity(0.14)))
                            .fixedSize()
                    }
                }
                Text(section.lead)
                    .font(Theme.Font.face(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func stepList(_ section: TutorialSection) -> some View {
        VStack(spacing: 9) {
            ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text(Digits.num(index + 1))
                        .font(Theme.Font.face(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.accent))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(Theme.Font.face(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(step.body)
                            .font(Theme.Font.face(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.75)
                )
            }
        }
    }

    private var shortcutTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.shortcutTitle)
                .font(Theme.Font.section)
                .tracking(0.6)
                .foregroundStyle(Theme.faint)

            VStack(spacing: 0) {
                ForEach(Array(copy.shortcuts.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        Text(row.0)
                            .font(Theme.Font.value)
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.inset)
                            )
                            .frame(minWidth: 62, alignment: .leading)
                        Text(row.1)
                            .font(Theme.Font.face(size: 12))
                            .foregroundStyle(Theme.muted)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    if index < copy.shortcuts.count - 1 {
                        Hairline().padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.75)
            )
        }
    }

    private func noteCard(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(name: "info.circle", size: 14, emphasised: true)
                .foregroundStyle(Theme.sky)
            Text(note)
                .font(Theme.Font.face(size: 11.5))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.sky.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.sky.opacity(0.18), lineWidth: 0.75)
        )
    }

    // MARK: - Footer

    private var visibleSections: [TutorialSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return copy.sections }
        return copy.sections.filter { section in
            let text = ([section.title, section.group, section.lead, section.note ?? ""]
                        + section.steps.flatMap { [$0.title, $0.body] })
                .joined(separator: "\n")
            return text.localizedCaseInsensitiveContains(needle)
        }
    }

    private var selectedSection: TutorialSection? {
        visibleSections.first { $0.id == selectedID } ?? visibleSections.first
    }

    private var currentIndex: Int? {
        guard let section = selectedSection else { return nil }
        return visibleSections.firstIndex { $0.id == section.id }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            SecondaryButton(title: copy.previous,
                            icon: "chevron.backward",
                            enabled: (currentIndex ?? 0) > 0) {
                move(-1)
            }
            .frame(width: 116)

            Spacer(minLength: 8)

            if let index = currentIndex {
                Text("\(Digits.num(index + 1)) / \(Digits.num(visibleSections.count))")
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.faint)
            }

            Spacer(minLength: 8)

            SecondaryButton(title: copy.next,
                            icon: "chevron.forward",
                            enabled: (currentIndex ?? visibleSections.count - 1) < visibleSections.count - 1) {
                move(1)
            }
            .frame(width: 116)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private func move(_ delta: Int) {
        guard let index = currentIndex else { return }
        let target = index + delta
        guard visibleSections.indices.contains(target) else { return }
        selectedID = visibleSections[target].id
    }
}
