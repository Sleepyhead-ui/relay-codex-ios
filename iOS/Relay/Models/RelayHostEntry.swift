import Foundation

struct RelayHostEntry: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var endpoint: String
    var workingDirectory: String

    init(id: String = UUID().uuidString, configuration: HostConfiguration) {
        self.id = id
        name = configuration.name
        endpoint = configuration.endpoint
        workingDirectory = configuration.workingDirectory
    }

    var configuration: HostConfiguration {
        HostConfiguration(name: name, endpoint: endpoint, workingDirectory: workingDirectory)
    }
}
