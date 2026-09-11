import Foundation
import SeedKit

// seed-mcp — servidor MCP (stdio, JSON-RPC 2.0 delimitado por linha) que expõe
// as reuniões do Seed ao Claude Code. Somente leitura de ~/Documents/Seed.

let store = MeetingStore()

// MARK: - Transporte

func send(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object)
    else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func reply(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func replyError(id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func textResult(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]]]
}

// MARK: - Definição das ferramentas

let toolDefinitions: [[String: Any]] = [
    [
        "name": "list_meetings",
        "description": "Lista as reuniões gravadas no Seed (título, data, duração, pasta, tags, id). Use os filtros para restringir por período, pasta ou tag.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "days": ["type": "number", "description": "Janela em dias (padrão 30)"],
                "folder": ["type": "string", "description": "Filtrar por pasta (ex.: 1:1)"],
                "tag": ["type": "string", "description": "Filtrar por tag (ex.: operações)"],
                "limit": ["type": "number", "description": "Máximo de resultados (padrão 50)"],
            ],
        ] as [String: Any],
    ],
    [
        "name": "get_meeting",
        "description": "Detalhe de uma reunião: metadados, participantes, notas do usuário e o resumo completo. Use o id retornado por list_meetings ou search_meetings.",
        "inputSchema": [
            "type": "object",
            "properties": ["id": ["type": "string", "description": "Id da reunião (nome da pasta, ex.: 20260707-103105)"]],
            "required": ["id"],
        ] as [String: Any],
    ],
    [
        "name": "get_transcript",
        "description": "Transcript completo de uma reunião (falas intercaladas com timestamps). Use para citações literais do que foi dito.",
        "inputSchema": [
            "type": "object",
            "properties": ["id": ["type": "string", "description": "Id da reunião"]],
            "required": ["id"],
        ] as [String: Any],
    ],
    [
        "name": "search_meetings",
        "description": "Busca textual em títulos, tags, resumos e transcripts das reuniões. Retorna as reuniões com trechos onde o termo aparece.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Termo de busca"],
                "days": ["type": "number", "description": "Janela em dias (padrão 90)"],
            ],
            "required": ["query"],
        ] as [String: Any],
    ],
]

// MARK: - Implementação

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "pt_BR")
    f.dateFormat = "EEE, d MMM yyyy HH:mm"
    return f
}()

func headerLine(_ meeting: Meeting) -> String {
    var parts = [
        "[\(meeting.id)]",
        meeting.title,
        dateFormatter.string(from: meeting.startedAt),
        "\(max(1, Int(meeting.durationSeconds / 60))) min",
        meeting.status.rawValue,
    ]
    if let folder = meeting.folder { parts.append("📁 \(folder)") }
    if !meeting.tags.isEmpty { parts.append(meeting.tags.map { "#\($0)" }.joined(separator: " ")) }
    return parts.joined(separator: " · ")
}

func meetings(inDays days: Int) -> [Meeting] {
    let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
    return store.list().filter { $0.startedAt >= cutoff }
}

func toolListMeetings(_ args: [String: Any]) -> String {
    let days = (args["days"] as? NSNumber)?.intValue ?? 30
    let limit = (args["limit"] as? NSNumber)?.intValue ?? 50
    var result = meetings(inDays: days)
    if let folder = args["folder"] as? String, !folder.isEmpty {
        result = result.filter { $0.folder?.lowercased() == folder.lowercased() }
    }
    if let tag = args["tag"] as? String, !tag.isEmpty {
        result = result.filter { $0.tags.contains(tag.lowercased()) }
    }
    guard !result.isEmpty else { return "Nenhuma reunião encontrada nos últimos \(days) dias com esses filtros." }
    let lines = result.prefix(limit).map(headerLine)
    return "Reuniões (últimos \(days) dias):\n\n" + lines.joined(separator: "\n")
}

func findMeeting(_ id: String) -> Meeting? {
    store.list().first { $0.id == id }
}

