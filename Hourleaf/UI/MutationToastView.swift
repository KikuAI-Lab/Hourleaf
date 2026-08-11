import SwiftUI

struct MutationToastView: View {
    let candidate: EntryUndoCandidate

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: candidate.operation == .delete ? "trash.fill" : "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(iconColor, in: Circle())
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mutationToast")
    }

    private var iconColor: Color {
        candidate.operation == .delete ? .orange : .green
    }

    private var title: LocalizedStringKey {
        candidate.operation == .delete ? "undo.banner.deleted" : "entry.saved"
    }
}
