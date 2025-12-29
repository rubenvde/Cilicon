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

    var body: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading) {
                    ForEach(logger.logs) { chunk in
                        Text(ANSIParser.parse(logger.formattedLogLine(for: chunk)))
                            .id(chunk.id)
                    }
                }
                .textSelection(.enabled)
                .onChange(of: logger.logs) { _ in
                    if let lastLog = logger.logs.last {
                        scrollViewProxy.scrollTo(lastLog.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(5)
        .navigationTitle("Log - \(vmRunner?.machineConfig.id ?? "")")
    }
}
