import SwiftUI

struct SystemTidbit: Identifiable {
    let id = UUID()
    let label: String
    let value: String

    init(_ label: String, _ value: Any) {
        self.init(label: label, value: String(describing: value))
    }

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

struct SystemInfoView: View {
    @State var tidbits = [
        SystemTidbit("modelName", System.modelName()),
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

    func addGpuTidbits() {
        if let device: MTLDevice = MTLCreateSystemDefaultDevice() {
            tidbits.append(
                SystemTidbit("MTLDevice.counterSets", device.counterSets as Any)
                )
            tidbits.append(
                SystemTidbit("MTLDevice.currentAllocatedSize", device.currentAllocatedSize)
                )
            tidbits.append(
                SystemTidbit("MTLDevice.hasUnifiedMemory", device.hasUnifiedMemory)
                )
            tidbits.append(
                SystemTidbit("MTLDevice.maxTransferRate", device.maxTransferRate)
                )
            tidbits.append(
                SystemTidbit("MTLDevice.recommendedMaxWorkingSetSize", device.recommendedMaxWorkingSetSize)
                )
        }
    }

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

            Divider()
        }
        .frame(maxWidth: 800)
        .onAppear {
            addGpuTidbits()
        }
    }
}

#Preview {
    SystemInfoView(tidbits: [
        SystemTidbit(label: "Model name", value: "iPhone 16SE"),
        SystemTidbit(label: "System uptime", value: "(days: 3, hrs: 4, mins: 38)"),
    ])
}
