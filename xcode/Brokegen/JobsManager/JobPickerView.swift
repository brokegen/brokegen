import SwiftUI


func layout(
    sizes: [CGSize],
    spacingX: CGFloat,
    spacingY: CGFloat,
    containerWidth: CGFloat
) -> (offsets: [CGPoint], size: CGSize) {
    var offsetResults: [CGPoint] = []
    var currentPosition: CGPoint = .zero

    var currentLineHeight: CGFloat = 0
    var overallMaxWidth: CGFloat = 0

    print("Starting FlowLayout: width \(containerWidth), \(sizes.count) viewSizes")
    for viewSize in sizes {
//        print("FlowLayout currently at position: \(currentPosition)")
//        print("FlowLayout parsing viewSize: \(viewSize.width)x\(viewSize.height)")

        // On a new line, reset the per-line counters
        if currentPosition.x + viewSize.width > containerWidth {
            currentPosition.x = 0
            currentPosition.y += currentLineHeight + spacingY
            currentLineHeight = 0
        }

        offsetResults.append(currentPosition)

        currentPosition.x += viewSize.width
        overallMaxWidth = max(overallMaxWidth, currentPosition.x)
        currentPosition.x += spacingX

        // TODO: THe heights in a FlowLayout aren't computed correctly, figure out why.
//        currentLineHeight = max(currentLineHeight, viewSize.height)
    }

    print("Result: \(overallMaxWidth), \(currentPosition) + \(currentLineHeight)")
    print("")

    return (offsetResults,
            .init(width: overallMaxWidth,
                  height: currentPosition.y + currentLineHeight))
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 72

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        let sizes = subviews.map {
            $0.sizeThatFits(.unspecified)
        }

        return layout(sizes: sizes,
                      spacingX: spacing,
                      spacingY: spacing,
                      containerWidth: containerWidth).size
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let sizes = subviews.map {
            $0.sizeThatFits(.unspecified)
        }
        let offsets = layout(sizes: sizes,
                             spacingX: spacing,
                             spacingY: spacing,
                             containerWidth: bounds.width).offsets

        for (offset, subview) in zip(offsets, subviews) {
            subview.place(at: .init(x: offset.x + bounds.minX,
                                    y: offset.y + bounds.minY),
                          proposal: .unspecified)
        }
    }
}

struct JobPickerView: View {
    let jobs: [BaseJob]

    init(_ jobs: [BaseJob]) {
        self.jobs = jobs
    }

    var body: some View {
        FlowLayout() {
            ForEach(jobs) { job in
                NavigationLink(destination: JobOutputView(job: job)) {
                    JobsSidebarItem(job: job)
                        .padding(24)
                }
            }
        }
        .frame(maxWidth: 800)
    }
}
