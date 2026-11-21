import UIKit

/// Opens the containing app from the keyboard. `extensionContext.open` only works for Today
/// widgets, so this walks the responder chain to UIApplication and calls its openURL method.
@MainActor
enum HostAppOpener {
    private typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void

    @discardableResult
    static func open(_ url: URL, from responder: UIResponder) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var current: UIResponder? = responder
        while let next = current {
            if let app = next as? UIApplication, app.responds(to: selector) {
                let open = unsafeBitCast(app.method(for: selector), to: OpenFunction.self)
                open(app, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            current = next.next
        }
        return false
    }
}
