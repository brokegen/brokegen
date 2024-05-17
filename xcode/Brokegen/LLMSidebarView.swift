import SwiftUI

struct LLMSidebarView: View {
    @Environment(ManagedProcessService.self) private var managedProcessService

    var body: some View {
        NavigationView {
            VStack {
                List {
                    NavigationLink(destination: SystemInfoView()) {
                        Text("System Info")
                            .font(.title2)
                    }
                    .padding(6)

                    Divider()

                    Section(header:
                        Text("Processes")
                            .font(.title2)
                            .foregroundStyle(.primary)
                    ) {
                        ForEach(managedProcessService.knownJobs) { job in
                            NavigationLink(destination: ProcessOutputView(job)) {
                                Text(job.makeTitle())
                                    .font(.title2)
                            }
                        }
                    }

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
                .listStyle(.sidebar)
                .frame(minWidth: 300, idealWidth: 400, maxHeight: .infinity)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button(action: toggleSidebar, label: {
                            Image(systemName: "sidebar.left")
                        })

                        Button("New Chat", systemImage: "square.and.pencil") {
                            toggleSidebar()
                        }
                        .buttonStyle(.accessoryBar)
                        .help("New Chat (⌘ + N)")
                        .frame(alignment: .trailing)
                    }
                }

                VStack(alignment: .trailing) {
                    Divider()
                    Group {
                        Text("Settings")
                            .font(.title2)
                            .foregroundStyle(.secondary)

                        NavigationLink(destination: PlaceholderContentView("INFERENCE")) {
                            Label("Inference", systemImage: "slider.horizontal.3")
                                .font(.title3)
                        }
                        NavigationLink(destination: PlaceholderContentView("RETRIEVAL")) {
                            Label("Retrieval", systemImage: "slider.horizontal.3")
                                .font(.title3)
                        }
                        NavigationLink(destination: PlaceholderContentView("AGENCE")) {
                            Label("A gents", systemImage: "slider.horizontal.3")
                                .font(.title3)
                        }

                        Button(action: toggleSidebar) {
                            Text("Agents")
                        }
                        .padding(12)
                    }
                    .padding(6)
                }
            }

            VStack {
                BigToolbar("[faux toolbar]")
                PlaceholderContentView()
            }
        }
    }
}

// Toggle Sidebar Function
func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
}

#Preview(traits: .fixedLayout(width: 1024, height: 1024)) {
    LLMSidebarView()
}
