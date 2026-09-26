# Como contribuir

Obrigado por ajudar. Relatos de bug, correções para versões novas da extensão e melhorias pequenas são bem-vindos.

## Antes de começar

- Para qualquer coisa maior que uma correção pequena, abra uma issue antes, para combinarmos o caminho.
- Se uma versão nova da extensão do Claude Code quebrou algo, rode `pwsh -File .\Excluir-SessoesClaude.ps1 -Probe`, compare com o que o VS Code mostra e coloque os dois na issue (com os títulos das sessões ocultados). Quase sempre isso basta para achar qual chave mudou.

## Ambiente

Você precisa de Windows 10 ou 11 e PowerShell 7. Não há outra dependência.

```powershell
git clone https://github.com/bsgustavo/delete-claude-sessions.git
cd delete-claude-sessions
pwsh -File .\tests\Executar-Testes.ps1
```

Os testes montam um `~\.claude` e um `state.vscdb` falsos em `tests\tmp`, então nunca tocam nas suas sessões reais. Eles precisam passar na sua máquina e na CI antes do merge de um pull request.

Se a mudança mexe na janela, rode também `pwsh -File .\tests\Executar-Testes.ps1 -Janela`: ele abre o app com os dados falsos e clica nos botões por UI Automation. Uma janela aparece por alguns segundos; não digite enquanto ele roda.

## Regras do projeto

- **Nunca gravar no `state.vscdb`.** O VS Code mantém o conteúdo em memória e sobrescreve mudanças feitas de fora.
- **A exclusão continua atrás da confirmação por `delete` e vai para a Lixeira.** Mudança que enfraqueça qualquer um dos dois precisa de um motivo muito bom e de conversa antes.
- **Textos novos da janela vão na tabela `$T`** do `Excluir-SessoesClaude.ps1`.
- **Capturas de tela só com dados de demonstração**, nunca títulos de sessões reais.
- **Arquivos:** UTF-8 com BOM e CRLF nos `.ps1` (ver `.editorconfig`). Código, comentários e documentação em português.

## Commits

[Conventional Commits](https://www.conventionalcommits.org), em português:

```
<tipo>(<escopo opcional>): <descrição no imperativo, minúsculo, sem ponto final>

<corpo opcional: o porquê da mudança; o diff já mostra o quê>
```

- Tipos: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Assunto com até 50 caracteres, no imperativo ("adiciona", não "adicionado"), sem emoji.
- Um commit por mudança lógica.
- Mudança que quebra compatibilidade: `feat!:` ou rodapé `BREAKING CHANGE:`.

Exemplos:

```
fix: le os grupos depois da troca de chave na extensao
feat(janela): adiciona busca por texto na lista
```

## Branches e pull requests

- Crie a branch a partir da `main` como `<tipo>/<descricao-curta-em-kebab>`, por exemplo `fix/troca-chave-grupos`.
- Título do pull request no mesmo formato de Conventional Commit.
- Preencha o template: contexto, o que muda, como testar e um print quando mexer na janela.

## Versões

[SemVer](https://semver.org/lang/pt-BR/): `fix` sobe o PATCH, `feat` sobe o MINOR e mudança que quebra compatibilidade sobe o MAJOR. Toda versão ganha uma tag `vX.Y.Z`, uma release no GitHub e uma entrada no [CHANGELOG.md](CHANGELOG.md) (formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)).
