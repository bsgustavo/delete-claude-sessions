#requires -Version 7
<#
.SYNOPSIS
  Testes ponta a ponta com um ~\.claude e um state.vscdb falsos (em tests\tmp).
  Não toca nas sessões reais nem no VS Code. O que a exclusão manda para a Lixeira durante o
  teste é tirado de lá no fim.

.PARAMETER Janela
  Também abre a janela de verdade (com os dados falsos) e opera por UI Automation: Abrir,
  Voltar, Esc e Atualizar. Só mexe na janela que ele mesmo abriu, mesmo que você esteja com
  o app aberto.
#>
[CmdletBinding()]
param([switch]$Janela)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$app  = Join-Path $raiz 'Excluir-SessoesClaude.ps1'
$tmp  = Join-Path $PSScriptRoot 'tmp'

$script:ok = 0; $script:falhas = @()
function Confere([string]$Nome, [bool]$Cond, [string]$Detalhe = '') {
    if ($Cond) { $script:ok++; Write-Host "  [ok]    $Nome" -ForegroundColor Green }
    else { $script:falhas += $Nome; Write-Host "  [FALHA] $Nome $Detalhe" -ForegroundColor Red }
}

# --- state.vscdb falso, gravado com o mesmo winsqlite3.dll que o app usa para ler ---
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FakeStateDb {
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open_v2")]    static extern int Open(byte[] file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close")]      static extern int Close(IntPtr db);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_exec")]       static extern int Exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, IntPtr err);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare_v2")] static extern int Prepare(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_text")]  static extern int BindText(IntPtr stmt, int idx, byte[] val, int n, IntPtr destructor);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step")]       static extern int Step(IntPtr stmt);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize")]   static extern int Finalize(IntPtr stmt);
    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

    public static void Write(string path, string key, string value) {
        IntPtr db;
        if (Open(Z(path), out db, 6 /* READWRITE | CREATE */, IntPtr.Zero) != 0) throw new Exception("open");
        try {
            Exec(db, Z("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            IntPtr stmt;
            if (Prepare(db, Z("INSERT INTO ItemTable (key, value) VALUES (?1, ?2)"), -1, out stmt, IntPtr.Zero) != 0) throw new Exception("prepare");
            try {
                byte[] k = Encoding.UTF8.GetBytes(key), v = Encoding.UTF8.GetBytes(value);
                BindText(stmt, 1, k, k.Length, new IntPtr(-1));
                BindText(stmt, 2, v, v.Length, new IntPtr(-1));
                if (Step(stmt) != 101) throw new Exception("step");
            } finally { Finalize(stmt); }
        } finally { Close(db); }
    }
}
'@

# Ids de teste com prefixo fixo: é o que permite limpar a Lixeira no fim sem risco.
function Id([int]$n) { 'eeeeeeee-0000-0000-0000-{0:d12}' -f $n }
function NovaSessao([string]$Projeto, [string]$Id, [string[]]$Linhas, [datetime]$Quando = (Get-Date).AddHours(-1)) {
    $f = Join-Path $Projeto "$Id.jsonl"
    Set-Content -LiteralPath $f -Value $Linhas -Encoding utf8NoBOM
    (Get-Item -LiteralPath $f).LastWriteTime = $Quando
}
function Limpar-LixeiraTeste {
    $lixeira = (New-Object -ComObject Shell.Application).NameSpace(10)
    foreach ($it in @($lixeira.Items() | Where-Object { $_.Name -like 'eeeeeeee-*' })) {
        $r = $it.Path
        $i = Join-Path (Split-Path $r) ('$I' + (Split-Path $r -Leaf).Substring(2))
        Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $i -Force -ErrorAction SilentlyContinue
    }
}

# --- Cenário ---
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
$home_ = Join-Path $tmp 'claude'
$alpha = (New-Item -ItemType Directory -Force (Join-Path $home_ 'projects\c--work-alpha')).FullName
$beta  = (New-Item -ItemType Directory -Force (Join-Path $home_ 'projects\c--work-beta')).FullName
$vazio = (New-Item -ItemType Directory -Force (Join-Path $home_ 'projects\c--vazio')).FullName
New-Item -ItemType Directory -Force (Join-Path $home_ 'sessions') | Out-Null
$db = Join-Path $tmp 'state.vscdb'

$s1, $s2, $s3, $s4, $s5, $s6, $s8 = (Id 1), (Id 2), (Id 3), (Id 4), (Id 5), (Id 6), (Id 8)

# s1: renomeada (custom-title vence ai-title), com cwd, pasta de subagentes, file-history e session-env
NovaSessao $alpha $s1 @(
    '{"parentUuid":null,"type":"user","cwd":"c:\\work\\alpha","sessionId":"' + $s1 + '","message":{"role":"user","content":"oi"}}'
    '{"type":"ai-title","aiTitle":"Título da IA","sessionId":"' + $s1 + '"}'
    '{"type":"custom-title","sessionId":"' + $s1 + '","customTitle":"Renomeada"}'
)
New-Item -ItemType Directory -Force (Join-Path $alpha "$s1\subagents") | Out-Null
Set-Content (Join-Path $alpha "$s1\subagents\a.jsonl") ('x' * 1000) -NoNewline -Encoding ascii
New-Item -ItemType Directory -Force (Join-Path $home_ "file-history\$s1"), (Join-Path $home_ "session-env\$s1") | Out-Null
Set-Content (Join-Path $home_ "file-history\$s1\f") 'x'
Set-Content (Join-Path $home_ "session-env\$s1\e") 'x'
# s2: dois ai-title (vale o último); está no grupo G1 mas arquivada
NovaSessao $alpha $s2 @(
    '{"type":"ai-title","aiTitle":"Velho","sessionId":"' + $s2 + '"}'
    '{"type":"ai-title","aiTitle":"Novo","sessionId":"' + $s2 + '"}'
)
# s3: só last-prompt, longo (corta em 100); tem arquivo de sessão com PID morto
NovaSessao $alpha $s3 @('{"type":"last-prompt","lastPrompt":"' + ('p' * 150) + '","sessionId":"' + $s3 + '"}')
'{"pid":999999,"sessionId":"' + $s3 + '"}' | Set-Content (Join-Path $home_ 'sessions\999999.json')
# s4: sem nenhum registro de título; grupo G2
NovaSessao $alpha $s4 @('{"parentUuid":null,"type":"user","sessionId":"' + $s4 + '"}')
# s5: só summary; gravada agora (conta como aberta)
NovaSessao $alpha $s5 @('{"type":"summary","summary":"Resumo antigo","leafUuid":"x"}') (Get-Date)
# s6: aberta por um processo vivo (este pwsh)
NovaSessao $alpha $s6 @('{"type":"ai-title","aiTitle":"Aberta","sessionId":"' + $s6 + '"}')
'{"pid":' + $PID + ',"sessionId":"' + $s6 + '"}' | Set-Content (Join-Path $home_ "sessions\$PID.json")
# Fora do padrão: arquivo que não é GUID e a pasta memory
'{"type":"ai-title","aiTitle":"nao e sessao"}' | Set-Content (Join-Path $alpha 'notas.jsonl')
'{"type":"ai-title","aiTitle":"nao e sessao"}' | Set-Content (Join-Path $vazio 'notas.jsonl')
New-Item -ItemType Directory -Force (Join-Path $alpha 'memory') | Out-Null
Set-Content (Join-Path $alpha 'memory\MEMORY.md') 'nao apagar'
# beta: 1 sessão num grupo próprio
NovaSessao $beta $s8 @('{"type":"ai-title","aiTitle":"Do beta","sessionId":"' + $s8 + '"}')

$state = [ordered]@{
    hiddenSessionIds              = @($s2)
    'sessionGroups:c:\work\alpha' = @(
        @{ id = 'g1'; name = 'G1'; collapsed = $false; sessionIds = @($s1, $s2, $s8) }
        @{ id = 'g2'; name = 'G2'; collapsed = $false; sessionIds = @($s4) }
    )
    'sessionGroups:c:\work\beta'  = @(@{ id = 'g3'; name = 'Beta'; collapsed = $false; sessionIds = @($s8) })
}
[FakeStateDb]::Write($db, 'Anthropic.claude-code', ($state | ConvertTo-Json -Depth 10))
[FakeStateDb]::Write($db, 'outra.extensao', '{"hiddenSessionIds":["' + $s1 + '"]}')

. $app -ClaudeHome $home_ -StateDb $db
$LiveProcessNames = @('claude', 'node', 'pwsh')

Write-Host "`nLeitura do state.vscdb"
$st = Read-ExtensionState
Confere 'lê o globalState da extensão certa' (@($st['hiddenSessionIds']).Count -eq 1 -and $st['hiddenSessionIds'][0] -eq $s2)
$erro = $null; $StateDb = Join-Path $tmp 'nao-existe.vscdb'
try { Read-ExtensionState | Out-Null } catch { $erro = $_.Exception.Message }
Confere 'state.vscdb ausente vira erro' ($erro -like '*não encontrado*') $erro
$StateDb = $db

Write-Host "`nProjetos e sessões"
$projetos = @(Get-ClaudeProjects)
$pa = $projetos | Where-Object Name -eq 'c--work-alpha'
$pb = $projetos | Where-Object Name -eq 'c--work-beta'
Confere 'lista só projetos com sessão (ignora c--vazio)' ($projetos.Count -eq 2) "($($projetos.Count))"
Confere 'caminho do projeto vem do cwd do .jsonl' ($pa.Path -eq 'c:\work\alpha') $pa.Path
Confere 'sem cwd, cai no nome da pasta' ($pb.Path -eq 'c--work-beta') $pb.Path
Confere 'ignora .jsonl que não é GUID' ($pa.Sessions.Count -eq 6) "($($pa.Sessions.Count))"
$por = @{}; foreach ($s in $pa.Sessions) { $por[$s.Id] = $s }
Confere 'custom-title vence ai-title' ($por[$s1].Title -eq 'Renomeada') $por[$s1].Title
Confere 'vale o último ai-title' ($por[$s2].Title -eq 'Novo') $por[$s2].Title
Confere 'last-prompt longo corta em 100' ($por[$s3].Title.Length -eq 100 -and $por[$s3].Title.EndsWith('...')) "($($por[$s3].Title.Length))"
Confere 'sem título vira "(sem título)"' ($por[$s4].Title -eq '(sem título)') $por[$s4].Title
Confere 'summary é usado quando não há outro' ($por[$s5].Title -eq 'Resumo antigo') $por[$s5].Title
Confere 'tamanho soma a pasta de subagentes' ($por[$s1].Bytes -eq ((Get-Item (Join-Path $alpha "$s1.jsonl")).Length + 1000)) "($($por[$s1].Bytes))"
Confere 'tamanho no formato brasileiro' ((Format-Size ([long](7.1 * 1MB))) -eq '7,1 MB' -and (Format-Size 1500) -eq '2 KB') (Format-Size ([long](7.1 * 1MB)))
Confere 'processo vivo = aberta' ($por[$s6].InUse)
Confere 'gravação recente = aberta' ($por[$s5].InUse)
Confere 'PID morto não conta como aberta' (-not $por[$s3].InUse)
Confere 'sessão parada não está aberta' (-not $por[$s1].InUse)
Confere 'o motivo diz por quê: processo vivo ou gravação recente' ($por[$s6].OpenReason -eq 'process' -and $por[$s5].OpenReason -eq 'recent' -and $null -eq $por[$s1].OpenReason)
$nenhum = [System.Collections.Generic.HashSet[string]]::new(); $t0 = Get-Date
Confere "gravada há 10s conta como aberta, há 45s não (limite ${RecentWriteSeconds}s)" ((Get-OpenReason 'x' $t0.AddSeconds(-10) $nenhum $t0) -eq 'recent' -and $null -eq (Get-OpenReason 'x' $t0.AddSeconds(-45) $nenhum $t0))
Confere 'a coluna Situação mostra o motivo' ((Get-StatusText ([pscustomobject]@{ OpenReason = 'process'; LastWrite = $t0 }) $t0) -eq 'aberta agora' -and (Get-StatusText ([pscustomobject]@{ OpenReason = 'recent'; LastWrite = $t0.AddSeconds(-12) }) $t0) -eq 'usada há 12s')

Write-Host "`nCategorias"
$cats = @(Get-Categories $pa $st)
$rotulos = ($cats | ForEach-Object { '{0}={1}' -f (Get-CategoryLabel $_), $_.Sessions.Count }) -join ', '
Confere 'ordem: grupos, Ungrouped, Archived' ($rotulos -eq 'Grupo: G1=1, Grupo: G2=1, Ungrouped=3, Archived sessions=1') $rotulos
Confere 'arquivada sai do grupo' (@($cats[0].Sessions.Id) -notcontains $s2 -and $cats[0].Sessions[0].Id -eq $s1)
Confere 'id de outro projeto no grupo é ignorado' (@($cats[0].Sessions.Id) -notcontains $s8)
Confere 'arquivada vai para Archived sessions' ($cats[3].Sessions[0].Id -eq $s2)
Confere 'grupo de outro workspace não aparece aqui' (@($cats.Name) -notcontains 'Beta')
$cb = @(Get-Categories $pb $st)
Confere 'workspace beta tem o próprio grupo' ($cb[0].Name -eq 'Beta' -and $cb[0].Sessions.Count -eq 1)
$c0 = @(Get-Categories $pa @{})
Confere 'sem state: tudo em Ungrouped' ($c0.Count -eq 2 -and $c0[0].Sessions.Count -eq 6 -and $c0[1].Sessions.Count -eq 0)

Write-Host "`nModo -Probe"
$antes = @(Get-ChildItem $home_ -Recurse -File).Count
$saida = (& pwsh -NoProfile -File $app -Probe -ClaudeHome $home_ -StateDb $db) -join "`n"
Confere '-Probe termina bem' ($LASTEXITCODE -eq 0 -and $saida -like '*PROBE OK*')
Confere '-Probe mostra grupo e por que a sessão está aberta' ($saida -like '*Grupo: G1  (1)*' -and $saida -like '*`[ABERTA: gravada*')
Confere '-Probe não apaga nada' (@(Get-ChildItem $home_ -Recurse -File).Count -eq $antes)

Write-Host "`nTrava do delete"
$d = New-ConfirmDialog @($por[$s1], $por[$s3])
Confere 'a confirmação está em português' ($d.Form.Text -eq 'Confirmar exclusão' -and $d.OkButton.Text -eq 'Excluir')
$travas = foreach ($t in '', 'Delete', 'DELETE', 'delet', 'deletee', 'excluir') { $d.Input.Text = $t; $d.OkButton.Enabled }
Confere 'só "delete" libera o botão (maiúscula, parcial e outra palavra não)' (-not ($travas -contains $true))
$d.Input.Text = 'delete'; $lib1 = $d.OkButton.Enabled
$d.Input.Text = '  delete  '; $lib2 = $d.OkButton.Enabled
Confere '"delete" libera, com ou sem espaço nas pontas' ($lib1 -and $lib2)
$d.Form.Dispose()

if ($Janela) {
    Write-Host "`nJanela de verdade (UI Automation)"
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    if (-not ('UiKeys' -as [type])) {
        Add-Type 'using System; using System.Runtime.InteropServices; public static class UiKeys { [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); }'
    }
    $AE     = [System.Windows.Automation.AutomationElement]
    $todos  = [System.Windows.Automation.Condition]::TrueCondition
    $porNome = New-Object System.Windows.Automation.PropertyCondition ($AE::NameProperty), 'Sessões do Claude Code'
    function Achar($win, [string]$Like) {
        # Elementos visíveis cujo nome casa (os controles da tela escondida ficam de fora)
        @($win.FindAll('Descendants', $todos) | Where-Object { $_.Current.Name -like $Like -and -not $_.Current.IsOffscreen })
    }
    function Esperar([scriptblock]$Cond, [int]$Ms = 8000) {
        $t = [Diagnostics.Stopwatch]::StartNew()
        while ($t.ElapsedMilliseconds -lt $Ms) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 200 }
        return $false
    }
    function Clicar($el) { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    function Tecla($el, [int]$Vk) { [void][UiKeys]::PostMessage([IntPtr]$el.Current.NativeWindowHandle, 0x0100, [IntPtr]$Vk, [IntPtr]::Zero) }   # WM_KEYDOWN
    function Esc($el) { Tecla $el 0x1B }
    # Botão com janela própria: a setinha do ComboBox também se chama "Abrir" no Windows em português
    function Botao($win, [string]$Nome) { Achar $win $Nome | Where-Object { $_.Current.NativeWindowHandle -ne 0 } | Select-Object -First 1 }
    function Linha($win, [string]$Nome) {
        Achar $win $Nome | Where-Object { $_.GetSupportedPatterns() -contains [System.Windows.Automation.TogglePattern]::Pattern } | Select-Object -First 1
    }
    function EstadoLinha($win, [string]$Nome) { $r = Linha $win $Nome; if ($r) { [string]$r.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState } }
    function AlternarLinha($win, [string]$Nome) { (Linha $win $Nome).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle(); Start-Sleep -Milliseconds 300 }

    # Sessão presa por um processo "claude" falso (cópia renomeada do cmd.exe), como uma aba do VS Code
    $s7 = Id 7
    NovaSessao $alpha $s7 @('{"type":"ai-title","aiTitle":"Sessão ocupada","sessionId":"' + $s7 + '"}')
    $claudeFalso = Join-Path $tmp 'claude.exe'
    Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') $claudeFalso
    function Iniciar-ClaudeFalso([string]$SessionId) {
        $fp = Start-Process $claudeFalso -ArgumentList '/c', 'ping -n 600 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
        '{"pid":' + $fp.Id + ',"sessionId":"' + $SessionId + '"}' | Set-Content (Join-Path $home_ "sessions\$($fp.Id).json")
        $fp
    }
    function Parar-ClaudeFalso($fp) {
        if (-not $fp) { return }
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($fp.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $fp.Id -Force -ErrorAction SilentlyContinue
        [void]$fp.WaitForExit(5000)
    }
    $ocupada = Iniciar-ClaudeFalso $s7; $ocupada2 = $null

    $jaAbertas = @($AE::RootElement.FindAll('Children', $porNome) | ForEach-Object { $_.Current.NativeWindowHandle })
    $p = Start-Process pwsh -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-File', $app, '-ClaudeHome', $home_, '-StateDb', $db -PassThru
    try {
        $win = $null
        [void](Esperar { $script:win = $AE::RootElement.FindAll('Children', $porNome) | Where-Object { $_.Current.NativeWindowHandle -notin $jaAbertas } | Select-Object -First 1; $script:win } 20000)
        $win = $script:win
        Confere 'a janela abre' ($null -ne $win)
        if ($win) {
            # O processo dono da janela (o Start-Process pode passar por um lançador)
            $winPid = $win.Current.ProcessId
            $hwnd   = $win.Current.NativeWindowHandle
            $tela1  = { (Achar $win 'Archived sessions*').Count -gt 0 -and (Achar $win 'Voltar').Count -eq 0 }
            $tela2  = { (Achar $win 'Voltar').Count -gt 0 -and (Achar $win 'Archived sessions*').Count -eq 0 }
            $viva   = { (Get-Process -Id $winPid -ErrorAction SilentlyContinue) -and ($AE::RootElement.FindAll('Children', $porNome) | Where-Object { $_.Current.NativeWindowHandle -eq $hwnd }) }
            Confere 'começa na tela 1 com as categorias' (Esperar $tela1)

            (Achar $win 'Ungrouped*')[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            Clicar (Botao $win 'Abrir')
            Confere 'Abrir vai para a tela 2' (Esperar $tela2)

            Clicar (Botao $win 'Voltar')
            Start-Sleep -Milliseconds 800
            Confere 'Voltar volta para a tela 1 e mantém a janela aberta' ((& $viva) -and (Esperar $tela1))

            Clicar (Botao $win 'Abrir')
            [void](Esperar $tela2)
            # O Esc é tratado no formulário (Form.ProcessDialogKey -> CancelButton): manda para a janela
            Esc $win
            Start-Sleep -Milliseconds 800
            Confere 'Esc na tela 2 volta sem fechar' ((& $viva) -and (Esperar $tela1))

            # O cenário do uso real: sessão aberta no VS Code, fechada, e Atualizar
            Clicar (Botao $win 'Abrir')
            [void](Esperar { Linha $win 'Sessão ocupada' })
            AlternarLinha $win 'Sessão ocupada'
            Confere 'sessão com processo claude vivo não pode ser marcada' ((EstadoLinha $win 'Sessão ocupada') -eq 'Off')

            Parar-ClaudeFalso $ocupada                  # "fecha a sessão no VS Code"
            Clicar (Botao $win 'Atualizar')
            [void](Esperar { (Linha $win 'Sessão ocupada') -and (& $tela2) })
            AlternarLinha $win 'Sessão ocupada'
            Confere 'depois de fechada, o Atualizar libera (e fica na tela 2)' ((& $tela2) -and (EstadoLinha $win 'Sessão ocupada') -eq 'On')

            $ocupada2 = Iniciar-ClaudeFalso $s7         # reaberta enquanto estava marcada
            Tecla $win 0x74                             # F5
            Start-Sleep -Milliseconds 800
            [void](Esperar { Linha $win 'Sessão ocupada' })
            Confere 'o F5 também atualiza e desmarca a sessão reaberta' ((& $tela2) -and (EstadoLinha $win 'Sessão ocupada') -eq 'Off')

            Esc $win
            [void](Esperar $tela1)
            Esc $win
            Confere 'Esc na tela 1 fecha o app' (Esperar { -not (Get-Process -Id $winPid -ErrorAction SilentlyContinue) })
        }
    } finally {
        if ($winPid) { Stop-Process -Id $winPid -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Parar-ClaudeFalso $ocupada; Parar-ClaudeFalso $ocupada2
        # deixa o cenário como as próximas seções esperam
        Remove-Item -LiteralPath (Join-Path $alpha "$s7.jsonl") -Force -ErrorAction SilentlyContinue
        foreach ($fp in $ocupada, $ocupada2) { if ($fp) { Remove-Item -LiteralPath (Join-Path $home_ "sessions\$($fp.Id).json") -Force -ErrorAction SilentlyContinue } }
    }
}

Write-Host "`nBotões da janela"
$f = New-Object System.Windows.Forms.Form; $b = New-Object System.Windows.Forms.Button
$f.CancelButton = $b
Confere 'o WinForms transforma o CancelButton em botão que fecha (a causa do bug do Voltar)' ($b.DialogResult -eq [System.Windows.Forms.DialogResult]::Cancel)
$b2 = New-Object System.Windows.Forms.Button
Set-EscapeButton $f $b2
Confere 'Set-EscapeButton mantém o Esc no botão sem fazê-lo fechar a janela' ($f.CancelButton -eq $b2 -and $b2.DialogResult -eq [System.Windows.Forms.DialogResult]::None)
$f.Dispose()

Write-Host "`nExclusão"
$erro = $null
try { Remove-ClaudeSession ([pscustomobject]@{ Id = 'memory'; ProjectDir = $alpha }) } catch { $erro = $_.Exception.Message }
Confere 'recusa id que não é GUID' ($erro -like '*inválido*') $erro
Confere 'pasta memory intacta' (Test-Path (Join-Path $alpha 'memory\MEMORY.md'))
try {
    Remove-ClaudeSession $por[$s1]
    Confere 'apaga o .jsonl' (-not (Test-Path (Join-Path $alpha "$s1.jsonl")))
    Confere 'apaga a pasta <id>' (-not (Test-Path (Join-Path $alpha $s1)))
    Confere 'apaga file-history e session-env' (-not (Test-Path (Join-Path $home_ "file-history\$s1")) -and -not (Test-Path (Join-Path $home_ "session-env\$s1")))
    Confere 'não mexe nas outras sessões' (@(Get-ChildItem $alpha -Filter 'eeeeeeee-*.jsonl').Count -eq 5)
    Confere 'memory continua intacta' (Test-Path (Join-Path $alpha 'memory\MEMORY.md'))
    $lixo = @((New-Object -ComObject Shell.Application).NameSpace(10).Items() | Where-Object { $_.Name -like "$s1*" })
    Confere 'foi para a Lixeira (dá para restaurar)' ($lixo.Count -ge 1) "($($lixo.Count) itens)"
} finally {
    Limpar-LixeiraTeste
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:falhas.Count) {
    Write-Host "$($script:ok) ok, $($script:falhas.Count) FALHA(S): $($script:falhas -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host "$($script:ok) verificações ok" -ForegroundColor Green
