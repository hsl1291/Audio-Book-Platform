import CarPlay
import SwiftData
import BacklistCore

/// The library on the car's screen.
///
/// Inert until Apple grants the CarPlay audio entitlement: without it the system
/// never connects this scene, and the app still works in the car through Now
/// Playing and the steering-wheel controls, which need no entitlement. With it,
/// this adds what is otherwise missing — choosing a book from the car's screen.
///
/// Lists are kept short and glanceable, as CarPlay requires. Private books never
/// appear: a car screen is visible to passengers.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private let continueList = CPListTemplate(title: "Continue", sections: [])
    private let libraryList = CPListTemplate(title: "Waiting", sections: [])
    /// Items by book, so artwork loaded later can find its row without the row
    /// itself (not Sendable) being handed to another task.
    private var items: [UUID: CPListItem] = [:]

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        continueList.tabImage = UIImage(systemName: "play.circle")
        libraryList.tabImage = UIImage(systemName: "books.vertical")
        continueList.emptyViewTitleVariants = ["Nothing in progress"]
        libraryList.emptyViewTitleVariants = ["No downloaded books"]

        reload()
        let tabs = CPTabBarTemplate(templates: [continueList, libraryList])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Lists

    private func reload() {
        items = [:]
        let context = AppServices.shared.container.mainContext
        let works = ((try? LibraryStore(context: context).allWorks()) ?? [])
            .filter { $0.isWaitingToRead && $0.hasPlayableCopy && !$0.isPrivate }

        let reading = works
            .filter { $0.shelf == .reading }
            .sorted { lastPlayed($0) > lastPlayed($1) }
        // Driving is not the moment to wait for a 400 MB download, so the library
        // tab lists only what is already on the phone.
        let onDevice = works
            .filter { $0.shelf != .reading && isOnDevice($0) }
            .sorted { $0.addedAt > $1.addedAt }

        continueList.updateSections([section(reading)])
        libraryList.updateSections([section(onDevice)])
    }

    private func section(_ works: [StoredWork]) -> CPListSection {
        let limit = CPListTemplate.maximumItemCount
        let rows = works.prefix(limit).map { item(for: $0) }
        return CPListSection(items: Array(rows))
    }

    private func item(for work: StoredWork) -> CPListItem {
        let item = CPListItem(
            text: work.title,
            detailText: work.authors.first,
            image: nil
        )
        item.accessoryType = isOnDevice(work) ? .none : .cloud

        let id = work.identifier
        item.handler = { [weak self] _, completion in
            completion()
            Task { @MainActor in await self?.play(id) }
        }

        items[id] = item
        if let key = work.coverCacheKey {
            Task { @MainActor [weak self] in
                guard let image = await CoverCache.shared.image(forKey: key) else { return }
                self?.items[id]?.setImage(image)
            }
        }
        return item
    }

    // MARK: - Actions

    private func play(_ id: UUID) async {
        let context = AppServices.shared.container.mainContext
        guard let work = ((try? LibraryStore(context: context).allWorks()) ?? [])
            .first(where: { $0.identifier == id })
        else { return }

        await AppServices.shared.playback.play(work)
        interfaceController?.pushTemplate(
            CPNowPlayingTemplate.shared, animated: true, completion: nil
        )
        reload()
    }

    // MARK: - Helpers

    private func isOnDevice(_ work: StoredWork) -> Bool {
        (work.copies ?? []).contains { $0.isPlayable && $0.availability == .downloaded }
    }

    private func lastPlayed(_ work: StoredWork) -> Date {
        (work.copies ?? []).compactMap(\.lastPlayedAt).max() ?? .distantPast
    }
}
