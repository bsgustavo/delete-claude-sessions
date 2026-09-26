#requires -Version 7
<#
.SYNOPSIS
  Janela para excluir de verdade as sessões do Claude Code na extensão do VS Code.
  Tela 1: escolhe o projeto e um grupo, "Ungrouped" ou "Archived sessions".
  Tela 2: marca as sessões e exclui. A exclusão exige digitar "delete" e manda os arquivos
  para a Lixeira (dá para restaurar de lá).
  Sessões abertas agora (processo claude vivo) aparecem em cinza e não podem ser marcadas.

  De onde vêm os dados:
    - Sessões: ~\.claude\projects\<projeto>\<id>.jsonl (+ pasta <id>\ com subagents/tool-results)
    - Títulos: registros custom-title (renomeada) / ai-title dentro do .jsonl
    - Grupos e arquivadas: globalState da extensão no state.vscdb do VS Code
      ("sessionGroups:<pasta>" e "hiddenSessionIds"). Só leitura: o script nunca grava lá.

.PARAMETER Probe
  Lista projetos, categorias e sessões no console. Sem janela e sem excluir nada.

.PARAMETER ClaudeHome
  Pasta de dados do Claude Code. Padrão: %USERPROFILE%\.claude

.PARAMETER StateDb
  Banco de estado do VS Code. Padrão: %APPDATA%\Code\User\globalStorage\state.vscdb
#>
param(
    [switch]$Probe,
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [string]$StateDb    = (Join-Path $env:APPDATA 'Code\User\globalStorage\state.vscdb')
)

$GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$ConfirmWord = 'delete'

# Processos que contam como "sessão aberta" (os testes acrescentam o pwsh)
$LiveProcessNames = @('claude', 'node')
# Um .jsonl gravado há menos que isso também conta como aberto. É só uma rede de segurança: a
# checagem de verdade é o processo vivo, cujo ~\.claude\sessions\<pid>.json some quando a sessão fecha.
$RecentWriteSeconds = 30

# --- Textos da janela ---
$T = @{
    WindowTitle    = 'Sessões do Claude Code'
    BoxTitle       = 'Sessões do Claude'
    DateFormat     = 'dd/MM/yyyy HH:mm'
    Project        = 'Projeto:'
    Loading        = 'Carregando sessões...'
    PickCategory   = 'Escolha um grupo, Ungrouped ou Archived sessions (duplo clique ou Enter para abrir):'
    Open           = 'Abrir'
    Close          = 'Fechar'
    ProjectItem    = '{0}    ({1} sessões)'
    Group          = 'Grupo: {0}'
    Header         = '{0}  -  {1} sessão(ões)  -  {2}'
    ColSession     = 'Sessão'
    ColLastActive  = 'Última atividade'
    ColSize        = 'Tamanho'
    ColStatus      = 'Situação'
    OpenNow        = 'aberta agora'
    UsedAgo        = 'usada há {0}s'
    Refresh        = 'Atualizar'
    CheckAll       = 'Marcar todas'
    UncheckAll     = 'Desmarcar'
    DeleteChecked  = 'Excluir selecionadas'
    Back           = 'Voltar'
    NoneChecked    = 'Nenhuma marcada'
    NChecked       = '{0} marcada(s), {1}'
    NoTitle        = '(sem título)'
    Unreadable     = '(ilegível) {0}'
    ConfirmTitle   = 'Confirmar exclusão'
    ConfirmSummary = "Você vai excluir {0} sessão(ões), {1} no total.`nOs arquivos vão para a Lixeira."
    ConfirmPrompt  = 'Para confirmar, digite  delete :'
    ConfirmButton  = 'Excluir'
    Cancel         = 'Cancelar'
    BlockedOpen    = "Estas sessões estão abertas agora e foram tiradas da seleção:`n`n{0}"
    Deleted        = '{0} sessão(ões) enviada(s) para a Lixeira ({1}).'
    Failed         = "`n`nFalharam:`n{0}"
    ReloadHint     = "`n`nSe ainda aparecerem na lista do VS Code, rode 'Developer: Reload Window'."
    Unexpected     = "Erro inesperado:`n{0}"
    NoSessions     = 'Nenhuma sessão encontrada em {0}'
    StateError     = "Não consegui ler os grupos e as arquivadas do VS Code:`n{0}`n`nTodas as sessões vão aparecer em Ungrouped."
}
# Números sempre no formato brasileiro ("7,1 MB"), mesmo num Windows em outro idioma
$UiCulture = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')

