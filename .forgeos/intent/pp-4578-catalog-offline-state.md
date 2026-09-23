---
name: pp-4578-catalog-offline-state
created: 2026-06-24
author: claude-opus-4-8
---

## Summary

PP-4578: replace the catalog screen's generic connection-error state (which
offers a Reload that cannot succeed offline) with an offline-aware state. When
the catalog fails to load and the device has no connectivity, show an offline
state that explains downloaded books are still available and provides a "Go to
My Books" button — with NO Reload action. The catalog reloads automatically when
connectivity returns. Genuine online load failures keep the existing error +
Reload behavior. iOS only.

## Claims

- adds case `offline` to enum `CatalogState`
- adds stored `reachability: Reachability` dependency + `cancellables` to `CatalogViewModel`, injected via a defaulted init param (`= AppContainer.production().reachability`)
- adds `observeConnectivity()` in `CatalogViewModel.init` that subscribes to `reachability.connectivityPublisher`, filters to reconnect edges, and on reconnect calls `handleConnectivityRestored()`
- adds `handleConnectivityRestored()` that reloads via `forceRefresh()` only while state is `.offline`
- adds `loadFailureState(message:)` mapping a load failure to `.offline` when `reachability.isConnectedToNetwork()` is false, else `.error(message)`
- routes both `load()` failure sites (nil feed + thrown error) through `loadFailureState(message:)`
- adds `offlineView` to `CatalogView` (wifi.slash icon, title, message, "Go to My Books" button via `appContainer.tabRouterHub.navigate(to: .myBooks)`)
- adds `.offline` case to the `catalogStateView` switch in `CatalogView`
- adds localized strings `Strings.Catalog.offlineTitle`, `offlineMessage`, `offlineGoToMyBooks`
- adds accessibility identifiers `AccessibilityID.Catalog.offlineStateView` and `goToMyBooksButton`
- adds unit tests: offline-on-thrown-error, offline-on-nil-feed, online-failure-stays-error, reconnect-auto-reloads (via injected `MockReachability`)
- updates existing `createViewModel` test helper to inject a connected `MockReachability` so error-path tests are deterministic under the suite's `NoNetworkURLProtocol`

## Anti-claims

- does NOT add a Reload action to the offline state (the whole point — Reload cannot succeed offline)
- does NOT implement offline catalog browsing or catalog-content caching (out of scope)
- does NOT change offline reading/listening of downloaded books (already works)
- does NOT touch Android or CPW (iOS only)
- does NOT change the construction site `AppTabHostView.swift:74` — the new `reachability` init param is defaulted
- does NOT alter the generic `.error` rendering or the `forceRefresh()`/`refresh()` flows beyond routing failures to the offline branch
- does NOT modify `Reachability` itself or its publisher
- does NOT add a new connectivity polling mechanism — reuses the existing `connectivityPublisher`

## Files in scope

- Palace/CatalogUI/ViewModels/CatalogState.swift
- Palace/CatalogUI/ViewModels/CatalogViewModel.swift
- Palace/CatalogUI/Views/CatalogView.swift
- Palace/Utilities/Localization/Strings.swift
- Palace/Utilities/Testing/AccessibilityIdentifiers.swift
- PalaceTests/CatalogUI/CatalogViewModelTests.swift
