import AppKit
import Foundation
import Security

struct QuotaError: Error {
    var message: String
}

enum QuotaFetch {
    static func gpt() -> ProviderQuota {
        guard let binary = codexBinary() else {
            return .unavailable("GPT", "没有找到 Codex，先安装并登录")
        }
        switch codexQuota(binary: binary) {
        case let .success(quota):
            return quota
        case let .failure(error):
            return .unavailable("GPT", error.message)
        }
    }

    static func signInGPT() -> ProviderQuota {
        guard let binary = codexBinary() else {
            return .unavailable("GPT", "没有找到 Codex，先安装并登录")
        }
        switch codexSignIn(binary: binary) {
        case let .success(quota):
            return quota
        case let .failure(error):
            return .unavailable("GPT", error.message)
        }
    }

    static func grokStamp() -> TimeInterval {
        [grokAuthPath, grokBotSecretsPath].reduce(0) { latest, path in
            guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
                return latest
            }
            return max(latest, date.timeIntervalSince1970)
        }
    }

    static func waitForGrokChange(since stamp: TimeInterval, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if grokStamp() != stamp { return true }
            usleep(500_000)
        }
        return false
    }

    /// Opens the official sign-in for whichever Grok login is installed.
    /// The Grok CLI opens its own browser page. Grok Bot keeps that page inside the app.
    static func openGrokLogin() -> String {
        if let binary = grokBinary() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["login"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                return "正在打开 Grok 官方登录页"
            }
        }
        let app = URL(fileURLWithPath: "/Applications/Grok Bot.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            return "没有找到 Grok"
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(app)
        }
        return "请在 Grok Bot 里登录或切换账号"
    }

    static func grok() -> ProviderQuota {
        if FileManager.default.fileExists(atPath: grokAuthPath) {
            switch xaiBilling() {
            case let .success(quota):
                return quota
            case let .failure(error):
                return .unavailable("Grok", error.message)
            }
        }
        if FileManager.default.fileExists(atPath: grokBotSecretsPath) {
            switch grokBotUsage() {
            case let .success(quota):
                return quota
            case let .failure(error):
                return .unavailable("Grok", error.message)
            }
        }
        return .unavailable("Grok", "先登录 Grok，或打开一次 Grok Bot")
    }

    private static var grokAuthPath: String {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("auth.json")
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".grok/auth.json")
    }

    private static var grokBotSecretsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Application Support/Grok Bot/sand-secrets.json"
        )
    }
}

private func codexBinary() -> String? {
    executable(["/opt/homebrew/bin/codex", "/usr/local/bin/codex"])
}

private func grokBinary() -> String? {
    executable(["/opt/homebrew/bin/grok", "/usr/local/bin/grok"])
}

