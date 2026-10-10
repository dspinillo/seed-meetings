# MCP: reuniões como contexto para agentes de IA

O `seed-mcp` permite que um agente consulte **resumos, transcrições, notas,
participantes e áudio** das reuniões do Seed. O cliente inicia um processo local
e troca mensagens MCP por **stdio**. Não há porta HTTP, upload automático ou
necessidade de o app Seed estar aberto.

O servidor consulta os arquivos salvos. Não inicia gravações, não transcreve,
não gera resumos e não usa o motor escolhido nas Preferências. Quem interpreta
as respostas é o agente/modelo do **cliente MCP**, com a conta e as permissões
desse cliente.

## 1. Obter o servidor

### Pelo app pronto (versão 0.2.1 ou superior)

O servidor acompanha o app. Se você colocou o Seed em Aplicativos, use:

```text
/Applications/Seed.app/Contents/MacOS/seed-mcp
```

Não precisa instalar Swift nem compilar. Abra o app uma vez seguindo as
orientações de segurança do macOS no README. O pacote comunitário não é
notarizado; restrições do macOS também podem afetar a execução do helper.

### Pelo código

```bash
git clone https://github.com/dspinillo/seed-meetings.git
cd seed-meetings
make mcp
```

O executável estará em `.build/release/seed-mcp`. Use seu caminho absoluto na
configuração. `make app` também compila e inclui esse servidor no bundle.

## 2. Conectar o cliente

### Codex CLI

```bash
codex mcp add seed -- /Applications/Seed.app/Contents/MacOS/seed-mcp
codex mcp list
```

Reabra a sessão do Codex após configurar. Para usar uma pasta isolada:

```bash
codex mcp add seed --env SEED_DATA_DIR=/caminho/absoluto/dados-seed -- /Applications/Seed.app/Contents/MacOS/seed-mcp
```

