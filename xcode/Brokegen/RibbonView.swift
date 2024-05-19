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
        }
        .frame(maxWidth: .infinity)
        .frame(idealHeight: 120)
        .padding(24)
    }
}

#Preview {
    VStack {
        RibbonView("faux")
        NavigationView {
            Text("empty")
        }
    }
}
