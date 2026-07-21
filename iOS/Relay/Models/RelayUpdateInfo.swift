import Foundation

struct RelayUpdateInfo: Equatable {
    let currentVersion: String
    let latestVersion: String
    let available: Bool
    let releaseURL: URL?
    let notes: String

    init(json: JSONValue) {
        currentVersion = json["currentVersion"]?.stringValue ?? ""
        latestVersion = json["latestVersion"]?.stringValue ?? ""
        available = json["available"]?.boolValue ?? false
        releaseURL = json["releaseUrl"]?.stringValue.flatMap(URL.init(string:))
        notes = json["notes"]?.stringValue ?? ""
    }
}
