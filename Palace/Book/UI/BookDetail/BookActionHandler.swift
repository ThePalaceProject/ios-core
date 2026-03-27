//  BookActionHandler.swift
//  Palace
//
//  Extracted from BookDetailViewModel - handles borrow, download,
//  return, delete, read, listen actions.

import Foundation
import UIKit
import PalaceAudiobookToolkit

/// Encapsulates book action handling (download, return, read, reserve, etc.)
@MainActor
final class BookActionHandler {
    private let downloadCenter: MyBooksDownloadCenter
    private weak var viewModel: BookDetailViewModel?

    init(downloadCenter: MyBooksDownloadCenter = .shared) {
        self.downloadCenter = downloadCenter
    }

    func attach(to viewModel: BookDetailViewModel) {
        self.viewModel = viewModel
    }

    func handleAction(for button: BookButtonType) {
        guard let vm = viewModel else { return }
        guard !vm.isProcessing(for: button) else {
            Log.debug(#file, "Button \(button) is already processing, ignoring tap")
            return
        }
        vm.processingButtons.insert(button)

        switch button {
        case .reserve:
            didSelectReserve(for: vm.book) { [weak vm] in
                vm?.removeProcessingButton(button)
                vm?.showHalfSheet = false
            }

        case .return, .remove, .returning, .cancelHold:
            vm.bookState = .returning
            didSelectReturn(for: vm.book) { [weak vm] in
                vm?.removeProcessingButton(button)
                vm?.showHalfSheet = false
                vm?.isManagingHold = false
            }

        case .download, .get, .retry:
            vm.downloadProgress = 0
            didSelectDownload(for: vm.book)

        case .read, .listen:
            didSelectRead(for: vm.book) { [weak vm] in
                vm?.removeProcessingButton(button)
            }

        case .cancel:
            didSelectCancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak vm] in
                vm?.removeProcessingButton(button)
            }

        case .sample, .audiobookSample:
            didSelectPlaySample(for: vm.book) { [weak vm] in
                vm?.removeProcessingButton(button)
            }

        case .close:
            break

        case .manageHold:
            vm.isManagingHold = true
            vm.bookState = .holding
        }
    }

    private func ensureAuthAndExecute(_ action: @escaping () -> Void) {
        let businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: AccountsManager.shared.currentAccount?.uuid ?? "",
            libraryAccountsProvider: AccountsManager.shared,
            urlSettingsProvider: TPPSettings.shared,
            bookRegistry: TPPBookRegistry.shared,
            bookDownloadsCenter: MyBooksDownloadCenter.shared,
            userAccountProvider: TPPUserAccount.self,
            uiDelegate: nil,
            drmAuthorizer: nil
        )

        businessLogic.ensureAuthenticationDocumentIsLoaded { [weak self] (_: Bool) in
            DispatchQueue.main.async {
                guard let self = self else { return }

                let account = TPPUserAccount.sharedAccount()
                if account.needsAuth && !account.hasCredentials() {
                    self.viewModel?.showHalfSheet = false
                    SignInModalPresenter.presentSignInModalForCurrentAccount { [weak self] in
                        guard let self else { return }
                        guard TPPUserAccount.sharedAccount().hasCredentials() else {
                            Log.info(#file, "Sign-in cancelled or failed, not proceeding with action")
                            self.viewModel?.processingButtons.remove(.download)
                            self.viewModel?.processingButtons.remove(.get)
                            self.viewModel?.processingButtons.remove(.retry)
                            self.viewModel?.processingButtons.remove(.reserve)
                            return
                        }
                        action()
                    }
                    return
                }
                action()
            }
        }
    }

    func didSelectDownload(for book: TPPBook) {
        viewModel?.downloadProgress = 0
        ensureAuthAndExecute { [weak self] in
            self?.startDownloadAfterAuth(book: book)
        }
    }

    private func startDownloadAfterAuth(book: TPPBook) {
        viewModel?.bookState = .downloading
        viewModel?.showHalfSheet = true
        downloadCenter.startDownload(for: book)
    }

    func didSelectReserve(for book: TPPBook, completion: (() -> Void)? = nil) {
        ensureAuthAndExecute { [weak self] in
            guard self != nil else {
                completion?()
                return
            }
            Task {
                do {
                    _ = try await MyBooksDownloadCenter.shared.borrowAsync(book, attemptDownload: false)
                } catch {
                    Log.error(#file, "Failed to borrow book: \(error.localizedDescription)")
                }
                await MainActor.run {
                    completion?()
                }
            }
        }
    }

    func didSelectCancel() {
        guard let vm = viewModel else { return }
        downloadCenter.cancelDownload(for: vm.book.identifier)
        vm.downloadProgress = 0
    }

    func didSelectReturn(for book: TPPBook, completion: (() -> Void)?) {
        viewModel?.processingButtons.insert(.returning)
        downloadCenter.returnBook(withIdentifier: book.identifier) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.viewModel?.bookState = .unregistered
                self.viewModel?.processingButtons.remove(.returning)
                completion?()
            }
        }
    }

    @MainActor
    func didSelectRead(for book: TPPBook, completion: (() -> Void)?) {
        ensureAuthAndExecute { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                #if FEATURE_DRM_CONNECTOR
                let user = TPPUserAccount.sharedAccount()

                if user.hasCredentials() {
                    if user.hasAuthToken() {
                        self.openBook(book, completion: completion)
                        return
                    } else if AdobeCertificate.isDRMAvailable &&
                                !AdobeDRMService.shared.isUserAuthorized(user.userID, deviceID: user.deviceID) {
                        let reauthenticator = TPPReauthenticator()
                        reauthenticator.authenticateIfNeeded(user, usingExistingCredentials: true) {
                            Task { @MainActor in
                                guard user.hasCredentials() else {
                                    completion?()
                                    return
                                }
                                self.openBook(book, completion: completion)
                            }
                        }
                        return
                    }
                }
                #endif
                self.openBook(book, completion: completion)
            }
        }
    }

    @MainActor
    func openBook(_ book: TPPBook, completion: (() -> Void)?) {
        guard let vm = viewModel else { return }
        Log.debug(#file, "🎬 [OPEN BOOK] User requested to open book: \(book.title) (ID: \(book.identifier))")
        TPPCirculationAnalytics.postEvent("open_book", withBook: book)

        let resolvedBook = vm.registry.book(forIdentifier: book.identifier) ?? book
        let contentType = resolvedBook.defaultBookContentType

        Log.debug(#file, "  Content type determined: \(TPPBookContentTypeConverter.stringValue(of: contentType))")
        Log.debug(#file, "  Distributor: \(resolvedBook.distributor ?? "nil")")

        switch contentType {
        case .epub:
            Log.debug(#file, "  → Opening as EPUB")
            vm.processingButtons.removeAll()
            BookService.open(resolvedBook)
        case .pdf:
            Log.debug(#file, "  → Opening as PDF")
            vm.processingButtons.removeAll()
            BookService.open(resolvedBook)
        case .audiobook:
            Log.debug(#file, "  → Opening as AUDIOBOOK")
            BookService.open(resolvedBook) { [weak vm] in
                DispatchQueue.main.async {
                    vm?.processingButtons.removeAll()
                    completion?()
                }
            }
        default:
            Log.error(#file, "  ❌ UNSUPPORTED CONTENT TYPE - showing error to user")
            vm.processingButtons.removeAll()
            presentUnsupportedItemError()
        }
    }

    func didSelectPlaySample(for book: TPPBook, completion: (() -> Void)?) {
        guard let vm = viewModel else { return }
        guard !vm.isProcessingSample else { return }
        vm.isProcessingSample = true

        if book.defaultBookContentType == .audiobook {
            if book.sampleAcquisition?.type == "text/html" {
                SamplePreviewManager.shared.close()
                presentWebView(book.sampleAcquisition?.hrefURL)
                vm.isProcessingSample = false
                completion?()
            } else {
                SamplePreviewManager.shared.toggle(for: book)
                vm.isProcessingSample = false
                completion?()
            }
        } else {
            SamplePreviewManager.shared.close()
            EpubSampleFactory.createSample(book: book) { sampleURL, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let error = error {
                        Log.debug("Sample generation error for \(book.title): \(error.localizedDescription)", "")
                    } else if let sampleWebURL = sampleURL as? EpubSampleWebURL {
                        self.presentWebView(sampleWebURL.url)
                    } else if let sampleURL = sampleURL?.url {
                        let isEpubSample = book.sample?.type == .contentTypeEpubZip

                        if isEpubSample {
                            ReaderService.shared.openSample(book, url: sampleURL)
                        } else {
                            let web = BundledHTMLViewController(fileURL: sampleURL, title: book.title)
                            if let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
                                top.present(web, animated: true)
                            }
                        }
                    }
                    vm.isProcessingSample = false
                    completion?()
                }
            }
        }
    }

    private func presentWebView(_ url: URL?) {
        guard let url = url else { return }
        let webController = BundledHTMLViewController(
            fileURL: url,
            title: AccountsManager.shared.currentAccount?.name ?? ""
        )

        if let top = (UIApplication.shared.delegate as? TPPAppDelegate)?.topViewController() {
            top.present(webController, animated: true)
        }
    }

    func presentUnsupportedItemError() {
        guard let book = viewModel?.book else { return }
        Log.error(#file, "Unsupported item: \(book.title) (\(book.identifier)), type=\(TPPBookContentTypeConverter.stringValue(of: book.defaultBookContentType))")
        TPPErrorLogger.logError(withCode: .unexpectedFormat, summary: "Unsupported book format", metadata: [
            "book_id": book.identifier, "book_title": book.title,
            "distributor": book.distributor ?? "unknown",
            "content_type": TPPBookContentTypeConverter.stringValue(of: book.defaultBookContentType)
        ])
        Self.presentSimpleAlert(title: Strings.Error.formatNotSupportedError, message: Strings.Error.formatNotSupportedError)
    }

    func presentCorruptedItemError() {
        guard let book = viewModel?.book else { return }
        TPPErrorLogger.logError(withCode: .epubDecodingError, summary: "Corrupted EPUB item - cannot open book", metadata: [
            "book_id": book.identifier, "book_title": book.title, "distributor": book.distributor ?? "unknown"
        ])
        Self.presentSimpleAlert(title: Strings.Error.epubNotValidError, message: Strings.Error.epubNotValidError)
    }

    func presentDRMKeyError(_ error: Error) {
        guard let book = viewModel?.book else { return }
        TPPErrorLogger.logError(error, summary: "DRM key error - cannot decrypt content", metadata: [
            "book_id": book.identifier, "book_title": book.title, "error_description": error.localizedDescription
        ])
        Self.presentSimpleAlert(title: "DRM Error", message: error.localizedDescription)
    }

    private static func presentSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    }
}
