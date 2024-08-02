import SwiftUI

struct RibbonView: View {
    let bigText: String

    init(_ bigText: String) {
        self.bigText = bigText
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(bigText)
                .font(.largeTitle)
                .monospaced()
                .textSelection(.enabled)
                .lineSpacing(20)
                .layoutPriority(0.2)

            Spacer()
                .frame(minWidth: 0)
        }
        .padding([.top, .bottom], 32)
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    VStack {
        RibbonView(
            "/System/Volumes/Data/Library\n" +
            "shrink the inappropriately long string, split across multiple lines\n" +
            "(🥺🥺 remember to check your kerning 🥺🥺)"
        )

        Divider()

        RibbonView(
            "/System/Volumes/Data/Library\n" +
            "inappropriately long string, split across multiple lines\n" +
            "(🥺🥺 remember to check your kerning 🥺🥺)"
        )
        List {
            Text("text 1")
            Text("text 2")
            Text("text 4")
            Text("text 8")
        }
    }
    .frame(height: 800)
}
