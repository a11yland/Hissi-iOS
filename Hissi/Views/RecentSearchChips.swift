import SwiftUI

// Recent searches as tappable capsule chips (replaces the plain list rows).
// Tap re-runs the search; long-press offers deletion — plus the "Alle
// löschen" header button as the bulk path. A plain section: the recents
// screen (ContentView) owns the surrounding scroll view, so the nearby
// suggestions can sit above.
struct RecentSearchChips: View {
    @ObservedObject var recents: RecentSearchesStore
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Letzte Suchen")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.hissiTextSecondary)
                Spacer()
                if !recents.searches.isEmpty {
                    Button("Alle löschen") { recents.clear() }
                        .font(.caption)
                }
            }

            if recents.searches.isEmpty {
                Text("Deine letzten Suchbegriffe erscheinen hier.")
                    .font(.footnote)
                    .foregroundStyle(Color.hissiTextSecondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(recents.searches, id: \.self) { term in
                        chip(term)
                    }
                }
            }
        }
    }

    private func chip(_ term: String) -> some View {
        Button {
            onSelect(term)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(Color.hissiTextSecondary)
                    .accessibilityHidden(true)
                Text(term)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.hissiSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                recents.remove(term)
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }
}

// Minimal left-aligned wrapping layout for the chips — SwiftUI ships no
// flow container.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(subviews, in: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, position) in zip(subviews, arrange(subviews, in: bounds.width).positions) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

#Preview {
    RecentSearchChips(recents: RecentSearchesStore()) { _ in }
}
