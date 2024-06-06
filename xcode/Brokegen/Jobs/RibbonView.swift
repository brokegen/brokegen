import AppKit
import SwiftUI

struct RibbonView: View {
    let bigText: String

    @State var expandView: Bool
    @State var currentCenter: CGPoint

    init(_ bigText: String?) {
        self.bigText = bigText ?? "🥺🥺"

        _expandView = .init(initialValue: false)
        _currentCenter = .init(initialValue: .zero)
    }

    var body: some View {
        ZStack {
            HStack {
                Text(bigText)
                    .font(.largeTitle)
                    .lineLimit(expandView ? 6 : 2)
                    .monospaced()
                    .lineSpacing(20)
                Spacer()
            }
            .frame(maxHeight: expandView ? 400 : 120)
            .frame(maxWidth: .infinity)
            .padding([.top, .bottom], 32)
            .padding([.leading, .trailing], 16)
        }
    }

    func expandView(_ expandView: Bool) -> RibbonView {
        let view = self
        view.expandView = expandView
        return view
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    VStack {
        RibbonView(
            "/System/Volumes/Data/Library\n" +
            "shrink the inappropriately long string, split across multiple lines\n" +
            "(🥺🥺 remember to check your kerning 🥺🥺)"
        )
        .expandView(false)

        Divider()

        RibbonView(
            "/System/Volumes/Data/Library\n" +
            "inappropriately long string, split across multiple lines\n" +
            "(🥺🥺 remember to check your kerning 🥺🥺)"
        )
        .expandView(true)
        List {
            Text("text 1")
            Text("text 2")
            Text("text 4")
            Text("text 8")
        }
    }
    .frame(height: 800)
}

#Preview {
    VStack {
        RibbonView(nil)
        NavigationView {
            EmptyView()
        }
    }
}
