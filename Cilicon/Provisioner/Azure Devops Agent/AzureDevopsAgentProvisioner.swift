import Citadel
import Foundation

/// The Azure DevOps Provisioner
class AzureDevopsAgentProvisioner: Provisioner {
    let url: String
    let personalToken: String
    let poolName: String
    let agentName: String
    let agentVersion: String
    init(config: AzureAgentProvisionerConfig) {
        self.url = config.url
        self.personalToken = config.personalToken
        self.poolName = config.poolName
        self.agentName = config.agentName
        self.agentVersion = config.agentVersion
    }
    func provision(sshClient: SSHClient, sshLogger: SSHLogger) async throws {
        // Define download URL and extraction command
        let downloadUrl = "https://vstsagentpackage.azureedge.net/agent/\(agentVersion)/vsts-agent-osx-arm64-\(agentVersion).tar.gz"
        let agentDir = "~/myagent"
        
        // Commands to download, extract, and configure the Azure DevOps agent
        let setupCommands = """
        mkdir -p \(agentDir) && cd \(agentDir)
        curl -sL \(downloadUrl) -o vsts-agent.tar.gz
        tar xzf vsts-agent.tar.gz
        ./config.sh --unattended --replace \
            --url \(url) \
            --auth pat \
            --token \(personalToken) \
            --pool \(poolName) \
            --agent \(agentName) && ./run.sh --once
        """
        // Execute commands on the remote machine
        let streamOutput = try await sshClient.executeCommandStream(setupCommands, inShell: true)
        for try await blob in streamOutput {
            switch blob {
            case let .stdout(stdout):
                sshLogger.log(string: String(buffer: stdout))
            case let .stderr(stderr):
                sshLogger.log(string: String(buffer: stderr))
            }
        }
    }
}
