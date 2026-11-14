import AppKit
import WebKit

/// Agent control of Relay's browser: read the page, click, type, press a key,
/// scroll, go back or forward, and capture. Agent arguments reach the page
/// only as `callAsyncJavaScript` arguments in an isolated content world, never
/// as script source, and page scripts cannot see the element references.
/// Navigation goes through the session's own routing, so the Mac guard and
/// the host-port rules apply exactly as they do for the user.
enum RelayBrowserAgentAction: String, Codable, CaseIterable {
    case open, read, click, type, press, scroll, back, forward, reload, capture

    /// Actions that change what the browser shows or sends.
    var changesPage: Bool { ![.read, .capture].contains(self) }
}

struct RelayBrowserAgentPage: Codable, Equatable {
    struct Element: Codable, Equatable {
        let ref: Int
        let kind: String
        let name: String
        var href: String?
        var value: String?
        var disabled: Bool?
    }
    var url: String
    var title: String
    var loading: Bool
    /// A page asked for another host port; only the user can allow it.
    var waitingForUser: String?
    var error: String?
    var text: String
    var textTruncated: Bool
    var elements: [Element]
    var elementsTruncated: Bool
    var scrollY: Int
    var scrollHeight: Int
}

enum RelayBrowserAgentError: Error, Equatable, LocalizedError {
    case noBrowser, staleRef(Int), notTypable(Int), script(String)
    var errorDescription: String? {
        switch self {
        case .noBrowser: "No Relay browser is open for this pane's host; use action open with a url."
        case .staleRef(let ref): "Element \(ref) is no longer on the page; read the page again."
        case .notTypable(let ref): "Element \(ref) does not accept text."
        case .script(let message): message
        }
    }
}

enum RelayBrowserAgentScripts {
    static let textLimit = 12_000
    static let elementLimit = 200
    static let keys: Set<String> = ["Enter", "Escape", "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
                                    "Backspace", "PageUp", "PageDown", "Home", "End", " "]

    /// Collects visible text and interactive elements; references stay in this world.
    static let read = """
    const limit = textLimit, max = elementLimit;
    const visible = el => { const r = el.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return false;
      const s = getComputedStyle(el); return s.visibility !== 'hidden' && s.display !== 'none'; };
    const label = el => (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder ||
      el.getAttribute('title') || el.getAttribute('alt') || el.name || '').replace(/\\s+/g, ' ').trim().slice(0, 120);
    const sel = 'a[href],button,input:not([type=hidden]),textarea,select,summary,[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[contenteditable=""],[contenteditable=true],[onclick]';
    const refs = []; const elements = [];
    for (const el of document.querySelectorAll(sel)) {
      if (!visible(el)) continue;
      if (elements.length >= max) break;
      refs.push(el);
      const tag = el.tagName.toLowerCase();
      const kind = tag === 'input' ? 'input:' + (el.type || 'text') : (el.getAttribute('role') || tag);
      const item = { ref: refs.length, kind, name: label(el) };
      if (el.href) item.href = String(el.href).slice(0, 500);
      if ((tag === 'input' || tag === 'textarea' || tag === 'select') && el.type !== 'password') item.value = String(el.value ?? '').slice(0, 200);
      if (el.type === 'checkbox' || el.type === 'radio') item.value = el.checked ? 'checked' : 'unchecked';
      if (el.disabled) item.disabled = true;
      elements.push(item);
    }
    globalThis.__relayRefs = refs;
    const all = (document.body ? document.body.innerText : '') || '';
    return { url: location.href, title: document.title, text: all.slice(0, limit), textTruncated: all.length > limit,
      elements, elementsTruncated: document.querySelectorAll(sel).length > elements.length,
      scrollY: Math.round(scrollY), scrollHeight: Math.round(document.documentElement.scrollHeight) };
    """

    static let click = """
    const el = (globalThis.__relayRefs || [])[ref - 1];
    if (!el || !el.isConnected) return 'stale';
    el.scrollIntoView({ block: 'center', inline: 'center' });
    if (el.focus) el.focus();
    el.click();
    return 'ok';
    """

    static let type = """
    const el = (globalThis.__relayRefs || [])[ref - 1];
    if (!el || !el.isConnected) return 'stale';
    el.scrollIntoView({ block: 'center' });
    if (el.focus) el.focus();
    if (el.isContentEditable) {
      document.execCommand('selectAll', false); document.execCommand('insertText', false, text);
    } else if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
      const proto = el instanceof HTMLInputElement ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } else if (el instanceof HTMLSelectElement) {
      const option = [...el.options].find(o => o.value === text || o.text.trim() === text);
      if (!option) return 'no-option';
      el.value = option.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } else return 'not-typable';
    if (submit) {
      const init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
      const go = el.dispatchEvent(new KeyboardEvent('keydown', init));
      el.dispatchEvent(new KeyboardEvent('keyup', init));
      if (go && el.form) { try { el.form.requestSubmit(); } catch (e) { el.form.submit(); } }
    }
    return 'ok';
    """

    static let press = """
    const el = document.activeElement || document.body;
    const init = { key, code: key === ' ' ? 'Space' : key, bubbles: true, cancelable: true };
    const go = el.dispatchEvent(new KeyboardEvent('keydown', init));
    el.dispatchEvent(new KeyboardEvent('keyup', init));
    if (go && key === 'Enter' && el.form) { try { el.form.requestSubmit(); } catch (e) { el.form.submit(); } }
    else if (go && key === 'Enter' && (el instanceof HTMLAnchorElement || el instanceof HTMLButtonElement)) el.click();
    return 'ok';
    """

