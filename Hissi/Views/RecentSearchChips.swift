import SwiftUI

// Recent searches as tappable chips (replaces the plain list rows) in the
// same bordered, 44 pt style as the nearby button, so the screen's targets
// are one size. Tap re-runs the search; long-press offers deletion — the bulk
// path is the "Letzte Suchen löschen" button ContentView pins above the
// search field. A plain section: the recents screen (ContentView) owns the
// surrounding scroll view, so the nearby suggestions can sit above.
struct RecentSearchChips: View {
    @ObservedObject var recents: RecentSearchesStore
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Letzte Suchen")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.hissiTextSecondary)

            if recents.searches.isEmpty {
                NoticeCard(text: "Deine letzten Suchbegriffe erscheinen hier.", systemImage: "clock.arrow.circlepath")
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
            Label(term, systemImage: "clock.arrow.circlepath")
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.bordered)
        // 44 pt tall — WCAG 2.5.5 (AAA) target size, like the nearby button.
        .controlSize(.large)
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
// flow container. Each chip is offered the container's width, so a long
// term (or a large text size) wraps inside its chip instead of growing it
// past the screen.
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
                proposal: Self.chipProposal(in: bounds.width)
            )
        }
    }

    private static func chipProposal(in width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(Self.chipProposal(in: width))
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
