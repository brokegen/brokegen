import AppKit
import SwiftUI

struct RibbonView: View {
    let bigText: String

    init(_ bigText: String?) {
        self.bigText = bigText ?? "🥺🥺"
    }

    var body: some View {
        HStack {
            Text(bigText)
                .font(.largeTitle)
                .lineLimit(6)
                .monospaced()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .frame(idealHeight: 120)
    }
}

#Preview {
    VStack {
        RibbonView(nil)
        NavigationView {
            EmptyView()
        }
    }
}
