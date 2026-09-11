# Desenvolvimento

## Arquitetura

| Diretório | Responsabilidade |
| --- | --- |
| `Sources/SeedKit` | Captura, transcrição, diarização, dados, motores e pipeline |
| `Sources/SeedApp` | Interface SwiftUI/AppKit, atalhos e estado do app |
| `Sources/SeedSpikeCLI` | CLI de diagnóstico e processamento |
| `Sources/SeedMCP` | Servidor de consulta MCP por stdio |
| `Tests/SeedKitTests` | Testes unitários e integração opt-in |
| `packaging` | Info.plist e ícones do app |
| `scripts` | Certificado local e auditoria de distribuição |

A dependência FluidAudio é fixada em `Package.swift`/`Package.resolved`.

## Testes sem dados reais

```bash
SEED_DATA_DIR="$(mktemp -d)" swift test
```

`SEED_DATA_DIR` aceita um caminho absoluto. É usado para preferências, glossário,
reuniões e memória de vozes. Sem override, o app usa `~/Documents/Seed`.
Os testes normais não chamam os motores remotos. Para exercitar de verdade os
CLIs autenticados (consome a cota da conta):

```bash
SEED_DATA_DIR="$(mktemp -d)" SEED_LIVE_TESTS=1 \
  swift test --filter ProviderIntegrationTests
```

Esse teste usa uma reunião fictícia, verifica resumo inline, pergunta ao vivo,
continuidade após a gravação e persistência do histórico. Executa nos quatro
modelos Codex do seletor e no Antigravity. Requer acesso a todos esses modelos;
falhas de conta/modelo não são mascaradas por fallback automático.

O transporte usa diretórios temporários privados e arquivos para stdin/stdout/
stderr, evitando deadlock com saídas grandes. Esses temporários são removidos
na conclusão normal. Codex recebe o prompt via stdin e devolve o resultado em
`--output-last-message`; Antigravity usa eventos JSON e exige um resultado final
bem-sucedido. O resumo tem validação de formato e uma tentativa de correção;
isso não valida a veracidade do conteúdo.

## Publicar uma versão

1. Execute os testes locais e, quando alterar integrações, os testes reais.
2. Revise documentos, exemplos e capturas para não publicar dados pessoais.
3. Compile `make app` (inclui `seed-mcp`) e confira a assinatura com `codesign --verify --deep --strict dist/Seed.app`.
4. Empacote somente o bundle. Nunca copie `~/Documents/Seed`, caches dos CLIs ou `.build` para a release.
5. Em builds comunitários, remova símbolos de debug (`strip -S`) antes de assinar a cópia de distribuição ad-hoc. Publique o zip e SHA-256 numa release.
6. Execute `python3 scripts/audit-distribution.py` no diretório público antes de enviar.

Releases comunitárias não são notarizadas. Uma distribuição notarizada exige
credenciais próprias do programa Apple Developer; não publique certificados,
chaves ou perfis pessoais no repo.

## Contribuir

Abra uma issue com versão, passos mínimos e comportamento esperado/observado.
Use nomes e transcrições fictícios. Não envie logs completos de CLI, tokens,
prints de reuniões reais ou arquivos da pasta de dados. Novas preferências
precisam de defaults retrocompatíveis. Novos motores devem funcionar sem
interação no Terminal e retornar só o texto final para resumo e chat.

## MCP

`make mcp` compila somente o servidor. `make test-mcp` valida as sete ferramentas
por stdio, incluindo paginação e áudio WAV/CAF fictício. O guia [MCP](MCP.md)
descreve configuração de clientes, formatos de resposta e teste opcional com agente.
