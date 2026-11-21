import UIKit
import WebKit

/// Keyboard extensions can't open the microphone with AVAudioSession, but WebKit's
/// `getUserMedia` runs in a separate WebContent process that can. A hidden 2x2 WKWebView
/// captures audio, converts it to 16-bit PCM in Web Audio and posts it back here.
/// (Approach from the MIT-licensed Hex iOS keyboard.)
@MainActor
final class MicCapture: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Event {
        case started
        case level(Float)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    private(set) var sampleRate = 48_000
    private var pcm = Data()
    private var pageLoaded = false
    private var pendingStart = false
    private let webView: WKWebView

    init(host: UIView) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakHandler(self), name: "mic")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.02
        webView.isAccessibilityElement = false
        host.addSubview(webView)
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://keyboard.dictkb.local/"))
    }

    func start() {
        pcm = Data()
        guard pageLoaded else { pendingStart = true; return }
        webView.evaluateJavaScript("micStart()")
    }

    /// Stops capture and returns the recorded 16-bit mono PCM.
    func stop() -> Data {
        pendingStart = false
        webView.evaluateJavaScript("micStop()")
        let data = pcm
        pcm = Data()
        return data
    }

    func tearDown() {
        webView.evaluateJavaScript("micStop()")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mic")
        webView.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if pendingStart {
            pendingStart = false
            webView.evaluateJavaScript("micStart()")
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "started":
            sampleRate = (body["rate"] as? NSNumber)?.intValue ?? 48_000
            onEvent?(.started)
        case "pcm":
            if let base64 = body["data"] as? String, let chunk = Data(base64Encoded: base64) {
                pcm.append(chunk)
            }
            onEvent?(.level((body["peak"] as? NSNumber)?.floatValue ?? 0))
        case "error":
            onEvent?(.failed(body["message"] as? String ?? "Microphone unavailable"))
        default:
            break
        }
    }

    private static let page = """
    <!doctype html><html><body><script>
    let stream = null, ctx = null, node = null, source = null, running = false;
    const post = (m) => window.webkit.messageHandlers.mic.postMessage(m);
    async function micStart() {
      if (running) return;
      running = true;
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: {
          echoCancellation: false, noiseSuppression: true, autoGainControl: true, channelCount: 1 } });
        ctx = new AudioContext();
        await ctx.resume();
        source = ctx.createMediaStreamSource(stream);
        node = ctx.createScriptProcessor(4096, 1, 1);
        node.onaudioprocess = (e) => {
          if (!running) return;
          const input = e.inputBuffer.getChannelData(0);
          const pcm = new Int16Array(input.length);
          let peak = 0;
          for (let i = 0; i < input.length; i++) {
            const s = Math.max(-1, Math.min(1, input[i]));
            peak = Math.max(peak, Math.abs(s));
            pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
          }
          const bytes = new Uint8Array(pcm.buffer);
          let binary = "";
          for (let i = 0; i < bytes.length; i += 0x8000) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          }
          post({ type: "pcm", data: btoa(binary), peak });
        };
        source.connect(node);
        node.connect(ctx.destination);
        post({ type: "started", rate: ctx.sampleRate });
      } catch (error) {
        running = false;
        micStop();
        post({ type: "error", message: (error && (error.name + ": " + error.message)) || String(error) });
      }
    }
    function micStop() {
      running = false;
      try { if (node) node.disconnect(); if (source) source.disconnect(); } catch (e) {}
      if (stream) stream.getTracks().forEach(t => t.stop());
      if (ctx) ctx.close();
      stream = null; ctx = null; node = null; source = null;
    }
    </script></body></html>
    """
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
