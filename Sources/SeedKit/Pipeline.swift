import FluidAudio
import Foundation

/// Trava assíncrona FIFO. O DiarizerManager do FluidAudio NÃO é thread-safe:
/// crash real em 10/07 — o launch disparou 3 process() concorrentes (órfã +
/// 2 refinos retomados) e morreu com SIGSEGV em Speaker.recalculateMainEmbedding.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// Pipeline pós-reunião: transcreve as 2 trilhas, diariza, reconhece vozes
/// conhecidas, monta o transcript intercalado e gera o resumo (mesclando as
/// notas do usuário, de gravação) via claude -p.
public final class Pipeline {
    public static let shared = Pipeline()

    private let asr = SpikeASR()
    private let diarizer = SpikeDiarizer()
    /// Um process() por vez (ver AsyncGate) + dedup por reunião.
    private let gate = AsyncGate()
    /// Serializa os trechos curtos (live tick × nota por voz) no mesmo ASR,
    /// sem esperar atrás de um refino completo como o gate principal.
    private let liveGate = AsyncGate()
    private var inFlight: Set<String> = []
    private let inFlightLock = NSLock()

    private init() {}

    /// Pré-carrega os modelos de ASR (chamar no launch do app para o primeiro
    /// resumo não pagar o custo de carregamento).
    public func warmUp() async {
        try? await asr.load()
    }

    /// Transcreve um trecho avulso (usado pela transcrição ao vivo) reusando
    /// os modelos já carregados.
    public func transcribeSamples(_ samples: [Float]) async throws -> String {
        await liveGate.acquire()
        defer { liveGate.release() }
        try await asr.load()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try LiveWav.write(samples, to: url)
        return try await asr.transcribe(url)
    }

