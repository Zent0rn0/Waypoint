import Foundation

// MARK: - Pool classes: services that should be served by the server that is best FOR THEM

public enum PoolClass: String, CaseIterable, Sendable, Codable, Hashable {
    case general, video, ai, chat

    public var title: String {
        switch self {
        case .general: return "Общий"
        case .video: return "Видео и музыка"
        case .ai: return "AI-сервисы"
        case .chat: return "Голос и мессенджеры"
        }
    }

    /// What the latency probe of this class fetches through every candidate server.
    public var testURL: String {
        switch self {
        case .general: return "https://www.gstatic.com/generate_204"
        case .video: return "https://www.youtube.com/generate_204"
        case .ai: return "https://chatgpt.com/cdn-cgi/trace"
        case .chat: return "https://discord.com/api/v9/gateway"
        }
    }
}

// MARK: - Services

public struct Service: Identifiable, Sendable, Hashable {
    public enum Group: String, Sendable, CaseIterable {
        case video = "Видео и музыка", social = "Соцсети", chat = "Голос и мессенджеры", ai = "AI и разработка"
        case work = "Работа", banks = "Банки и госсервисы", ru = "Российские сервисы"
    }
    public let id: String
    public let title: String
    public let symbol: String                 // SF Symbol
    public let group: Group
    public let pool: PoolClass
    /// What Waypoint does when the user has no opinion. nil = "auto": direct, learn from failures.
    /// These are hints for the default region (Russia); everything else is discovered by the racer.
    public let defaultRoute: Route?
    public let suffixes: [String]
    public let cidrs: [String]
    /// Names of native apps that belong to this service (for suggesting per-app rules).
    public let appNames: [String]

    init(_ id: String, _ title: String, _ symbol: String, _ group: Group, pool: PoolClass = .general, route: Route? = nil,
         _ suffixes: [String], cidrs: [String] = [], apps: [String] = []) {
        self.id = id; self.title = title; self.symbol = symbol; self.group = group; self.pool = pool
        self.defaultRoute = route; self.suffixes = suffixes; self.cidrs = cidrs; self.appNames = apps
    }
}

public enum Catalog {
    /// Official IPv4 ranges: https://core.telegram.org/resources/cidr.txt — Telegram clients connect to bare IPs and speak
    /// MTProto on ports 80/443, so only the address identifies them.
    public static let telegramCIDRs = [
        "91.105.192.0/23", "91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22", "91.108.16.0/22",
        "91.108.20.0/22", "91.108.56.0/22", "149.154.160.0/20", "185.76.151.0/24",
    ]

    /// Top-level domains and generic Russian suffixes that are direct by default in the Russian region.
    public static let russianTLDs = ["ru", "su", "xn--p1ai", "xn--80asehdb", "xn--d1acj3b"]

