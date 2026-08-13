import Foundation

struct PairingPayload: Equatable {
    let endpoint: String
    let token: String
    let computerName: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "relay",
              url.host?.lowercased() == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            if let value = item.value { result[item.name] = value }
        }
        guard let endpoint = values["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let token = values["token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              URL(string: endpoint).map({ ["ws", "wss"].contains($0.scheme?.lowercased() ?? "") }) == true,
              !token.isEmpty else { return nil }
        self.endpoint = endpoint
        self.token = token
        computerName = values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Windows 电脑"
    }
}
