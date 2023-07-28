//
//  AudiobookDataManager.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 03/07/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import ULID

fileprivate struct LibraryBook: Codable, Hashable {
  var bookId: String
  var libraryId: String
  
  init(bookId: String, libraryId: String) {
    self.bookId = bookId
    self.libraryId = libraryId
  }
  
  init(time: AudiobookTimeEntry) {
    self.init(bookId: time.bookId, libraryId: time.libraryId)
  }
}

fileprivate struct RequestData: Codable {
  
  struct TimeEntry: Codable {
    let id: String
    let duringMinute: String
    let secondsPlayed: Int
    
    init(id: String, duringMinute: String, secondsPlayed: Int) {
      self.id = id
      self.duringMinute = duringMinute
      self.secondsPlayed = secondsPlayed
    }
    
    init(time: AudiobookTimeEntry) {
      self.id = time.id
      self.duringMinute = time.duringMinute
      self.secondsPlayed = Int(time.duration)
    }
  }
  
  let libraryId: String
  let bookId: String
  let timeEntries: [TimeEntry]
  
  enum CodingKeys: String, CodingKey {
      case libraryId = "library_id"
      case bookId = "book_id"
      case timeEntries
  }
  
  init(libraryId: String, bookId: String, timeEntries: [TimeEntry]) {
    self.libraryId = libraryId
    self.bookId = bookId
    self.timeEntries = timeEntries
  }
  
  init(libraryBook: LibraryBook, timeEntries: [AudiobookTimeEntry]) {
    self.libraryId = libraryBook.libraryId
    self.bookId = libraryBook.bookId
    self.timeEntries = timeEntries.map { TimeEntry(time: $0) }
  }
  
  var jsonRepresentation: Data? {
    return try? JSONEncoder().encode(self)
  }
}

fileprivate struct ResponseData: Codable {
  
  struct ResponseEntry: Codable {
    let status: Int
    let message: String
    let id: String
  }

  let responses: [ResponseEntry]
  
  init(responses: [ResponseEntry]) {
    self.responses = responses
  }
  
  init?(data: Data) {
    guard let value = try? JSONDecoder().decode(ResponseData.self, from: data) else {
      return nil
    }
    self.init(responses: value.responses)
  }
}

fileprivate struct AudiobookDataManagerStore: Codable {
  var urls: [LibraryBook: URL] = [:]
  var queue: [AudiobookTimeEntry] = []
  
  init() { }
  
  init?(data: Data) {
    guard let value = try? JSONDecoder().decode(AudiobookDataManagerStore.self, from: data) else {
      return nil
    }
    self = value
  }
  
  var jsonRepresentation: Data? {
    try? JSONEncoder().encode(self)
  }
}


class AudiobookDataManager {
  static let shared = AudiobookDataManager()
  private let syncTimeInterval: TimeInterval = 60
  private var subscriptions: Set<AnyCancellable> = []
  
  private var store = AudiobookDataManagerStore()
  
  init() {
    Timer.publish(every: syncTimeInterval, on: .main, in: .default)
      .autoconnect()
      .sink(receiveValue: syncValues)
      .store(in: &subscriptions)

    NotificationCenter.default.publisher(for: .TPPReachabilityChanged)
      .receive(on: RunLoop.main)
      .sink(receiveValue: reachabilityStatusChanged)
      .store(in: &subscriptions)

    loadStore()
  }

  func save(time: AudiobookTimeEntry) {
    store.urls[LibraryBook(time: time)] = time.timeTrackingUrl
    store.queue.append(time)
    saveStore()
  }
  
  private func reachabilityStatusChanged(_ notification: Notification) {
    if let isConnected = notification.object as? Bool, isConnected {
      syncValues()
    }
  }
  
  private func syncValues(_: Date? = nil) {
    let queuedLibraryBooks: Set<LibraryBook> = Set(store.queue.map { LibraryBook(time: $0) })
    for libraryBook in queuedLibraryBooks {
      let requestData = RequestData(
        libraryBook: libraryBook,
        timeEntries: store.queue.filter { libraryBook == LibraryBook(time: $0) }
      )
      // perform request
      if let requestUrl = store.urls[libraryBook], let requestBody = requestData.jsonRepresentation {
        
        // DEBUG:
        try! requestData.jsonRepresentation?.write(to: storeDirectoryUrl!.appendingPathComponent("\(libraryBook.bookId).json"))
        
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        TPPNetworkExecutor.shared.POST(request) { result, response, error in
          if let response = response as? HTTPURLResponse, !response.isSuccess() {
            TPPErrorLogger.logError(error, summary: "Error uploading audiobook tracker data", metadata: [
              "libraryId": libraryBook.libraryId,
              "bookId": libraryBook.bookId,
              "requestUrl": requestUrl,
              "requestBody": String(data: requestBody, encoding: .utf8) ?? "",
              "responseCode": response.statusCode,
              "responseBody": String(data: (result ?? Data()), encoding: .utf8) ?? ""
            ])
            return
          }
          if let data = result, let responseData = ResponseData(data: data) {
            for responseEntry in responseData.responses {
              if responseEntry.status >= 400 {
                TPPErrorLogger.logError(error, summary: "Error entry in audiobook tracker response", metadata: [
                  "libraryId": libraryBook.libraryId,
                  "bookId": libraryBook.bookId,
                  "requestUrl": requestUrl,
                  "requestBody": String(data: requestBody, encoding: .utf8) ?? "",
                  "entryId": responseEntry.id,
                  "entryStatus": responseEntry.status,
                  "entryMessage": responseEntry.message
                ])
              }
            }
            self.removeSynchronizedEntries(ids: responseData.responses.map { $0.id } )
            self.cleanUpUrls()
          }
        }
      }
    }
  }
  
  private var storeDirectoryUrl: URL? {
    return TPPBookContentMetadataFilesHelper.directory(for: "timetracker")
  }
  
  private var storeUrl: URL? {
    return storeDirectoryUrl?.appendingPathComponent("store.json")
  }

  private func loadStore() {
    guard let storeUrl, FileManager.default.fileExists(atPath: storeUrl.path) else {
      return
    }
    do {
      let data = try Data(contentsOf: storeUrl)
      if let store = AudiobookDataManagerStore(data: data) {
        self.store = store
      }
    } catch {
      TPPErrorLogger.logError(error, summary: "AudiobookDataManager error opening time tracker store")
    }
  }
  
  private func saveStore() {
    guard let storeDirectoryUrl, let storeUrl else {
      return
    }
    do {
      if !FileManager.default.fileExists(atPath: storeDirectoryUrl.path) {
        try FileManager.default.createDirectory(at: storeDirectoryUrl, withIntermediateDirectories: true)
      }
      try store.jsonRepresentation?.write(to: storeUrl)
    } catch {
      TPPErrorLogger.logError(error, summary: "AudiobookDataManager error saving time tracker store")
    }
  }
  
  private func cleanUpUrls() {
    let remainingLibraryBooks: Set<LibraryBook> = Set(store.queue.map { LibraryBook(time: $0) })
    store.urls = store.urls.filter { remainingLibraryBooks.contains($0.key) }
    saveStore()
  }
    
  private func removeSynchronizedEntries(ids: [String]) {
    store.queue = store.queue.filter { !ids.contains($0.id) }
    saveStore()
  }
  
}

extension AudiobookDataManager: DataManager {
  func save(time: TimeEntry) {
    guard let timeEntry = time as? AudiobookTimeEntry else {
      return
    }
    save(time: timeEntry)
  }
}
