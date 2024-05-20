import AppKit
import SwiftUI

struct RibbonView: View {
    let bigText: String

    @State var expandView: Bool = false

    init(_ bigText: String?) {
        self.bigText = bigText ?? "🥺🥺"
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

            /// TODO: Figure out how to make a ZStack element that doesn't consume all space
//            HStack {
//                Spacer()
//
//                VStack {
//                    Button(
//                        expandView ? "Expanded" : "Collapsed",
//                        systemImage: expandView ? "chevron.down" : "chevron.left"
//                    ) {
//                        // TODO: This doesn't work
//                        // _ = self.expandView(!expandView)
//                    }
//
//                    Spacer()
//                }
//            }
        }
    }

    func expandView(_ expandView: Bool) -> RibbonView {
        let view = self
        view.expandView = expandView
        return view
    }
}

#Preview {
    VStack {
        RibbonView(
            "/System/Volumes/Data/Library\n" +
            "shrink the inappropriately long string, split across multiple lines\n" +
            "(🥺🥺 remember to check your kerning 🥺🥺)"
        )
        .expandView(false)

        List {
            Text("1\n2\n3\n4\n5\n")
            Spacer()
        }
    }
    .frame(height: 200)
}

#Preview {
    VStack {
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
