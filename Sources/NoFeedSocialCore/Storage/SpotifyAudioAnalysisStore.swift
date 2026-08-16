import Foundation

public struct SpotifyAudioAnalysisStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "spotifyAudioAnalysisByTrack") {
        self.defaults = defaults
        self.key = key
    }

    public func cachedAnalysis(for trackId: String) -> MusicAnimationMetadata? {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONDecoder().decode([String: MusicAnimationMetadata].self, from: data)
        else {
            return nil
        }
        return all[trackId]
    }

    public func cacheAnalysis(_ analysis: MusicAnimationMetadata, for trackId: String) {
        var all: [String: MusicAnimationMetadata] = [:]
        if let data = defaults.data(forKey: key) {
            all = (try? JSONDecoder().decode([String: MusicAnimationMetadata].self, from: data)) ?? [:]
        }
        all[trackId] = analysis
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }
}
