# Changelog

Todas as mudanças relevantes do projeto ficam registradas aqui.

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) · Versionamento: [SemVer](https://semver.org/lang/pt-BR/).

## [1.0.0] - 2026-09-26

### Adicionado

- `Excluir-SessoesClaude.ps1`: janela em duas telas. A primeira lista o projeto e os grupos, `Ungrouped` e `Archived sessions`, com contagem. A segunda lista as sessões com título, última atividade, tamanho e situação, para marcar e excluir.
- Grupos e arquivadas lidos do `state.vscdb` do VS Code (só leitura, pelo `winsqlite3.dll` do Windows), com a mesma regra da extensão: sessão arquivada sai do grupo.
- Título na ordem `custom-title` > `ai-title` > `summary` > `last-prompt`.
- Proteção de sessão aberta: processo `claude` vivo (`aberta agora`) ou gravada há menos de 30 segundos (`usada há 12s`), conferida de novo na hora de excluir.
- Botão **Atualizar** nas duas telas (e a tecla F5): relê tudo sem sair da tela atual, mantendo projeto, grupo e marcações. Sessão fechada no VS Code fica liberada; sessão reaberta é desmarcada.
- Confirmação por digitação de `delete` e exclusão para a Lixeira: `.jsonl`, pasta `<id>\`, `file-history` e `session-env`. Só aceita nomes no formato GUID.
- Esc volta da tela de sessões para a de grupos; na tela de grupos, fecha a janela.
- Modo `-Probe`: lista tudo no console, sem janela e sem excluir.
- `Instalar-Atalho.ps1`: atalho "Sessões do Claude" na área de trabalho, pelo alias estável do `pwsh`.
- `tests/Executar-Testes.ps1`: 43 verificações com `~\.claude` e `state.vscdb` falsos; com `-Janela`, mais 9 que abrem a janela de verdade e operam por UI Automation. Tudo roda no GitHub Actions em `windows-latest`.

[1.0.0]: https://github.com/bsgustavo/delete-claude-sessions/releases/tag/v1.0.0
