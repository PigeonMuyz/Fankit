import AppKit
import CryptoKit
import Foundation
import Observation

struct GitHubRelease: Codable, Sendable {
    struct Asset: Codable, Identifiable, Sendable {
        let id: Int
        let name: String
        let digest: String?
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    var version: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    var diskImage: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    var checksumAsset: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg.sha256") }
    }
}

@MainActor
@Observable
final class GitHubUpdateService {
    private(set) var latestRelease: GitHubRelease?
    private(set) var isChecking = false
    private(set) var isDownloading = false
    private(set) var errorMessage: String?
    private(set) var lastCheckedAt: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fanControl = FanControlService()
    @ObservationIgnored private let releasesEndpoint = URL(
        string: "https://api.github.com/repos/PigeonMuyz/Fankit/releases/latest"
    )!

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastCheckedAt = defaults.object(forKey: PreferenceKey.lastUpdateCheck) as? Date
        if let data = defaults.data(forKey: PreferenceKey.cachedLatestRelease) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            latestRelease = try? decoder.decode(GitHubRelease.self, from: data)
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isUpdateAvailable: Bool {
        guard let latestRelease else { return false }
        return Self.compareVersions(latestRelease.version, currentVersion) == .orderedDescending
    }

    func checkForUpdatesAtLaunch() async {
        guard defaults.bool(forKey: PreferenceKey.automaticallyCheckForUpdates) else { return }
        if defaults.bool(forKey: PreferenceKey.checkForUpdatesAtEveryLaunch) {
            await checkForUpdates()
        } else {
            await checkForUpdatesIfNeeded()
        }
    }

