import AppKit
import Darwin
import Foundation

struct AccountUsage {
    let account: String
    let plan: String
    let fiveHourLeft: String
    let weekLeft: String
    let fiveHourReset: String
    let weekReset: String
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

        let columns = ["Account", "Email", "Plan", "5h left", "Week left", "5h reset", "Week reset", "Source"]
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

            return AccountUsage(
                account: values[0],
                plan: values[2],
                fiveHourLeft: values[3],
                weekLeft: values[4],
                fiveHourReset: values[5],
                weekReset: values[6]
            )
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
        try repairSessions()

        let usage = try CommandRunner.run(["cxs", "usage"], timeout: 45)
        guard usage.status == 0 else {
            throw commandError(domain: "CXSTray.CXSService", "cxs usage", usage)
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
        let result = try CommandRunner.run(["cxs", "sync", account], timeout: 90)
        guard result.status == 0 else {
            throw commandError(domain: "CXSTray.CXSService", "cxs sync \(account)", result)
        }
    }

    func repairSessions() throws {
        let result = try CommandRunner.run(["cxs", "repair-sessions"], timeout: 90)
        guard result.status == 0 else {
            throw commandError(domain: "CXSTray.CXSService", "cxs repair-sessions", result)
        }
    }

    func ensureOCXIfAvailable() throws -> Bool {
        let available = try CommandRunner.run(["sh", "-c", "command -v ocx >/dev/null 2>&1"], timeout: 5)
        guard available.status == 0 else { return false }

        let result = try CommandRunner.run(["ocx", "ensure"], timeout: 30)
        guard result.status == 0 else {
            throw commandError(domain: "CXSTray.CXSService", "ocx ensure", result)
        }
        return true
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

func commandError(domain: String, _ command: String, _ result: CommandResult) -> NSError {
    let detail = [result.error, result.output]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? "exit \(result.status)"
    return NSError(
        domain: domain,
        code: Int(result.status),
        userInfo: [NSLocalizedDescriptionKey: "\(command) failed: \(detail)"]
    )
}

func switchCodexAccount(_ account: String, appName: String, service: CXSService) throws {
    let codex = CodexAppController(appName: appName)
    try codex.quitGracefully()
    try codex.stopStandaloneAppServers()
    try service.sync(account: account)
    try codex.relaunch()
    _ = try service.ensureOCXIfAvailable()
}

final class CodexAppController: @unchecked Sendable {
    private let appName: String

    init(appName: String) {
        self.appName = appName
    }

    func quitGracefully(timeout: TimeInterval = 8) throws {
        let runningApps = matchingRunningApps()

        guard !runningApps.isEmpty else { return }

        runningApps.forEach { _ = $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if matchingRunningApps().isEmpty {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        let stillRunning = matchingRunningApps()
        guard stillRunning.isEmpty else {
            throw NSError(
                domain: "CXSTray.CodexAppController",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(appName) did not quit within \(Int(timeout))s; account switch aborted. Still running: \(appListDescription(stillRunning))"
                ]
            )
        }
    }

    func stopStandaloneAppServers(timeout: TimeInterval = 5) throws {
        let pids = try standaloneAppServerPIDs()
        guard !pids.isEmpty else { return }

        let killResult = try CommandRunner.run(["kill"] + pids.map(String.init), timeout: 5)
        if killResult.status != 0, !(try standaloneAppServerPIDs()).isEmpty {
            throw commandError(domain: "CXSTray.CodexAppController", "kill standalone codex app-server", killResult)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try standaloneAppServerPIDs().isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let remaining = try standaloneAppServerPIDs()
        guard remaining.isEmpty else {
            throw NSError(
                domain: "CXSTray.CodexAppController",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "standalone codex app-server did not stop within \(Int(timeout))s; account switch aborted. PIDs: \(remaining.map(String.init).joined(separator: ", "))"
                ]
            )
        }
    }

    private func matchingRunningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == appName || $0.bundleIdentifier?.localizedCaseInsensitiveContains("codex") == true
        }
    }

    private func appListDescription(_ apps: [NSRunningApplication]) -> String {
        apps.map { app in
            app.localizedName
                ?? app.bundleIdentifier
                ?? "pid \(app.processIdentifier)"
        }.joined(separator: ", ")
    }

    private func standaloneAppServerPIDs() throws -> [Int32] {
        let result = try CommandRunner.run(["pgrep", "-f", "(^|/)codex app-server --listen unix://"], timeout: 5)
        if result.status == 1 {
            return []
        }
        guard result.status == 0 else {
            throw commandError(domain: "CXSTray.CodexAppController", "pgrep standalone codex app-server", result)
        }

        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func relaunch(timeout: TimeInterval = 8) throws {
        do {
            let result = try CommandRunner.run(["open", "-a", appName], timeout: 10)
            if result.status != 0 {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/\(appName).app"), configuration: NSWorkspace.OpenConfiguration())
            }
        } catch {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/\(appName).app"), configuration: NSWorkspace.OpenConfiguration())
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !matchingRunningApps().isEmpty {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        throw NSError(
            domain: "CXSTray.CodexAppController",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "\(appName) did not launch within \(Int(timeout))s; ocx ensure skipped."
            ]
        )
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
        let service = CXSService()

        do {
            try switchCodexAccount(account, appName: appName, service: service)
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
          CXSTray switch <account> Quit Codex, stop stale app-server, run cxs sync <account>, relaunch Codex, run ocx ensure if available

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
                try codex.quitGracefully()
                try codex.stopStandaloneAppServers()
                try service.sync(account: accountName)
                try codex.relaunch()
                _ = try service.ensureOCXIfAvailable()
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
            let widths = menuColumnWidths(for: accounts)
            accounts.forEach { account in
                let title = menuTitle(for: account, widths: widths)
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

    private func menuColumnWidths(for accounts: [AccountUsage]) -> (account: Int, plan: Int, fiveHourLeft: Int, fiveHourReset: Int, weekLeft: Int, weekReset: Int) {
        (
            account: accounts.map(\.account.count).max() ?? 0,
            plan: accounts.map(\.plan.count).max() ?? 0,
            fiveHourLeft: accounts.map(\.fiveHourLeft.count).max() ?? 0,
            fiveHourReset: accounts.map(\.fiveHourReset.count).max() ?? 0,
            weekLeft: accounts.map(\.weekLeft.count).max() ?? 0,
            weekReset: accounts.map(\.weekReset.count).max() ?? 0
        )
    }

    private func pad(_ value: String, to width: Int) -> String {
        value.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private func menuTitle(for account: AccountUsage, widths: (account: Int, plan: Int, fiveHourLeft: Int, fiveHourReset: Int, weekLeft: Int, weekReset: Int)) -> String {
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

    @objc private func refreshAction(_: NSMenuItem) {
        refresh()
    }

    @objc private func quit(_: NSMenuItem) {
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
