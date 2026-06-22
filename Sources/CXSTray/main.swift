import AppKit
import Darwin
import Foundation

struct AccountUsage {
    let account: String
    let email: String
    let plan: String
    let fiveHourLeft: String
    let weekLeft: String
    let fiveHourReset: String
    let weekReset: String
    let source: String
    var isDefault: Bool = false
}

struct CommandResult {
    let output: String
    let error: String
    let status: Int32
}

extension FileHandle {
    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }
}

enum CommandRunner {
    static func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/Applications/Codex.app/Contents/Resources:/usr/bin:/bin:/usr/sbin:/sbin"
        ]) { _, trayValue in trayValue }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            throw NSError(
                domain: "CXSTray.CommandRunner",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "\(arguments.joined(separator: " ")) timed out"]
            )
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(output: output, error: error, status: process.terminationStatus)
    }
}

enum CXSParser {
    static func parseUsage(_ text: String) -> [AccountUsage] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first(where: { $0.contains("Account") && $0.contains("Week left") }) else {
            return []
        }

        let modernColumns = ["Account", "Email", "Plan", "5h left", "Week left", "5h reset", "Week reset", "Source"]
        let legacyColumns = ["Account", "Email", "Plan", "5h left", "Week left", "Reset", "Source"]
        let columns = modernColumns.allSatisfy { header.contains($0) } ? modernColumns : legacyColumns
        let starts = columns.compactMap { column -> (String, String.Index)? in
            guard let range = header.range(of: column) else { return nil }
            return (column, range.lowerBound)
        }

        guard starts.count == columns.count else { return [] }

        return lines.drop(while: { $0 != header }).dropFirst().compactMap { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let values = columns.enumerated().map { index, column in
                let start = starts[index].1
                let end = index + 1 < starts.count ? starts[index + 1].1 : line.endIndex
                return slice(line, fromHeaderIndex: start, toHeaderIndex: end, header: header)
                    .trimmingCharacters(in: .whitespaces)
            }

            guard values.count == columns.count, !values[0].isEmpty else { return nil }

            if columns == modernColumns {
                return AccountUsage(
                    account: values[0],
                    email: values[1],
                    plan: values[2],
                    fiveHourLeft: values[3],
                    weekLeft: values[4],
                    fiveHourReset: values[5],
                    weekReset: values[6],
                    source: values[7]
                )
            } else {
                return AccountUsage(
                    account: values[0],
                    email: values[1],
                    plan: values[2],
                    fiveHourLeft: values[3],
                    weekLeft: values[4],
                    fiveHourReset: values[5],
                    weekReset: values[5],
                    source: values[6]
                )
            }
        }
    }

    static func parseDefaultAccount(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first(where: { $0.contains("Account") && $0.contains("Default") }) else {
            return nil
        }

        guard
            let accountStart = header.range(of: "Account")?.lowerBound,
            let defaultStart = header.range(of: "Default")?.lowerBound,
            let lastUsedStart = header.range(of: "Last Used")?.lowerBound
        else {
            return nil
        }

        return lines.drop(while: { $0 != header }).dropFirst().compactMap { line in
            let account = slice(line, fromHeaderIndex: accountStart, toHeaderIndex: defaultStart, header: header)
                .trimmingCharacters(in: .whitespaces)
            let isDefault = slice(line, fromHeaderIndex: defaultStart, toHeaderIndex: lastUsedStart, header: header)
                .trimmingCharacters(in: .whitespaces)
            return isDefault == "yes" ? account : nil
        }.first
    }

    private static func slice(_ line: String, fromHeaderIndex start: String.Index, toHeaderIndex end: String.Index, header: String) -> String {
        let startOffset = header.distance(from: header.startIndex, to: start)
        let endOffset = header.distance(from: header.startIndex, to: end)
        let lineStart = line.index(line.startIndex, offsetBy: min(startOffset, line.count))
        let lineEnd = line.index(line.startIndex, offsetBy: min(endOffset, line.count))
        return String(line[lineStart..<lineEnd])
    }
}

