import Foundation

struct SidebarPreferencesSelection: Equatable {
    var organization: SidebarOrganization
    var sort: SidebarSort

    init(
        organization: SidebarOrganization = .byProject,
        sort: SidebarSort = .priority
    ) {
        self.organization = organization
        self.sort = sort
    }

    func merging(json: JSONValue) -> SidebarPreferencesSelection {
        let sidebar = json["sidebar"] ?? json
        return SidebarPreferencesSelection(
            organization: sidebar["organization"]?.stringValue
                .flatMap { SidebarOrganization(rawValue: $0) } ?? organization,
            sort: sidebar["sort"]?.stringValue
                .flatMap { SidebarSort(rawValue: $0) } ?? sort
        )
    }
}
