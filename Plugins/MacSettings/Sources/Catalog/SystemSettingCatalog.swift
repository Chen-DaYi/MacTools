import Foundation
import MacToolsPluginKit

@MainActor
struct SystemSettingRecord {
    let definition: SystemSettingDefinition
    let adapter: any SystemSettingAdapter

    var id: SystemSettingID { definition.id }
}

enum SystemSettingCatalogValidationError: Error, Equatable {
    case duplicateID(SystemSettingID)
    case emptyID
    case invalidSchema(SystemSettingID)
    case invalidDefaultValue(SystemSettingID)
    case missingSearchMetadata(SystemSettingID)
    case sensitivePortableValue(SystemSettingID)
}

@MainActor
struct SystemSettingCatalog {
    let records: [SystemSettingRecord]

    init(records: [SystemSettingRecord]) throws {
        var ids: Set<SystemSettingID> = []
        for record in records {
            let definition = record.definition
            guard !definition.id.rawValue.isEmpty else {
                throw SystemSettingCatalogValidationError.emptyID
            }
            guard ids.insert(definition.id).inserted else {
                throw SystemSettingCatalogValidationError.duplicateID(definition.id)
            }
            guard definition.schema.isValid else {
                throw SystemSettingCatalogValidationError.invalidSchema(definition.id)
            }
            if let defaultValue = definition.defaultValue,
               !definition.schema.accepts(defaultValue) {
                throw SystemSettingCatalogValidationError.invalidDefaultValue(definition.id)
            }
            guard !definition.title.isEmpty,
                  !definition.description.isEmpty,
                  !definition.searchTerms.isEmpty else {
                throw SystemSettingCatalogValidationError.missingSearchMetadata(definition.id)
            }
            guard !definition.isSensitive || definition.portability != .portable else {
                throw SystemSettingCatalogValidationError.sensitivePortableValue(definition.id)
            }
        }
        self.records = records
    }

    subscript(id: SystemSettingID) -> SystemSettingRecord? {
        records.first { $0.id == id }
    }

    func search(_ query: String, in records: [SystemSettingRecord]? = nil) -> [SystemSettingRecord] {
        let candidates = records ?? self.records
        let tokens = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return candidates }

        return candidates.compactMap { record -> (SystemSettingRecord, Int)? in
            let definition = record.definition
            let title = definition.title.lowercased()
            let document = definition.searchDocument
            guard tokens.allSatisfy({ document.contains($0) }) else { return nil }
            let score = tokens.reduce(into: 0) { score, token in
                if title == token { score += 100 }
                else if title.hasPrefix(token) { score += 60 }
                else if title.contains(token) { score += 40 }
                else if definition.searchTerms.contains(where: { $0.lowercased() == token }) { score += 25 }
                else { score += 10 }
            }
            return (record, score)
        }
        .sorted {
            if $0.1 == $1.1 {
                return $0.0.definition.title.localizedCompare($1.0.definition.title) == .orderedAscending
            }
            return $0.1 > $1.1
        }
        .map(\.0)
    }
}

@MainActor
enum MacSettingsCatalogFactory {
    static let globalDomain = UserDefaults.globalDomain
    static let finderDomain = "com.apple.finder"
    static let dockDomain = "com.apple.dock"
    static let screenshotDomain = "com.apple.screencapture"
    static let trackpadDomain = "com.apple.AppleMultitouchTrackpad"
    static let bluetoothTrackpadDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"

