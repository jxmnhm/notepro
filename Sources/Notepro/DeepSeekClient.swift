// DeepSeekClient.swift — DeepSeek V4 API 客户端（OpenAI 兼容格式）
// 当前模型：deepseek-v4-flash / deepseek-v4-pro（1M 上下文）。
// 思考模式通过顶层 thinking 字段开关；默认 enabled，这里按用户设置显式传 enabled/disabled。
import Foundation

struct DeepSeekClient {
    var apiKey: String
    var model: String = "deepseek-v4-flash"
    var thinking: Bool = false
    var baseURL = URL(string: "https://api.deepseek.com/chat/completions")!

    struct Message: Codable { let role: String; let content: String }

    private struct Thinking: Codable { let type: String }
    private struct Request: Codable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let thinking: Thinking
        let temperature: Double?      // 思考模式下会被忽略，故 nil 不传
        let reasoning_effort: String? // 仅思考模式有意义
    }
    private struct Response: Codable {
        struct Choice: Codable {
            struct Msg: Codable {
                let content: String?
                let reasoning_content: String?
            }
            let message: Msg
        }
        let choices: [Choice]
    }
    private struct APIError: Codable {
        struct E: Codable { let message: String }
        let error: E
    }

    enum ClientError: LocalizedError {
        case noKey, http(Int, String), decode, empty
        var errorDescription: String? {
            switch self {
            case .noKey: return "还没填 DeepSeek API Key，请到「设置」里填写。"
            case .http(let code, let msg): return "API 返回错误 (\(code))：\(msg)"
            case .decode: return "无法解析 API 返回。"
            case .empty: return "API 返回为空。"
            }
        }
    }

    func complete(system: String, user: String, temperature: Double = 0.7) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw ClientError.noKey }

        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = Request(
            model: model,
            messages: [.init(role: "system", content: system),
                       .init(role: "user", content: user)],
            stream: false,
            thinking: Thinking(type: thinking ? "enabled" : "disabled"),
            temperature: thinking ? nil : temperature,
            reasoning_effort: thinking ? "high" : nil)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.decode }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8) ?? "未知错误"
            throw ClientError.http(http.statusCode, msg)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ClientError.decode
        }
        // 思考模式下取最终答案 content（reasoning_content 是思维链，不展示给用户）
        let text = decoded.choices.first?.message.content ?? ""
        guard !text.isEmpty else { throw ClientError.empty }
        return text
    }

    // MARK: - 流式输出（SSE）：边收边回调，content 一片一片冒出来
    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoning_content: String?
            }
            let delta: Delta
        }
        let choices: [Choice]
    }

    /// 流式补全。onDelta 每收到一段正文就回调（在调用方指定的执行环境里自行切主线程）。
    /// 返回完整正文。reasoning_content（思维链）不回传给 UI。
    func stream(system: String,
                user: String,
                temperature: Double = 0.7,
                onDelta: @escaping (String) -> Void) async throws -> String {
        try await streamMessages(
            [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: temperature, onDelta: onDelta)
    }

    /// 多轮对话版流式：传入完整 messages 历史，支持二次追问。
    func streamMessages(_ messages: [Message],
                        temperature: Double = 0.7,
                        onDelta: @escaping (String) -> Void) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw ClientError.noKey }

        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = Request(
            model: model,
            messages: messages,
            stream: true,
            thinking: Thinking(type: thinking ? "enabled" : "disabled"),
            temperature: thinking ? nil : temperature,
            reasoning_effort: thinking ? "high" : nil)
        req.httpBody = try JSONEncoder().encode(body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.decode }
        guard (200..<300).contains(http.statusCode) else {
            // 错误时把响应体读出来，给出可读信息
            var raw = ""
            for try await line in bytes.lines { raw += line }
            let msg = (try? JSONDecoder().decode(APIError.self, from: Data(raw.utf8)))?.error.message
                ?? raw
            throw ClientError.http(http.statusCode, msg.isEmpty ? "未知错误" : msg)
        }

        let decoder = JSONDecoder()
        var full = ""
        // SSE：每行形如 "data: {...}"，以 "data: [DONE]" 结束
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(StreamChunk.self, from: data),
                  let piece = chunk.choices.first?.delta.content, !piece.isEmpty
            else { continue }
            full += piece
            onDelta(piece)
        }
        guard !full.isEmpty else { throw ClientError.empty }
        return full
    }
}
