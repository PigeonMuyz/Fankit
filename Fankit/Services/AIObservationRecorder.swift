import Foundation

enum AICaptureRecorderError: LocalizedError {
    case unavailable
    case alreadyRecording
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Fankit could not open its local AI observation folder."
        case .alreadyRecording:
            "An AI observation is already recording."
        case .noActiveSession:
            "There is no active AI observation."
        }
    }
}

actor AIObservationRecorder {
    static let sampleInterval: TimeInterval = 10
    static let maximumDuration: TimeInterval = 24 * 60 * 60

    private struct Metadata: Codable {
        let id: UUID
        let startedAt: Date
        var endedAt: Date?
        var state: AICaptureSessionState
    }

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private var activeSession: AICaptureSession?
    private var activeSamplesURL: URL?
    private var latestCompletedSession: AICaptureSession?

    init() {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        directoryURL = baseURL
            .appendingPathComponent("Fankit", isDirectory: true)
            .appendingPathComponent("AI", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func restore() throws -> (active: AICaptureSession?, latest: AICaptureSession?) {
        try ensureDirectory()

        let metadataURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "meta" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var active: AICaptureSession?
        var completed: [AICaptureSession] = []

        for metadataURL in metadataURLs {
            guard var session = try loadSession(metadataURL: metadataURL) else { continue }
            if session.state == .recording {
                if Date().timeIntervalSince(session.startedAt) >= Self.maximumDuration {
                    session.state = .completed
                    session.endedAt = session.startedAt.addingTimeInterval(Self.maximumDuration)
                    try saveMetadata(for: session)
                    completed.append(session)
                } else if active == nil {
                    active = session
                }
            } else if session.state == .completed {
                completed.append(session)
            }
        }

        activeSession = active
        activeSamplesURL = active.map(samplesURL(for:))
        latestCompletedSession = completed.max {
            ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt)
        }
        return (active, latestCompletedSession)
    }

    func startSession(now: Date = .now) throws -> AICaptureSession {
        try ensureDirectory()
        if let activeSession { return activeSession }

        let session = AICaptureSession(
            id: UUID(),
            startedAt: now,
            endedAt: nil,
            state: .recording,
            samples: []
        )
        let samplesFileURL = samplesURL(for: session)
        try Data().write(to: samplesFileURL, options: .atomic)
        try saveMetadata(for: session)
        activeSession = session
        activeSamplesURL = samplesFileURL
        return session
    }

    func append(_ sample: AICaptureSample) throws -> AICaptureSession {
        guard var session = activeSession, let samplesURL = activeSamplesURL else {
            throw AICaptureRecorderError.noActiveSession
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(sample)
        line.append(0x0A)

        let handle = try FileHandle(forWritingTo: samplesURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()

        session.samples.append(sample)
        if sample.timestamp.timeIntervalSince(session.startedAt) >= Self.maximumDuration {
            session.state = .completed
            session.endedAt = session.startedAt.addingTimeInterval(Self.maximumDuration)
            activeSession = nil
            activeSamplesURL = nil
            latestCompletedSession = session
        } else {
            activeSession = session
        }
        try saveMetadata(for: session)
        return session
    }

    func finishSession(now: Date = .now) throws -> AICaptureSession {
        guard var session = activeSession else {
            throw AICaptureRecorderError.noActiveSession
        }
        session.state = .completed
        session.endedAt = min(now, session.startedAt.addingTimeInterval(Self.maximumDuration))
        try saveMetadata(for: session)
        activeSession = nil
        activeSamplesURL = nil
        latestCompletedSession = session
        return session
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw AICaptureRecorderError.unavailable
        }
    }

    private func samplesURL(for session: AICaptureSession) -> URL {
        directoryURL.appendingPathComponent("\(session.id.uuidString).jsonl")
    }

    private func metadataURL(for session: AICaptureSession) -> URL {
        directoryURL.appendingPathComponent("\(session.id.uuidString).meta")
    }

    private func saveMetadata(for session: AICaptureSession) throws {
        let metadata = Metadata(
            id: session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            state: session.state
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL(for: session), options: .atomic)
    }

    private func loadSession(metadataURL: URL) throws -> AICaptureSession? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(Metadata.self, from: Data(contentsOf: metadataURL))
        let samplesURL = directoryURL.appendingPathComponent("\(metadata.id.uuidString).jsonl")
        guard fileManager.fileExists(atPath: samplesURL.path) else { return nil }

        let data = try Data(contentsOf: samplesURL)
        let samples = try String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> AICaptureSample? in
                guard !line.isEmpty else { return nil }
                return try? decoder.decode(AICaptureSample.self, from: Data(line.utf8))
            }

        return AICaptureSession(
            id: metadata.id,
            startedAt: metadata.startedAt,
            endedAt: metadata.endedAt,
            state: metadata.state,
            samples: samples
        )
    }
}
