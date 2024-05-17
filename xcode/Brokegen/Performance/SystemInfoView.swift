import SwiftUI

struct SystemTidbit: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct SystemInfoView: View {
    @State var tidbits = [
        SystemTidbit(label: "modelName", value: System.modelName()),
        SystemTidbit(label: "physicalCores", value: String(describing: System.physicalCores())),
        SystemTidbit(label: "logicalCores", value: String(describing: System.logicalCores())),
        SystemTidbit(label: "loadAverage", value: String(describing: System.loadAverage())),
        SystemTidbit(label: "machFactor", value: String(describing: System.machFactor())),
        SystemTidbit(label: "processCounts", value: String(describing: System.processCounts())),
        SystemTidbit(label: "physicalMemory", value: String(describing: System.physicalMemory())),
        SystemTidbit(label: "memoryUsage", value: String(describing: System.memoryUsage())),
        SystemTidbit(label: "uptime", value: String(describing: System.uptime())),
        SystemTidbit(label: "CPUPowerLimit", value: String(describing: System.CPUPowerLimit())),
        SystemTidbit(label: "thermalLevel", value: String(describing: System.thermalLevel())),
    ]

    var body: some View {
        List {
            HStack {
                Text("Last updated")
                    .font(.title2)
                Spacer()

                Text(String(describing: Date.now))
            }
            .padding(18)

            ForEach(tidbits) { tidbit in
                HStack {
                    Label(tidbit.label, systemImage: "bubble")
                    Spacer()

                    Text(tidbit.value)
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .padding(12)
                .lineLimit(4)
            }
            .onMove { indices, newOffset in
                tidbits.move(fromOffsets: indices, toOffset: newOffset)
            }
        }
        .frame(maxWidth: 800)
    }
}

#Preview {
    SystemInfoView(tidbits: [
        SystemTidbit(label: "Model name", value: "iPhone 16SE"),
        SystemTidbit(label: "System uptime", value: "(days: 3, hrs: 4, mins: 38)"),
    ])
}
