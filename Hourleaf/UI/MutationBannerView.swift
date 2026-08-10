import SwiftUI

struct MutationBannerView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let candidate: EntryUndoCandidate
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                regularLayout
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mutationBanner")
    }

    private var regularLayout: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(accessibilityDetail)
            }
            Spacer(minLength: 0)
            actions
        }
    }

    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(accessibilityDetail)
                }
                Spacer(minLength: 0)
                dismissButton
            }
            undoButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var icon: some View {
        Image(systemName: candidate.operation == .delete ? "trash" : "checkmark.circle.fill")
            .foregroundStyle(candidate.operation == .delete ? Color.orange : Color.accentColor)
            .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            undoButton
            dismissButton
        }
    }

    private var undoButton: some View {
        Button("undo.action", action: undo)
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .accessibilityIdentifier("undoMutationButton")
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("undo.dismiss")
        .accessibilityIdentifier("dismissUndoBannerButton")
    }

    private var title: LocalizedStringKey {
        candidate.operation == .delete ? "undo.banner.deleted" : "undo.banner.saved"
    }

    private var detail: String {
        "\(candidate.entry.entry.kind.localizedName) · \(DurationText.format(minutes: candidate.entry.entry.minutes))"
    }

    private var accessibilityDetail: String {
        String(
            format: String(localized: "undo.banner.accessibility"),
            candidate.entry.entry.kind.localizedName,
            DurationText.format(minutes: candidate.entry.entry.minutes),
            AppDateText.day(candidate.entry.entry.day)
        )
    }
}
