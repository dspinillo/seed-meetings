import Foundation

/// Um falante detectado numa reunião (cluster da diarização), com o rótulo
/// atual e sugestões de nome vindas da memória de vozes.
public struct MeetingSpeaker: Codable, Identifiable, Sendable {
    public struct Suggestion: Codable, Sendable {
        public let name: String
        public let score: Float
    }

    public var id: String { cluster }
    public let cluster: String      // id do cluster da diarização ("1", "2"…)
    public var label: String        // "Falante 1" ou nome confirmado/reconhecido
    public var confirmed: Bool      // true quando o usuário confirmou o nome
    public let embedding: [Float]
    public var suggestions: [Suggestion]
}

/// Impressão de voz persistida: reconhece participantes recorrentes.
public struct Voiceprint: Codable, Sendable {
    public var name: String
    public var embedding: [Float]
    public var samples: Int
    public var updatedAt: Date
}

/// Memória de vozes entre reuniões (.voiceprints.json na pasta de dados).
public final class VoiceprintStore {
    private let fileURL: URL

    /// ≥ auto: assume o nome direto; ≥ suggest: vira sugestão de 1 clique.
    public static let autoThreshold: Float = 0.70
    public static let suggestThreshold: Float = 0.55

    public init(rootURL: URL) {
        fileURL = rootURL.appendingPathComponent(".voiceprints.json")
    }

    public func all() -> [Voiceprint] {
        guard let data = try? Data(contentsOf: fileURL),
              let prints = try? JSONDecoder().decode([Voiceprint].self, from: data)
        else { return [] }
        return prints
    }

    private func save(_ prints: [Voiceprint]) {
        guard let data = try? JSONEncoder().encode(prints) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Aprende (ou reforça) a voz de uma pessoa — média móvel dos embeddings.
    public func learn(name: String, embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        var prints = all()
        if let index = prints.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            var print = prints[index]
            let n = Float(print.samples)
            if print.embedding.count == embedding.count {
                print.embedding = zip(print.embedding, embedding).map { ($0 * n + $1) / (n + 1) }
            } else {
                print.embedding = embedding
            }
            print.samples += 1
            print.updatedAt = Date()
            prints[index] = print
        } else {
            prints.append(Voiceprint(name: name, embedding: embedding, samples: 1, updatedAt: Date()))
        }
        save(prints)
    }

    /// Reverte um learn — a média móvel é exatamente reversível. Desfaz a
    /// amostra de uma confirmação errada (uma confirmação de nome incorreta
    /// contamina a memória de voz). Remove o voiceprint
    /// inteiro se era a única amostra.
    public func unlearn(name: String, embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        var prints = all()
        guard let index = prints.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        var print = prints[index]
        if print.samples <= 1 {
            prints.remove(at: index)
        } else if print.embedding.count == embedding.count {
            let s = Float(print.samples)
            print.embedding = zip(print.embedding, embedding).map { ($0 * s - $1) / (s - 1) }
            print.samples -= 1
            print.updatedAt = Date()
            prints[index] = print
        } else {
            return
        }
        save(prints)
    }