# --- Leitura do state.vscdb pelo winsqlite3.dll (vem com o Windows, sem dependência extra) ---
if (-not ('WinSqlite' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WinSqlite {
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open_v2")]      static extern int Open(byte[] file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close")]        static extern int Close(IntPtr db);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_busy_timeout")] static extern int BusyTimeout(IntPtr db, int ms);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare_v2")]   static extern int Prepare(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_text")]    static extern int BindText(IntPtr stmt, int idx, byte[] val, int n, IntPtr destructor);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step")]         static extern int Step(IntPtr stmt);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_blob")]  static extern IntPtr ColumnBlob(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_bytes")] static extern int ColumnBytes(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize")]     static extern int Finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_errmsg")]       static extern IntPtr ErrMsg(IntPtr db);

    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

    // Valor de ItemTable[key] como texto; null se a chave não existe.
    public static string ReadItem(string path, string key) {
        IntPtr db;
        int rc = Open(Z(path), out db, 1 /* SQLITE_OPEN_READONLY */, IntPtr.Zero);
        try {
            if (rc != 0) throw new Exception("sqlite open rc=" + rc);
            BusyTimeout(db, 3000);
            IntPtr stmt;
            rc = Prepare(db, Z("SELECT value FROM ItemTable WHERE key = ?1 COLLATE NOCASE"), -1, out stmt, IntPtr.Zero);
            if (rc != 0) throw new Exception(Marshal.PtrToStringUTF8(ErrMsg(db)));
            try {
                byte[] k = Encoding.UTF8.GetBytes(key);
                BindText(stmt, 1, k, k.Length, new IntPtr(-1) /* SQLITE_TRANSIENT */);
                rc = Step(stmt);
                if (rc == 101) return null;                        // SQLITE_DONE
                if (rc != 100) throw new Exception(Marshal.PtrToStringUTF8(ErrMsg(db)));
                IntPtr p = ColumnBlob(stmt, 0);
                int n = ColumnBytes(stmt, 0);
                if (p == IntPtr.Zero || n == 0) return "";
                byte[] buf = new byte[n];
                Marshal.Copy(p, buf, 0, n);
                return Encoding.UTF8.GetString(buf);
            } finally { Finalize(stmt); }
        } finally { if (db != IntPtr.Zero) Close(db); }
    }
}
'@
}

function Read-ExtensionState {
    # globalState da extensão (hashtable). Lança erro se não conseguir ler.
    if (-not (Test-Path -LiteralPath $StateDb)) { throw "state.vscdb não encontrado: $StateDb" }
    try {
        $raw = [WinSqlite]::ReadItem($StateDb, 'Anthropic.claude-code')
    } catch {
        # Banco ocupado (o VS Code está gravando): lê de uma cópia
        $tmp = Join-Path $env:TEMP "claude-sessions-state-$PID.vscdb"
        Copy-Item -LiteralPath $StateDb $tmp -Force
        try { $raw = [WinSqlite]::ReadItem($tmp, 'Anthropic.claude-code') }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if (-not $raw) { return @{} }
    return ($raw | ConvertFrom-Json -AsHashtable)
}

function Get-JsonField([string]$line, [string]$field) {
    if (-not $line) { return $null }
    try { return ($line | ConvertFrom-Json).$field } catch { return $null }
}

function Read-SessionFile([System.IO.FileInfo]$file) {
    # Varre o .jsonl uma vez guardando só as linhas que interessam (vale o último registro de cada tipo).
    $custom = $ai = $summary = $prompt = $cwd = $null
    $fs = [System.IO.FileStream]::new($file.FullName, 'Open', 'Read', 'ReadWrite, Delete')
    $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
    try {
        while ($null -ne ($line = $sr.ReadLine())) {
            if     ($line.StartsWith('{"type":"custom-title"', [StringComparison]::Ordinal)) { $custom  = $line }
            elseif ($line.StartsWith('{"type":"ai-title"',     [StringComparison]::Ordinal)) { $ai      = $line }
            elseif ($line.StartsWith('{"type":"summary"',      [StringComparison]::Ordinal)) { $summary = $line }
            elseif ($line.StartsWith('{"type":"last-prompt"',  [StringComparison]::Ordinal)) { $prompt  = $line }
            elseif ($null -eq $cwd -and $line.Contains('"cwd":"')) {
                $m = [regex]::Match($line, '"cwd":"((?:[^"\\]|\\.)*)"')
                if ($m.Success) { $cwd = ('"' + $m.Groups[1].Value + '"') | ConvertFrom-Json }
            }
        }
    } finally { $sr.Dispose() }

    $title = @(
        (Get-JsonField $custom  'customTitle'),
        (Get-JsonField $ai      'aiTitle'),
        (Get-JsonField $summary 'summary'),
        (Get-JsonField $prompt  'lastPrompt')
    ) | Where-Object { $_ -and "$_".Trim() } | Select-Object -First 1
    if (-not $title) { $title = $T.NoTitle }
    $title = ($title -replace '\s+', ' ').Trim()
    if ($title.Length -gt 100) { $title = $title.Substring(0, 97) + '...' }
    [pscustomobject]@{ Title = $title; Cwd = $cwd }
}

function Get-LiveSessionIds {
    # Sessões com processo claude vivo (~\.claude\sessions\<pid>.json). Arquivo de PID morto é ignorado.
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dir = Join-Path $ClaudeHome 'sessions'
    if (-not (Test-Path -LiteralPath $dir)) { return , $ids }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
        try { $j = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if (-not $j.sessionId -or -not $j.pid) { continue }
        $p = Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -in $LiveProcessNames) { [void]$ids.Add($j.sessionId) }
    }
    return , $ids
}

