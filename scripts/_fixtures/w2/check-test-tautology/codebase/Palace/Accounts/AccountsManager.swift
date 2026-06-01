// Palace/Accounts/AccountsManager.swift (fixture)
import Foundation

struct Account {}
struct Catalog {}

final class AccountsManager {
    // NON-optional return: `accounts()` -> [Account]
    func accounts() -> [Account] { [] }

    // NON-optional return: `currentLibraryUUID()` -> String
    func currentLibraryUUID() -> String { "" }

    // OPTIONAL return: `lookupCatalog()` -> Catalog?
    func lookupCatalog() -> Catalog? { nil }

    // OPTIONAL return: explicit Optional<T>
    func explicitOptional() -> Optional<String> { nil }
}