    /// Melhores matches para um embedding, ordenados por similaridade.
    public func matches(for embedding: [Float], limit: Int = 3) -> [MeetingSpeaker.Suggestion] {
        all()
            .map { MeetingSpeaker.Suggestion(name: $0.name, score: Self.cosine($0.embedding, embedding)) }
            .filter { $0.score >= Self.suggestThreshold }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = (normA.squareRoot() * normB.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}

public enum Speakers {
    /// Embedding representativo de cada cluster: média ponderada pela duração.
    public static func clusterEmbeddings(from segments: [SpeakerSegment]) -> [String: [Float]] {
        var sums: [String: (vector: [Float], weight: Float)] = [:]
        for segment in segments where !segment.embedding.isEmpty {
            let weight = Float(max(segment.end - segment.start, 0.1))
            if var current = sums[segment.speakerId], current.vector.count == segment.embedding.count {
                for i in 0..<current.vector.count {
                    current.vector[i] += segment.embedding[i] * weight
                }
                current.weight += weight
                sums[segment.speakerId] = current
            } else {
                sums[segment.speakerId] = (segment.embedding.map { $0 * weight }, weight)
            }
        }
        return sums.mapValues { entry in entry.vector.map { $0 / entry.weight } }
    }

    /// Airtime (segundos de fala) por cluster.
    public static func airtimes(_ segments: [SpeakerSegment]) -> [String: Double] {
        var result: [String: Double] = [:]
        for segment in segments {
            result[segment.speakerId, default: 0] += max(segment.end - segment.start, 0)
        }
        return result
    }

    /// Desmistura clusters que a diarização colou: quando o embedding médio de
    /// um cluster bate em DUAS ou mais vozes conhecidas (≥ suggestThreshold),
    /// os segmentos são reatribuídos um a um à voz conhecida mais próxima e o
    /// cluster se divide — exemplo: Pessoa A (0,91) + Pessoa B (0,70) no mesmo
    /// cluster de 55min (o speakerThreshold do diarizer é permissivo demais
    /// para vozes parecidas; os voiceprints sabem separar).
    public static func splitMixedClusters(
        _ segments: [SpeakerSegment],
        voiceprints: VoiceprintStore
    ) -> [SpeakerSegment] {
        guard !segments.isEmpty else { return segments }
        let prints = voiceprints.all()
        guard prints.count >= 2 else { return segments }
        let embeddings = clusterEmbeddings(from: segments)
        var nextId = (segments.compactMap { Int($0.speakerId) }.max() ?? 0) + 1

        var result = segments
        for (cluster, embedding) in embeddings {
            let matched = prints
                .map { (print: $0, score: VoiceprintStore.cosine($0.embedding, embedding)) }
                .filter { $0.score >= VoiceprintStore.suggestThreshold }
                .sorted { $0.score > $1.score }
            guard matched.count >= 2 else { continue }

            // reatribui cada segmento à voz conhecida mais próxima
            var assignment: [Int: String] = [:]
            var airtimePerName: [String: Double] = [:]
            for (index, segment) in result.enumerated()
            where segment.speakerId == cluster && !segment.embedding.isEmpty {
                let best = matched.max { a, b in
                    VoiceprintStore.cosine(a.print.embedding, segment.embedding)
                        < VoiceprintStore.cosine(b.print.embedding, segment.embedding)
                }
                guard let name = best?.print.name else { continue }
                assignment[index] = name
                airtimePerName[name, default: 0] += max(segment.end - segment.start, 0)
            }
            guard airtimePerName.count >= 2 else { continue }

            // a voz com mais airtime herda o id original; as demais ganham ids novos
            let dominantName = airtimePerName.max { $0.value < $1.value }!.key
            var idForName: [String: String] = [dominantName: cluster]
            for name in airtimePerName.keys.sorted() where name != dominantName {
                idForName[name] = String(nextId)
                nextId += 1
            }
            for (index, name) in assignment {
                guard let id = idForName[name], id != cluster else { continue }
                let s = result[index]
                result[index] = SpeakerSegment(speakerId: id, start: s.start, end: s.end, embedding: s.embedding)
            }
            // segmentos sem embedding continuam no id original (voz dominante)
        }
        return result
    }

    /// Limpeza pós-diarização contra "falantes fantasma":
    /// 1. FUSÃO — cluster cujo embedding tem cosseno ≥ `fuseThreshold` com um
    ///    cluster de mais airtime funde nele (mesma pessoa que a diarização
    ///    dividiu; exemplo: 18s com cosseno 0,578 contra o cluster de 16min).
    /// 2. FILTRO — cluster com menos de `minSeconds` OU menos de `minShare`
    ///    do tempo falado é ruído e não vira "Falante N"; o dominante nunca cai.
    public static func cleanClusters(
        _ segments: [SpeakerSegment],
        fuseThreshold: Float = VoiceprintStore.suggestThreshold,
        minSeconds: Double = 20,
        minShare: Double = 0.02,
        voiceprints: VoiceprintStore? = nil,
        protected: Set<String> = []
    ) -> [SpeakerSegment] {
        guard !segments.isEmpty else { return segments }
        let embeddings = clusterEmbeddings(from: segments)
        let times = airtimes(segments)
        // por airtime decrescente: fusões sempre apontam para clusters maiores,
        // já resolvidos quando chega a vez dos menores
        let clusters = times.keys.sorted { (times[$0] ?? 0) > (times[$1] ?? 0) }

        // voz conhecida dominante de cada cluster — dois clusters com nomes
        // conhecidos DIFERENTES nunca se fundem, mesmo com cosseno alto
        var knownName: [String: String?] = [:]
        func topName(_ cluster: String) -> String? {
            if let cached = knownName[cluster] { return cached }
            let name = voiceprints.flatMap { store -> String? in
                guard let embedding = embeddings[cluster] else { return nil }
                return store.matches(for: embedding).first?.name
            }
            knownName[cluster] = name
            return name
        }

        var mapping: [String: String] = [:]
        for cluster in clusters.dropFirst() {
            guard !protected.contains(cluster) else { continue }
            guard let embedding = embeddings[cluster], !embedding.isEmpty else { continue }
            var best: (id: String, score: Float)?
            for candidate in clusters {
                guard (times[candidate] ?? 0) > (times[cluster] ?? 0) else { break }
                let root = mapping[candidate] ?? candidate
                guard root != cluster, let other = embeddings[root], !other.isEmpty else { continue }
                if let mine = topName(cluster), let theirs = topName(root), mine != theirs { continue }
                let score = VoiceprintStore.cosine(embedding, other)
                if score >= fuseThreshold, score > (best?.score ?? 0) { best = (root, score) }
            }
            if let best { mapping[cluster] = best.id }
        }
        var fused = segments.map { segment in
            mapping[segment.speakerId].map {
                SpeakerSegment(speakerId: $0, start: segment.start, end: segment.end, embedding: segment.embedding)
            } ?? segment
        }

        let fusedTimes = airtimes(fused)
        let total = fusedTimes.values.reduce(0, +)
        guard total > 0 else { return fused }
        let dominant = fusedTimes.max { $0.value < $1.value }?.key
        let keep = Set(
            fusedTimes.filter { id, seconds in
                protected.contains(id) || id == dominant
                    || (seconds >= minSeconds && seconds / total >= minShare)
            }.keys
        )
        fused.removeAll { !keep.contains($0.speakerId) }
        return fused
    }

    /// Monta os falantes da reunião com auto-nome/sugestões da memória de vozes.
    public static func build(
        segments: [SpeakerSegment],
        voiceprints: VoiceprintStore
    ) -> [MeetingSpeaker] {
        let embeddings = clusterEmbeddings(from: segments)
        return embeddings.keys.sorted().map { cluster in
            let embedding = embeddings[cluster] ?? []
            let suggestions = voiceprints.matches(for: embedding)
            let auto = suggestions.first.flatMap { $0.score >= VoiceprintStore.autoThreshold ? $0 : nil }
            return MeetingSpeaker(
                cluster: cluster,
                label: auto?.name ?? "Falante \(cluster)",
                confirmed: false,
                embedding: embedding,
                suggestions: suggestions
            )
        }
    }

    /// Resultado da subdivisão de um cluster gigante: bins ancorados em vozes
    /// conhecidas + bins novos (candidatos a pessoas sem voiceprint).
    public struct SubdivisionBin: Sendable {
        public let id: String            // nome da âncora ou "novo-N"
        public let anchorName: String?   // voz conhecida, quando âncora
        public let segments: [SpeakerSegment]

        public var airtime: Double {
            segments.reduce(0) { $0 + max($1.end - $1.start, 0) }
        }
    }

    /// Centroide ponderado pela duração dos segmentos.
    public static func weightedCentroid(_ segments: [SpeakerSegment]) -> [Float] {
        var sum: [Float] = []
        var weight: Float = 0
        for segment in segments where !segment.embedding.isEmpty {
            let w = Float(max(segment.end - segment.start, 0.1))
            if sum.isEmpty { sum = [Float](repeating: 0, count: segment.embedding.count) }
            guard sum.count == segment.embedding.count else { continue }
            for i in 0..<sum.count { sum[i] += segment.embedding[i] * w }
            weight += w
        }
        guard weight > 0 else { return [] }
        return sum.map { $0 / weight }
    }

    /// Subdivide um cluster que a diarização colou (exemplo: blob de 55,8min
    /// com 5 vozes na uma reunião de teste). Estratégia:
    /// 1. ÂNCORAS — cada segmento com cosseno ≥ `anchorThreshold` a uma voz
    ///    conhecida vai para o bin daquela pessoa;
    /// 2. RESÍDUO — o que sobrou (pessoas sem voiceprint) é re-clusterizado
    ///    com limiar RÍGIDO (`joinThreshold`), centroides ponderados;
    /// 3. subs gêmeos fundem (≥ `mergeThreshold`) e subs < `minSubSeconds`
    ///    são absorvidos pelo vizinho mais próximo (sub ou âncora).
    public static func subdivideCluster(
        _ cluster: String,
        segments: [SpeakerSegment],
        voiceprints: [Voiceprint],
        anchorThreshold: Float = 0.55,
        joinThreshold: Float = 0.60,
        mergeThreshold: Float = 0.65,
        minSubSeconds: Double = 20,
        refineIterations: Int = 2
    ) -> [SubdivisionBin] {
        let target = segments.filter { $0.speakerId == cluster && !$0.embedding.isEmpty }
        guard !target.isEmpty else { return [] }

        // 1. âncoras
        var anchorSegments: [String: [SpeakerSegment]] = [:]
        var residual: [SpeakerSegment] = []
        for segment in target {
            var best: (name: String, score: Float)?
            for voiceprint in voiceprints {
                let score = VoiceprintStore.cosine(voiceprint.embedding, segment.embedding)
                if score > (best?.score ?? 0) { best = (voiceprint.name, score) }
            }
            if let best, best.score >= anchorThreshold {
                anchorSegments[best.name, default: []].append(segment)
            } else {
                residual.append(segment)
            }
        }

        // 2. clustering ganancioso do resíduo
        struct Sub {
            var sum: [Float]
            var weight: Float
            var segments: [SpeakerSegment]
            var centroid: [Float] { sum.map { $0 / max(weight, 0.001) } }
            var airtime: Double { segments.reduce(0) { $0 + max($1.end - $1.start, 0) } }
        }
        var subs: [Sub] = []
        for segment in residual.sorted(by: { $0.start < $1.start }) {
            let w = Float(max(segment.end - segment.start, 0.1))
            var bestIndex = -1
            var bestScore: Float = 0
            for (index, sub) in subs.enumerated() {
                let score = VoiceprintStore.cosine(sub.centroid, segment.embedding)
                if score > bestScore { bestScore = score; bestIndex = index }
            }
            if bestIndex >= 0, bestScore >= joinThreshold, subs[bestIndex].sum.count == segment.embedding.count {
                for i in 0..<subs[bestIndex].sum.count { subs[bestIndex].sum[i] += segment.embedding[i] * w }
                subs[bestIndex].weight += w
                subs[bestIndex].segments.append(segment)
            } else {
                subs.append(Sub(sum: segment.embedding.map { $0 * w }, weight: w, segments: [segment]))
            }
        }

        // 3a. fusão de subs gêmeos
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in 0..<subs.count {
                for j in (i + 1)..<subs.count where subs[i].sum.count == subs[j].sum.count {
                    if VoiceprintStore.cosine(subs[i].centroid, subs[j].centroid) >= mergeThreshold {
                        subs[i].sum = zip(subs[i].sum, subs[j].sum).map(+)
                        subs[i].weight += subs[j].weight
                        subs[i].segments += subs[j].segments
                        subs.remove(at: j)
                        didMerge = true
                        break outer
                    }
                }
            }
        }

        // 3b. refinamento iterativo: reatribui cada segmento ao centroide mais
        // próximo — as âncoras passam a usar o centroide DESTA reunião (mais
        // fiel que o voiceprint global), puxando de volta sobras de vozes
        // conhecidas que caíram no resíduo (exemplo: falas da Pessoa A
        // dentro do bin da Pessoa C na uma reunião de teste)
        struct WorkBin {
            var anchorName: String?
            var segments: [SpeakerSegment]
            var airtime: Double { segments.reduce(0) { $0 + max($1.end - $1.start, 0) } }
        }
        var bins: [WorkBin] = anchorSegments.map { WorkBin(anchorName: $0.key, segments: $0.value) }
            + subs.map { WorkBin(anchorName: nil, segments: $0.segments) }

        for _ in 0..<max(refineIterations, 0) {
            let centroids: [[Float]] = bins.map { bin in
                let inMeeting = weightedCentroid(bin.segments)
                if !inMeeting.isEmpty { return inMeeting }
                if let name = bin.anchorName,
                   let voiceprint = voiceprints.first(where: { $0.name == name }) {
                    return voiceprint.embedding
                }
                return []
            }
            var regrouped = [[SpeakerSegment]](repeating: [], count: bins.count)
            for segment in target {
                var bestIndex = -1
                var bestScore: Float = -2
                for (index, centroid) in centroids.enumerated() where !centroid.isEmpty {
                    let score = VoiceprintStore.cosine(centroid, segment.embedding)
                    if score > bestScore { bestScore = score; bestIndex = index }
                }
                if bestIndex >= 0 { regrouped[bestIndex].append(segment) }
            }
            for index in 0..<bins.count { bins[index].segments = regrouped[index] }
            bins.removeAll { $0.segments.isEmpty }
        }

        // 3c. bins pequenos são absorvidos pelo vizinho mais próximo
        let smallBins = bins.filter { $0.airtime < minSubSeconds }
        bins.removeAll { $0.airtime < minSubSeconds }
        for small in smallBins {
            guard !bins.isEmpty else { bins.append(small); continue }
            let smallCentroid = weightedCentroid(small.segments)
            var bestIndex = 0
            var bestScore: Float = -2
            for (index, bin) in bins.enumerated() {
                let score = VoiceprintStore.cosine(weightedCentroid(bin.segments), smallCentroid)
                if score > bestScore { bestScore = score; bestIndex = index }
            }
            bins[bestIndex].segments += small.segments
        }

        var output: [SubdivisionBin] = bins
            .filter { $0.anchorName != nil }
            .map { SubdivisionBin(id: $0.anchorName!, anchorName: $0.anchorName, segments: $0.segments) }
            .sorted { $0.airtime > $1.airtime }
        let novos = bins.filter { $0.anchorName == nil }
            .sorted { $0.airtime > $1.airtime }
        for (index, bin) in novos.enumerated() {
            output.append(SubdivisionBin(id: "novo-\(index + 1)", anchorName: nil, segments: bin.segments))
        }
        return output
    }

    /// Refinamento pós-diarização (bloco 12): cluster SUSPEITO — contém voz
    /// conhecida com pureza baixa (<0,90) ou mais de uma voz conhecida — é
    /// subdividido em âncoras + novos falantes ("Falante N" nomeáveis).
    /// Validado em uma reunião de teste: blob de 55,8min virou Pessoa A 0,97 + Pessoa D
    /// 0,92 + 3 vozes novas (Luana/Pessoa C/Felipe). Os ids resultantes voltam
    /// como `protected`: não podem ser fundidos nem filtrados depois.
    public static func refineClusters(
        _ segments: [SpeakerSegment],
        voiceprints: VoiceprintStore
    ) -> (segments: [SpeakerSegment], protected: Set<String>) {
        let prints = voiceprints.all()
        guard !prints.isEmpty else { return (segments, []) }
        let embeddings = clusterEmbeddings(from: segments)
        let times = airtimes(segments)

        var nextId = (segments.compactMap { Int($0.speakerId) }.max() ?? 0) + 1
        var untouched = segments
        var reissued: [SpeakerSegment] = []
        var protected: Set<String> = []

        for (cluster, embedding) in embeddings {
            let matched = voiceprints.matches(for: embedding)
            let airtime = times[cluster] ?? 0
            let suspicious = airtime >= 120
                && (matched.count >= 2 || (matched.first.map { $0.score < 0.90 } ?? false))
            guard suspicious else { continue }

            let bins = subdivideCluster(cluster, segments: segments, voiceprints: prints)
            guard bins.count >= 2 else { continue }

            untouched.removeAll { $0.speakerId == cluster }
            for (index, bin) in bins.enumerated() {
                let id: String
                if index == 0 {
                    id = cluster  // o maior bin herda o id original
                } else {
                    id = String(nextId)
                    nextId += 1
                }
                protected.insert(id)
                reissued += bin.segments.map {
                    SpeakerSegment(speakerId: id, start: $0.start, end: $0.end, embedding: $0.embedding)
                }
            }
        }
        return (untouched + reissued, protected)
    }

    /// Nota de confiança dos rótulos por voz, para o prompt do resumo — o LLM
    /// deve DUVIDAR de rótulos fracos (exemplo: cluster contaminado rotulado
    /// "Pessoa A 0,84" continha a Pessoa C; o resumo corrigiu pelo contexto).
    public static func confidenceNote(_ speakers: [MeetingSpeaker]) -> String? {
        let lines = speakers.compactMap { speaker -> String? in
            if speaker.confirmed {
                return "\(speaker.label): confirmado pelo usuário"
            }
            guard let best = speaker.suggestions.first, speaker.label == best.name else { return nil }
            return "\(speaker.label): \(Int(best.score * 100))% de confiança"
        }
        guard !lines.isEmpty else { return nil }
        return """


        IDENTIFICAÇÃO DOS FALANTES POR VOZ (índice de confiança):
        \(lines.joined(separator: "\n"))
        Abaixo de ~90%, o rótulo pode estar errado ou o falante pode conter MAIS DE UMA pessoa \
        (vozes parecidas coladas pela diarização). Confirme pelo contexto — como as pessoas se \
        chamam na conversa — e, se divergir, use o nome do contexto no resumo sinalizando a \
        correção (ex.: "rotulado X pela voz, mas o contexto indica Y").
        """
    }

    // MARK: - Persistência por reunião

    public static func speakersURL(for meeting: Meeting) -> URL {
        meeting.folderURL.appendingPathComponent("speakers.json")
    }

    public static func load(for meeting: Meeting) -> [MeetingSpeaker] {
        guard let data = try? Data(contentsOf: speakersURL(for: meeting)),
              let speakers = try? JSONDecoder().decode([MeetingSpeaker].self, from: data)
        else { return [] }
        return speakers
    }

    public static func save(_ speakers: [MeetingSpeaker], for meeting: Meeting) {
        guard let data = try? JSONEncoder().encode(speakers) else { return }
        try? data.write(to: speakersURL(for: meeting), options: .atomic)
    }

    /// Troca o rótulo de um falante num texto já gerado (resumo/follow-up),
    /// sem chamada de LLM. Trata "Falante 5 (Pessoa B)" e "Pessoa B (Falante 5)"
    /// antes do replace simples (não sobra "Pessoa B (Pessoa B)") e protege
    /// ocorrências já corretas (renomear "Pessoa B" → "Pessoa B Exemplo" não pode
    /// virar "Pessoa B Exemplo Soares").
    public static func relabel(_ text: String, from oldLabel: String, to newLabel: String) -> String {
        guard oldLabel != newLabel, !oldLabel.isEmpty, !newLabel.isEmpty else { return text }
        let old = NSRegularExpression.escapedPattern(for: oldLabel)
        let new = NSRegularExpression.escapedPattern(for: newLabel)
        let template = NSRegularExpression.escapedTemplate(for: newLabel)

        func replace(_ pattern: String, in text: String, with template: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { return text }
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }

        var result = text
        result = replace("\\b\(old)\\s*\\(\\s*\(new)\\s*\\)", in: result, with: template)
        result = replace("\\b\(new)\\s*\\(\\s*\(old)\\s*\\)", in: result, with: template)
        let sentinel = "\u{E000}"
        result = replace("\\b\(new)\\b", in: result, with: sentinel)
        result = replace("\\b\(old)\\b", in: result, with: template)
        result = result.replacingOccurrences(of: sentinel, with: newLabel)
        return result
    }

    /// Renomeia um falante: atualiza speakers.json, reescreve o transcript a
    /// partir do segments.json, troca o rótulo no resumo/follow-up já gerados
    /// e ensina a voz à memória. Tudo local — nenhuma chamada de LLM.
    public static func rename(
        cluster: String,
        to name: String,
        meeting: Meeting,
        voiceprints: VoiceprintStore
    ) {
        var speakers = load(for: meeting)
        guard let index = speakers.firstIndex(where: { $0.cluster == cluster }) else { return }
        let oldLabel = speakers[index].label
        // corrigir um nome já confirmado desfaz o aprendizado errado primeiro
        if speakers[index].confirmed, oldLabel != name {
            voiceprints.unlearn(name: oldLabel, embedding: speakers[index].embedding)
        }
        speakers[index].label = name
        speakers[index].confirmed = true
        save(speakers, for: meeting)
        voiceprints.learn(name: name, embedding: speakers[index].embedding)

        // troca o rótulo antigo nos textos já gerados — SÓ quando era placeholder
        // ("Falante N"): trocar nome real por nome real faria replace cego em
        // menções legítimas da pessoa antiga (ex.: Pessoa D citada no resumo de
        // uma reunião onde o cluster "Pessoa D" era na verdade a Pessoa C)
        if oldLabel.hasPrefix("Falante ") {
            for file in ["resumo.md", "followup.md"] {
                let url = meeting.folderURL.appendingPathComponent(file)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let updated = relabel(text, from: oldLabel, to: name)
                if updated != text {
                    try? updated.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }

        rewriteTranscript(meeting: meeting, speakers: speakers)
    }

    /// Desfaz um nome (volta para "Falante N"): reverte o voiceprint aprendido
    /// e reescreve o transcript — o "cancelar" de uma confirmação errada.
    public static func unname(cluster: String, meeting: Meeting, voiceprints: VoiceprintStore) {
        var speakers = load(for: meeting)
        guard let index = speakers.firstIndex(where: { $0.cluster == cluster }) else { return }
        if speakers[index].confirmed {
            voiceprints.unlearn(name: speakers[index].label, embedding: speakers[index].embedding)
        }
        speakers[index].label = "Falante \(cluster)"
        speakers[index].confirmed = false
        save(speakers, for: meeting)
        rewriteTranscript(meeting: meeting, speakers: speakers)
    }

    /// Reescreve segments.json + transcript.md com os rótulos atuais.
    private static func rewriteTranscript(meeting: Meeting, speakers: [MeetingSpeaker]) {
        let segmentsURL = meeting.folderURL.appendingPathComponent("segments.json")
        guard let data = try? Data(contentsOf: segmentsURL),
              var utterances = try? JSONDecoder().decode([Utterance].self, from: data)
        else { return }
        let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.cluster, $0.label) })
        for i in utterances.indices {
            if let cluster = utterances[i].cluster, let label = labels[cluster] {
                utterances[i].speaker = label
            }
        }
        if let updated = try? JSONEncoder().encode(utterances) {
            try? updated.write(to: segmentsURL, options: .atomic)
        }
        let transcript = TranscriptBuilder.render(title: meeting.title, utterances: utterances)
        try? transcript.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)
    }

    /// Mescla dois falantes que a diarização separou mas são a mesma pessoa:
    /// as falas do `source` passam para o `target`, transcript/resumo são
    /// reescritos e o voiceprint do alvo é reforçado. Local, sem LLM.
    public static func merge(
        cluster source: String,
        into target: String,
        meeting: Meeting,
        voiceprints: VoiceprintStore
    ) {
        guard source != target else { return }
        var speakers = load(for: meeting)
        guard let sourceIndex = speakers.firstIndex(where: { $0.cluster == source }),
              let targetSpeaker = speakers.first(where: { $0.cluster == target })
        else { return }
        let sourceSpeaker = speakers[sourceIndex]
        if targetSpeaker.confirmed, !sourceSpeaker.embedding.isEmpty {
            voiceprints.learn(name: targetSpeaker.label, embedding: sourceSpeaker.embedding)
        }
        speakers.remove(at: sourceIndex)
        save(speakers, for: meeting)

        let segmentsURL = meeting.folderURL.appendingPathComponent("segments.json")
        guard let data = try? Data(contentsOf: segmentsURL),
              var utterances = try? JSONDecoder().decode([Utterance].self, from: data)
        else { return }
        for i in utterances.indices where utterances[i].cluster == source {
            utterances[i].cluster = target
            utterances[i].speaker = targetSpeaker.label
        }
        if let updated = try? JSONEncoder().encode(utterances) {
            try? updated.write(to: segmentsURL, options: .atomic)
        }
        let transcript = TranscriptBuilder.render(title: meeting.title, utterances: utterances)
        try? transcript.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)

        // o rótulo antigo some também do resumo/follow-up (só se era placeholder
        // — nome real por nome real exige Refazer resumo, não replace cego)
        if sourceSpeaker.label.hasPrefix("Falante ") {
            for file in ["resumo.md", "followup.md"] {
                let url = meeting.folderURL.appendingPathComponent(file)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let updated = relabel(text, from: sourceSpeaker.label, to: targetSpeaker.label)
                if updated != text {
                    try? updated.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
