# Roadmap: busca, tópicos e classificação

Proposta de evolução discutida em outubro de 2026. Nada aqui está implementado;
o documento registra decisões, ordem de trabalho e riscos.

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

Antes das funcionalidades abaixo, é preciso resolver dois problemas que podem
travar o app. Já existe uma correção local, ainda fora do repositório.

1. **Dados em `~/Documents/Seed`** (`Sources/SeedKit/SeedPaths.swift`). Com
   Documentos no iCloud, áudios e transcripts são sincronizados. Com “Otimizar
   armazenamento do Mac”, os arquivos podem sair do disco e a leitura fica
   bloqueada esperando o download.
2. **Leitura de tudo na abertura** (`AppState.refresh()`). O cache de busca lê
   resumo e transcript de todas as reuniões de forma síncrona.

Direção: guardar os dados fora de Documentos (por exemplo
`~/Library/Application Support/Seed`) e migrar uma vez sem apagar a pasta
antiga. Montar o cache de busca em segundo plano e sob demanda.

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

## Ordem de trabalho

0. Correção do travamento (pré-requisito).
1. Tópicos manuais com chat sobre os resumos.
2. Classificação com o motor atual.
3. Índice com EmbeddingGemma 2: sugestão de tópico, recuperação e busca semântica.
4. Chat ao vivo mais rápido. É independente e pode entrar a qualquer momento.
5. Jev como opção, se um teste em português justificar.
