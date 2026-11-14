import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum StatusModeChoice: String, CaseIterable, Identifiable {
    case simple
    case template
    case script

    var id: String { rawValue }
    var title: String {
        switch self {
        case .simple: return "简洁默认"
        case .template: return "自定义模板"
        case .script: return "脚本完全接管"
        }
    }
}

struct IgnoredAppDisplay: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let icon: NSImage
    var id: String { bundleID }
}

final class SettingsViewModel: ObservableObject {
    @Published var selectedTab: SettingsTab = .layout
    @Published var modifiers: [String]
    @Published var workspaceMode: String
    @Published var workspaceCount: Int
    @Published var masterRatioPercent: Double
    @Published var ratioStepPercent: Double
    @Published var masterCount: Int

    @Published var ignoreApps: [String]
    @Published var manualBundleID: String = ""
    @Published var showManualBundleInput: Bool = false

    @Published var appWorkspaces: [String: WorkspaceTarget]
    @Published var manualAssignBundleID: String = ""
    @Published var manualAssignWorkspace: Int = 2
    @Published var showManualAssignInput: Bool = false

    @Published var statusShowIcon: Bool
    @Published var spaceLabels: [String]
    @Published var workspaceIcons: [String]
    @Published var newSpaceLabel: String = ""
    @Published var statusMode: StatusModeChoice

    // Template mode fields
    @Published var customTemplate: String
    @Published var workspaceCurrent: String
    @Published var workspaceOther: String
    @Published var primaryFont: String
    @Published var statusFontSize: Double
    @Published var commands: [StatusCommand]

    // Script mode fields
    @Published var scriptName: String
    @Published var scriptExecutable: String
    @Published var scriptArgumentsText: String
    @Published var scriptInterval: Double
    @Published var scriptTimeout: Double
    @Published var scriptMarkup: Bool
    @Published var scriptOnChange: Bool

    // Optional file I/O
    @Published var statusTextFile: String
    @Published var statusStateFile: String

    // Disclosure states
    @Published var showWorkspaceStyleSection: Bool = false
    @Published var showCommandsSection: Bool = false
    @Published var showFileIOSection: Bool = false

    // Persistence status
    @Published var saveURL: URL
    @Published var migratedFromJSON: Bool
    @Published var statusBanner: String = "修改会自动保存到配置文件并立即生效"
    @Published var validationMessage: String?

    private var legacyFormat: String
    private var extraFonts: [String]
    private var suppressAutoSave = false
    private var saveWorkItem: DispatchWorkItem?
    var onConfigurationApplied: ((Configuration, URL) -> Void)?
    var lastWrittenDate: Date?

    init(config: Configuration, resolution: ConfigResolution) {
        self.saveURL = resolution.saveURL
        self.migratedFromJSON = resolution.migratedFromJSON
        self.modifiers = config.modifiers
        self.workspaceMode = config.workspaceMode
        self.workspaceCount = config.workspaceCount
        self.masterRatioPercent = (config.masterRatio * 100).rounded()
        self.ratioStepPercent = (config.ratioStep * 1000).rounded() / 10
        self.masterCount = config.masterCount
        self.ignoreApps = config.ignoreApps
        self.appWorkspaces = config.appWorkspaces

        self.statusShowIcon = config.statusShowIcon
        self.spaceLabels = config.spaceLabels
        self.workspaceIcons = config.workspaceIcons
        self.legacyFormat = config.statusFormat
        self.workspaceCurrent = config.workspaceCurrent
        self.workspaceOther = config.workspaceOther
        self.primaryFont = config.statusFonts.first ?? ""
        self.extraFonts = Array(config.statusFonts.dropFirst())
        self.statusFontSize = config.statusFontSize
        self.commands = config.statusCommands
        self.statusTextFile = config.statusTextFile ?? ""
        self.statusStateFile = config.statusStateFile ?? ""

        let defaults = Configuration()
        if config.statusCommands.count == 1,
           let only = config.statusCommands.first,
           config.statusTemplate?.trimmingCharacters(in: .whitespaces) == "%\(only.name)%" {
            self.statusMode = .script
            self.customTemplate = "%spaces%  <fc=#89CFC2>%layout%</fc>"
            self.scriptName = only.name
            self.scriptExecutable = only.executable
            self.scriptArgumentsText = (only.arguments ?? []).joined(separator: " ")
            self.scriptInterval = only.interval ?? 10
            self.scriptTimeout = only.timeout ?? 2
            self.scriptMarkup = only.markup ?? true
            self.scriptOnChange = only.onChange ?? true
        } else if config.statusTemplate != nil || !config.statusCommands.isEmpty || config.statusFormat != defaults.statusFormat {
            self.statusMode = .template
            self.customTemplate = config.statusTemplate ?? "%spaces%  <fc=#89CFC2>%layout%</fc>"
            self.scriptName = "mybar"
            self.scriptExecutable = "/usr/bin/python3"
            self.scriptArgumentsText = ""
            self.scriptInterval = 10
            self.scriptTimeout = 2
            self.scriptMarkup = true
            self.scriptOnChange = true
        } else {
            self.statusMode = .simple
            self.customTemplate = "%spaces%  <fc=#89CFC2>%layout%</fc>"
            self.scriptName = "mybar"
            self.scriptExecutable = "/usr/bin/python3"
            self.scriptArgumentsText = ""
            self.scriptInterval = 10
            self.scriptTimeout = 2
            self.scriptMarkup = true
            self.scriptOnChange = true
        }

        self.showWorkspaceStyleSection = false
        self.showCommandsSection = false
        self.showFileIOSection = false

        if resolution.migratedFromJSON {
            self.statusBanner = "已读取旧版 config.json；修改后将保存至 \(abbreviatedPath(resolution.saveURL))"
        }
    }

