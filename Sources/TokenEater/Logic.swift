import CommonCrypto
import Foundation

struct WindowQuota: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var remainingPercent: Int
    var resetsAt: Date?
}

struct ProviderQuota: Equatable, Sendable {
    var name: String
    var plan: String?
    var account: String? = nil
    var windows: [WindowQuota]
    var message: String?

    static func loading(_ name: String) -> ProviderQuota {
        ProviderQuota(name: name, plan: nil, windows: [], message: "正在读取")
    }

    static func unavailable(_ name: String, _ message: String) -> ProviderQuota {
        ProviderQuota(name: name, plan: nil, windows: [], message: message)
    }
}

enum OfficialLogin {
    static func gptURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host?.lowercased() else {
            return nil
        }
        if host == "auth.openai.com" || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") {
            return url
        }
        return nil
    }

    static func needsOfficialLogin(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.contains("登录")
    }
}

enum QuotaMath {
    static func remaining(usedPercent: Double) -> Int {
        let used = Int(usedPercent.rounded())
        return min(100, max(0, 100 - used))
    }

    static func windowLabel(minutes: Int?) -> String {
        switch minutes {
        case 300, 180:
            return "5 小时"
        case 10080:
            return "每周"
        case 43200:
            return "每月"
        case let minutes? where minutes > 0:
            if minutes % 1440 == 0 {
                return "\(minutes / 1440) 天"
            }
            if minutes % 60 == 0 {
                return "\(minutes / 60) 小时"
            }
            return "\(minutes) 分钟"
        default:
            return "额度"
        }
    }

    static func resetText(until date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "即将重置" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(minutes, 1)) 分钟后重置" }
        let hours = minutes / 60
        let remainMinutes = minutes % 60
        if hours < 48 {
            if remainMinutes == 0 { return "\(hours) 小时后重置" }
            return "\(hours) 小时 \(remainMinutes) 分钟后重置"
        }
        let days = hours / 24
        let remainHours = hours % 24
        if remainHours == 0 { return "\(days) 天后重置" }
        return "\(days) 天 \(remainHours) 小时后重置"
    }

    static func displayPlan(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "pro", "prolite", "pro_lite", "pro-lite":
            return "Pro"
        case "plus":
            return "Plus"
        case "team":
            return "Team"
        case "free":
            return "Free"
        case "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        case "premium", "premium+":
            return "Premium"
        default:
            if raw.count > 18 { return String(raw.prefix(18)) }
            return raw
        }
    }

    static func parseResetDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

enum CodexParser {
    static func parse(result: [String: Any]) -> ProviderQuota {
        let limits = result["rateLimits"] as? [String: Any]
        let plan = QuotaMath.displayPlan(limits?["planType"] as? String)
        var windows: [WindowQuota] = []
        if let primary = window(limits?["primary"], fallbackID: "primary") {
            windows.append(primary)
        }
        if let secondary = window(limits?["secondary"], fallbackID: "secondary") {
            windows.append(secondary)
        }
        windows.sort { lhs, rhs in
            let left = lhs.resetsAt?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            let right = rhs.resetsAt?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            if left == right { return lhs.remainingPercent < rhs.remainingPercent }
            return left < right
        }
        if windows.isEmpty {
            return .unavailable("GPT", "这次没有读到额度窗口")
        }
        return ProviderQuota(name: "GPT", plan: plan, windows: windows, message: nil)
    }

    private static func window(_ raw: Any?, fallbackID: String) -> WindowQuota? {
        guard let raw = raw as? [String: Any] else { return nil }
        guard let used = number(raw["usedPercent"]) else { return nil }
        let minutes = number(raw["windowDurationMins"]).map { Int($0.rounded()) }
        let resets = number(raw["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
        let label = QuotaMath.windowLabel(minutes: minutes)
        return WindowQuota(
            id: "\(label)-\(fallbackID)",
            label: label,
            remainingPercent: QuotaMath.remaining(usedPercent: used),
            resetsAt: resets
        )
    }

    static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }
}

enum GrokBillingParser {
    static func parse(body: [String: Any]) -> ProviderQuota? {
        guard let config = body["config"] as? [String: Any] else { return nil }
        guard let used = CodexParser.number(config["creditUsagePercent"]) else { return nil }
        let period = config["currentPeriod"] as? [String: Any]
        let endRaw = (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        let resets = endRaw.flatMap(QuotaMath.parseResetDate)
        let kind = (period?["type"] as? String) ?? ""
        let label: String
        if kind.contains("MONTH") {
            label = "每月"
        } else if kind.contains("WEEK") || resets == nil {
            label = "每周"
        } else {
            label = "每周"
        }
        let window = WindowQuota(
            id: "grok-\(label)",
            label: label,
            remainingPercent: QuotaMath.remaining(usedPercent: used),
            resetsAt: resets
        )
        return ProviderQuota(name: "Grok", plan: "Premium", windows: [window], message: nil)
    }
}

enum GrokBotParser {
    static func parse(body: [String: Any]) -> ProviderQuota {
        guard let used = CodexParser.number(body["usagePercent"]) else {
            return .unavailable("Grok", "返回里没有用量")
        }
        let resets = (body["nextResetTimestampUtc"] as? String).flatMap(QuotaMath.parseResetDate)
        let plan = QuotaMath.displayPlan(body["grokPlanLabel"] as? String) ?? "Grok Bot"
        let window = WindowQuota(
            id: "grokbot-week",
            label: "每周",
            remainingPercent: QuotaMath.remaining(usedPercent: used),
            resetsAt: resets
        )
        return ProviderQuota(name: "Grok", plan: plan, windows: [window], message: nil)
    }