    public static let services: [Service] = [
        // — video & music
        Service("youtube", "YouTube", "play.rectangle.fill", .video, pool: .video, route: .vpn,
                ["youtube.com", "youtu.be", "googlevideo.com", "ytimg.com", "ggpht.com", "youtube-nocookie.com", "youtubekids.com", "youtubei.googleapis.com"],
                apps: ["YouTube"]),
        Service("tiktok", "TikTok", "music.note.tv.fill", .video, pool: .video, route: .vpn,
                ["tiktok.com", "tiktokv.com", "tiktokcdn.com", "tiktokcdn-us.com", "tiktokcdn-eu.com", "tiktokv.us", "tiktokw.us", "tiktokw.eu",
                 "tiktokapis.com", "byteoversea.com", "ibytedtos.com", "ibyteimg.com", "muscdn.com", "musical.ly", "tik-tokapi.com",
                 "ttwstatic.com", "ttoversea.net", "isnssdk.com", "sgsnssdk.com", "worldfcdn.com", "ttlivecdn.com"],
                apps: ["TikTok"]),
        Service("twitch", "Twitch", "gamecontroller.fill", .video, pool: .video, route: .vpn,
                ["twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net", "twitchsvc.net"], apps: ["Twitch"]),
        Service("netflix", "Netflix", "film.fill", .video, pool: .video, route: .vpn,
                ["netflix.com", "nflxvideo.net", "nflximg.net", "nflxext.com", "nflxso.net"], apps: ["Netflix"]),
        Service("spotify", "Spotify", "music.quarternote.3", .video, pool: .video, route: .vpn,
                ["spotify.com", "scdn.co", "spotifycdn.com"], apps: ["Spotify"]),
        Service("soundcloud", "SoundCloud", "waveform", .video, pool: .video, route: .vpn, ["soundcloud.com", "sndcdn.com"], apps: ["SoundCloud"]),
        // — social
        Service("instagram", "Instagram", "camera.fill", .social, route: .vpn, ["instagram.com", "cdninstagram.com", "instagr.am"], apps: ["Instagram"]),
        Service("facebook", "Facebook и Meta", "person.2.fill", .social, route: .vpn,
                ["facebook.com", "fbcdn.net", "fb.com", "fb.me", "messenger.com", "facebook.net", "threads.net", "threads.com"], apps: ["Facebook", "Messenger", "Threads"]),
        Service("x", "X (Twitter)", "at", .social, route: .vpn, ["twitter.com", "x.com", "twimg.com", "t.co"], apps: ["X", "Twitter"]),
        Service("linkedin", "LinkedIn", "briefcase.fill", .social, route: .vpn, ["linkedin.com", "licdn.com"], apps: ["LinkedIn"]),
        Service("reddit", "Reddit", "bubble.left.and.bubble.right.fill", .social, ["reddit.com", "redd.it", "redditstatic.com", "redditmedia.com"], apps: ["Reddit"]),
        Service("medium", "Medium", "text.book.closed.fill", .social, route: .vpn, ["medium.com"]),
        // — voice & messengers
        Service("discord", "Discord", "headphones", .chat, pool: .chat, route: .vpn,
                ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media", "discordcdn.com", "discordstatus.com", "discord.new", "discord.gift"],
                apps: ["Discord"]),
        Service("telegram", "Telegram", "paperplane.fill", .chat, pool: .chat, route: .vpn,
                ["telegram.org", "t.me", "telegram.me", "tdesktop.com", "telesco.pe", "cdn-telegram.org", "telegra.ph", "telegram.dog", "graph.org"],
                cidrs: telegramCIDRs, apps: ["Telegram", "AyuGram", "Telegram Lite"]),
        Service("whatsapp", "WhatsApp", "phone.bubble.fill", .chat, pool: .chat, route: .vpn, ["whatsapp.com", "whatsapp.net", "wa.me"], apps: ["WhatsApp"]),
        Service("signal", "Signal", "lock.shield.fill", .chat, pool: .chat, route: .vpn, ["signal.org", "signal.art", "whispersystems.org"], apps: ["Signal"]),
        // — AI & development
        Service("openai", "ChatGPT и OpenAI", "sparkles", .ai, pool: .ai, route: .vpn,
                ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "sora.com"], apps: ["ChatGPT"]),
        Service("anthropic", "Claude и Anthropic", "brain.head.profile", .ai, pool: .ai, route: .vpn,
                ["anthropic.com", "claude.ai", "claude.com", "claudeusercontent.com"], apps: ["Claude"]),
        Service("google-ai", "Gemini и Google AI", "wand.and.stars", .ai, pool: .ai, route: .vpn,
                ["gemini.google.com", "aistudio.google.com", "generativelanguage.googleapis.com", "bard.google.com", "notebooklm.google.com", "labs.google", "deepmind.google", "deepmind.com"]),
        Service("perplexity", "Perplexity", "magnifyingglass.circle.fill", .ai, pool: .ai, route: .vpn, ["perplexity.ai"], apps: ["Perplexity", "Comet"]),
        Service("ai-other", "Midjourney, Hugging Face, Mistral, xAI", "cpu.fill", .ai, pool: .ai, route: .vpn,
                ["midjourney.com", "huggingface.co", "hf.co", "mistral.ai", "x.ai", "grok.com"]),
        Service("dev-ai", "Cursor и Copilot", "chevron.left.forwardslash.chevron.right", .ai, pool: .ai,
                ["cursor.com", "cursor.sh", "githubcopilot.com"], apps: ["Cursor"]),
        Service("github", "GitHub", "cat.fill", .ai, ["github.com", "githubusercontent.com", "githubassets.com", "github.io", "ghcr.io"], apps: ["GitHub Desktop"]),
        // — work
        Service("notion", "Notion", "doc.text.fill", .work, route: .vpn, ["notion.so", "notion.site"], apps: ["Notion"]),
        Service("figma", "Figma", "pencil.and.ruler.fill", .work, route: .vpn, ["figma.com"], apps: ["Figma"]),
        Service("canva", "Canva, Grammarly, DeepL", "textformat", .work, route: .vpn, ["canva.com", "grammarly.com", "deepl.com"]),
        Service("speedtest", "Speedtest", "speedometer", .work, route: .vpn, ["speedtest.net", "ookla.com"]),
        // — banks & government: must see a local address
        Service("ru-gov", "Госуслуги и госсайты", "building.columns.fill", .banks, route: .direct,
                ["gosuslugi.ru", "mos.ru", "nalog.gov.ru", "nalog.ru", "gov.ru", "pfr.gov.ru", "sfr.gov.ru", "cbr.ru", "nspk.ru"]),
        Service("ru-banks", "Российские банки", "banknote.fill", .banks, route: .direct,
                ["sberbank.ru", "sber.ru", "sbrf.ru", "sberbank.com", "tbank.ru", "tinkoff.ru", "vtb.ru", "alfabank.ru", "raiffeisen.ru", "gazprombank.ru",
                 "psbank.ru", "sovcombank.ru", "mkb.ru", "open.ru", "rshb.ru", "pochtabank.ru", "uralsib.ru", "mironline.ru"]),
        // — Russian services: direct
        Service("ru-yandex", "Яндекс", "y.circle.fill", .ru, route: .direct,
                ["yandex.ru", "yandex.net", "yandex.com", "yandex.by", "yandex.kz", "yastatic.net", "ya.ru", "ya.cc", "yandexcloud.net", "dzen.ru", "kinopoisk.ru"], apps: ["Яндекс Музыка", "Yandex"]),
        Service("ru-vk", "ВКонтакте и Одноклассники", "person.crop.circle.fill", .ru, route: .direct,
                ["vk.com", "vk.ru", "vk.me", "vkuser.net", "userapi.com", "mycdn.me", "vkuseraudio.net", "vk-cdn.net", "ok.ru", "mail.ru"], apps: ["VK", "VK Мессенджер"]),
        Service("ru-market", "Маркетплейсы и сервисы", "cart.fill", .ru, route: .direct,
                ["ozon.ru", "wildberries.ru", "wb.ru", "wbstatic.net", "avito.ru", "avito.st", "2gis.ru", "2gis.com", "hh.ru", "rutube.ru", "rzd.ru", "aeroflot.ru", "tutu.ru"]),
        Service("ru-telecom", "Операторы связи", "antenna.radiowaves.left.and.right", .ru, route: .direct, ["mts.ru", "megafon.ru", "beeline.ru", "tele2.ru", "rt.ru"]),
    ]

    public static func service(_ id: String) -> Service? { services.first { $0.id == id } }
}

