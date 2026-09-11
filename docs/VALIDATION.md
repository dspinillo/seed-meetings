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
