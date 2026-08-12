import Foundation
import Observation

@MainActor
@Observable
final class FanControlStore {
    private(set) var fans: [FanSnapshot] = []
    private(set) var temperatures: [ThermalSensor] = []
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var controlMessage: String?
    private(set) var helperStatus: ControlHelperStatus = .notInstalled
    private(set) var isChangingHelper = false
    private(set) var curveProfiles: [ThermalCurveProfile]
    private(set) var activeCurveID: String
    private(set) var curveControlTemperature: Double?
    private(set) var curveTargetRPMs: [Int: Double] = [:]
    private(set) var curveStatus = L10n.string("System control below activation temperature")
    private(set) var isCurveOverrideActive = false
    private(set) var curveEditorMessage: String?
    private(set) var activeAICurveID: String?
    private(set) var aiCaptureSession: AICaptureSession?
    private(set) var latestAICaptureSession: AICaptureSession?
    private(set) var aiCaptureError: String?
    private(set) var isLoadingAIState = true
    private(set) var aiPreviewProfile: ThermalCurveProfile?
    private(set) var aiPreviewError: String?
    var aiWorkflowRequestID = 0
    var selectedMode: FanControlMode = .system

    @ObservationIgnored private var monitor: HardwareMonitor?
    @ObservationIgnored private let fanControl = FanControlService()
    @ObservationIgnored private let aiRecorder = AIObservationRecorder()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isEvaluatingCurve = false
    @ObservationIgnored private var filteredControlTemperature: Double?
    @ObservationIgnored private var previousCurveTargets: [Int: Double] = [:]
    @ObservationIgnored private var lastCaptureSampleAt: Date?
    @ObservationIgnored private var isAppendingCaptureSample = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let startupMode: FanControlMode
    @ObservationIgnored private var didRestoreStartupMode = false