    static func make(
        actionContext: @escaping () -> PluginActionExecutionHostContext?
    ) throws -> SystemSettingCatalog {
        let records: [SystemSettingRecord] = [
            direct(
                id: "accessibility.three-finger-drag",
                title: "三指拖移",
                description: "使用三根手指拖移窗口和项目。",
                category: .accessibility,
                systemImage: "hand.draw",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["drag window trackpad", "three finger drag", "拖动窗口", "触控板"],
                destination: accessibilityDestination("PointerControl"),
                note: "Uses the runtime-validated System Settings trackpad backend for an immediate hardware update, then verifies both built-in and Bluetooth preference domains.",
                adapter: LiveTrackpadBooleanSystemSettingAdapter(
                    threeFingerDragPersistedAdapter: CompositeBooleanSystemSettingAdapter(adapters: [
                        DefaultsSystemSettingAdapter.boolean(
                            domain: trackpadDomain,
                            key: "TrackpadThreeFingerDrag",
                            defaultValue: false
                        ),
                        DefaultsSystemSettingAdapter.boolean(
                            domain: bluetoothTrackpadDomain,
                            key: "TrackpadThreeFingerDrag",
                            defaultValue: false
                        ),
                    ])
                )
            ),
            direct(
                id: "accessibility.pointer-size",
                title: "指针大小",
                description: "让屏幕上的指针更容易看清。",
                category: .accessibility,
                systemImage: "cursorarrow",
                schema: .decimal(range: 1 ... 4, step: 0.1),
                defaultValue: .decimal(1),
                requirements: .init(requiredPermissionID: MacSettingsPermission.fullDiskAccess),
                searchTerms: ["large cursor", "pointer size", "大光标", "鼠标指针"],
                destination: accessibilityDestination("Display"),
                note: "Requires Full Disk Access because macOS protects the persisted Universal Access domain. After authorization and an app relaunch, MacTools persists the allowlisted cursor key, invokes Apple's live cursor rebuild, and verifies WindowServer's active scale.",
                adapter: UniversalAccessSystemSettingAdapter.cursorSize()
            ),
            direct(
                id: "accessibility.keyboard-zoom",
                title: "使用键盘快捷键缩放",
                description: "使用 Option–Command 快捷键缩放屏幕。",
                category: .accessibility,
                systemImage: "plus.magnifyingglass",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["zoom keyboard", "keyboard shortcuts to zoom", "屏幕缩放", "放大"],
                destination: accessibilityDestination("Zoom"),
                note: "Uses Apple's live keyboard-zoom setter so the zoom shortcuts are enabled immediately.",
                adapter: UniversalAccessSystemSettingAdapter.keyboardZoom()
            ),
            direct(
                id: "accessibility.scroll-zoom",
                title: "使用滚动手势缩放",
                description: "按住修饰键并滚动来缩放屏幕。",
                category: .accessibility,
                systemImage: "scroll",
                schema: .boolean,
                defaultValue: .boolean(false),
                searchTerms: ["scroll gesture zoom", "modifier zoom", "滚动缩放", "修饰键缩放"],
                destination: accessibilityDestination("Zoom"),
                note: "Uses Apple's live scroll-zoom setter, which updates the active HID modifier binding immediately.",
                adapter: UniversalAccessSystemSettingAdapter.scrollZoom()
            ),
            direct(
                id: "accessibility.scroll-zoom-modifier",
                title: "滚动手势修饰键",
                description: "选择配合滚动手势使用的修饰键。",
                category: .accessibility,
                systemImage: "command",
                schema: .choice(options: [
                    .init(id: "control", title: "⌃ Control"),
                    .init(id: "option", title: "⌥ Option"),
                    .init(id: "command", title: "⌘ Command"),
                ]),
                defaultValue: .choice(id: "control"),
                searchTerms: ["scroll zoom modifier", "modifier", "control option command", "缩放修饰键", "滚动手势按键"],
                destination: accessibilityDestination("Zoom"),
                note: "Maps Apple's supported modifiers and applies the selected binding to the active HID zoom gesture immediately.",
                adapter: UniversalAccessSystemSettingAdapter.scrollZoomModifier(
                    defaultID: "control",
                    values: [
                        "control": 262_144,
                        "option": 524_288,
                        "command": 1_048_576,
                    ]
                )
            ),
            guided(
                id: "accessibility.full-keyboard-access",
                title: "全键盘控制",
                description: "使用 Tab 键和其他按键在屏幕控制项之间移动。",
                category: .accessibility,
                systemImage: "keyboard.badge.ellipsis",
                schema: .boolean,
                defaultValue: .boolean(false),
                executionClass: .guidedManual,
                searchTerms: ["full keyboard access", "keyboard navigation", "全键盘访问", "Tab 导航"],
                destination: accessibilityDestination("Keyboard"),
                note: "Open Accessibility Keyboard settings; direct activation remains deferred until a stable live setter and verification path are validated."
            ),
            guided(
                id: "accessibility.sticky-keys",
                title: "粘滞键",
                description: "依次按下修饰键来输入组合键。",
                category: .accessibility,
                systemImage: "command",
                schema: .boolean,
                defaultValue: .boolean(false),
                executionClass: .guidedManual,
                searchTerms: ["sticky keys", "modifier keys", "粘滞键", "组合键"],
                destination: accessibilityDestination("Keyboard"),
                note: "Open Accessibility Keyboard settings; direct activation remains deferred until a stable live setter and verification path are validated."
            ),
            guided(
                id: "accessibility.slow-keys",
                title: "慢速键",
                description: "调整按键被接受前需要按住的时间。",
                category: .accessibility,
                systemImage: "timer",
                schema: .boolean,
                defaultValue: .boolean(false),
                executionClass: .guidedManual,
                searchTerms: ["slow keys", "acceptance delay", "慢速键", "按键延迟"],
                destination: accessibilityDestination("Keyboard"),
                note: "Open Accessibility Keyboard settings; direct activation remains deferred until a stable live setter and verification path are validated."
            ),
            guided(
                id: "input.secondary-click",
                title: "辅助点按",
                description: "选择使用触控板进行右键点按的手势。",
                category: .input,
                systemImage: "hand.point.up.left",
                schema: .boolean,
                defaultValue: .boolean(true),
                executionClass: .guidedManual,
                searchTerms: ["secondary click", "right click", "辅助点按", "右键"],
                destination: inputDestination,
                note: "Open Trackpad settings; the gesture choice uses coupled device-specific state that is not yet safely represented by one Boolean."
            ),
            guided(
                id: "input.scroll-speed",
                title: "滚动速度",
                description: "调整鼠标或触控板滚动内容的速度。",
                category: .input,
                systemImage: "scroll",
                schema: .decimal(range: 0 ... 10, step: 0.1),
                defaultValue: .decimal(5),
                executionClass: .guidedManual,
                searchTerms: ["scroll speed", "wheel speed", "滚轮速度"],
                destination: inputDestination,
                note: "Open Pointer Control settings; direct support remains deferred until separate mouse and trackpad live backends can be verified."
            ),
            direct(
                id: "input.tap-to-click",
                title: "轻点来点按",
                description: "轻点触控板即可执行点按。",
                category: .input,
                systemImage: "hand.tap",
                schema: .boolean,
                defaultValue: .boolean(false),
                executionClass: .hardwareDependent,
                searchTerms: ["tap to click", "touch click", "触控板轻点"],
                destination: inputDestination,
                note: "Uses the runtime-validated System Settings trackpad backend, then verifies the active tap behavior and both preference domains.",
                adapter: LiveTrackpadBooleanSystemSettingAdapter(
                    tapToClickPersistedAdapter: CompositeBooleanSystemSettingAdapter(adapters: [
                        DefaultsSystemSettingAdapter.boolean(
                            domain: trackpadDomain,
                            key: "Clicking",
                            defaultValue: false
                        ),
                        DefaultsSystemSettingAdapter.boolean(
                            domain: bluetoothTrackpadDomain,
                            key: "Clicking",
                            defaultValue: false
                        ),
                    ])
                )
            ),
            domainBoolean(
                id: "input.natural-scrolling",
                title: "自然滚动",
                description: "按手指移动方向滚动内容。",
                category: .input,
                domain: globalDomain,
                key: "com.apple.swipescrolldirection",
                defaultValue: true,
                searchTerms: ["natural scrolling", "reverse scroll", "滚动方向"],
                destination: inputDestination,
                notificationName: Notification.Name("SwipeScrollDirectionDidChangeNotification")
            ),
            defaultsDecimal(
                id: "input.mouse-tracking-speed",
                title: "鼠标跟踪速度",
                description: "调整鼠标指针移动速度。",
                category: .input,
                key: "com.apple.mouse.scaling",
                defaultValue: 1,
                range: 0 ... 3,
                step: 0.1,
                searchTerms: ["mouse tracking speed", "pointer speed", "鼠标速度"],
                destination: mouseDestination,
                executionClass: .directRequiresLogout
            ),
            direct(
                id: "input.trackpad-tracking-speed",
                title: "触控板跟踪速度",
                description: "调整触控板指针移动速度。",
                category: .input,
                systemImage: "slider.horizontal.3",
                schema: .decimal(range: 0 ... 3, step: 0.1),
                defaultValue: .decimal(1),
                executionClass: .hardwareDependent,
                searchTerms: ["trackpad tracking speed", "pointer speed", "触控板速度"],
                destination: inputDestination,
                note: "Uses the runtime-validated System Settings trackpad backend and verifies the active tracking speed.",
                adapter: LiveTrackpadDecimalSystemSettingAdapter(
                    persistedAdapter: DefaultsSystemSettingAdapter.decimal(
                        domain: globalDomain,
                        key: "com.apple.trackpad.scaling",
                        defaultValue: 1
                    )
                )
            ),
            defaultsInteger(
                id: "keyboard.key-repeat",
                title: "按键重复速度",
                description: "调整按住按键时字符重复的速度。",
                key: "KeyRepeat",
                defaultValue: 6,
                range: 1 ... 15,
                searchTerms: ["key repeat rate", "typing repeat", "按键连发"],
                executionClass: .directRequiresLogout
            ),
            defaultsInteger(
                id: "keyboard.initial-key-repeat",
                title: "重复前延迟",
                description: "调整按住按键后开始重复前的等待时间。",
                key: "InitialKeyRepeat",
                defaultValue: 25,
                range: 10 ... 120,
                searchTerms: ["delay until repeat", "key repeat delay", "重复延迟"],
                executionClass: .directRequiresLogout
            ),
            domainBoolean(
                id: "keyboard.function-keys",
                title: "将 F1、F2 等键用作标准功能键",
                description: "直接使用功能键，按住 Fn 键来使用特殊功能。",
                category: .keyboard,
                domain: globalDomain,
                key: "com.apple.keyboard.fnState",
                defaultValue: false,
                searchTerms: ["function keys", "standard F keys", "Fn 键"],
                destination: keyboardDestination,
                notificationName: Notification.Name("com.apple.keyboard.fnstatedidchange")
            ),
            finderBoolean(
                id: "finder.show-all-extensions",
                title: "显示所有文件扩展名",
                description: "在访达中显示所有文件名扩展名。",
                key: "AppleShowAllExtensions",
                defaultValue: false,
                searchTerms: ["show extension", "filename extension", "文件后缀"],
                executionClass: .directRequiresRestart
            ),
            finderBoolean(
                id: "finder.warn-extension-change",
                title: "更改扩展名之前显示警告",
                description: "更改文件扩展名时先显示确认警告。",
                key: "FXEnableExtensionChangeWarning",
                defaultValue: true,
                searchTerms: ["extension warning", "change filename extension", "扩展名警告"],
                executionClass: .directAppliesNextUse
            ),
            finderBoolean(
                id: "finder.warn-empty-trash",
                title: "清倒废纸篓之前显示警告",
                description: "永久移除废纸篓项目之前要求确认。",
                key: "WarnOnEmptyTrash",
                defaultValue: true,
                searchTerms: ["empty trash warning", "trash confirmation", "清倒废纸篓警告"],
                executionClass: .directAppliesNextUse
            ),
            finderBoolean(
                id: "finder.folders-first",
                title: "按名称排序时文件夹置顶",
                description: "在访达窗口中先显示文件夹，再显示文件。",
                key: "_FXSortFoldersFirst",
                defaultValue: false,
                searchTerms: ["folders on top", "sort folders first", "文件夹置顶"],
                executionClass: .directRequiresRestart
            ),
            finderBoolean(
                id: "finder.show-path-bar",
                title: "显示路径栏",
                description: "在访达窗口底部显示当前位置路径。",
                key: "ShowPathbar",
                defaultValue: false,
                searchTerms: ["finder path bar", "show path", "路径栏"],
                executionClass: .directRequiresRestart
            ),
            finderBoolean(
                id: "finder.show-status-bar",
                title: "显示状态栏",
                description: "在访达窗口底部显示项目数量和可用空间。",
                key: "ShowStatusBar",
                defaultValue: false,
                searchTerms: ["finder status bar", "free space", "状态栏"],
                executionClass: .directRequiresRestart
            ),
            defaultsChoice(
                id: "finder.search-scope",
                title: "执行搜索时",
                description: "选择访达搜索默认使用的范围。",
                category: .finder,
                domain: finderDomain,
                key: "FXDefaultSearchScope",
                defaultValue: "SCev",
                options: [
                    .init(id: "SCev", title: "搜索这台 Mac"),
                    .init(id: "SCcf", title: "搜索当前文件夹"),
                    .init(id: "SCsp", title: "使用上次的搜索范围"),
                ],
                searchTerms: ["search current folder", "finder search scope", "搜索范围"],
                destination: finderDestination,
                executionClass: .directAppliesNextUse
            ),
            defaultsChoice(
                id: "finder.new-window-target",
                title: "访达新窗口显示",
                description: "选择新访达窗口的默认位置。",
                category: .finder,
                domain: finderDomain,
                key: "NewWindowTarget",
                defaultValue: "PfHm",
                options: [
                    .init(id: "PfHm", title: "个人文件夹"),
                    .init(id: "PfDe", title: "桌面"),
                    .init(id: "PfDo", title: "文稿"),
                    .init(id: "PfCm", title: "电脑"),
                ],
                searchTerms: ["new finder window destination", "finder opens", "新窗口位置"],
                destination: finderDestination,
                executionClass: .directAppliesNextUse
            ),
            providerBoolean(
                id: "dock.auto-hide",
                title: "自动隐藏程序坞",
                description: "不使用时自动隐藏程序坞。",
                category: .desktopAndDock,
                providerID: "auto-hide-dock",
                actionID: "set-enabled",
                readDomain: dockDomain,
                readKey: "autohide",
                defaultValue: false,
                searchTerms: ["dock disappear", "automatically hide dock", "隐藏 Dock"],
                destination: dockDestination,
                actionContext: actionContext
            ),
            defaultsDecimal(
                id: "dock.size",
                title: "程序坞大小",
                description: "调整程序坞图标的基础大小。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "tilesize",
                defaultValue: 48,
                range: 16 ... 128,
                step: 1,
                searchTerms: ["dock size", "dock icon size", "程序坞大小", "Dock 图标"],
                destination: dockDestination,
                dockPreference: .dockSize
            ),
            defaultsChoice(
                id: "dock.position",
                title: "程序坞位置",
                description: "选择程序坞显示在屏幕哪一侧。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "orientation",
                defaultValue: "bottom",
                options: [
                    .init(id: "left", title: "左侧"),
                    .init(id: "bottom", title: "底部"),
                    .init(id: "right", title: "右侧"),
                ],
                searchTerms: ["dock position", "dock left right", "程序坞位置"],
                destination: dockDestination,
                dockPreference: .screenEdge
            ),
            domainBoolean(
                id: "dock.magnification",
                title: "程序坞放大",
                description: "指针移过图标时将其放大。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "magnification",
                defaultValue: false,
                searchTerms: ["dock magnification", "dock icons bigger", "图标放大"],
                destination: dockDestination,
                dockPreference: .magnification
            ),
            defaultsDecimal(
                id: "dock.magnification-size",
                title: "程序坞放大尺寸",
                description: "调整程序坞图标放大后的大小。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "largesize",
                defaultValue: 64,
                range: 16 ... 128,
                step: 1,
                searchTerms: ["dock magnification size", "large dock icons", "放大尺寸"],
                destination: dockDestination,
                dockPreference: .magnificationSize
            ),
            defaultsChoice(
                id: "dock.minimize-effect",
                title: "最小化窗口效果",
                description: "选择窗口最小化到程序坞时的动画。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "mineffect",
                defaultValue: "genie",
                options: [
                    .init(id: "genie", title: "神奇效果"),
                    .init(id: "scale", title: "缩放效果"),
                ],
                searchTerms: ["minimize effect", "genie scale", "最小化动画"],
                destination: dockDestination,
                dockPreference: .minimizeEffect
            ),
            domainBoolean(
                id: "dock.show-recents",
                title: "在程序坞中显示最近使用的 App",
                description: "在固定 App 旁显示最近使用的应用。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "show-recents",
                defaultValue: true,
                searchTerms: ["recent apps dock", "show recents", "最近使用 App"],
                destination: dockDestination,
                dockPreference: .showRecents
            ),
            domainBoolean(
                id: "dock.minimize-into-application",
                title: "将窗口最小化至应用程序图标",
                description: "把最小化窗口收进对应的 App 图标。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "minimize-to-application",
                defaultValue: false,
                searchTerms: ["minimize into application icon", "dock window icon", "最小化至图标"],
                destination: dockDestination,
                dockPreference: .minimizeIntoApplication
            ),
            domainBoolean(
                id: "dock.animate-opening-applications",
                title: "打开应用程序时显示动画",
                description: "启动 App 时让程序坞图标弹跳。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "launchanim",
                defaultValue: true,
                searchTerms: ["animate opening applications", "bouncing dock icon", "启动动画"],
                destination: dockDestination,
                dockPreference: .animate
            ),
            domainBoolean(
                id: "dock.show-open-indicators",
                title: "为打开的应用程序显示指示灯",
                description: "在运行中的 App 图标下方显示圆点。",
                category: .desktopAndDock,
                domain: dockDomain,
                key: "show-process-indicators",
                defaultValue: true,
                searchTerms: ["show indicators open applications", "running app dot", "运行指示灯"],
                destination: dockDestination,
                dockPreference: .showIndicators
            ),
            defaultsChoice(
                id: "screenshots.format",
                title: "截屏格式",
                description: "选择截屏文件使用的图片格式。",
                category: .screenshots,
                domain: screenshotDomain,
                key: "type",
                defaultValue: "png",
                options: [
                    .init(id: "png", title: "PNG"),
                    .init(id: "jpg", title: "JPEG"),
                    .init(id: "heic", title: "HEIC"),
                    .init(id: "pdf", title: "PDF"),
                    .init(id: "tiff", title: "TIFF"),
                ],
                searchTerms: ["screenshot jpg", "screen capture format", "截屏 JPEG"],
                destination: screenshotDestination,
                executionClass: .directAppliesNextUse
            ),
            domainBoolean(
                id: "screenshots.floating-thumbnail",
                title: "显示浮动缩略图",
                description: "截屏后在屏幕角落短暂显示预览。",
                category: .screenshots,
                domain: screenshotDomain,
                key: "show-thumbnail",
                defaultValue: true,
                searchTerms: ["floating thumbnail", "screenshot preview", "截屏缩略图"],
                destination: screenshotDestination,
                executionClass: .directAppliesNextUse
            ),
            domainBoolean(
                id: "screenshots.window-shadow",
                title: "包括窗口阴影",
                description: "截取窗口时保留窗口周围的阴影。",
                category: .screenshots,
                domain: screenshotDomain,
                key: "disable-shadow",
                defaultValue: true,
                inverted: true,
                searchTerms: ["include window shadow", "screenshot shadow", "窗口阴影"],
                destination: screenshotDestination,
                executionClass: .directAppliesNextUse
            ),
            direct(
                id: "screenshots.destination",
                title: "截屏存储位置",
                description: "选择新截屏文件保存到的文件夹。",
                category: .screenshots,
                systemImage: "folder.badge.gearshape",
                schema: .url,
                defaultValue: .url(FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!),
                executionClass: .directAppliesNextUse,
                portability: .deviceSpecific,
                searchTerms: ["screenshot destination", "save screenshots", "截屏保存位置"],
                destination: screenshotDestination,
                note: "Stores and verifies a local directory path in the screencapture preference domain.",
                adapter: DefaultsSystemSettingAdapter.directoryURL(
                    domain: screenshotDomain,
                    key: "location",
                    defaultValue: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
                )
            ),
            providerBoolean(
                id: "appearance.dark-mode",
                title: "深色模式",
                description: "在浅色与深色系统外观之间切换。",
                category: .appearance,
                providerID: "appearance",
                actionID: "set-enabled",
                readDomain: globalDomain,
                readKey: "AppleInterfaceStyle",
                defaultValue: false,
                readBoolean: { ($0 as? String) == "Dark" },
                searchTerms: ["dark mode", "light appearance", "深色外观"],
                destination: appearanceDestination,
                actionContext: actionContext
            ),
            defaultsChoice(
                id: "appearance.show-scroll-bars",
                title: "显示滚动条",
                description: "选择窗口中的滚动条何时可见。",
                category: .appearance,
                domain: globalDomain,
                key: "AppleShowScrollBars",
                defaultValue: "Automatic",
                options: [
                    .init(id: "Automatic", title: "根据鼠标或触控板自动显示"),
                    .init(id: "WhenScrolling", title: "滚动时"),
                    .init(id: "Always", title: "始终"),
                ],
                searchTerms: ["show scroll bars", "scrollbar visibility", "显示滚动条"],
                destination: appearanceDestination,
                executionClass: .directAppliesNextUse
            ),
            domainBoolean(
                id: "appearance.scroll-bar-click-jumps-to-spot",
                title: "点按滚动条时跳到点按位置",
                description: "点按滚动条时直接移动到对应位置，而不是翻到下一页。",
                category: .appearance,
                domain: globalDomain,
                key: "AppleScrollerPagingBehavior",
                defaultValue: false,
                searchTerms: ["click scroll bar jump", "scrollbar paging", "滚动条点按位置"],
                destination: appearanceDestination,
                executionClass: .directAppliesNextUse
            ),
            providerBooleanFromActionState(
                id: "display.true-tone",
                title: "原彩显示",
                description: "根据环境光自动调节显示器颜色。",
                category: .display,
                providerID: "display-true-color",
                readActionID: "toggle",
                writeActionID: "set-enabled",
                defaultValue: false,
                searchTerms: ["true tone", "display color", "原彩显示", "环境光"],
                destination: displayDestination,
                actionContext: actionContext
            ),
            providerBooleanFromActionState(
                id: "display.night-shift",
                title: "夜览",
                description: "在较暗环境中让显示器颜色变暖。",
                category: .display,
                providerID: "night-shift",
                readActionID: "toggle",
                writeActionID: "set-enabled",
                defaultValue: false,
                searchTerms: ["night shift", "warm display", "夜览", "蓝光"],
                destination: displayDestination,
                actionContext: actionContext
            ),
            guided(
                id: "power.low-power-mode",
                title: "低电量模式",
                description: "降低能源消耗以延长电池续航时间。",
                category: .power,
                systemImage: "battery.25percent",
                schema: .boolean,
                defaultValue: .boolean(false),
                executionClass: .guidedManual,
                searchTerms: ["low power mode", "energy mode", "低电量模式", "节能"],
                destination: powerDestination,
                note: "Open Battery settings; available choices vary by Mac model and power source."
            ),
            guided(
                id: "network.wifi",
                title: "Wi-Fi",
                description: "管理 Wi-Fi 状态、网络与详细信息。",
                category: .network,
                systemImage: "wifi",
                schema: .boolean,
                defaultValue: .boolean(true),
                executionClass: .guidedManual,
                searchTerms: ["wifi", "wireless network", "无线网络", "网络"],
                destination: networkDestination,
                note: "Open Network settings; credentials and per-service configuration remain outside portable Mac Settings profiles."
            ),
            providerBoolean(
                id: "desktop.menu-bar-auto-hide",
                title: "自动隐藏菜单栏",
                description: "不使用时自动隐藏菜单栏。",
                category: .desktopAndDock,
                providerID: "auto-hide-menu-bar",
                actionID: "set-enabled",
                readDomain: globalDomain,
                readKey: "_HIHideMenuBar",
                defaultValue: false,
                searchTerms: ["auto hide menu bar", "menu bar disappear", "隐藏菜单栏"],
                destination: dockDestination,
                actionContext: actionContext
            ),
            providerBoolean(
                id: "desktop.stage-manager",
                title: "台前调度",
                description: "整理窗口并把最近使用的 App 保留在屏幕一侧。",
                category: .desktopAndDock,
                providerID: "stage-manager",
                actionID: "set-enabled",
                readDomain: "com.apple.WindowManager",
                readKey: "GloballyEnabled",
                defaultValue: false,
                searchTerms: ["stage manager", "window manager", "幕前调度"],
                destination: dockDestination,
                actionContext: actionContext
            ),
        ]
        return try SystemSettingCatalog(records: records)
    }

