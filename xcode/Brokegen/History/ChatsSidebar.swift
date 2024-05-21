import SwiftUI

struct ChatsSidebar: View {
    var body: some View {
        // Generic chats
        Text("Chats")
            .font(.title3)
            .foregroundStyle(.primary)

        Section(header: Text("Pinned")) {
            Text("What did people do before ski masks")
            Text("How do you spell 60")
            Text("دمك ثقيل")
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }

        Section(header: Text("2024-05")) {
            Label("Today's topic: Avogadro", systemImage: "pills")
            Text("Yesterday's topic")
        }
        .collapsible(false)

        Section(header: Text("Earlier…")) {
            Text("Last quarter: Lakers")
        }

        VStack(alignment: .trailing) {
            NavigationLink(destination: NavigationView {
                    PlaceholderContentView()
                    PlaceholderContentView()
                }
                .toolbar{
                    ToolbarItem(placement: .navigation) {
                        Label("Settings", systemImage: "gear")
                    }
                }
            ) {
                Text("[Load more…]")
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity)

        Divider()
            .padding(.leading, -8)
            .padding(.trailing, -8)

        // Agent-y chats
        Text("Agents")
            .font(.title3)

        Section(header: Text("SillyTavern")) {
            NavigationLink(destination: PlaceholderContentView()) {
                Text("Vernisite -- SillyTavern")
            }
            Text("IRC for lonely hearts")
        }

        Button(action: toggleSidebar, label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        })

        Spacer()

        // Non-chatlike completions
        Text("Prompt Engineering")

        Text("Pure raw")
        Text("Template-provided raw")
        NavigationLink(destination: SystemInfoView()) {
            Text("Augmented Raw Prompts")
        }
    }
}