    init() {
        startupMode = FanControlMode(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKey.savedFanMode) ?? ""
        ) ?? .system
        let customProfiles: [ThermalCurveProfile]
        if let data = UserDefaults.standard.data(forKey: "customThermalCurves"),
           let decoded = try? JSONDecoder().decode([ThermalCurveProfile].self, from: data)
        {
            customProfiles = decoded
                .filter { !$0.isBuiltIn }
                .map { $0.validated() }
        } else if let data = UserDefaults.standard.data(forKey: "customThermalCurve"),
                  let decoded = try? JSONDecoder().decode(ThermalCurveProfile.self, from: data)
        {
            customProfiles = [decoded.validated()]
        } else {
            customProfiles = [.defaultCustom]
        }
        let profiles = ThermalCurveProfile.presets + customProfiles
        let savedID = UserDefaults.standard.string(forKey: "activeThermalCurveID")
        let savedAICurveID = UserDefaults.standard.string(forKey: "activeAICurveID")
        curveProfiles = profiles
        activeCurveID = profiles.contains(where: { $0.id == savedID }) ? savedID! : ThermalCurveProfile.balanced.id
        activeAICurveID = profiles.first(where: { $0.id == savedAICurveID && $0.isAIGenerated })?.id
    }

    var canControlFans: Bool { helperStatus == .ready }
    var aiProfiles: [ThermalCurveProfile] { curveProfiles.filter(\.isAIGenerated) }
    var hasAISchedule: Bool { activeAICurve != nil }
    var isCurveMode: Bool { selectedMode == .autoBoost || selectedMode == .aiScheduling }
    var hottestTemperature: Double? { temperatures.map(\.celsius).max() }
    var hottestCPUTemperature: Double? {
        temperatures(in: .cpu).map(\.celsius).max()
    }
    var hottestGPUTemperature: Double? {
        temperatures(in: .gpu).map(\.celsius).max()
    }
    var fastestFanRPM: Double? { fans.map(\.currentRPM).max() }
    var displayedCurveTemperature: Double? {
        if isCurveMode, let curveControlTemperature {
            return curveControlTemperature
        }
        return temperatures
            .filter { [.cpu, .gpu, .memory].contains($0.group) }
            .map(\.celsius)
            .max()
    }
    var quietFanFraction: Double? {
        guard !fans.isEmpty else { return nil }
        return fans.map { $0.fraction(forRPM: 3_000) }.min()
    }
    var activeCurve: ThermalCurveProfile {
        curveProfiles.first(where: { $0.id == activeCurveID }) ?? .balanced
    }

    var activeAICurve: ThermalCurveProfile? {
        guard let activeAICurveID else { return nil }
        return curveProfiles.first(where: { $0.id == activeAICurveID && $0.isAIGenerated })
    }

    var activeScheduleCurve: ThermalCurveProfile {
        selectedMode == .aiScheduling ? (activeAICurve ?? .balanced) : activeCurve
    }

    func start() {
        guard refreshTask == nil else { return }
        do {
            monitor = try HardwareMonitor()
            refresh()
            refreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let savedInterval = self?.defaults.object(forKey: "refreshInterval") as? Double
                    let interval = max(savedInterval ?? 2, 1)
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                    if self?.canControlFans == false {
                        await self?.refreshHelperStatus()
                    }
                }
            }
            Task { await refreshHelperStatus() }
            Task { await restoreAIState() }
        } catch {
            errorMessage = L10n.error(error)
        }
    }

    func refresh() {
        guard let monitor else { return }
        isRefreshing = true
        fans = monitor.readFans()
        temperatures = monitor.readTemperatures()
        lastUpdated = .now
        errorMessage = fans.isEmpty && temperatures.isEmpty
            ? L10n.string("AppleSMC is connected, but no supported sensors were found.")
            : nil
        isRefreshing = false
        NotificationCenter.default.post(name: .fanControlDidRefresh, object: self)
        if isCurveMode {
            Task { await evaluateCurveIfNeeded() }
        }
        recordAICaptureSampleIfNeeded()
    }

    func selectMode(_ mode: FanControlMode) {
        if mode == .aiScheduling && !hasAISchedule {
            requestAIWorkflow()
            return
        }
        guard mode != selectedMode else { return }
        Task { _ = await applyMode(mode, persist: true) }
    }

    func requestAIWorkflow() {
        aiWorkflowRequestID &+= 1
    }

    func refreshHelperStatus() async {
        helperStatus = await fanControl.refreshStatus()
        if helperStatus == .ready {
            controlMessage = nil
            await restoreStartupModeIfNeeded()
        }
    }

    func installOrApproveHelper() {
        if helperStatus == .requiresApproval {
            fanControl.openApprovalSettings()
            return
        }
        isChangingHelper = true
        Task {
            defer { isChangingHelper = false }
            do {
                helperStatus = try await fanControl.install()
                controlMessage = helperStatus == .ready ? nil : helperStatus.detail
            } catch {
                helperStatus = .failed(error.localizedDescription)
                controlMessage = error.localizedDescription
            }
        }
    }

    func selectCurve(_ id: String) {
        guard curveProfiles.contains(where: { $0.id == id && !$0.isAIGenerated }) else { return }
        activeCurveID = id
        defaults.set(id, forKey: "activeThermalCurveID")
        filteredControlTemperature = nil
        previousCurveTargets = [:]
        if isCurveMode {
            Task { await evaluateCurveIfNeeded() }
        }
    }

    func selectAICurve(_ id: String) {
        guard curveProfiles.contains(where: { $0.id == id && $0.isAIGenerated }) else { return }
        activeAICurveID = id
        defaults.set(id, forKey: "activeAICurveID")
        filteredControlTemperature = nil
        previousCurveTargets = [:]
        if selectedMode == .aiScheduling {
            Task { await evaluateCurveIfNeeded() }
        }
    }

    var aiCaptureSummary: AICaptureSummary? {
        latestAICaptureSession.map(AIPromptBuilder.summary(for:))
    }

    var aiPrompt: String? {
        latestAICaptureSession.map(AIPromptBuilder.prompt(for:))
    }

    func beginAICaptureIfNeeded() {
        guard !isLoadingAIState,
              aiCaptureSession == nil,
              latestAICaptureSession == nil
        else { return }
        startAICapture()
    }

    func startAICapture() {
        guard aiCaptureSession == nil else { return }
        aiCaptureError = nil
        Task { @MainActor in
            if selectedMode != .system {
                guard await applyMode(.system, persist: false) else {
                    aiCaptureError = L10n.string("Fankit could not switch to System scheduling for recording.")
                    return
                }
            }
            do {
                let session = try await aiRecorder.startSession()
                aiCaptureSession = session
                latestAICaptureSession = nil
                lastCaptureSampleAt = nil
            } catch {
                aiCaptureError = error.localizedDescription
            }
        }
    }

    func finishAICapture() {
        guard aiCaptureSession != nil else { return }
        Task { @MainActor in
            do {
                let session = try await aiRecorder.finishSession()
                aiCaptureSession = nil
                latestAICaptureSession = session
                lastCaptureSampleAt = nil
            } catch {
                aiCaptureError = error.localizedDescription
            }
        }
    }

    func discardLatestAICapture() {
        latestAICaptureSession = nil
        aiPreviewProfile = nil
        aiPreviewError = nil
        aiCaptureError = nil
    }

    func previewAIResponse(_ text: String) {
        do {
            aiPreviewProfile = try AIScheduleParser.parse(text)
            aiPreviewError = nil
        } catch {
            aiPreviewProfile = nil
            aiPreviewError = error.localizedDescription
        }
    }

    func clearAIPreview() {
        aiPreviewProfile = nil
        aiPreviewError = nil
    }

    @discardableResult
    func saveAIPreview() -> Bool {
        guard var profile = aiPreviewProfile else { return false }
        profile.id = "ai.\(UUID().uuidString)"
        profile.isBuiltIn = false
        curveProfiles.append(profile)
        activeAICurveID = profile.id
        persistCustomCurves()
        aiPreviewProfile = nil
        return true
    }

    func saveAndEnableAIPreview() {
        guard saveAIPreview() else { return }
        Task { _ = await applyMode(.aiScheduling, persist: true) }
    }

    func deleteActiveAICurve() {
        guard let activeAICurveID,
              let index = curveProfiles.firstIndex(where: { $0.id == activeAICurveID && $0.isAIGenerated })
        else { return }
        curveProfiles.remove(at: index)
        self.activeAICurveID = aiProfiles.first?.id
        defaults.set(self.activeAICurveID, forKey: "activeAICurveID")
        if selectedMode == .aiScheduling {
            Task { _ = await applyMode(.system, persist: true) }
        }
        persistCustomCurves()
    }

    private func restoreAIState() async {
        defer { isLoadingAIState = false }
        do {
            let restored = try await aiRecorder.restore()
            aiCaptureSession = restored.active
            latestAICaptureSession = restored.latest
            lastCaptureSampleAt = restored.active?.samples.last?.timestamp
        } catch {
            aiCaptureError = error.localizedDescription
        }
    }

    private func recordAICaptureSampleIfNeeded() {
        guard aiCaptureSession != nil,
              !isAppendingCaptureSample,
              !fans.isEmpty || !temperatures.isEmpty
        else { return }
        let now = Date()
        if let lastCaptureSampleAt,
           now.timeIntervalSince(lastCaptureSampleAt) < AIObservationRecorder.sampleInterval
        {
            return
        }

        let sample = AICaptureSample(timestamp: now, sensors: temperatures, fans: fans)
        lastCaptureSampleAt = now
        isAppendingCaptureSample = true
        Task { @MainActor in
            defer { isAppendingCaptureSample = false }
            do {
                let updatedSession = try await aiRecorder.append(sample)
                if updatedSession.isRecording {
                    aiCaptureSession = updatedSession
                } else {
                    aiCaptureSession = nil
                    latestAICaptureSession = updatedSession
                    lastCaptureSampleAt = nil
                }
            } catch {
                aiCaptureError = error.localizedDescription
            }
        }
    }

    func renameCustomCurve(_ name: String) {
        guard let index = curveProfiles.firstIndex(where: { $0.id == activeCurveID }),
              !curveProfiles[index].isBuiltIn
        else { return }
        curveProfiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : name
        persistCustomCurves()
    }

    func updateCurvePoint(id: UUID, temperature: Double? = nil, fanFraction: Double? = nil) {
        let editableID = ensureEditableCurve()
        guard let profileIndex = curveProfiles.firstIndex(where: { $0.id == editableID }),
              let pointIndex = curveProfiles[profileIndex].points.firstIndex(where: { $0.id == id })
        else { return }

        if let temperature { curveProfiles[profileIndex].points[pointIndex].temperature = temperature }
        if let fanFraction { curveProfiles[profileIndex].points[pointIndex].fanFraction = fanFraction }
        curveProfiles[profileIndex] = curveProfiles[profileIndex].validated()
        persistCustomCurves()
    }

    func addCurvePoint() {
        let editableID = ensureEditableCurve()
        guard let index = curveProfiles.firstIndex(where: { $0.id == editableID }) else { return }
        let points = curveProfiles[index].normalizedPoints
        guard points.count < 8 else { return }
        let last = points.last ?? .init(temperature: 80, fanFraction: 0.8)
        curveProfiles[index].points.append(.init(
            temperature: min(last.temperature + 5, 100),
            fanFraction: min(last.fanFraction + 0.1, 1)
        ))
        curveProfiles[index] = curveProfiles[index].validated()
        curveEditorMessage = L10n.string("Added a new point. Drag the fine controls or click the chart again.")
        persistCustomCurves()
    }

    func removeCurvePoint(id: UUID) {
        let editableID = ensureEditableCurve()
        guard let index = curveProfiles.firstIndex(where: { $0.id == editableID }),
              curveProfiles[index].points.count > 2
        else { return }
        curveProfiles[index].points.removeAll { $0.id == id }
        persistCustomCurves()
    }

    func saveCurveAsPreset(named requestedName: String) {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        var copy = activeCurve.validated()
        copy.id = "custom.\(UUID().uuidString)"
        copy.name = trimmed.isEmpty
            ? L10n.format("%@ Copy", activeCurve.localizedName)
            : trimmed
        copy.summary = "Custom fan preset."
        copy.isBuiltIn = false
        copy.points = copy.points.map {
            ThermalCurvePoint(temperature: $0.temperature, fanFraction: $0.fanFraction)
        }
        curveProfiles.append(copy)
        activeCurveID = copy.id
        curveEditorMessage = L10n.format("Saved %@.", copy.name)
        persistCustomCurves()
    }

    func deleteActiveCustomCurve() {
        guard let index = curveProfiles.firstIndex(where: { $0.id == activeCurveID }),
              !curveProfiles[index].isBuiltIn
        else { return }
        let deletedName = curveProfiles[index].name
        curveProfiles.remove(at: index)
        activeCurveID = ThermalCurveProfile.balanced.id
        curveEditorMessage = L10n.format(
            "Deleted %@. %@ is now selected.",
            deletedName,
            ThermalCurveProfile.balanced.localizedName
        )
        persistCustomCurves()
    }

    func coarseAdjustCurve(temperature: Double, fanFraction: Double) {
        let editableID = ensureEditableCurve()
        guard let index = curveProfiles.firstIndex(where: { $0.id == editableID }) else { return }
        switch curveProfiles[index].coarseAdjust(temperature: temperature, fanFraction: fanFraction) {
        case .added(let temperature, let fanFraction):
            curveEditorMessage = L10n.format(
                "Added %d°C at %d%%.",
                Int(temperature),
                Int(fanFraction * 100)
            )
        case .moved(let temperature, let fanFraction):
            curveEditorMessage = L10n.format(
                "Moved the nearest point to %d°C at %d%%.",
                Int(temperature),
                Int(fanFraction * 100)
            )
        case .unchanged:
            curveEditorMessage = nil
        }
        persistCustomCurves()
    }

    func addCurvePoint(temperature: Double, fanFraction: Double) {
        let editableID = ensureEditableCurve()
        guard let index = curveProfiles.firstIndex(where: { $0.id == editableID }) else { return }
        guard curveProfiles[index].points.count < 8 else {
            curveEditorMessage = L10n.string("A curve can contain up to 8 points.")
            return
        }

        let temperature = min(max(temperature.rounded(), 35), 100)
        let fanFraction = min(max((fanFraction * 100).rounded() / 100, 0), 1)
        guard curveProfiles[index].points.allSatisfy({ abs($0.temperature - temperature) >= 1 }) else {
            curveEditorMessage = L10n.format(
                "Drag the existing point at %d°C instead.",
                Int(temperature)
            )
            return
        }

        curveProfiles[index].points.append(.init(
            temperature: temperature,
            fanFraction: fanFraction
        ))
        curveProfiles[index] = curveProfiles[index].validated()
        curveEditorMessage = L10n.format(
            "Added %d°C at %d%%.",
            Int(temperature),
            Int(fanFraction * 100)
        )
        persistCustomCurves()
    }

    func dragCurvePoint(id: UUID, temperature: Double, fanFraction: Double) {
        let editableID = ensureEditableCurve()
        guard let profileIndex = curveProfiles.firstIndex(where: { $0.id == editableID }) else { return }
        curveProfiles[profileIndex].movePoint(
            id: id,
            temperature: temperature,
            fanFraction: fanFraction
        )
        curveEditorMessage = nil
    }

    func finishDraggingCurvePoint(id: UUID) {
        guard let point = activeCurve.points.first(where: { $0.id == id }) else { return }
        curveEditorMessage = L10n.format(
            "Moved point to %d°C at %d%%.",
            Int(point.temperature),
            Int(point.fanFraction * 100)
        )
        persistCustomCurves()
    }

    func temperatures(in group: ThermalGroup) -> [ThermalSensor] {
        temperatures.filter { $0.group == group }
    }

    private func evaluateCurveIfNeeded() async {
        guard isCurveMode, canControlFans, !isEvaluatingCurve else { return }
        isEvaluatingCurve = true
        defer { isEvaluatingCurve = false }

        let controlSensors = temperatures.filter { [.cpu, .gpu, .memory].contains($0.group) }
        guard let rawTemperature = controlSensors.map(\.celsius).max(), rawTemperature.isFinite, !fans.isEmpty else {
            await failCurveSafely(
                message: L10n.string("No valid processor, graphics, or memory temperature is available.")
            )
            return
        }

        if let filteredControlTemperature {
            let factor = rawTemperature > filteredControlTemperature ? 0.65 : 0.25
            self.filteredControlTemperature = filteredControlTemperature
                + ((rawTemperature - filteredControlTemperature) * factor)
        } else {
            filteredControlTemperature = rawTemperature
        }
        let temperature = max(filteredControlTemperature ?? rawTemperature, rawTemperature >= 95 ? rawTemperature : 0)
        curveControlTemperature = temperature

        do {
            if rawTemperature >= 100 {
                try await fanControl.apply(.maximum)
                isCurveOverrideActive = true
                curveTargetRPMs = Dictionary(uniqueKeysWithValues: fans.map { ($0.index, $0.maximumRPM) })
                previousCurveTargets = curveTargetRPMs
                curveStatus = L10n.string("Emergency cooling at maximum speed")
                return
            }

            let activation = activeScheduleCurve.activationTemperature
            if isCurveOverrideActive && temperature <= activation - 2 {
                try await fanControl.apply(.system)
                resetCurveRuntimeState(keepTemperature: true)
                curveStatus = L10n.format(
                    "System control · %d°C is below %d°C",
                    Int(temperature.rounded()),
                    Int(activation)
                )
                return
            }

            guard let fraction = activeScheduleCurve.fanFraction(at: temperature) else {
                curveStatus = L10n.format(
                    "System control · activates at %d°C",
                    Int(activation)
                )
                curveTargetRPMs = [:]
                return
            }

            var nextTargets: [Int: Double] = [:]
            for fan in fans {
                let requested = ThermalCurveProfile.targetRPM(
                    for: fraction,
                    minimumRPM: fan.minimumRPM,
                    maximumRPM: fan.maximumRPM
                )
                if requested == 0 {
                    try await fanControl.setTargetRPM(0, fan: fan.index)
                    nextTargets[fan.index] = 0
                    continue
                }
                let previous = previousCurveTargets[fan.index] ?? max(fan.currentRPM, requested)
                let limited: Double
                if requested >= previous {
                    limited = min(requested, previous + 900)
                } else {
                    limited = max(requested, previous - 350)
                }
                let target = min(max(limited, fan.minimumRPM), fan.maximumRPM)
                try await fanControl.setTargetRPM(target, fan: fan.index)
                nextTargets[fan.index] = target
            }
            previousCurveTargets = nextTargets
            curveTargetRPMs = nextTargets
            isCurveOverrideActive = true
            curveStatus = L10n.format(
                "%d%% fan demand",
                Int((fraction * 100).rounded())
            )
        } catch {
            await failCurveSafely(message: error.localizedDescription)
        }
    }

    private func failCurveSafely(message: String) async {
        try? await fanControl.apply(.system)
        selectedMode = .system
        defaults.set(FanControlMode.system.rawValue, forKey: PreferenceKey.savedFanMode)
        resetCurveRuntimeState()
        controlMessage = L10n.format(
            "Auto Boost stopped and restored System mode: %@",
            message
        )
    }

    @discardableResult
    private func applyMode(_ mode: FanControlMode, persist: Bool) async -> Bool {
        do {
            if mode == .autoBoost || mode == .aiScheduling {
                if mode == .aiScheduling, activeAICurve == nil {
                    selectedMode = .system
                    return false
                }
                try await fanControl.apply(.system)
                selectedMode = mode
                resetCurveRuntimeState()
                try await fanControl.apply(mode)
                if persist {
                    defaults.set(mode.rawValue, forKey: PreferenceKey.savedFanMode)
                }
                controlMessage = nil
                await evaluateCurveIfNeeded()
                return selectedMode == mode
            } else {
                try await fanControl.apply(mode)
                selectedMode = mode
                resetCurveRuntimeState()
                if persist {
                    defaults.set(mode.rawValue, forKey: PreferenceKey.savedFanMode)
                }
                controlMessage = nil
                return true
            }
        } catch {
            controlMessage = error.localizedDescription
            return false
        }
    }

    private func restoreStartupModeIfNeeded() async {
        guard !didRestoreStartupMode else { return }
        guard startupMode != .system else {
            didRestoreStartupMode = true
            return
        }
        if startupMode == .aiScheduling, activeAICurve == nil {
            // A deleted or invalid AI profile must not cause every helper refresh
            // to retry a mode that cannot be applied.
            didRestoreStartupMode = true
            return
        }
        let restored = await applyMode(startupMode, persist: false)
        didRestoreStartupMode = restored
    }

    private func resetCurveRuntimeState(keepTemperature: Bool = false) {
        isCurveOverrideActive = false
        previousCurveTargets = [:]
        curveTargetRPMs = [:]
        if !keepTemperature {
            filteredControlTemperature = nil
            curveControlTemperature = nil
        }
        curveStatus = L10n.string("System control below activation temperature")
    }

    @discardableResult
    private func ensureEditableCurve() -> String {
        if !activeCurve.isBuiltIn { return activeCurveID }
        var editable = activeCurve
        editable.id = "custom.\(UUID().uuidString)"
        editable.name = L10n.format("%@ Custom", activeCurve.localizedName)
        editable.summary = L10n.format("Customized from %@.", activeCurve.localizedName)
        editable.isBuiltIn = false
        curveProfiles.append(editable)
        activeCurveID = editable.id
        curveEditorMessage = L10n.format(
            "Created %@. Built-in presets remain unchanged.",
            editable.name
        )
        persistCustomCurves()
        return editable.id
    }

    private func persistCustomCurves() {
        let customProfiles = curveProfiles
            .filter { !$0.isBuiltIn }
            .map { $0.validated() }
        guard let data = try? JSONEncoder().encode(customProfiles) else { return }
        defaults.set(data, forKey: "customThermalCurves")
        defaults.set(activeCurveID, forKey: "activeThermalCurveID")
        defaults.set(activeAICurveID, forKey: "activeAICurveID")
        filteredControlTemperature = nil
        previousCurveTargets = [:]
        if isCurveMode {
            Task { await evaluateCurveIfNeeded() }
        }
    }
}

extension Notification.Name {
    static let fanControlDidRefresh = Notification.Name("FanControl.didRefresh")
}