    func reloadFromExternal(config: Configuration, resolution: ConfigResolution) {
        suppressAutoSave = true
        defer { suppressAutoSave = false }

        saveURL = resolution.saveURL
        migratedFromJSON = resolution.migratedFromJSON
        modifiers = config.modifiers
        workspaceMode = config.workspaceMode
        workspaceCount = config.workspaceCount
        masterRatioPercent = (config.masterRatio * 100).rounded()
        ratioStepPercent = (config.ratioStep * 1000).rounded() / 10
        masterCount = config.masterCount
        ignoreApps = config.ignoreApps
        appWorkspaces = config.appWorkspaces
        statusShowIcon = config.statusShowIcon
        spaceLabels = config.spaceLabels
        workspaceIcons = config.workspaceIcons
        legacyFormat = config.statusFormat
        workspaceCurrent = config.workspaceCurrent
        workspaceOther = config.workspaceOther
        primaryFont = config.statusFonts.first ?? ""
        extraFonts = Array(config.statusFonts.dropFirst())
        statusFontSize = config.statusFontSize
        commands = config.statusCommands
        statusTextFile = config.statusTextFile ?? ""
        statusStateFile = config.statusStateFile ?? ""

        let defaults = Configuration()
        if config.statusCommands.count == 1,
           let only = config.statusCommands.first,
           config.statusTemplate?.trimmingCharacters(in: .whitespaces) == "%\(only.name)%" {
            statusMode = .script
            scriptName = only.name
            scriptExecutable = only.executable
            scriptArgumentsText = (only.arguments ?? []).joined(separator: " ")
            scriptInterval = only.interval ?? 10
            scriptTimeout = only.timeout ?? 2
            scriptMarkup = only.markup ?? true
            scriptOnChange = only.onChange ?? true
        } else if config.statusTemplate != nil || !config.statusCommands.isEmpty || config.statusFormat != defaults.statusFormat {
            statusMode = .template
            customTemplate = config.statusTemplate ?? "%spaces%  <fc=#89CFC2>%layout%</fc>"
        } else {
            statusMode = .simple
        }
        validationMessage = nil
        statusBanner = "已从磁盘同步最新配置 (\(abbreviatedPath(saveURL)))"
    }

