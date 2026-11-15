import XCTest
import WebKit
@testable import RoomReset

final class EmbeddedGameTests: XCTestCase {
    @MainActor
    func testLocalGameAndNativeFolderBridge() async throws {
        let host = RoomHost(bookmarkKey: "roomTest-" + UUID().uuidString)
        let web = host.makeWebView(store: .nonPersistent())
        // WebKit suspends CSS and Web Animations timelines on detached views.
        #if os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = web
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #else
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        #endif
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if let ready = try? await web.evaluateJavaScript("typeof roomReply === 'function' && document.querySelectorAll('#floor button').length > 0") as? Bool, ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let title = try await web.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "Room Reset")

        // Exercise the page-to-native security checks and the actual asynchronous reply.
        let response = try await web.callAsyncJavaScript("""
          return await new Promise((resolve, reject) => {
            const original = window.roomReply;
            const timeout = setTimeout(() => reject(new Error("Native scan timed out")), 4000);
            window.roomReply = (id, response) => {
              if (id !== "test-native-scan") { original(id, response); return; }
              clearTimeout(timeout);
              window.roomReply = original;
              resolve(response.ok && response.value === null);
            };
            window.webkit.messageHandlers.room.postMessage({id:"test-native-scan", op:"scan", args:{}});
          });
        """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(response as? Bool, true)

        let swept = try await web.callAsyncJavaScript("""
            document.getElementById('sweep').click();
            for (let i=0; i<100; i++) {
              if (!document.querySelector('#floor button')) return true;
              await new Promise(r => setTimeout(r,100));
            }
            return false;
        """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(swept as? Bool, true)
        _ = try await web.evaluateJavaScript("document.getElementById('undo').click()")
        let count = try await web.evaluateJavaScript("document.querySelectorAll('#floor button').length") as? Int
        XCTAssertGreaterThan(count ?? 0, 0)
    }
}
