import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let store: FanControlStore
    private let openMainWindow: () -> Void
    private let statusItem: NSStatusItem
    private let labelView = StatusItemLabelView()
    private let popover = NSPopover()
    private var observers: [NSObjectProtocol] = []
    private var currentLanguageRaw = ""

    init(store: FanControlStore, openMainWindow: @escaping () -> Void) {
        self.store = store
        self.openMainWindow = openMainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        observeChanges()
        refreshLabel()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        labelView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(labelView)
        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
            labelView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
            labelView.topAnchor.constraint(equalTo: button.topAnchor),
            labelView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
    }

    private func configurePopover() {
        currentLanguageRaw = UserDefaults.standard.string(forKey: PreferenceKey.appLanguage)
            ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: currentLanguageRaw) ?? .system
        popover.behavior = .transient
        popover.animates = true
        let hostingController = NSHostingController(rootView: MenuBarPanelView(
            store: store,
            showMainWindow: { [weak self] in self?.showMainWindow() },
            showSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            onPreferredSizeChange: { [weak self] size in
                self?.updatePopoverContentSize(size)
            },
            openAIWorkflow: { [weak self] in
                self?.showAIWorkflow()
            }
        ).environment(\.locale, language.locale))
        hostingController.view.wantsLayer = true
        popover.contentViewController = hostingController
        updatePopoverContentSize(for: store.selectedMode)
    }

    private func observeChanges() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .fanControlDidRefresh,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshLabel()
                let languageRaw = UserDefaults.standard.string(forKey: PreferenceKey.appLanguage)
                    ?? AppLanguage.system.rawValue
                if languageRaw != self.currentLanguageRaw {
                    self.configurePopover()
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLabel() }
        })
    }

    private func refreshLabel() {
        let defaults = UserDefaults.standard
        let presentation = MenuBarStatusPresentation(
            cpuTemperature: store.hottestCPUTemperature,
            gpuTemperature: store.hottestGPUTemperature,
            rpm: store.fastestFanRPM,
            showCPU: defaults.bool(forKey: PreferenceKey.menuBarShowCPU),
            showGPU: defaults.bool(forKey: PreferenceKey.menuBarShowGPU),
            showFanSpeed: defaults.bool(forKey: PreferenceKey.menuBarShowFanSpeed),
            iconStyle: MenuBarIconStyle(
                rawValue: defaults.string(forKey: "menuBarIconStyle") ?? ""
            ) ?? .thermometer,
            customSymbol: defaults.string(forKey: "menuBarCustomSymbol") ?? "thermometer.medium"
        )
        labelView.configure(presentation)
        statusItem.length = labelView.preferredWidth + 4
        statusItem.button?.toolTip = labelView.accessibilitySummary
    }

    private func updatePopoverContentSize(_ size: CGSize) {
        let contentSize = NSSize(width: size.width, height: size.height)
        guard popover.contentSize != contentSize else { return }
        popover.contentSize = contentSize
    }

    private func updatePopoverContentSize(for mode: FanControlMode) {
        let height: CGFloat = mode == .autoBoost || mode == .aiScheduling ? 500 : 350
        updatePopoverContentSize(NSSize(width: 380, height: height))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMainWindow() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window = existingMainWindow() {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        openMainWindow()
        Task { @MainActor [weak self] in
            self?.existingMainWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    private func existingMainWindow() -> NSWindow? {
        let popoverWindow = popover.contentViewController?.view.window
        return NSApp.windows.first { window in
            // A SwiftUI `Window` remains registered with NSApp after the user
            // closes it, but is no longer visible. Reuse that window directly;
            // calling openWindow for an already-existing hidden scene is a no-op.
            guard window !== popoverWindow else { return false }
            if let identifier = window.identifier?.rawValue {
                return identifier == "main" || identifier.hasPrefix("main-")
            }
            return window.canBecomeMain
        }
    }

    private func showSettings() {
        store.requestSettings()
        showMainWindow()
    }

    private func showAIWorkflow() {
        store.requestAIWorkflow()
        showMainWindow()
    }
}

@MainActor
final class StatusItemLabelView: NSView {
    private let imageView = NSImageView()
    private let firstLine = NSTextField(labelWithString: "--°C / --°C")
    private let secondLine = NSTextField(labelWithString: "---- RPM")
    private(set) var preferredWidth: CGFloat = 88
    private(set) var accessibilitySummary = "Fankit"
    private var displayLayout = MenuBarStatusLayout.twoLine

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyDown
        firstLine.font = .monospacedDigitSystemFont(
            ofSize: MenuBarStatusMetrics.fontSize,
            weight: .medium
        )
        secondLine.font = .monospacedDigitSystemFont(
            ofSize: MenuBarStatusMetrics.fontSize,
            weight: .medium
        )
        firstLine.textColor = .labelColor
        secondLine.textColor = .labelColor
        addSubview(imageView)
        addSubview(firstLine)
        addSubview(secondLine)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: MenuBarStatusMetrics.contentHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let hasIcon = !imageView.isHidden
        let textX = hasIcon && displayLayout != .iconOnly
            ? MenuBarStatusMetrics.iconSize + MenuBarStatusMetrics.iconTextSpacing
            : 0
        let iconX = displayLayout == .iconOnly
            ? floor((bounds.width - MenuBarStatusMetrics.iconSize) / 2)
            : 0
        imageView.frame = NSRect(
            x: iconX,
            y: floor((bounds.height - MenuBarStatusMetrics.iconSize) / 2),
            width: hasIcon ? MenuBarStatusMetrics.iconSize : 0,
            height: MenuBarStatusMetrics.iconSize
        )

        switch displayLayout {
        case .twoLine:
            firstLine.frame = NSRect(
                x: textX,
                y: 11,
                width: bounds.width - textX,
                height: MenuBarStatusMetrics.lineHeight
            )
            secondLine.frame = NSRect(
                x: textX,
                y: 1,
                width: bounds.width - textX,
                height: MenuBarStatusMetrics.lineHeight
            )
        case .singleLine:
            firstLine.frame = NSRect(
                x: textX,
                y: floor((bounds.height - 14) / 2),
                width: bounds.width - textX,
                height: 14
            )
            secondLine.frame = .zero
        case .iconOnly:
            firstLine.frame = .zero
            secondLine.frame = .zero
        }
    }

    func configure(_ presentation: MenuBarStatusPresentation) {
        displayLayout = presentation.layout
        accessibilitySummary = presentation.accessibilitySummary

        if let symbol = presentation.symbolName {
            imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imageView.contentTintColor = .labelColor
            imageView.isHidden = false
        } else {
            imageView.image = nil
            imageView.isHidden = true
        }

        if let first = presentation.firstLine {
            firstLine.stringValue = first
            firstLine.isHidden = false
        } else {
            firstLine.isHidden = true
        }
        if let second = presentation.secondLine {
            secondLine.stringValue = second
            secondLine.isHidden = false
        } else {
            secondLine.isHidden = true
        }

        let iconWidth = imageView.isHidden
            ? 0
            : MenuBarStatusMetrics.iconSize + (presentation.hasText ? MenuBarStatusMetrics.iconTextSpacing : 0)
        let textWidth = max(
            firstLine.isHidden ? 0 : measure(firstLine.stringValue),
            secondLine.isHidden ? 0 : measure(secondLine.stringValue)
        )
        preferredWidth = max(
            iconWidth + textWidth,
            imageView.isHidden ? 20 : MenuBarStatusMetrics.iconSize + 2
        )
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func measure(_ string: String) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: firstLine.font as Any]).width) + 2
    }
}
