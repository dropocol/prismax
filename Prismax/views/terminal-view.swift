import SwiftUI
import WebKit
import Darwin

/// Renders an interactive terminal using xterm.js inside a WKWebView, bridged
/// to a `TerminalProcess` PTY. Keystrokes flow webview → PTY; output flows
/// PTY → webview. This is the VS Code-style integrated terminal.
struct TerminalView: NSViewRepresentable {
    @Bindable var process: TerminalProcess

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // IMPORTANT: WKUserContentController does NOT retain script message
        // handlers (to avoid retain cycles). We register the coordinator itself
        // (which is retained by the SwiftUI view) under both names, and route by
        // name inside userContentController(_:didReceive:).
        let coordinator = context.coordinator
        config.userContentController.add(coordinator, name: "terminalInput")
        config.userContentController.add(coordinator, name: "terminalResize")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.underPageBackgroundColor = NSColor(red: 0.106, green: 0.106, blue: 0.110, alpha: 1)
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        if webView.responds(to: NSSelectorFromString("setInspectable:")) {
            webView.setValue(true, forKey: "inspectable")
        }
        #endif

        // Load the bundled xterm.js HTML. Resources may be in a `terminal/`
        // subfolder (folder reference) or flattened into the bundle root.
        let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "terminal")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
        if let htmlURL {
            let accessURL = Bundle.main.resourceURL ?? htmlURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: accessURL)
        } else {
            print("⚠️ Prismax: index.html not found in bundle")
        }
        coordinator.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Ensure the WebView can accept keyboard input.
        nsView.becomeFirstResponder()
        // If the underlying process re-spawned after dying (e.g. the user ran a
        // command and the manager revived the shell), the previous output-pump
        // task already exited when the old stream finished. Restart it so the
        // fresh shell's output reaches the webview.
        context.coordinator.restartPumpIfNeededIfRunning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(process: process)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let process: TerminalProcess
        private var outputTask: Task<Void, Never>?
        /// True while our output pump is actively consuming the stream. It ends
        /// when the stream finishes (process exit); a re-spawn clears it.
        private var pumpIsAlive = false
        private var webViewReady = false

        init(process: TerminalProcess) {
            self.process = process
        }

        /// Restarts the output pump when the process has been (re)spawned but
        /// our previous consumer already terminated — i.e. the shell was
        /// revived after dying.
        func restartPumpIfNeededIfRunning() {
            guard webViewReady else { return }
            // If the process is running but our pump isn't consuming, the shell
            // must have re-spawned: spin up a fresh pump.
            if process.isRunning && !pumpIsAlive {
                startOutputPump()
            }
        }

        // MARK: Script messages (keystrokes + resize)

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "terminalInput":
                if let base64 = message.body as? String {
                    handleInput(base64)
                }
            case "terminalResize":
                if let dict = message.body as? [String: Any],
                   let cols = dict["cols"] as? Int, let rows = dict["rows"] as? Int {
                    handleResize(cols: cols, rows: rows)
                }
            default:
                break
            }
        }

        @MainActor
        private func handleInput(_ base64: String) {
            guard let data = Data(base64Encoded: base64) else { return }
            process.send(data)
        }

        @MainActor
        private func handleResize(cols: Int, rows: Int) {
            var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols),
                             ws_xpixel: 0, ws_ypixel: 0)
            let fd = process.masterFD
            _ = withUnsafeMutablePointer(to: &ws) { ptr in
                ptr.withMemoryRebound(to: Int.self, capacity: 1) { intPtr in
                    ioctl(fd, UInt(TIOCSWINSZ), intPtr)
                }
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("Prismax: terminal HTML loaded")
            webViewReady = true
            webView.evaluateJavaScript("typeof Terminal !== 'undefined' && typeof window.writeToTerminal === 'function'") { result, _ in
                if let ok = result as? Bool, ok {
                    print("Prismax: xterm.js initialized OK")
                    self.startOutputPump()
                    // Focus the terminal so it accepts keystrokes immediately.
                    webView.evaluateJavaScript("window.focusTerminal && window.focusTerminal();")
                } else {
                    print("⚠️ Prismax: xterm.js did NOT initialize — scripts may have failed to load")
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("⚠️ Prismax: terminal failed to load: \(error.localizedDescription)")
        }

        private func startOutputPump() {
            outputTask?.cancel()
            pumpIsAlive = true
            outputTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await data in self.process.outputStream() {
                    let base64 = data.base64EncodedString()
                    self.webView?.evaluateJavaScript("window.writeToTerminal('\(base64)');", completionHandler: nil)
                }
                // Stream finished → the shell exited. Mark the pump dead so a
                // future re-spawn can restart it.
                pumpIsAlive = false
            }
        }
    }
}