    /// Caminho RÁPIDO pós-reunião: usa as falas da transcrição ao vivo como
    /// transcript e gera o resumo na hora (~1 min). O refino de qualidade
    /// total roda depois via `process(silent: true)` e substitui os arquivos.
    public func finishFast(
        _ meeting: Meeting,
        store: MeetingStore,
        utterances: [Utterance],
        progress: @escaping @Sendable (String) -> Void
    ) async -> Meeting {
        guard !utterances.isEmpty else {
            // sem transcript ao vivo → pipeline completo padrão
            return await process(meeting, store: store, progress: progress)
        }
        var updated = store.update(meeting) {
            $0.status = .processing
            $0.errorMessage = nil
        }
        do {
            let merged = Glossary.apply(to: utterances.sorted { $0.start < $1.start })
            if let data = try? JSONEncoder().encode(merged) {
                try? data.write(to: meeting.folderURL.appendingPathComponent("segments.json"))
            }
            let transcript = TranscriptBuilder.render(title: meeting.title, utterances: merged)
            try transcript.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)

            progress("Gerando resumo…")
            let summary = try Summarizer.summarize(
                transcript: transcript,
                meetingName: meeting.title,
                userNotes: store.readNotes(meeting),
                template: meeting.summaryTemplate
            )
            try summary.write(to: meeting.summaryURL, atomically: true, encoding: .utf8)

            updated = store.update(updated) {
                $0.status = .ready
                $0.refined = false
            }
            return updated
        } catch {
            // qualquer falha no caminho rápido cai no pipeline completo
            return await process(meeting, store: store, progress: progress)
        }
    }

    /// Processa a reunião e devolve o Meeting atualizado (ready ou failed).
    /// Com `silent: true` (refino em 2º plano), não altera status/erro — só
    /// substitui os arquivos ao final, preservando a UI já em "ready".
    public func process(
        _ meeting: Meeting,
        store: MeetingStore,
        silent: Bool = false,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Meeting {
        // dedup: se esta reunião já está na esteira, não processa em dobro
        inFlightLock.lock()
        if inFlight.contains(meeting.id) {
            inFlightLock.unlock()
            return store.read(folderURL: meeting.folderURL) ?? meeting
        }
        inFlight.insert(meeting.id)
        inFlightLock.unlock()
        defer {
            inFlightLock.lock()
            inFlight.remove(meeting.id)
            inFlightLock.unlock()
        }

        // um pipeline por vez: ASR/diarização compartilham modelos mutáveis
        progress("Na fila…")
        await gate.acquire()
        defer { gate.release() }

        var updated = meeting
        if !silent {
            updated = store.update(meeting) {
                $0.status = .processing
                $0.errorMessage = nil
            }
        }

        do {
            progress("Carregando modelos…")
            try await asr.load()

            progress("Transcrevendo sua trilha…")
            // trilha do mic vazia/ilegível (captura falhou) não pode matar o
            // refino — segue só com a dos outros (caso real 10/07: mic 0 bytes)
            let micResult = try? await asr.transcribeDetailed(meeting.micURL)
            if micResult == nil {
                fputs("[pipeline] trilha do mic ilegível — seguindo só com a trilha do sistema\n", stderr)
            }

            progress("Transcrevendo os outros participantes…")
            let systemResult = try await asr.transcribeDetailed(meeting.systemURL)

            var segments: [SpeakerSegment] = []
            do {
                progress("Separando vozes…")
                try await diarizer.load()
                // clusters suspeitos são subdivididos em âncoras (vozes
                // conhecidas) + novos falantes; depois a limpeza anti-fantasma
                // (bins subdivididos ficam protegidos de fusão/filtro)
                let refined = Speakers.refineClusters(
                    try diarizer.diarize(meeting.systemURL),
                    voiceprints: store.voiceprints
                )
                segments = Speakers.cleanClusters(
                    refined.segments,
                    voiceprints: store.voiceprints,
                    protected: refined.protected
                )
            } catch {
                // diarização não bloqueia o resumo
            }

            progress("Reconhecendo vozes conhecidas…")
            let speakers = Speakers.build(segments: segments, voiceprints: store.voiceprints)
            Speakers.save(speakers, for: meeting)
            let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.cluster, $0.label) })

            let transcript = buildTranscript(
                meeting: meeting,
                micResult: micResult,
                systemResult: systemResult,
                segments: segments,
                labels: labels
            )
            try transcript.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)

            // refino em 2º plano: respeita a economia configurada (mesma IA,
            // uma IA específica, ou manter o resumo rápido)
            let refineSetting = SeedSettings.load().refineProvider
            let skipSummary = silent && refineSetting == "skip"
            if !skipSummary {
                progress("Gerando resumo…")
                let providerOverride: LLMProviderID? =
                    silent && refineSetting != "same" ? LLMProviderID(rawValue: refineSetting) : nil
                let summary = try Summarizer.summarize(
                    transcript: transcript,
                    meetingName: meeting.title,
                    userNotes: store.readNotes(meeting),
                    template: meeting.summaryTemplate,
                    provider: providerOverride,
                    speakersNote: Speakers.confidenceNote(speakers)
                )
                try summary.write(to: meeting.summaryURL, atomically: true, encoding: .utf8)
            }

            // re-lê o meta antes do save final: durante o refino (minutos) o
            // usuário pode ter renomeado/tagueado a reunião — não sobrescrever
            updated = store.update(updated) {
                $0.status = .ready
                $0.refined = true
            }
            return updated
        } catch {
            if silent {
                // refino falhou: mantém os artefatos rápidos, não derruba a UI
                return meeting
            }
            updated = store.update(updated) {
                $0.status = .failed
                $0.errorMessage = "\(error)"
            }
            return updated
        }
    }

    /// Regenera só o resumo (sem re-transcrever) — usado após renomear
    /// falantes, editar notas ou trocar o template.
    public func resummarize(
        _ meeting: Meeting,
        store: MeetingStore,
        progress: @escaping @Sendable (String) -> Void
    ) async -> Meeting {
        var updated = store.update(meeting) { $0.status = .processing }
        do {
            guard let transcript = store.readTranscript(meeting) else {
                throw SeedError("transcript não encontrado — use Reprocessar")
            }
            progress("Gerando resumo…")
            let summary = try Summarizer.summarize(
                transcript: transcript,
                meetingName: meeting.title,
                userNotes: store.readNotes(meeting),
                template: meeting.summaryTemplate,
                speakersNote: Speakers.confidenceNote(Speakers.load(for: meeting))
            )
            try summary.write(to: meeting.summaryURL, atomically: true, encoding: .utf8)
            updated = store.update(updated) { $0.status = .ready }
            return updated
        } catch {
            updated = store.update(updated) {
                $0.status = .failed
                $0.errorMessage = "\(error)"
            }
            return updated
        }
    }

    /// Monta o transcript intercalado (diálogo). Se os timings não vierem,
    /// cai no formato em blocos por trilha.
    private func buildTranscript(
        meeting: Meeting,
        micResult: ASRResult?,
        systemResult: ASRResult,
        segments: [SpeakerSegment],
        labels: [String: String]
    ) -> String {
        let micTimings = micResult?.tokenTimings ?? []
        if let systemTimings = systemResult.tokenTimings,
           !(micTimings.isEmpty && systemTimings.isEmpty) {
            let micUtterances = TranscriptBuilder.utterances(
                from: micTimings, track: "mic", speaker: "Você"
            )
            let systemUtterances = TranscriptBuilder.assignSpeakers(
                TranscriptBuilder.utterances(from: systemTimings, track: "system", speaker: "Falante 1"),
                segments: segments,
                labels: labels
            )
            let merged = Glossary.apply(to: TranscriptBuilder.merge(micUtterances, systemUtterances))

            // segments.json permite renomear falantes sem re-transcrever
            if let data = try? JSONEncoder().encode(merged) {
                try? data.write(to: meeting.folderURL.appendingPathComponent("segments.json"))
            }

            return TranscriptBuilder.render(title: meeting.title, utterances: merged)
        }

        // fallback: formato em blocos (Fase 1)
        let timeline = formatTimeline(segments)
        return """
        # \(meeting.title)

        ## Trilha VOCÊ (microfone)

        \((micResult?.text.isEmpty ?? true) ? "(vazio)" : Glossary.apply(to: micResult?.text ?? ""))

        ## Trilha OUTROS (áudio do sistema)

        \(systemResult.text.isEmpty ? "(vazio)" : Glossary.apply(to: systemResult.text))

        ## Linha do tempo de vozes na trilha OUTROS (diarização)

        \(timeline)
        """
    }
}
