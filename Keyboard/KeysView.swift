import UIKit

/// A compact QWERTY layout with shift, numbers and punctuation.
final class KeysView: UIView {
    enum Key {
        case character(String)
        case space
        case delete
        case `return`
    }

    var onKey: ((Key) -> Void)?
    private var shifted = true { didSet { rebuild() } }
    private var numbers = false { didSet { rebuild() } }
    private let rows = UIStackView()
    private var deleteTimer: Timer?

    private static let letters = [["q","w","e","r","t","y","u","i","o","p"], ["a","s","d","f","g","h","j","k","l"], ["z","x","c","v","b","n","m"]]
    private static let symbols = [["1","2","3","4","5","6","7","8","9","0"], ["-","/",":",";","(",")","$","&","@","\""], [".",",","?","!","'"]]

    override init(frame: CGRect) {
        super.init(frame: frame)
        rows.axis = .vertical
        rows.distribution = .fillEqually
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let layout = numbers ? Self.symbols : Self.letters
        for (index, chars) in layout.enumerated() {
            var views: [UIView] = chars.map { char in
                let title = numbers || !shifted ? char : char.uppercased()
                return key(title, id: "key.\(title)") { [weak self] in
                    guard let self else { return }
                    self.onKey?(.character(title))
                    if self.shifted && !self.numbers { self.shifted = false }
                }
            }
            if index == 2 {
                let shift = key(numbers ? "" : (shifted ? "⇧" : "⇪"), id: "key.shift", wide: true) { [weak self] in
                    guard let self, !self.numbers else { return }
                    self.shifted.toggle()
                }
                shift.accessibilityLabel = "shift"
                let delete = key("⌫", id: "key.delete", wide: true) { [weak self] in self?.onKey?(.delete) }
                delete.accessibilityLabel = "delete"
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(deleteHeld(_:)))
                hold.minimumPressDuration = 0.4
                delete.addGestureRecognizer(hold)
                views.insert(shift, at: 0)
                views.append(delete)
            }
            rows.addArrangedSubview(row(views))
        }
        let toggle = key(numbers ? "ABC" : "123", id: "key.mode", wide: true) { [weak self] in self?.numbers.toggle() }
        let space = key("space", id: "key.space") { [weak self] in
            self?.onKey?(.space)
        }
        let enter = key("return", id: "key.return", wide: true) { [weak self] in self?.onKey?(.return) }
        let bottom = row([toggle, space, enter])
        space.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.5).isActive = true
        rows.addArrangedSubview(bottom)
    }

    private func row(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 5
        stack.distribution = .fill
        let regular = views.filter { ($0 as? KeyButton)?.wide == false }
        if let first = regular.first {
            for view in regular.dropFirst() { view.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true }
        }
        for view in views where (view as? KeyButton)?.wide == true {
            if let first = regular.first, regular.count > 3 {
                view.widthAnchor.constraint(equalTo: first.widthAnchor, multiplier: 1.4).isActive = true
            }
        }
        return stack
    }

    private func key(_ title: String, id: String, wide: Bool = false, action: @escaping () -> Void) -> KeyButton {
        let button = KeyButton(wide: wide, action: action)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id
        return button
    }

    @objc private func deleteHeld(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onKey?(.delete) }
            }
        case .ended, .cancelled, .failed:
            deleteTimer?.invalidate()
            deleteTimer = nil
        default: break
        }
    }
}

final class KeyButton: UIButton {
    let wide: Bool
    private let action: () -> Void

    init(wide: Bool, action: @escaping () -> Void) {
        self.wide = wide
        self.action = action
        super.init(frame: .zero)
        backgroundColor = wide ? .systemGray4 : .systemBackground
        layer.cornerRadius = 5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        setTitleColor(.label, for: .normal)
        titleLabel?.font = .systemFont(ofSize: wide ? 16 : 22)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        UIDevice.current.playInputClick()
        action()
    }
}
