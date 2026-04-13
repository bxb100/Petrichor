import Foundation

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesSearchResult]
}

private struct ITunesSearchResult: Decodable {
    let artworkUrl100: String?
    let artworkUrl60: String?
}

private struct ITunesArtworkQuery: Hashable {
    let term: String
    let entity: String
    let country: String
}

actor ITunesArtworkService {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var artworkURLCache: [ITunesArtworkQuery: URL?] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func downloadArtworkData(for item: EmbyAudioItem, fallbackTrack: FullTrack?) async -> Data? {
        let queries = buildQueries(for: item, fallbackTrack: fallbackTrack)
        guard !queries.isEmpty else { return nil }

        for query in queries {
            guard let artworkURL = await artworkURL(for: query) else { continue }

            do {
                let (data, response) = try await session.data(from: artworkURL)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      !data.isEmpty else {
                    continue
                }

                if let compressed = ImageUtils.compressImage(from: data, source: "iTunes/\(query.entity)") {
                    return compressed
                }

                return ImageUtils.validatedImageData(from: data, source: "iTunes/\(query.entity)")
            } catch {
                Logger.warning("Failed to download iTunes artwork for '\(query.term)': \(error)")
            }
        }

        return nil
    }
}

private extension ITunesArtworkService {
    func artworkURL(for query: ITunesArtworkQuery) async -> URL? {
        if let cached = artworkURLCache[query] {
            return cached
        }

        let resolvedURL = await searchArtworkURL(for: query)
        artworkURLCache[query] = resolvedURL
        return resolvedURL
    }

    func searchArtworkURL(for query: ITunesArtworkQuery) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query.term),
            URLQueryItem(name: "entity", value: query.entity),
            URLQueryItem(name: "country", value: query.country),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components?.url else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let searchResponse = try decoder.decode(ITunesSearchResponse.self, from: data)
            guard let result = searchResponse.results.first else {
                return nil
            }

            if let artworkURL = upgradedArtworkURL(from: result.artworkUrl100 ?? result.artworkUrl60) {
                return artworkURL
            }
        } catch {
            Logger.warning("Failed to query iTunes artwork for '\(query.term)': \(error)")
        }

        return nil
    }

    func buildQueries(for item: EmbyAudioItem, fallbackTrack: FullTrack?) -> [ITunesArtworkQuery] {
        let country = Locale.current.region?.identifier.lowercased() ?? "us"

        let album = normalizedValue(item.album)
            ?? normalizedValue(fallbackTrack?.album)
        let title = normalizedValue(item.name)
            ?? normalizedValue(fallbackTrack?.title)
        let artist = normalizedValue(item.albumArtist)
            ?? normalizedValue(item.albumArtists?.compactMap(\.name).first)
            ?? normalizedValue(item.artists?.first)
            ?? normalizedValue(item.artistItems?.compactMap(\.name).first)
            ?? normalizedValue(fallbackTrack?.albumArtist)
            ?? normalizedPrimaryName(from: fallbackTrack?.artist)

        var queries: [ITunesArtworkQuery] = []

        if let artist, let album {
            queries.append(ITunesArtworkQuery(term: "\(artist) \(album)", entity: "album", country: country))
        }

        if let album {
            queries.append(ITunesArtworkQuery(term: album, entity: "album", country: country))
        }

        if let artist, let title {
            queries.append(ITunesArtworkQuery(term: "\(artist) \(title)", entity: "song", country: country))
        }

        if let title {
            queries.append(ITunesArtworkQuery(term: title, entity: "song", country: country))
        }

        var uniqueQueries = Set<ITunesArtworkQuery>()
        return queries.filter { uniqueQueries.insert($0).inserted }
    }

    func normalizedValue(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("Unknown ") else { return nil }
        return trimmed
    }

    func normalizedPrimaryName(from rawValue: String?) -> String? {
        guard let normalized = normalizedValue(rawValue) else { return nil }

        let separators = [";", ",", "&", " feat. ", " ft. "]
        for separator in separators {
            if let first = normalized.components(separatedBy: separator).first {
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return normalized
    }

    func upgradedArtworkURL(from rawValue: String?) -> URL? {
        guard let rawValue, !rawValue.isEmpty else { return nil }

        let upgradedValue = rawValue
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "60x60bb", with: "600x600bb")

        return URL(string: upgradedValue)
    }
}
