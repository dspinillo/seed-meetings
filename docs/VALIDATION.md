# Validação da versão 0.2.0

Executada em 11/09/2026 em macOS/Apple Silicon.

- 46 testes locais passaram: captura auxiliar, segmentação, diarização, persistência, glossário, formato de resumo, seleção de modelo e processos externos.
- Glossário inexistente começa vazio; arquivo inválido não é substituído por dados de exemplo.
- Preferências antigas recebem o padrão do Codex; modelos selecionados sobrevivem à serialização.
- Entrada e saídas grandes foram testadas, incluindo stderr simultâneo e encerramento por timeout.
- Testes reais autenticados passaram com GPT-5.6 Sol, Luna, Terra, GPT-6 Astra e Antigravity: resumo inline, pergunta sobre transcrição ao vivo, continuidade após a reunião e persistência do histórico.
- Todas as chamadas reais usaram uma reunião fictícia em diretório separado. Nenhum conteúdo real foi necessário para essa bateria.

Esses testes exercitam o núcleo chamado pela interface. Não equivalem a teste
manual de cada tela, a uma nova gravação de chamada completa, nem garantem
acesso aos modelos em outras contas. As capturas do README foram fornecidas para
documentação e antecedem o novo seletor Codex. A qualidade factual de resultados
de IA continua exigindo revisão humana.

## MCP na versão 0.2.1

Validado em 11/09/2026 com o executável real, por JSON-RPC/stdio:

- Inicialização/negociação de protocolo, notificações, ping e descoberta das sete ferramentas.
- Listagem, busca sem distinção de acentos/maiúsculas, resumo, notas e transcrição completa reconstruída por páginas.
- Trilhas WAV estéreo 48 kHz e CAF convertidas para áudio MCP WAV mono 16 kHz, decodificado e verificado por um cliente Python.
- Recorte no meio e no fim da trilha, áudio ausente, início além do fim e duração máxima.
- IDs inválidos, links simbólicos para fora da pasta, argumentos negativos/fracionários/booleanos e mensagens JSON inválidas.
- Agente Codex com MCP configurado apenas para o teste: leu um código aleatório presente no resumo, um nome na transcrição e a duração da trilha de uma reunião fictícia.

O teste do agente valida consumo de texto/metadados via MCP. Não valida audição
por um modelo: o áudio foi verificado no cliente de protocolo com decodificação WAV.

## Versão 0.3.0

Executada em 08–10/10/2026 em macOS/Apple Silicon.

- 59 testes locais passaram, 13 deles novos: decodificação e listas fechadas da classificação, exigência de evidências, redução e validação de vetores, prompts de tarefa do embedding, divisão do transcript em trechos, janela recente do chat ao vivo, eventos de streaming do Claude e ordenação/compatibilidade dos tópicos.
- `make test-mcp` validou as dez ferramentas, incluindo classificação e tópicos em `get_meeting`, filtros por temperatura e flag, `list_topics`, `get_topic` e o erro de `semantic_search` com a busca desligada.
- Migração da pasta de dados numa instalação real: 109 arquivos e 2,0 GB movidos de Documentos (com 69 arquivos só no iCloud) para o novo local, com contagem e bytes idênticos.
- Com cópias de reuniões reais em diretório isolado, pelo CLI de diagnóstico: classificação com Claude (Haiku) e Antigravity; streaming com Claude e Ollama; índice de 7 reuniões e 152 trechos, com reindexação idempotente; busca semântica; resumo consolidado e chat de tópico com trechos do índice.
- Vazamento de descritores do detector medido em 25 ciclos: de 4 para 54 antes da correção, de 4 para 4 depois.
- O app foi reiniciado com esta versão sobre a biblioteca real, recuperou uma gravação interrompida e manteve a detecção ativa.

Não validado: inspeção visual das telas novas (tópicos, faixa de classificação,
streaming no chat, novas preferências); classificação e streaming com o Codex;
uma gravação completa de ponta a ponta com esta versão; a migração automática
feita pelo próprio app (a pasta foi movida manualmente antes). Os limiares da
busca semântica e da sugestão de tópico foram calibrados com poucas reuniões do
mesmo gênero e são preliminares.
