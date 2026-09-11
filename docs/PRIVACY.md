# Privacidade e armazenamento

## O que vem na instalação

O app contém código e recursos visuais. Não contém reuniões, contatos, glossário,
memória de vozes, credenciais ou configurações pessoais. O dicionário inicial é
vazio. Os exemplos de testes são fictícios; as capturas de tela são documentação,
não conteúdo importado pelo app.

Os modelos de reconhecimento são baixados separadamente pelo FluidAudio. Não
são treinados com suas reuniões pelo Seed.

## O que fica no Mac

Por padrão, `~/Documents/Seed/` contém:

| Arquivo | Conteúdo |
| --- | --- |
| `.config.json` | Preferências de motores, modelos, captura e retenção |
| `.glossario.json` | Dicionário cadastrado pelo usuário |
| `.voiceprints.json` | Nomes e vetores da memória de vozes |
| `<reunião>/meta.json` | Título, datas, duração, tags, pasta e estado |
| `mic.caf`, `sistema.caf` (ou `.wav`) | Áudio bruto de microfone/sistema |
| `transcript.md`, `segments.json` | Transcrição e falas com tempos |
| `speakers.json` | Falantes, nomes e sugestões |
| `resumo.md`, `notas.md`, `chat.json` | Resumo, notas e conversa |
| `followup.md` | Rascunho de follow-up, quando gerado |

Notas por voz podem deixar arquivos de recuperação na pasta da reunião. Os
modelos e CLIs também mantêm caches/configurações em seus próprios diretórios.

**Reinstalar ou atualizar não apaga dados existentes.** Assim, um dicionário de
uma instalação antiga continua sendo seu dicionário. Edite/remova as entradas
em Preferências → Transcrição. Para começar completamente do zero, feche o app
e mova sua pasta de dados para um backup antes de reabrir. Não faça isso durante
uma gravação.

O app não criptografa esses arquivos. A proteção depende da conta do macOS,
permissões de arquivos, FileVault e backups. Se Documentos estiver sincronizado
com iCloud ou outro serviço, os arquivos podem ser sincronizados por ele.

## O que é enviado a motores de IA

- Resumo: transcrição, título, notas, glossário e instruções sobre participantes.
- Chat ao vivo: transcrição parcial, notas, horário relativo, pergunta e histórico recente.
- Chat após a reunião: resumo, transcrição, notas, pergunta e histórico recente.
- Follow-up/tarefas: resumos e contexto necessário para o rascunho.

O Seed não envia áudio aos motores de texto. Claude, Codex e Antigravity são
processos externos autenticados pelo próprio usuário. Seus logs, configurações,
plugins e políticas são independentes do Seed. O Codex é chamado com sessão
efêmera e sandbox de leitura; isso não representa promessa de retenção zero
pelo fornecedor. O Antigravity pode manter histórico próprio. As instruções do
Seed pedem resposta direta e nenhum uso de ferramentas, mas prompts não são
uma fronteira de segurança para configurações externas de um agente.

Ollama é acessado em `localhost:11434`. **Somente modelos executados localmente**
mantêm o processamento de texto no dispositivo. Modelos cloud do Ollama usam
serviços remotos.

## Retenção e compartilhamento

A retenção automática remove `mic.caf`, `mic.wav`, `sistema.caf` e `sistema.wav`
quando a reunião supera o prazo configurado. Textos e arquivos de recuperação
não são apagados por essa rotina. Excluir uma reunião remove sua pasta; a memória
de vozes é compartilhada entre reuniões e não é apagada com uma reunião.

O Seed não oferece upload, telemetria própria ou sincronização própria. Copiar
um resumo e conectar o servidor MCP são ações de compartilhamento sob controle
do usuário. Um cliente MCP pode solicitar textos e trechos de áudio e encaminhá-los a serviços externos. Essa saída de áudio pelo cliente é opcional e diferente da transcrição local do Seed. Veja [MCP](MCP.md).

Não envie logs, dumps ou capturas com informações reais em issues públicas.
