import Citadel
import Foundation

/// The Buildkite Provisioner
class BuildkiteAgentProvisioner: Provisioner {
    let config: BuildkiteAgentProvisionerConfig

    init(config: BuildkiteAgentProvisionerConfig) {
        self.config = config
    }

    func provision(sshClient: SSHClient, sshLogger: SSHLogger) async throws {
        let command = """
        sudo su - buildkite-agent -c \"buildkite-agent start --token \(config.agentToken) --tags \(config.tags.joined(separator: ","))\"
        """
        
        let streamOutput = try await sshClient.executeCommandStream(command, inShell: true)
        for try await blob in streamOutput {
            switch blob {
            case let .stdout(stdout):
                await sshLogger.log(string: String(buffer: stdout))
            case let .stderr(stderr):
                await sshLogger.log(string: String(buffer: stderr))
            }
        }
    }
}