final class CXSService: @unchecked Sendable {
    func loadAccounts() throws -> [AccountUsage] {
        let usage = try CommandRunner.run(["cxs", "usage"], timeout: 45)
        guard usage.status == 0 else {
            throw commandError("cxs usage", usage)
        }

        let list = try CommandRunner.run(["cxs", "list"], timeout: 10)
        let defaultAccount = list.status == 0 ? CXSParser.parseDefaultAccount(list.output) : nil

        return CXSParser.parseUsage(usage.output).map { account in
            var copy = account
            copy.isDefault = account.account == defaultAccount
            return copy
        }
    }

    func sync(account: String) throws {
        let result = try CommandRunner.run(["cxs", "sync", account], timeout: 30)
        guard result.status == 0 else {
            throw commandError("cxs sync \(account)", result)
        }
    }

    func ensureOCXIfAvailable() throws -> Bool {
        let available = try CommandRunner.run(["sh", "-c", "command -v ocx >/dev/null 2>&1"], timeout: 5)
        guard available.status == 0 else { return false }

        let result = try CommandRunner.run(["ocx", "ensure"], timeout: 30)
        guard result.status == 0 else {
            throw commandError("ocx ensure", result)
        }
        return true
    }

    private func commandError(_ command: String, _ result: CommandResult) -> NSError {
        let detail = [result.error, result.output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "exit \(result.status)"
        return NSError(
            domain: "CXSTray.CXSService",
            code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: "\(command) failed: \(detail)"]
        )
    }
}

enum AppSettings {
    static var codexAppName: String {
        ProcessInfo.processInfo.environment["CXS_TRAY_CODEX_APP_NAME"]
            ?? UserDefaults(suiteName: "com.cxs.tray")?.string(forKey: "CodexAppName")
            ?? UserDefaults.standard.string(forKey: "CodexAppName")
            ?? "Codex"
    }
}

final class CodexAppController: @unchecked Sendable {
    private let appName: String

    init(appName: String) {
        self.appName = appName
    }

    func quitGracefully(timeout: TimeInterval = 8) {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == appName || $0.bundleIdentifier?.localizedCaseInsensitiveContains("codex") == true
        }

        guard !runningApps.isEmpty else { return }

