import Foundation

extension HomeModel {

    /// The TV tells Siri its titles after Home loads (`SiriIntents.swift`, #77). Siri on the iPhone comes with its own
    /// slice, so here Home's refresh asks nothing of Siri.
    func refreshTitleCatalog() async {}
}
