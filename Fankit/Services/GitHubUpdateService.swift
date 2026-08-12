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
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(GitHubRelease.self, from: data)
            latestRelease = release
            let checkedAt = Date()
            lastCheckedAt = checkedAt
            defaults.set(checkedAt, forKey: PreferenceKey.lastUpdateCheck)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let cachedRelease = try? encoder.encode(release) {
                defaults.set(cachedRelease, forKey: PreferenceKey.cachedLatestRelease)
            }
        } catch {
            errorMessage = Self.localizedMessage(for: error)
        }
    }

    func downloadAndOpenUpdate() async {
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

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Fankit-\(release.version)-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            guard NSWorkspace.shared.open(destination) else {
                throw UpdateError.cannotOpenInstaller
            }
        } catch {
            errorMessage = Self.localizedMessage(for: error)
        }
    }

    func openReleasePage() {
        guard let latestRelease else { return }
        NSWorkspace.shared.open(latestRelease.htmlURL)
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive])
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
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode)
        else {
            throw UpdateError.invalidResponse
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func localizedMessage(for error: Error) -> String {
        if let error = error as? UpdateError {
            return L10n.string(error.localizationKey)
        }
        return error.localizedDescription
    }
}

private enum UpdateError: Error {
    case invalidResponse
    case checksumUnavailable
    case checksumMismatch
    case cannotOpenInstaller

    var localizationKey: String {
        switch self {
        case .invalidResponse:
            "GitHub returned an invalid update response."
        case .checksumUnavailable:
            "This release does not provide a SHA-256 checksum."
        case .checksumMismatch:
            "The downloaded update failed SHA-256 verification."
        case .cannotOpenInstaller:
            "Fankit could not open the downloaded installer."
        }
    }
}
