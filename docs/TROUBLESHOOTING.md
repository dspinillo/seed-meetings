# Solução de problemas

## O motor está verde, mas não responde

Verde significa CLI encontrado (ou Ollama respondendo), não login e cota
validados. Abra `claude`, `codex` ou `agy` no Terminal e conclua a autenticação.
Teste uma pergunta fictícia. Confirme que sua conta tem acesso ao modelo
selecionado. Em Codex, experimente “Padrão do CLI”. Não há troca silenciosa de
modelo em caso de falha.

Se o CLI funciona no Terminal mas não no app, feche e abra o Seed após instalar.
O app procura em locais usuais, como `~/.local/bin`, `/opt/homebrew/bin` e
`/usr/local/bin`, e consulta o PATH do shell de login. “Verificar IAs de novo”
atualiza o indicador. Use um CLI atual compatível com os parâmetros listados no README.

## Resumo vazio, com link ou mensagem de erro

Atualize o Seed e o CLI. O app captura o resultado final estruturado, pede o
conteúdo inline e repete uma vez quando o resumo não tem as seções markdown
esperadas. Se as duas respostas forem inválidas, mantém o resumo anterior e
informa erro. Use a ação de gerar novamente; não precisa transcrever tudo outra vez.

Um resumo antigo contendo só um link não é convertido automaticamente: o app
não abre caminhos de arquivos sugeridos pelo modelo. Gere novamente, ou recupere
manualmente um arquivo que você conheça e confie, mantendo backup do original.

## Chat ao vivo sem resposta útil

Aguarde as primeiras falas transcritas. O chat usa um snapshot do que estava
disponível ao enviar a pergunta, não áudio ainda não transcrito. A resposta
aparece inteira ao terminar a geração. Verifique o motor selecionado em
Preferências → Resumos. Para erros de cota/contexto, troque o modelo ou tente
uma reunião menor. Não é possível garantir atribuições de falantes sem revisão.

## Sem áudio ou vozes trocadas

Confira as permissões de Microfone e Gravação de Áudio do Sistema nos Ajustes
do macOS. Selecione o microfone em Preferências → Transcrição. Fones Bluetooth
podem mudar o dispositivo padrão; escolha um dispositivo fixo se necessário.
A captura do sistema pode incluir outros sons do Mac, além da reunião.

Para diarização incorreta, revise “Quem é quem”, confirme nomes e mescle falantes
quando fizer sentido. O refino em segundo plano pode melhorar a separação.

## A detecção não aparece

Deixe o Seed aberto. Para Meet, use o Chrome, entre na sala e confira a permissão
de Automação do Chrome. Para Teams, confira o app e o uso do microfone.
Preferências → Detecção → “Testar detecção agora” mostra os sinais usados.
Detecção nunca inicia gravação sem confirmação; use gravação manual se necessário.

Até a versão 0.2.1, a detecção podia parar depois de muitas horas com o app
aberto (o `.detector.log` mostra `não consegui rodar o osascript: … Bad file
descriptor`). Atualize para a 0.3.0 ou reinicie o Seed.

## O app demora a abrir, trava ao gravar ou fecha sozinho

Na 0.2.1 e anteriores os dados ficavam em `~/Documents/Seed`. Com Documentos no
iCloud e “Otimizar Armazenamento do Mac”, o macOS remove os arquivos do disco e
cada leitura espera o download. A 0.3.0 move a pasta para
`~/Library/Application Support/Seed` na primeira abertura; essa primeira
abertura pode demorar enquanto o macOS baixa o que estava só na nuvem.

Confira também o espaço livre: gravação, modelos de reconhecimento e a memória
virtual do macOS precisam de alguns gigabytes. Com o disco quase cheio o Mac
inteiro pode ficar lento ou congelar.

Se o app fechar sozinho, as últimas linhas de `.detector.log`, na pasta de
dados, registram o encerramento (`encerramento: SIGTERM recebido`,
`willTerminate do AppKit`) e se a interface estava respondendo. Uma gravação
interrompida é retomada na próxima abertura, depois que a máquina ficar livre.

## Claude não responde: “Exec format error”

Algumas instalações via npm deixam em `/usr/local/bin/claude` um arquivo de texto
que só imprime “claude native binary not installed”. Versões até a 0.2.1
escolhiam esse arquivo. A 0.3.0 ignora executáveis que não são binários nem
scripts e também procura em instalações do nvm. Rode `claude` no Terminal para
confirmar que o CLI abre; se não abrir, reinstale-o.

## A classificação não aparece

Ela é gerada depois de um resumo novo (ou de “Refazer o resumo”); reuniões
antigas não são classificadas sozinhas. Confira **Preferências → Resumos →
Classificar reuniões**. Se o motor devolver algo fora do formato duas vezes, a
reunião fica sem classificação e o resumo não é afetado — use “Classificar de
novo” no selo, ou “Refazer o resumo”.

## A busca semântica não encontra nada

1. O Ollama precisa estar aberto (`ollama list` deve responder).
2. O modelo precisa estar baixado: `ollama pull embeddinggemma-2:270m`, ou o
   nome que estiver em Preferências → Resumos → Modelo de embedding.
3. Só reuniões prontas e já refinadas entram no índice, e a indexação espera
   não haver gravação em andamento. Com o CLI de diagnóstico, `seed-spike index`
   mostra o que foi indexado e `seed-spike search "consulta"` mostra os scores.
4. Trocar o modelo de embedding reindexa todas as reuniões.

Resultados fora do assunto podem aparecer: os limiares são preliminares.

## O atalho de voz não funciona

Confira o atalho e o modo Segurar/Apertar 2× em Preferências → Geral. Teste um
atalho diferente em caso de conflito. Silencie seu microfone na chamada antes
de ditar; o app não silencia o Meet/Teams por você.

## Dicionário já preenchido depois de reinstalar

Atualizações preservam `~/Library/Application Support/Seed/.glossario.json`. Uma instalação nova
não inclui termos. Edite as entradas existentes na tela de Transcrição. Não
substitua seu arquivo por um glossário de outra pessoa.

## Compilação ou primeira transcrição lenta

Use Swift 6/Xcode ou Command Line Tools atualizados e macOS compatível. A
primeira compilação baixa dependências; a primeira transcrição baixa modelos.
Mantenha internet e espaço livre. Avisos de concorrência do modo Swift 5 podem
aparecer no build; erros de compilação devem ser reportados com versão do macOS,
Swift e o trecho mínimo do erro, sem dados pessoais.
