import SwiftUI
import UniformTypeIdentifiers
import WebKit

@main
struct RoomResetApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("Room Reset", id: "room") {
            RoomScreen().frame(minWidth: 420, minHeight: 570)
        }
        .defaultSize(width: 1040, height: 820)
        #else
        WindowGroup { RoomScreen() }
        #endif
    }
}

private struct RoomScreen: View {
    @StateObject private var host = RoomHost()
    var body: some View {
        RoomWebView(host: host)
            .background(Color(red: 0.97, green: 0.94, blue: 0.88))
            .fileImporter(isPresented: $host.picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                host.finishPick(result.flatMap { urls in
                    urls.first.map(Result.success) ?? .failure(CocoaError(.userCancelled))
                })
            } onCancellation: {
                host.cancelPick()
            }
    }
}

#if os(macOS)
private struct RoomWebView: NSViewRepresentable {
    let host: RoomHost
    func makeNSView(context: Context) -> WKWebView { host.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct RoomWebView: UIViewRepresentable {
    let host: RoomHost
    func makeUIView(context: Context) -> WKWebView { host.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

private final class SelectedFolder {
    private let bookmarkKey: String
    init(bookmarkKey: String) { self.bookmarkKey = bookmarkKey }
    private let ledgerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Room Reset/Move History", isDirectory: true)

    private func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: .withSecurityScope)
        #else
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    func operate(_ op: String, _ ids: [String], selecting picked: URL?) throws -> Any {
        var stale = false
        let url: URL
        if let picked {
            url = picked
        } else if let saved = UserDefaults.standard.data(forKey: bookmarkKey) {
            #if os(macOS)
            url = try URL(resolvingBookmarkData: saved, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            url = try URL(resolvingBookmarkData: saved, bookmarkDataIsStale: &stale)
            #endif
        } else { return NSNull() }
        guard url.startAccessingSecurityScopedResource() else { throw RoomError("Choose the folder again to restore access.") }
        defer { url.stopAccessingSecurityScopedResource() }

        var answer: Result<[String: Any], Error>?
        var coordinationError: NSError?
        let accessor: (URL) -> Void = { folderURL in
            answer = Result {
                let room = try RoomFolder(url: folderURL, journalDirectory: self.ledgerDir)
                switch op {
                case "pick", "scan": return try room.scan()
                case "tidy": return try room.tidy(ids: ids)
                case "undo": return try room.undo()
                case "purge": return try room.purge()
                default: throw RoomError("Unknown action.")
                }
            }
        }
        if op == "scan" || op == "pick" {
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError, byAccessor: accessor)
        } else {
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError { throw coordinationError }
        guard let answer else { throw RoomError("Folder unavailable.") }
        let scan = try answer.get()
        if picked != nil || stale {
            UserDefaults.standard.set(try bookmark(for: url), forKey: bookmarkKey)
        }
        return scan
    }
}

final class RoomHost: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var picking = false
    private var pickerID: Any?
    private weak var view: WKWebView?
    private let work = DispatchQueue(label: "org.roomreset.folder", qos: .userInitiated)
    private let folder: SelectedFolder
    init(bookmarkKey: String = "selectedRoomBookmark") { folder = SelectedFolder(bookmarkKey: bookmarkKey) }
    private let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")

    func makeWebView(store: WKWebsiteDataStore = .default()) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self, name: "room")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        #if os(iOS)
        web.scrollView.bounces = false
        #endif
        view = web
        if let page { web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        return web
    }

    private func isLocalPage(_ url: URL?) -> Bool {
        guard let url, let page, url.isFileURL else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.path ==
            page.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = action.targetFrame?.isMainFrame == true && isLocalPage(action.request.url)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === view,
              isLocalPage(message.webView?.url),
              let body = message.body as? [String: Any], let id = body["id"], id is String || id is NSNumber,
              let op = body["op"] as? String else { return }
        if op == "pick" {
            guard pickerID == nil else { reply(id, ["ok": false, "error": "A folder picker is already open."]); return }
            pickerID = id
            picking = true
        } else {
            let args = body["args"] as? [String: Any]
            run(id, op, args?["ids"] as? [String] ?? [])
        }
    }

    func finishPick(_ result: Result<URL, Error>) {
        guard let id = pickerID else { return }
        pickerID = nil
        switch result {
        case .success(let url): run(id, "pick", [], selecting: url)
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { reply(id, ["ok": true, "value": NSNull()]) }
            else { reply(id, ["ok": false, "error": error.localizedDescription]) }
        }
    }

    func cancelPick() {
        guard let id = pickerID else { return }
        pickerID = nil
        reply(id, ["ok": true, "value": NSNull()])
    }

    private func run(_ id: Any, _ op: String, _ ids: [String], selecting url: URL? = nil) {
        work.async {
            let result: [String: Any]
            do { result = ["ok": true, "value": try self.folder.operate(op, ids, selecting: url)] }
            catch { result = ["ok": false, "error": error.localizedDescription] }
            DispatchQueue.main.async { self.reply(id, result) }
        }
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        view?.callAsyncJavaScript("window.roomReply(id, result)", arguments: ["id": id, "result": result],
                                  in: nil, in: .page, completionHandler: nil)
    }
}