    func checkForUpdatesIfNeeded() async {
        guard defaults.bool(forKey: PreferenceKey.automaticallyCheckForUpdates) else { return }
        if let lastCheck = defaults.object(forKey: PreferenceKey.lastUpdateCheck) as? Date,
           Date().timeIntervalSince(lastCheck) < 12 * 60 * 60
        {
            lastCheckedAt = lastCheck
            return
        }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        do {
            var request = URLRequest(url: releasesEndpoint)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Fankit/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            if let token = defaults.string(forKey: PreferenceKey.githubAPIToken)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty
            {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let etag = defaults.string(forKey: PreferenceKey.cachedLatestReleaseETag) {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            if let response = response as? HTTPURLResponse,
               response.statusCode == 304,
               latestRelease != nil
            {
                recordSuccessfulCheck()
                return
            }
            try Self.validate(response)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(GitHubRelease.self, from: data)
            latestRelease = release
            recordSuccessfulCheck()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let cachedRelease = try? encoder.encode(release) {
                defaults.set(cachedRelease, forKey: PreferenceKey.cachedLatestRelease)
            }
            if let response = response as? HTTPURLResponse,
               let etag = response.value(forHTTPHeaderField: "ETag")
            {
                defaults.set(etag, forKey: PreferenceKey.cachedLatestReleaseETag)
            }
        } catch {
            errorMessage = Self.localizedMessage(for: error)
        }
    }

    func downloadAndInstallUpdate() async {
        guard !isDownloading, let release = latestRelease else { return }
        guard let diskImage = release.diskImage else {
            errorMessage = L10n.string("This release does not include a DMG installer.")
            return
        }
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }

        do {
            let expectedChecksum = try await expectedChecksum(for: diskImage, release: release)
            let (temporaryURL, response) = try await URLSession.shared.download(from: diskImage.browserDownloadURL)
            try Self.validate(response)
            let actualChecksum = try Self.sha256(of: temporaryURL)
            guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
                throw UpdateError.checksumMismatch
            }

            let diskImageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Fankit-\(release.version)-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: temporaryURL, to: diskImageURL)
            defer { try? FileManager.default.removeItem(at: diskImageURL) }

            guard let teamIdentifier = FanControlCodeSigning.teamIdentifier() else {
                throw UpdateError.cannotVerifyInstaller
            }
            let bundleIdentifier = FanControlHelperConstants.appBundleIdentifier
            let codeSigningRequirement = FanControlCodeSigning.requirement(
                identifier: bundleIdentifier,
                teamIdentifier: teamIdentifier
            )
            let releaseVersion = release.version
            let installedVersion = currentVersion
            let installedAppURL = Bundle.main.bundleURL
            var installationResult: AppUpdateInstallationResult?
            let helperSupportsInPlaceUpdates = Self.compareVersions(
                installedVersion,
                "1.0.13"
            ) != .orderedAscending

            // New helpers perform the replacement as root, so the running app
            // never needs to make /Applications writable or open a DMG for the
            // user. Older helpers do not know this XPC method; keep a bridge for
            // them below so the first update can still finish automatically.
            if helperSupportsInPlaceUpdates {
                do {
                    try await fanControl.installUpdate(
                        diskImageURL: diskImageURL,
                        currentAppURL: installedAppURL,
                        releaseVersion: releaseVersion
                    )
                    installationResult = .installed(installedAppURL)
                } catch {
                    NSLog("Fankit helper update path unavailable; trying compatibility paths: %@", error.localizedDescription)
                }
            }
            if installationResult == nil {
                try await fanControl.prepareForAppUpdate()
                installationResult = try await Task.detached {
                    try AppUpdateInstaller.install(
                        diskImageURL: diskImageURL,
                        releaseVersion: releaseVersion,
                        currentVersion: installedVersion,
                        currentAppURL: installedAppURL,
                        bundleIdentifier: bundleIdentifier,
                        codeSigningRequirement: codeSigningRequirement
                    )
                }.value
            }

            if case .requiresAdministratorAuthorization = installationResult {
                // A standard-user installation cannot replace /Applications on
                // its own. Run the already verified, same-team helper from the
                // downloaded app with macOS administrator authorization instead
                // of opening the DMG and asking the user to copy files.
                try await Task.detached {
                    try AppUpdateInstaller.installUsingAdministratorPrivileges(
                        diskImageURL: diskImageURL,
                        releaseVersion: releaseVersion,
                        currentVersion: installedVersion,
                        currentAppURL: installedAppURL,
                        bundleIdentifier: bundleIdentifier,
                        codeSigningRequirement: codeSigningRequirement
                    )
                }.value
                installationResult = .installed(installedAppURL)
            }

            guard case .installed(let appURL) = installationResult else {
                throw UpdateError.installationFailed
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            try await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            )
            NSApp.terminate(nil)
        } catch {
            errorMessage = Self.localizedMessage(for: error)
        }
    }

    func openReleasePage() {
        guard let latestRelease else { return }
        NSWorkspace.shared.open(latestRelease.htmlURL)
    }

    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }

    private func recordSuccessfulCheck() {
        let checkedAt = Date()
        lastCheckedAt = checkedAt
        defaults.set(checkedAt, forKey: PreferenceKey.lastUpdateCheck)
    }

    private func expectedChecksum(
        for diskImage: GitHubRelease.Asset,
        release: GitHubRelease
    ) async throws -> String {
        if let digest = diskImage.digest,
           digest.lowercased().hasPrefix("sha256:")
        {
            return String(digest.dropFirst("sha256:".count))
        }

        guard let checksumAsset = release.checksumAsset else {
            throw UpdateError.checksumUnavailable
        }
        let (data, response) = try await URLSession.shared.data(from: checksumAsset.browserDownloadURL)
        try Self.validate(response)
        guard let text = String(data: data, encoding: .utf8),
              let checksum = text.split(whereSeparator: \.isWhitespace).first,
              checksum.count == 64
        else {
            throw UpdateError.checksumUnavailable
        }
        return String(checksum)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw UpdateError.invalidAPIToken
            }
            let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            if response.statusCode == 429 || (response.statusCode == 403 && remaining == "0") {
                throw UpdateError.rateLimited
            }
            throw UpdateError.httpFailure(response.statusCode)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func localizedMessage(for error: Error) -> String {
        if let error = error as? UpdateError {
            return error.localizedMessage
        }
        if error is AppUpdateInstallationError {
            return L10n.string("Fankit could not verify or install the update safely.")
        }
        return error.localizedDescription
    }
}

private enum UpdateError: Error {
    case invalidResponse
    case invalidAPIToken
    case rateLimited
    case httpFailure(Int)
    case checksumUnavailable
    case checksumMismatch
    case installationFailed
    case cannotVerifyInstaller

    var localizedMessage: String {
        switch self {
        case .invalidResponse:
            L10n.string("GitHub returned an invalid update response.")
        case .invalidAPIToken:
            L10n.string("GitHub rejected the API token. Check or remove it in Update Settings.")
        case .rateLimited:
            L10n.string("GitHub update checks are temporarily rate limited. Try again later.")
        case .httpFailure(let statusCode):
            L10n.format("GitHub update request failed (HTTP %@).", String(statusCode))
        case .checksumUnavailable:
            L10n.string("This release does not provide a SHA-256 checksum.")
        case .checksumMismatch:
            L10n.string("The downloaded update failed SHA-256 verification.")
        case .installationFailed:
            L10n.string("Fankit could not install the update automatically.")
        case .cannotVerifyInstaller:
            L10n.string("Fankit could not verify that the update was signed by the same developer team.")
        }
    }
}