function Get-OpenReason([string]$Id, [datetime]$LastWrite, $Live, [datetime]$Now = (Get-Date)) {
    # 'process' (processo claude vivo), 'recent' (.jsonl gravado há poucos segundos) ou $null (livre para excluir)
    if ($Live.Contains($Id)) { return 'process' }
    if (($Now - $LastWrite).TotalSeconds -lt $RecentWriteSeconds) { return 'recent' }
    return $null
}

function Get-StatusText($session, [datetime]$Now = (Get-Date)) {
    switch ($session.OpenReason) {
        'process' { $T.OpenNow }
        'recent'  { $T.UsedAgo -f [Math]::Max(1, [int]($Now - $session.LastWrite).TotalSeconds) }
        default   { '' }
    }
}

function Get-ClaudeProjects {
    $root = Join-Path $ClaudeHome 'projects'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $live = Get-LiveSessionIds
    $now  = Get-Date
    $projects = foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Force) {
        $sessions = [System.Collections.Generic.List[object]]::new()
        foreach ($f in Get-ChildItem -LiteralPath $d.FullName -Filter '*.jsonl' -File -Force) {
            $id = $f.BaseName
            if ($id -notmatch $GuidPattern) { continue }
            try { $info = Read-SessionFile $f } catch { $info = [pscustomobject]@{ Title = ($T.Unreadable -f $id); Cwd = $null } }
            $bytes = $f.Length
            $sub = Join-Path $d.FullName $id
            if (Test-Path -LiteralPath $sub -PathType Container) {
                $bytes += (Get-ChildItem -LiteralPath $sub -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            }
            $reason = Get-OpenReason $id $f.LastWriteTime $live $now
            $sessions.Add([pscustomobject]@{
                Id         = $id
                Title      = $info.Title
                Cwd        = $info.Cwd
                LastWrite  = $f.LastWriteTime
                Bytes      = [long]$bytes
                ProjectDir = $d.FullName
                InUse      = [bool]$reason
                OpenReason = $reason
            })
        }
        if ($sessions.Count -eq 0) { continue }
        $newest = $sessions | Sort-Object LastWrite -Descending
        [pscustomobject]@{
            Name      = $d.Name
            Dir       = $d.FullName
            Path      = ($newest | Where-Object Cwd | Select-Object -First 1).Cwd ?? $d.Name
            Sessions  = $sessions
            LastWrite = ($newest | Select-Object -First 1).LastWrite
        }
    }
    return @($projects | Sort-Object LastWrite -Descending)
}