    private static var finderDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Finder-Settings.extension", anchor: nil)
    }

    private static var dockDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Desktop-Settings.extension", anchor: nil)
    }

    private static var screenshotDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.ScreenCapture-Settings.extension", anchor: nil)
    }

    private static var keyboardDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Keyboard-Settings.extension", anchor: nil)
    }

    private static var inputDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Trackpad-Settings.extension", anchor: nil)
    }

    private static var mouseDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Mouse-Settings.extension", anchor: nil)
    }

    private static var appearanceDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.Appearance-Settings.extension", anchor: nil)
    }

    private static var displayDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.preference.displays", anchor: nil)
    }

    private static var powerDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.preference.energysaver", anchor: nil)
    }

    private static var networkDestination: SystemSettingSystemDestination {
        .init(pane: "com.apple.preference.network", anchor: nil)
    }

    private static func accessibilityDestination(_ anchor: String) -> SystemSettingSystemDestination {
        .init(pane: "com.apple.Accessibility-Settings.extension", anchor: anchor)
    }

    private static func direct(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        systemImage: String,
        schema: SystemSettingValueSchema,
        defaultValue: SystemSettingValue,
        executionClass: SystemSettingExecutionClass = .directVerified,
        requirements: SystemSettingRequirements = .init(),
        portability: SystemSettingPortability = .portable,
        searchTerms: [String],
        destination: SystemSettingSystemDestination?,
        note: String,
        adapter: any SystemSettingAdapter
    ) -> SystemSettingRecord {
        SystemSettingRecord(
            definition: SystemSettingDefinition(
                id: id,
                title: title,
                description: description,
                category: category,
                systemImage: systemImage,
                schema: schema,
                defaultValue: defaultValue,
                executionClass: executionClass,
                requirements: requirements,
                portability: portability,
                isSensitive: false,
                canReset: true,
                canRollback: executionClass != .guidedManual && executionClass != .unsupported,
                verificationAvailable: executionClass != .guidedManual && executionClass != .unsupported,
                searchTerms: searchTerms,
                destination: destination,
                implementationNote: note
            ),
            adapter: adapter
        )
    }

    private static func guided(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        systemImage: String,
        schema: SystemSettingValueSchema,
        defaultValue: SystemSettingValue,
        executionClass: SystemSettingExecutionClass,
        searchTerms: [String],
        destination: SystemSettingSystemDestination?,
        note: String
    ) -> SystemSettingRecord {
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: systemImage,
            schema: schema,
            defaultValue: defaultValue,
            executionClass: executionClass,
            portability: .localOnly,
            searchTerms: searchTerms,
            destination: destination,
            note: note,
            adapter: UnavailableSystemSettingAdapter(message: note)
        )
    }

    private static func defaultsBoolean(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        key: String,
        defaultValue: Bool,
        searchTerms: [String],
        destination: SystemSettingSystemDestination
    ) -> SystemSettingRecord {
        domainBoolean(
            id: id,
            title: title,
            description: description,
            category: category,
            domain: globalDomain,
            key: key,
            defaultValue: defaultValue,
            searchTerms: searchTerms,
            destination: destination
        )
    }

    private static func domainBoolean(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        domain: String,
        key: String,
        defaultValue: Bool,
        inverted: Bool = false,
        searchTerms: [String],
        destination: SystemSettingSystemDestination,
        notificationName: Notification.Name? = nil,
        dockPreference: DockSystemEventsPreference? = nil,
        executionClass: SystemSettingExecutionClass = .directVerified
    ) -> SystemSettingRecord {
        let persistedAdapter = DefaultsSystemSettingAdapter.boolean(
            domain: domain,
            key: key,
            defaultValue: inverted ? !defaultValue : defaultValue,
            inverted: inverted,
            notificationName: notificationName
        )
        let adapter: any SystemSettingAdapter = if let dockPreference {
            DockSystemEventsSettingAdapter(
                persistedAdapter: persistedAdapter,
                preference: dockPreference
            )
        } else {
            persistedAdapter
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "switch.2",
            schema: .boolean,
            defaultValue: .boolean(defaultValue),
            executionClass: executionClass,
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads and writes a curated preference key and verifies the stored value.",
            adapter: adapter
        )
    }

    private static func finderBoolean(
        id: SystemSettingID,
        title: String,
        description: String,
        key: String,
        defaultValue: Bool,
        searchTerms: [String],
        executionClass: SystemSettingExecutionClass = .directVerified
    ) -> SystemSettingRecord {
        domainBoolean(
            id: id,
            title: title,
            description: description,
            category: .finder,
            domain: finderDomain,
            key: key,
            defaultValue: defaultValue,
            searchTerms: searchTerms,
            destination: finderDestination,
            executionClass: executionClass
        )
    }

    private static func defaultsInteger(
        id: SystemSettingID,
        title: String,
        description: String,
        key: String,
        defaultValue: Int,
        range: ClosedRange<Int>,
        searchTerms: [String],
        executionClass: SystemSettingExecutionClass
    ) -> SystemSettingRecord {
        return direct(
            id: id,
            title: title,
            description: description,
            category: .keyboard,
            systemImage: "keyboard",
            schema: .integer(range: range, step: 1),
            defaultValue: .integer(defaultValue),
            executionClass: executionClass,
            searchTerms: searchTerms,
            destination: keyboardDestination,
            note: "Reads and writes the global keyboard repeat preference and verifies persistence.",
            adapter: DefaultsSystemSettingAdapter.integer(
                domain: globalDomain,
                key: key,
                defaultValue: defaultValue
            )
        )
    }

    private static func defaultsDecimal(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        domain: String = globalDomain,
        key: String,
        defaultValue: Double,
        range: ClosedRange<Double>,
        step: Double,
        searchTerms: [String],
        destination: SystemSettingSystemDestination,
        notificationName: Notification.Name? = nil,
        dockPreference: DockSystemEventsPreference? = nil,
        executionClass: SystemSettingExecutionClass = .directVerified
    ) -> SystemSettingRecord {
        let persistedAdapter = DefaultsSystemSettingAdapter.decimal(
            domain: domain,
            key: key,
            defaultValue: defaultValue,
            notificationName: notificationName
        )
        let adapter: any SystemSettingAdapter = if let dockPreference {
            DockSystemEventsSettingAdapter(
                persistedAdapter: persistedAdapter,
                preference: dockPreference
            )
        } else {
            persistedAdapter
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "slider.horizontal.3",
            schema: .decimal(range: range, step: step),
            defaultValue: .decimal(defaultValue),
            executionClass: executionClass,
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads and writes a bounded numeric preference and verifies the stored value.",
            adapter: adapter
        )
    }

    private static func defaultsChoice(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        domain: String,
        key: String,
        defaultValue: String,
        options: [SystemSettingChoice],
        searchTerms: [String],
        destination: SystemSettingSystemDestination,
        notificationName: Notification.Name? = nil,
        dockPreference: DockSystemEventsPreference? = nil,
        executionClass: SystemSettingExecutionClass = .directVerified
    ) -> SystemSettingRecord {
        let persistedAdapter = DefaultsSystemSettingAdapter.choice(
            domain: domain,
            key: key,
            defaultValue: defaultValue,
            notificationName: notificationName
        )
        let adapter: any SystemSettingAdapter = if let dockPreference {
            DockSystemEventsSettingAdapter(
                persistedAdapter: persistedAdapter,
                preference: dockPreference
            )
        } else {
            persistedAdapter
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "list.bullet",
            schema: .choice(options: options),
            defaultValue: .choice(id: defaultValue),
            executionClass: executionClass,
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads and writes an allowlisted preference choice and verifies its stable identifier.",
            adapter: adapter
        )
    }

    private static func providerBoolean(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        providerID: String,
        actionID: String,
        readDomain: String,
        readKey: String,
        defaultValue: Bool,
        readBoolean: @escaping (Any?) -> Bool = { ($0 as? NSNumber)?.boolValue ?? false },
        searchTerms: [String],
        destination: SystemSettingSystemDestination,
        actionContext: @escaping () -> PluginActionExecutionHostContext?
    ) -> SystemSettingRecord {
        let store = ProcessSystemDefaultsDomainStore()
        let reader: () async throws -> SystemSettingValue = {
            .boolean(readBoolean(try store.object(forKey: readKey, inDomain: readDomain)))
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "puzzlepiece.extension",
            schema: .boolean,
            defaultValue: .boolean(defaultValue),
            executionClass: .existingPluginProvider,
            requirements: .init(existingProviderID: providerID),
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads current state and delegates deterministic writes to the existing MacTools canonical action provider.",
            adapter: ExistingPluginActionSettingAdapter(
                reader: reader,
                reference: { value in
                    guard case let .boolean(enabled) = value else {
                        throw SystemSettingAdapterError.invalidValue
                    }
                    return ActionReference(
                        key: ActionKey(providerID: providerID, actionID: actionID),
                        parameters: try ActionParameterSet(["enabled": .boolean(enabled)])
                    )
                },
                context: actionContext
            )
        )
    }

    private static func providerBooleanFromActionState(
        id: SystemSettingID,
        title: String,
        description: String,
        category: SystemSettingCategory,
        providerID: String,
        readActionID: String,
        writeActionID: String,
        defaultValue: Bool,
        searchTerms: [String],
        destination: SystemSettingSystemDestination,
        actionContext: @escaping () -> PluginActionExecutionHostContext?
    ) -> SystemSettingRecord {
        let readReference = ActionReference(
            key: ActionKey(providerID: providerID, actionID: readActionID)
        )
        let reader: () async throws -> SystemSettingValue = {
            guard let item = actionContext()?.item(for: readReference),
                  let presentationState = item.presentationState else {
                throw SystemSettingAdapterError.unreadable
            }
            return .boolean(presentationState == .active)
        }
        return direct(
            id: id,
            title: title,
            description: description,
            category: category,
            systemImage: "puzzlepiece.extension",
            schema: .boolean,
            defaultValue: .boolean(defaultValue),
            executionClass: .existingPluginProvider,
            requirements: .init(existingProviderID: providerID),
            searchTerms: searchTerms,
            destination: destination,
            note: "Reads live canonical action presentation state and delegates deterministic writes to the existing MacTools provider.",
            adapter: ExistingPluginActionSettingAdapter(
                reader: reader,
                reference: { value in
                    guard case let .boolean(enabled) = value else {
                        throw SystemSettingAdapterError.invalidValue
                    }
                    return ActionReference(
                        key: ActionKey(providerID: providerID, actionID: writeActionID),
                        parameters: try ActionParameterSet(["enabled": .boolean(enabled)])
                    )
                },
                context: actionContext
            )
        )
    }
}
