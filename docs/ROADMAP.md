# Roadmap: busca, tópicos e classificação

Proposta de evolução discutida em outubro de 2026. O documento registra
decisões, ordem de trabalho e riscos, e agora também o que já foi entregue.

## Estado

| Item | Estado |
| --- | --- |
| 0. Travamento na abertura | **Feito** (#2). |
| 1. Tópicos | **Feito**, exceto seleção múltipla na biblioteca (o vínculo é por reunião, no menu de contexto). |
| 2. Classificação | **Feito.** |
| 3. Índice semântico | **Fase A feita** (Ollama, opcional, desligada por padrão). Fase B (MLX Swift) não iniciada. Limiares com calibração preliminar. |
| 4. Chat ao vivo mais rápido | **Feito** para Claude Code e Ollama (streaming); modelo rápido só no Claude. Codex e Antigravity seguem sem streaming. |
| 5. Jev | Não iniciado. |
| 6. Telas compartilhadas | Só plano (ver seção própria). |

## Resumo das decisões

| Componente | Decisão |
| --- | --- |
| Transcrição | Continua no **Parakeet** (FluidAudio/Core ML). |
| Resumo, chat e classificação | Continuam no motor escolhido: Claude Code, Codex, Antigravity ou Ollama. |
| Memória de vozes | Continua com os embeddings de falante do FluidAudio. |
| EmbeddingGemma 2 | Entra **local**, como camada nova de busca e recuperação. Não substitui nada. |
| Jev (TypeSafe AI) | Fica de fora por enquanto. Pode ser reavaliado para classificação fechada em alto volume. |
| Gemini Embedding 2 (API) | Descartado: enviaria transcrições ao Google, contra a proposta local do Seed. |

## Pré-requisito: travamento na abertura

Resolvido na #2. Eram dois problemas que podiam travar o app:

1. **Dados em `~/Documents/Seed`** (`Sources/SeedKit/SeedPaths.swift`). Com
   Documentos no iCloud, áudios e transcripts são sincronizados. Com “Otimizar
   armazenamento do Mac”, os arquivos podem sair do disco e a leitura fica
   bloqueada esperando o download.
2. **Leitura de tudo na abertura** (`AppState.refresh()`). O cache de busca lê
   resumo e transcript de todas as reuniões de forma síncrona.

O que foi feito: os dados passaram para `~/Library/Application Support/Seed`,
com migração automática no primeiro launch, e o cache de busca é montado em
segundo plano. Diferente da direção original, a pasta antiga é **movida**, não
copiada: mantê-la em Documentos deixaria os áudios sincronizando no iCloud e
duas bibliotecas divergentes.

## 1. Tópicos: ligar reuniões sobre o mesmo assunto

Um **Tópico** reúne reuniões com títulos diferentes sobre o mesmo assunto, como
“Planejamento Q4” ou “Churn”. É diferente da **pasta** (`Meeting.folder`):
cada reunião fica em uma pasta só, mas pode pertencer a vários tópicos.

- **Dados:** nome, descrição e lista de reuniões em `topicos.json`, na raiz de
  dados do Seed.
- **Vínculo manual:** selecionar reuniões na biblioteca e usar “Vincular a tópico…”.
- **Chat do tópico:** a primeira versão envia os resumos e as notas das reuniões
  em ordem cronológica. Os resumos de 4 a 10 reuniões cabem no contexto sem
  precisar de embeddings.
- **Linha do tempo:** decisões e pendências de cada reunião, com o que foi
  resolvido e o que segue aberto.
- **Resumo consolidado** do tópico, gerado sob demanda.
- **MCP:** `list_topics` e `get_topic`.
- **Depois (fase 3):** sugestão automática de tópico ao terminar uma reunião,
  confirmada pelo usuário, no mesmo estilo de “Quem é quem”.

**Como ficou:** `topicos.json` guarda nome, descrição, reuniões e o resumo
consolidado; a conversa de cada tópico fica em `.topicos-chat.json`. O vínculo
é feito pelo menu de contexto da reunião (uma por vez; a seleção múltipla ficou
de fora). Linha do tempo e resumo consolidado saem na mesma geração, com as
seções “Onde estamos”, “Linha do tempo”, “Resolvido”, “Em aberto” e “Mudanças
de rumo”. A sugestão automática aparece como chip na tela da reunião quando o
índice semântico está ligado; não há aviso ao terminar a gravação.

## 2. Classificação da reunião

Feita pelo **motor de IA atual**, numa chamada separada e pequena depois do
resumo, em segundo plano. Pode usar um modelo rápido, como o Haiku. A chamada
roda de novo depois do refino.

A resposta é JSON com formato fixo, decodificado com `Codable`. Se não
decodificar, o Seed tenta outra vez, como já faz com o validador do resumo.

```json
{
  "temperatura": "tranquila | neutra | tensa | conflituosa",
  "temperatura_motivo": "Discordância sobre prazo entre produto e suporte",
  "evidencias": [{ "momento": "12:40", "trecho": "..." }],
  "ferramentas": ["Zendesk", "Databricks", "SendGrid"],
  "temas": ["CSAT", "entrega de e-mails"],
  "flags": ["cliente_insatisfeito", "risco_de_prazo", "decisao_pendente", "escalonamento"]
}
```

- `temperatura` e `flags` usam listas fechadas, para filtros e comparação entre
  reuniões. `ferramentas` e `temas` são livres. O glossário ajuda na grafia.
- O resultado fica em `classificacao.json`, na pasta da reunião. Ferramentas e
  temas viram sugestões de tags (`Meeting.tags`).
- **Interface:** selo de temperatura e chips no topo do resumo. Ao clicar,
  aparecem as evidências com `[mm:ss]`. A classificação pode ser corrigida à mão.
- **MCP:** classificação no `get_meeting` e filtro no `search_meetings`.
- Saída estruturada nativa, como `--output-schema` no Codex e `format` com
  schema no Ollama, pode ser adotada depois, onde existir. O formato pedido no
  prompt, com validação, funciona nos quatro motores.

**Como ficou:** a classificação roda depois do resumo rápido, do refino e de
“Refazer o resumo”, e pode ser desligada em Preferências → Resumos. Sem
evidências, a resposta não pode marcar `tensa`/`conflituosa` nem flags: é
rejeitada e pedida de novo, uma vez. Uma classificação corrigida à mão não é
sobrescrita pelas execuções automáticas. Ferramentas e temas aparecem como
chips que viram tag com um clique.

**Cuidados**

- A temperatura vem só do texto: tom de voz e ironia se perdem. As evidências
  são obrigatórias.
- Classificar a reunião, não as pessoas.
- Não usar áudio para detectar emoção: os modelos disponíveis não foram
  treinados para isso.

## 3. Índice semântico com EmbeddingGemma 2

O EmbeddingGemma 2 foi lançado pelo Google DeepMind em 06/10/2026, com licença
Apache 2.0.

- Tem 740M parâmetros no total: 270M de texto, 170M de visão e 300M de áudio,
  estes dois opcionais.
- Gera vetores de 768 dimensões, que podem ser reduzidos para 512, 256 ou 128
  (Matryoshka). Aceita até 8K tokens de entrada.
- No MTEB multilingual, a qualidade de texto é parecida com a do v1
  (61,36 contra 61,15). Não há nota publicada só para português.
- O Foresight, app offline do Google para reuniões no Mac, usa a mesma
  combinação: reconhecimento de fala, Gemma 4 para notas e chat e
  EmbeddingGemma 2 para busca.

**Usos**

- Busca **híbrida** na biblioteca e no MCP: substring + similaridade.
- Sugestão automática de reuniões para um tópico, combinada com ferramentas e
  temas em comum.
- Recuperação de trechos para o chat entre reuniões, para o chat do tópico, para
  reuniões longas e para modelos locais do Ollama com contexto pequeno.

**Implementação**

- **Fase A:** `/api/embed` do Ollama, opcional, ativo quando o servidor estiver
  rodando.
- **Fase B:** MLX Swift só com a parte de texto (cerca de 200 MB de RAM), para
  não depender do Ollama.
- Indexar **depois** da reunião e do refino, em segundo plano, nunca durante a
  gravação.
- Trechos de cerca de 30 a 60 s, com `[mm:ss]`, usando os prompts de tarefa
  `SearchQuery` e `Document`.
- Guardar `model_id` e `dims` no índice e reindexar quando mudarem.
- Comparação direta com o `cosine` que já existe. Com 256 dimensões, o índice
  ocupa cerca de 1 KB por trecho.

**Como ficou (fase A):** modelo `embeddinggemma-2:270m` (só texto) pelo
`/api/embed` do Ollama, vetores cortados para 256 dimensões e renormalizados,
gravados em `indice.json` na pasta de cada reunião com `model`, `dims` e a data
do transcript — mudar qualquer um deles reindexa. A indexação roda em segundo
plano depois do refino e para se uma gravação começar. Vetor com NaN, infinito
ou norma nula é erro, não é gravado.

**Calibração preliminar.** Os scores desse modelo ficam comprimidos. Numa
amostra de 152 trechos de 7 reuniões reais em português, consultas sem relação
chegaram a 0,61–0,66 (uma a 0,71) e consultas relacionadas ficaram em
0,70–0,79; o limiar da busca ficou em 0,70. Z-score e centralização pelo vetor
médio do acervo não separaram melhor. Entre vetores médios de reuniões, a
similaridade foi de 0,89–0,92 para assuntos diferentes do mesmo gênero e 0,98
para o mesmo assunto; o limiar da sugestão de tópico ficou em 0,93. São poucos
dados e todos do mesmo tipo de reunião: rever com um acervo maior antes de
ligar por padrão.

**Riscos**

| Risco | Mitigação |
| --- | --- |
| Usar o áudio do EG2 no lugar da memória de vozes | Não fazer: ele representa o conteúdo do som, não quem fala. |
| Busca só semântica perde nomes, números e termos exatos | Busca híbrida. |
| RAG no lugar do transcript completo piora o chat de uma reunião | Manter o transcript completo quando couber. Usar RAG entre reuniões ou quando não couber. |
| float16 gera NaN ou vetores piorados sem erro | Usar bf16 ou fp32. Validar `isFinite` e a norma de cada vetor. |
| Disputa de ANE e GPU com Parakeet e diarização | Indexar só depois da reunião, com baixa prioridade. |
| Qualidade em português e com erros de transcrição | Testar com reuniões reais antes de ativar por padrão. |

## Chat ao vivo mais rápido

Os embeddings ajudam pouco aqui. O tempo vem do processo novo do CLI a cada
pergunta e da resposta sem streaming. Melhorias independentes:

- modelo rápido, como o Haiku, só no chat ao vivo;
- streaming da resposta (`stream-json` no Claude e no Antigravity);
- para perguntas sobre tempo, como “o que perdi nos últimos 5 min?”, enviar só a
  janela recente do transcript, recortada por `[mm:ss]`.

**Como ficou:** as três melhorias entraram para o Claude Code (modelo rápido
configurável, padrão Haiku, e `stream-json`); o Ollama ganhou streaming; a
janela recente vale para todos os motores. O streaming também atende o chat
depois da reunião e o chat do tópico. Antigravity e Codex continuam respondendo
só ao final.

## Jev (TypeSafe AI): por que fica de fora

O Jev é um modelo de decisão hospedado, lançado em acesso antecipado em
15/09/2026. Ele devolve escolhas, notas ou sim/não com probabilidade calibrada
e não gera texto.

Serviria bem para temperatura, flags e “esta reunião pertence ao tópico X?”.
Não serve para:

- temas livres;
- descobrir ferramentas novas;
- evidências com `[mm:ss]`.

Também exigiria um fornecedor a mais, com chave de API e envio do transcript a
outra nuvem. Os números de qualidade e velocidade são do fabricante e não há
avaliação em português.

## Telas compartilhadas (plano, não iniciado)

Inspirado na captura de telas do Granola: guardar imagens do que os outros
apresentam e usar o conteúdo nas notas. Diferença de proposta: tudo local.

- **Captura:** ScreenCaptureKit (macOS 14+), um frame da janela da reunião a
  cada ~5 s durante a gravação. Começar por Meet e Teams no Chrome, que o
  detector já localiza; Teams desktop e Zoom depois (janelas destacadas são
  mais difíceis de identificar).
- **O que é slide:** sem ler a interface do Meet. Slide fica parado e vídeo de
  câmera muda sempre: guardar um frame só quando ficou estável por duas
  amostras e difere do último guardado, comparando por blocos para tolerar as
  miniaturas de câmera. Dispensa a permissão de Acessibilidade.
- **Não capturar o que não deve:** antes de cada frame, conferir se a aba ativa
  da janela ainda é a da reunião; se não for, pular.
- **Texto:** OCR local (Vision, pt-BR) em cada tela guardada, gravado em
  `telas.json` (momento, arquivo, texto). O texto entra nos prompts de resumo,
  chat e classificação como "telas compartilhadas [mm:ss]" e no índice
  semântico. Nenhuma imagem sai do Mac.
- **Interface e MCP:** faixa "Telas" na reunião, com `[mm:ss]`; ferramentas
  para listar e obter a imagem, no molde do áudio.
- **Armazenamento:** pasta `telas/` na reunião, JPEG reduzido, teto de ~60 por
  reunião (cerca de 20 MB).

**Riscos:** permissão nova de Gravação de Tela, que o macOS volta a pedir de
tempos em tempos; a heurística de "parado" erra com animações, vídeo embutido e
demos ao vivo e precisa de calibração em chamadas reais; capturar tela de
terceiros é mais sensível que áudio — desligado por padrão, com aviso ao ligar.

**Decisões em aberto:** retenção (expirar com o áudio ou manter como o
transcript); enviar só o texto do OCR ou também a imagem a motores
multimodais; capturar ou não quando é o próprio usuário quem apresenta.

**Primeiro passo:** um `seed-spike screens` que captura e deduplica numa
chamada real, para validar a heurística antes de mexer no app.

## Ordem de trabalho

0. Correção do travamento (pré-requisito).
1. Tópicos manuais com chat sobre os resumos.
2. Classificação com o motor atual.
3. Índice com EmbeddingGemma 2: sugestão de tópico, recuperação e busca semântica.
4. Chat ao vivo mais rápido. É independente e pode entrar a qualquer momento.
5. Jev como opção, se um teste em português justificar.
6. Telas compartilhadas, começando pelo spike no CLI.
