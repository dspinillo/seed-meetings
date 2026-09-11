# Conectar um cliente MCP

O servidor opcional `seed-mcp` expõe ferramentas de consulta por stdio. Não abre
porta de rede e não inicia automaticamente junto com o app.

```bash
swift build -c release --product seed-mcp
```

No cliente compatível, configure o caminho **absoluto** do executável:

```json
{
  "mcpServers": {
    "seed": {
      "command": "/caminho/para/seed-meetings/.build/release/seed-mcp",
      "args": []
    }
  }
}
```

O esquema de configuração varia por cliente; o trecho acima ilustra o formato
`mcpServers`. Reinicie/recarregue o cliente após configurar.

| Ferramenta | Uso |
| --- | --- |
| `list_meetings` | Listar por período, pasta, tag e limite |
| `get_meeting` | Ler metadados, participantes, notas e resumo |
| `get_transcript` | Ler a transcrição completa |
| `search_meetings` | Buscar texto nas reuniões |

Por padrão lê `~/Documents/Seed`. Para isolamento, defina `SEED_DATA_DIR` no
ambiente do servidor com outro caminho absoluto. Autorize apenas clientes nos
quais confia: eles passam a poder ler as reuniões, e podem enviar conteúdo ao
motor remoto do próprio cliente. O servidor não precisa de credenciais de IA.
