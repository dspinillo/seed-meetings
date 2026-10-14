import CoreFoundation
import Foundation
import SeedKit

// MCP stdio: stdout contém somente JSON-RPC, uma mensagem por linha.
let store = MeetingStore()
let root = store.rootURL.resolvingSymlinksInPath().standardizedFileURL
let supportedVersions = ["2025-03-26", "2025-06-18", "2025-11-25"]
let idProperty: [String: Any] = ["type": "string", "description": "ID retornado por list_meetings ou search_meetings"]
func number(_ minimum: Double, _ maximum: Double, _ description: String, integer: Bool = true) -> [String: Any] {
    ["type": integer ? "integer" : "number", "minimum": minimum, "maximum": maximum, "description": description]
}
func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
     "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
}
let paging: [String: Any] = ["id": idProperty,
    "offset": number(0, 100_000_000, "Posição em caracteres; padrão 0"),
    "limit": number(1, 180_000, "Caracteres por página; padrão 20000")]
let toolDefinitions = [
    tool("list_meetings", "Lista reuniões por período, pasta e tag, com paginação. Não lê áudio.", [
        "days": number(1, 36500, "Últimos dias; padrão 30"), "limit": number(1, 200, "Reuniões por página; padrão 50"),
        "offset": number(0, 100_000_000, "Posição na lista; padrão 0"),
        "folder": ["type": "string"], "tag": ["type": "string"],
        "temperature": ["type": "string", "enum": MeetingClassification.Temperatura.allCases.map(\.rawValue)],
        "flag": ["type": "string", "enum": MeetingClassification.allowedFlags]]),
    tool("get_meeting", "Metadados, participantes, notas e resumo (até 20000 caracteres por texto). Para textos longos use get_summary/get_transcript.", ["id": idProperty], required: ["id"]),
    tool("get_summary", "Lê o resumo salvo com paginação. Não gera resumo nem chama IA.", paging, required: ["id"]),
    tool("get_transcript", "Lê transcrição salva com tempos. Continue com next_offset até null; pode ser parcial durante processamento.", paging, required: ["id"]),
    tool("search_meetings", "Busca em título, tags, resumo e transcrição, com trechos e paginação. Filtra por temperatura e flag da classificação.", [
        "query": ["type": "string", "minLength": 1], "days": number(1, 36500, "Últimos dias; padrão 90"),
        "temperature": ["type": "string", "enum": MeetingClassification.Temperatura.allCases.map(\.rawValue)],
        "flag": ["type": "string", "enum": MeetingClassification.allowedFlags],
        "offset": number(0, 100_000_000, "Posição nos resultados; padrão 0"), "limit": number(1, 200, "Resultados por página; padrão 50")], required: ["query"]),
    tool("semantic_search", "Busca por sentido nos trechos de transcrição (índice local via Ollama). Retorna trechos com [mm:ss] e score. Falha se a busca semântica estiver desligada nas Preferências ou o Ollama parado; nesse caso use search_meetings.", [
        "query": ["type": "string", "minLength": 1], "limit": number(1, 50, "Trechos retornados; padrão 10")], required: ["query"]),
    tool("list_topics", "Lista os tópicos (grupos de reuniões sobre o mesmo assunto) com a contagem de reuniões.", [:]),
    tool("get_topic", "Tópico com suas reuniões em ordem cronológica e o resumo consolidado salvo, se houver. Não chama IA.", [
        "topic_id": ["type": "string", "description": "ID retornado por list_topics"]], required: ["topic_id"]),
    tool("list_audio", "Lista trilhas mic/system, duração e disponibilidade. Não retorna bytes. Áudio pode ter expirado pela retenção.", ["id": idProperty], required: ["id"]),
    tool("get_audio", "Retorna trecho de até 30s em conteúdo MCP audio/wav (PCM mono 16kHz). Requer cliente/modelo com suporte a áudio; não transcreve. Os tempos são relativos à trilha escolhida.", [
        "id": idProperty, "track": ["type": "string", "enum": ["mic", "system"]],
        "start_seconds": number(0, 1_000_000_000, "Início relativo à trilha; padrão 0", integer: false),
        "duration_seconds": number(0.01, 30, "Duração desejada; padrão 15 segundos", integer: false)], required: ["id", "track"]),
]