    func buildConfiguration() -> Configuration {
        var config = Configuration()
        let orderedMods = ["control", "option", "command"].filter { modifiers.contains($0) }
        config.modifiers = orderedMods.isEmpty ? ["option"] : orderedMods
        config.workspaceMode = (workspaceMode == "virtual") ? "virtual" : "native"
        config.workspaceCount = min(9, max(1, workspaceCount))
        config.masterRatio = min(0.8, max(0.2, (masterRatioPercent.rounded() / 100.0)))
        config.ratioStep = min(0.2, max(0.01, ((ratioStepPercent * 10).rounded() / 1000.0)))
        config.masterCount = min(20, max(1, masterCount))
        config.ignoreApps = ignoreApps
        config.appWorkspaces = appWorkspaces

        config.statusShowIcon = statusShowIcon
        config.spaceLabels = spaceLabels.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)) }.filter { !$0.isEmpty }
        config.workspaceIcons = workspaceIcons.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)) }.filter { !$0.isEmpty }

        let trimmedFont = primaryFont.trimmingCharacters(in: .whitespacesAndNewlines)
        config.statusFonts = trimmedFont.isEmpty ? [] : ([trimmedFont] + extraFonts)
        config.statusFontSize = (statusFontSize * 2).rounded() / 2

        let trimmedText = statusTextFile.trimmingCharacters(in: .whitespacesAndNewlines)
        config.statusTextFile = trimmedText.isEmpty ? nil : trimmedText
        let trimmedState = statusStateFile.trimmingCharacters(in: .whitespacesAndNewlines)
        config.statusStateFile = trimmedState.isEmpty ? nil : trimmedState

        switch statusMode {
        case .simple:
            config.statusTemplate = nil
            config.statusFormat = "{spaces}  {layout}"
            config.workspaceCurrent = workspaceCurrent
            config.workspaceOther = workspaceOther
            config.statusCommands = []
        case .template:
            config.statusTemplate = customTemplate
            config.workspaceCurrent = workspaceCurrent
            config.workspaceOther = workspaceOther
            config.statusCommands = commands
        case .script:
            let safeName = scriptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mybar" : scriptName.trimmingCharacters(in: .whitespacesAndNewlines)
            config.statusTemplate = "%\(safeName)%"
            config.workspaceCurrent = workspaceCurrent
            config.workspaceOther = workspaceOther
            let args = parseArgumentLine(scriptArgumentsText)
            config.statusCommands = [
                StatusCommand(
                    name: safeName,
                    executable: scriptExecutable.trimmingCharacters(in: .whitespacesAndNewlines),
                    arguments: args.isEmpty ? nil : args,
                    interval: scriptInterval,
                    timeout: scriptTimeout,
                    markup: scriptMarkup,
                    onChange: scriptOnChange
                )
            ]
        }
        return config
    }

    func notifyChanged(immediate: Bool = false) {
        guard !suppressAutoSave else { return }
        let candidate = buildConfiguration()
        do {
            try candidate.validate()
            validationMessage = nil
        } catch {
            validationMessage = localizeValidationError(error)
            return
        }

        onConfigurationApplied?(candidate, saveURL)

        saveWorkItem?.cancel()
        let writeBlock = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                try candidate.save(to: self.saveURL)
                self.lastWrittenDate = Date()
                self.migratedFromJSON = false
                self.statusBanner = "✓ 已自动保存至 \(abbreviatedPath(self.saveURL)) 并生效"
            } catch {
                self.validationMessage = "保存失败：\(error)"
            }
        }
        saveWorkItem = writeBlock
        if immediate {
            writeBlock.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: writeBlock)
        }
    }

    func flushPendingSave() {
        if let pending = saveWorkItem, !pending.isCancelled {
            pending.cancel()
            notifyChanged(immediate: true)
        }
    }

    func resetToDefaults() {
        let defaults = Configuration()
        reloadFromExternal(config: defaults, resolution: ConfigResolution(loadURL: saveURL, saveURL: saveURL, migratedFromJSON: false))
        notifyChanged(immediate: true)
    }

    func toggleModifier(_ mod: String) {
        if modifiers.contains(mod) {
            guard modifiers.count > 1 else { return }
            modifiers.removeAll { $0 == mod }
        } else {
            modifiers.append(mod)
        }
        notifyChanged(immediate: true)
    }

    func setModifierPreset(_ preset: [String]) {
        modifiers = preset
        notifyChanged(immediate: true)
    }

    var modifierSymbolPrefix: String {
        var out = ""
        if modifiers.contains("control") { out += "⌃" }
        if modifiers.contains("option") { out += "⌥" }
        if modifiers.contains("command") { out += "⌘" }
        return out
    }

    func addIgnoredApp(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ignoreApps.contains(trimmed) else { return }
        appWorkspaces.removeValue(forKey: trimmed)
        ignoreApps.append(trimmed)
        notifyChanged(immediate: true)
    }

    func removeIgnoredApp(_ bundleID: String) {
        ignoreApps.removeAll { $0 == bundleID }
        notifyChanged(immediate: true)
    }

    func setAppWorkspace(_ bundleID: String, workspaceOneBased: Int) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clamped = min(9, max(1, workspaceOneBased))
        ignoreApps.removeAll { $0 == trimmed }
        if case .label = appWorkspaces[trimmed], clamped - 1 < spaceLabels.count {
            appWorkspaces[trimmed] = .label(spaceLabels[clamped - 1])
        } else {
            appWorkspaces[trimmed] = .index(clamped)
        }
        notifyChanged(immediate: true)
    }

    func removeAppWorkspace(_ bundleID: String) {
        appWorkspaces.removeValue(forKey: bundleID)
        notifyChanged(immediate: true)
    }

    func workspaceOptionTitle(oneBased: Int) -> String {
        if oneBased - 1 >= 0, oneBased - 1 < spaceLabels.count {
            return "工作区 \(oneBased) · \(spaceLabels[oneBased - 1])"
        }
        return "工作区 \(oneBased)"
    }

    func resolvedOneBasedWorkspace(for target: WorkspaceTarget) -> Int {
        if let zeroBased = target.resolve(workspaceCount: 9, spaceLabels: spaceLabels) {
            return min(max(1, workspaceCount), zeroBased + 1)
        }
        if case .index(let n) = target {
            return min(max(1, workspaceCount), max(1, n))
        }
        return min(max(1, workspaceCount), 2)
    }

    func applyTemplatePreset(_ preset: String) {
        switch preset {
        case "icons":
            customTemplate = "%spaces%  <fc=#80808066>│</fc>  <fc=#14B8A6>%layout%</fc> · %count%"
            workspaceCurrent = "<fc=#FFFFFF,#0F766E> %icon%%fullscreen% </fc>"
            workspaceOther = " %icon%%fullscreen% "
            if workspaceIcons.isEmpty {
                workspaceIcons = ["terminal", "globe", "chevron.left.forwardslash.chevron.right", "bubble.left.and.bubble.right", "square.grid.2x2"]
            }
        case "compact":
            customTemplate = "%spaces%  <fc=#80808066>│</fc>  <fc=#0D9488>%layout%</fc> · %count%"
            workspaceCurrent = "<fc=#FFFFFF,#0F766E> %index%:%label%%fullscreen% </fc>"
            workspaceOther = " %index%:%label%%occupied%%fullscreen% "
        case "underline":
            customTemplate = "%spaces%  <fc=#80808066>│</fc>  <fc=#14B8A6>%layout%</fc> · %count%"
            workspaceCurrent = "<box type=Bottom width=2 color=#14B8A6> %index%:%label%%fullscreen% </box>"
            workspaceOther = " %index%:%label%%occupied%%fullscreen% "
        case "pills":
            customTemplate = "%spaces%  <fc=,#80808024> %layout% · %count% </fc>"
            workspaceCurrent = "<fc=#FFFFFF,#0F766E><box type=Full width=1 color=#2DD4BF80> %index%:%label%%fullscreen% </box></fc>"
            workspaceOther = "<fc=,#80808022> %index%:%label%%occupied%%fullscreen% </fc>"
        case "powerline":
            customTemplate = "%spaces%  <fc=#D97706>▶ %layout%</fc>"
            workspaceCurrent = "<fc=#191C24,#F0C674> %index%:%label%%fullscreen% </fc>"
            workspaceOther = "<fc=,#80808028> %index%:%label%%occupied%%fullscreen% </fc>"
        case "clock":
            customTemplate = "%spaces%  <fc=#80808066>│</fc>  <fc=#0D9488>%layout%</fc>  %clock%"
            workspaceCurrent = "<fc=#FFFFFF,#0F766E> %index%:%label%%fullscreen% </fc>"
            workspaceOther = " %index%:%label%%occupied%%fullscreen% "
            if !commands.contains(where: { $0.name == "clock" }) {
                commands.append(StatusCommand(name: "clock", executable: "/bin/date", arguments: ["+%H:%M"], interval: 30, timeout: 2))
                showCommandsSection = true
            }
        default:
            break
        }
        notifyChanged(immediate: true)
    }

    func previewImage(dark: Bool) -> NSImage {
        let candidate = buildConfiguration()
        let sampleSpaces: [SpaceEntry]
        if candidate.workspaceMode == "virtual" {
            sampleSpaces = (0..<candidate.workspaceCount).map { idx in
                let winCount = idx == 0 ? 2 : (idx == 1 ? 1 : 0)
                return SpaceEntry(id: UInt64(idx + 1), isCurrent: idx == 0, isFullscreen: false, windowCount: winCount)
            }
        } else {
            sampleSpaces = [
                SpaceEntry(id: 1, isCurrent: true, isFullscreen: false),
                SpaceEntry(id: 2, isCurrent: false, isFullscreen: false),
                SpaceEntry(id: 3, isCurrent: false, isFullscreen: true),
            ]
        }
        let sampleValues = StatusValues(
            spaces: sampleSpaces,
            layout: "Tall",
            title: "Terminal",
            count: candidate.workspaceMode == "virtual" ? 2 : 3,
            custom: "就绪",
            paused: false,
            spaceLabels: candidate.spaceLabels,
            spaceIcons: candidate.workspaceIcons
        )
        let parts = templateStatusParts(config: candidate, values: sampleValues) { idx in
            guard candidate.statusCommands.indices.contains(idx) else { return "" }
            let cmd = candidate.statusCommands[idx]
            if cmd.name == "clock" || cmd.executable.hasSuffix("/date") {
                let df = DateFormatter()
                df.dateFormat = "HH:mm"
                return df.string(from: Date())
            }
            if cmd.markup == true {
                return "<fc=#89CFC2>[1]</fc> 2 3•  Tall"
            }
            return "[\(cmd.name)]"
        }
        return configuredStatusImage(parts: parts, dark: dark, showIcon: candidate.statusShowIcon)
    }

    func openConfigInEditor() {
        flushPendingSave()
        if !FileManager.default.fileExists(atPath: saveURL.path) {
            try? buildConfiguration().save(to: saveURL)
        }
        if NSWorkspace.shared.urlForApplication(toOpen: saveURL) != nil {
            NSWorkspace.shared.open(saveURL)
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-t", saveURL.path]
            try? proc.run()
        }
    }

    func revealConfigInFinder() {
        flushPendingSave()
        if !FileManager.default.fileExists(atPath: saveURL.path) {
            try? buildConfiguration().save(to: saveURL)
        }
        NSWorkspace.shared.activateFileViewerSelecting([saveURL])
    }

    private func localizeValidationError(_ error: Error) -> String {
        if let cfgErr = error as? ConfigError {
            switch cfgErr {
            case .invalidModifiers: return "请至少选择一个快捷键修饰键"
            case .invalidWorkspaceMode: return "工作区模式必须为原生空间或虚拟工作区"
            case .invalidWorkspaceCount: return "虚拟工作区数量需在 1 到 9 之间"
            case .invalidAppWorkspace: return "应用自动归位规则无效：请检查 Bundle ID 与目标工作区（1–9 或有效名称）"
            case .invalidRatio: return "主窗口占比需在 20% 到 80% 之间"
            case .invalidStep: return "每次调整步长需在 1% 到 20% 之间"
            case .invalidCount: return "主区窗口数需在 1 到 20 之间"
            case .invalidStatusCommand: return "请检查命令：名称仅限字母数字（不能与内置变量重名），程序路径需为以 / 开头的绝对路径"
            case .conflictingStatusFiles: return "输入文本文件与状态导出文件不能是同一个路径"
            case .invalidStatusFormat: return "请检查工作区名称（1–16 字）、字号（8–14）或模板长度"
            }
        }
        return "\(error)"
    }
}