private func executable(_ candidates: [String]) -> String? {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func codexQuota(binary: String) -> Result<ProviderQuota, QuotaError> {
    let connection: CodexConnection
    switch CodexConnection.start(binary: binary) {
    case let .success(value):
        connection = value
    case let .failure(error):
        return .failure(error)
    }
    defer { connection.close() }
    return connection.readQuota()
}

private func codexSignIn(binary: String) -> Result<ProviderQuota, QuotaError> {
    let connection: CodexConnection
    switch CodexConnection.start(binary: binary) {
    case let .success(value):
        connection = value
    case let .failure(error):
        return .failure(error)
    }
    defer { connection.close() }
    guard case let .success(response) = connection.call(
        "account/login/start",
        params: [
            "type": "chatgpt",
            "useHostedLoginSuccessPage": true,
            "appBrand": "chatgpt",
        ],
        timeout: 20
    ) else {
        return .failure(QuotaError(message: "打不开 GPT 登录页"))
    }
    guard let result = response["result"] as? [String: Any],
          let authURL = result["authUrl"] as? String,
          let url = OfficialLogin.gptURL(authURL) else {
        return .failure(QuotaError(message: "打不开 GPT 登录页"))
    }
    let opened = DispatchSemaphore(value: 0)
    var didOpen = false
    DispatchQueue.main.async {
        didOpen = NSWorkspace.shared.open(url)
        opened.signal()
    }
    opened.wait()
    guard didOpen else {
        if let loginID = result["loginId"] as? String {
            _ = connection.call("account/login/cancel", params: ["loginId": loginID], timeout: 10)
        }
        return .failure(QuotaError(message: "打不开 GPT 登录页"))
    }
    guard let completed = connection.waitForMethod("account/login/completed", timeout: 180),
          let params = completed["params"] as? [String: Any],
          truth(params["success"]) else {
        return .failure(QuotaError(message: "登录未完成"))
    }
    return connection.readQuota()
}

private func truth(_ raw: Any?) -> Bool {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    return false
}

private final class CodexConnection {
    private let process: Process
    private let stdin: FileHandle
    private let reader: LineReader
    private var nextID = 1

    private init(process: Process, stdin: FileHandle, reader: LineReader) {
        self.process = process
        self.stdin = stdin
        self.reader = reader
    }

    static func start(binary: String) -> Result<CodexConnection, QuotaError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failure(QuotaError(message: "Codex 没有启动"))
        }
        let connection = CodexConnection(
            process: process,
            stdin: input.fileHandleForWriting,
            reader: LineReader(handle: output.fileHandleForReading)
        )
        guard case .success = connection.call(
            "initialize",
            params: [
                "clientInfo": [
                    "name": "tokeneater",
                    "title": "TokenEater",
                    "version": "0.1.0",
                ],
            ],
            timeout: 20
        ) else {
            connection.close()
            return .failure(QuotaError(message: "请先登录 Codex"))
        }
        guard connection.send(["method": "initialized"]) else {
            connection.close()
            return .failure(QuotaError(message: "Codex 没有响应"))
        }
        return .success(connection)
    }

    func readQuota() -> Result<ProviderQuota, QuotaError> {
        guard case let .success(limits) = call("account/rateLimits/read", params: [:], timeout: 25),
              let result = limits["result"] as? [String: Any] else {
            return .failure(QuotaError(message: "请先登录 Codex"))
        }
        var quota = CodexParser.parse(result: result)
        if case let .success(account) = call("account/read", params: ["refreshToken": false], timeout: 15),
           let body = account["result"] as? [String: Any],
           let info = body["account"] as? [String: Any],
           let email = info["email"] as? String,
           !email.isEmpty {
            quota.account = email
        }
        return .success(quota)
    }

    func call(_ method: String, params: [String: Any], timeout: TimeInterval) -> Result<[String: Any], QuotaError> {
        let id = nextID
        nextID += 1
        var payload: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { payload["params"] = params }
        guard send(payload) else { return .failure(QuotaError(message: "Codex 没有响应")) }
        guard let message = reader.message(id: id, timeout: timeout) else {
            return .failure(QuotaError(message: "Codex 没有响应"))
        }
        if message["error"] != nil { return .failure(QuotaError(message: "请先登录 Codex")) }
        return .success(message)
    }

    func waitForMethod(_ method: String, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let message = reader.nextObject(timeout: min(2, deadline.timeIntervalSinceNow)) else {
                if reader.ended { return nil }
                continue
            }
            if message["method"] as? String == method { return message }
        }
        return nil
    }

    func close() {
        try? stdin.close()
        if process.isRunning { process.terminate() }
        reader.close()
    }

    private func send(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }
        var line = data
        line.append(0x0A)
        do {
            try stdin.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }
}

private final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    private(set) var ended = false

    init(handle: FileHandle) {
        fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    func close() {
        ended = true
    }

    func message(id: Int, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let object = nextObject(timeout: min(2, deadline.timeIntervalSinceNow)) else {
                if ended { return nil }
                continue
            }
            if CodexParser.number(object["id"]).map({ Int($0) }) == id {
                return object
            }
        }
        return nil
    }

    func nextObject(timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while Date() < deadline {
            if let line = nextLine() {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    return object
                }
                continue
            }
            if ended { return nil }
            usleep(40_000)
        }
        return nil
    }

    private func nextLine() -> Data? {
        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            return Data(line)
        }
        var chunk = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk.prefix(count))
        } else if count == 0 {
            ended = true
        }
        return nil
    }
}

