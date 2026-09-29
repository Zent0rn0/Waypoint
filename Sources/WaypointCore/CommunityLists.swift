import Foundation

/// Public, community-maintained rule lists (compiled sing-box `.srs`). They only ever change *routing*; they are opt-in,
/// downloaded by the app (never by the root daemon) and checked (magic + sing-box `check`) before use.
public struct CommunityList: Sendable, Identifiable, Hashable {
    public enum Role: Hashable, Sendable {
        case vpn(PoolClass)      // blocked / restricted: through the VPN
        case directStrict        // services that only work from a local address: direct, above anything learned
        case direct              // ordinary local sites / addresses: direct
    }
    public let id: String        // rule-set tag, e.g. "c-ru-blocked"
    public let title: String
    public let path: String      // inside the release branch
    public let role: Role
    public var file: String { id + ".srs" }

    public static let base = "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/"
    public static let mirror = "https://cdn.jsdelivr.net/gh/runetfreedom/russia-v2ray-rules-dat@release/sing-box/"
    public var url: String { Self.base + path }
    public var mirrorURL: String { Self.mirror + path }

    static func gs(_ n: String) -> String { "rule-set-geosite/geosite-\(n).srs" }
    static func gi(_ n: String) -> String { "rule-set-geoip/geoip-\(n).srs" }

    public static let all: [CommunityList] = [
        CommunityList(id: "c-ru-inside", title: "Сервисы, доступные только из РФ", path: gs("ru-available-only-inside"), role: .directStrict),
        CommunityList(id: "c-bank-ru", title: "Российские банки", path: gs("category-bank-ru"), role: .directStrict),
        CommunityList(id: "c-ru-blocked", title: "Заблокированные в РФ (домены)", path: gs("ru-blocked"), role: .vpn(.general)),
        CommunityList(id: "c-ru-blocked-ip", title: "Заблокированные в РФ (IP)", path: gi("ru-blocked"), role: .vpn(.general)),
        CommunityList(id: "c-telegram", title: "Telegram (домены)", path: gs("telegram"), role: .vpn(.chat)),
        CommunityList(id: "c-telegram-ip", title: "Telegram (IP)", path: gi("telegram"), role: .vpn(.chat)),
        CommunityList(id: "c-discord", title: "Discord", path: gs("discord"), role: .vpn(.chat)),
        CommunityList(id: "c-whatsapp", title: "WhatsApp", path: gs("whatsapp"), role: .vpn(.chat)),
        CommunityList(id: "c-youtube", title: "YouTube и Google Video", path: gs("youtube"), role: .vpn(.video)),
        CommunityList(id: "c-tiktok", title: "TikTok", path: gs("tiktok"), role: .vpn(.video)),
        CommunityList(id: "c-spotify", title: "Spotify", path: gs("spotify"), role: .vpn(.video)),
        CommunityList(id: "c-netflix", title: "Netflix", path: gs("netflix"), role: .vpn(.video)),
        CommunityList(id: "c-openai", title: "OpenAI", path: gs("openai"), role: .vpn(.ai)),
        CommunityList(id: "c-anthropic", title: "Anthropic", path: gs("anthropic"), role: .vpn(.ai)),
        CommunityList(id: "c-perplexity", title: "Perplexity", path: gs("perplexity"), role: .vpn(.ai)),
        CommunityList(id: "c-instagram", title: "Instagram", path: gs("instagram"), role: .vpn(.general)),
        CommunityList(id: "c-facebook", title: "Facebook и Meta", path: gs("facebook"), role: .vpn(.general)),
        CommunityList(id: "c-twitter", title: "X (Twitter)", path: gs("twitter"), role: .vpn(.general)),
        CommunityList(id: "c-ru-category", title: "Российские сайты", path: gs("category-ru"), role: .direct),
        CommunityList(id: "c-ru-ip", title: "IP-адреса России", path: gi("ru"), role: .direct),
    ]

    /// Every compiled sing-box rule-set starts with these three bytes.
    public static func hasValidMagic(_ d: Data) -> Bool { d.count > 8 && d.prefix(3) == Data([0x53, 0x52, 0x53]) }
}
