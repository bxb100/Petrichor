import Foundation

actor SourceRegistry {
    static let shared = SourceRegistry()

    private let providers: [SourceKind: any SourceProvider]

    init(
        providers: [any SourceProvider] = [
            EmbyProvider(),
            NavidromeProvider()
        ]
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    func provider(for kind: SourceKind) -> (any SourceProvider)? {
        providers[kind]
    }
}
