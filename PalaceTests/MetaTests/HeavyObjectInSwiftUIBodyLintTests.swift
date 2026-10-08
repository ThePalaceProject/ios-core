//
//  HeavyObjectInSwiftUIBodyLintTests.swift
//  PalaceTests
//
//  A SwiftUI view's content is rebuilt on every state change, so a view
//  controller or web view built there is built again each time. #1620 removed
//  four `RemoteHTMLViewController`s from Settings rows that each started a
//  WebKit WebContent process per re-render. Scope rules and limits are on
//  `SwiftUIBodyConstructionScanner`.
//

import XCTest

final class HeavyObjectInSwiftUIBodyLintTests: XCTestCase {

    private typealias Scanner = SwiftUIBodyConstructionScanner

    private static let palaceSourceRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MetaTests/
        .deletingLastPathComponent()   // PalaceTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Palace")

    private struct SourceFile { let path: String; let code: String }

    /// Every `.swift` and `.h` file under `Palace/`, comments and strings removed.
    private static let sources: [SourceFile] = {
        let root = palaceSourceRoot.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: palaceSourceRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [SourceFile] = []
        for case let url as URL in enumerator where ["swift", "h"].contains(url.pathExtension) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = "Palace/" + url.standardizedFileURL.path.replacingOccurrences(of: root, with: "")
            files.append(SourceFile(path: path, code: Scanner.stripCommentsAndStrings(text)))
        }
        return files.sorted { $0.path < $1.path }
    }()

    private static let heavyTypes = Scanner.heavyTypes(declaredInCode: sources.map(\.code))

    private func scan(_ source: String, extraTypes: Set<String> = []) -> [Scanner.Finding] {
        Scanner.findings(in: source, path: "Fixture.swift", heavyTypes: Self.heavyTypes.union(extraTypes))
    }

    // MARK: - The tree

    /// No view controller or web view is constructed while a view's content is built.
    func testPalaceSources_ConstructNoHeavyObjectInViewContent() throws {
        let swiftFiles = Self.sources.filter { $0.path.hasSuffix(".swift") }
        XCTAssertGreaterThan(swiftFiles.count, 500, "resolved too few sources under \(Self.palaceSourceRoot.path)")
        let scopeCount = swiftFiles.reduce(0) { $0 + Scanner.viewScopes(in: $1.code).count }
        XCTAssertGreaterThan(scopeCount, 300, "found too few view scopes; the scope pattern no longer matches")

        let findings = swiftFiles.flatMap {
            Scanner.findings(inCode: $0.code, path: $0.path, heavyTypes: Self.heavyTypes)
        }
        XCTAssertTrue(
            findings.isEmpty,
            "Built while a SwiftUI view's content is built, so built again on every re-render:\n"
            + findings.map { "  \($0)" }.joined(separator: "\n")
            + "\nBuild it in makeUIViewController, as RemoteHTMLPage does, or pass it to "
            + "UIViewControllerWrapper, whose argument is an autoclosure."
        )
    }

    /// The class census reaches the named types and subclasses declared in the app.
    func testHeavyTypeCensus_IncludesSeedsAndAppSubclasses() {
        for name in ["WKWebView", "RemoteHTMLViewController", "BundledHTMLViewController",
                     "TPPAccountList", "TPPEPUBViewController", "EPUBNavigatorViewController"] {
            XCTAssertTrue(Self.heavyTypes.contains(name), "\(name) missing from the heavy-type census")
        }
    }

    /// The autoclosure exemption is only sound while each listed callee's
    /// initialiser really takes its first argument as `@autoclosure`.
    func testAutoclosureCallees_ReallyTakeAutoclosures() throws {
        for callee in Scanner.autoclosureCallees {
            let declaration = try NSRegularExpression(pattern: #"\b(?:struct|class)\s+"# + callee + #"\b"#)
            let initialiser = try NSRegularExpression(pattern: #"\binit\s*\(\s*\w+\s+\w+\s*:\s*[^,)]*@autoclosure"#)
            let owner = Self.sources.first {
                declaration.firstMatch(in: $0.code, range: NSRange(location: 0, length: $0.code.utf16.count)) != nil
            }
            let file = try XCTUnwrap(owner, "no declaration of \(callee) under Palace/")
            XCTAssertNotNil(
                initialiser.firstMatch(in: file.code, range: NSRange(location: 0, length: file.code.utf16.count)),
                "\(callee)'s initialiser no longer takes an @autoclosure, so the lint must stop exempting it"
            )
        }
    }

    /// AccountDetailView builds three remote pages through `UIViewControllerWrapper`;
    /// they are present in its view scopes and not reported.
    func testAccountDetailView_AutoclosureUseIsNotReported() throws {
        let file = try XCTUnwrap(Self.sources.first { $0.path == "Palace/Settings/AccountDetailView.swift" })
        let constructions = file.code.components(separatedBy: "RemoteHTMLViewController(").count - 1
        XCTAssertGreaterThanOrEqual(constructions, 3, "the fixture this test relies on has moved")
        XCTAssertEqual(Scanner.findings(inCode: file.code, path: file.path, heavyTypes: Self.heavyTypes), [])
    }

    // MARK: - Must report

    /// The shape #1620 removed: a controller built in a computed row, then wrapped.
    func testReports_ControllerBuiltInComputedRow_Issue1620Shape() {
        let source = """
        struct SettingsView: View {
            @ViewBuilder private var aboutRow: some View {
                let viewController = RemoteHTMLViewController(
                    URL: url, title: "About", failureMessage: "x"
                )
                let wrapper = UIViewControllerWrapper(viewController, updater: { _ in })
                row(destination: wrapper.anyView())
            }
        }
        """
        XCTAssertEqual(scan(source).map(\.line), [3])
        XCTAssertEqual(scan(source).first?.scope, "aboutRow")
    }

    func testReports_WebViewAndBundledPageInBody() {
        let source = """
        struct V: View {
            var body: some View {
                let web = WKWebView(frame: .zero)
                Holder(BundledHTMLViewController(fileURL: url, title: "t"))
            }
        }
        """
        XCTAssertEqual(scan(source).map(\.typeName), ["WKWebView", "BundledHTMLViewController"])
    }

    /// `.init`, generic and module-qualified spellings are constructions too.
    func testReports_InitGenericAndModuleQualifiedSpellings() {
        let source = """
        struct V: View {
            var body: some View {
                let a = RemoteHTMLViewController.init(URL: url, title: "", failureMessage: "")
                let b = UIHostingController<Text>(rootView: Text(""))
                let c = SafariServices.SFSafariViewController(url: url)
                let d = WKWebView.init(frame: .zero)
            }
        }
        """
        XCTAssertEqual(scan(source).map(\.line), [3, 4, 5, 6])
    }

    /// A ToolbarContent body is rebuilt with the view that owns it.
    func testReports_ConstructionInToolbarContent() {
        let source = """
        struct V: View {
            private var toolbarItems: some ToolbarContent {
                ToolbarItem { Holder(WKWebView()) }
            }
        }
        """
        XCTAssertEqual(scan(source).map(\.scope), ["toolbarItems"])
    }

    /// A local named like an event modifier is content, not an event closure.
    func testReports_ContentAfterBareIdentifierNamedLikeModifier() {
        let source = """
        struct V: View {
            var body: some View {
                if let task { Holder(WKWebView()) }
                if async { Holder(WKWebView()) }
            }
        }
        """
        XCTAssertEqual(scan(source).map(\.line), [3, 4])
    }

    /// SDK controllers are heavy too, including names that begin with `A`.
    func testReports_SDKControllerInBody() {
        let source = """
        struct V: View {
            var body: some View {
                Holder(AVPlayerViewController())
            }
        }
        """
        XCTAssertEqual(scan(source).map(\.typeName), ["AVPlayerViewController"])
    }

    func testReports_ConstructionInViewReturningFunction() {
        let source = """
        struct V: View {
            private func page(for url: URL) -> some View {
                Holder(RemoteHTMLViewController(URL: url, title: "", failureMessage: ""))
            }
            func erased() -> AnyView { AnyView(Holder(WKWebView())) }
        }
        """
        XCTAssertEqual(scan(source).map(\.line), [3, 5])
    }

    /// A subclass is heavy through the census, transitively, including a
    /// trailing-closure initialiser.
    func testReports_ControllerSubclassFromCensus() {
        let declarations = """
        final class PickerVC: UIViewController {}
        final class SpecialPickerVC: PickerVC {}
        """
        let types = Scanner.heavyTypes(declaredIn: [declarations])
        XCTAssertTrue(types.isSuperset(of: ["PickerVC", "SpecialPickerVC"]))

        let source = """
        struct V: View {
            var body: some View {
                Holder(SpecialPickerVC { picked in select(picked) })
            }
        }
        """
        XCTAssertEqual(Scanner.findings(in: source, path: "F", heavyTypes: types).map(\.typeName), ["SpecialPickerVC"])
    }

    /// A button's label runs during rendering, unlike its action.
    func testReports_ConstructionInButtonLabel() {
        let source = """
        struct V: View {
            var body: some View {
                Button(action: open) { Holder(WKWebView()) }
                Button { open() } label: { Holder(WKWebView()) }
            }
        }
        """
        XCTAssertEqual(scan(source).map(\.line), [3, 4])
    }

    /// Braces and quotes inside strings, interpolations, raw and multi-line
    /// strings and comments do not end the scope early.
    func testReports_AfterBracesHiddenInStringsAndComments() {
        let source = #"""
        struct V: View {
            var body: some View {
                Text("} \(label("{")) }")
                Text(#"}"#)
                let note = """
                }
                """
                /* } */ // }
                Holder(WKWebView())
            }
        }
        """#
        XCTAssertEqual(scan(source).map(\.line), [9])
    }

    // MARK: - Must not report

    func testIgnores_RepresentableFactoryMethods() {
        let source = """
        struct Page: UIViewControllerRepresentable {
            func makeUIViewController(context: Context) -> UIViewController {
                RemoteHTMLViewController(URL: url, title: "", failureMessage: "")
            }
            func updateUIViewController(_ vc: UIViewController, context: Context) {}
        }
        struct Web: UIViewRepresentable {
            func makeUIView(context: Context) -> WKWebView { WKWebView() }
            func updateUIView(_ view: WKWebView, context: Context) { _ = WKWebView() }
        }
        """
        XCTAssertEqual(scan(source), [])
    }

    /// The AccountDetailView shape: the controller is the wrapper's autoclosure argument.
    func testIgnores_AutoclosureWrapperArgument() {
        let source = """
        struct V: View {
            @ViewBuilder private var privacyPolicyView: some View {
                if let url {
                    UIViewControllerWrapper(
                        RemoteHTMLViewController(URL: url, title: "", failureMessage: ""),
                        updater: { _ in }
                    )
                }
            }
        }
        """
        XCTAssertEqual(scan(source), [])
    }

    /// An explicit generic argument does not hide the autoclosure callee.
    func testIgnores_GenericAutoclosureWrapperArgument() {
        let source = """
        struct V: View {
            var body: some View {
                UIViewControllerWrapper<RemoteHTMLViewController>(
                    RemoteHTMLViewController(URL: url, title: "", failureMessage: ""),
                    updater: { _ in }
                )
            }
        }
        """
        XCTAssertEqual(scan(source), [])
    }

    /// A truncated file that ends in `#` is lexed without reading past its end.
    func testLexer_SourceEndingInHashIsKeptIntact() {
        XCTAssertEqual(Scanner.stripCommentsAndStrings("let a = 1 #"), "let a = 1 #")
    }

    func testIgnores_ActionAndEventClosures() {
        let source = """
        struct V: View {
            var body: some View {
                Button(action: { present(WKWebView()) }, label: { Text("a") })
                Button("b") { present(RemoteHTMLViewController(URL: u, title: "", failureMessage: "")) }
                Button { present(WKWebView()) } label: { Text("c") }
                Text("d")
                    .onAppear { preload(WKWebView()) }
                    .onTapGesture(count: 2) { present(WKWebView()) }
                    .task { await load(WKWebView()) }
                    .onChange(of: x) { _ in present(WKWebView()) }
                    .simultaneousGesture(TapGesture().onEnded { present(WKWebView()) })
                    .sheet(isPresented: $shown, onDismiss: { cache = WKWebView() }) { Text("e") }
            }
            func open() { Task { present(WKWebView()) } }
        }
        """
        XCTAssertEqual(scan(source), [])
    }

    func testIgnores_CodeOutsideSwiftUIViews() {
        let source = """
        final class Coordinator {
            func showAbout() {
                let vc = RemoteHTMLViewController(URL: url, title: "", failureMessage: "")
                navigationController.pushViewController(vc, animated: true)
            }
            func makeController() -> UIViewController { BundledHTMLViewController(fileURL: u, title: "") }
            var webView: WKWebView { WKWebView() }
        }
        """
        XCTAssertEqual(scan(source), [])
    }

    func testIgnores_MentionsInCommentsAndStrings() {
        let source = """
        struct V: View {
            var body: some View {
                // let vc = RemoteHTMLViewController(URL: url)
                /* WKWebView() */
                Text("WKWebView(frame: .zero)")
                Text(verbatim: \"\"\"
                BundledHTMLViewController(fileURL: u)
                \"\"\")
            }
        }
        """
        XCTAssertEqual(scan(source), [])
    }

    /// Member access, type annotations, casts and type checks are not constructions.
    func testIgnores_NonConstructionReferences() {
        let source = """
        struct V: View {
            let controller: RemoteHTMLViewController
            var body: some View {
                let type = WKWebView.self
                let page: RemoteHTMLViewController? = cached
                Holder(factory.RemoteHTMLViewController(x))
                if let vc = presenter as? UIViewController { Text("a") }
                if host is WKWebView { Text("b") }
                let web = view as! WKWebView
                let generic = presenter as? UIHostingController<Text>
            }
        }
        """
        XCTAssertEqual(scan(source), [])
    }
}