private func parseArgumentLine(_ text: String) -> [String] {
    var args: [String] = []
    var current = ""
    var quote: Character?
    for ch in text {
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
        } else if ch == " " || ch == "\t" {
            if !current.isEmpty { args.append(current); current = "" }
        } else {
            current.append(ch)
        }
    }
    if !current.isEmpty { args.append(current) }
    return args
}

func abbreviatedPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if url.path.hasPrefix(home + "/") {
        return "~" + String(url.path.dropFirst(home.count))
    }
    return url.path
}

func resolveAppDisplay(bundleID: String) -> IgnoredAppDisplay {
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let bundle = Bundle(url: appURL)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 28, height: 28)
        return IgnoredAppDisplay(bundleID: bundleID, name: name, icon: icon)
    }
    let fallback = NSWorkspace.shared.icon(for: .applicationBundle)
    fallback.size = NSSize(width: 28, height: 28)
    return IgnoredAppDisplay(bundleID: bundleID, name: bundleID, icon: fallback)
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case layout
    case rules
    case menubar

    var id: String { rawValue }
    var label: String {
        switch self {
        case .layout: return "快捷键与布局"
        case .rules: return "应用规则"
        case .menubar: return "菜单栏"
        }
    }
    var symbol: String {
        switch self {
        case .layout: return "rectangle.split.2x1"
        case .rules: return "macwindow.on.rectangle"
        case .menubar: return "menubar.rectangle"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Clean segmented tab bar header
            HStack {
                Spacer()
                Picker("", selection: $model.selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.label, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 390)
                Spacer()
            }
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.selectedTab {
                    case .layout:
                        ShortcutsAndLayoutView(model: model)
                    case .rules:
                        AppRulesView(model: model)
                    case .menubar:
                        MenuBarSettingsView(model: model)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .containerRelativeFrame(.horizontal, alignment: .leading)
            }

            Divider()

            // Persistent dotfile footer bar
            HStack(spacing: 10) {
                Image(systemName: model.validationMessage == nil ? "doc.text" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.validationMessage == nil ? .secondary : Color.orange)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 1) {
                    Text(abbreviatedPath(model.saveURL))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    if let warning = model.validationMessage {
                        Text(warning)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.orange)
                            .lineLimit(1)
                    } else {
                        Text(model.statusBanner)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button("重置默认") {
                    model.resetToDefaults()
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Button("在 Finder 中显示") {
                    model.revealConfigInFinder()
                }
                .controlSize(.small)

                Button("打开配置文件") {
                    model.openConfigInEditor()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 660)
    }
}

private struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = arranged.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard !subviews.isEmpty else { return (.zero, []) }
        let limit = maxWidth > 0 ? maxWidth : .infinity
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            var itemSize = subview.sizeThatFits(.unspecified)
            if limit.isFinite && itemSize.width > limit {
                itemSize = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                itemSize.width = min(itemSize.width, limit)
            }
            if x > 0 && x + itemSize.width > limit {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: itemSize))
            usedWidth = max(usedWidth, x + itemSize.width)
            x += itemSize.width + horizontalSpacing
            rowHeight = max(rowHeight, itemSize.height)
        }

        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ShortcutsAndLayoutView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SectionCard(
            title: "工作区模式",
            subtitle: model.workspaceMode == "virtual"
                ? "由 Talus 接管多工作区：支持快捷键无动画瞬切与一键移窗（退出时自动恢复所有窗口）。"
                : "跟随 macOS 原生桌面空间（Mission Control），由系统快捷键或触控板滑动切换。"
        ) {
            HStack(spacing: 12) {
                Picker("", selection: $model.workspaceMode) {
                    Text("macOS 原生空间").tag("native")
                    Text("Talus 虚拟工作区").tag("virtual")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 268)
                .onChange(of: model.workspaceMode) { _, _ in
                    model.notifyChanged(immediate: true)
                }

                Spacer()

                if model.workspaceMode == "virtual" {
                    HStack(spacing: 6) {
                        Text("预设数量")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Stepper(value: $model.workspaceCount, in: 1...9) {
                            Text("\(model.workspaceCount) 个")
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        }
                        .onChange(of: model.workspaceCount) { _, _ in
                            model.notifyChanged(immediate: true)
                        }
                    }
                }
            }
        }

        SectionCard(
            title: "快捷键修饰键",
            subtitle: "点选修饰键组合（也可一键切换常用方案）；至少保留一个修饰键。"
        ) {
            HStack(spacing: 8) {
                ModifierKeyButton(symbol: "⌃", name: "Control", active: model.modifiers.contains("control")) {
                    model.toggleModifier("control")
                }
                ModifierKeyButton(symbol: "⌥", name: "Option", active: model.modifiers.contains("option")) {
                    model.toggleModifier("option")
                }
                ModifierKeyButton(symbol: "⌘", name: "Command", active: model.modifiers.contains("command")) {
                    model.toggleModifier("command")
                }

                Spacer()

                Menu("快速预设") {
                    Button("⌥ 单键 Option（最顺手）") { model.setModifierPreset(["option"]) }
                    Button("⌃⌥ Control + Option（默认，少冲突）") { model.setModifierPreset(["control", "option"]) }
                    Button("⌘⌥ Command + Option") { model.setModifierPreset(["option", "command"]) }
                }
                .controlSize(.small)
                .fixedSize()
            }

            let prefix = model.modifierSymbolPrefix
            VStack(spacing: 6) {
                if model.workspaceMode == "virtual" {
                    let switchKeys = model.workspaceCount == 1 ? "\(prefix)1" : "\(prefix)1–\(model.workspaceCount)"
                    let moveKeys = model.workspaceCount == 1 ? "\(prefix)⇧1" : "\(prefix)⇧1–\(model.workspaceCount)"
                    HStack(spacing: 16) {
                        ShortcutRow(keys: switchKeys, action: "瞬时切换工作区")
                        ShortcutRow(keys: moveKeys, action: "将焦点窗口移至工作区")
                    }
                }
                HStack(spacing: 16) {
                    ShortcutRow(keys: "\(prefix)J / \(prefix)K", action: "切换焦点窗口")
                    ShortcutRow(keys: "\(prefix)⇧J / \(prefix)⇧K", action: "移动交换窗口")
                }
                HStack(spacing: 16) {
                    ShortcutRow(keys: "\(prefix)Return", action: "将当前窗口移至主区")
                    ShortcutRow(keys: "\(prefix)Space", action: "切换布局 (Tall / Mirror / Full)")
                }
                HStack(spacing: 16) {
                    ShortcutRow(keys: "\(prefix)H / \(prefix)L", action: "缩小 / 放大主区宽度")
                    ShortcutRow(keys: "\(prefix)T  ·  \(prefix)P", action: "浮动当前窗口 · 暂停平铺")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }

        SectionCard(
            title: "主副分栏布局",
            subtitle: "设置平铺时的初始主窗口占比与数量。"
        ) {
            HStack(alignment: .center, spacing: 18) {
                TilingPreviewDiagram(
                    ratio: model.masterRatioPercent / 100.0,
                    masterCount: model.masterCount
                )
                .frame(width: 148, height: 94)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("默认主区宽度")
                            .font(.system(size: 12.5))
                            .frame(width: 86, alignment: .leading)
                        Slider(value: $model.masterRatioPercent, in: 20...80)
                            .onChange(of: model.masterRatioPercent) { _, newVal in
                                let rounded = newVal.rounded()
                                if abs(newVal - rounded) > 0.001 {
                                    model.masterRatioPercent = rounded
                                }
                                model.notifyChanged()
                            }
                        Text("\(Int(model.masterRatioPercent.rounded()))%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 38, alignment: .trailing)
                    }

                    HStack {
                        Text("主区窗口数量")
                            .font(.system(size: 12.5))
                            .frame(width: 86, alignment: .leading)
                        Stepper(value: $model.masterCount, in: 1...20) {
                            Text("\(model.masterCount) 个")
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        }
                        .onChange(of: model.masterCount) { _, _ in
                            model.notifyChanged(immediate: true)
                        }
                        Spacer()
                    }

                    HStack {
                        Text("按键调节步长")
                            .font(.system(size: 12.5))
                            .frame(width: 86, alignment: .leading)
                        Picker("", selection: Binding(
                            get: {
                                let v = model.ratioStepPercent
                                for preset in [2.0, 3.0, 5.0, 10.0] where abs(v - preset) < 0.15 {
                                    return preset
                                }
                                return v
                            },
                            set: { newVal in
                                model.ratioStepPercent = newVal
                                model.notifyChanged(immediate: true)
                            }
                        )) {
                            Text("2%").tag(2.0)
                            Text("3%").tag(3.0)
                            Text("5%").tag(5.0)
                            Text("10%").tag(10.0)
                            if ![2.0, 3.0, 5.0, 10.0].contains(where: { abs($0 - model.ratioStepPercent) < 0.15 }) {
                                Text(String(format: "%.1f%%", model.ratioStepPercent)).tag(model.ratioStepPercent)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 210)
                        Spacer()
                    }
                }
            }
        }
    }
}

