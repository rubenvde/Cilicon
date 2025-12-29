import Citadel
import Foundation
import Semaphore
import Virtualization

let vmSemaphore = AsyncSemaphore(value: 1)
@MainActor
@Observable
class VMRunner: NSObject, Identifiable, VZVirtualMachineDelegate {
    var state: State = .idle
    let provisioner: Provisioner?
    let config: Config
    let machineConfig: MachineConfig
    let fileManager = FileManager()
    let macAddress: VZMACAddress
    let sshLogger = SSHLogger()
    let id: String
    var livenessProbeTask: Task<Void, Never>?

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        print("did stop with error")
        print(error.localizedDescription)
    }

    init(config: Config, vmConfig: VMRunnerConfig) {
        switch vmConfig.machineConfig.provisioner {
        case let .github(githubConfig):
            self.provisioner = GithubActionsProvisioner(
                config: vmConfig.machineConfig,
                githubConfig: githubConfig
            )
        case let .gitlab(gitLabConfig):
            self.provisioner = GitLabRunnerProvisioner(config: gitLabConfig)
        case let .buildkite(buildkiteConfig):
            self.provisioner = BuildkiteAgentProvisioner(config: buildkiteConfig)
        case let .azure(azureConfig):
            self.provisioner = AzureDevopsAgentProvisioner(config: azureConfig)
        case let .script(scriptConfig):
            self.provisioner = ScriptProvisioner(runBlock: scriptConfig.run)
        }
        self.config = config
        self.id = vmConfig.machineConfig.id
        self.machineConfig = vmConfig.machineConfig
        self.macAddress = VZMACAddress(string: vmConfig.macAddress)!
    }

    @MainActor
    func startVM(vm: VZVirtualMachine) async throws {
        await vmSemaphore.wait()
        defer { vmSemaphore.signal() }
        try await vm.start()
    }

    @MainActor
    func stopVM(vm: VZVirtualMachine) async throws {
        await vmSemaphore.wait()
        defer { vmSemaphore.signal() }
        guard vm.canStop else { return }
        try await vm.stop()
    }

    var runTask: Task<Void, Error>?
    func forceStop() {
        runTask?.cancel()
        runTask = nil
    }

    func start() async throws {
        let task = Task(priority: .background) {
            do {
                // Get Source
                setState(state: .fetching)
                let source = machineConfig.source
                let path = try await SourceManager.shared.getPath(source: source)
                // Clone Source
                setState(state: .cloning)
                let clonedURL = try cloneSource(at: path.path)
                // Run VM
                let bundle = VMBundle(url: clonedURL)
                let vmHelper = VMConfigHelper(vmBundle: bundle)
                let vmConfig = try vmHelper.computeRunConfiguration(
                    config: machineConfig,
                    macAddress: macAddress
                )
                let virtualMachine = VZVirtualMachine(configuration: vmConfig)
                virtualMachine.delegate = self
                try await startVM(vm: virtualMachine)
                setState(state: .running(virtualMachine, .connecting))
                let ip = try await fetchIP()
                try Task.checkCancellation()
                let client = try await createAndConnectSSHClient(ip: ip)

                if let preRun = machineConfig.preRun {
                    setState(state: .running(virtualMachine, .preRun))
                    try await provisioner?.runCommand(cmd: preRun, sshClient: client, sshLogger: sshLogger)
                }

                if let livenessProbe = machineConfig.provisioner.livenessProbe {
                    startLivenessProbe(livenessProbe: livenessProbe, virtualMachine: virtualMachine, ip: ip)
                }

                if let provisioner {
                    setState(state: .running(virtualMachine, .provisioning))
                    try await provisioner.provision(sshClient: client, sshLogger: sshLogger)
                }

                if let postRun = machineConfig.postRun {
                    setState(state: .running(virtualMachine, .postRun))
                    try await provisioner?.runCommand(cmd: postRun, sshClient: client, sshLogger: sshLogger)
                }
                
                livenessProbeTask?.cancel()
                livenessProbeTask = nil

                setState(state: .running(virtualMachine, .shutdown))
                try await stopVM(vm: virtualMachine)
                setState(state: .cleanup)
                try cleanup()
            } catch {
                setState(state: .failed(error.localizedDescription))
                throw error
            }
        }
        runTask = task

        switch await task.result {
        case .success:
            break
        case let .failure(err):
            if err is CancellationError {
                if case let .running(vm, _) = state {
                    try await stopVM(vm: vm)
                }
                try cleanup()
                setState(state: .canceled)
            } else {
                throw err
            }
        }
    }

    private func fetchIP() async throws -> String {
        var leaseTries = 0
        while true {
            try Task.checkCancellation()
            let ipResult = Result {
                try LeaseParser.leaseForMacAddress(mac: macAddress.string).ipAddress
            }
            switch ipResult {
            case let .success(ip):
                return ip
            case let .failure(err):
                if leaseTries >= 5 {
                    throw err
                }
                try await Task.sleep(for: .seconds(5))
                leaseTries += 1
            }
        }
    }

    var cloneDirectoryPath: String {
        config.clonePath ?? NSString("~/cilicon-clones/").expandingTildeInPath
    }

    var clonePath: String {
        cloneDirectoryPath + "/" + machineConfig.id + "/"
    }

    private func cloneSource(at source: String) throws -> URL {
        if !fileManager.fileExists(atPath: cloneDirectoryPath) {
            try fileManager.createDirectory(atPath: cloneDirectoryPath, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: clonePath) {
            try fileManager.removeItem(atPath: clonePath)
        }
        try fileManager.copyItem(atPath: source, toPath: clonePath)
        return URL(filePath: clonePath)
    }

    private func cleanup() throws {
        livenessProbeTask?.cancel()
        livenessProbeTask = nil
        try fileManager.removeItem(atPath: clonePath)
    }

    @MainActor
    func setState(state: State) {
        self.state = state
    }

    enum State {
        case fetching
        case idle
        case cloning
        case running(VZVirtualMachine, RunState)
        case stopping
        case cleanup
        case canceled
        case failed(String)

        var isRunning: Bool {
            if case .running = self {
                return true
            }
            return false
        }
    }

    enum RunState {
        case connecting
        case provisioning
        case preRun
        case postRun
        case shutdown
    }
    
    private func startLivenessProbe(livenessProbe: LivenessProbeConfig, virtualMachine: VZVirtualMachine, ip: String) {
        livenessProbeTask = Task {
            sshLogger.log(string: "[1;34mLiveness probe starting in \(livenessProbe.delay) seconds[0m\n")

            // Initial delay before starting probes
            try? await Task.sleep(for: .seconds(livenessProbe.delay))

            guard !Task.isCancelled else { return }

            sshLogger.log(string: "[1;34mLiveness probe active (interval: \(livenessProbe.interval)s)[0m\n")

            while !Task.isCancelled {
                do {
                    // Create a new SSH client for the probe
                    let probeClient = try await SSHClient.connect(
                        host: ip,
                        authenticationMethod: .passwordBased(
                            username: machineConfig.sshCredentials.username,
                            password: machineConfig.sshCredentials.password
                        ),
                        hostKeyValidator: .acceptAnything(),
                        reconnect: .never,
                        connectTimeout: .seconds(5)
                    )

                    // Execute the liveness probe command and check exit code
                    // We use a wrapper command that explicitly outputs the exit code
                    let wrappedCommand = "\(livenessProbe.command); echo \"EXIT_CODE:$?\""
                    let streamOutput = try await probeClient.executeCommandStream(wrappedCommand, inShell: true)

                    var outputBuffer = ""
                    for try await blob in streamOutput {
                        switch blob {
                        case let .stdout(stdout):
                            outputBuffer += String(buffer: stdout)
                        case .stderr:
                            break
                        }
                    }

                    try await probeClient.close()

                    // Extract exit code from output
                    var exitCode = 1
                    if let exitCodeMatch = outputBuffer.range(of: #"EXIT_CODE:(\d+)"#, options: .regularExpression) {
                        let exitCodeString = outputBuffer[exitCodeMatch].replacingOccurrences(of: "EXIT_CODE:", with: "")
                        exitCode = Int(exitCodeString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
                    }

                    guard exitCode == 0 else {
                        sshLogger.log(string: "[1;31mLiveness probe failed with exit code \(exitCode), restarting VM[0m\n")

                        // Cancel this task to prevent further probes
                        livenessProbeTask?.cancel()
                        livenessProbeTask = nil

                        // Stop and restart the VM
                        try await stopVM(vm: virtualMachine)
                        // No explicit handleStop needed, cancellation/stop will trigger restart logic in start()
                        return
                    }

                    // Wait for the next probe interval
                    try await Task.sleep(for: .seconds(livenessProbe.interval))
                } catch is CancellationError {
                    return
                } catch {
                    // Log SSH or command execution errors but don't restart
                    sshLogger.log(string: "[1;33mLiveness probe error (will retry): \(error.localizedDescription)[0m\n")
                    try? await Task.sleep(for: .seconds(livenessProbe.interval))
                }
            }
        }
    }

    private func createAndConnectSSHClient(ip: String) async throws -> SSHClient {
        sshLogger.log(string: "Waiting for VM to boot and SSH to be available...\n")
        let maxRetries = machineConfig.sshConnectMaxRetries
        var tries = 0

        while tries < maxRetries {
            do {
                let client = try await SSHClient.connect(
                    host: ip,
                    authenticationMethod: .passwordBased(
                        username: machineConfig.sshCredentials.username,
                        password: machineConfig.sshCredentials.password
                    ),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never,
                    connectTimeout: .seconds(5)
                )

                // Test if we can execute a simple command
                let token = "ssh-connected"
                let streamOutput = try await client.executeCommandStream("echo \(token)", inShell: true)
                var commandSuccessful = false

                for try await blob in streamOutput {
                    switch blob {
                    case let .stdout(stdout):
                        let output = String(buffer: stdout)
                        if output.contains(token) {
                            commandSuccessful = true
                        }
                    case .stderr:
                        break
                    }
                }

                if commandSuccessful {
                    sshLogger.log(string: "VM fully booted and SSH available\n")
                    return client
                }

                try await client.close()
            } catch {
                // SSH not ready yet, continue waiting
                tries += 1
                sshLogger.log(string: "SSH connect \(tries)/\(maxRetries): SSH not ready, waiting 5s...\n")
                try await Task.sleep(for: .seconds(5))
            }
        }

        throw VMRunnerError.sshConnectTimeout
    }
}

enum VMRunnerError: Error {
    case sshConnectTimeout
}

extension VMRunnerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .sshConnectTimeout:
            return "SSH Connect timeout"
        }
    }
}

struct VMRunnerConfig {
    let macAddress: String = VZMACAddress.randomLocallyAdministered().string
    let machineConfig: MachineConfig
}