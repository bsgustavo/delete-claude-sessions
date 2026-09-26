#requires -Version 7
<#
.SYNOPSIS
  Cria (ou remove) o atalho "Sessões do Claude" na área de trabalho, apontando para o
  Excluir-SessoesClaude.ps1 desta pasta. Rodar de novo recria o atalho (útil se a pasta mudou).

.PARAMETER Remover
  Apaga o atalho.
#>
param([switch]$Remover)

$atalho = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Sessões do Claude.lnk'

if ($Remover) {
    if (Test-Path -LiteralPath $atalho) { Remove-Item -LiteralPath $atalho; "Atalho removido: $atalho" }
    else { "Atalho não existe: $atalho" }
    return
}

$app = Join-Path $PSScriptRoot 'Excluir-SessoesClaude.ps1'
if (-not (Test-Path -LiteralPath $app)) { throw "Não achei $app" }

# Alias de execução do pwsh da Microsoft Store: caminho estável entre versões
# (o caminho real, WindowsApps\Microsoft.PowerShell_<versão>_..., muda a cada atualização).
# Instalação por MSI não tem o alias: usa o pwsh do PATH.
$pwsh = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = (Get-Command pwsh -ErrorAction Stop).Source }

$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($atalho)
$s.TargetPath       = $pwsh
$s.Arguments        = "-NoProfile -WindowStyle Hidden -File `"$app`""
$s.WorkingDirectory = $PSScriptRoot
$s.IconLocation     = "$env:SystemRoot\System32\shell32.dll,31"
$s.Description      = 'Listar e excluir sessões do Claude Code (extensão do VS Code)'
$s.Save()

"Atalho criado: $atalho"
"  -> $pwsh $($s.Arguments)"
