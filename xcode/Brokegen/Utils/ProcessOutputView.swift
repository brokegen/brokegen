import SwiftUI

struct ProcessOutputView: View {
    @State private var headerText: String
    @Binding private var text: String

    init(headerText: String, text: Binding<String>) {
        self.headerText = headerText
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(headerText)
                .font(.headline)
            Text(text)
                .monospaced()
        }
        .padding()
    }

    public func text(_ text: String) -> ProcessOutputView {
        let view = self
        view.text = text

        return view
    }
}

#Preview {
    struct ViewHolder: View {
        @State private var sampleText = """
        +-o Root  <class IORegistryEntry, id 0x100000100, retain 38>
        +-o J316cAP  <class IOPlatformExpertDevice, id 0x100000275, registered, matched, active, busy 0 (659599 ms), retain 41>
          {
            "manufacturer" = <"Apple Inc.">
            "compatible" = <"J316cAP","MacBookPro18,2","AppleARM">
            "model" = <"MacBookPro18,2">
          }
        """

        var body: some View {
            ProcessOutputView(
                headerText: "/usr/sbin/ioreg -c IOPlatformExpertDevice -d 2",
                text: $sampleText)
        }
    }

    return ViewHolder()
}