    static let scroll = "window.scrollBy(0, dy); return Math.round(scrollY);"
}

extension RelayBrowserSession {
    static let agentWorld = WKContentWorld.world(name: "relay-agent")

    private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.agentWorld)
        } catch {
            throw RelayBrowserAgentError.script("The page did not accept the action: \(error.localizedDescription)")
        }
    }

    /// Waits for a started navigation and any port being carried to finish.
    /// A click's navigation can start after the click returns and reports its
    /// new address before the new document exists, so this waits until the
    /// loaded document is the one at the shown address and is complete.
    func settle(timeout: Duration = .seconds(10)) async {
        let clock = ContinuousClock(), deadline = clock.now + timeout
        try? await Task.sleep(for: .milliseconds(250))
        while clock.now < deadline, confirm == nil {
            if !webView.isLoading, !busy, await documentMatchesAddress() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func documentMatchesAddress() async -> Bool {
        guard let shown = webView.url?.absoluteString else { return true }
        guard let state = try? await call("return [document.readyState, location.href]") as? [String],
              state.count == 2 else { return false }
        return state[0] == "complete" && (state[1] == shown || shown == "about:blank")
    }

    func agentPage() async -> RelayBrowserAgentPage {
        var page = RelayBrowserAgentPage(url: webView.url?.absoluteString ?? "", title: webView.title ?? "",
                                         loading: webView.isLoading, waitingForUser: confirm?.absoluteString,
                                         error: error, text: "", textTruncated: false, elements: [],
                                         elementsTruncated: false, scrollY: 0, scrollHeight: 0)
        guard webView.url != nil, let raw = try? await call(RelayBrowserAgentScripts.read,
                ["textLimit": RelayBrowserAgentScripts.textLimit, "elementLimit": RelayBrowserAgentScripts.elementLimit]),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let read = try? JSONDecoder().decode(RelayBrowserAgentRead.self, from: data) else { return page }
        page.title = read.title
        page.text = read.text
        page.textTruncated = read.textTruncated
        page.elements = read.elements
        page.elementsTruncated = read.elementsTruncated
        page.scrollY = read.scrollY
        page.scrollHeight = read.scrollHeight
        return page
    }

    func agentClick(_ ref: Int) async throws {
        let result = try await call(RelayBrowserAgentScripts.click, ["ref": ref]) as? String
        if result == "stale" { throw RelayBrowserAgentError.staleRef(ref) }
    }

    func agentType(_ ref: Int, text: String, submit: Bool) async throws {
        switch try await call(RelayBrowserAgentScripts.type, ["ref": ref, "text": text, "submit": submit]) as? String {
        case "stale": throw RelayBrowserAgentError.staleRef(ref)
        case "not-typable": throw RelayBrowserAgentError.notTypable(ref)
        case "no-option": throw RelayBrowserAgentError.script("No option \"\(text)\" in element \(ref).")
        default: break
        }
    }

    func agentPress(_ key: String) async throws {
        _ = try await call(RelayBrowserAgentScripts.press, ["key": key])
    }

    func agentScroll(_ dy: Int) async throws {
        _ = try await call(RelayBrowserAgentScripts.scroll, ["dy": dy])
    }

    /// A PNG of the visible page, at most 1280 points wide.
    func agentCapture() async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        if webView.bounds.width > 1280 { configuration.snapshotWidth = 1280 }
        let image = try await webView.takeSnapshot(configuration: configuration)
        // One pixel per point keeps the image small enough for an agent to read.
        let size = NSSize(width: max(1, image.size.width.rounded()), height: max(1, image.size.height.rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw RelayBrowserAgentError.script("The page could not be captured.")
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RelayBrowserAgentError.script("The page could not be captured.")
        }
        return png
    }
}

private struct RelayBrowserAgentRead: Decodable {
    let title: String
    let text: String
    let textTruncated: Bool
    let elements: [RelayBrowserAgentPage.Element]
    let elementsTruncated: Bool
    let scrollY: Int
    let scrollHeight: Int
}

extension RelayBrowserController {
    /// The open browser for a pane's host, if there is one.
    func session(for profile: ConnectionProfile) -> RelayBrowserSession? {
        existing(Self.key(profile)).flatMap { $0.profile == profile ? $0 : nil }
    }

    /// Carries out one agent action on the pane's host browser and returns the page after it.
    func agent(_ action: RelayBrowserAgentAction, profile: ConnectionProfile, directory: String?, near window: NSWindow?,
               url: URL?, ref: Int?, text: String?, submit: Bool, key: String?, dy: Int?) async throws
        -> (page: RelayBrowserAgentPage, capture: Data?) {
        if action == .open, let url {
            open(url, profile: profile, directory: directory, near: window, takeFocus: false)
        }
        guard let session = session(for: profile) else { throw RelayBrowserAgentError.noBrowser }
        switch action {
        case .open, .read, .capture: break
        case .click: try await session.agentClick(ref ?? 0)
        case .type: try await session.agentType(ref ?? 0, text: text ?? "", submit: submit)
        case .press: try await session.agentPress(key ?? "Enter")
        case .scroll: try await session.agentScroll(dy ?? 600)
        case .back: session.webView.goBack()
        case .forward: session.webView.goForward()
        case .reload: session.webView.reload()
        }
        if action.changesPage { await session.settle() }
        let capture = action == .capture ? try await session.agentCapture() : nil
        return (await session.agentPage(), capture)
    }
}
