import UIKit

/// Three rows of letters (or numbers and punctuation) with shift; space, delete and return live in the keyboard's utility row.
final class KeysView: UIView {
    enum Key {
        case character(String)
    }

    var onKey: ((Key) -> Void)?
    private var shifted = true { didSet { rebuild() } }
    private var numbers = false { didSet { rebuild() } }
    private let rows = UIStackView()

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
                let mode = key(numbers ? "ABC" : "123", id: "key.mode", wide: true) { [weak self] in self?.numbers.toggle() }
                views.insert(shift, at: 0)
                views.append(mode)
            }
            rows.addArrangedSubview(row(views))
        }
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
}

final class KeyButton: UIButton {
    let wide: Bool
    private let action: () -> Void

    init(wide: Bool, action: @escaping () -> Void) {
        self.wide = wide
        self.action = action
        super.init(frame: .zero)
        backgroundColor = wide ? Palette.insertion : Palette.surface
        layer.cornerRadius = 8
        layer.borderWidth = 0.5
        layer.borderColor = Palette.separator.cgColor
        setTitleColor(Palette.text, for: .normal)
        titleLabel?.font = .systemFont(ofSize: wide ? 16 : 22)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layer.borderColor = Palette.separator.resolvedColor(with: traitCollection).cgColor
    }

    @objc private func tapped() {
        UIDevice.current.playInputClick()
        action()
    }
}
