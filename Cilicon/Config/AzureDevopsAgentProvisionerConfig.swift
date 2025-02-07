import Foundation

struct AzureAgentProvisionerConfig: Decodable {
    let url: String
    let personalToken: String
    let poolName: String
    let agentName: String
    let agentVersion: String

    enum CodingKeys: CodingKey {
        case url
        case personalToken
        case poolName
        case agentName
        case agentVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.personalToken = try container.decode(String.self, forKey: .personalToken)
        self.poolName = try container.decode(String.self, forKey: .poolName)
        self.agentName = try container.decode(String.self, forKey: .agentName)
        self.agentVersion = try container.decode(String.self, forKey: .agentVersion)
    }
}