    /// The Mac app stores this object as a JSON string. Linux stores the object itself.
    static func accountsObject(in root: [String: Any]) -> [String: Any]? {
        switch root["cursor-accounts"] {
        case let object as [String: Any]:
            return object
        case let text as String:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        default:
            return nil
        }
    }
}

enum OSCrypt {
    static func deriveKey(secret: Data) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status: CCCryptorStatus = key.withUnsafeMutableBytes { keyBuffer in
            secret.withUnsafeBytes { secretBuffer in
                guard let password = secretBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                      let derived = keyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return CCCryptorStatus(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password,
                    secret.count,
                    salt,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    derived,
                    kCCKeySizeAES128
                )
            }
        }
        return status == CCCryptorStatus(kCCSuccess) ? key : nil
    }

    static func decrypt(blob: String, key: Data) -> String? {
        guard let packed = Data(base64Encoded: blob), packed.count > 3 else { return nil }
        let prefix = packed.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else { return nil }
        let cipher = packed.dropFirst(3)
        guard !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0 else { return nil }
        let outputCount = cipher.count + kCCBlockSizeAES128
        var output = Data(count: outputCount)
        var moved = 0
        let iv = Array(repeating: UInt8(0x20), count: kCCBlockSizeAES128)
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuffer in
            cipher.withUnsafeBytes { cipherBuffer in
                key.withUnsafeBytes { keyBuffer in
                    guard let out = outBuffer.baseAddress,
                          let input = cipherBuffer.baseAddress,
                          let keyBytes = keyBuffer.baseAddress else {
                        return CCCryptorStatus(kCCParamError)
                    }
                    return CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes,
                        kCCKeySizeAES128,
                        iv,
                        input,
                        cipher.count,
                        out,
                        outputCount,
                        &moved
                    )
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), moved > 0 else { return nil }
        return String(data: output.prefix(moved), encoding: .utf8)
    }
}

enum LogicTests {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures.append(name) }
        }

        check("remaining clamps", QuotaMath.remaining(usedPercent: 44) == 56)
        check("remaining over", QuotaMath.remaining(usedPercent: 140) == 0)
        check("weekly label", QuotaMath.windowLabel(minutes: 10080) == "每周")
        check("five hour label", QuotaMath.windowLabel(minutes: 300) == "5 小时")
        check(
            "reset days",
            QuotaMath.resetText(
                until: Date(timeIntervalSince1970: 4 * 24 * 3600 + 5 * 3600),
                now: Date(timeIntervalSince1970: 0)
            ) == "4 天 5 小时后重置"
        )

        let codex: [String: Any] = [
            "rateLimits": [
                "planType": "prolite",
                "primary": [
                    "usedPercent": 44,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_794_414_489,
                ],
                "secondary": NSNull(),
            ] as [String: Any],
        ]
        let parsed = CodexParser.parse(result: codex)
        check("codex plan", parsed.plan == "Pro")
        check("codex remaining", parsed.windows.first?.remainingPercent == 56)
        check("codex window", parsed.windows.first?.label == "每周")

        let billing: [String: Any] = [
            "config": [
                "creditUsagePercent": 25.0,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2026-11-13T01:53:09.930537Z",
                ],
            ] as [String: Any],
        ]
        let grok = GrokBillingParser.parse(body: billing)
        check("grok remaining", grok?.windows.first?.remainingPercent == 75)
        check("grok plan", grok?.plan == "Premium")
        check("grok reset", grok?.windows.first?.resetsAt != nil)

        let wrapped = "{\"active\":\"a\",\"accounts\":{}}"
        let accounts = GrokBotParser.accountsObject(in: ["cursor-accounts": wrapped])
        check("accounts string", accounts?["active"] as? String == "a")

        let bot = GrokBotParser.parse(body: [
            "usagePercent": 12,
            "nextResetTimestampUtc": "2026-09-18T18:43:19.645Z",
            "grokPlanLabel": "Grok Bot Plan",
        ])
        check("bot remaining", bot.windows.first?.remainingPercent == 88)
        check("bot reset", bot.windows.first?.resetsAt != nil)

        let secret = Data("test-secret".utf8)
        let key = OSCrypt.deriveKey(secret: secret)
        check(
            "pbkdf2",
            key?.map { String(format: "%02x", $0) }.joined() == "01ab06dc67d036480129f3e40d53ca5f"
        )
        let token = key.flatMap { OSCrypt.decrypt(blob: "djEwtabSqW3C6jgn5ZRKjZXA5w==", key: $0) }
        check("oscrypt", token == "hello-token")
        check(
            "gpt login url",
            OfficialLogin.gptURL("https://auth.openai.com/oauth/authorize?state=1")?.host == "auth.openai.com"
        )
        check("reject other login url", OfficialLogin.gptURL("https://example.com/oauth/authorize") == nil)
        check("needs login", OfficialLogin.needsOfficialLogin("请先登录 Codex"))
        check("network is not login", !OfficialLogin.needsOfficialLogin("Grok 没有连上"))
        return failures
    }
}
