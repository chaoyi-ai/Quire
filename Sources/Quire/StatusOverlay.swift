import AppKit

extension NSViewController {
    /// 把状态胶囊（字数等）贴到本视图右下角；从旧父视图移走
    @MainActor
    func attachStatusOverlay(_ v: NSView, bottomInset: CGFloat = 10) {
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -bottomInset),
        ])
    }
}
