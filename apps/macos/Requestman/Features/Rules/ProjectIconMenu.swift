import AppKit

/// Native palette rows supply pointer, keyboard and accessibility behavior.
@MainActor enum ProjectIconMenu {
    private static let choices: [(name: String, symbol: String)] = [
        ("文件夹", "folder"), ("网络", "network"), ("地球", "globe"), ("服务器", "server.rack"),
        ("终端", "terminal"), ("代码", "curlybraces"),
        ("工具", "wrench.and.screwdriver"), ("星标", "star"), ("闪电", "bolt"), ("盒子", "shippingbox"),
        ("归档", "archivebox"), ("收件箱", "tray"),
        ("文档", "doc"), ("文本", "doc.text"), ("文档组", "doc.on.doc"), ("书籍", "book.closed"),
        ("书签", "bookmark"), ("标签", "tag"),
        ("旗标", "flag"), ("收藏", "heart"), ("火焰", "flame"), ("叶片", "leaf"),
        ("星光", "sparkles"), ("链接", "link"),
        ("无线网络", "wifi"), ("天线", "antenna.radiowaves.left.and.right"), ("云端", "cloud"),
        ("外置存储", "externaldrive"), ("内置存储", "internaldrive"), ("桌面电脑", "desktopcomputer"),
        ("笔记本", "laptopcomputer"), ("手机", "iphone"), ("平板", "ipad"), ("手表", "applewatch"),
        ("浏览器", "safari"), ("网页代码", "chevron.left.forwardslash.chevron.right"),
        ("构建", "hammer"), ("设置", "gearshape"), ("处理器", "cpu"), ("内存", "memorychip"),
        ("锁定", "lock"), ("安全", "shield"),
        ("钥匙", "key"), ("调试", "ladybug"), ("测试", "testtube.2"), ("时间", "clock"),
        ("计时", "timer"), ("性能", "speedometer")
    ]

    static func make(selected: String, onSelect: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu(title: "修改图标")
        let available = choices.compactMap { choice -> (String, String, NSImage)? in
            guard let image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: choice.name) else { return nil }
            let symbol = image.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) ?? image
            // Palette menus render template images in their own image slot. Keep
            // the canvas tight: extra transparent padding also gets scaled down.
            // The native palette supplies the surrounding space and hit target.
            let preview = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
                let scale = 16 / max(symbol.size.width, symbol.size.height)
                let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                      width: size.width, height: size.height))
                return true
            }
            preview.isTemplate = true
            preview.accessibilityDescription = choice.name
            return (choice.name, choice.symbol, preview)
        }
        for start in stride(from: 0, to: available.count, by: 6) {
            let palette = NSMenu()
            palette.presentationStyle = .palette
            palette.selectionMode = .selectOne
            for (name, symbol, image) in available[start..<min(start + 6, available.count)] {
                let choice = RulesMenuItem("") { [weak menu] in
                    // The selection is global across all palette rows.
                    for item in menu?.items.flatMap({ $0.submenu?.items ?? [] }) ?? [] {
                        item.state = item.representedObject as? String == symbol ? .on : .off
                    }
                    onSelect(symbol)
                }
                choice.image = image
                if #available(macOS 27.0, *) { choice.preferredImageVisibility = .visible }
                choice.toolTip = name
                choice.setAccessibilityLabel(name)
                choice.representedObject = symbol
                choice.state = symbol == selected ? .on : .off
                palette.addItem(choice)
            }
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.submenu = palette
            menu.addItem(row)
        }
        return menu
    }
}
