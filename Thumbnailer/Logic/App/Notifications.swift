/*
 
 Notifications.swift
 Thumbnailer
 
 Notification Handler
 
 George Babichev
 
 */

import SwiftUI
import UserNotifications

// One-time install guard for foreground badge auto-clear
fileprivate var _badgeObserverInstalled = false

// MARK: - Notification helpers

/// Clears Dock badge, and (when available) Notification Center badge count.
@MainActor
func clearAppBadge() {
    NSApplication.shared.dockTile.badgeLabel = nil
    if #available(macOS 13.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}

@MainActor private func _clearDockBadge() {
    NSApplication.shared.dockTile.badgeLabel = nil
}

/// Installs a listener that clears the Dock badge whenever the app becomes active.
/// Safe to call multiple times.
@MainActor
func ensureBadgeAutoClearInstalled() {
    guard !_badgeObserverInstalled else { return }
    _badgeObserverInstalled = true
    NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
    ) { _ in
        Task { @MainActor in _clearDockBadge() }
        if #available(macOS 13.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
    }
}

@MainActor
func clearDeliveredNotifications() {
    let center = UNUserNotificationCenter.current()
    center.removeAllDeliveredNotifications()     // removes this app’s delivered items from Notification Center
    if #available(macOS 13.0, *) {
        center.setBadgeCount(0)                  // also resets Notification Center badge count
    }
}