function Get-Categories($project, $state) {
    # Mesma regra da extensão: sessão arquivada sai do grupo; Ungrouped = nem arquivada nem em grupo.
    $hidden = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($state['hiddenSessionIds'] | Where-Object { $_ }), [StringComparer]::OrdinalIgnoreCase)
    $byId = @{}
    foreach ($s in $project.Sessions) { $byId[$s.Id] = $s }

    # Chave "sessionGroups:<pasta do workspace>"; a pasta de projeto do Claude é esse caminho com
    # tudo que não é letra ou dígito trocado por "-".
    $groups = foreach ($k in @($state.Keys)) {
        if (-not $k.StartsWith('sessionGroups:')) { continue }
        $ws = $k.Substring('sessionGroups:'.Length)
        if (($ws -replace '[^a-zA-Z0-9]', '-') -ine $project.Name) { continue }
        @($state[$k])
    }

    $cats    = [System.Collections.Generic.List[object]]::new()
    $grouped = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($g in $groups) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($sid in @($g['sessionIds'])) {
            if ($sid -and $byId.ContainsKey($sid) -and -not $hidden.Contains($sid) -and $grouped.Add($sid)) { $items.Add($byId[$sid]) }
        }
        $cats.Add([pscustomobject]@{ Kind = 'group'; Name = [string]$g['name']; Sessions = $items })
    }
    $ungrouped = [System.Collections.Generic.List[object]]::new()
    $archived  = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $project.Sessions) {
        if ($hidden.Contains($s.Id)) { $archived.Add($s) }
        elseif (-not $grouped.Contains($s.Id)) { $ungrouped.Add($s) }
    }
    # Os mesmos nomes que a extensão mostra (em inglês, como no VS Code)
    $cats.Add([pscustomobject]@{ Kind = 'ungrouped'; Name = 'Ungrouped';         Sessions = $ungrouped })
    $cats.Add([pscustomobject]@{ Kind = 'archived';  Name = 'Archived sessions'; Sessions = $archived })
    $cats
}

function Get-CategoryLabel($cat) {
    if ($cat.Kind -eq 'group') { $T.Group -f $cat.Name } else { $cat.Name }
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { [string]::Format($UiCulture, '{0:N1} GB', $b / 1GB) }
    elseif ($b -ge 1MB) { [string]::Format($UiCulture, '{0:N1} MB', $b / 1MB) }
    else { [string]::Format($UiCulture, '{0:N0} KB', [math]::Ceiling($b / 1KB)) }
}

function Remove-ClaudeSession($session) {
    # Manda para a Lixeira: o .jsonl, a pasta <id>\ do projeto e os restos em file-history/session-env.
    if ($session.Id -notmatch $GuidPattern) { throw "Id de sessão inválido: '$($session.Id)'" }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $id = $session.Id
    $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
    $rb = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    $jsonl = Join-Path $session.ProjectDir "$id.jsonl"
    if (Test-Path -LiteralPath $jsonl -PathType Leaf) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($jsonl, $ui, $rb) }
    $dirs = @(
        (Join-Path $session.ProjectDir $id),
        (Join-Path $ClaudeHome "file-history\$id"),
        (Join-Path $ClaudeHome "session-env\$id")
    )
    foreach ($dir in $dirs) {
        if (Test-Path -LiteralPath $dir -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($dir, $ui, $rb) }
    }
}

function New-ConfirmDialog($sessions) {
    # Separado do Show-ConfirmDialog para os testes conferirem a trava do "delete" sem exibir a janela.
    $total = [long]($sessions | Measure-Object Bytes -Sum).Sum
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = $T.ConfirmTitle
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ShowInTaskbar   = $false
    $dlg.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.ClientSize      = New-Object System.Drawing.Size(520, 372)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = $T.ConfirmSummary -f $sessions.Count, (Format-Size $total)
    $lbl.Location = New-Object System.Drawing.Point(14, 12)
    $lbl.Size     = New-Object System.Drawing.Size(492, 40)
    $dlg.Controls.Add($lbl)

    $list = New-Object System.Windows.Forms.TextBox
    $list.Multiline  = $true
    $list.ReadOnly   = $true
    $list.ScrollBars = 'Vertical'
    $list.Location   = New-Object System.Drawing.Point(14, 56)
    $list.Size       = New-Object System.Drawing.Size(492, 200)
    $list.Text       = ($sessions | ForEach-Object { '- {0}   ({1})' -f $_.Title, $_.LastWrite.ToString($T.DateFormat) }) -join "`r`n"
    $dlg.Controls.Add($list)

    $lbl2 = New-Object System.Windows.Forms.Label
    $lbl2.Text     = $T.ConfirmPrompt
    $lbl2.AutoSize = $true
    $lbl2.Location = New-Object System.Drawing.Point(14, 268)
    $dlg.Controls.Add($lbl2)

    $typed = New-Object System.Windows.Forms.TextBox
    $typed.Location = New-Object System.Drawing.Point(14, 290)
    $typed.Size     = New-Object System.Drawing.Size(492, 24)
    $dlg.Controls.Add($typed)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text         = $T.ConfirmButton
    $ok.Enabled      = $false
    $ok.Size         = New-Object System.Drawing.Size(100, 32)
    $ok.Location     = New-Object System.Drawing.Point(300, 328)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text         = $T.Cancel
    $cancel.Size         = New-Object System.Drawing.Size(100, 32)
    $cancel.Location     = New-Object System.Drawing.Point(406, 328)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancel)

    $word = $ConfirmWord
    $typed.Add_TextChanged({ $ok.Enabled = ($typed.Text.Trim() -ceq $word) }.GetNewClosure())
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel
    $dlg.Add_Shown({ $typed.Focus() }.GetNewClosure())
    [pscustomobject]@{ Form = $dlg; Input = $typed; OkButton = $ok }
}