private struct ModifierKeyButton: View {
    let symbol: String
    let name: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(name)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(action)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TilingPreviewDiagram: View {
    let ratio: Double
    let masterCount: Int

    var body: some View {
        GeometryReader { geo in
            let pad: CGFloat = 6
            let gap: CGFloat = 4
            let innerW = geo.size.width - pad * 2
            let innerH = geo.size.height - pad * 2
            let masterW = max(24, (innerW - gap) * CGFloat(ratio))
            let stackW = max(20, innerW - gap - masterW)
            let mRows = min(3, max(1, masterCount))
            let mRowH = (innerH - gap * CGFloat(mRows - 1)) / CGFloat(mRows)
            let sRows = 2
            let sRowH = (innerH - gap) / CGFloat(sRows)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

                ForEach(0..<mRows, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(i == 0 ? 0.85 : 0.55))
                        .frame(width: masterW, height: mRowH)
                        .overlay(
                            Text(i == 0 ? "主区" : "")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .offset(x: pad, y: pad + CGFloat(i) * (mRowH + gap))
                }

                ForEach(0..<sRows, id: \.self) { j in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: stackW, height: sRowH)
                        .offset(x: pad + masterW + gap, y: pad + CGFloat(j) * (sRowH + gap))
                }
            }
        }
    }
}

private struct AppRulesView: View {
    @ObservedObject var model: SettingsViewModel

