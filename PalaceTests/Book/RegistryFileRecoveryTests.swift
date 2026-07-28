//
//  RegistryFileRecoveryTests.swift
//  PalaceTests
//
//  Reliability initiative — Workstream B. Pure classification + quarantine /
//  backup unit tests for `RegistryFileRecovery`. No `BookRegistrySync`, no
//  network, no keychain — just `Data` and temp-directory file I/O.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class RegistryFileRecoveryTests: XCTestCase {

  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("RegistryFileRecoveryTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    tempDir = nil
    super.tearDown()
  }

  // MARK: - Fixtures

  private func registryURL() -> URL {
    tempDir.appendingPathComponent("registry").appendingPathComponent("registry.json")
  }

  private func recordDict(id: String) -> [String: Any] {
    // Minimal well-formed record shape (only the keys classify() cares about are
    // structural; classify does not decode TPPBook, only the records array).
    [
      TPPBookRegistryKey.book.rawValue: ["id": id, "title": "Book \(id)"],
      TPPBookRegistryKey.state.rawValue: "DownloadSuccessful"
    ]
  }

  private func versionedPayload(records: [[String: Any]], version: Int?) -> Data {
    var json: [String: Any] = [TPPBookRegistryKey.records.rawValue: records]
    if let version { json[RegistryFileRecovery.schemaVersionKey] = version }
    return try! JSONSerialization.data(withJSONObject: json)
  }

  private func write(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
  }

  // MARK: - classify()

  func testClassify_nilData_isEmpty() {
    guard case .empty = RegistryFileRecovery.classify(data: nil) else {
      return XCTFail("nil data must classify as .empty")
    }
  }

  func testClassify_zeroLengthData_isEmpty() {
    guard case .empty = RegistryFileRecovery.classify(data: Data()) else {
      return XCTFail("zero-length data must classify as .empty")
    }
  }

  func testClassify_wellFormedWithRecords_isValidWithRecordCount() {
    let data = versionedPayload(records: [recordDict(id: "a"), recordDict(id: "b")], version: 1)
    guard case .valid(let records) = RegistryFileRecovery.classify(data: data) else {
      return XCTFail("well-formed registry must classify as .valid")
    }
    XCTAssertEqual(records.count, 2, "the two persisted records must survive classification")
  }

  func testClassify_wellFormedEmptyRecordsArray_isValidEmpty_notCorrupt() {
    // An authoritatively-empty shelf (e.g. all loans returned) is VALID, not
    // corrupt — it must never be quarantined.
    let data = versionedPayload(records: [], version: 1)
    guard case .valid(let records) = RegistryFileRecovery.classify(data: data) else {
      return XCTFail("empty-but-well-formed registry must classify as .valid, not .corrupt")
    }
    XCTAssertTrue(records.isEmpty)
  }

  func testClassify_unparseableJSON_isCorrupt() {
    let data = Data("{ this is not valid json".utf8)
    guard case .corrupt = RegistryFileRecovery.classify(data: data) else {
      return XCTFail("unparseable bytes must classify as .corrupt (recoverable)")
    }
  }

  func testClassify_jsonObjectMissingRecordsArray_isCorrupt() {
    // Valid JSON, but the wrong shape (no records array) — truncated/garbled
    // payload. Must be treated as corrupt so it is quarantined, not silently
    // replaced by an empty registry.
    let data = try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "unexpected": "shape"])
    guard case .corrupt = RegistryFileRecovery.classify(data: data) else {
      return XCTFail("a JSON object without a records array must classify as .corrupt")
    }
  }

  func testClassify_jsonArrayAtRoot_isCorrupt() {
    // Root is an array, not the expected `{ records: [...] }` object.
    let data = try! JSONSerialization.data(withJSONObject: [["x": 1]])
    guard case .corrupt = RegistryFileRecovery.classify(data: data) else {
      return XCTFail("a bare JSON array at root is not a registry object → .corrupt")
    }
  }

  // MARK: - Schema version / migration

  func testSchemaVersion_readsPersistedVersion() {
    let data = versionedPayload(records: [recordDict(id: "a")], version: 1)
    XCTAssertEqual(RegistryFileRecovery.schemaVersion(from: data), 1)
  }

  func testSchemaVersion_unversionedFile_isNil() {
    let data = versionedPayload(records: [recordDict(id: "a")], version: nil)
    XCTAssertNil(RegistryFileRecovery.schemaVersion(from: data),
                 "a legacy file without the schemaVersion key must report nil version")
  }

  func testNeedsMigration_trueForUnversionedValidFile() {
    let data = versionedPayload(records: [recordDict(id: "a")], version: nil)
    XCTAssertTrue(RegistryFileRecovery.needsMigration(data: data),
                  "an unversioned but valid file must be flagged for migration")
  }

  func testNeedsMigration_falseForVersionedFile() {
    let data = versionedPayload(records: [recordDict(id: "a")], version: RegistryFileRecovery.currentSchemaVersion)
    XCTAssertFalse(RegistryFileRecovery.needsMigration(data: data),
                   "a file already at the current version must not be flagged for migration")
  }

  func testNeedsMigration_falseForCorruptData() {
    XCTAssertFalse(RegistryFileRecovery.needsMigration(data: Data("garbage".utf8)),
                   "corrupt data is not a migration candidate — it is a recovery case")
  }

  // MARK: - Path derivation

  func testBackupURL_appendsBakExtension() {
    let url = registryURL()
    XCTAssertEqual(RegistryFileRecovery.backupURL(for: url).lastPathComponent, "registry.json.bak")
  }

  func testQuarantineURL_encodesTimestamp() {
    let url = registryURL()
    let ts = Date(timeIntervalSince1970: 1_700_000_000)
    let q = RegistryFileRecovery.quarantineURL(for: url, timestamp: ts)
    XCTAssertEqual(q.lastPathComponent, "registry.json.corrupt-1700000000",
                   "quarantine filename must embed the unix timestamp so multiple corruptions do not collide")
  }

  // MARK: - quarantine() — never destroys the original (INV-1 core)

  func testCorruptFile_isQuarantined_notOverwrittenEmpty() {
    // The load-time policy in one place: a corrupt file is COPIED aside; the
    // original bytes are preserved (not destroyed, not zeroed). This is the
    // recovery-helper half of INV-1.
    let url = registryURL()
    let corruptBytes = Data("{ truncated registry".utf8)
    write(corruptBytes, to: url)

    let ts = Date(timeIntervalSince1970: 1_700_000_123)
    let quarantined = RegistryFileRecovery.quarantine(corruptFileAt: url, timestamp: ts)

    // A quarantine copy exists and holds the exact corrupt bytes.
    XCTAssertNotNil(quarantined, "a present corrupt file must be quarantined")
    XCTAssertEqual(quarantined?.lastPathComponent, "registry.json.corrupt-1700000123")
    XCTAssertEqual(try? Data(contentsOf: quarantined!), corruptBytes,
                   "the quarantine copy must contain the original corrupt bytes verbatim")

    // The ORIGINAL still exists, unchanged — quarantine copies, never moves.
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                  "quarantine must NOT delete the original corrupt file")
    XCTAssertEqual(try? Data(contentsOf: url), corruptBytes,
                   "the original file must be byte-identical after quarantine (never overwritten empty)")
  }

  func testQuarantine_absentFile_returnsNil() {
    XCTAssertNil(RegistryFileRecovery.quarantine(corruptFileAt: registryURL()),
                 "there is nothing to quarantine when the file does not exist")
  }

  // MARK: - writeBackup / recoverFromBackup roundtrip

  func testWriteBackup_thenRecover_returnsRecords() throws {
    let url = registryURL()
    let payload = versionedPayload(records: [recordDict(id: "x"), recordDict(id: "y")], version: 1)

    try RegistryFileRecovery.writeBackup(data: payload, for: url)

    XCTAssertTrue(FileManager.default.fileExists(atPath: RegistryFileRecovery.backupURL(for: url).path),
                  "writeBackup must produce a registry.json.bak sidecar")
    let recovered = RegistryFileRecovery.recoverFromBackup(for: url)
    XCTAssertEqual(recovered?.count, 2, "the backup must round-trip both records")
    XCTAssertTrue(RegistryFileRecovery.backupHasRecords(for: url),
                  "a non-empty backup must report backupHasRecords == true")
  }

  func testWriteBackup_leavesNoTempFile() throws {
    let url = registryURL()
    try RegistryFileRecovery.writeBackup(data: versionedPayload(records: [recordDict(id: "x")], version: 1), for: url)
    let tmp = RegistryFileRecovery.backupURL(for: url).appendingPathExtension("tmp")
    XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path),
                   "the write-new → fsync → rename sequence must leave no .tmp behind")
  }

  func testRecoverFromBackup_emptyRecordsBackup_returnsNil() throws {
    // An empty backup is not a usable recovery source — recovering "zero books"
    // would be indistinguishable from the shelf-erasure we are guarding against.
    let url = registryURL()
    try RegistryFileRecovery.writeBackup(data: versionedPayload(records: [], version: 1), for: url)
    XCTAssertNil(RegistryFileRecovery.recoverFromBackup(for: url),
                 "an empty backup must not be treated as recoverable records")
    XCTAssertFalse(RegistryFileRecovery.backupHasRecords(for: url),
                   "an empty backup must report backupHasRecords == false")
  }

  func testRecoverFromBackup_noBackup_returnsNil() {
    XCTAssertNil(RegistryFileRecovery.recoverFromBackup(for: registryURL()))
    XCTAssertFalse(RegistryFileRecovery.backupHasRecords(for: registryURL()))
  }

  func testRecoverFromBackup_corruptBackup_returnsNil() throws {
    let url = registryURL()
    let bak = RegistryFileRecovery.backupURL(for: url)
    write(Data("{ corrupt backup".utf8), to: bak)
    XCTAssertNil(RegistryFileRecovery.recoverFromBackup(for: url),
                 "a corrupt backup must not be offered as a recovery source")
  }

  // MARK: - primaryHasRecords() / onDiskHasRecords() (broadened INV-1, #18414)

  func testPrimaryHasRecords_nonEmptyPrimary_isTrue() {
    let url = registryURL()
    write(versionedPayload(records: [recordDict(id: "p1")], version: 1), to: url)
    XCTAssertTrue(RegistryFileRecovery.primaryHasRecords(for: url),
                  "a valid non-empty primary must report primaryHasRecords == true")
  }

  func testPrimaryHasRecords_absentPrimary_isFalse() {
    XCTAssertFalse(RegistryFileRecovery.primaryHasRecords(for: registryURL()),
                   "an absent primary file must report false")
  }

  func testPrimaryHasRecords_validEmptyPrimary_isFalse() {
    let url = registryURL()
    write(versionedPayload(records: [], version: 1), to: url)
    XCTAssertFalse(RegistryFileRecovery.primaryHasRecords(for: url),
                   "a valid-but-empty primary is not a shelf to protect — must report false")
  }

  func testPrimaryHasRecords_corruptPrimary_isFalse() {
    let url = registryURL()
    write(Data("{ truncated corrupt".utf8), to: url)
    XCTAssertFalse(RegistryFileRecovery.primaryHasRecords(for: url),
                   "a corrupt primary carries no usable records — must report false")
  }

  /// Kills the `||` -> `&&` mutant on `onDiskHasRecords`: a non-empty PRIMARY
  /// with NO backup must still report true. Under `&&` (both required) this
  /// would be false, so the assertion fails the mutant.
  func testOnDiskHasRecords_primaryOnly_noBackup_isTrue() {
    let url = registryURL()
    write(versionedPayload(records: [recordDict(id: "only-primary")], version: 1), to: url)
    XCTAssertFalse(RegistryFileRecovery.backupHasRecords(for: url),
                   "precondition: no backup present")
    XCTAssertTrue(RegistryFileRecovery.onDiskHasRecords(for: url),
                  "onDiskHasRecords must be true when only the PRIMARY holds records (|| not &&)")
  }

  /// The other `||` arm: a non-empty BACKUP with NO/empty primary must report
  /// true (the post-corrupt rebuild-window shape).
  func testOnDiskHasRecords_backupOnly_noPrimary_isTrue() {
    let url = registryURL()
    write(versionedPayload(records: [recordDict(id: "only-bak")], version: 1),
          to: RegistryFileRecovery.backupURL(for: url))
    XCTAssertFalse(RegistryFileRecovery.primaryHasRecords(for: url),
                   "precondition: primary absent")
    XCTAssertTrue(RegistryFileRecovery.onDiskHasRecords(for: url),
                  "onDiskHasRecords must be true when only the BACKUP holds records")
  }

  func testOnDiskHasRecords_neitherPresent_isFalse() {
    XCTAssertFalse(RegistryFileRecovery.onDiskHasRecords(for: registryURL()),
                   "no primary and no backup means nothing on disk to protect — false")
  }
}
