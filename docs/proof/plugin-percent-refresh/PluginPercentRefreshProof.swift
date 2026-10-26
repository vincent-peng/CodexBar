#if DEBUG
import AppKit
import CodexBarCore
import CryptoKit
import Foundation
import SwiftUI

/// Temporary, opt-in native proof. The app's ordinary startup never runs in this mode.
@MainActor
enum PluginPercentRefreshProof {
    private static weak var activeDelegate: Delegate?

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--plugin-percent-refresh-proof") else { return false }
        do {
            let options = try Options()
            let app = NSApplication.shared
            _ = app.setActivationPolicy(.accessory)
            let delegate = try Delegate(options: options)
            self.activeDelegate = delegate
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
            self.activeDelegate = nil
        } catch {
            FileHandle.standardError.write(Data("Plugin percent proof refused: \(error)\n".utf8))
        }
        return true
    }

    /// Integrate at the start of updateIcons, after its released-for-testing guard.
    static func beginIconUpdate(precomputed: String?) {
        self.activeDelegate?.beginIconUpdate(precomputed: precomputed)
    }

    /// Integrate in a defer at the same point as beginIconUpdate.
    static func endIconUpdate() {
        self.activeDelegate?.endIconUpdate()
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    private struct Options {
        let output: URL
        let home: URL
        let baseline: Bool
        let automatic: Bool

        init() throws {
            let arguments = CommandLine.arguments
            let environment = ProcessInfo.processInfo.environment
            guard let index = arguments.firstIndex(of: "--proof-output"),
                  arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/")
            else { throw Failure(description: "Pass an absolute --proof-output directory") }
            self.output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard self.output.path != "/", self.output.pathComponents.count >= 3 else {
                throw Failure(description: "The proof output must be a dedicated contained directory")
            }
            for key in [
                "SWIFT_TESTING_ENABLED", "CODEXBAR_DISABLE_KEYCHAIN_ACCESS",
                "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS", CodexCredentialFileAccess.isolationEnvironmentKey,
                "CODEXBAR_TEST_SESSION_FILE_ISOLATION",
            ] where environment[key] != "1" {
                throw Failure(description: "Missing required isolation flag \(key)=1")
            }
            guard environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
                  environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil
            else { throw Failure(description: "Do not authorize real Keychain or credential fixtures") }
            guard let homePath = environment["HOME"], let fixedHome = environment["CFFIXED_USER_HOME"],
                  homePath.hasPrefix("/"), fixedHome.hasPrefix("/")
            else { throw Failure(description: "Set explicit contained HOME and CFFIXED_USER_HOME") }
            self.home = URL(fileURLWithPath: homePath, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            let resolvedFixedHome = URL(fileURLWithPath: fixedHome, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            let cocoaHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard self.home.path.hasPrefix(self.output.path + "/"),
                  self.home == resolvedFixedHome, self.home == cocoaHome
            else { throw Failure(description: "HOME, CFFIXED_USER_HOME and NSHomeDirectory must match inside output") }
            guard Bundle.main.bundleIdentifier?.hasPrefix("com.steipete.codexbar.proof.") == true else {
                throw Failure(description: "Use a proof bundle copy with identifier com.steipete.codexbar.proof.*")
            }
            guard SettingsStore.isRunningTests else {
                throw Failure(description: "TestProcessSafety must be active before SettingsStore initializes")
            }
            self.baseline = arguments.contains("--proof-baseline")
            self.automatic = arguments.contains("--proof-auto")
        }
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private struct Update {
            let number: Int
            let origin: String
            let beganIn: String
            let signature: String?
        }

        private let options: Options
        private let transport = NoNetworkTransport()
        private let notifier = NoNotifications()
        private let events: FileHandle
        private let launchedAt = Date()
        private var settings: SettingsStore?
        private var defaults: DictionaryDefaults?
        private var store: UsageStore?
        private var controller: StatusItemController?
        private var settingsWindow: NSWindow?
        private var plugin: UserProviderPlugin?
        private var task: Task<Void, Never>?
        private var phase = "setup"
        private var sequence = 0
        private var updateCount = 0
        private var updateStack: [Update] = []
        private var measuredObserverUpdates = 0
        private var measuredOtherUpdates = 0
        private var initialTitle: String?
        private var measuredTitle: String?
        private var initialConfigRevision: Int?
        private var initialBackgroundRevision: Int?
        private var initialDefaultsFingerprint: String?
        private var initialSourceHash: String?
        private var mutationAt: Date?
        private var measurementCompleted = false
        private var forcedControlCompleted = false
        private var stopping = false
        private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

        init(options: Options) throws {
            self.options = options
            try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
            let eventsURL = options.output.appendingPathComponent("events.jsonl")
            guard !FileManager.default.fileExists(atPath: eventsURL.path) else {
                throw Failure(description: "Use a fresh output directory; events.jsonl already exists")
            }
            guard FileManager.default.createFile(
                atPath: eventsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw Failure(description: "Could not create events.jsonl") }
            self.events = try FileHandle(forWritingTo: eventsURL)
            super.init()
        }

        func applicationDidFinishLaunching(_: Notification) {
            do {
                try self.prepareController()
                self.append("controller-created")
                self.task = Task { @MainActor [weak self] in
                    await self?.drive()
                }
            } catch {
                self.append("setup-failed", extra: ["error": String(describing: error)])
                self.writeJSON("failure.json", value: ["error": String(describing: error)])
                self.stop(reason: "setup-failed")
            }
        }

        func applicationWillTerminate(_: Notification) {
            self.task?.cancel()
            self.controller?.prepareForAppShutdown()
            self.settingsWindow?.close()
            try? self.events.close()
        }

        private func prepareController() throws {
            let pluginsDirectory = self.options.output.appendingPathComponent("plugins", isDirectory: true)
            try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
            let source = """
            defineProvider({
              id: "proof-monthly-pool", name: "Synthetic Monthly Pool",
              icon: {monogram: "MP", tint: "#336699"},
              endpoints: ["https://example.invalid"], settings: [],
              fetchUsage() { throw new Error("The native proof must not fetch usage"); }
            });
            """
            try Data(source.utf8).write(to: pluginsDirectory.appendingPathComponent("monthly-pool.js"))
            let loader = UserProviderPluginLoader(
                providersDirectory: pluginsDirectory,
                cacheDirectory: self.options.output.appendingPathComponent("plugin-cache"),
                transport: self.transport,
                storageDirectory: self.options.output.appendingPathComponent("plugin-storage"))
            let results = UserProviderPluginRegistry.refresh(loader: loader)
            guard results.count == 1, let plugin = results.first?.plugin else {
                throw Failure(description: "Synthetic plugin failed to load: \(results.map { $0.error ?? "no error" })")
            }
            self.plugin = plugin
            let configStore = CodexBarConfigStore(fileURL: self.options.output.appendingPathComponent("config.json"))
            try configStore.save(CodexBarConfig(providers:
                UsageProvider.allCases.map { ProviderConfig(id: $0.instanceID, enabled: false) }
                    + [ProviderConfig(id: plugin.manifest.id, enabled: true)]))
            let defaults = DictionaryDefaults(values: [
                "debugDisableKeychainAccess": true,
                "codexbar.legacySecretsMigrationCompleted": true,
                "providerDetectionCompleted": true,
                "openAIWebAccessEnabled": false,
                "debugFileLoggingEnabled": false,
                "launchAtLogin": false,
            ])
            self.defaults = defaults
            let secrets = EmptySecrets()
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: secrets,
                syntheticTokenStore: secrets,
                codexCookieStore: secrets,
                claudeCookieStore: secrets,
                cursorCookieStore: secrets,
                opencodeCookieStore: secrets,
                factoryCookieStore: secrets,
                minimaxCookieStore: secrets,
                minimaxAPITokenStore: secrets,
                kimiTokenStore: secrets,
                augmentCookieStore: secrets,
                ampCookieStore: secrets,
                copilotTokenStore: secrets,
                tokenAccountStore: EmptyTokenAccounts(fileURL: self.options.output.appendingPathComponent("accounts.json")),
                antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                    fileURL: self.options.output.appendingPathComponent("antigravity.json")),
                keychainAccessPolicy: SettingsStoreKeychainAccessPolicy(
                    setDisabled: { _ in }, isExplicitlyDisabled: { true }),
                performInitialProviderDetection: false)
            settings.configFileWatcher?.stop()
            settings.configFileWatcher = nil
            settings.statusChecksEnabled = false
            settings.costUsageEnabled = false
            settings.codexLocalSessionCostLedgerEnabled = false
            settings.accountWidgetsEnabled = false
            settings.agentSessionsEnabled = false
            settings.agentSessionsRemoteEnabled = false
            settings.adaptiveActivityScanConsent = .declined
            settings.stayAwakeEnabled = false
            settings.refreshFrequency = .manual
            settings.mergeIcons = true
            settings.mergeIconsStacked = false
            settings.unifiedIconSource = .currentSelection
            settings.menuBarIconStyle = .iconAndPercent
            settings.usageBarsShowUsed = true
            settings.mergedMenuLastSelectedWasOverview = false
            settings.selectedMenuProvider = plugin.manifest.id
            settings.setMenuBarLayout(
                MenuBarLayout(lines: [[.lanePercent(lane: .tertiary)]]), forInstanceID: plugin.manifest.id)
            self.settings = settings
            let environment = [
                "HOME": self.options.home.path,
                "CFFIXED_USER_HOME": self.options.home.path,
                "CODEX_HOME": self.options.home.appendingPathComponent(".codex").path,
                "XDG_CONFIG_HOME": self.options.home.appendingPathComponent(".config").path,
                "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1",
                "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
                "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
                "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
                "SWIFT_TESTING_ENABLED": "1",
            ]
            let store = UsageStore(
                fetcher: UsageFetcher(environment: environment),
                browserDetection: BrowserDetection(homeDirectory: self.options.home.path, cacheTTL: 0),
                costUsageFetcher: CostUsageFetcher(cacheRoot: self.options.output.appendingPathComponent("cost-cache")),
                settings: settings,
                historicalUsageHistoryStore: HistoricalUsageHistoryStore(
                    fileURL: self.options.output.appendingPathComponent("history.json")),
                planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
                sessionQuotaNotifier: self.notifier,
                startupBehavior: .testing,
                environmentBase: environment,
                pluginApprovalStore: ProviderPluginApprovalStore(
                    fileURL: self.options.output.appendingPathComponent("approvals.json")),
                widgetSnapshotURL: self.options.output.appendingPathComponent("widget.json"),
                cliUsageCacheURL: self.options.output.appendingPathComponent("cli-cache.json"),
                widgetTimelineReloader: {})
            store._test_widgetSnapshotSaveOverride = { _ in }
            store.snapshots[plugin.manifest.id] = self.snapshot(monthly: 76.9)
            self.store = store
            self.controller = StatusItemController(
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: .system,
                menuCardRenderingEnabled: false,
                menuRefreshEnabled: false,
                observeProviderConfigNotifications: false)
            self.showSettingsWindow(settings: settings, plugin: plugin)
        }

        private func showSettingsWindow(settings: SettingsStore, plugin: UserProviderPlugin) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 310),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CodexBar - Synthetic Monthly Selection"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProofSettingsView(
                settings: settings,
                instanceID: plugin.manifest.id,
                snapshot: self.snapshot(monthly: 76.9))
                .environment(\.locale, Locale(identifier: "en")))
            self.settingsWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        private func snapshot(monthly: Double) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                tertiary: RateWindow(
                    usedPercent: monthly, windowMinutes: 43200, resetsAt: nil, resetDescription: nil, title: "Monthly"),
                updatedAt: self.fixedDate)
        }

        private func drive() async {
            do {
                try await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self.phase = "ready"
                self.initialTitle = self.controller?.statusItem.button?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                self.initialConfigRevision = self.settings?.configRevision
                self.initialBackgroundRevision = self.settings?.backgroundWorkSettingsRevision
                self.initialDefaultsFingerprint = self.defaultsFingerprint()
                self.initialSourceHash = self.plugin?.sourceHash
                self.append("ready")
                self.writeJSON("ready.json", value: self.state())
                let readyAt = Date()
                while !Task.isCancelled, Date().timeIntervalSince(self.launchedAt) < 300 {
                    if self.commandExists("done") {
                        self.stop(reason: "done-file")
                        return
                    }
                    if self.mutationAt == nil,
                       self.commandExists("mutate") ||
                       (self.options.automatic && Date().timeIntervalSince(readyAt) >= 5)
                    {
                        self.mutateOnlySnapshot()
                    }
                    if let mutationAt = self.mutationAt, !self.measurementCompleted,
                       Date().timeIntervalSince(mutationAt) >= 3
                    {
                        self.completeMeasurement()
                    }
                    if self.measurementCompleted, self.options.baseline, !self.forcedControlCompleted,
                       self.commandExists("force")
                    {
                        self.forceRedrawControl()
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }
                self.stop(reason: "300-second-deadline")
            } catch {
                guard !Task.isCancelled else { return }
                self.append("drive-failed", extra: ["error": String(describing: error)])
                self.stop(reason: "drive-failed")
            }
        }

        private func mutateOnlySnapshot() {
            guard let store, let plugin else { return }
            self.phase = "measured"
            self.measuredObserverUpdates = 0
            self.measuredOtherUpdates = 0
            self.append("snapshot-mutation-before")
            self.mutationAt = Date()
            store.snapshots[plugin.manifest.id] = self.snapshot(monthly: 80)
            self.append("snapshot-mutation-after-assignment")
        }

        private func completeMeasurement() {
            self.measuredTitle = self.controller?.statusItem.button?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.measurementCompleted = true
            self.phase = "measured-complete"
            self.append("measurement-complete")
            self.writeJSON("measured.json", value: self.state())
        }

        private func forceRedrawControl() {
            self.phase = "forced-redraw-control"
            self.append("forced-control-before")
            // This optional negative-control step starts only after measured.json is saved.
            self.controller?.updateIcons()
            self.forcedControlCompleted = true
            self.append("forced-control-after")
            self.writeJSON("forced-control.json", value: self.state())
        }

        func beginIconUpdate(precomputed: String?) {
            self.updateCount += 1
            let origin = precomputed == nil ? "other" : "store-observer"
            if self.phase == "measured" {
                if precomputed == nil {
                    self.measuredOtherUpdates += 1
                } else {
                    self.measuredObserverUpdates += 1
                }
            }
            let update = Update(
                number: self.updateCount, origin: origin, beganIn: self.phase, signature: precomputed)
            self.updateStack.append(update)
            self.append("icon-update-begin", extra: self.updateFields(update))
        }

        func endIconUpdate() {
            guard let update = self.updateStack.popLast() else {
                self.append("unmatched-icon-update-end")
                return
            }
            self.append("icon-update-end", extra: self.updateFields(update))
        }

        private func updateFields(_ update: Update) -> [String: Any] {
            [
                "updateNumber": update.number,
                "origin": update.origin,
                "updateBeganIn": update.beganIn,
                "precomputedSignature": update.signature as Any? ?? NSNull(),
            ]
        }

        private func commandExists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: self.options.output.appendingPathComponent(name).path)
        }

        private func state() -> [String: Any] {
            let button = self.controller?.statusItem.button
            let snapshot = self.plugin.flatMap { self.store?.snapshots[$0.manifest.id] }
            let settingsUnchanged = self.settings?.configRevision == self.initialConfigRevision
                && self.settings?.backgroundWorkSettingsRevision == self.initialBackgroundRevision
                && self.defaultsFingerprint() == self.initialDefaultsFingerprint
                && self.plugin?.sourceHash == self.initialSourceHash
            let expectedMeasuredTitle = self.options.baseline ? "77%" : "80%"
            var value: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "elapsedSeconds": Date().timeIntervalSince(self.launchedAt),
                "phase": self.phase,
                "baseline": self.options.baseline,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "executable": Bundle.main.executableURL?.path as Any? ?? NSNull(),
                "bundleIdentifier": Bundle.main.bundleIdentifier as Any? ?? NSNull(),
                "gitCommit": Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as Any? ?? NSNull(),
                "buildTimestamp": Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as Any? ?? NSNull(),
                "output": self.options.output.path,
                "home": self.options.home.path,
                "buttonTitle": button?.title as Any? ?? NSNull(),
                "buttonAttributedTitle": button?.attributedTitle.string as Any? ?? NSNull(),
                "buttonHasImage": button?.image != nil,
                "initialTitle": self.initialTitle as Any? ?? NSNull(),
                "measuredTitle": self.measuredTitle as Any? ?? NSNull(),
                "primaryUsedPercent": snapshot?.primary?.usedPercent as Any? ?? NSNull(),
                "weeklyUsedPercent": snapshot?.secondary?.usedPercent as Any? ?? NSNull(),
                "monthlyUsedPercent": snapshot?.tertiary?.usedPercent as Any? ?? NSNull(),
                "snapshotUpdatedAt": snapshot?.updatedAt.timeIntervalSince1970 as Any? ?? NSNull(),
                "pluginID": self.plugin?.manifest.id.rawValue as Any? ?? NSNull(),
                "pluginSourceHash": self.plugin?.sourceHash as Any? ?? NSNull(),
                "initialPluginSourceHash": self.initialSourceHash as Any? ?? NSNull(),
                "defaultsFingerprint": self.defaultsFingerprint() as Any? ?? NSNull(),
                "initialDefaultsFingerprint": self.initialDefaultsFingerprint as Any? ?? NSNull(),
                "storeIconSignature": self.controller?.lastObservedStoreIconWorkSignature as Any? ?? NSNull(),
                "totalIconUpdates": self.updateCount,
                "hooksObserved": self.updateCount > 0,
                "measuredObserverUpdates": self.measuredObserverUpdates,
                "measuredOtherUpdates": self.measuredOtherUpdates,
                "openMenus": self.controller?.openMenus.count ?? 0,
                "animationDriverActive": self.controller?.animationDriver != nil,
                "blinkTaskActive": self.controller?.blinkTask != nil,
                "countdownTaskActive": self.controller?.menuBarCountdownRefreshTask != nil,
                "networkAttempts": self.transport.attempts,
                "notificationAttempts": self.notifier.attempts,
                "settingsUnchangedSinceReady": settingsUnchanged,
                "settingsWindowNumber": self.settingsWindow?.windowNumber as Any? ?? NSNull(),
                "measurementCompleted": self.measurementCompleted,
                "forcedControlCompleted": self.forcedControlCompleted,
                "initialTitleCorrect": self.initialTitle == "77%",
                "measuredTitleMatchesMode": self.measuredTitle == expectedMeasuredTitle,
                "baselineProofPassed": self.measurementCompleted && self.options.baseline
                    && self.initialTitle == "77%" && self.measuredTitle == "77%"
                    && self.measuredObserverUpdates == 0 && self.measuredOtherUpdates == 0
                    && settingsUnchanged && self.transport.attempts == 0 && self.notifier.attempts == 0,
                "forcedControlPassed": self.forcedControlCompleted && self.measuredTitle == "77%"
                    && button?.title.trimmingCharacters(in: .whitespacesAndNewlines) == "80%",
                "observerProofPassed": self.measurementCompleted && !self.options.baseline
                    && self.initialTitle == "77%" && self.measuredTitle == "80%"
                    && self.measuredObserverUpdates == 1 && self.measuredOtherUpdates == 0
                    && settingsUnchanged && self.transport.attempts == 0 && self.notifier.attempts == 0,
            ]
            if let settings {
                value["mergeIcons"] = settings.mergeIcons
                value["mergeIconsStacked"] = settings.mergeIconsStacked
                value["unifiedIconSource"] = settings.unifiedIconSource.rawValue
                value["menuBarIconStyle"] = settings.menuBarIconStyle.rawValue
                value["usageBarsShowUsed"] = settings.usageBarsShowUsed
                value["selectedProvider"] = settings.selectedMenuProvider?.rawValue as Any? ?? NSNull()
                value["mergedMenuLastSelectedWasOverview"] = settings.mergedMenuLastSelectedWasOverview
                value["configRevision"] = settings.configRevision
                value["backgroundWorkSettingsRevision"] = settings.backgroundWorkSettingsRevision
                value["initialConfigRevision"] = self.initialConfigRevision as Any? ?? NSNull()
                value["initialBackgroundWorkSettingsRevision"] = self.initialBackgroundRevision as Any? ?? NSNull()
                if let plugin {
                    let layout = settings.menuBarLayout(forPlugin: plugin.manifest.id)
                    value["selectedWindow"] = MenuBarPercentWindowPreference.current(in: layout)?.id as Any? ?? NSNull()
                    value["selectedWindowLabel"] = MenuBarPercentWindowPreference.current(in: layout)?
                        .label(for: nil, snapshot: snapshot) as Any? ?? NSNull()
                    if let encoded = try? JSONEncoder().encode(layout),
                       let layoutJSON = try? JSONSerialization.jsonObject(with: encoded)
                    {
                        value["selectedLayout"] = layoutJSON
                    }
                }
            }
            if let controller {
                value["statusItemVisible"] = controller.statusItem.isVisible
                value["statusItemLength"] = Double(controller.statusItem.length)
                value["primaryProviderForIcon"] = controller.primaryProviderForUnifiedIcon().rawValue
                value["enabledProviders"] = controller.store.enabledProvidersForDisplay().map(\.rawValue)
            }
            if let button, let window = button.window {
                let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
                value["windowNumber"] = window.windowNumber
                value["buttonFrameInScreen"] = Self.rect(frame)
                value["statusItemWindowFrame"] = Self.rect(window.frame)
                value["frameOnVisibleDisplay"] = NSScreen.screens.contains { $0.frame.intersects(frame) }
                value["screens"] = NSScreen.screens.map { Self.rect($0.frame) }
            }
            return value
        }

        private static func rect(_ rect: NSRect) -> [String: Double] {
            ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
        }

        private func defaultsFingerprint() -> String? {
            guard let defaults,
                  let data = try? JSONSerialization.data(
                      withJSONObject: Self.normalizedProperty(defaults.dictionaryRepresentation()),
                      options: [.sortedKeys])
            else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func normalizedProperty(_ value: Any) -> Any {
            if let data = value as? Data { return ["dataBase64": data.base64EncodedString()] }
            if let date = value as? Date { return ["dateSeconds": date.timeIntervalSince1970] }
            if let url = value as? URL { return ["url": url.absoluteString] }
            if let values = value as? [String: Any] {
                return values.mapValues { Self.normalizedProperty($0) }
            }
            if let values = value as? [Any] { return values.map { Self.normalizedProperty($0) } }
            if value is String || value is NSNumber || value is NSNull { return value }
            return ["type": String(reflecting: type(of: value)), "description": String(describing: value)]
        }

        private func append(_ event: String, extra: [String: Any] = [:]) {
            self.sequence += 1
            var value = self.state()
            value["sequence"] = self.sequence
            value["event"] = event
            value.merge(extra) { _, new in new }
            do {
                var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                data.append(0x0A)
                try self.events.write(contentsOf: data)
                FileHandle.standardOutput.write(data)
            } catch {
                FileHandle.standardError.write(Data("Proof receipt write failed: \(error)\n".utf8))
            }
        }

        private func writeJSON(_ name: String, value: [String: Any]) {
            do {
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
                    .write(to: self.options.output.appendingPathComponent(name), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Proof state write failed: \(error)\n".utf8))
            }
        }

        private func stop(reason: String) {
            guard !self.stopping else { return }
            self.stopping = true
            self.phase = "finished"
            self.append("finished", extra: ["reason": reason])
            self.writeJSON("finished.json", value: self.state())
            NSApplication.shared.terminate(nil)
        }
    }

    @MainActor
    private struct ProofSettingsView: View {
        let settings: SettingsStore
        let instanceID: ProviderInstanceID
        let snapshot: UsageSnapshot

        var body: some View {
            Form {
                LabeledContent("Merge icons", value: self.settings.mergeIcons ? "Enabled" : "Disabled")
                LabeledContent("Merged icon source", value: self.settings.unifiedIconSource.label)
                LabeledContent("Menu bar style", value: self.settings.menuBarIconStyle.label)
                ProviderMenuBarPercentWindowSettingsView(
                    instanceID: self.instanceID, settings: self.settings, snapshot: self.snapshot)
                Text("Synthetic plugin data. Read the percentage on the native menu bar item.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding(12)
            .frame(width: 480, height: 310)
        }
    }

    private struct EmptySecrets: ZaiTokenStoring, SyntheticTokenStoring, CookieHeaderStoring,
        MiniMaxCookieStoring, MiniMaxAPITokenStoring, KimiTokenStoring, CopilotTokenStoring
    {
        func loadToken() throws -> String? { nil }
        func loadCookieHeader() throws -> String? { nil }
        func storeToken(_: String?) throws { throw Failure(description: "Unexpected synthetic credential write") }
        func storeCookieHeader(_: String?) throws { throw Failure(description: "Unexpected synthetic cookie write") }
    }

    private struct EmptyTokenAccounts: ProviderTokenAccountStoring {
        let fileURL: URL
        func loadAccounts() throws -> [UsageProvider: ProviderTokenAccountData] { [:] }
        func storeAccounts(_: [UsageProvider: ProviderTokenAccountData]) throws {
            throw Failure(description: "Unexpected synthetic token-account write")
        }

        func ensureFileExists() throws -> URL { self.fileURL }
    }

    private final class NoNetworkTransport: ProviderHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var attempts: Int { self.lock.withLock { self.count } }

        func data(for _: URLRequest) async throws -> (Data, URLResponse) {
            self.lock.withLock { self.count += 1 }
            throw Failure(description: "Synthetic proof forbids network transport")
        }
    }

    @MainActor
    private final class NoNotifications: SessionQuotaNotifying {
        private(set) var attempts = 0
        func post(transition _: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {
            self.attempts += 1
        }

        func postQuotaWarning(
            event _: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {
            self.attempts += 1
        }
    }

    /// Dictionary-only reads and writes, copied from the repository's test-store contract.
    private final class DictionaryDefaults: UserDefaults, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any]

        init(values: [String: Any]) {
            self.values = values
            super.init(suiteName: "PluginPercentRefreshProof-\(UUID().uuidString)")!
        }

        override func object(forKey key: String) -> Any? { self.lock.withLock { self.values[key] } }
        override func set(_ value: Any?, forKey key: String) { self.lock.withLock { self.values[key] = value } }
        override func removeObject(forKey key: String) { self.set(nil as Any?, forKey: key) }
        override func bool(forKey key: String) -> Bool { (self.object(forKey: key) as? NSNumber)?.boolValue ?? false }
        override func integer(forKey key: String) -> Int { (self.object(forKey: key) as? NSNumber)?.intValue ?? 0 }
        override func float(forKey key: String) -> Float { (self.object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
        override func double(forKey key: String) -> Double { (self.object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
        override func string(forKey key: String) -> String? { self.object(forKey: key) as? String }
        override func array(forKey key: String) -> [Any]? { self.object(forKey: key) as? [Any] }
        override func dictionary(forKey key: String) -> [String: Any]? { self.object(forKey: key) as? [String: Any] }
        override func data(forKey key: String) -> Data? { self.object(forKey: key) as? Data }
        override func stringArray(forKey key: String) -> [String]? { self.object(forKey: key) as? [String] }
        override func url(forKey key: String) -> URL? { self.object(forKey: key) as? URL }
        override func set(_ value: Bool, forKey key: String) { self.set(value as Any, forKey: key) }
        override func set(_ value: Int, forKey key: String) { self.set(value as Any, forKey: key) }
        override func set(_ value: Float, forKey key: String) { self.set(value as Any, forKey: key) }
        override func set(_ value: Double, forKey key: String) { self.set(value as Any, forKey: key) }
        override func set(_ value: URL?, forKey key: String) { self.set(value as Any?, forKey: key) }
        override func dictionaryRepresentation() -> [String: Any] { self.lock.withLock { self.values } }
    }
}
#endif
