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
            print("⚠️ PrismaX: index.html not found in bundle")
        }
        coordinator.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Ensure the WebView can accept keyboard input.
        nsView.becomeFirstResponder()

        // Detect a process swap (e.g. the user switched projects, so
        // TerminalPanel handed us a different TerminalProcess). When that
        // happens we re-bind this Coordinator to the new process: seed the
        // webview with the new shell's scrollback and start a fresh output
        // pump. This keeps the WKWebView alive across project switches instead
        // of (incorrectly) keeping it bound to the first project's shell.
        if ObjectIdentifier(context.coordinator.process) != ObjectIdentifier(process) {
            context.coordinator.rebind(to: process)
        } else {
            // Same process. If the underlying shell re-spawned after dying, the
            // previous output-pump task already exited when the old stream
            // finished. Restart it so the fresh shell's output reaches us.
            context.coordinator.restartPumpIfNeededIfRunning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(process: process)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        /// Mutable so a project switch can re-bind this Coordinator to a
        /// different TerminalProcess via `rebind(to:)` without recreating the
        /// WKWebView (which would wipe xterm.js scrollback).
        var process: TerminalProcess
        private var outputTask: Task<Void, Never>?
        /// True while our output pump is actively consuming the stream. It ends
        /// when the stream finishes (process exit); a re-spawn clears it.
        private var pumpIsAlive = false
        private var webViewReady = false

        init(process: TerminalProcess) {
            self.process = process
            super.init()
            armRespawnCallback()
        }

        /// Wires `process.onRespawn` so that when this shell is re-spawned (e.g.
        /// an environment-change restart) we automatically re-seed xterm.js and
        /// start a fresh output pump — without waiting for a SwiftUI re-render.
        func armRespawnCallback() {
            process.onRespawn = { [weak self] in
                guard let self, self.webViewReady else { return }
                self.webView?.evaluateJavaScript("term.reset();", completionHandler: nil)
                self.process.replayHistory { [weak self] base64 in
                    self?.webView?.evaluateJavaScript("window.writeToTerminal('\(base64)');", completionHandler: nil)
                }
                self.startOutputPump()
            }
        }

        /// Re-binds this Coordinator to a new `TerminalProcess` (project switch
        /// or tab switch). Seeds the existing webview with the new process's
        /// accumulated scrollback and starts a fresh live output pump.
        func rebind(to newProcess: TerminalProcess) {
            // Stop consuming the old process's stream.
            outputTask?.cancel()
            pumpIsAlive = false
            process = newProcess
            armRespawnCallback()

            guard webViewReady else { return }

            // Reset xterm.js to a blank slate, then replay the new process's
            // scrollback so the user sees its prior output, not the old
            // project's. `\x1bc` is the RIS ("reset") escape; we follow with a
            // fresh prompt-friendly clear by resetting the buffer in JS.
            webView?.evaluateJavaScript("term.reset();", completionHandler: nil)
            newProcess.replayHistory { [weak self] base64 in
                self?.webView?.evaluateJavaScript("window.writeToTerminal('\(base64)');", completionHandler: nil)
            }
            startOutputPump()
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
            print("PrismaX: terminal HTML loaded")
            webViewReady = true
            webView.evaluateJavaScript("typeof Terminal !== 'undefined' && typeof window.writeToTerminal === 'function'") { result, _ in
                if let ok = result as? Bool, ok {
                    print("PrismaX: xterm.js initialized OK")
                    // Seed the fresh webview with this process's accumulated
                    // scrollback before attaching the live pump, so a recreated
                    // view shows prior output instead of going blank.
                    self.process.replayHistory { base64 in
                        webView.evaluateJavaScript("window.writeToTerminal('\(base64)');", completionHandler: nil)
                    }
                    self.startOutputPump()
                    // Focus the terminal so it accepts keystrokes immediately.
                    webView.evaluateJavaScript("window.focusTerminal && window.focusTerminal();")
                } else {
                    print("⚠️ PrismaX: xterm.js did NOT initialize — scripts may have failed to load")
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("⚠️ PrismaX: terminal failed to load: \(error.localizedDescription)")
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