private func xaiBilling() -> Result<ProviderQuota, QuotaError> {
    let path: String
    if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
        path = (home as NSString).appendingPathComponent("auth.json")
    } else {
        path = (NSHomeDirectory() as NSString).appendingPathComponent(".grok/auth.json")
    }
    guard let token = xaiAccessToken(path: path) else {
        return .failure(QuotaError(message: "Grok 登录已失效，重新登录一次"))
    }
    var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
    request.httpMethod = "GET"
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
    let (data, status) = syncData(for: request)
    guard let status else { return .failure(QuotaError(message: "Grok 没有连上")) }
    if status == 401 || status == 403 { return .failure(QuotaError(message: "Grok 登录已失效，重新登录一次")) }
    guard (200..<300).contains(status),
          let data,
          let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let quota = GrokBillingParser.parse(body: body) else {
        return .failure(QuotaError(message: "Grok 这次没有读到额度"))
    }
    return .success(quota)
}

private func xaiAccessToken(path: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    var chosen: String?
    for (scope, value) in root {
        guard let entry = value as? [String: Any], let key = entry["key"] as? String, !key.isEmpty else {
            continue
        }
        let mode = (entry["auth_mode"] as? String)?.lowercased() ?? ""
        if mode == "api_key" || scope == "xai::api_key" { continue }
        if let expiry = entry["expires_at"] as? String,
           let date = QuotaMath.parseResetDate(expiry),
           date < Date() {
            continue
        }
        if scope.contains("::") {
            return key
        }
        chosen = key
    }
    return chosen
}

private struct GrokBotKey {
    static var cached: Data?
}

private func grokBotUsage() -> Result<ProviderQuota, QuotaError> {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(
        "Library/Application Support/Grok Bot/sand-secrets.json"
    )
    guard let token = grokBotAccessToken(path: path) else {
        return .failure(QuotaError(message: "请先打开 Grok Bot 并登录"))
    }
    guard let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus") else {
        return .failure(QuotaError(message: "Grok 没有连上"))
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.httpBody = Data("{}".utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue("sand", forHTTPHeaderField: "x-cursor-client-type")
    request.setValue("0.1.0", forHTTPHeaderField: "x-cursor-client-version")
    request.setValue("prod", forHTTPHeaderField: "x-sand-box-namespace")
    request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
    request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
    let (data, status) = syncData(for: request)
    guard let status else { return .failure(QuotaError(message: "Grok 没有连上")) }
    if status == 401 || status == 403 {
        return .failure(QuotaError(message: "打开一次 Grok Bot，让它刷新登录"))
    }
    guard (200..<300).contains(status),
          let data,
          let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failure(QuotaError(message: "Grok 这次没有读到额度"))
    }
    return .success(GrokBotParser.parse(body: body))
}

/// Reads the access token the Grok Bot app already stored. The token stays in
/// memory for this request and is never written back or refreshed here.
private func grokBotAccessToken(path: String) -> String? {
    guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let accounts = GrokBotParser.accountsObject(in: root),
          let active = accounts["active"] as? String,
          let entries = accounts["accounts"] as? [String: Any],
          let entry = entries[active] as? [String: Any],
          let blob = entry["cursor-access-token"] as? String else {
        return nil
    }
    if GrokBotKey.cached == nil {
        GrokBotKey.cached = grokBotStorageKey()
    }
    guard let key = GrokBotKey.cached else { return nil }
    return OSCrypt.decrypt(blob: blob, key: key)
}

private func grokBotStorageKey() -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Grok Bot Safe Storage",
        kSecAttrAccount as String: "Grok Bot Key",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let secret = item as? Data, !secret.isEmpty else {
        return nil
    }
    return OSCrypt.deriveKey(secret: secret)
}

private func syncData(for request: URLRequest) -> (Data?, Int?) {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResponseBox()
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        box.data = data
        box.status = (response as? HTTPURLResponse)?.statusCode
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 25)
    return (box.data, box.status)
}

private final class ResponseBox: @unchecked Sendable {
    var data: Data?
    var status: Int?
}
