// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import UserNotifications
import VultureCore

/// Settings, by name, with their defaults. Views bind to them with @AppStorage(Preferences.…).
enum Preferences {
    static let showDeveloperFiles = "showDeveloperFiles"
    static let showStorageMap = "showStorageMap"
    static let notifyWhenLots = "notifyWhenLow"
    static let lowSpaceGB = "lowSpaceGB"
    static let keepDays = "keepDays"
    static let emptyEarly = "emptyEarlyWhenFull"
    static let recentDays = "skipRecentlyUsedDays"
    static let chooseCheckFirst = "chooseCheckFirstMyself"
    static let neverTouch = "neverTouchFolders"
    static let disabledRules = "disabledRules"
    static let autoCheck = "autoCheck"
    static let menuBarStats = "menuBarStats"
    static let lastCleanable = "lastCleanableBytes"
    static let lastAutoCheck = "lastAutoCheck"
    static let lastLotsNotice = "lastLotsNotice"
    static let lastLowSpaceNotice = "lastLowSpaceNotice"

    /// When "a lot to clean" is worth a notification.
    static let lotsThreshold: Int64 = 5_000_000_000
    /// "Empty early" starts below this much free space.
    static let almostFull: Int64 = 10_000_000_000

    static func register() {
        UserDefaults.standard.register(defaults: [
            showDeveloperFiles: true, showStorageMap: false, notifyWhenLots: true, lowSpaceGB: 20,
            keepDays: RecentlyRemoved.defaultKeepDays, emptyEarly: true, recentDays: 7, chooseCheckFirst: true,
            autoCheck: AutoCheck.never.rawValue, menuBarStats: "cpu",
        ])
    }

    private static var d: UserDefaults { .standard }

    static var keepDaysValue: Int { max(1, d.integer(forKey: keepDays)) }
    static var recentDaysValue: Int { d.integer(forKey: recentDays) }
    static var chooseCheckFirstValue: Bool { d.bool(forKey: chooseCheckFirst) }
    static var emptyEarlyValue: Bool { d.bool(forKey: emptyEarly) }

    static var neverTouchFolders: [URL] {
        get { (d.stringArray(forKey: neverTouch) ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue.map(\.path), forKey: neverTouch) }
    }

    static var disabledRuleIDs: Set<String> {
        get { Set(d.stringArray(forKey: disabledRules) ?? []) }
        set { d.set(newValue.sorted(), forKey: disabledRules) }
    }

    static func safetyPolicy(home: URL) -> SafetyPolicy {
        SafetyPolicy(home: home, alsoProtecting: neverTouchFolders)
    }

    enum AutoCheck: String, CaseIterable, Identifiable {
        case never, daily, weekly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: "Never"
            case .daily: "Every day"
            case .weekly: "Every week"
            }
        }
        var interval: TimeInterval? {
            switch self {
            case .never: nil
            case .daily: 86_400
            case .weekly: 7 * 86_400
            }
        }
    }

    static var autoCheckValue: AutoCheck { AutoCheck(rawValue: d.string(forKey: autoCheck) ?? "") ?? .never }

    /// Which numbers the menu bar item shows next to its icon.
    enum MenuStat: String, CaseIterable, Identifiable {
        case cpu, memory, disk, network
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cpu: "Processor"
            case .memory: "Memory"
            case .disk: "Free space"
            case .network: "Internet speed"
            }
        }
    }

    static var menuStats: Set<MenuStat> {
        get { Set((d.string(forKey: menuBarStats) ?? "").split(separator: ",").compactMap { MenuStat(rawValue: String($0)) }) }
        set { d.set(MenuStat.allCases.filter { newValue.contains($0) }.map(\.rawValue).joined(separator: ","), forKey: menuBarStats) }
    }
}

/// Quiet notifications: at most one a week for "lots to clean", one a day for low space.
enum Reminders {
    /// Notifications need a real app bundle; `swift run` has none.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func afterScan(cleanable: Int64, free: Int64) {
        let d = UserDefaults.standard
        d.set(cleanable, forKey: Preferences.lastCleanable)
        if d.bool(forKey: Preferences.notifyWhenLots), cleanable >= Preferences.lotsThreshold,
           isDue(Preferences.lastLotsNotice, every: 7 * 86_400) {
            post(id: "lots", title: "There's a lot to clean up",
                 body: "Vulture found \(formatBytes(cleanable)) of files apps make again. Open Vulture to free it up.")
            d.set(Date(), forKey: Preferences.lastLotsNotice)
        }
        checkFreeSpace(free)
    }

    static func checkFreeSpace(_ free: Int64) {
        let d = UserDefaults.standard
        let limit = Int64(d.integer(forKey: Preferences.lowSpaceGB)) * 1_000_000_000
        guard limit > 0, free > 0, free < limit, isDue(Preferences.lastLowSpaceNotice, every: 86_400) else { return }
        post(id: "low", title: "Your Mac is running low on space",
             body: "Only \(formatBytes(free)) is free. Vulture can show you what's safe to remove.")
        d.set(Date(), forKey: Preferences.lastLowSpaceNotice)
    }

    private static func isDue(_ key: String, every interval: TimeInterval) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: key) as? Date else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    private static func post(id: String, title: String, body: String) {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.interruptionLevel = .passive
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "vulture.\(id)", content: content, trigger: nil))
        }
    }
}
