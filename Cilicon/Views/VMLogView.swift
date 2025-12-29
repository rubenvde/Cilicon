import SwiftUI
import Virtualization

struct VMLogView: View {
    var coreApp: CiliconCoreApp

    let vmId: VMRunner.ID

    var vmRunner: VMRunner? {
        coreApp.vmRunners.first(where: { $0.id == vmId })
    }

    var logger: SSHLogger {
        vmRunner!.sshLogger
    }

    @State private var refreshID = UUID()

    var body: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading) {
                    ForEach([logger], id: \.combinedLog) {
                        Text($0.attributedLog)
                    }
                }
                .textSelection(.enabled)
                .onReceive(logger.$log) { _ in
                    refreshID = UUID()
                    scrollViewProxy.scrollTo(logger.combinedLog, anchor: .bottom)
                }
            }
        }
        .padding(5)
        .navigationTitle("Log - \(vmRunner?.machineConfig.id ?? "")")
        .id(refreshID)
    }
}
