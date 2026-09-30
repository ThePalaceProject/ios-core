//
//  MyBooksDownloadCenter+AccountScope.swift
//  Palace
//
//  Account-scope notes for MyBooksDownloadCenter (no code in this file).
//
//  The download center reads account scope (current account id, auth-surface
//  hosts) through `DownloadAccountScopeProviding`, but still reads credentials
//  through the concrete `AccountsManager`: the URLSession challenge needs a
//  `TPPUserAccount` for `NYPLBasicAuthCredentialsProvider`, which
//  `DownloadUserAccount` does not declare. The default scope is an
//  `AccountsManagerDownloadContextAdapter` over the same `accountsManager`, so
//  scope and credential reads observe one account. Its empty host set for a
//  nil account is equivalent to nil: `AuthErrorClassifier` treats both as the
//  cold-launch fallback. See docs/architecture/god-class-decomposition-plan.md.
//
