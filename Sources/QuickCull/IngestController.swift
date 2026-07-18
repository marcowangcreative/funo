import AppKit

/// Card ingest - the B·3 sheet: a friendly five-element face (card summary,
/// job, destination breadcrumb, one brass button, trust line) over a
/// remembered pro ritual (templates, per-shooter card folders, serial
/// recognition, split cards, top-ups). Beginners see decisions; pros see
/// their decisions remembered. Advanced lives in ONE drawer.
final class IngestController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    private static var current: IngestController?

    static func show(onOpenFolder: @escaping (URL) -> Void) {
        let controller = current ?? IngestController()
        current = controller
        controller.onOpenFolder = onOpenFolder
        controller.prefillActiveJob()
        controller.refreshCards()
        controller.showWindow(nil)
        // Optically centered EVERY open (Apple's center() sits slightly
        // above true middle), not just on first creation - the sheet
        // shouldn't reappear wherever it was last dragged.
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        // Ride ABOVE the main window until dismissed - clicking the grid
        // must not bury the sheet. Child windows also travel with the
        // parent and die with it.
        if let ingestWindow = controller.window, ingestWindow.parent == nil,
           let mainWindow = NSApp.windows.first(where: { $0.delegate is AppDelegate }) {
            mainWindow.addChildWindow(ingestWindow, ordered: .above)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Main window is going away - take the ingest sheet with it.
    static func closeIfOpen() {
        current?.window?.close()
    }

    private var onOpenFolder: ((URL) -> Void)?

    private struct CardRow {
        let master: NSButton?
        var sections: [(button: NSButton, folder: URL)]
    }
    private var cardRows: [CardRow] = []
    private var job: IngestJob?

    // MARK: - State

    private var detectedSerial: String?
    private var detectedModel: String?
    private var detectedCardUUID: String?
    /// Section folder → body serial. Cameras write their own DCIM
    /// subfolders, so per-SECTION sampling sees every body on a mixed card.
    private var sectionSerials: [URL: String] = [:]
    private var detectedCardVolumes: [URL] = []
    /// Stat'd ONCE per card detection, in the background - refreshCrumbs
    /// runs per keystroke and must never touch the disk.
    private var cardMemoryFolderExists = false
    private var selectedShooterPrefix: String?
    private var cardPhotoCount = 0
    private var cardBytes: Int64 = 0
    /// Per-SECTION totals, so "needs X" and the counts follow the
    /// checkboxes instead of always billing the whole card.
    private var sectionBytes: [URL: Int64] = [:]
    private var lastErrors: [String] = []

    // Mixed-card chains: totals accumulate across per-shooter runs.
    private var chainCopied = 0
    private var chainSkipped = 0
    private var chainErrors: [String] = []

    private var backupDestination: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "QuickCullBackupDest") else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "QuickCullBackupDest") }
    }
    private var backupEnabled: Bool { backupDestination != nil }

    /// Has the user ever actually chosen a destination? Until then the
    /// sheet shows an empty slot, not a guess.
    private var destinationIsSet: Bool {
        UserDefaults.standard.string(forKey: "QuickCullIngestDest") != nil
    }

    private var destination: URL {
        get {
            if let saved = UserDefaults.standard.string(forKey: "QuickCullIngestDest") {
                return URL(fileURLWithPath: saved)
            }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "QuickCullIngestDest")
            refreshCrumbs()
        }
    }

    // MARK: - Views

    private let cardEyebrow = NSTextField(labelWithString: "")
    private let specLine = NSTextField(labelWithString: "")
    private let jobField = NSTextField()
    private let shooterStack = NSStackView()
    private let shooterInfo = NSTextField(labelWithString: "")
    private let crumbLabel = NSTextField(labelWithString: "")
    private let newTag = NSTextField(labelWithString: "NEW")
    private let spaceValue = NSTextField(labelWithString: "")
    private let trustLabel = NSTextField(labelWithString: "Your card is never changed - photos are copied.")
    private let multiCardWarning = NSTextField(labelWithString: "")
    private var thumbCells: [ThumbCell] = []
    private let moreLabel = NSTextField(labelWithString: "")
    private let railEmptyLabel = NSTextField(labelWithString: "Insert a card")

    private let drawer = NSStackView()
    private let templatePopup = NSPopUpButton()
    private let copyIntoPopup = NSPopUpButton()
    private let foldersSummary = NSTextField(labelWithString: "")
    private let ejectWhenDoneCheck = BrassSwitch()
    private let notifySwitch = BrassSwitch()
    private let newOnlySwitch = BrassSwitch()
    private let structurePopup = NSPopUpButton()
    private let patternField = NSTextField()
    private let patternHint = NSTextField(labelWithString: "")
    private let backupCrumbLabel = NSTextField(labelWithString: "")
    private var backupChangeButton: NSButton!
    private var backupClearButton: NSButton!
    private var backupRow: NSStackView!
    private var backupRule: NSView!
    private var crumbRowStack: NSStackView!
    private let backupSpaceValue = NSTextField(labelWithString: "")
    private var backupSpaceRow: NSStackView!
    private var detectedCardName = ""
    private var currentIngestNumber = 1

    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorsButton = NSButton()
    private let optionsButton = NSButton()
    private let ejectButton = NSButton()
    private let notNowButton = NSButton()
    private let cancelButton = NSButton()
    private var startButton: BrassButton!

    // MARK: - Window

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ingest"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.bg1
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    func windowWillClose(_ notification: Notification) {
        job?.cancel()
        if let window, let parent = window.parent {
            parent.removeChildWindow(window)
        }
    }

    // MARK: - UI construction

    private func eyebrow(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: Theme.monoEyebrow, .foregroundColor: Theme.tx2, .kern: 1.4
        ])
        return label
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg1.cgColor

        // ---------- left rail: the card's first frames ----------
        let rail = NSView()
        rail.wantsLayer = true
        rail.layer?.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1).cgColor
        rail.translatesAutoresizingMaskIntoConstraints = false

        let railEyebrow = eyebrow("On this card")
        let thumbGrid = NSStackView()
        thumbGrid.orientation = .vertical
        thumbGrid.spacing = 7
        for _ in 0..<3 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 7
            for _ in 0..<2 {
                let cell = ThumbCell()
                thumbCells.append(cell)
                row.addArrangedSubview(cell)
                NSLayoutConstraint.activate([
                    cell.widthAnchor.constraint(equalToConstant: 104),
                    cell.heightAnchor.constraint(equalToConstant: 74)
                ])
            }
            thumbGrid.addArrangedSubview(row)
        }
        moreLabel.font = Theme.monoCaption
        moreLabel.textColor = Theme.tx2
        moreLabel.alignment = .center
        railEmptyLabel.font = Theme.monoCaption
        railEmptyLabel.textColor = Theme.tx2
        railEmptyLabel.alignment = .center

        let railStack = NSStackView(views: [railEyebrow, thumbGrid, moreLabel, railEmptyLabel])
        railStack.orientation = .vertical
        railStack.alignment = .leading
        railStack.spacing = 10
        railStack.setCustomSpacing(14, after: railEyebrow)
        railStack.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(railStack)
        NSLayoutConstraint.activate([
            // Same top as the right column's eyebrow - the two eyebrows sit
            // on ONE line across the sheet, like the mock.
            railStack.topAnchor.constraint(equalTo: rail.topAnchor, constant: 28),
            railStack.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 18),
            rail.widthAnchor.constraint(equalToConstant: 252),
            // Centered captions stay centered UNDER THE GRID, not under
            // whatever width the label happens to be.
            moreLabel.widthAnchor.constraint(equalTo: thumbGrid.widthAnchor),
            railEmptyLabel.widthAnchor.constraint(equalTo: thumbGrid.widthAnchor)
        ])

        // ---------- right column ----------
        cardEyebrow.attributedStringValue = NSAttributedString(string: "NO CARD", attributes: [
            .font: Theme.monoEyebrow, .foregroundColor: Theme.tx2, .kern: 1.4
        ])
        specLine.font = Theme.monoData
        specLine.lineBreakMode = .byTruncatingTail
        specLine.usesSingleLineMode = true
        specLine.maximumNumberOfLines = 1

        let jobWell = well(containing: jobField, height: 36)
        jobField.font = Theme.monoData
        jobField.textColor = Theme.tx0
        jobField.placeholderString = "Job name - becomes the folder"
        jobField.isBordered = false
        jobField.drawsBackground = false
        jobField.focusRingType = .none
        jobField.delegate = self

        shooterStack.orientation = .horizontal
        shooterStack.spacing = 6
        shooterInfo.font = Theme.caption
        shooterInfo.textColor = .tertiaryLabelColor
        shooterInfo.lineBreakMode = .byTruncatingTail

        // destination well: breadcrumb row + SPACE row
        let destWell = NSView()
        destWell.wantsLayer = true
        destWell.layer?.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1).cgColor
        destWell.layer?.cornerRadius = 8
        destWell.layer?.borderWidth = 1
        destWell.layer?.borderColor = Theme.line.cgColor
        destWell.translatesAutoresizingMaskIntoConstraints = false

        let disk = NSImageView(image: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSImage())
        disk.contentTintColor = Theme.tx2
        crumbLabel.font = Theme.monoData
        crumbLabel.lineBreakMode = .byTruncatingMiddle
        crumbLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newTag.font = Theme.monoEyebrow
        newTag.textColor = Theme.accent
        newTag.wantsLayer = true
        newTag.layer?.borderColor = Theme.accent.withAlphaComponent(0.85).cgColor
        newTag.layer?.borderWidth = 1
        newTag.layer?.cornerRadius = 3
        let change = NSButton(title: "Change", target: self, action: #selector(chooseDestination(_:)))
        change.bezelStyle = .rounded
        change.controlSize = .small
        crumbRowStack = NSStackView(views: [disk, crumbLabel, newTag, NSView(), change])
        crumbRowStack.orientation = .horizontal
        crumbRowStack.spacing = 7
        let crumbRow: NSStackView = crumbRowStack

        let destRule = NSView()
        destRule.wantsLayer = true
        destRule.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        destRule.translatesAutoresizingMaskIntoConstraints = false
        destRule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        spaceValue.font = Theme.monoCaption
        spaceValue.textColor = Theme.tx1
        let spaceRow = NSStackView(views: [eyebrow("Space"), NSView(), spaceValue])
        spaceRow.orientation = .horizontal
        backupSpaceValue.font = Theme.monoCaption
        backupSpaceValue.textColor = Theme.tx1
        backupSpaceRow = NSStackView(views: [eyebrow("Backup"), NSView(), backupSpaceValue])
        backupSpaceRow.orientation = .horizontal

        // Second destination (BACKUP) - a twin crumb row, hidden until
        // the drawer's switch turns it on.
        let backupDisk = NSImageView(image: NSImage(systemSymbolName: "externaldrive.badge.checkmark",
                                                    accessibilityDescription: nil) ?? NSImage())
        backupDisk.contentTintColor = Theme.tx2
        backupCrumbLabel.font = Theme.monoData
        backupCrumbLabel.lineBreakMode = .byTruncatingMiddle
        backupCrumbLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        backupChangeButton = NSButton(title: "Change", target: self, action: #selector(chooseBackupDestination(_:)))
        backupChangeButton.bezelStyle = .rounded
        backupChangeButton.controlSize = .small
        backupClearButton = NSButton(title: "✕", target: self, action: #selector(clearBackup(_:)))
        backupClearButton.isBordered = false
        backupClearButton.font = Theme.caption
        backupClearButton.contentTintColor = .tertiaryLabelColor
        backupClearButton.toolTip = "Remove the second copy"
        let backupTag = NSTextField(labelWithString: "")
        backupTag.attributedStringValue = NSAttributedString(string: " BACKUP ", attributes: [
            .font: Theme.monoEyebrow, .foregroundColor: Theme.tx2, .kern: 1.0
        ])
        backupTag.wantsLayer = true
        backupTag.layer?.borderColor = Theme.line.cgColor
        backupTag.layer?.borderWidth = 1
        backupTag.layer?.cornerRadius = 3
        backupRow = NSStackView(views: [backupDisk, backupCrumbLabel, backupTag, NSView(), backupClearButton, backupChangeButton])
        backupRow.orientation = .horizontal
        backupRow.spacing = 7
        backupRule = NSView()
        backupRule.wantsLayer = true
        backupRule.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        backupRule.translatesAutoresizingMaskIntoConstraints = false
        backupRule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let destStack = NSStackView(views: [crumbRow, backupRule, backupRow, destRule, spaceRow, backupSpaceRow])
        destStack.orientation = .vertical
        destStack.spacing = 8
        destStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        destStack.translatesAutoresizingMaskIntoConstraints = false
        destWell.addSubview(destStack)
        NSLayoutConstraint.activate([
            destStack.topAnchor.constraint(equalTo: destWell.topAnchor),
            destStack.bottomAnchor.constraint(equalTo: destWell.bottomAnchor),
            destStack.leadingAnchor.constraint(equalTo: destWell.leadingAnchor),
            destStack.trailingAnchor.constraint(equalTo: destWell.trailingAnchor),
            crumbRow.widthAnchor.constraint(equalTo: destStack.widthAnchor, constant: -24),
            backupRow.widthAnchor.constraint(equalTo: destStack.widthAnchor, constant: -24),
            backupRule.widthAnchor.constraint(equalTo: destStack.widthAnchor, constant: -24),
            backupSpaceRow.widthAnchor.constraint(equalTo: destStack.widthAnchor, constant: -24),
            destRule.widthAnchor.constraint(equalTo: destStack.widthAnchor, constant: -24),
            spaceRow.widthAnchor.constraint(equalTo: destStack.widthAnchor, constant: -24)
        ])

        trustLabel.font = Theme.caption
        trustLabel.textColor = Theme.tx2
        trustLabel.alignment = .center

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true

        statusLabel.font = Theme.monoCaption
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // Long messages TRUNCATE - they never get to demand window width.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shooterInfo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        specLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        errorsButton.title = "Show Failures…"
        errorsButton.bezelStyle = .rounded
        errorsButton.controlSize = .small
        errorsButton.contentTintColor = .systemRed
        errorsButton.target = self
        errorsButton.action = #selector(showErrors(_:))
        errorsButton.isHidden = true
        let statusRow = NSStackView(views: [statusLabel, NSView(), errorsButton])
        statusRow.orientation = .horizontal

        // Chips need a title - floating names read as decoration.
        let shooterEyebrow = eyebrow("Photographer")
        multiCardWarning.attributedStringValue = NSAttributedString(
            string: "\u{26A0} Two cards use the SELECTED photographer for anything unrecognized. For two different shooters, ingest one card at a time.",
            attributes: [.font: Theme.caption, .foregroundColor: Theme.accent])
        multiCardWarning.lineBreakMode = .byWordWrapping
        multiCardWarning.maximumNumberOfLines = 2
        multiCardWarning.isHidden = true
        multiCardWarning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rightStack = NSStackView(views: [cardEyebrow, specLine, jobWell, shooterEyebrow, shooterStack, shooterInfo,
                                             multiCardWarning, destWell, trustLabel, progressBar, statusRow])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 11
        rightStack.setCustomSpacing(7, after: cardEyebrow)
        rightStack.setCustomSpacing(14, after: specLine)
        rightStack.setCustomSpacing(6, after: shooterEyebrow)
        rightStack.setCustomSpacing(4, after: shooterStack)
        rightStack.setCustomSpacing(10, after: multiCardWarning)
        rightStack.setCustomSpacing(8, after: destWell)
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(rail)
        main.addSubview(rightStack)
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: main.topAnchor),
            rail.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            rightStack.topAnchor.constraint(equalTo: main.topAnchor, constant: 28),
            rightStack.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 22),
            rightStack.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -22),
            rightStack.bottomAnchor.constraint(lessThanOrEqualTo: main.bottomAnchor, constant: -12),
            jobWell.widthAnchor.constraint(equalTo: rightStack.widthAnchor),
            destWell.widthAnchor.constraint(equalTo: rightStack.widthAnchor),
            trustLabel.widthAnchor.constraint(equalTo: rightStack.widthAnchor),
            multiCardWarning.widthAnchor.constraint(equalTo: rightStack.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: rightStack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: rightStack.widthAnchor)
        ])

        // ---------- options drawer ----------
        // The mock, faithfully: brass eyebrow + rule + "remembered", then
        // [engraved key | body] rows split by hairlines - token well with a
        // live example, styled popups, brass switches. Every control here
        // is REAL; BACKUP waits for 0.10 rather than shipping as a prop.
        drawer.orientation = .vertical
        drawer.alignment = .leading
        drawer.spacing = 0
        drawer.edgeInsets = NSEdgeInsets(top: 14, left: 22, bottom: 16, right: 22)
        drawer.wantsLayer = true
        drawer.layer?.backgroundColor = NSColor(srgbRed: 25/255, green: 27/255, blue: 30/255, alpha: 1).cgColor
        drawer.isHidden = true

        let defaults = UserDefaults.standard

        // COPY AS - rename pattern with a live example.
        patternField.font = Theme.monoData
        patternField.textColor = Theme.tx0
        patternField.placeholderString = "keep original names"
        patternField.isBordered = false
        patternField.drawsBackground = false
        patternField.focusRingType = .none
        patternField.delegate = self
        patternField.stringValue = defaults.string(forKey: "QuickCullCopyAsPattern") ?? ""
        let patternWell = well(containing: patternField, height: 28)
        patternWell.widthAnchor.constraint(equalToConstant: 190).isActive = true
        patternHint.font = Theme.monoCaption
        patternHint.textColor = .tertiaryLabelColor
        patternHint.lineBreakMode = .byTruncatingTail
        patternHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // LR's trick, not PM's: nobody memorizes token syntax. A menu of
        // human names inserts them, and each item SHOWS what it becomes.
        let insertMenu = NSPopUpButton()
        insertMenu.pullsDown = true
        insertMenu.controlSize = .small
        insertMenu.font = Theme.caption
        insertMenu.addItem(withTitle: "Insert")
        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyyMMdd"
        let tokenChoices: [(String, String)] = [
            ("Sequence number  →  0001", "{seq}"),
            ("Import number  →  \(String(format: "%02d", max(1, defaults.integer(forKey: "QuickCullIngestSeq"))))", "{iseq}"),
            ("Capture date  →  \(todayFormatter.string(from: Date()))", "{date}"),
            ("Original name  →  IMG_4021", "{name}")
        ]
        for (title, token) in tokenChoices {
            let item = NSMenuItem(title: title, action: #selector(insertToken(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = token
            insertMenu.menu?.addItem(item)
        }
        let copyAsBody = NSStackView(views: [patternWell, insertMenu, patternHint])
        copyAsBody.orientation = .horizontal
        copyAsBody.alignment = .centerY
        copyAsBody.spacing = 10

        // STRUCTURE
        structurePopup.removeAllItems()
        structurePopup.addItems(withTitles: ["Flatten", "Keep card folders"])
        structurePopup.selectItem(at: defaults.bool(forKey: "QuickCullPreserveFolders") ? 1 : 0)
        structurePopup.target = self
        structurePopup.action = #selector(structureChanged(_:))

        templatePopup.target = self
        templatePopup.action = #selector(templateChanged(_:))
        rebuildTemplatePopup()
        lastTemplateChoice = templatePopup.titleOfSelectedItem ?? "None"
        rebuildCopyInto()
        copyIntoPopup.target = self
        copyIntoPopup.action = #selector(copyIntoChanged(_:))

        // A count is DATA - same voice as the spec line's COPY segment.
        foldersSummary.font = Theme.monoData
        foldersSummary.textColor = Theme.tx1
        let chooseFoldersButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolders(_:)))
        chooseFoldersButton.bezelStyle = .rounded
        chooseFoldersButton.controlSize = .small
        let refresh = NSButton(title: "Refresh Cards", target: self, action: #selector(refreshTapped(_:)))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        let sectionsBody = NSStackView(views: [foldersSummary, chooseFoldersButton, refresh])
        sectionsBody.orientation = .horizontal
        sectionsBody.alignment = .centerY
        sectionsBody.spacing = 10

        func rowLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = Theme.secondary
            label.textColor = Theme.tx1
            return label
        }
        func subLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = Theme.caption
            label.textColor = .tertiaryLabelColor
            return label
        }

        // NEW ONLY
        newOnlySwitch.state = (defaults.object(forKey: "QuickCullSkipExisting") == nil
                               || defaults.bool(forKey: "QuickCullSkipExisting")) ? .on : .off
        newOnlySwitch.target = self
        newOnlySwitch.action = #selector(newOnlyToggled(_:))
        let newOnlyBody = NSStackView(views: [newOnlySwitch, rowLabel("Skip photos already copied"),
                                              subLabel("re-inserted cards copy only the new frames")])
        newOnlyBody.orientation = .horizontal
        newOnlyBody.alignment = .centerY
        newOnlyBody.spacing = 8

        // WHEN DONE
        ejectWhenDoneCheck.state = defaults.bool(forKey: "QuickCullEjectWhenDone") ? .on : .off
        ejectWhenDoneCheck.target = self
        ejectWhenDoneCheck.action = #selector(ejectWhenDoneToggled(_:))
        notifySwitch.state = defaults.bool(forKey: "QuickCullNotifyWhenDone") ? .on : .off
        notifySwitch.target = self
        notifySwitch.action = #selector(notifyToggled(_:))
        let whenDoneBody = NSStackView(views: [ejectWhenDoneCheck, rowLabel("Eject card"),
                                               subLabel("·"), notifySwitch, rowLabel("Notify")])
        whenDoneBody.orientation = .horizontal
        whenDoneBody.alignment = .centerY
        whenDoneBody.spacing = 8

        func pill(_ popup: NSPopUpButton) -> NSView {
            popup.isBordered = false
            popup.font = Theme.secondary
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.02).cgColor
            container.layer?.cornerRadius = 6
            container.layer?.borderWidth = 1
            container.layer?.borderColor = Theme.line.cgColor
            container.translatesAutoresizingMaskIntoConstraints = false
            popup.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(popup)
            NSLayoutConstraint.activate([
                popup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                popup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
                popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                container.heightAnchor.constraint(equalToConstant: 28)
            ])
            return container
        }
        func drawerHairline() -> NSView {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor(srgbRed: 32/255, green: 34/255, blue: 38/255, alpha: 1).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return line
        }
        func drawerRow(_ key: String, _ body: NSView, baseline: Bool = true) -> NSStackView {
            let k = eyebrow(key)
            k.translatesAutoresizingMaskIntoConstraints = false
            k.widthAnchor.constraint(equalToConstant: 86).isActive = true
            let row = NSStackView(views: [k, body])
            row.orientation = .horizontal
            row.alignment = baseline ? .firstBaseline : .centerY
            row.spacing = 16
            row.edgeInsets = NSEdgeInsets(top: 17, left: 2, bottom: 17, right: 2)
            return row
        }

        // STRUCTURE, TEMPLATE and COPY INTO are one thought - one line.
        let structureBody = NSStackView(views: [pill(structurePopup),
                                                eyebrow("Template"), pill(templatePopup),
                                                eyebrow("Copy into"), pill(copyIntoPopup)])
        structureBody.orientation = .horizontal
        structureBody.alignment = .centerY
        structureBody.spacing = 10
        structureBody.setCustomSpacing(16, after: structureBody.arrangedSubviews[0])
        structureBody.setCustomSpacing(16, after: structureBody.arrangedSubviews[2])

        let optionsEyebrow = NSTextField(labelWithString: "")
        optionsEyebrow.attributedStringValue = NSAttributedString(string: "INGEST OPTIONS", attributes: [
            .font: Theme.monoEyebrow, .foregroundColor: Theme.accent, .kern: 1.4
        ])
        let headRule = NSView()
        headRule.wantsLayer = true
        headRule.layer?.backgroundColor = NSColor(srgbRed: 38/255, green: 40/255, blue: 44/255, alpha: 1).cgColor
        headRule.translatesAutoresizingMaskIntoConstraints = false
        headRule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        headRule.setContentHuggingPriority(.init(1), for: .horizontal)
        let drawerHeader = NSStackView(views: [optionsEyebrow, headRule])
        drawerHeader.orientation = .horizontal
        drawerHeader.alignment = .centerY
        drawerHeader.spacing = 10

        drawer.addArrangedSubview(drawerHeader)
        drawer.setCustomSpacing(10, after: drawerHeader)
        let drawerRows: [NSView] = [
            drawerRow("Rename", copyAsBody, baseline: false),
            drawerRow("Structure", structureBody, baseline: false),
            drawerRow("Card folders", sectionsBody),
            drawerRow("New only", newOnlyBody, baseline: false),
            drawerRow("When done", whenDoneBody, baseline: false)
        ]
        for (index, row) in drawerRows.enumerated() {
            drawer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: drawer.widthAnchor, constant: -44).isActive = true
            if index < drawerRows.count - 1 {
                let line = drawerHairline()
                drawer.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: drawer.widthAnchor, constant: -44).isActive = true
            }
        }
        drawerHeader.widthAnchor.constraint(equalTo: drawer.widthAnchor, constant: -44).isActive = true
        refreshPatternHint()

        // ---------- footer band ----------
        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.015).cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerRule = NSView()
        footerRule.wantsLayer = true
        footerRule.layer?.backgroundColor = Theme.line.cgColor
        footerRule.translatesAutoresizingMaskIntoConstraints = false

        optionsButton.title = "Options…"
        optionsButton.bezelStyle = .rounded
        optionsButton.target = self
        optionsButton.action = #selector(toggleDrawer(_:))

        ejectButton.title = "⏏ Eject"
        ejectButton.bezelStyle = .rounded
        ejectButton.target = self
        ejectButton.action = #selector(ejectTapped(_:))
        ejectButton.isHidden = true

        notNowButton.title = "Not Now"
        notNowButton.bezelStyle = .rounded
        notNowButton.target = self
        notNowButton.action = #selector(notNowTapped(_:))

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.isHidden = true

        startButton = BrassButton(title: "Copy & Start Culling", target: self, action: #selector(startTapped(_:)))
        startButton.keyEquivalent = "\r"

        let footerStack = NSStackView(views: [optionsButton, ejectButton, NSView(), cancelButton, notNowButton, startButton])
        footerStack.orientation = .horizontal
        footerStack.spacing = 10
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerRule)
        footer.addSubview(footerStack)
        NSLayoutConstraint.activate([
            footerRule.topAnchor.constraint(equalTo: footer.topAnchor),
            footerRule.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerStack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 11),
            footerStack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -11),
            footerStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 18),
            footerStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -18)
        ])

        // ---------- assemble ----------
        let root = NSStackView(views: [main, drawer, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            main.widthAnchor.constraint(equalTo: root.widthAnchor),
            drawer.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            main.heightAnchor.constraint(greaterThanOrEqualToConstant: 330),
            // The sheet's width is a DECISION, not a negotiation - no label
            // gets to blow the window open.
            content.widthAnchor.constraint(equalToConstant: 760)
        ])

        rebuildShooterChips()
        refreshShooterInfo()
        refreshBackupUI()
    }

    private func well(containing field: NSTextField, height: CGFloat) -> NSView {
        let wellView = NSView()
        wellView.wantsLayer = true
        wellView.layer?.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1).cgColor
        wellView.layer?.cornerRadius = 8
        wellView.layer?.borderWidth = 1
        wellView.layer?.borderColor = Theme.line.cgColor
        wellView.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        wellView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: wellView.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: wellView.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: wellView.centerYAnchor),
            wellView.heightAnchor.constraint(equalToConstant: height)
        ])
        return wellView
    }

    // MARK: - Live composition

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === patternField {
            UserDefaults.standard.set(patternField.stringValue, forKey: "QuickCullCopyAsPattern")
            refreshPatternHint()
            return
        }
        refreshCrumbs()
    }

    @objc private func templateChanged(_ sender: Any?) {
        if let choice = templatePopup.titleOfSelectedItem, choice != "Edit Templates…" {
            lastTemplateChoice = choice
        }
        rebuildCopyInto()
        refreshCrumbs()
    }

    private var lastTemplateChoice = "None"

    /// The popup owns its whole lifecycle now - no backing out to the
    /// sidebar menu just to edit a template.
    private func rebuildTemplatePopup(selecting: String? = nil) {
        let wanted = selecting ?? templatePopup.titleOfSelectedItem
        templatePopup.removeAllItems()
        templatePopup.addItem(withTitle: "None")
        templatePopup.addItems(withTitles: FolderTemplates.names)
        templatePopup.menu?.addItem(.separator())
        let editItem = NSMenuItem(title: "Edit Templates…",
                                  action: #selector(editTemplatesTapped(_:)), keyEquivalent: "")
        editItem.target = self
        templatePopup.menu?.addItem(editItem)
        if let wanted, templatePopup.itemTitles.contains(wanted), wanted != "Edit Templates…" {
            templatePopup.selectItem(withTitle: wanted)
        } else if templatePopup.itemTitles.contains("Wedding") {
            templatePopup.selectItem(withTitle: "Wedding")
        } else {
            templatePopup.selectItem(at: 0)
        }
    }

    @objc private func editTemplatesTapped(_ sender: Any?) {
        // Clicking the item made it the popup's selection - put the real
        // choice back before the editor opens.
        rebuildTemplatePopup(selecting: lastTemplateChoice)
        TemplateEditor.show()
    }

    /// Back from the template editor (or anywhere): the popup reflects
    /// whatever templates exist NOW, selection preserved.
    func windowDidBecomeKey(_ notification: Notification) {
        rebuildTemplatePopup(selecting: lastTemplateChoice)
        rebuildCopyInto()
    }
    @objc private func copyIntoChanged(_ sender: Any?) { refreshCrumbs() }
    @objc private func ejectWhenDoneToggled(_ sender: BrassSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "QuickCullEjectWhenDone")
    }

    private func rebuildCopyInto() {
        let previous = copyIntoPopup.titleOfSelectedItem
        copyIntoPopup.removeAllItems()
        copyIntoPopup.addItem(withTitle: "Job folder")
        if let template = templatePopup.titleOfSelectedItem, template != "None",
           let paths = FolderTemplates.all[template] {
            let topLevel = paths.filter { !$0.contains("/") }
            copyIntoPopup.addItems(withTitles: topLevel)
        }
        if let previous, copyIntoPopup.itemTitles.contains(previous) {
            copyIntoPopup.selectItem(withTitle: previous)
        } else if copyIntoPopup.itemTitles.contains("ingest") {
            copyIntoPopup.selectItem(withTitle: "ingest")
        }
    }

    /// The breadcrumb IS the answer: root › Job (brass, typed live) ›
    /// ingest › ansel-01 - dim = where things live, brass = what you're
    /// making right now.
    private func refreshCrumbs() {
        let dim: [NSAttributedString.Key: Any] = [.font: Theme.monoData, .foregroundColor: Theme.tx2]
        let sep: [NSAttributedString.Key: Any] = [.font: Theme.monoData, .foregroundColor: NSColor(calibratedWhite: 0.29, alpha: 1)]
        let brass: [NSAttributedString.Key: Any] = [.font: Theme.monoDataStrong, .foregroundColor: Theme.accent]

        let jobName = jobField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let into: String? = {
            guard let title = copyIntoPopup.titleOfSelectedItem, title != "Job folder" else { return nil }
            return title
        }()
        var tailText: String?
        var tailIsTopUp = false
        if let prefix = selectedShooterPrefix {
            // Same card + same job = top-up into its existing folder.
            if let uuid = detectedCardUUID,
               let memory = ShooterStore.shared.cardMemory(volumeUUID: uuid),
               memory.lastJob == jobName,
               cardMemoryFolderExists {
                tailText = URL(fileURLWithPath: memory.lastFolder).lastPathComponent
                tailIsTopUp = true
            } else {
                tailText = "\(prefix)-··"
            }
        }
        newTag.isHidden = tailIsTopUp || jobName.isEmpty

        // One composition, painted on both drives' rows. The label
        // truncates from the head; the tooltip tells the whole truth.
        func compose(rootName: String, rootPath: String) -> (line: NSAttributedString, path: String) {
            let line = NSMutableAttributedString(string: rootName, attributes: dim)
            var path = rootPath
            line.append(NSAttributedString(string: " › ", attributes: sep))
            line.append(NSAttributedString(string: jobName.isEmpty ? "…" : jobName, attributes: brass))
            if !jobName.isEmpty { path += "/" + jobName }
            if let into {
                line.append(NSAttributedString(string: " › ", attributes: sep))
                line.append(NSAttributedString(string: into, attributes: dim))
                path += "/" + into
            }
            if let tailText {
                line.append(NSAttributedString(string: " › ", attributes: sep))
                line.append(NSAttributedString(string: tailText, attributes: brass))
                path += "/" + tailText
            }
            return (line, path)
        }

        if destinationIsSet {
            let main = compose(rootName: destination.lastPathComponent, rootPath: destination.path)
            crumbLabel.attributedStringValue = main.line
            crumbLabel.toolTip = main.path
            crumbRowStack?.toolTip = main.path
        } else {
            crumbLabel.attributedStringValue = NSAttributedString(
                string: "Choose a destination", attributes:
                [.font: Theme.monoData, .foregroundColor: NSColor.tertiaryLabelColor])
            crumbLabel.toolTip = nil
            crumbRowStack?.toolTip = "Where photos land - pick a folder on your working drive."
            newTag.isHidden = true
        }
        if let backup = backupDestination {
            let second = compose(rootName: backup.lastPathComponent, rootPath: backup.path)
            backupCrumbLabel.attributedStringValue = second.line
            backupCrumbLabel.toolTip = second.path
            backupRow?.toolTip = second.path
        } else {
            backupCrumbLabel.attributedStringValue = NSAttributedString(
                string: "No second copy", attributes:
                [.font: Theme.monoData, .foregroundColor: NSColor.tertiaryLabelColor])
            backupCrumbLabel.toolTip = nil
            backupRow?.toolTip = "Add a second drive - every ingest lands on both."
        }
        refreshSpace()
    }

    private var spaceScanGeneration = 0

    private func refreshSpace() {
        let needed = selectedBytes
        let mainTarget: URL? = destinationIsSet ? destination : nil
        let backupTarget = backupDestination
        spaceScanGeneration += 1
        let generation = spaceScanGeneration
        // statfs on a sleeping external blocks for the whole spin-up, and
        // this fires on every keystroke in the job field - the watchdog
        // caught it on main. Query in the background, paint on main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mainFree = mainTarget.map { Self.freeSpace(at: $0) }
            let backupFree = backupTarget.map { Self.freeSpace(at: $0) }
            DispatchQueue.main.async {
                guard let self, self.spaceScanGeneration == generation else { return }
                self.applySpace(needed: needed, mainFree: mainFree, backupFree: backupFree)
            }
        }
    }

    /// importantUsage is the honest number (it counts purgeable space), but
    /// volumes that don't support it report ZERO - exFAT/HFS externals,
    /// network shares. Fall down the ladder instead of announcing "Zero KB
    /// free" in cheerful green.
    private static func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        var free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        if free <= 0 { free = Int64(values?.volumeAvailableCapacity ?? 0) }
        if free <= 0,
           let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let fsFree = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
            free = fsFree
        }
        return free
    }

    private func applySpace(needed: Int64, mainFree: Int64?, backupFree: Int64?) {
        let k: [NSAttributedString.Key: Any] = [.font: Theme.monoCaption, .foregroundColor: Theme.tx2]
        var allFit = true

        // One line per drive - the primary carries "needs", the backup
        // answers only for itself.
        func verdictLine(free: Int64, withNeeds: Bool) -> NSAttributedString {
            let text = NSMutableAttributedString()
            if withNeeds, needed > 0 {
                text.append(NSAttributedString(string: "needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))", attributes: k))
            }
            // Unknown free space: say nothing rather than something wrong,
            // and never block the start button on a blind guess.
            guard free > 0 else { return text }
            let fits = needed < free
            allFit = allFit && fits
            if text.length > 0 { text.append(NSAttributedString(string: " · ", attributes: k)) }
            let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            text.append(NSAttributedString(string: fits ? "\(freeText) free ✓" : "\(freeText) free - won't fit",
                attributes: [.font: Theme.monoCaption,
                             .foregroundColor: fits ? Theme.labelColors[3] : Theme.red]))
            return text
        }

        if let mainFree {
            spaceValue.attributedStringValue = verdictLine(free: mainFree, withNeeds: true)
        } else if needed > 0 {
            spaceValue.attributedStringValue = NSAttributedString(
                string: "needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))",
                attributes: k)
        } else {
            spaceValue.stringValue = ""
        }
        if let backupFree {
            backupSpaceValue.attributedStringValue = verdictLine(free: backupFree, withNeeds: false)
        } else {
            backupSpaceValue.stringValue = ""
        }
        startButton.isEnabled = allFit
    }

    /// The job you're MID-WAY through - card 2 of a wedding must not ask
    /// the name again. Set when a run starts, gone when the app quits;
    /// never persisted, so every fresh session opens a blank slate.
    private var sessionJob: String?

    /// First open of a session: blank slate, nothing presumed. Once an
    /// ingest has run, later opens continue that job - insert, Enter.
    private func prefillActiveJob() {
        if let sessionJob {
            jobField.stringValue = sessionJob
        } else {
            jobField.stringValue = ""
            selectedShooterPrefix = nil
        }
        rebuildShooterChips()
        refreshShooterInfo()
        refreshCrumbs()
    }

    // MARK: - Shooters

    private func rebuildShooterChips() {
        shooterStack.arrangedSubviews.forEach { shooterStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for shooter in ShooterStore.shared.shooters {
            let chip = NSButton(title: shooter.name, target: self, action: #selector(shooterChipTapped(_:)))
            chip.bezelStyle = .rounded
            chip.controlSize = .small
            // Selection is BRASS, not system blue - bezelColor carries it,
            // so no push-on state (which would tint aqua).
            let selected = shooter.prefix == selectedShooterPrefix
            chip.bezelColor = selected ? Theme.accent : nil
            chip.attributedTitle = NSAttributedString(string: shooter.name, attributes: [
                .font: Theme.secondary,
                .foregroundColor: selected
                    ? NSColor(calibratedRed: 0.09, green: 0.075, blue: 0.06, alpha: 1)
                    : Theme.tx1
            ])
            chip.identifier = NSUserInterfaceItemIdentifier(shooter.prefix)
            // Right-click: manage the roster in place.
            let menu = NSMenu()
            let editItem = NSMenuItem(title: "Edit \(shooter.name)…",
                                      action: #selector(editShooterTapped(_:)), keyEquivalent: "")
            editItem.target = self
            editItem.representedObject = shooter.prefix
            menu.addItem(editItem)
            let removeItem = NSMenuItem(title: "Remove \(shooter.name)",
                                        action: #selector(removeShooterTapped(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = shooter.prefix
            menu.addItem(removeItem)
            chip.menu = menu
            chip.toolTip = "Right-click to edit or remove"
            shooterStack.addArrangedSubview(chip)
        }
        let add = NSButton(title: "Add…", target: self, action: #selector(addShooterTapped(_:)))
        add.bezelStyle = .rounded
        add.controlSize = .small
        shooterStack.addArrangedSubview(add)
    }

    @objc private func shooterChipTapped(_ sender: NSButton) {
        guard let prefix = sender.identifier?.rawValue else { return }
        if selectedShooterPrefix == prefix {
            // Tap the active chip again = NO photographer: photos land
            // straight in the ingest folder, no per-shooter subfolder.
            selectedShooterPrefix = nil
        } else {
            selectedShooterPrefix = prefix
            if let serial = detectedSerial, ShooterStore.shared.shooter(forSerial: serial) == nil {
                ShooterStore.shared.assign(serial: serial, to: prefix, model: detectedModel)
            }
        }
        rebuildShooterChips()
        refreshShooterInfo()
        if selectedShooterPrefix == nil, !ShooterStore.shared.shooters.isEmpty {
            shooterInfo.stringValue = "No photographer - photos land straight in the ingest folder."
            shooterInfo.textColor = .tertiaryLabelColor
        }
        refreshCrumbs()
    }

    @objc private func editShooterTapped(_ sender: NSMenuItem) {
        guard let prefix = sender.representedObject as? String,
              let shooter = ShooterStore.shared.shooters.first(where: { $0.prefix == prefix }) else { return }
        let alert = NSAlert()
        alert.messageText = "Edit shooter"
        alert.informativeText = "Card folders are named with the prefix - ansel-01, ansel-02…"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        nameField.stringValue = shooter.name
        let prefixField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        prefixField.stringValue = shooter.prefix
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        holder.addSubview(nameField)
        holder.addSubview(prefixField)
        alert.accessoryView = holder
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        var newPrefix = prefixField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if newPrefix.isEmpty { newPrefix = newName.lowercased().replacingOccurrences(of: " ", with: "") }
        guard !newName.isEmpty, !newPrefix.isEmpty else { return }
        ShooterStore.shared.updateShooter(prefix: prefix, newName: newName, newPrefix: newPrefix)
        if selectedShooterPrefix == prefix { selectedShooterPrefix = newPrefix }
        rebuildShooterChips()
        refreshShooterInfo()
        refreshCrumbs()
    }

    @objc private func removeShooterTapped(_ sender: NSMenuItem) {
        guard let prefix = sender.representedObject as? String,
              let shooter = ShooterStore.shared.shooters.first(where: { $0.prefix == prefix }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(shooter.name)?"
        alert.informativeText = "Their camera assignments are forgotten. Folders already on disk are untouched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ShooterStore.shared.removeShooter(prefix: prefix)
        if selectedShooterPrefix == prefix { selectedShooterPrefix = nil }
        rebuildShooterChips()
        refreshShooterInfo()
        refreshCrumbs()
    }

    @objc private func addShooterTapped(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Add a shooter"
        alert.informativeText = "Card folders are named with the prefix - ansel-01, ansel-02…"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        nameField.placeholderString = "Name (Ansel Adams)"
        let prefixField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        prefixField.placeholderString = "folder prefix (ansel)"
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        holder.addSubview(nameField)
        holder.addSubview(prefixField)
        alert.accessoryView = holder
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        var prefix = prefixField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if prefix.isEmpty { prefix = name.lowercased().replacingOccurrences(of: " ", with: "") }
        guard !name.isEmpty, !prefix.isEmpty else { return }
        let shooter = ShooterStore.shared.addShooter(name: name, prefix: prefix)
        selectedShooterPrefix = shooter.prefix
        if let serial = detectedSerial, ShooterStore.shared.shooter(forSerial: serial) == nil {
            ShooterStore.shared.assign(serial: serial, to: shooter.prefix, model: detectedModel)
        }
        rebuildShooterChips()
        refreshShooterInfo()
        refreshCrumbs()
    }

    private func refreshShooterInfo() {
        let uniqueSerials = Set(sectionSerials.values)
        if uniqueSerials.count > 1 {
            let names = uniqueSerials.map { serial -> String in
                let model = ShooterStore.shared.cameraModel(forSerial: serial).map { ShooterStore.shortModel($0) }
                if let shooter = ShooterStore.shared.shooter(forSerial: serial) {
                    return model.map { "\(shooter.name)'s \($0)" } ?? shooter.name
                }
                return model ?? "unknown camera"
            }.sorted()
            let known = uniqueSerials.allSatisfy { ShooterStore.shared.shooter(forSerial: $0) != nil }
            shooterInfo.stringValue = known
                ? "\(uniqueSerials.count) cameras - \(names.joined(separator: " + ")). Splits into per-shooter folders."
                : "\(uniqueSerials.count) cameras (\(names.joined(separator: " + "))) - unclaimed follow the selected chip."
            shooterInfo.textColor = .secondaryLabelColor
            return
        }
        if let serial = detectedSerial {
            let model = detectedModel ?? ShooterStore.shared.cameraModel(forSerial: serial)
            let body = model.map { ShooterStore.shortModel($0) }
            if let shooter = ShooterStore.shared.shooter(forSerial: serial) {
                shooterInfo.stringValue = body.map { "\(shooter.name)'s \($0) - recognized" }
                    ?? "\(shooter.name)'s camera - recognized"
                shooterInfo.textColor = .secondaryLabelColor
            } else {
                shooterInfo.stringValue = body.map { "New camera - \($0). Tap who shot it (remembered forever)" }
                    ?? "New camera - tap who shot it (remembered forever)"
                shooterInfo.textColor = .secondaryLabelColor
            }
        } else {
            shooterInfo.stringValue = "Photos land in a per-card folder: ansel-01, ansel-02…"
            shooterInfo.textColor = .tertiaryLabelColor
        }
    }

    // MARK: - Cards

    private var cardScanGeneration = 0
    /// When the status line last received a RESTING message ("Card
    /// ejected", "Done - N copied", a failure). Card rescans retire
    /// stale ones - but not the message that triggered the rescan.
    private var statusStamp = Date.distantPast

    private func refreshCards() {
        cardRows.removeAll()

        cardScanGeneration += 1
        let generation = cardScanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found: [(card: URL, name: String, sections: [URL])] = IngestJob.detectCards().map { card in
                (card,
                 (try? card.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? card.lastPathComponent,
                 IngestJob.sections(of: card))
            }
            DispatchQueue.main.async {
                guard let self, self.cardScanGeneration == generation else { return }
                self.buildCardRows(found)
                self.detectCameraOnFirstCard(found)
            }
        }
    }

    private func buildCardRows(_ found: [(card: URL, name: String, sections: [URL])]) {
        // A NEW card context retires the old card's status ("Card ejected
        // - safe to remove" must not haunt the next card). The 1.5s grace
        // keeps the eject confirmation alive through its own rescan.
        if job == nil, Date().timeIntervalSince(statusStamp) > 1.5 {
            statusLabel.stringValue = ""
            statusLabel.toolTip = nil
            statusLabel.textColor = .secondaryLabelColor
        }
        detectedCardVolumes = found.map { $0.card }
        multiCardWarning.isHidden = found.count < 2
        ejectButton.isHidden = found.isEmpty
        railEmptyLabel.isHidden = !found.isEmpty
        moreLabel.isHidden = found.isEmpty
        thumbCells.forEach { $0.clear() }

        if let first = found.first {
            cardEyebrow.attributedStringValue = NSAttributedString(
                string: found.count > 1 ? "CARDS DETECTED (\(found.count))" : "CARD DETECTED",
                attributes: [.font: Theme.monoEyebrow, .foregroundColor: Theme.tx2, .kern: 1.4])
            specLine.font = Theme.monoData
            specLine.stringValue = (found.count > 1 ? "\(found.count) cards" : first.name) + " - counting…"
        } else {
            cardEyebrow.attributedStringValue = NSAttributedString(string: "NO CARD",
                attributes: [.font: Theme.monoEyebrow, .foregroundColor: Theme.tx2, .kern: 1.4])
            specLine.font = Theme.secondary
            specLine.stringValue = "Insert a memory card, or Refresh in Options."
            specLine.textColor = Theme.tx2
        }

        // The checkboxes live in the Choose… dialog now - the drawer line
        // only carries the verdict ("Whole card - 4 folders").
        let multipleCards = found.count > 1
        for (_, name, sections) in found {
            var row = CardRow(master: nil, sections: [])
            if multipleCards {
                let master = NSButton(checkboxWithTitle: "", target: self, action: #selector(masterToggled(_:)))
                master.attributedTitle = NSAttributedString(string: name, attributes: [
                    .font: Theme.monoDataStrong, .foregroundColor: Theme.tx0])
                master.state = .on
                row = CardRow(master: master, sections: [])
            }
            for section in sections {
                let label = section.lastPathComponent == "DCIM" ? "All files" : section.lastPathComponent
                let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(sectionToggled(_:)))
                check.attributedTitle = NSAttributedString(string: label, attributes: [
                    .font: Theme.monoCaption, .foregroundColor: Theme.tx1])
                check.state = .on
                check.controlSize = .small
                row.sections.append((check, section))
            }
            cardRows.append(row)
        }
        refreshScope()
        window?.layoutIfNeeded()
    }

    @objc private func masterToggled(_ sender: NSButton) {
        guard let row = cardRows.first(where: { $0.master === sender }) else { return }
        for (button, _) in row.sections { button.state = sender.state }
        refreshScope()
    }

    @objc private func sectionToggled(_ sender: NSButton) { refreshScope() }

    /// Sections the user has actually checked - the basis for "needs X".
    private var selectedSections: [URL] {
        cardRows.flatMap { $0.sections.filter { $0.button.state == .on }.map { $0.folder } }
    }
    private var selectedBytes: Int64 {
        // Before detection fills the maps, fall back to the whole-card
        // figure so the verdict isn't blank mid-scan.
        guard !sectionBytes.isEmpty else { return cardBytes }
        return selectedSections.reduce(0) { $0 + (sectionBytes[$1] ?? 0) }
    }
    private func refreshScope() {
        let total = cardRows.reduce(0) { $0 + $1.sections.count }
        let on = cardRows.reduce(0) { $0 + $1.sections.filter { $0.button.state == .on }.count }
        if total == 0 {
            foldersSummary.stringValue = "No card"
            foldersSummary.textColor = .tertiaryLabelColor
        } else if on == total {
            foldersSummary.stringValue = total == 1 ? "Whole card" : "Whole card - all \(total) folders"
            foldersSummary.textColor = Theme.tx1
        } else if on == 0 {
            foldersSummary.stringValue = "None selected"
            foldersSummary.textColor = Theme.red
        } else {
            foldersSummary.stringValue = "\(on) of \(total) folders"
            foldersSummary.textColor = Theme.tx1
        }
        guard !detectedCardName.isEmpty else { return }
        refreshSpecLine(cardName: detectedCardName)
        refreshSpace()
    }

    /// The folder checkboxes, summoned on demand - the drawer stays terse.
    @objc private func chooseFolders(_ sender: Any?) {
        guard !cardRows.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Which folders should copy?"
        alert.informativeText = "Cameras write one folder per body or per thousand frames."
        alert.addButton(withTitle: "Done")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let multiple = cardRows.count > 1
        for row in cardRows {
            if let master = row.master { stack.addArrangedSubview(master) }
            for (button, _) in row.sections {
                if multiple {
                    let indent = NSStackView(views: [button])
                    indent.orientation = .horizontal
                    indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
                    stack.addArrangedSubview(indent)
                } else {
                    stack.addArrangedSubview(button)
                }
            }
        }
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.refreshScope()
        }
    }

    @objc private func clearBackup(_ sender: Any?) {
        backupDestination = nil
        refreshBackupUI()
    }

    @objc private func chooseBackupDestination(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = backupDestination
        panel.prompt = "Set Backup Destination"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                self?.refreshBackupUI()
                return
            }
            // A backup on the SAME drive dies with it - that's a copy,
            // not a backup. Warn, don't forbid.
            let mainVolume = (try? self.destination.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
            let pickedVolume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
            if let mainVolume, mainVolume == pickedVolume {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "That's the same drive as the main destination."
                alert.informativeText = "A backup on the same drive dies with it. Pick a different drive for a real backup - or keep this for a plain second copy."
                alert.addButton(withTitle: "Pick a Different Drive")
                alert.addButton(withTitle: "Use Anyway")
                if alert.runModal() == .alertFirstButtonReturn {
                    DispatchQueue.main.async { self.chooseBackupDestination(nil) }
                    return
                }
            }
            self.backupDestination = url
            self.refreshBackupUI()
        }
    }

    private func refreshBackupUI() {
        // The backup slot is ALWAYS on the sheet - an empty slot is an
        // invitation, a filled one is a promise.
        let hasBackup = backupDestination != nil
        backupRow.isHidden = false
        backupRule.isHidden = false
        backupSpaceRow.isHidden = !hasBackup
        backupClearButton.isHidden = !hasBackup
        backupChangeButton.title = hasBackup ? "Change" : "Add Backup…"
        trustLabel.stringValue = hasBackup
            ? "Your card is never changed - photos are copied to both drives."
            : "Your card is never changed - photos are copied."
        refreshCrumbs()
        window?.layoutIfNeeded()
    }

    @objc private func structureChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1, forKey: "QuickCullPreserveFolders")
    }

    @objc private func newOnlyToggled(_ sender: BrassSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "QuickCullSkipExisting")
    }

    @objc private func notifyToggled(_ sender: BrassSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "QuickCullNotifyWhenDone")
    }

    @objc private func insertToken(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        patternField.stringValue += token
        UserDefaults.standard.set(patternField.stringValue, forKey: "QuickCullCopyAsPattern")
        refreshPatternHint()
    }

    /// The COPY AS answer, not documentation: show what the pattern DOES.
    private func refreshPatternHint() {
        let pattern = patternField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else {
            patternHint.stringValue = "→ original names kept"
            patternHint.toolTip = nil
            return
        }
        let n = max(1, UserDefaults.standard.integer(forKey: "QuickCullIngestSeq"))
        let one = IngestJob.applyPattern(pattern, seq: 1, ingest: n, originalStem: "IMG_4021")
        let two = IngestJob.applyPattern(pattern, seq: 2, ingest: n, originalStem: "IMG_4022")
        patternHint.stringValue = "→ \(one).CR3, \(two).CR3…"
        patternHint.toolTip = patternHint.stringValue
    }

    @objc private func refreshTapped(_ sender: Any?) {
        refreshCards()
    }

    /// One frame per SECTION off the first card: serials + models + card
    /// UUID; plus totals for the spec line and the first six thumbnails.
    private func detectCameraOnFirstCard(_ found: [(card: URL, name: String, sections: [URL])]) {
        guard let first = found.first else {
            detectedSerial = nil; detectedModel = nil; detectedCardUUID = nil
            cardMemoryFolderExists = false
            sectionSerials = [:]; cardPhotoCount = 0; cardBytes = 0
            sectionBytes = [:]
            refreshShooterInfo(); refreshCrumbs()
            return
        }
        let generation = cardScanGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let uuid = ShooterStore.volumeUUID(of: first.card)
            var perSection: [URL: (serial: String, model: String?)] = [:]
            var allFiles: [URL] = []
            // EVERY card's sections - two readers at once is a real
            // wedding-night shape, and card 2's serials matter as much
            // as card 1's.
            var perSectionBytes: [URL: Int64] = [:]
            for cardEntry in found {
                for section in cardEntry.sections {
                    let files = IngestJob.mediaFiles(under: section)
                    allFiles.append(contentsOf: files)
                    perSectionBytes[section] = files.reduce(Int64(0)) {
                        $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    }
                    if let file = files.first, let info = ShooterStore.cameraInfo(of: file) {
                        perSection[section] = info
                    }
                }
            }
            let bytes = perSectionBytes.values.reduce(0, +)
            let thumbSources = Array(allFiles.prefix(6))
            let memoryFolderExists: Bool = {
                guard let uuid, let memory = ShooterStore.shared.cardMemory(volumeUUID: uuid) else { return false }
                return FileManager.default.fileExists(atPath: memory.lastFolder)
            }()
            DispatchQueue.main.async {
                guard let self, self.cardScanGeneration == generation else { return }
                self.sectionSerials = perSection.mapValues { $0.serial }
                let headline = first.sections.compactMap { perSection[$0] }.first
                self.detectedSerial = headline?.serial
                self.detectedModel = headline?.model
                self.detectedCardUUID = uuid
                self.cardMemoryFolderExists = memoryFolderExists
                self.cardPhotoCount = allFiles.count
                self.cardBytes = bytes
                self.sectionBytes = perSectionBytes
                for (_, info) in perSection {
                    if let model = info.model { ShooterStore.shared.noteModel(model, forSerial: info.serial) }
                }
                // First open: recognition INFORMS, selecting stays the
                // user's move. Mid-session (job active): the recognized
                // shooter pre-selects - card 2 is insert, Enter.
                if self.sessionJob != nil,
                   let serial = headline?.serial,
                   let shooter = ShooterStore.shared.shooter(forSerial: serial) {
                    self.selectedShooterPrefix = shooter.prefix
                    self.rebuildShooterChips()
                }
                self.detectedCardName = found.count > 1 ? "\(found.count) cards" : first.name
                self.refreshSpecLine(cardName: self.detectedCardName)
                self.refreshShooterInfo()
                self.refreshCrumbs()
                for (index, cell) in self.thumbCells.enumerated() {
                    guard index < thumbSources.count else { cell.clear(); continue }
                    ThumbnailLoader.shared.request(thumbSources[index], maxPixel: 256) { [weak cell] image in
                        cell?.setImage(image)
                    }
                }
                self.moreLabel.stringValue = allFiles.count > 6 ? "+ \(allFiles.count - 6) more" : ""
            }
        }
    }

    private func refreshSpecLine(cardName: String) {
        let k: [NSAttributedString.Key: Any] = [.font: Theme.monoData, .foregroundColor: Theme.tx2]
        let v: [NSAttributedString.Key: Any] = [.font: Theme.monoDataStrong, .foregroundColor: Theme.tx0]
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: cardName, attributes: v))
        line.append(NSAttributedString(string: "   PHOTOS ", attributes: k))
        line.append(NSAttributedString(string: "\(cardPhotoCount)", attributes: v))
        line.append(NSAttributedString(string: "   SIZE ", attributes: k))
        line.append(NSAttributedString(string: ByteCountFormatter.string(fromByteCount: cardBytes, countStyle: .file), attributes: v))
        // The answer to "did it quietly pick a folder?" - scope is ALWAYS
        // on the face of the sheet, drawer open or closed.
        let total = cardRows.reduce(0) { $0 + $1.sections.count }
        let on = cardRows.reduce(0) { $0 + $1.sections.filter { $0.button.state == .on }.count }
        line.append(NSAttributedString(string: "   COPY ", attributes: k))
        if total == 0 || on == total {
            line.append(NSAttributedString(string: "whole card", attributes: v))
        } else if on == 0 {
            line.append(NSAttributedString(string: "none selected", attributes:
                [.font: Theme.monoDataStrong, .foregroundColor: Theme.red]))
        } else {
            line.append(NSAttributedString(string: "\(on) of \(total) folders", attributes: v))
        }
        specLine.attributedStringValue = line
    }

    // MARK: - Run

    @objc private func startTapped(_ sender: Any?) {
        let sources = cardRows.flatMap { row in
            row.sections.filter { $0.button.state == .on }.map { $0.folder }
        }
        guard !sources.isEmpty else { NSSound.beep(); return }
        guard destinationIsSet else {
            NSSound.beep()
            chooseDestination(nil)   // the missing decision, asked directly
            return
        }
        let jobName = jobField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobName.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(jobField)
            return
        }

        let jobFolder = destination.appendingPathComponent(jobName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: jobFolder, withIntermediateDirectories: true)
        } catch {
            statusLabel.stringValue = "Couldn't create job folder: \(error.localizedDescription)"
            return
        }
        if let template = templatePopup.titleOfSelectedItem, template != "None" {
            FolderTemplates.apply(template, to: jobFolder)
        }

        var target = jobFolder
        if let into = copyIntoPopup.titleOfSelectedItem, into != "Job folder" {
            target = jobFolder.appendingPathComponent(into, isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }

        // Group the selected sections by CARD + shooter: every card gets
        // its own numbered folder (two cards from one shooter = marco-01
        // AND marco-02), and a mixed card still splits per shooter.
        // Unknown serials follow the selected chip.
        var groups: [(prefix: String, sources: [URL])] = []
        if let fallback = selectedShooterPrefix {
            var byKey: [String: (prefix: String, sources: [URL])] = [:]
            for source in sources {
                let prefix = sectionSerials[source]
                    .flatMap { ShooterStore.shared.shooter(forSerial: $0)?.prefix } ?? fallback
                let volume = (try? source.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? ""
                let key = volume + "|" + prefix
                byKey[key, default: (prefix, [])].sources.append(source)
            }
            groups = byKey.sorted { $0.key < $1.key }.map { $0.value }
        }

        var runs: [(sources: [URL], target: URL, label: String)] = []
        if groups.count <= 1 {
            if let prefix = selectedShooterPrefix {
                if let uuid = detectedCardUUID,
                   let memory = ShooterStore.shared.cardMemory(volumeUUID: uuid),
                   memory.lastJob == jobName,
                   FileManager.default.fileExists(atPath: memory.lastFolder) {
                    target = URL(fileURLWithPath: memory.lastFolder, isDirectory: true)
                } else {
                    let sub = ShooterStore.nextCardFolderName(prefix: prefix, in: target)
                    target = target.appendingPathComponent(sub, isDirectory: true)
                }
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
            runs = [(sources, target, "")]
        } else {
            for (index, group) in groups.enumerated() {
                let sub = ShooterStore.nextCardFolderName(prefix: group.prefix, in: target)
                let groupTarget = target.appendingPathComponent(sub, isDirectory: true)
                try? FileManager.default.createDirectory(at: groupTarget, withIntermediateDirectories: true)
                runs.append((group.sources, groupTarget,
                             "Copy \(index + 1) of \(groups.count) - \(sub)…"))
            }
        }

        // BACKUP: mirror every run onto the second drive - same relative
        // structure, chained after the primary copies.
        let backupActive = backupEnabled
        if backupActive, let backupRoot = backupDestination {
            let primaryRuns = runs
            for run in primaryRuns {
                var rel = run.target.path
                if rel.hasPrefix(destination.path) { rel = String(rel.dropFirst(destination.path.count)) }
                while rel.hasPrefix("/") { rel.removeFirst() }
                let backupTarget = rel.isEmpty ? backupRoot
                    : backupRoot.appendingPathComponent(rel, isDirectory: true)
                try? FileManager.default.createDirectory(at: backupTarget, withIntermediateDirectories: true)
                runs.append((run.sources, backupTarget,
                             "Second copy - \(backupTarget.lastPathComponent)…"))
            }
        }
        if let uuid = detectedCardUUID {
            ShooterStore.shared.rememberCard(volumeUUID: uuid, job: jobName,
                                             folder: runs.first?.target.path ?? target.path)
            cardMemoryFolderExists = true   // we're about to create it
        }
        UserDefaults.standard.set(jobName, forKey: "QuickCullLastJob")
        sessionJob = jobName

        // Open the grid on the first landing folder - thumbnails pour in live.
        onOpenFolder?(runs.first?.target ?? target)

        startButton.isEnabled = false
        cancelButton.isHidden = false
        notNowButton.isHidden = true
        progressBar.isHidden = false
        ejectButton.isEnabled = false   // never mid-copy
        statusLabel.stringValue = "Starting…"

        // {iseq}: one import number per press of the brass button.
        currentIngestNumber = max(1, UserDefaults.standard.integer(forKey: "QuickCullIngestSeq"))
        UserDefaults.standard.set(currentIngestNumber + 1, forKey: "QuickCullIngestSeq")

        chainCopied = 0; chainSkipped = 0; chainErrors = []
        let progressHandler: (IngestJob.Progress) -> Void = { [weak self] progress in
            guard let self else { return }
            if progress.bytesTotal > 0 {
                self.progressBar.doubleValue = Double(progress.bytesDone) / Double(progress.bytesTotal)
            }
            let done = ByteCountFormatter.string(fromByteCount: progress.bytesDone, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.bytesTotal, countStyle: .file)
            var line = "\(progress.filesDone)/\(progress.filesTotal) files · \(done) of \(total)"
            if progress.skipped > 0 { line += " · \(progress.skipped) already there" }
            self.statusLabel.stringValue = line
        }
        let completeHandler: (Int, Int, [String]) -> Void = { [weak self] copied, skipped, errors in
            guard let self else { return }
            self.progressBar.doubleValue = 1
            self.startButton.isEnabled = true
            self.startButton.attributedTitle = NSAttributedString(string: "Ingest Again", attributes: [
                .font: Theme.bodyStrong,
                .foregroundColor: NSColor(calibratedRed: 0.09, green: 0.075, blue: 0.06, alpha: 1)
            ])
            self.cancelButton.isHidden = true
            self.notNowButton.isHidden = false
            self.ejectButton.isEnabled = true
            self.lastErrors = errors
            self.errorsButton.isHidden = errors.isEmpty
            self.errorsButton.title = "Show \(errors.count) Failure\(errors.count == 1 ? "" : "s")…"
            var line = backupActive
                ? "Done - \(copied) files written · 2 destinations"
                : "Done - \(copied) copied"
            if skipped > 0 { line += ", \(skipped) skipped" }
            if !errors.isEmpty {
                line = "⚠ Done with FAILURES - \(copied) copied, \(errors.count) failed. Do NOT format the card."
                self.statusLabel.textColor = .systemRed
            } else {
                self.statusLabel.textColor = .secondaryLabelColor
            }
            self.statusLabel.stringValue = line
            self.statusStamp = Date()
            for error in errors { NSLog("funo ingest error: \(error)") }
            self.job = nil
            if errors.isEmpty, UserDefaults.standard.bool(forKey: "QuickCullEjectWhenDone") {
                self.ejectTapped(nil)
            }
            if UserDefaults.standard.bool(forKey: "QuickCullNotifyWhenDone") {
                NSSound(named: "Glass")?.play()
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        runChain(runs: runs, index: 0, onProgress: progressHandler, onComplete: completeHandler)
    }

    /// Sequential per-shooter runs for a mixed card. Each group gets a
    /// FRESH IngestJob (the engine accumulates per-instance state); totals
    /// carry across so the final report covers the whole card.
    private func runChain(runs: [(sources: [URL], target: URL, label: String)], index: Int,
                          onProgress: @escaping (IngestJob.Progress) -> Void,
                          onComplete: @escaping (Int, Int, [String]) -> Void) {
        guard index < runs.count else { return }
        let run = runs[index]
        let newJob = IngestJob()
        self.job = newJob
        let defaults = UserDefaults.standard
        let pattern = (defaults.string(forKey: "QuickCullCopyAsPattern") ?? "")
            .trimmingCharacters(in: .whitespaces)
        newJob.renamePattern = pattern.isEmpty ? nil : pattern
        newJob.ingestNumber = currentIngestNumber
        newJob.skipExisting = defaults.object(forKey: "QuickCullSkipExisting") == nil
            || defaults.bool(forKey: "QuickCullSkipExisting")
        newJob.preserveFolders = defaults.bool(forKey: "QuickCullPreserveFolders")
        newJob.onProgress = onProgress
        if index < runs.count - 1 {
            newJob.onComplete = { [weak self] copied, skipped, errors in
                guard let self else { return }
                self.chainCopied += copied
                self.chainSkipped += skipped
                self.chainErrors.append(contentsOf: errors)
                self.runChain(runs: runs, index: index + 1,
                              onProgress: onProgress, onComplete: onComplete)
            }
        } else {
            newJob.onComplete = { [weak self] copied, skipped, errors in
                guard let self else { return }
                onComplete(self.chainCopied + copied,
                           self.chainSkipped + skipped,
                           self.chainErrors + errors)
            }
        }
        if !run.label.isEmpty {
            statusLabel.stringValue = run.label
        }
        newJob.start(sources: run.sources, destination: run.target)
    }

    // MARK: - Footer actions

    @objc private func toggleDrawer(_ sender: Any?) {
        drawer.isHidden.toggle()
        optionsButton.title = drawer.isHidden ? "Options…" : "Hide Options"
        window?.contentView?.layoutSubtreeIfNeeded()
        if let content = window?.contentView {
            window?.setContentSize(content.fittingSize)
        }
    }

    @objc private func notNowTapped(_ sender: Any?) {
        window?.close()
    }

    @objc private func ejectTapped(_ sender: Any?) {
        guard job == nil else { NSSound.beep(); return }
        let volumes = detectedCardVolumes
        guard !volumes.isEmpty else { return }

        cardScanGeneration += 1                     // orphan any running walk
        ejectButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Releasing card…"

        // Ejector releases every hold f/uno owns (grid watchers, queued
        // decodes), retries the blocking unmount off-main, and on failure
        // asks lsof who ELSE is pinning the card.
        Ejector.eject(volumes: volumes) { [weak self] result in
            guard let self else { return }
            self.ejectButton.isEnabled = true
            self.statusStamp = Date()
            if result.succeeded {
                self.statusLabel.textColor = .secondaryLabelColor
                self.statusLabel.stringValue = result.ejected.count == 1
                    ? "Card ejected - safe to remove."
                    : "\(result.ejected.count) cards ejected - safe to remove."
                self.refreshCards()
            } else {
                self.statusLabel.textColor = .systemOrange
                self.statusLabel.stringValue = result.failureMessage
                self.statusLabel.toolTip = result.failureDetail
            }
            // NO refresh on failure - a rescan would re-open the very files
            // we're trying to release, making retry a coin flip.
        }
    }

    @objc private func cancelTapped(_ sender: Any?) {
        job?.cancel()
        statusLabel.stringValue = "Cancelling…"
    }

    @objc private func chooseDestination(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Set Destination"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.destination = url
        }
    }

    @objc private func showErrors(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(lastErrors.count) file\(lastErrors.count == 1 ? "" : "s") failed to copy"
        alert.informativeText = "These files are still on the card - do not format it. "
            + "Re-running the same ingest retries only what's missing.\n\n"
            + lastErrors.prefix(25).joined(separator: "\n")
            + (lastErrors.count > 25 ? "\n…and \(lastErrors.count - 25) more" : "")
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Aspect-fill photo cell for the rail - layer-backed so previews crop
/// like photographs instead of letterboxing like attachments.
private final class ThumbCell: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setImage(_ image: NSImage?) {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        layer?.contents = cg
    }
    func clear() {
        layer?.contents = nil
    }
}

/// The mock's toggle: 30×18 pill, brass when on. NSSwitch can't be tinted
/// and its system blue would be a foreign object in this sheet.
private final class BrassSwitch: NSControl {
    var state: NSControl.StateValue = .off { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let track = NSRect(x: 0, y: (bounds.height - 18) / 2, width: 30, height: 18)
        let pill = NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9)
        (on ? Theme.accent
            : NSColor(srgbRed: 42/255, green: 45/255, blue: 49/255, alpha: 1)).setFill()
        pill.fill()
        if !on {
            Theme.line.setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }
        let knobX = on ? track.maxX - 15.5 : track.minX + 2.5
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: track.midY - 6.5, width: 13, height: 13))
        (on ? NSColor(srgbRed: 23/255, green: 19/255, blue: 16/255, alpha: 1)
            : NSColor(srgbRed: 220/255, green: 217/255, blue: 211/255, alpha: 1)).setFill()
        knob.fill()
    }

    override func mouseDown(with event: NSEvent) {
        state = state == .on ? .off : .on
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}
