# Mudanças

## 0.3.0 — não publicada

### Novo
- **Tópicos**: ligam reuniões sobre o mesmo assunto, com lista cronológica, resumo consolidado com linha do tempo e chat sobre todas elas.
- **Classificação**: temperatura, flags, ferramentas e temas de cada reunião, com evidências; corrigível à mão e desligável.
- **Busca semântica opcional** via Ollama (`embeddinggemma-2:270m`): busca híbrida na biblioteca, trechos para o chat do tópico e sugestão de tópico.
- **Chat**: resposta em streaming com Claude Code e Ollama; modelo rápido do Claude no chat ao vivo; janela recente do transcript para perguntas sobre os últimos minutos.
- **MCP**: `semantic_search`, `list_topics`, `get_topic`; classificação e tópicos em `get_meeting`; filtros `temperature` e `flag`.
- CLI de diagnóstico: `classify`, `topic`, `index`, `search`, `fdleak` e `chat --stream`.

### Mudou
- A pasta de dados passou de `~/Documents/Seed` para `~/Library/Application Support/Seed`, com migração automática. Em Documentos, o iCloud sincronizava os áudios e podia remover arquivos do disco, travando o app.
- O `.detector.log` só registra mudanças de estado e é cortado acima de 1 MB.
- Gravações interrompidas e refinos pendentes são retomados só depois que a máquina fica livre, nunca durante uma gravação.

### Corrigido
- Travamento ao abrir e ao começar a gravar: leituras de disco saíram da thread principal e as preferências ficam em cache.
- O detector vazava 2 descritores de arquivo por ciclo; depois de horas a detecção de reuniões parava até reiniciar o app.
- O modelo de reconhecimento podia ser carregado em paralelo por três caminhos.
- O `claude` real era preterido por um arquivo de texto com bit de execução em `/usr/local/bin`; instalações via nvm não eram encontradas.
- O `.mic.log` ignorava `SEED_DATA_DIR`.
- Encerramentos por sinal agora ficam registrados e fecham os arquivos de áudio.

## 0.2.1
- Servidor MCP incluído no app, com textos paginados e trechos de áudio.

## 0.2.0
- Primeira versão pública.