function Set-EscapeButton($form, $button) {
    # O Esc clica no $button. O Form.CancelButton também troca o DialogResult do botão para Cancel
    # quando ele é None, e numa janela modal um botão com DialogResult fecha a janela logo depois
    # do Click: o "Voltar" fecharia tudo. Zera o DialogResult para o próprio botão decidir.
    $form.CancelButton = $button
    $button.DialogResult = [System.Windows.Forms.DialogResult]::None
}

function Show-ConfirmDialog($sessions, $owner) {
    $d = New-ConfirmDialog $sessions
    $r = $d.Form.ShowDialog($owner)
    $confirmed = ($r -eq [System.Windows.Forms.DialogResult]::OK) -and ($d.Input.Text.Trim() -ceq $ConfirmWord)
    $d.Form.Dispose()
    return $confirmed
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Dot-source (testes): só carrega as funções
if ($MyInvocation.InvocationName -eq '.') { return }

# --- Modo -Probe: lista e sai, sem janela ---
if ($Probe) {
    try { $state = Read-ExtensionState; "state.vscdb: OK ($StateDb)" }
    catch { $state = @{}; "state.vscdb: ERRO $($_.Exception.Message)" }
    foreach ($p in Get-ClaudeProjects) {
        ''
        "== $($p.Path)   [$($p.Name)]   $($p.Sessions.Count) sessões"
        foreach ($c in Get-Categories $p $state) {
            '  {0}  ({1})' -f (Get-CategoryLabel $c), $c.Sessions.Count
            foreach ($s in $c.Sessions | Sort-Object LastWrite -Descending) {
                $open = switch ($s.OpenReason) {
                    'process' { '   [ABERTA: processo vivo]' }
                    'recent'  { '   [ABERTA: gravada há {0:N0}s]' -f ((Get-Date) - $s.LastWrite).TotalSeconds }
                    default   { '' }
                }
                '      {0}  {1,9}  {2}{3}' -f $s.LastWrite.ToString('dd/MM/yyyy HH:mm'), (Format-Size $s.Bytes), $s.Title, $open
            }
        }
    }
    ''
    'PROBE OK (janela não exibida, nada excluído)'
    return
}

# --- Esconde a janela do console ---
$win32 = @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleWin {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
try { Add-Type -TypeDefinition $win32 -ErrorAction Stop; [ConsoleWin]::ShowWindow([ConsoleWin]::GetConsoleWindow(), 0) | Out-Null } catch {}

[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-Box($msg, $icon = 'Information') {
    [System.Windows.Forms.MessageBox]::Show($form, $msg, $T.BoxTitle, 'OK', $icon) | Out-Null
}

$script:State      = @{}
$script:Projects   = @()
$script:Cats       = @()
$script:CurrentCat = $null
$script:Filling    = $false

# --- Janela ---
$form = New-Object System.Windows.Forms.Form
$form.Text          = $T.WindowTitle
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
$form.ClientSize    = New-Object System.Drawing.Size(820, 520)
# Não fica mais estreita que o padrão: as linhas de baixo têm botões presos aos dois lados
$form.MinimumSize   = New-Object System.Drawing.Size($form.Width, 400)
$form.KeyPreview    = $true   # F5 = Atualizar, com o foco em qualquer controle

$anchorAll = [System.Windows.Forms.AnchorStyles]'Top, Bottom, Left, Right'
$anchorTLR = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
$anchorBR  = [System.Windows.Forms.AnchorStyles]'Bottom, Right'
$anchorBL  = [System.Windows.Forms.AnchorStyles]'Bottom, Left'

function New-Button($text, $x, $y, $w, $anchor) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text     = $text
    $b.Size     = New-Object System.Drawing.Size($w, 32)
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Anchor   = $anchor
    $b
}

# Tela 1: projeto + categorias
# O painel já nasce com o tamanho final: as âncoras guardam a distância até a borda no momento
# em que o controle entra, e o tamanho padrão (200x100) empurraria tudo para fora da janela.
$pCat = New-Object System.Windows.Forms.Panel
$pCat.Size = $form.ClientSize
$pCat.Dock = 'Fill'

$lblProj = New-Object System.Windows.Forms.Label
$lblProj.Text     = $T.Project
$lblProj.AutoSize = $true
$lblProj.Location = New-Object System.Drawing.Point(14, 17)
$pCat.Controls.Add($lblProj)

$cbProj = New-Object System.Windows.Forms.ComboBox
$cbProj.DropDownStyle = 'DropDownList'
$cbProj.Location      = New-Object System.Drawing.Point(76, 13)
$cbProj.Size          = New-Object System.Drawing.Size(730, 24)
$cbProj.Anchor        = $anchorTLR
$pCat.Controls.Add($cbProj)

$lblCat = New-Object System.Windows.Forms.Label
$lblCat.Text     = $T.Loading
$lblCat.AutoSize = $true
$lblCat.Location = New-Object System.Drawing.Point(14, 50)
$pCat.Controls.Add($lblCat)

$lbCat = New-Object System.Windows.Forms.ListBox
$lbCat.Location       = New-Object System.Drawing.Point(14, 72)
$lbCat.Size           = New-Object System.Drawing.Size(792, 380)
$lbCat.Anchor         = $anchorAll
$lbCat.IntegralHeight = $false
$lbCat.Font           = New-Object System.Drawing.Font('Segoe UI', 10)
$pCat.Controls.Add($lbCat)

$btnRefresh1 = New-Button $T.Refresh 14  470 100 $anchorBL
$btnOpen     = New-Button $T.Open    600 470 100 $anchorBR
$btnClose    = New-Button $T.Close   706 470 100 $anchorBR
$pCat.Controls.AddRange(@($btnRefresh1, $btnOpen, $btnClose))

# Tela 2: sessões da categoria
$pSes = New-Object System.Windows.Forms.Panel
$pSes.Size    = $form.ClientSize
$pSes.Dock    = 'Fill'
$pSes.Visible = $false

$lblHead = New-Object System.Windows.Forms.Label
$lblHead.AutoSize = $true
$lblHead.Location = New-Object System.Drawing.Point(14, 16)
$lblHead.Font     = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$pSes.Controls.Add($lblHead)

$lv = New-Object System.Windows.Forms.ListView
$lv.View          = 'Details'
$lv.CheckBoxes    = $true
$lv.FullRowSelect = $true
$lv.GridLines     = $true
$lv.Location      = New-Object System.Drawing.Point(14, 44)
$lv.Size          = New-Object System.Drawing.Size(792, 408)
$lv.Anchor        = $anchorAll
[void]$lv.Columns.Add($T.ColSession, 470)
[void]$lv.Columns.Add($T.ColLastActive, 120)
[void]$lv.Columns.Add($T.ColSize, 80, 'Right')
[void]$lv.Columns.Add($T.ColStatus, 95)
$pSes.Controls.Add($lv)

$lblSel = New-Object System.Windows.Forms.Label
$lblSel.AutoSize = $true
$lblSel.Location = New-Object System.Drawing.Point(124, 478)
$lblSel.Anchor   = $anchorBL
$pSes.Controls.Add($lblSel)

$btnRefresh2 = New-Button $T.Refresh       14  470 100 $anchorBL
$btnAll      = New-Button $T.CheckAll      354 470 100 $anchorBR
$btnNone     = New-Button $T.UncheckAll    460 470 90  $anchorBR
$btnDel      = New-Button $T.DeleteChecked 556 470 144 $anchorBR
$btnBack     = New-Button $T.Back          706 470 100 $anchorBR
$pSes.Controls.AddRange(@($btnRefresh2, $btnAll, $btnNone, $btnDel, $btnBack))

$form.Controls.AddRange(@($pSes, $pCat))

# --- Lógica da tela ---
function Update-ProjectCombo([string]$SelectName) {
    # Mantém o projeto escolhido pelo nome: depois de recarregar, a ordem (mais recente primeiro) pode mudar
    $keep = [Math]::Max(0, $cbProj.SelectedIndex)
    if ($SelectName) {
        $i = [Array]::FindIndex([object[]]$script:Projects, [Predicate[object]] { param($p) $p.Name -eq $SelectName })
        if ($i -ge 0) { $keep = $i }
    }
    $cbProj.Items.Clear()
    foreach ($p in $script:Projects) { [void]$cbProj.Items.Add(($T.ProjectItem -f $p.Path, $p.Sessions.Count)) }
    if ($cbProj.Items.Count) { $cbProj.SelectedIndex = [Math]::Min($keep, $cbProj.Items.Count - 1) }
}

function Update-Categories {
    $keep = [Math]::Max(0, $lbCat.SelectedIndex)
    $lbCat.Items.Clear()
    $script:Cats = @()
    if ($cbProj.SelectedIndex -lt 0) { return }
    $script:Cats = @(Get-Categories $script:Projects[$cbProj.SelectedIndex] $script:State)
    foreach ($c in $script:Cats) { [void]$lbCat.Items.Add(('{0}    ({1})' -f (Get-CategoryLabel $c), $c.Sessions.Count)) }
    if ($lbCat.Items.Count) { $lbCat.SelectedIndex = [Math]::Min($keep, $lbCat.Items.Count - 1) }
}

function Update-SelectionLabel {
    $sel = @($lv.CheckedItems | ForEach-Object { $_.Tag })
    $lblSel.Text = if ($sel.Count) { $T.NChecked -f $sel.Count, (Format-Size ([long]($sel | Measure-Object Bytes -Sum).Sum)) } else { $T.NoneChecked }
    $btnDel.Enabled = $sel.Count -gt 0
}

function Update-SessionList([string[]]$CheckIds = @()) {
    # $CheckIds: sessões a remarcar depois de recarregar (as que estiverem abertas ficam de fora)
    $c = $script:CurrentCat
    $lblHead.Text = $T.Header -f (Get-CategoryLabel $c), $c.Sessions.Count, $script:Projects[$cbProj.SelectedIndex].Path
    $script:Filling = $true
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $now = Get-Date
    foreach ($s in $c.Sessions | Sort-Object LastWrite -Descending) {
        $it = New-Object System.Windows.Forms.ListViewItem($s.Title)
        [void]$it.SubItems.Add($s.LastWrite.ToString($T.DateFormat))
        [void]$it.SubItems.Add((Format-Size $s.Bytes))
        [void]$it.SubItems.Add((Get-StatusText $s $now))
        $it.Tag = $s
        if ($s.InUse) { $it.ForeColor = [System.Drawing.Color]::Gray }
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    foreach ($it in $lv.Items) { if ($it.Tag.Id -in $CheckIds -and -not $it.Tag.InUse) { $it.Checked = $true } }
    $script:Filling = $false
    Update-SelectionLabel
}

function Import-Sessions {
    # (Re)lê grupos, arquivadas e todos os .jsonl. Devolve o erro do state.vscdb, se houver.
    $form.Cursor = 'WaitCursor'
    $form.Refresh()
    $err = $null
    try { $script:State = Read-ExtensionState } catch { $script:State = @{}; $err = $_.Exception.Message }
    $script:Projects = @(Get-ClaudeProjects)
    $form.Cursor = 'Default'
    return $err
}

function Invoke-Refresh {
    # Recarrega tudo sem sair da tela atual: mesmo projeto, categoria e marcações
    $projName = if ($cbProj.SelectedIndex -ge 0) { $script:Projects[$cbProj.SelectedIndex].Name }
    $onSessions = $pSes.Visible -and $script:CurrentCat
    $kind = $script:CurrentCat.Kind; $name = $script:CurrentCat.Name
    $checked = @($lv.CheckedItems | ForEach-Object { $_.Tag.Id })

    $stateError = Import-Sessions
    Update-ProjectCombo $projName
    if ($stateError) { Show-Box ($T.StateError -f $stateError) 'Warning' }
    if ($onSessions) {
        $script:CurrentCat = $script:Cats | Where-Object { $_.Kind -eq $kind -and $_.Name -eq $name } | Select-Object -First 1
        if ($script:CurrentCat) { Update-SessionList $checked } else { Show-CategoryPanel }
    }
}

function Show-CategoryPanel {
    $pSes.Visible = $false
    $pCat.Visible = $true
    $form.AcceptButton = $btnOpen
    Set-EscapeButton $form $btnClose
    $lbCat.Focus()
}

function Open-SelectedCategory {
    if ($lbCat.SelectedIndex -lt 0) { return }
    $script:CurrentCat = $script:Cats[$lbCat.SelectedIndex]
    Update-SessionList
    $pCat.Visible = $false
    $pSes.Visible = $true
    $form.AcceptButton = $null
    Set-EscapeButton $form $btnBack
    $lv.Focus()
}

function Invoke-DeleteChecked {
    $sel = @($lv.CheckedItems | ForEach-Object { $_.Tag })
    if (-not $sel.Count) { return }

    # Confere de novo agora: a sessão pode ter sido aberta depois que a lista carregou
    $live = Get-LiveSessionIds
    $now  = Get-Date
    foreach ($s in $sel) {
        $f = Get-Item -LiteralPath (Join-Path $s.ProjectDir "$($s.Id).jsonl") -ErrorAction SilentlyContinue
        if ($f) { $s.LastWrite = $f.LastWriteTime }
        $s.OpenReason = Get-OpenReason $s.Id $s.LastWrite $live $now
        $s.InUse = [bool]$s.OpenReason
    }
    $blocked = @($sel | Where-Object InUse)
    $sel = @($sel | Where-Object { -not $_.InUse })
    if ($blocked.Count) {
        Show-Box ($T.BlockedOpen -f (($blocked | ForEach-Object { "- $($_.Title)" }) -join "`n")) 'Warning'
        Update-SessionList @($sel.Id)
    }
    if (-not $sel.Count) { return }
    if (-not (Show-ConfirmDialog $sel $form)) { return }

    $form.Cursor = 'WaitCursor'
    $deleted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $fails   = [System.Collections.Generic.List[string]]::new()
    [long]$freed = 0
    foreach ($s in $sel) {
        try { Remove-ClaudeSession $s; [void]$deleted.Add($s.Id); $freed += $s.Bytes }
        catch { $fails.Add("- $($s.Title): $($_.Exception.Message)") }
    }
    foreach ($p in $script:Projects) {
        for ($k = $p.Sessions.Count - 1; $k -ge 0; $k--) { if ($deleted.Contains($p.Sessions[$k].Id)) { $p.Sessions.RemoveAt($k) } }
    }
    $form.Cursor = 'Default'

    $kind = $script:CurrentCat.Kind; $name = $script:CurrentCat.Name
    Update-ProjectCombo $script:Projects[$cbProj.SelectedIndex].Name
    Update-Categories
    $script:CurrentCat = $script:Cats | Where-Object { $_.Kind -eq $kind -and $_.Name -eq $name } | Select-Object -First 1
    if ($script:CurrentCat) { Update-SessionList } else { Show-CategoryPanel }

    $msg = $T.Deleted -f $deleted.Count, (Format-Size $freed)
    if ($fails.Count) { $msg += $T.Failed -f ($fails -join "`n") }
    $msg += $T.ReloadHint
    Show-Box $msg $(if ($fails.Count) { 'Warning' } else { 'Information' })
}

$cbProj.Add_SelectedIndexChanged({ Update-Categories })
$lbCat.Add_DoubleClick({ Open-SelectedCategory })
$btnOpen.Add_Click({ Open-SelectedCategory })
$btnClose.Add_Click({ $form.Close() })
$btnBack.Add_Click({ Show-CategoryPanel })
$btnAll.Add_Click({ foreach ($it in $lv.Items) { if (-not $it.Tag.InUse) { $it.Checked = $true } } })
$btnNone.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $false } })
$btnDel.Add_Click({
    try { Invoke-DeleteChecked }
    catch { $form.Cursor = 'Default'; Show-Box ($T.Unexpected -f $_.Exception.Message) 'Error' }
})
$lv.Add_ItemCheck({ param($src, $e) if ($lv.Items[$e.Index].Tag.InUse) { $e.NewValue = $e.CurrentValue } })
$lv.Add_ItemChecked({ if (-not $script:Filling) { Update-SelectionLabel } })

$refresh = {
    try { Invoke-Refresh }
    catch { $form.Cursor = 'Default'; Show-Box ($T.Unexpected -f $_.Exception.Message) 'Error' }
}
$btnRefresh1.Add_Click($refresh)
$btnRefresh2.Add_Click($refresh)
$form.Add_KeyDown({
    param($src, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { $e.Handled = $true; & $refresh }
})

# Carrega depois de a janela aparecer (ler os .jsonl leva alguns segundos)
$form.Add_Shown({
    $form.Activate()
    $stateError = Import-Sessions
    if (-not $script:Projects.Count) { Show-Box ($T.NoSessions -f (Join-Path $ClaudeHome 'projects')) 'Warning'; $form.Close(); return }
    $lblCat.Text = $T.PickCategory
    Update-ProjectCombo
    if ($stateError) { Show-Box ($T.StateError -f $stateError) 'Warning' }
    Show-CategoryPanel
})

Show-CategoryPanel
[void]$form.ShowDialog()
$form.Dispose()
