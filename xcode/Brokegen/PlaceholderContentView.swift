import SwiftUI

struct PlaceholderContentView: View {
    let headerText: String

    init(_ headerText: String? = nil) {
        self.headerText = headerText ?? "[faux header]"
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(self.headerText)
                .font(.headline)
            Text("content 1 2 3 4 億貳參肆")
                .monospaced()
        }
        .padding()
        .toolbar {
            ToolbarItem {
                Text("big button")
            }
        }
    }
}

#Preview {
    PlaceholderContentView()
}
