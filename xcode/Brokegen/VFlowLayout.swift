import SwiftUI

struct VFlowLayout: Layout {
    let spacingX: CGFloat
    let spacingY: CGFloat

    init(spacing: CGFloat = 0) {
        // TODO: See what if there's an equivalent to Alignment()
        // that allows for more complex spacing considerations.
        self.spacingX = spacing
        self.spacingY = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for size in sizes {
            // Only include the spacing value if there's two or more items already.
            let potentialLineWidth: CGFloat = (
                (lineWidth > 0)
                ? lineWidth + spacingX + size.width
                : size.width
            )
            let potentialTotalHeight: CGFloat = (
                (totalHeight > 0)
                ? totalHeight + spacingY + lineHeight
                : lineHeight
            )

            // If it's too wide, push to the next line
            if potentialLineWidth > (proposal.width ?? 0) {
                totalHeight = potentialTotalHeight
                lineWidth = size.width
                lineHeight = size.height
            }
            else {
                lineWidth = potentialLineWidth
                lineHeight = max(lineHeight, size.height)
            }

            totalWidth = max(totalWidth, lineWidth)
        }

        totalHeight = (
            (totalHeight > 0)
            ? totalHeight + spacingY + lineHeight
            : lineHeight
        )

        return .init(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        var itemX: CGFloat = 0
        var itemY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for index in subviews.indices {
            var spaceredLineX: CGFloat = (
                // Add spacing only if we're not the first item
                (itemX > 0)
                ? itemX + spacingX
                : itemX
            )
            var spaceredLineY: CGFloat = (
                (itemY > 0)
                ? itemY + spacingY
                : itemY
            )

            if spaceredLineX + sizes[index].width > (proposal.width ?? 0) {
                itemY = spaceredLineY + lineHeight
                spaceredLineY = (
                    (itemY > 0)
                    ? itemY + spacingY
                    : itemY
                )
                lineHeight = 0

                itemX = 0
                spaceredLineX = 0
            }

            subviews[index].place(
                at: .init(
                    x: bounds.minX + spaceredLineX + sizes[index].width / 2,
                    y: bounds.minY + spaceredLineY + sizes[index].height / 2
                ),
                anchor: .center,
                proposal: ProposedViewSize(sizes[index])
            )

            lineHeight = max(lineHeight, sizes[index].height)
            itemX = spaceredLineX + sizes[index].width
        }
    }
}
