//
//  MyBooksDownloadCenter+AccountScope.swift — notes only, no code.
//
//  Account scope is read through `DownloadAccountScopeProviding`, but
//  credentials still come from the concrete `AccountsManager`: the URLSession
//  challenge needs a `TPPUserAccount`, which `DownloadUserAccount` does not
//  declare. The default scope adapter wraps the same `accountsManager`, so both
//  reads observe one account; its empty host set for a nil account is treated
//  like nil (cold-launch fallback). See god-class-decomposition-plan.md.
//
