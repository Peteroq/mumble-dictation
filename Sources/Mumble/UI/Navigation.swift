import Observation

/// Which page the main window is showing.
///
/// Held outside the view because two things now open the settings page — the gear on the
/// transport card and ⌘, from the menu bar — and one of them is a `Scene`-level command with
/// no path into the view's own state.
@MainActor
@Observable
final class Navigation {
    static let shared = Navigation()

    var section: MainWindow.Section = .transcriptions

    private init() {}
}
