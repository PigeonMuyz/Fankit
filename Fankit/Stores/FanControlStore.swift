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
    private(set) var aiPreviewProfiles: [ThermalCurveProfile] = []
    private(set) var aiPreviewError: String?
    private(set) var quietCalibrationProfile: QuietCalibrationProfile?
    private(set) var isStartingQuietCalibration = false
    private(set) var isQuietCalibrationActive = false
    private(set) var quietCalibrationScope: QuietCalibrationScope = .allFans
    private(set) var quietCalibrationMethod: QuietCalibrationMethod?
    private(set) var quietCalibrationFanPosition = 0
    private(set) var quietCalibrationFanFraction = 0.25
    private(set) var quietCalibrationDraftRPMs: [Int: Double] = [:]
    private(set) var quietCalibrationMessage: String?
    var aiWorkflowRequestID = 0
    var settingsWorkflowRequestID = 0
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
    @ObservationIgnored private var quietCalibrationOriginalMode: FanControlMode?
    @ObservationIgnored private var quietCalibrationStartTask: Task<Void, Never>?
    @ObservationIgnored private var quietCalibrationApplyTask: Task<Void, Never>?
    @ObservationIgnored private var isStoppingQuietCalibration = false
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
        if let data = UserDefaults.standard.data(forKey: PreferenceKey.quietCalibrationProfile) {
            quietCalibrationProfile = try? JSONDecoder().decode(QuietCalibrationProfile.self, from: data)
        }
        curveProfiles = profiles
        activeCurveID = profiles.contains(where: { $0.id == savedID }) ? savedID! : ThermalCurveProfile.balanced.id
        activeAICurveID = profiles.first(where: { $0.id == savedAICurveID && $0.isAIGenerated })?.id
    }

    var canControlFans: Bool { helperStatus == .ready }
    var aiProfiles: [ThermalCurveProfile] {
        curveProfiles.filter(\.isAIGenerated).sorted {
            let lhs = $0.aiPresetKind?.sortOrder ?? Int.max
            let rhs = $1.aiPresetKind?.sortOrder ?? Int.max
            return lhs == rhs ? $0.localizedName < $1.localizedName : lhs < rhs
        }
    }
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
        let profile = compatibleQuietCalibrationProfile
        return fans.map { fan in
            let rpm = profile?.limit(for: fan.index)?.quietRPM ?? 3_000
            return fan.fraction(forRPM: rpm)
        }.min()
    }
    func quietFanFraction(for fanIndex: Int?) -> Double? {
        guard let fanIndex,
              let fan = fans.first(where: { $0.index == fanIndex })
        else { return quietFanFraction }
        let rpm = compatibleQuietCalibrationProfile?.limit(for: fan.index)?.quietRPM ?? 3_000
        return fan.fraction(forRPM: rpm)
    }
    var compatibleQuietCalibrationProfile: QuietCalibrationProfile? {
        guard let quietCalibrationProfile,
              quietCalibrationProfile.isCompatible(with: fans)
        else { return nil }
        return quietCalibrationProfile
    }
    var hasQuietCalibration: Bool { compatibleQuietCalibrationProfile != nil }
    var quietCalibrationScopeIsCaptured: Bool {
        switch quietCalibrationScope {
        case .allFans:
            !fans.isEmpty && fans.allSatisfy { quietCalibrationDraftRPMs[$0.index] != nil }
        case .fan(let index):
            quietCalibrationDraftRPMs[index] != nil
        }
    }
    var quietCalibrationCurrentFan: FanSnapshot? {
        guard quietCalibrationMethod == .individual else { return nil }
        let orderedFans = fans.sorted { $0.index < $1.index }
        guard orderedFans.indices.contains(quietCalibrationFanPosition) else { return nil }
        return orderedFans[quietCalibrationFanPosition]
    }
    var quietCalibrationStep: Int { min(quietCalibrationFanPosition + 1, max(fans.count, 1)) }
    var quietCalibrationIsLastFan: Bool { quietCalibrationStep >= fans.count }
    var quietCalibrationTargetRPMs: [Int: Double] {
        calibrationTargets(scope: quietCalibrationScope, fraction: quietCalibrationFanFraction)
    }
    var quietRangeDescription: String {
        guard let profile = compatibleQuietCalibrationProfile else {
            return L10n.string("Generic quiet reference · ≤ 3000 RPM")
        }
        if profile.resolvedMethod == .individual {
            return L10n.string("Individual fan quiet limits")
        }
        let values = fans.compactMap { fan -> String? in
            guard let rpm = profile.limit(for: fan.index)?.quietRPM else { return nil }
            return "\(fan.name) \(Int(rpm.rounded())) RPM"
        }
        return L10n.format("Combined quiet level · %@", values.joined(separator: " · "))
    }
    var activeCurve: ThermalCurveProfile {
        curveProfiles.first(where: { $0.id == activeCurveID }) ?? .balanced
    }

    var activeAICurve: ThermalCurveProfile? {
        guard let activeAICurveID else { return nil }
        return curveProfiles.first(where: { $0.id == activeAICurveID && $0.isAIGenerated })
    }

    var activeScheduleCurve: ThermalCurveProfile {
        let profile = selectedMode == .aiScheduling ? (activeAICurve ?? .balanced) : activeCurve
        return quietCalibrationAdjustedCurve(profile)
    }

    private func quietCalibrationAdjustedCurve(
        _ profile: ThermalCurveProfile
    ) -> ThermalCurveProfile {
        guard profile.id == ThermalCurveProfile.quiet.id,
              let calibration = compatibleQuietCalibrationProfile,
              !fans.isEmpty
        else { return profile }

        let semanticScale: Double
        if calibration.resolvedMethod == .combined || fans.count == 1 {
            semanticScale = 1
        } else {
            // Individual audible limits cannot be treated as a combined acoustic
            // result. Reduce each limit as more independently calibrated fans run.
            semanticScale = max(0.65, 1 / sqrt(Double(fans.count)))
        }

        var adjusted = profile
        adjusted.summary = L10n.string(
            "Uses this Mac's calibrated quiet headroom for stronger low-noise cooling."
        )
        adjusted.fanCurves = fans.sorted { $0.index < $1.index }.compactMap { fan in
            guard let limit = calibration.limit(for: fan.index) else { return nil }
            let calibratedFraction = fan.fraction(forRPM: limit.quietRPM) * semanticScale
            return FanSpecificCurve(
                fanIndex: fan.index,
                fanName: fan.name,
                points: profile.quietHeadroomPoints(
                    calibratedFraction: calibratedFraction
                )
            )
        }
        return adjusted.validated()
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
        if isQuietCalibrationActive, (hottestTemperature ?? 0) >= 100 {
            quietCalibrationMessage = L10n.string("Calibration stopped because the temperature reached 100°C.")
            stopQuietCalibration(save: false, emergencyCooling: true)
        }
        recordAICaptureSampleIfNeeded()
    }

    func selectMode(_ mode: FanControlMode) {
        guard !isQuietCalibrationActive, !isStartingQuietCalibration, !isStoppingQuietCalibration else { return }
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

    func requestSettings() {
        settingsWorkflowRequestID &+= 1
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
        latestAICaptureSession.map {
            AIPromptBuilder.prompt(
                for: $0,
                quietProfile: compatibleQuietCalibrationProfile,
                currentFans: fans
            )
        }
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
        aiPreviewProfiles = []
        aiPreviewError = nil
        aiCaptureError = nil
    }

    func previewAIResponse(_ text: String) {
        do {
            aiPreviewProfiles = try AIScheduleParser.parseProfiles(text, fans: fans)
            aiPreviewError = nil
        } catch {
            aiPreviewProfiles = []
            aiPreviewError = error.localizedDescription
        }
    }

    func clearAIPreview() {
        aiPreviewProfiles = []
        aiPreviewError = nil
    }

    @discardableResult
    func saveAIPreview() -> Bool {
        guard !aiPreviewProfiles.isEmpty else { return false }
        let savedProfiles = aiPreviewProfiles.map { preview -> ThermalCurveProfile in
            var profile = preview
            let kind = preview.aiPresetKind?.rawValue ?? "custom"
            profile.id = "ai.\(kind).\(UUID().uuidString)"
            profile.isBuiltIn = false
            profile.points = profile.points.map {
                ThermalCurvePoint(temperature: $0.temperature, fanFraction: $0.fanFraction)
            }
            profile.fanCurves = profile.fanCurves?.map { curve in
                FanSpecificCurve(
                    fanIndex: curve.fanIndex,
                    fanName: curve.fanName,
                    points: curve.points.map {
                        ThermalCurvePoint(temperature: $0.temperature, fanFraction: $0.fanFraction)
                    }
                )
            }
            return profile
        }
        curveProfiles.removeAll(where: \.isAIGenerated)
        curveProfiles.append(contentsOf: savedProfiles)
        activeAICurveID = savedProfiles.first(where: { $0.aiPresetKind == .balanced })?.id
            ?? savedProfiles.first?.id
        persistCustomCurves()
        aiPreviewProfiles = []
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

    func beginQuietCalibration(method requestedMethod: QuietCalibrationMethod? = nil) {
        guard !isQuietCalibrationActive, !isStartingQuietCalibration, !isStoppingQuietCalibration else { return }
        guard canControlFans, !fans.isEmpty else {
            quietCalibrationMessage = L10n.string("Enable fan control before starting quiet calibration.")
            return
        }

        isStartingQuietCalibration = true
        quietCalibrationMessage = nil
        quietCalibrationOriginalMode = selectedMode
        quietCalibrationStartTask = Task { @MainActor in
            defer { quietCalibrationStartTask = nil }
            let restoredSystem = await applyMode(.system, persist: false)
            guard isStartingQuietCalibration else { return }
            guard restoredSystem else {
                isStartingQuietCalibration = false
                quietCalibrationOriginalMode = nil
                quietCalibrationMessage = L10n.string("Fankit could not enter System mode for calibration.")
                return
            }

            let method: QuietCalibrationMethod = fans.count == 1 ? .individual : (requestedMethod ?? .combined)
            quietCalibrationMethod = method
            quietCalibrationFanPosition = 0
            let existingProfile = compatibleQuietCalibrationProfile
            quietCalibrationDraftRPMs = existingProfile?.resolvedMethod == method
                ? Dictionary(uniqueKeysWithValues: (existingProfile?.fanLimits ?? []).map { ($0.fanIndex, $0.quietRPM) })
                : [:]
            quietCalibrationScope = method == .combined
                ? .allFans
                : .fan(fans.sorted { $0.index < $1.index }[0].index)
            quietCalibrationFanFraction = calibrationFraction(for: quietCalibrationScope)
            isQuietCalibrationActive = true
            isStartingQuietCalibration = false
            await applyQuietCalibrationTargets()
        }
    }

    func updateQuietCalibrationFanFraction(_ fraction: Double) {
        guard isQuietCalibrationActive else { return }
        quietCalibrationFanFraction = min(max(fraction, 0), 1)
        switch quietCalibrationScope {
        case .allFans:
            for fan in fans { quietCalibrationDraftRPMs.removeValue(forKey: fan.index) }
        case .fan(let index):
            quietCalibrationDraftRPMs.removeValue(forKey: index)
        }
        scheduleQuietCalibrationTargetUpdate()
    }

    func captureQuietCalibrationLevel() {
        guard isQuietCalibrationActive else { return }
        let targets = calibrationTargets(
            scope: quietCalibrationScope,
            fraction: quietCalibrationFanFraction
        )
        switch quietCalibrationScope {
        case .allFans:
            quietCalibrationDraftRPMs.merge(targets) { _, new in new }
            quietCalibrationMessage = L10n.string("Recorded the combined quiet level for all fans.")
        case .fan(let index):
            guard let target = targets[index] else { return }
            quietCalibrationDraftRPMs[index] = target
            let name = fans.first(where: { $0.index == index })?.name ?? L10n.string("Fan")
            quietCalibrationMessage = L10n.format("Recorded the quiet level for %@.", name)
        }
    }

    @discardableResult
    func captureAndAdvanceQuietCalibration() -> Bool {
        guard isQuietCalibrationActive else { return false }
        captureQuietCalibrationLevel()
        if quietCalibrationMethod == .individual, !quietCalibrationIsLastFan {
            quietCalibrationFanPosition += 1
            guard let fan = quietCalibrationCurrentFan else { return false }
            quietCalibrationScope = .fan(fan.index)
            quietCalibrationFanFraction = calibrationFraction(for: quietCalibrationScope)
            quietCalibrationMessage = L10n.format(
                "Saved %@. Now calibrate %@.",
                fans.sorted { $0.index < $1.index }[quietCalibrationFanPosition - 1].name,
                fan.name
            )
            scheduleQuietCalibrationTargetUpdate()
            return false
        }
        completeQuietCalibration()
        return true
    }

    func completeQuietCalibration() {
        guard isQuietCalibrationActive,
              let method = quietCalibrationMethod,
              quietCalibrationDraftRPMs.count == fans.count
        else { return }
        let limits = fans.compactMap { fan -> QuietFanLimit? in
            guard let quietRPM = quietCalibrationDraftRPMs[fan.index] else { return nil }
            return QuietFanLimit(
                fanIndex: fan.index,
                fanName: fan.name,
                quietRPM: min(
                    max(quietRPM, 0),
                    ThermalCurveProfile.maximumTargetRPM(
                        maximumRPM: fan.maximumRPM
                    )
                ),
                minimumRPM: fan.minimumRPM,
                maximumRPM: fan.maximumRPM
            )
        }
        quietCalibrationProfile = QuietCalibrationProfile(
            hardwareFingerprint: QuietCalibrationProfile.hardwareFingerprint(for: fans),
            fanLimits: limits,
            method: method
        )
        if let quietCalibrationProfile,
           let data = try? JSONEncoder().encode(quietCalibrationProfile)
        {
            defaults.set(data, forKey: PreferenceKey.quietCalibrationProfile)
        }
        quietCalibrationMessage = L10n.string("Saved the quiet calibration for this Mac.")
        stopQuietCalibration(save: true)
    }

    func cancelQuietCalibration() {
        guard isQuietCalibrationActive || isStartingQuietCalibration else { return }
        stopQuietCalibration(save: false)
    }

    func resetQuietCalibration() {
        guard !isQuietCalibrationActive, !isStartingQuietCalibration else { return }
        quietCalibrationProfile = nil
        defaults.removeObject(forKey: PreferenceKey.quietCalibrationProfile)
        quietCalibrationMessage = L10n.string("Removed this Mac's quiet calibration.")
    }

    private func calibrationFraction(for scope: QuietCalibrationScope) -> Double {
        let profile = compatibleQuietCalibrationProfile
        switch scope {
        case .allFans:
            return fans.map { fan in
                let rpm = quietCalibrationDraftRPMs[fan.index]
                    ?? profile?.limit(for: fan.index)?.quietRPM
                    ?? 3_000
                return fan.fraction(forRPM: rpm)
            }.min() ?? 0.25
        case .fan(let index):
            guard let fan = fans.first(where: { $0.index == index }) else { return 0.25 }
            let rpm = quietCalibrationDraftRPMs[index]
                ?? profile?.limit(for: index)?.quietRPM
                ?? 3_000
            return fan.fraction(forRPM: rpm)
        }
    }

    private func calibrationTargets(
        scope: QuietCalibrationScope,
        fraction: Double
    ) -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: fans.map { fan in
            let target: Double
            switch scope {
            case .allFans:
                target = ThermalCurveProfile.targetRPM(
                    for: fraction,
                    maximumRPM: fan.maximumRPM
                )
            case .fan(let selectedIndex):
                target = fan.index == selectedIndex
                    ? ThermalCurveProfile.targetRPM(
                        for: fraction,
                        maximumRPM: fan.maximumRPM
                    )
                    : 0
            }
            let maximumTarget = ThermalCurveProfile.maximumTargetRPM(
                maximumRPM: fan.maximumRPM
            )
            return (fan.index, min(max(target, 0), maximumTarget))
        })
    }

    private func scheduleQuietCalibrationTargetUpdate() {
        quietCalibrationApplyTask?.cancel()
        quietCalibrationApplyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.applyQuietCalibrationTargets()
        }
    }

    private func applyQuietCalibrationTargets() async {
        guard isQuietCalibrationActive else { return }
        let targets = quietCalibrationTargetRPMs
        do {
            for fan in fans {
                guard isQuietCalibrationActive, !Task.isCancelled else { return }
                guard let target = targets[fan.index] else { continue }
                try await fanControl.setTargetRPM(target, fan: fan.index)
            }
        } catch {
            quietCalibrationMessage = error.localizedDescription
            stopQuietCalibration(save: false)
        }
    }

    private func stopQuietCalibration(save: Bool, emergencyCooling: Bool = false) {
        guard !isStoppingQuietCalibration else { return }
        isStoppingQuietCalibration = true
        quietCalibrationStartTask?.cancel()
        quietCalibrationApplyTask?.cancel()
        quietCalibrationApplyTask = nil
        let originalMode = quietCalibrationOriginalMode ?? .system
        isStartingQuietCalibration = false
        isQuietCalibrationActive = false
        quietCalibrationMethod = nil
        quietCalibrationFanPosition = 0
        quietCalibrationOriginalMode = nil
        if !save {
            quietCalibrationDraftRPMs = [:]
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if emergencyCooling {
                do {
                    try await fanControl.apply(.maximum)
                    selectedMode = .maximum
                } catch {
                    controlMessage = error.localizedDescription
                }
            } else {
                _ = await applyMode(originalMode, persist: false)
            }
            isStoppingQuietCalibration = false
        }
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

    func curveProfile(for fanIndex: Int?) -> ThermalCurveProfile {
        activeCurve.displayProfile(for: fanIndex)
    }

    func updateCurvePoint(
        id: UUID,
        temperature: Double? = nil,
        fanFraction: Double? = nil,
        fanIndex: Int? = nil
    ) {
        mutateEditableCurve(fanIndex: fanIndex) { profile in
            guard let pointIndex = profile.points.firstIndex(where: { $0.id == id }) else { return }
            if let temperature { profile.points[pointIndex].temperature = temperature }
            if let fanFraction { profile.points[pointIndex].fanFraction = fanFraction }
            profile = profile.validated()
        }
        persistCustomCurves()
    }

    func addCurvePoint(fanIndex: Int? = nil) {
        let points = curveProfile(for: fanIndex).normalizedPoints
        guard points.count < 8 else { return }
        let last = points.last ?? .init(temperature: 80, fanFraction: 0.8)
        mutateEditableCurve(fanIndex: fanIndex) { profile in
            profile.points.append(.init(
                temperature: min(last.temperature + 5, 100),
                fanFraction: min(last.fanFraction + 0.1, 1)
            ))
            profile = profile.validated()
        }
        curveEditorMessage = L10n.string("Added a new point. Drag the fine controls or click the chart again.")
        persistCustomCurves()
    }

    func removeCurvePoint(id: UUID, fanIndex: Int? = nil) {
        guard curveProfile(for: fanIndex).points.count > 2 else { return }
        mutateEditableCurve(fanIndex: fanIndex) { profile in
            profile.points.removeAll { $0.id == id }
        }
        persistCustomCurves()
    }

    func resetIndependentCurve(for fanIndex: Int) {
        let editableID = ensureEditableCurve()
        guard let profileIndex = curveProfiles.firstIndex(where: { $0.id == editableID })
        else { return }
        curveProfiles[profileIndex].fanCurves?.removeAll { $0.fanIndex == fanIndex }
        if curveProfiles[profileIndex].fanCurves?.isEmpty == true {
            curveProfiles[profileIndex].fanCurves = nil
        }
        curveEditorMessage = L10n.string("This fan now follows the shared curve.")
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
        copy.fanCurves = copy.fanCurves?.map { curve in
            FanSpecificCurve(
                fanIndex: curve.fanIndex,
                fanName: curve.fanName,
                points: curve.points.map {
                    ThermalCurvePoint(temperature: $0.temperature, fanFraction: $0.fanFraction)
                }
            )
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

    func coarseAdjustCurve(temperature: Double, fanFraction: Double, fanIndex: Int? = nil) {
        var adjustment = CurveAdjustment.unchanged
        mutateEditableCurve(fanIndex: fanIndex) { profile in
            adjustment = profile.coarseAdjust(temperature: temperature, fanFraction: fanFraction)
        }
        switch adjustment {
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

    func addCurvePoint(temperature: Double, fanFraction: Double, fanIndex: Int? = nil) {
        let currentProfile = curveProfile(for: fanIndex)
        guard currentProfile.points.count < 8 else {
            curveEditorMessage = L10n.string("A curve can contain up to 8 points.")
            return
        }

        let temperature = min(max(temperature.rounded(), 35), 100)
        let fanFraction = min(max((fanFraction * 100).rounded() / 100, 0), 1)
        guard currentProfile.points.allSatisfy({ abs($0.temperature - temperature) >= 1 }) else {
            curveEditorMessage = L10n.format(
                "Drag the existing point at %d°C instead.",
                Int(temperature)
            )
            return
        }

        mutateEditableCurve(fanIndex: fanIndex) { profile in
            profile.points.append(.init(
                temperature: temperature,
                fanFraction: fanFraction
            ))
            profile = profile.validated()
        }
        curveEditorMessage = L10n.format(
            "Added %d°C at %d%%.",
            Int(temperature),
            Int(fanFraction * 100)
        )
        persistCustomCurves()
    }

    func dragCurvePoint(
        id: UUID,
        temperature: Double,
        fanFraction: Double,
        fanIndex: Int? = nil
    ) {
        mutateEditableCurve(fanIndex: fanIndex) { profile in
            profile.movePoint(id: id, temperature: temperature, fanFraction: fanFraction)
        }
        curveEditorMessage = nil
    }

    func finishDraggingCurvePoint(id: UUID, fanIndex: Int? = nil) {
        guard let point = curveProfile(for: fanIndex).points.first(where: { $0.id == id }) else { return }
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
                curveTargetRPMs = Dictionary(uniqueKeysWithValues: fans.map { fan in
                    (
                        fan.index,
                        ThermalCurveProfile.maximumTargetRPM(
                            maximumRPM: fan.maximumRPM
                        )
                    )
                })
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

            let fractions = Dictionary(uniqueKeysWithValues: fans.compactMap { fan -> (Int, Double)? in
                guard let fraction = activeScheduleCurve.fanFraction(at: temperature, fanIndex: fan.index) else {
                    return nil
                }
                return (fan.index, fraction)
            })
            guard !fractions.isEmpty else {
                curveStatus = L10n.format(
                    "System control · activates at %d°C",
                    Int(activation)
                )
                curveTargetRPMs = [:]
                return
            }

            var nextTargets: [Int: Double] = [:]
            for fan in fans {
                let fraction = fractions[fan.index]
                let requested = ThermalCurveProfile.targetRPM(
                    for: fraction ?? 0,
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
                let maximumTarget = ThermalCurveProfile.maximumTargetRPM(
                    maximumRPM: fan.maximumRPM
                )
                let target = min(max(limited, 0), maximumTarget)
                try await fanControl.setTargetRPM(target, fan: fan.index)
                nextTargets[fan.index] = target
            }
            previousCurveTargets = nextTargets
            curveTargetRPMs = nextTargets
            isCurveOverrideActive = true
            let percentageValues = fans.compactMap { fan -> Int? in
                guard let fraction = fractions[fan.index] else { return 0 }
                return Int((fraction * 100).rounded())
            }
            if Set(percentageValues).count <= 1, let percentage = percentageValues.first {
                curveStatus = L10n.format("%d%% fan demand", percentage)
            } else {
                let values = fans.map { fan in
                    let percentage = Int(((fractions[fan.index] ?? 0) * 100).rounded())
                    return "\(fan.name) \(percentage)%"
                }.joined(separator: " · ")
                curveStatus = L10n.format("Independent fan control · %@", values)
            }
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

    private func mutateEditableCurve(
        fanIndex: Int?,
        mutation: (inout ThermalCurveProfile) -> Void
    ) {
        let editableID = ensureEditableCurve()
        guard let profileIndex = curveProfiles.firstIndex(where: { $0.id == editableID }) else { return }
        var editableProfile = curveProfiles[profileIndex].displayProfile(for: fanIndex)
        mutation(&editableProfile)

        guard let fanIndex else {
            curveProfiles[profileIndex].points = editableProfile.points
            return
        }
        let fanName = fans.first(where: { $0.index == fanIndex })?.name
            ?? curveProfiles[profileIndex].fanCurves?.first(where: { $0.fanIndex == fanIndex })?.fanName
            ?? L10n.string("Fan")
        let fanCurve = FanSpecificCurve(
            fanIndex: fanIndex,
            fanName: fanName,
            points: editableProfile.points
        )
        if let curveIndex = curveProfiles[profileIndex].fanCurves?.firstIndex(where: { $0.fanIndex == fanIndex }) {
            curveProfiles[profileIndex].fanCurves?[curveIndex] = fanCurve
        } else {
            curveProfiles[profileIndex].fanCurves = (curveProfiles[profileIndex].fanCurves ?? []) + [fanCurve]
        }
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