        runningApps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while runningApps.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }

    func relaunch() {
        do {
            _ = try CommandRunner.run(["open", "-a", appName], timeout: 10)
        } catch {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/\(appName).app"), configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

enum CLI {
    static func runIfRequested(arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst())
        guard !args.isEmpty else { return nil }

        if args == ["--help"] || args == ["-h"] || args == ["help"] {
            printUsage()
            return 0
        }

        guard args.count == 2, ["switch", "sync"].contains(args[0]) else {
            printUsage(to: FileHandle.standardError)
            return 64
        }

        return switchAccount(args[1])
    }

    private static func switchAccount(_ account: String) -> Int32 {
        let appName = AppSettings.codexAppName
        let codex = CodexAppController(appName: appName)
        let service = CXSService()

        do {
            print("Quitting \(appName)...")
            codex.quitGracefully()
            print("Syncing \(account)...")
            try service.sync(account: account)
            if try service.ensureOCXIfAvailable() {
                print("Ensured ocx")
            }
            print("Launching \(appName)...")
            codex.relaunch()
            print("Synced \(account)")
            return 0
        } catch {
            FileHandle.standardError.write("CXSTray: \(error.localizedDescription)\n")
            return 1
        }
    }

    private static func printUsage(to handle: FileHandle = .standardOutput) {
        handle.write("""
        Usage:
          CXSTray                 Run the menu bar app
          CXSTray switch <account> Quit Codex, run cxs sync <account>, run ocx ensure if available, relaunch Codex

        Environment:
          CXS_TRAY_CODEX_APP_NAME Override the Codex app name to relaunch

        """)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let service = CXSService()
    private var accounts: [AccountUsage] = []
    private var refreshTimer: Timer?
    private var isBusy = false

    private var codexAppName: String {
        AppSettings.codexAppName
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "CXS"
        statusItem.button?.toolTip = "CXS account usage"
        statusItem.menu = menu

        rebuildMenu(status: "Loading...")
        refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func refresh() {
        guard !isBusy else { return }
        isBusy = true
        statusItem.button?.title = "CXS..."
        rebuildMenu(status: "Refreshing...")

        let service = service
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try service.loadAccounts() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let accounts):
                    self.accounts = accounts
                    self.statusItem.button?.title = self.buttonTitle(for: accounts)
                    self.rebuildMenu()
                case .failure(let error):
                    self.statusItem.button?.title = "CXS!"
                    self.rebuildMenu(error: error.localizedDescription)
                }
            }
        }
    }

    private func sync(_ account: AccountUsage) {
        guard !isBusy else { return }
        isBusy = true
        statusItem.button?.title = "Sync..."
        rebuildMenu(status: "Switching to \(account.account)...")

        let appName = codexAppName
        let service = service
        let accountName = account.account
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let codex = CodexAppController(appName: appName)
                codex.quitGracefully()
                try service.sync(account: accountName)
                _ = try service.ensureOCXIfAvailable()
                codex.relaunch()
                return try service.loadAccounts()
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let accounts):
                    self.accounts = accounts
                    self.statusItem.button?.title = self.buttonTitle(for: accounts)
                    self.rebuildMenu(status: "Synced \(accountName)")
                case .failure(let error):
                    self.statusItem.button?.title = "CXS!"
                    self.rebuildMenu(error: error.localizedDescription)
                }
            }
        }
    }

    private func rebuildMenu(status: String? = nil, error: String? = nil) {
        menu.removeAllItems()

        if let status {
            let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if let error {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if accounts.isEmpty {
            let empty = NSMenuItem(title: "No accounts loaded", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let columnWidths = menuColumnWidths(for: accounts)
            accounts.forEach { account in
                let title = menuTitle(for: account, widths: columnWidths)
                let item = NSMenuItem(title: title, action: #selector(selectAccount(_:)), keyEquivalent: "")
                item.attributedTitle = menuAttributedTitle(title)
                item.target = self
                item.representedObject = account.account
                item.state = account.isDefault ? .on : .off
                item.isEnabled = !isBusy
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Usage", action: #selector(refreshAction(_:)), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isBusy
        menu.addItem(refreshItem)

        let appNameItem = NSMenuItem(title: "Codex app: \(codexAppName)", action: nil, keyEquivalent: "")
        appNameItem.isEnabled = false
        menu.addItem(appNameItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit CXS Tray", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func buttonTitle(for accounts: [AccountUsage]) -> String {
        if let current = accounts.first(where: \.isDefault) {
            return "CXS \(current.account) \(current.fiveHourLeft)"
        }
        return "CXS"
    }

    private struct MenuColumnWidths {
        let account: Int
        let plan: Int
        let fiveHourLeft: Int
        let fiveHourReset: Int
        let weekLeft: Int
        let weekReset: Int
    }

    private func menuColumnWidths(for accounts: [AccountUsage]) -> MenuColumnWidths {
        MenuColumnWidths(
            account: maxWidth(accounts.map(\.account)),
            plan: maxWidth(accounts.map(\.plan)),
            fiveHourLeft: maxWidth(accounts.map(\.fiveHourLeft)),
            fiveHourReset: maxWidth(accounts.map(\.fiveHourReset)),
            weekLeft: maxWidth(accounts.map(\.weekLeft)),
            weekReset: maxWidth(accounts.map(\.weekReset))
        )
    }

    private func maxWidth(_ values: [String]) -> Int {
        values.map(\.count).max() ?? 0
    }

    private func pad(_ value: String, to width: Int) -> String {
        value.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private func menuTitle(for account: AccountUsage, widths: MenuColumnWidths) -> String {
        let defaultMarker = account.isDefault ? "current" : "sync"
        return [
            pad(account.account, to: widths.account),
            pad(account.plan, to: widths.plan),
            "5h \(pad(account.fiveHourLeft, to: widths.fiveHourLeft)) reset \(pad(account.fiveHourReset, to: widths.fiveHourReset))",
            "week \(pad(account.weekLeft, to: widths.weekLeft)) reset \(pad(account.weekReset, to: widths.weekReset))",
            defaultMarker
        ].joined(separator: "  ")
    }

    private func menuAttributedTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
        )
    }

    @objc private func selectAccount(_ sender: NSMenuItem) {
        guard
            let accountName = sender.representedObject as? String,
            let account = accounts.first(where: { $0.account == accountName })
        else {
            return
        }

        sync(account)
    }

    @objc private func refreshAction(_ sender: NSMenuItem) {
        refresh()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

if let status = CLI.runIfRequested(arguments: CommandLine.arguments) {
    exit(status)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