Se `seed` já estiver registrado, remova a configuração anterior com
`codex mcp remove seed` antes de adicioná-lo novamente. Veja a
[documentação oficial do Codex MCP](https://developers.openai.com/codex/mcp).

### Claude Code

```bash
claude mcp add --transport stdio --scope user seed -- /Applications/Seed.app/Contents/MacOS/seed-mcp
claude mcp list
```

Dentro de uma sessão do Claude Code, `/mcp` mostra os servidores e o estado da
conexão. `--scope user` disponibiliza a configuração nos projetos dessa conta
local. Veja a [documentação oficial do Claude Code MCP](https://code.claude.com/docs/en/mcp).

### Outros clientes com suporte a MCP stdio

Este é o formato usado por clientes que aceitam `mcpServers`; o nome do arquivo
e a interface para cadastrar o servidor variam:

```json
{
  "mcpServers": {
    "seed": {
      "command": "/Applications/Seed.app/Contents/MacOS/seed-mcp",
      "args": []
    }
  }
}
```

Para outra pasta de dados, adicione `"env": {"SEED_DATA_DIR": "/caminho/absoluto/dados-seed"}`
à configuração de `seed`. Sem essa variável, o servidor lê `~/Library/Application Support/Seed`
da conta macOS que executa o cliente. Um cliente na nuvem não acessa esse stdio
local diretamente; esta versão não oferece endpoint remoto.

## 3. Pedir ao agente para consultar suas reuniões

Exemplos de prompts:

> Use o MCP seed para listar minhas reuniões dos últimos sete dias e resumir as decisões pendentes. Cite a reunião de origem de cada decisão.

> Busque reuniões sobre orçamento. Leia o resumo e a transcrição da reunião relevante; continue as páginas até terminar. Mostre quem assumiu cada tarefa e cite os tempos disponíveis.

> Na reunião escolhida, liste as trilhas de áudio. Se seu cliente suportar áudio MCP, consulte 15 segundos da trilha system a partir de 120 segundos e compare com a transcrição. Se não suportar, informe a limitação.

O fluxo recomendado é **buscar/listar → selecionar o ID → ler resumo → consultar
transcrição → pedir áudio somente quando necessário**. O áudio não acompanha
as ferramentas de texto automaticamente.

## Ferramentas e argumentos

`semantic_search`, `list_topics`, `get_topic` e os campos de classificação
exigem a versão 0.3.0 ou superior. Todos os argumentos opcionais têm os padrões abaixo. IDs devem vir das
ferramentas de listagem/busca; não são caminhos livres de arquivos.

| Ferramenta | Argumentos | Resultado |
| --- | --- | --- |
| `list_meetings` | `days=30`, `folder?`, `tag?`, `temperature?`, `flag?`, `offset=0`, `limit=50` | Metadados, total e próxima página. `days` até 36500; `limit` até 200. |
| `search_meetings` | `query` obrigatório; `days=90`, `temperature?`, `flag?`, `offset=0`, `limit=50` | Reuniões e trechos encontrados em títulos, tags, resumos e transcrições. |
| `get_meeting` | `id` | Metadados, participantes, notas, resumo, classificação e tópicos. Textos limitados a 20000 caracteres; `summary_truncated` indica resumo cortado. |
| `get_summary` | `id`, `offset=0`, `limit=20000` | Página do resumo salvo, total de caracteres e `next_offset`. |
| `get_transcript` | `id`, `offset=0`, `limit=20000` | Página da transcrição salva com timestamps, total de caracteres e `next_offset`. |
| `semantic_search` | `query` obrigatório; `limit=10` | Trechos de transcrição mais próximos da consulta pelo sentido, com `start_seconds` e `score`. Retorna erro se a busca semântica estiver desligada ou o Ollama parado. |
| `list_topics` | — | Tópicos (grupos de reuniões sobre o mesmo assunto) com descrição e contagem. |
| `get_topic` | `topic_id` | Reuniões do tópico em ordem cronológica e o resumo consolidado salvo, se houver. |
| `list_audio` | `id` | Trilhas `mic` (seu microfone) e `system` (áudio do Mac), disponibilidade e duração em segundos. |
| `get_audio` | `id`, `track` (`mic` ou `system`), `start_seconds=0`, `duration_seconds=15` | Texto descritivo + bloco MCP `audio`, MIME `audio/wav`, base64. Duração máxima: 30 segundos. |

`get_summary` e `get_transcript` aceitam até 180000 caracteres por página. O
`offset` conta caracteres de texto Swift (grapheme clusters), não bytes; **use
o `next_offset` retornado**, sem calculá-lo pelo tamanho em bytes. Quando
`next_offset` for `null`, terminou. Não há truncamento silencioso da transcrição.
As consultas não são snapshots: conteúdo em processamento pode mudar entre páginas.

Os resultados de texto têm `structuredContent` e uma cópia JSON em bloco `text`,
para clientes que só leem texto. Erros de operação usam `isError: true`;
argumentos inválidos usam erro JSON-RPC `-32602`.

## Como o áudio é entregue

O servidor lê `.caf` e `.wav` existentes, extrai o intervalo solicitado e converte
em memória para **WAV PCM mono, 16 kHz, 16 bits**. Um trecho de 30 segundos ocupa
cerca de 960 KB antes do base64. Não grava exportações temporárias na pasta da
reunião e não altera o áudio original. No fim da trilha, retorna só o intervalo
disponível. Os tempos são relativos à trilha; a captura e a transcrição podem
ter pequenas diferenças de alinhamento.

Exemplo de chamada:

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/call",
  "params": {
    "name": "get_audio",
    "arguments": {
      "id": "ID_OBTIDO_NA_LISTAGEM",
      "track": "system",
      "start_seconds": 120,
      "duration_seconds": 15
    }
  }
}
```

O resultado contém um bloco com `"type": "audio"`, `"mimeType": "audio/wav"`
e `"data"` com os bytes em base64. Esse é o
[formato de áudio de ferramentas MCP](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#audio-content).
Um cliente programático pode decodificar `data` como base64 e abrir o WAV ou
encaminhá-lo a um modelo de áudio.

**Suporte ao protocolo MCP não implica suporte a áudio no modelo.** Alguns
clientes podem recusar, descartar ou não encaminhar blocos `audio`. Não assuma
que o agente ouviu a gravação só porque a ferramenta existe. Nesse caso, use
`get_transcript`, ou um cliente/adaptador que trate áudio. Os exemplos Codex e
Claude Code acima configuram a conexão; não prometem reprodução ou compreensão
de áudio em todas as versões/modelos desses clientes.

`list_audio` não devolve bytes. Trilhas expiradas pela retenção, removidas ou
ilegíveis aparecem como indisponíveis. `get_audio` retorna erro se a trilha não
existe, se o início está além do fim, ou se os argumentos são inválidos. Não
há recuperação de áudio apagado nem download da reunião inteira numa única chamada.

## Dados e permissões

O servidor é de consulta: não oferece ferramentas de escrita/exclusão e não
regenera conteúdo. Bloqueia caminhos arbitrários e links simbólicos que escapem
da pasta da reunião. Ele não exige credenciais de IA e não faz chamadas de rede.
Ao iniciar, a camada de armazenamento pode criar a pasta de dados se inexistente.

**Conectar o MCP permite ao cliente ler os textos e solicitar os áudios das
reuniões dessa pasta.** Se o cliente os enviar a um modelo remoto, esse conteúdo
sai do Mac, inclusive o áudio solicitado. Isso é diferente da transcrição local
do Seed. Para restringir o conjunto exposto, use uma pasta separada com apenas
as reuniões autorizadas e configure `SEED_DATA_DIR` para ela.

O servidor lê dados já salvos; a transcrição que está apenas na memória da
interface ao vivo não é exposta por ele. Aguarde o processamento para consultar
o resultado final. Para desconectar, remova o servidor da configuração do cliente.
Leia também [Privacidade](PRIVACY.md).

## Testar e diagnosticar

```bash
make test-mcp
```

Esse teste inicia o executável real, negocia o protocolo, descobre as sete
ferramentas e consulta uma reunião fictícia. Verifica paginação completa, WAV e
CAF, decodificação de áudio, validação de argumentos, erros e bloqueio de links
para arquivos externos. Não usa suas reuniões nem chama uma IA.

Teste opcional com um agente Codex autenticado (consome cota):

```bash
SEED_MCP_AGENT_TEST=1 python3 scripts/test-mcp.py
```

Usa configuração temporária, sem registrar o MCP globalmente; o agente precisa
consultar resumo, transcrição e metadados de áudio fictícios. A decodificação
do áudio é coberta pelo teste do protocolo, não por esse teste do modelo.

Se não aparecerem reuniões, confira o caminho de dados e aumente `days`. Se o
servidor não conectar, confirme o caminho absoluto/executável e as permissões
do macOS. Não rode o app principal como servidor: use `seed-mcp`. Executá-lo
sozinho no Terminal parece não fazer nada porque ele espera JSON-RPC em stdin.
Esta versão negocia MCP `2025-03-26`, `2025-06-18` e `2025-11-25`, com ferramentas
por stdio; não implementa resources, prompts, HTTP nem subscriptions.