func toolGetMeeting(_ args: [String: Any]) -> String {
    guard let id = args["id"] as? String, let meeting = findMeeting(id) else {
        return "Reunião não encontrada. Use list_meetings para ver os ids."
    }
    var output = headerLine(meeting)
    let speakers = Speakers.load(for: meeting)
    if !speakers.isEmpty {
        let names = (["Você"] + speakers.map(\.label)).joined(separator: ", ")
        output += "\nParticipantes: \(names)"
    }
    if let notes = store.readNotes(meeting), !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        output += "\n\n== NOTAS DO USUÁRIO ==\n\(notes)"
    }
    if let summary = store.readSummary(meeting) {
        output += "\n\n== RESUMO ==\n\(summary)"
    } else {
        output += "\n\n(resumo ainda não disponível — status \(meeting.status.rawValue))"
    }
    return output
}

func toolGetTranscript(_ args: [String: Any]) -> String {
    guard let id = args["id"] as? String, let meeting = findMeeting(id) else {
        return "Reunião não encontrada. Use list_meetings para ver os ids."
    }
    guard let transcript = store.readTranscript(meeting) else {
        return "Transcript ainda não disponível (status \(meeting.status.rawValue))."
    }
    let limit = 180_000
    if transcript.count > limit {
        return String(transcript.prefix(limit)) + "\n\n[transcript truncado em \(limit) caracteres]"
    }
    return transcript
}

func toolSearchMeetings(_ args: [String: Any]) -> String {
    guard let query = (args["query"] as? String)?.lowercased(), !query.isEmpty else {
        return "Informe um termo de busca."
    }
    let days = (args["days"] as? NSNumber)?.intValue ?? 90
    var hits: [String] = []
    for meeting in meetings(inDays: days) {
        var snippets: [String] = []
        if meeting.title.lowercased().contains(query) { snippets.append("(título)") }
        if meeting.tags.contains(where: { $0.contains(query) }) { snippets.append("(tag)") }
        for (label, content) in [("resumo", store.readSummary(meeting)), ("transcript", store.readTranscript(meeting))] {
            guard let content, !content.isEmpty else { continue }
            let lower = content.lowercased()
            guard let range = lower.range(of: query) else { continue }
            let start = content.index(range.lowerBound, offsetBy: -120, limitedBy: content.startIndex) ?? content.startIndex
            let end = content.index(range.upperBound, offsetBy: 120, limitedBy: content.endIndex) ?? content.endIndex
            let snippet = content[start..<end].replacingOccurrences(of: "\n", with: " ")
            snippets.append("(\(label)) …\(snippet)…")
        }
        if !snippets.isEmpty {
            hits.append(headerLine(meeting) + "\n  " + snippets.joined(separator: "\n  "))
        }
    }
    guard !hits.isEmpty else { return "Nada encontrado para \"\(query)\" nos últimos \(days) dias." }
    return "Resultados para \"\(query)\":\n\n" + hits.joined(separator: "\n\n")
}

// MARK: - Loop principal

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String
    else { continue }

    let id = message["id"]

    switch method {
    case "initialize":
        let params = message["params"] as? [String: Any]
        let version = (params?["protocolVersion"] as? String) ?? "2024-11-05"
        if let id {
            reply(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "seed", "version": "1.0.0"],
            ])
        }
    case "ping":
        if let id { reply(id: id, result: [:]) }
    case "tools/list":
        if let id { reply(id: id, result: ["tools": toolDefinitions]) }
    case "tools/call":
        guard let id else { continue }
        guard let params = message["params"] as? [String: Any],
              let name = params["name"] as? String
        else {
            replyError(id: id, code: -32602, message: "parâmetros inválidos")
            continue
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let output: String
        switch name {
        case "list_meetings": output = toolListMeetings(args)
        case "get_meeting": output = toolGetMeeting(args)
        case "get_transcript": output = toolGetTranscript(args)
        case "search_meetings": output = toolSearchMeetings(args)
        default:
            replyError(id: id, code: -32602, message: "ferramenta desconhecida: \(name)")
            continue
        }
        reply(id: id, result: textResult(output))
    default:
        // notificações (notifications/*) são ignoradas; requests desconhecidos recebem erro
        if let id {
            replyError(id: id, code: -32601, message: "método não suportado: \(method)")
        }
    }
}
