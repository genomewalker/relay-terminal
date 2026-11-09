import AppKit
import SwiftUI
import XCTest
@testable import Relay

/// Offscreen renders of each Settings page in light and dark. These never open a
/// visible window; PNGs are written only when RELAY_SNAPSHOT_DIR is set.
@MainActor final class RelaySettingsRenderTests: XCTestCase {
    /// Sections that do not read host accounts or SSH state while rendering.
    static let renderedSections = ["general", "keyboard", "intelligence", "connections", "clients", "plugins", "advanced"]

    func testRendersEachSettingsSectionInLightAndDark() throws {
        let navigation = RelaySettingsNavigation.shared
        let preferences = RelayPreferences.shared
        let saved = (navigation.section, preferences.decisionModelPath, preferences.decisionModelSHA256)
        defer {
            navigation.section = saved.0
            preferences.decisionModelPath = saved.1
            preferences.decisionModelSHA256 = saved.2
        }
        preferences.decisionModelPath = ""
        preferences.decisionModelSHA256 = ""
        for section in Self.renderedSections {
            navigation.section = section
            let dark = try RelaySnapshot.render(RelaySettingsView().environment(\.colorScheme, .dark),
                                                name: "settings-\(section)", width: 940, appearance: .darkAqua)
            let light = try RelaySnapshot.render(RelaySettingsView().environment(\.colorScheme, .light),
                                                 name: "settings-\(section)", width: 940, appearance: .aqua)
            XCTAssertEqual(dark.size.height, 680, section)
            XCTAssertEqual(light.size.height, 680, section)
        }
    }
}

/// Copy and structure checks for the Settings window.
@MainActor final class RelaySettingsCopyTests: XCTestCase {
    static let jargon = ["relayd", "supervisor", "socket", "receipt", "shared binary"]

    func testVisibleLabelsAvoidInternalNames() {
        for label in RelaySettingsCopy.visibleLabels {
            for term in Self.jargon {
                XCTAssertFalse(label.lowercased().contains(term), "\"\(label)\" contains \"\(term)\"")
            }
        }
        // Technical names stay available to power users in tooltips.
        XCTAssertTrue(RelaySettingsCopy.autoUpdateHelperDetail.contains("relayd"))
        XCTAssertTrue(RelaySettingsCopy.connectionsExplanationDetail.contains("relayd"))
        XCTAssertTrue(RelaySettingsCopy.helperManagerSubtitleDetail.contains("relayd"))
    }

    /// The Miko entry is drawn once, in the sidebar footer shared by every page, and no
    /// page header carries Miko text. Checked by rendering each page with and without a
    /// workspace (the entry needs one) and comparing pixels region by region.
    func testAskMikoEntryRendersOnceInSidebarNotInPageHeader() throws {
        let navigation = RelaySettingsNavigation.shared
        let savedSection = navigation.section
        defer { navigation.section = savedSection }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-settings-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: directory)
        for section in RelaySettingsRenderTests.renderedSections {
            XCTAssertFalse(RelaySettingsCopy.description(section: section).contains("Miko"), section)
            navigation.section = section
            let with = try RelaySnapshot.render(RelaySettingsView(workspace: workspace), name: "miko-with",
                                                width: 940, appearance: .darkAqua).bitmap
            let without = try RelaySnapshot.render(RelaySettingsView(), name: "miko-without",
                                                   width: 940, appearance: .darkAqua).bitmap
            let scale = CGFloat(with.pixelsWide) / 940
            func differs(_ rect: NSRect) -> Bool {
                for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 2) {
                    for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 2)
                    where with.colorAt(x: x, y: y) != without.colorAt(x: x, y: y) { return true }
                }
                return false
            }
            // Bitmap rows run top-down: header is the top band right of the 176pt sidebar,
            // the entry sits in the sidebar footer above the "Relay" caption.
            XCTAssertFalse(differs(NSRect(x: 180, y: 0, width: 760, height: 110)), "page header of \(section)")
            XCTAssertTrue(differs(NSRect(x: 0, y: 560, width: 176, height: 90)), "sidebar entry on \(section)")
        }
    }
}
