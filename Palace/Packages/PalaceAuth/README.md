# PalaceAuth

Pure-Swift authentication primitives extracted from `Palace/SignInLogic/`. Hosts the auth state machine reducer (`AuthReducer`), `TokenRequest` (Basic-Auth bearer-token exchange), the SAML helper's protocol-based core (`TPPSAMLHelper`), front-end input validation (`TPPUserAccountFrontEndValidation`), and the `URLResponse` re-auth classifier extension.

Depends on `PalaceLogging`, `PalaceNetwork`, and `PalaceCatalog`. Heavy main-target collaborators (`TPPSignInBusinessLogic`, `Account`, `AccountsManager`, `TPPUserAccount`) stay in the app target and are reached through narrow public protocols (`UniversalLinksProviding`, `TPPLibraryAccountReadable`, `TPPSignInValidationContext`, `SAMLAuthContext`, `SAMLWebViewPresenting`) declared in this package.