    private var assignCandidates: [(name: String, bundleID: String)] {
        let ownBundle = Bundle.main.bundleIdentifier ?? "local.talus.windowmanager"
        var seen: Set<String> = Set(model.appWorkspaces.keys)
        seen.insert(ownBundle)
        var list: [(String, String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            let name = app.localizedName ?? bid
            list.append((name, bid))
        }
        return list.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private var runningCandidates: [(name: String, bundleID: String)] {
        let ownBundle = Bundle.main.bundleIdentifier ?? "local.talus.windowmanager"
        var seen: Set<String> = Set(model.ignoreApps)
        seen.insert(ownBundle)
        var list: [(String, String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            let name = app.localizedName ?? bid
            list.append((name, bid))
        }
        return list.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        SectionCard(
            title: "应用自动归入工作区",
            subtitle: model.workspaceMode == "virtual"
                ? "指定应用启动或新开窗口时，自动扔进目标工作区，焦点留在当前工作区（XMonad doShift）。"
                : "当前处于 macOS 原生空间模式；开启「Talus 虚拟工作区」后以下自动归位规则自动生效。"
        ) {
            if model.workspaceMode != "virtual" {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("自动归位仅在虚拟工作区模式下生效。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("开启虚拟工作区") {
                        model.workspaceMode = "virtual"
                        model.notifyChanged(immediate: true)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
            }

            HStack(spacing: 8) {
                Menu {
                    let candidates = assignCandidates
                    if candidates.isEmpty {
                        Text("当前没有其他可添加的运行中应用")
                    } else {
                        ForEach(candidates, id: \.bundleID) { item in
                            Button("\(item.name)  (\(item.bundleID))") {
                                model.setAppWorkspace(item.bundleID, workspaceOneBased: min(2, max(1, model.workspaceCount)))
                            }
                        }
                    }
                } label: {
                    Label("从运行中的应用添加", systemImage: "plus.circle.fill")
                }
                .fixedSize()

                Button {
                    pickAssignedApplicationBundle()
                } label: {
                    Label("浏览应用程序…", systemImage: "folder")
                }

                Spacer()

                Button(model.showManualAssignInput ? "收起手动输入" : "手动输入 ID") {
                    model.showManualAssignInput.toggle()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            if model.showManualAssignInput {
                HStack(spacing: 8) {
                    TextField("例如 com.apple.Safari", text: $model.manualAssignBundleID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { submitManualAssign() }
                    Picker("", selection: $model.manualAssignWorkspace) {
                        ForEach(1...max(1, model.workspaceCount), id: \.self) { n in
                            Text(model.workspaceOptionTitle(oneBased: n)).tag(n)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 148)
                    Button("添加") { submitManualAssign() }
                        .disabled(model.manualAssignBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            let sortedKeys = model.appWorkspaces.keys.sorted()
            if sortedKeys.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                    Text("尚未设置自动归位规则 — 添加后（如浏览器 → 工作区 2、微信 → 工作区 4），新窗口会自动落入目标工作区。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedKeys.enumerated()), id: \.element) { idx, bundleID in
                        let info = resolveAppDisplay(bundleID: bundleID)
                        let target = model.appWorkspaces[bundleID] ?? .index(1)
                        HStack(spacing: 10) {
                            Image(nsImage: info.icon)
                                .resizable()
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                if info.name != info.bundleID {
                                    Text(info.bundleID)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Picker("", selection: Binding(
                                get: { model.resolvedOneBasedWorkspace(for: target) },
                                set: { newWS in model.setAppWorkspace(bundleID, workspaceOneBased: newWS) }
                            )) {
                                ForEach(1...max(1, model.workspaceCount), id: \.self) { n in
                                    Text(model.workspaceOptionTitle(oneBased: n)).tag(n)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 152)

                            Button {
                                model.removeAppWorkspace(bundleID)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("移除规则")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        if idx + 1 < sortedKeys.count {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }
        }

        SectionCard(
            title: "不参与平铺的应用",
            subtitle: "选中的应用窗口将保持自由尺寸与位置，且在切换工作区时保持常驻不被隐藏。"
        ) {
            HStack(spacing: 8) {
                Menu {
                    let candidates = runningCandidates
                    if candidates.isEmpty {
                        Text("当前没有其他可添加的运行中应用")
                    } else {
                        ForEach(candidates, id: \.bundleID) { item in
                            Button("\(item.name)  (\(item.bundleID))") {
                                model.addIgnoredApp(item.bundleID)
                            }
                        }
                    }
                } label: {
                    Label("从运行中的应用添加", systemImage: "plus.circle.fill")
                }
                .fixedSize()

                Button {
                    pickApplicationBundle()
                } label: {
                    Label("浏览应用程序…", systemImage: "folder")
                }

                Spacer()

                Button(model.showManualBundleInput ? "收起手动输入" : "手动输入 ID") {
                    model.showManualBundleInput.toggle()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            if model.showManualBundleInput {
                HStack(spacing: 8) {
                    TextField("例如 com.apple.systempreferences", text: $model.manualBundleID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { submitManualBundle() }
                    Button("添加") { submitManualBundle() }
                        .disabled(model.manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if model.ignoreApps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("尚未添加忽略应用")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("所有可调整尺寸的标准窗口都会自动参与平铺；对话框已自动跳过，固定尺寸窗口在虚拟工作区中以原尺寸浮动跟随。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.ignoreApps.enumerated()), id: \.element) { idx, bundleID in
                        let info = resolveAppDisplay(bundleID: bundleID)
                        HStack(spacing: 10) {
                            Image(nsImage: info.icon)
                                .resizable()
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                if info.name != info.bundleID {
                                    Text(info.bundleID)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Button {
                                model.removeIgnoredApp(bundleID)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("移除")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        if idx + 1 < model.ignoreApps.count {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }
        }
    }

    private func submitManualAssign() {
        let trimmed = model.manualAssignBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.setAppWorkspace(trimmed, workspaceOneBased: model.manualAssignWorkspace)
        model.manualAssignBundleID = ""
    }

    private func pickAssignedApplicationBundle() {
        let panel = NSOpenPanel()
        panel.title = "选择自动归入工作区的应用程序"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            let defaultTarget = min(2, max(1, model.workspaceCount))
            for url in panel.urls {
                if let bid = Bundle(url: url)?.bundleIdentifier {
                    model.setAppWorkspace(bid, workspaceOneBased: defaultTarget)
                }
            }
        }
    }

    private func submitManualBundle() {
        let trimmed = model.manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addIgnoredApp(trimmed)
        model.manualBundleID = ""
    }

    private func pickApplicationBundle() {
        let panel = NSOpenPanel()
        panel.title = "选择不参与平铺的应用程序"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let bid = Bundle(url: url)?.bundleIdentifier {
                    model.addIgnoredApp(bid)
                }
            }
        }
    }
}

private struct MenuBarSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    private var installedMonospaceFonts: [String] {
        let candidates = [
            "SFMono-Regular", "Menlo-Regular", "Monaco", "JetBrainsMono-Regular",
            "JetBrainsMonoNF-Regular", "FiraCode-Regular", "Hack-Regular", "Iosevka"
        ]
        return candidates.filter { NSFont(name: $0, size: 12) != nil }
    }

    var body: some View {
        // 1. Live actual renderer preview
        SectionCard(
            title: "实时菜单栏预览",
            subtitle: model.workspaceMode == "virtual"
                ? "使用 Talus 实际矢量渲染器绘制（深色编号为有窗口的工作区，浅淡编号为空闲工作区）"
                : "使用 Talus 实际矢量渲染器绘制（示例含 3 个桌面空间，第 3 个为全屏空间 •）"
        ) {
            VStack(spacing: 8) {
                MenuBarPreviewPill(label: "深色", dark: true, image: model.previewImage(dark: true))
                MenuBarPreviewPill(label: "浅色", dark: false, image: model.previewImage(dark: false))
            }
        }

        // 2. Core Menu Bar controls
        SectionCard(title: "显示内容与工作区名称") {
            Toggle("显示 Talus 三格状态栏图标", isOn: $model.statusShowIcon)
                .font(.system(size: 12.5))
                .onChange(of: model.statusShowIcon) { _, _ in
                    model.notifyChanged(immediate: true)
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("工作区名称")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("（按顺序对应桌面 1、2、3…，留空则显示数字编号）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(Array(model.spaceLabels.enumerated()), id: \.offset) { idx, label in
                        HStack(spacing: 4) {
                            Text("\(idx + 1):")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(label)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Button {
                                model.spaceLabels.remove(at: idx)
                                model.notifyChanged(immediate: true)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    }

                    if model.spaceLabels.count < 12 {
                        HStack(spacing: 4) {
                            TextField("桌面 \(model.spaceLabels.count + 1) 名称，回车添加", text: $model.newSpaceLabel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .frame(width: 158)
                                .onSubmit { appendSpaceLabel() }
                            if !model.newSpaceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button("添加") { appendSpaceLabel() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("内容模式")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Picker("", selection: $model.statusMode) {
                    ForEach(StatusModeChoice.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                .onChange(of: model.statusMode) { _, _ in
                    model.notifyChanged(immediate: true)
                }
            }

            switch model.statusMode {
            case .simple:
                Text("自动显示工作区列表与当前布局（Tall / Mirror / Full），无需编写模板语法。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

            case .template:
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("状态栏模板")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Menu("套用示例预设") {
                            Button("纯图标工作区（SF Symbols）") { model.applyTemplatePreset("icons") }
                            Button("青绿圆角胶囊") { model.applyTemplatePreset("compact") }
                            Button("xmobar 下划线指示") { model.applyTemplatePreset("underline") }
                            Button("磨砂分组胶囊") { model.applyTemplatePreset("pills") }
                            Button("暖金分段胶囊") { model.applyTemplatePreset("powerline") }
                            Button("工作区 + 布局 + 时钟") { model.applyTemplatePreset("clock") }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }

                    TextField("%spaces%  <fc=#89CFC2>%layout%</fc>", text: $model.customTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: model.customTemplate) { _, _ in model.notifyChanged() }

                    FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        Text("插入变量:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                        ForEach([
                            ("%spaces%", "工作区"),
                            ("%layout%", "布局"),
                            ("%title%", "窗口标题"),
                            ("%count%", "窗口数"),
                        ], id: \.0) { token, desc in
                            Button("\(desc) \(token)") {
                                model.customTemplate += (model.customTemplate.isEmpty ? "" : "  ") + token
                                model.notifyChanged(immediate: true)
                            }
                            .controlSize(.mini)
                        }
                    }

                    DisclosureGroup("工作区高亮样式与字体", isExpanded: $model.showWorkspaceStyleSection) {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledMonoField(label: "当前工作区", text: $model.workspaceCurrent) {
                                model.notifyChanged()
                            }
                            LabeledMonoField(label: "其他工作区", text: $model.workspaceOther) {
                                model.notifyChanged()
                            }
                            HStack(spacing: 10) {
                                Text("字体与字号")
                                    .font(.system(size: 12))
                                    .frame(width: 72, alignment: .leading)
                                TextField("系统默认等宽数字字体", text: $model.primaryFont)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .onChange(of: model.primaryFont) { _, _ in model.notifyChanged() }
                                Menu("选择已装字体") {
                                    Button("系统默认") {
                                        model.primaryFont = ""
                                        model.notifyChanged(immediate: true)
                                    }
                                    Divider()
                                    ForEach(installedMonospaceFonts, id: \.self) { f in
                                        Button(f) {
                                            model.primaryFont = f
                                            model.notifyChanged(immediate: true)
                                        }
                                    }
                                }
                                .controlSize(.small)
                                .fixedSize()

                                Stepper(value: $model.statusFontSize, in: 8...14, step: 0.5) {
                                    Text(String(format: "%.1f pt", model.statusFontSize))
                                        .font(.system(size: 11.5, design: .monospaced))
                                }
                                .onChange(of: model.statusFontSize) { _, _ in model.notifyChanged(immediate: true) }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.system(size: 12, weight: .medium))

                    DisclosureGroup(
                        model.commands.isEmpty ? "外部命令数据源" : "外部命令数据源（已配置 \(model.commands.count) 项）",
                        isExpanded: $model.showCommandsSection
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.commands.indices), id: \.self) { idx in
                                CommandRowEditor(
                                    command: Binding(
                                        get: { model.commands[idx] },
                                        set: { newCmd in
                                            model.commands[idx] = newCmd
                                            model.notifyChanged()
                                        }
                                    ),
                                    onDelete: {
                                        model.commands.remove(at: idx)
                                        model.notifyChanged(immediate: true)
                                    }
                                )
                            }

                            Button {
                                var idx = 1
                                var candidateName = "clock"
                                while model.commands.contains(where: { $0.name == candidateName }) {
                                    idx += 1
                                    candidateName = "cmd\(idx)"
                                }
                                model.commands.append(
                                    StatusCommand(name: candidateName, executable: "/bin/date", arguments: ["+%H:%M"], interval: 30, timeout: 2)
                                )
                                if !model.customTemplate.contains("%\(candidateName)%") {
                                    model.customTemplate += "  %\(candidateName)%"
                                }
                                model.notifyChanged(immediate: true)
                            } label: {
                                Label("添加命令数据源", systemImage: "plus")
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 8)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .padding(.top, 4)

            case .script:
                VStack(alignment: .leading, spacing: 10) {
                    Text("由你编写的程序（如 Python / Haskell / 可执行脚本）读取环境变量 TALUS_STATUS_JSON 并直接输出整条状态栏字符串。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text("程序路径")
                            .font(.system(size: 12))
                            .frame(width: 64, alignment: .leading)
                        TextField("/usr/bin/python3 或自定义编译产物路径", text: $model.scriptExecutable)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: model.scriptExecutable) { _, _ in model.notifyChanged() }
                        Button("选择…") {
                            if let path = pickExecutableFile() {
                                model.scriptExecutable = path
                                model.notifyChanged(immediate: true)
                            }
                        }
                        .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Text("启动参数")
                            .font(.system(size: 12))
                            .frame(width: 64, alignment: .leading)
                        TextField("可选，例如 /Users/you/status.py（空格分隔）", text: $model.scriptArgumentsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: model.scriptArgumentsText) { _, _ in model.notifyChanged() }
                    }

                    HStack(spacing: 18) {
                        Toggle("解析 <fc> / <fn> 颜色与字体标记", isOn: $model.scriptMarkup)
                            .font(.system(size: 12))
                            .onChange(of: model.scriptMarkup) { _, _ in model.notifyChanged(immediate: true) }
                        Toggle("空间或焦点变化时立即刷新", isOn: $model.scriptOnChange)
                            .font(.system(size: 12))
                            .onChange(of: model.scriptOnChange) { _, _ in model.notifyChanged(immediate: true) }
                    }

                    HStack(spacing: 12) {
                        Text("定时间隔")
                            .font(.system(size: 12))
                            .frame(width: 64, alignment: .leading)
                        Stepper(value: $model.scriptInterval, in: 1...3600, step: 5) {
                            Text("\(Int(model.scriptInterval)) 秒")
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .onChange(of: model.scriptInterval) { _, _ in model.notifyChanged(immediate: true) }
                        Spacer()
                    }
                }
                .padding(.top, 4)
            }
            Divider()

            DisclosureGroup("外部状态文件读写（高级可选）", isExpanded: $model.showFileIOSection) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledMonoField(label: "读取文本 (%custom%)", placeholder: "可选，供 %custom% 读取的纯文本路径", text: $model.statusTextFile) {
                        model.notifyChanged()
                    }
                    LabeledMonoField(label: "导出状态 JSON", placeholder: "可选，将当前工作区/窗口标题写入该路径", text: $model.statusStateFile) {
                        model.notifyChanged()
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    private func appendSpaceLabel() {
        let trimmed = String(model.newSpaceLabel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
        guard !trimmed.isEmpty, model.spaceLabels.count < 32 else { return }
        model.spaceLabels.append(trimmed)
        model.newSpaceLabel = ""
        model.notifyChanged(immediate: true)
    }
}

private struct MenuBarPreviewPill: View {
    let label: String
    let dark: Bool
    let image: NSImage

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Image(nsImage: image)
                        .interpolation(.high)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
            }
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.92, green: 0.93, blue: 0.95))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

private struct LabeledMonoField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onChange(of: text) { _, _ in onEdit() }
        }
    }
}

private struct CommandRowEditor: View {
    @Binding var command: StatusCommand
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("名称", text: $command.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 84)
                Text("%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)

                TextField("/bin/date", text: $command.executable)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button("浏览…") {
                    if let chosen = pickExecutableFile() {
                        command.executable = chosen
                    }
                }
                .controlSize(.small)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除命令")
            }

            HStack(spacing: 12) {
                TextField("参数（空格分隔，如 +%H:%M）", text: Binding(
                    get: { (command.arguments ?? []).joined(separator: " ") },
                    set: { text in
                        let parsed = parseArgumentLine(text)
                        command.arguments = parsed.isEmpty ? nil : parsed
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))

                Stepper(value: Binding(
                    get: { command.interval ?? 10 },
                    set: { command.interval = $0 }
                ), in: 1...3600, step: 5) {
                    Text("\(Int(command.interval ?? 10))s")
                        .font(.system(size: 11.5, design: .monospaced))
                }

                Toggle("颜色标记", isOn: Binding(
                    get: { command.markup ?? false },
                    set: { command.markup = $0 ? true : nil }
                ))
                .font(.system(size: 11.5))

                Toggle("变化即跑", isOn: Binding(
                    get: { command.onChange ?? false },
                    set: { command.onChange = $0 ? true : nil }
                ))
                .font(.system(size: 11.5))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private func pickExecutableFile() -> String? {
    let panel = NSOpenPanel()
    panel.title = "选择可执行文件或脚本"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.showsHiddenFiles = true
    return panel.runModal() == .OK ? panel.url?.path : nil
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let viewModel: SettingsViewModel
    var onClose: (() -> Void)?

    init(config: Configuration, resolution: ConfigResolution, onApply: @escaping (Configuration, URL) -> Void) {
        self.viewModel = SettingsViewModel(config: config, resolution: resolution)
        super.init()
        self.viewModel.onConfigurationApplied = onApply
    }

    func show() {
        ensureEditMenuInstalled()
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsRootView(model: viewModel))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Talus 设置"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.collectionBehavior = [.moveToActiveSpace]
        win.minSize = NSSize(width: 600, height: 560)
        win.setContentSize(NSSize(width: 640, height: 660))
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    var nsWindow: NSWindow? { window }

    func windowWillClose(_ notification: Notification) {
        viewModel.flushPendingSave()
        onClose?()
    }

    /// Ensures standard keyboard shortcuts (⌘C/⌘V/⌘X/⌘A/⌘Z/⌘W) work inside text fields of an LSUIElement menu-bar app.
    private func ensureEditMenuInstalled() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appSubmenu = NSMenu()
        appSubmenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appSubmenu.addItem(.separator())
        appSubmenu.addItem(withTitle: "退出 Talus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appSubmenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
