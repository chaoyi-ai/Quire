import AppKit

// Quire 入口。不用 @main + storyboard，纯代码装配（启动更快、无 nib 解析）。
let app = NSApplication.shared
// 必须在任何 NSDocumentController.shared 访问之前实例化，成为共享控制器
_ = QuireDocumentController()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
