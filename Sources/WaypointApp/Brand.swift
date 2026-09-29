import SwiftUI
import WaypointCore

// Each scenario and service has its own color, like the categories in System Settings.

extension Playbook {
    var color: Color {
        switch id {
        case "tiktok": Color(red: 1.00, green: 0.17, blue: 0.40)
        case "media": .red
        case "social": .blue
        case "ai": .purple
        case "voice": .teal
        case "strict-ru": .green
        case "lockdown": .orange
        case "saver": .mint
        case "abroad": .cyan
        default: .gray
        }
    }
    var icon: String {
        switch id {
        case "tiktok": "music.note"
        case "media": "play.rectangle.fill"
        case "social": "person.2.fill"
        case "ai": "sparkles"
        case "voice": "phone.fill"
        case "strict-ru": "building.columns.fill"
        case "lockdown": "wifi.exclamationmark"
        case "saver": "leaf.fill"
        case "abroad": "airplane"
        default: symbol
        }
    }
    /// Short effect description shown under the title.
    var effect: String {
        switch id {
        case "voice": "Discord, Telegram, WhatsApp, Signal и весь трафик звонков и игр — через VPN"
        default: subtitle
        }
    }

    static let groups: [(title: String, ids: [String])] = [
        ("Сервисы", ["tiktok", "media", "social", "ai", "voice"]),
        ("Надёжность", ["strict-ru"]),
        ("Режимы работы", ["lockdown", "saver", "abroad"]),
    ]
}

extension Service {
    var color: Color {
        switch id {
        case "youtube": Color(red: 1.0, green: 0.0, blue: 0.0)
        case "tiktok": Color(red: 1.0, green: 0.17, blue: 0.40)
        case "twitch": Color(red: 0.57, green: 0.27, blue: 1.0)
        case "netflix": Color(red: 0.78, green: 0.03, blue: 0.10)
        case "spotify": Color(red: 0.11, green: 0.73, blue: 0.33)
        case "soundcloud": Color(red: 1.0, green: 0.45, blue: 0.0)
        case "instagram": Color(red: 0.88, green: 0.19, blue: 0.45)
        case "facebook": Color(red: 0.09, green: 0.47, blue: 0.95)
        case "x": Color(white: 0.18)
        case "linkedin": Color(red: 0.04, green: 0.40, blue: 0.76)
        case "reddit": Color(red: 1.0, green: 0.27, blue: 0.0)
        case "medium": Color(white: 0.25)
        case "discord": Color(red: 0.35, green: 0.40, blue: 0.95)
        case "telegram": Color(red: 0.16, green: 0.63, blue: 0.90)
        case "whatsapp": Color(red: 0.15, green: 0.83, blue: 0.40)
        case "signal": Color(red: 0.23, green: 0.46, blue: 0.94)
        case "openai": Color(red: 0.06, green: 0.64, blue: 0.50)
        case "anthropic": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "google-ai": Color(red: 0.26, green: 0.52, blue: 0.96)
        case "perplexity": Color(red: 0.13, green: 0.55, blue: 0.60)
        case "ai-other": .indigo
        case "dev-ai": Color(white: 0.22)
        case "github": Color(white: 0.2)
        case "notion": Color(white: 0.3)
        case "figma": Color(red: 0.64, green: 0.35, blue: 1.0)
        case "canva": Color(red: 0.0, green: 0.77, blue: 0.80)
        case "speedtest": Color(red: 0.08, green: 0.14, blue: 0.30)
        case "ru-gov": Color(red: 0.0, green: 0.40, blue: 0.80)
        case "ru-banks": Color(red: 0.13, green: 0.63, blue: 0.29)
        case "ru-yandex": Color(red: 0.99, green: 0.24, blue: 0.16)
        case "ru-vk": Color(red: 0.0, green: 0.47, blue: 1.0)
        case "ru-market": Color(red: 0.55, green: 0.20, blue: 0.85)
        case "ru-telecom": Color(red: 0.90, green: 0.10, blue: 0.20)
        default: .gray
        }
    }
}
