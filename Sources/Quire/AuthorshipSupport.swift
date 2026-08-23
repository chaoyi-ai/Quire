import AppKit
import QuireCore
import QuireRender

/// 编辑 → 著作归属 子菜单（动态：作者列表随当前文档变）与窗口控制器上的动作
@MainActor
enum AuthorshipMenu {
    static func build() -> NSMenu {
        let m = NSMenu(title: L("著作归属"))
        m.delegate = delegate
        m.autoenablesItems = true
        return m
    }

    @MainActor static let delegate = Delegate()

    final class Delegate: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            MainActor.assumeIsolated {
                menu.removeAllItems()
                let on = menu.addItem(withTitle: L("著作归属"), action: #selector(DocumentWindowController.toggleAuthorship(_:)), keyEquivalent: "A")
                on.keyEquivalentModifierMask = [.command, .shift]
                on.state = Preferences.shared.authorship ? .on : .off
                menu.addItem(.separator())
                let doc = NSDocumentController.shared.currentDocument as? MarkdownDocument
                let authorship = doc?.authorship ?? Authorship()
                func authorsMenu(_ title: String, action: Selector, selected: String?, allowNone: Bool) -> NSMenuItem {
                    let sub = NSMenu(title: title)
                    for a in authorship.authors {
                        let it = sub.addItem(withTitle: a.name, action: action, keyEquivalent: "")
                        it.representedObject = a.id
                        it.image = swatch(a.color)
                        if a.id == selected { it.state = .on }
                    }
                    if allowNone { sub.addItem(.separator()); let n = sub.addItem(withTitle: L("无归属"), action: action, keyEquivalent: ""); n.representedObject = "" }
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.submenu = sub
                    return item
                }
                menu.addItem(authorsMenu(L("当前作者"), action: #selector(DocumentWindowController.setCurrentAuthor(_:)), selected: Preferences.shared.authorshipAuthor, allowNone: false))
                menu.addItem(authorsMenu(L("以作者粘贴"), action: #selector(DocumentWindowController.pasteAsAuthor(_:)), selected: nil, allowNone: false))
                menu.addItem(authorsMenu(L("标记选区为"), action: #selector(DocumentWindowController.markSelectionAsAuthor(_:)), selected: nil, allowNone: true))
                menu.addItem(.separator())
                menu.addItem(withTitle: L("添加作者…"), action: #selector(DocumentWindowController.addAuthor(_:)), keyEquivalent: "")
                menu.addItem(withTitle: L("归属统计…"), action: #selector(DocumentWindowController.showAuthorshipStats(_:)), keyEquivalent: "")
            }
        }

        private func swatch(_ hex: String) -> NSImage {
            let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                ((ThemeColor(hex: hex) ?? ThemeColor(hex: "#888888")!).nsColor).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
                return true
            }
            return img
        }
    }
}

extension DocumentWindowController {
    /// 读入时注释块哈希对不上：提示一次（区间已丢弃，作者表保留）
    func noteAuthorshipMismatchIfNeeded() {
        guard let doc = markdownDocument, doc.authorshipMismatch, let window else { return }
        doc.authorshipMismatch = false
        let a = NSAlert()
        a.messageText = L("著作归属标记已丢弃")
        a.informativeText = L("这份文件的正文在 Quire 之外被修改过，文件尾的著作归属标记对不上了，已丢弃（作者列表保留）。之后的键入与粘贴会重新记录。")
        a.addButton(withTitle: L("好"))
        a.beginSheetModal(for: window)
    }

    @objc func toggleAuthorship(_ sender: Any?) {
        Preferences.shared.authorship.toggle()
        if Preferences.shared.authorship, markdownDocument?.authorship == nil { markdownDocument?.authorship = Authorship() }
        if mode == .reader || mode == .hybrid { setModeSplit(nil) }
        editorViewController.pushAuthorshipColors()
    }

    @objc func setCurrentAuthor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, !id.isEmpty else { return }
        Preferences.shared.authorshipAuthor = id
    }

    @objc func pasteAsAuthor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, !id.isEmpty, let doc = markdownDocument else { return }
        if !Preferences.shared.authorship { Preferences.shared.authorship = true }
        if doc.authorship == nil { doc.authorship = Authorship() }
        doc.nextPasteAuthor = id
        if mode == .reader || mode == .hybrid { setModeSplit(nil) }
        guard hasEditorPane else { NSSound.beep(); return }
        editorViewController.textView.paste(nil)
    }

    @objc func markSelectionAsAuthor(_ sender: NSMenuItem) {
        guard let doc = markdownDocument, hasEditorPane else { NSSound.beep(); return }
        let id = (sender.representedObject as? String) ?? ""
        let sel = editorViewController.textView.selectedRange()
        guard sel.length > 0 else { NSSound.beep(); return }
        if doc.authorship == nil { doc.authorship = Authorship() }
        doc.authorship?.assign(start: sel.location, length: sel.length, author: id.isEmpty ? nil : id)
        doc.updateChangeCount(.changeDone)
        editorViewController.pushAuthorshipColors()
    }

    @objc func addAuthor(_ sender: Any?) {
        guard let doc = markdownDocument else { return }
        let a = NSAlert()
        a.messageText = L("添加作者")
        a.informativeText = L("作者名会存在这份文件的著作归属块里；颜色自动分配。")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.placeholderString = L("例如：编辑、ChatGPT、张三")
        a.accessoryView = tf
        a.addButton(withTitle: L("添加")); a.addButton(withTitle: L("取消"))
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if doc.authorship == nil { doc.authorship = Authorship() }
        let author = doc.authorship!.addAuthor(named: name)
        Preferences.shared.authorshipAuthor = author.id
        doc.updateChangeCount(.changeDone)
    }

    @objc func showAuthorshipStats(_ sender: Any?) {
        guard let doc = markdownDocument else { return }
        let a = NSAlert()
        a.messageText = L("归属统计")
        guard let au = doc.authorship, !au.spans.isEmpty else { a.informativeText = L("这份文件还没有归属记录。打开 编辑 → 著作归属 后，新键入与粘贴的文字会被记录。"); a.runModal(); return }
        let total = (doc.source as NSString).length
        let counts = au.characterCounts
        var lines: [String] = []
        for author in au.authors { if let c = counts[author.id] { lines.append(String(format: "%@：%d 字（%.0f%%）", author.name, c, Double(c) / Double(max(1, total)) * 100)) } }
        let attributed = total - counts.values.reduce(0, +)
        if attributed > 0 { lines.append(String(format: L("无归属：%d 字（%.0f%%）"), attributed, Double(attributed) / Double(max(1, total)) * 100)) }
        a.informativeText = lines.joined(separator: "\n")
        a.runModal()
    }
}