// MARK: - Playbooks ("scenarios"): one switch that sets many rules at once

public struct Playbook: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let vpn: [String]            // service ids forced through the VPN
    public let direct: [String]         // service ids forced direct
    public let appHints: [String]       // app names for which a per-app VPN rule is suggested
    public let udpViaVPN: Bool
    public let finalMode: FinalMode?
    public let regionOverride: Region?
    /// Details shown in the UI so the effect is never a black box.
    public let details: String

    public static let all: [Playbook] = [
        Playbook(id: "tiktok", title: "TikTok — свежая лента", subtitle: "Все домены TikTok и приложение — только через VPN",
                 symbol: "music.note.tv.fill", vpn: ["tiktok"], direct: [], appHints: ["TikTok"], udpViaVPN: false, finalMode: nil, regionOverride: nil,
                 details: "TikTok определяет регион по адресу, с которого пришёл запрос. Если хоть часть запросов (API, CDN, видео) уйдёт напрямую через российского провайдера, лента остаётся старой или урезанной. Сценарий отправляет через VPN ВСЕ домены TikTok (выше выученного и списков) и, если приложение установлено, весь его трафик по процессу — даже к доменам, которых нет в списках. Ярлык «Диагностика → TikTok» показывает, какой регион видит сайт."),
        Playbook(id: "strict-ru", title: "Банки и госсервисы — только напрямую", subtitle: "Никакого VPN для банков, Госуслуг и налоговой",
                 symbol: "building.columns.fill", vpn: [], direct: ["ru-gov", "ru-banks", "ru-market", "ru-telecom", "ru-yandex", "ru-vk"], appHints: [], udpViaVPN: false, finalMode: nil, regionOverride: nil,
                 details: "Эти сервисы ставятся выше выученного и списков блокировок: даже если Waypoint по ошибке выучит домен как «заблокированный», банк не пойдёт через чужой адрес."),
        Playbook(id: "media", title: "Видео и музыка", subtitle: "YouTube, Twitch, Netflix, Spotify, SoundCloud — через VPN",
                 symbol: "play.rectangle.fill", vpn: ["youtube", "twitch", "netflix", "spotify", "soundcloud"], direct: [], appHints: ["Spotify", "Twitch"], udpViaVPN: false, finalMode: nil, regionOverride: nil,
                 details: "Для этой группы сервер подбирается отдельно по скорости до YouTube (если добавлено несколько серверов)."),
        Playbook(id: "social", title: "Соцсети", subtitle: "Instagram, Facebook, X, LinkedIn, Reddit, Medium — через VPN",
                 symbol: "person.2.fill", vpn: ["instagram", "facebook", "x", "linkedin", "reddit", "medium"], direct: [], appHints: [], udpViaVPN: false, finalMode: nil, regionOverride: nil,
                 details: "Принудительно поверх выученного и списков."),
        Playbook(id: "voice", title: "Голос, звонки и игры", subtitle: "Discord, Telegram, WhatsApp, Signal + весь неопознанный UDP через VPN",
                 symbol: "headphones", vpn: ["discord", "telegram", "whatsapp", "signal"], direct: [], appHints: ["Discord", "Telegram", "WhatsApp", "Signal"], udpViaVPN: true, finalMode: nil, regionOverride: nil,
                 details: "У голосового трафика (UDP) нет имени сайта, по которому можно решить маршрут, поэтому включается весь неопознанный UDP. Для этой группы отдельный выбор сервера по задержке."),
        Playbook(id: "ai", title: "AI и разработка", subtitle: "ChatGPT, Claude, Gemini, Perplexity, Cursor — через VPN",
                 symbol: "sparkles", vpn: ["openai", "anthropic", "google-ai", "perplexity", "ai-other", "dev-ai"], direct: [], appHints: ["ChatGPT", "Claude", "Cursor"], udpViaVPN: false, finalMode: nil, regionOverride: nil,
                 details: "Многие AI-сервисы ограничивают регионы на своей стороне: соединение проходит, а отказ приходит уже в HTTP. Поэтому они не определяются автоматически и включаются здесь принудительно."),
        Playbook(id: "lockdown", title: "Публичный Wi‑Fi: всё через VPN", subtitle: "Всё, кроме локальной сети и банков, — через VPN",
                 symbol: "lock.shield.fill", vpn: [], direct: [], appHints: [], udpViaVPN: true, finalMode: .allVPN, regionOverride: nil,
                 details: "Максимальная защита: в открытой сети провайдер Wi‑Fi не видит ничего, кроме канала до VPN. Российские банки и Госуслуги остаются напрямую. Если VPN недоступен, туннель выключается — и вы снова онлайн без защиты (fail-open), а не остаётесь без сети."),
        Playbook(id: "saver", title: "Экономия трафика VPN", subtitle: "Через VPN только заведомо нужное, без проб на незнакомых сайтах",
                 symbol: "leaf.fill", vpn: [], direct: [], appHints: [], udpViaVPN: false, finalMode: .savings, regionOverride: nil,
                 details: "Незнакомые сайты идут напрямую без гонки (не тратится квота VPN на пробы). Заблокированное, что не в списках, придётся добавить вручную или включить обычный режим."),
        Playbook(id: "abroad", title: "Я за границей", subtitle: "Стартовые списки выключены, всё напрямую",
                 symbol: "airplane", vpn: [], direct: [], appHints: [], udpViaVPN: false, finalMode: nil, regionOverride: Region.none,
                 details: "За пределами России блокировок нет — VPN не нужен. Российские банки могут не пускать с иностранного адреса; для этого нужен сервер в России."),
    ]

    public static func playbook(_ id: String) -> Playbook? { all.first { $0.id == id } }
}

public enum FinalMode: String, Codable, Sendable { case auto, allVPN, savings }
