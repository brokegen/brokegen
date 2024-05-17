import AppKit
import SwiftUI

struct BigToolbar: View {
    let bigText: String

    init(_ bigText: String?) {
        self.bigText = bigText ?? "🥺🥺"
    }

    var body: some View {
        HStack {
            Text(bigText)
                .font(.largeTitle)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 100)
        .padding(24)
    }
}

#Preview {
    VStack {
        BigToolbar("faux")
        NavigationView {
            Text("empty")
        }
    }
}