func send(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
}
func errorReply(_ id: Any, _ code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}
func structured(_ value: [String: Any]) -> [String: Any] {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return ["structuredContent": value, "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
}
func safeFile(_ url: URL, in folder: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    return resolved.deletingLastPathComponent() == folder &&
        (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}
func meetings() -> [Meeting] {
    let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return entries.compactMap { url -> Meeting? in
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        guard folder == url.standardizedFileURL, folder.deletingLastPathComponent() == root,
              safeFile(folder.appendingPathComponent("meta.json"), in: folder) else { return nil }
        return store.read(folderURL: folder)
    }.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
}
func meeting(_ args: [String: Any]) throws -> Meeting {
    guard let id = args["id"] as? String, !id.isEmpty, !id.contains("/"), id != ".", id != "..",
          let found = meetings().first(where: { $0.id == id }) else {
        throw SeedError("Reunião não encontrada. Use list_meetings para obter IDs válidos.")
    }
    return found
}
func read(_ url: URL, _ meeting: Meeting) -> String? {
    guard safeFile(url, in: meeting.folderURL) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
}
func classification(_ meeting: Meeting) -> MeetingClassification? {
    safeFile(meeting.folderURL.appendingPathComponent("classificacao.json"), in: meeting.folderURL)
        ? Classifier.load(for: meeting) : nil
}
func meta(_ meeting: Meeting) -> [String: Any] {
    ["id": meeting.id, "title": meeting.title, "started_at": ISO8601DateFormatter().string(from: meeting.startedAt),
     "duration_seconds": meeting.durationSeconds, "status": meeting.status.rawValue,
     "folder": meeting.folder as Any? ?? NSNull(), "tags": meeting.tags]
}
func value(_ args: [String: Any], _ key: String, _ fallback: Int) -> Int { (args[key] as? NSNumber)?.intValue ?? fallback }
func page(_ text: String, _ args: [String: Any], _ id: String) -> [String: Any] {
    let offset = value(args, "offset", 0), limit = value(args, "limit", 20_000)
    let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
    let end = text.index(start, offsetBy: min(limit, text.distance(from: start, to: text.endIndex)))
    let next = min(offset, text.count) + text.distance(from: start, to: end)
    return ["id": id, "text": String(text[start..<end]), "offset": offset,
            "total_characters": text.count, "next_offset": next < text.count ? next as Any : NSNull()]
}
func validate(_ args: [String: Any], definition: [String: Any]) -> Bool {
    let schema = definition["inputSchema"] as! [String: Any]
    let properties = schema["properties"] as! [String: [String: Any]]
    for key in schema["required"] as! [String] where args[key] == nil { return false }
    for (key, input) in args {
        guard let spec = properties[key], let type = spec["type"] as? String else { return false }
        if type == "string" {
            guard let string = input as? String else { return false }
            if let options = spec["enum"] as? [String], !options.contains(string) { return false }
            if let min = spec["minLength"] as? Int, string.trimmingCharacters(in: .whitespacesAndNewlines).count < min { return false }
        } else {
            guard let n = input as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return false }
            if type == "integer" && n.doubleValue.rounded() != n.doubleValue { return false }
            if let min = spec["minimum"] as? Double, n.doubleValue < min { return false }
            if let max = spec["maximum"] as? Double, n.doubleValue > max { return false }
        }
    }
    return true
}
func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
    if name == "list_meetings" || name == "search_meetings" {
        let days = value(args, "days", name == "search_meetings" ? 90 : 30)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var results: [[String: Any]] = []
        for item in meetings() where item.startedAt >= cutoff {
            if let folder = args["folder"] as? String, item.folder?.lowercased() != folder.lowercased() { continue }
            if let tag = args["tag"] as? String, !item.tags.contains(where: { $0.lowercased() == tag.lowercased() }) { continue }
            if args["temperature"] != nil || args["flag"] != nil {
                guard let found = classification(item) else { continue }
                if let wanted = args["temperature"] as? String, found.temperatura.rawValue != wanted { continue }
                if let flag = args["flag"] as? String, !found.flags.contains(flag) { continue }
            }
            var entry = meta(item)
            if let query = args["query"] as? String {
                let texts = [item.title, item.tags.joined(separator: " "), read(item.summaryURL, item) ?? "", read(item.transcriptURL, item) ?? ""]
                let snippets = texts.compactMap { text -> String? in
                    guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
                    let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
                    return String(text[start..<end])
                }
                if snippets.isEmpty { continue }
                entry["snippets"] = snippets
            }
            results.append(entry)
        }
        let offset = value(args, "offset", 0), limit = value(args, "limit", 50)
        let items = Array(results.dropFirst(offset).prefix(limit))
        let next = offset + items.count
        return structured(["meetings": items, "total": results.count, "next_offset": next < results.count ? next as Any : NSNull()])
    }
    if name == "semantic_search" {
        let known = Dictionary(uniqueKeysWithValues: meetings().map { ($0.id, $0) })
        let hits = try SemanticIndex.search(args["query"] as! String, store: store, meetingIDs: Set(known.keys),
                                            limit: value(args, "limit", 10))
        return structured(["results": hits.map { hit -> [String: Any] in
            ["id": hit.meetingID, "title": known[hit.meetingID]?.title ?? "", "score": Double(hit.score),
             "start_seconds": hit.start, "text": hit.text]
        }])
    }
    if name == "list_topics" {
        return structured(["topics": Topics.load().map { ["topic_id": $0.id, "name": $0.name,
            "description": $0.description, "meeting_count": $0.meetingIDs.count] }])
    }
    if name == "get_topic" {
        guard let topic = Topics.load().first(where: { $0.id == args["topic_id"] as? String }) else {
            throw SeedError("Tópico não encontrado. Use list_topics para obter IDs válidos.")
        }
        return structured(["topic_id": topic.id, "name": topic.name, "description": topic.description,
            "meetings": Topics.meetings(of: topic, in: meetings()).map(meta),
            "summary": topic.summary.map { String($0.prefix(20_000)) } as Any? ?? NSNull()])
    }
    let item = try meeting(args)
    switch name {
    case "get_meeting":
        var result = meta(item)
        let speakerURL = item.folderURL.appendingPathComponent("speakers.json")
        result["participants"] = safeFile(speakerURL, in: item.folderURL) ? Speakers.load(for: item).map(\.label) : []
        result["notes"] = read(item.notesURL, item).map { String($0.prefix(20_000)) } as Any? ?? NSNull()
        let summary = read(item.summaryURL, item)
        result["summary"] = summary.map { String($0.prefix(20_000)) } as Any? ?? NSNull()
        result["summary_truncated"] = (summary?.count ?? 0) > 20_000
        result["classification"] = classification(item).map { found -> [String: Any] in
            ["temperatura": found.temperatura.rawValue, "temperatura_motivo": found.temperaturaMotivo,
             "evidencias": found.evidencias.map { ["momento": $0.momento, "trecho": $0.trecho] },
             "ferramentas": found.ferramentas, "temas": found.temas, "flags": found.flags]
        } as Any? ?? NSNull()
        result["topics"] = Topics.load().filter { $0.meetingIDs.contains(item.id) }.map { ["topic_id": $0.id, "name": $0.name] }
        return structured(result)
    case "get_summary", "get_transcript":
        guard let text = read(name == "get_summary" ? item.summaryURL : item.transcriptURL, item) else {
            throw SeedError("Texto indisponível ou inacessível; estado da reunião: \(item.status.rawValue).")
        }
        return structured(page(text, args, item.id))
    case "list_audio":
        var tracks: [[String: Any]] = []
        for (track, url) in [("mic", item.micURL), ("system", item.systemURL)] {
            let available = safeFile(url, in: item.folderURL)
            let duration = available ? try? MeetingAudio.duration(of: url) : nil
            tracks.append(["track": track, "available": available && duration != nil,
                           "duration_seconds": duration as Any? ?? NSNull(), "format": url.pathExtension])
        }
        return structured(["id": item.id, "tracks": tracks, "max_clip_seconds": 30])
    case "get_audio":
        let track = args["track"] as! String
        let url = track == "mic" ? item.micURL : item.systemURL
        guard safeFile(url, in: item.folderURL) else {
            throw SeedError("Áudio indisponível: a trilha pode ter expirado, sido removida ou ainda não existir.")
        }
        let start = (args["start_seconds"] as? NSNumber)?.doubleValue ?? 0
        let duration = (args["duration_seconds"] as? NSNumber)?.doubleValue ?? 15
        let clip = try MeetingAudio.clip(url: url, start: start, duration: duration)
        return ["content": [
            ["type": "text", "text": "\(item.id), trilha \(track), início \(start)s, duração \(clip.durationSeconds)s. WAV mono 16 kHz."],
            ["type": "audio", "mimeType": "audio/wav", "data": clip.wav.base64EncodedString()]]]
    default: throw SeedError("Ferramenta desconhecida.")
    }
}

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
        errorReply(NSNull(), -32700, "JSON inválido"); continue
    }
    guard let message = object as? [String: Any], message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
        errorReply(NSNull(), -32600, "Request inválido"); continue
    }
    guard let id = message["id"] else { continue } // Notificações não recebem resposta.
    let params = message["params"] as? [String: Any] ?? [:]
    var result: [String: Any]
    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        result = ["protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions.last!,
                  "capabilities": ["tools": [:] as [String: Any]], "serverInfo": ["name": "seed", "version": "0.3.0"]]
    case "ping": result = [:]
    case "tools/list": result = ["tools": toolDefinitions]
    case "tools/call":
        guard let name = params["name"] as? String, let definition = toolDefinitions.first(where: { $0["name"] as? String == name }),
              params["arguments"] == nil || params["arguments"] is [String: Any],
              validate(params["arguments"] as? [String: Any] ?? [:], definition: definition) else {
            errorReply(id, -32602, "Ferramenta ou argumentos inválidos; consulte tools/list."); continue
        }
        do { result = try call(name, params["arguments"] as? [String: Any] ?? [:]) }
        catch { result = ["isError": true, "content": [["type": "text", "text": String(describing: error)]]] }
    default:
        errorReply(id, -32601, "Método não suportado: \(method)"); continue
    }
    send(["jsonrpc": "2.0", "id": id, "result": result])
}
