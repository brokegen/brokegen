import AppKit
import SwiftUI

//struct Toolbar: NSViewRepresentable {
//    let toolbar = NSToolbar()
//
//    func makeNSView(context: Context) -> NSToolbar {
//        return self.toolbar
//    }
//
//    func updateNSView(_ nsView: NSToolbar, context: Context) {
//        // Update the toolbar items or styles here
//    }
//}

struct BigToolbar: View {
    var body: some View {
        // Real toolbar, to do things by default:
        HStack {
            Label("futureproof this", systemImage: "gear")
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
//        .background(Color.accentColor)
    }
}

#Preview {
    VStack {
        BigToolbar()
        NavigationView {
            Text("empty")
        }
    }
}
