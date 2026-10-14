#Requires -Version 5.1
<#
.SYNOPSIS
    FileTransfer - 共有フォルダ・この PC・サーバーの間でファイルを転送する

.DESCRIPTION
    送るファイルを選び、送り先（「このPC」またはサーバーのホスト名）とフォルダを指定して転送する。
    転送は robocopy で行い、サーバーへは管理共有（\\HOST\C$ など）に SMB で直接書き込む。
    設計: docs\design.md

.PARAMETER NoShow
    画面を表示せずに初期化だけ行う（tests\ から読み込むため）
#>
param([switch]$NoShow)

$ErrorActionPreference = 'Stop'
$script:AppRoot = $PSScriptRoot

# 起動に失敗したらログに残して知らせる（画面表示後の例外は DispatcherUnhandledException で扱う）
trap {
    $logDir = Join-Path $env:LOCALAPPDATA 'FileTransfer\logs'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $entry = "[{0}] {1}`r`n{2}`r`n" -f (Get-Date), $_, $_.ScriptStackTrace
        [System.IO.File]::AppendAllText((Join-Path $logDir 'startup-error.log'), $entry, [System.Text.Encoding]::UTF8)
    } catch { }
    if ($NoShow) { break }
    try { [System.Windows.MessageBox]::Show("FileTransfer を起動できませんでした。`n$($_.Exception.Message)", 'FileTransfer', 'OK', 'Error') | Out-Null } catch { }
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

#region 初期化 ------------------------------------------------------------------

# lib\*.cs をコンパイルして読み込む。毎回のコンパイルは遅いので、ソースのハッシュ別に DLL をキャッシュする
function Import-FtTypes {
    if ('FileTransfer.Native' -as [type]) { return }
    $sources = @('Native.cs', 'Models.cs') | ForEach-Object { Join-Path $script:AppRoot "lib\$_" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($source in $sources) { $bytes.AddRange([System.IO.File]::ReadAllBytes($source)) }
    $hash = (-join ($sha.ComputeHash($bytes.ToArray()) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
    $binDir = Join-Path $env:LOCALAPPDATA 'FileTransfer\bin'
    $dll = Join-Path $binDir "FileTransfer.Types.$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        if (-not (Test-Path -LiteralPath $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
        Add-Type -Path $sources -OutputAssembly $dll -OutputType Library
    }
    Add-Type -Path $dll
    # 古いバージョンのキャッシュを消す（別のウィンドウで使用中なら消せないので無視する）
    Get-ChildItem -LiteralPath $binDir -Filter 'FileTransfer.Types.*.dll' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $dll } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Read-FtXaml {
    param([string]$Name)
    $reader = [System.Xml.XmlReader]::Create((Join-Path $script:AppRoot "ui\$Name"))
    try { return [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
}

function Get-FtNamedElements {
    param($Root, [string[]]$Names)
    $table = @{}
    foreach ($name in $Names) { $table[$name] = $Root.FindName($name) }
    return $table
}

Import-FtTypes
$script:ModulePaths = @('Config', 'PathResolver', 'Connection', 'TransferEngine', 'Log') |
    ForEach-Object { Join-Path $script:AppRoot "lib\$_.psm1" }
foreach ($modulePath in $script:ModulePaths) { Import-Module $modulePath -Force -DisableNameChecking }

# スタイルはアプリケーションのリソースに置き、各ウィンドウの XAML から StaticResource で参照する
$script:App = [System.Windows.Application]::Current
if (-not $script:App) {
    $script:App = New-Object System.Windows.Application
    $script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
}
$script:App.Resources.MergedDictionaries.Add((Read-FtXaml 'Styles.xaml'))

# バックグラウンド処理（接続確認・フォルダのサイズ計算・転送）用
$sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
$sessionState.ImportPSModule([string[]]$script:ModulePaths)
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 4, $sessionState, $Host)
$script:Pool.Open()

$script:Config = Get-FtConfig -AppRoot $script:AppRoot
Remove-FtOldLogs -RetentionDays ([int]$script:Config.log.retentionDays)

#endregion

#region 状態 --------------------------------------------------------------------

$script:Items = New-Object 'System.Collections.ObjectModel.ObservableCollection[FileTransfer.FileItem]'
$script:Phase = 'idle'                  # idle | running | done | error
$script:Check = @{ Status = 'empty'; Code = 0; User = ''; Root = ''; HostName = ''; Seq = 0 }
$script:DestKind = 'server'             # server | local
$script:LastFolder = @{
    server = @($script:Config.history.serverFolders)[0]
    local  = @($script:Config.history.localFolders)[0]
}
$script:HostAlias = @{}                 # ホスト名 → 実際に接続した名前（FQDN など）
$script:SessionUsers = @{}              # ホスト名 → このセッションでログオンしたユーザー
$script:Connections = New-Object System.Collections.Generic.List[string]
$script:Run = $null
$script:RunLog = New-Object System.Collections.Generic.List[string]
$script:LastError = $null
$script:NoticeUntil = [datetime]::MinValue
$script:PendingSizes = 0
$script:Suppress = $false
$script:Jobs = New-Object System.Collections.ArrayList

#endregion

#region 画面 --------------------------------------------------------------------

$window = Read-FtXaml 'MainWindow.xaml'
$ui = Get-FtNamedElements $window @(
    'CountText', 'ClearButton', 'AddButton', 'FileList', 'EmptyHint',
    'DestBox', 'DestBadge', 'DestDot', 'DestPcIcon', 'FolderBox', 'HintText',
    'ResultPanel', 'ResultIcon', 'ResultText', 'OpenLink', 'RdpLink', 'LogonLink', 'DetailLink',
    'StartButton', 'ProgressPanel', 'TotalProgress', 'ProgressText', 'CancelButton')
$ui.FileList.ItemsSource = $script:Items

$iconPath = Join-Path $script:AppRoot 'FileTransfer.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $iconPath)) } catch { }
}

function Get-FtBrush { param([string]$Key) $script:App.Resources[$Key] }

#endregion

#region バックグラウンド処理 -----------------------------------------------------

# Script を Runspace プールで実行し、終わったら UI スレッドで OnComplete（param($value, $err, $context)）を呼ぶ
function Start-FtJob {
    param([string]$Script, [hashtable]$Parameters = @{}, [scriptblock]$OnComplete, $Context = $null)
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($Script)
    foreach ($key in $Parameters.Keys) { [void]$ps.AddParameter($key, $Parameters[$key]) }
    $handle = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ PowerShell = $ps; Handle = $handle; OnComplete = $OnComplete; Context = $Context })
}

function Update-FtJobs {
    for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) {
        $job = $script:Jobs[$i]
        if (-not $job.Handle.IsCompleted) { continue }
        $script:Jobs.RemoveAt($i)
        $value = $null
        $err = $null
        try {
            $output = $job.PowerShell.EndInvoke($job.Handle)
            if ($output.Count -gt 0) { $value = $output[$output.Count - 1] }
        } catch {
            $err = $_.Exception
        }
        $job.PowerShell.Dispose()
        if ($job.OnComplete) { & $job.OnComplete $value $err $job.Context }
    }
}

#endregion

#region 送り先 ------------------------------------------------------------------

function Get-FtDestText { "$($ui.DestBox.Text)".Trim() }
function Get-FtFolderText { "$($ui.FolderBox.Text)".Trim() }
function Get-FtDestKey { (Get-FtDestText) + '|' + (Get-FtFolderText) }

function Resolve-FtCurrent {
    param([datetime]$Now = (Get-Date))
    return Resolve-FtDestination -Destination (Get-FtDestText) -Folder (Get-FtFolderText) -Now $Now `
        -Mappings @($script:Config.serverShareMappings) -HostAlias $script:HostAlias
}

# 接続に使われるユーザー: このセッションでログオンした人 > 保存済みの資格情報 > Windows のログオンユーザー
function Get-FtHostUser {
    param([string]$HostName)
    if ($script:SessionUsers.ContainsKey($HostName)) { return $script:SessionUsers[$HostName] }
    $saved = Get-FtSavedUser $HostName
    if ($saved) { return $saved }
    return Get-FtCurrentUser
}

function Set-FtComboText {
    param($Combo, [string]$Text)
    $script:Suppress = $true
    try { $Combo.Text = $Text } finally { $script:Suppress = $false }
}

function Set-FtComboItems {
    param($Combo, [object[]]$Items)
    $text = $Combo.Text
    $script:Suppress = $true
    try {
        $Combo.ItemsSource = [string[]]@($Items | Where-Object { $_ })
        $Combo.Text = $text
    } finally { $script:Suppress = $false }
}

function Update-FtDestItems {
    Set-FtComboItems $ui.DestBox (@(Get-FtLocalLabel) + @($script:Config.history.destinations))
}

function Update-FtFolderItems {
    $key = if ($script:DestKind -eq 'local') { 'localFolders' } else { 'serverFolders' }
    Set-FtComboItems $ui.FolderBox @($script:Config.history[$key])
}

# 送り先の種類（このPC / サーバー）が変わったら、フォルダ欄をその種類で前回使った値に戻す
function Update-FtDestKind {
    $kind = if (Test-FtLocalDestination (Get-FtDestText)) { 'local' } else { 'server' }
    if ($kind -eq $script:DestKind) { return }
    $script:LastFolder[$script:DestKind] = $ui.FolderBox.Text
    $script:DestKind = $kind
    Update-FtFolderItems
    Set-FtComboText $ui.FolderBox $script:LastFolder[$kind]
}

# 接続確認を予約する（入力中は 0.7 秒待つ）
function Request-FtHostCheck {
    param([switch]$Immediate)
    $script:CheckTimer.Stop()
    $script:Check.Seq++
    $resolved = Resolve-FtCurrent
    if ($resolved.IsLocal) {
        $script:Check.Status = 'local'
    } elseif (-not $resolved.HostName -or -not (Test-FtHostName $resolved.HostName)) {
        $script:Check.Status = 'empty'
    } else {
        $script:Check.Status = 'checking'
        if ($Immediate) { Invoke-FtHostCheck } else { $script:CheckTimer.Start() }
    }
    Update-FtView
}

function Invoke-FtHostCheck {
    $resolved = Resolve-FtCurrent
    if ($resolved.IsLocal -or -not $resolved.HostName -or -not (Test-FtHostName $resolved.HostName)) { Update-FtView; return }
    $connectName = if ($script:HostAlias.ContainsKey($resolved.HostName)) { $script:HostAlias[$resolved.HostName] } else { $resolved.HostName }
    $root = if ($resolved.ShareRoot) { $resolved.ShareRoot } else { "\\$connectName\C`$" }
    $seq = ++$script:Check.Seq
    $script:Check.Status = 'checking'
    $script:Check.Root = $root
    $script:Check.HostName = $resolved.HostName
    Update-FtView
    Start-FtJob -Script 'param($ShareRoot) Test-FtShareAccess -ShareRoot $ShareRoot' -Parameters @{ ShareRoot = $root } `
        -Context @{ Seq = $seq; HostName = $resolved.HostName } -OnComplete {
            param($value, $err, $context)
            if ($context.Seq -ne $script:Check.Seq) { return }
            if ($err -or $null -eq $value) {
                $script:Check.Status = 'error'
                $script:Check.Code = 0
            } else {
                $script:Check.Status = $value.Status
                $script:Check.Code = $value.Code
            }
            $script:Check.User = Get-FtHostUser $context.HostName
            Update-FtView
        }
}

function Update-FtDestination {
    param([switch]$Immediate)
    Exit-FtFinished
    Update-FtDestKind
    Request-FtHostCheck -Immediate:$Immediate
}

function Update-FtFolder {
    Exit-FtFinished
    # サーバーで、ドライブや共有が変わったら確認し直す（C:\ → D:\ など）
    $resolved = Resolve-FtCurrent
    if (-not $resolved.IsLocal -and $resolved.ShareRoot -and $resolved.ShareRoot -ine $script:Check.Root -and $script:Check.Status -ne 'empty') {
        Request-FtHostCheck
    } else {
        Update-FtView
    }
}

#endregion

#region 送るファイル --------------------------------------------------------------

function Find-FtItem {
    param([string]$Path)
    foreach ($item in $script:Items) { if ($item.Path -ieq $Path) { return $item } }
    return $null
}

function Add-FtPaths {
    param([string[]]$Paths)
    if ($script:Phase -eq 'running') { return }
    $skipped = New-Object System.Collections.Generic.List[string]
    $added = 0
    foreach ($raw in $Paths) {
        $path = "$raw".Trim().TrimEnd('\')
        if (-not $path) { continue }
        $isFolder = [System.IO.Directory]::Exists($path)
        if (-not $isFolder -and -not [System.IO.File]::Exists($path)) { continue }
        if (Find-FtItem $path) { continue }
        $name = [System.IO.Path]::GetFileName($path)
        if (-not $name) { continue }
        if (@($script:Items | Where-Object { $_.Name -ieq $name }).Count -gt 0) { $skipped.Add($name); continue }

        $item = New-Object FileTransfer.FileItem $path, $isFolder
        if ($isFolder) {
            $script:PendingSizes++
            Start-FtJob -Script 'param($Path) Measure-FtFolder -Path $Path' -Parameters @{ Path = $path } -Context @{ Item = $item } -OnComplete {
                param($value, $err, $context)
                $script:PendingSizes--
                if ($value) {
                    $context.Item.Size = [long]$value.Bytes
                    $context.Item.FileCount = [int]$value.Files
                } else {
                    $context.Item.Size = 0
                }
                Update-FtView
            }
        } else {
            $item.Size = (New-Object System.IO.FileInfo $path).Length
        }
        $script:Items.Add($item)
        $added++
    }
    if ($added -gt 0 -or $skipped.Count -gt 0) { Exit-FtFinished }
    if ($skipped.Count -gt 0) {
        Show-FtNotice ('同じ名前のファイルがあるため追加しませんでした：' + ($skipped -join '、')) 'warn'
    }
    Update-FtView
}

function Remove-FtItems {
    param([object[]]$Items)
    if ($script:Phase -eq 'running') { return }
    foreach ($item in @($Items)) { if ($null -ne $item) { [void]$script:Items.Remove($item) } }
    Exit-FtFinished
    Update-FtView
}

function Show-FtOpenDialog {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Title = '送るファイルを選択'
    $dialog.Filter = 'すべてのファイル (*.*)|*.*'
    $last = "$($script:Config.history.lastOpenDir)"
    if ($last) { $dialog.InitialDirectory = $last }
    if ($dialog.ShowDialog($window)) {
        $script:Config.history.lastOpenDir = Split-Path -Parent $dialog.FileNames[0]
        Save-FtSettings
        Add-FtPaths $dialog.FileNames
    }
}

#endregion

#region 表示 --------------------------------------------------------------------

function Get-FtTotalBytes {
    $total = 0L
    foreach ($item in $script:Items) { if ($item.Size -gt 0) { $total += $item.Size } }
    return $total
}

function Test-FtCanStart {
    if ($script:Phase -eq 'running' -or $script:Items.Count -eq 0 -or $script:PendingSizes -gt 0) { return $false }
    $resolved = Resolve-FtCurrent
    if ($resolved.Error) { return $false }
    if ($resolved.IsLocal) { return $true }
    return $script:Check.Status -in 'ok', 'auth', 'conflict', 'error'
}

function Set-FtHint {
    param([string]$Kind, [string]$Text, [switch]$WithLogon)
    $hint = $ui.HintText
    $hint.Inlines.Clear()
    $hint.ToolTip = $null
    if ($Kind -eq 'path') {
        $hint.Foreground = Get-FtBrush 'MutedBrush'
        $hint.Inlines.Add((New-Object System.Windows.Documents.Run '→ '))
        $run = New-Object System.Windows.Documents.Run $Text
        $run.FontFamily = Get-FtBrush 'MonoFont'
        $run.Foreground = Get-FtBrush 'PathBrush'
        $hint.Inlines.Add($run)
        $hint.ToolTip = $Text
        return
    }
    $hint.Foreground = switch ($Kind) { 'warn' { Get-FtBrush 'WarnBrush' } 'error' { Get-FtBrush 'ErrorBrush' } default { Get-FtBrush 'MutedBrush' } }
    $hint.Inlines.Add((New-Object System.Windows.Documents.Run $Text))
    if ($WithLogon) {
        $hint.Inlines.Add((New-Object System.Windows.Documents.Run '  '))
        $link = New-Object System.Windows.Documents.Hyperlink (New-Object System.Windows.Documents.Run 'ログオン…')
        $link.Foreground = Get-FtBrush 'AccentBrush'
        $link.Add_Click({ Show-FtLogon })
        $hint.Inlines.Add($link)
    }
}

function Update-FtHint {
    param($Resolved)
    $hostName = $Resolved.HostName
    if (-not $Resolved.IsLocal -and -not $hostName) { Set-FtHint 'muted' 'ホスト名を入力するか、▾ から選んでください'; return }
    if ($Resolved.Error) { Set-FtHint 'error' $Resolved.Error; return }
    if (-not $Resolved.IsLocal) {
        switch ($script:Check.Status) {
            'checking'    { Set-FtHint 'muted' '接続を確認しています…'; return }
            'unreachable' { Set-FtHint 'error' "$hostName に接続できません（ホスト名を確認してください）"; return }
            'noshare'     { Set-FtHint 'error' "$($script:Check.Root) が見つかりません（管理共有が無効の可能性があります）"; return }
            'auth'        { Set-FtHint 'warn' "$hostName へのログオンが必要です" -WithLogon; return }
            'conflict'    { Set-FtHint 'warn' "$hostName には別のユーザーで接続中です" -WithLogon; return }
            'error'       { Set-FtHint 'warn' "$hostName の確認でエラーが発生しました（エラー $($script:Check.Code)）"; return }
        }
    }
    Set-FtHint 'path' $Resolved.Path
}

function Update-FtBadge {
    param($Resolved)
    $badge = $ui.DestBadge
    if ($Resolved.IsLocal) {
        $ui.DestDot.Visibility = 'Collapsed'
        $ui.DestPcIcon.Visibility = 'Visible'
        $badge.IsEnabled = $false
        $badge.ToolTip = 'この PC'
        return
    }
    $ui.DestDot.Visibility = 'Visible'
    $ui.DestPcIcon.Visibility = 'Collapsed'
    $dot = $ui.DestDot
    $dot.Stroke = $null
    switch ($script:Check.Status) {
        'ok'       { $dot.Fill = Get-FtBrush 'OkDotBrush'; $badge.ToolTip = "接続OK：$($script:Check.User)（クリックでアカウントを変更）" }
        'auth'     { $dot.Fill = Get-FtBrush 'WarnDotBrush'; $badge.ToolTip = 'ログオンが必要です（クリックしてログオン）' }
        'conflict' { $dot.Fill = Get-FtBrush 'WarnDotBrush'; $badge.ToolTip = '別のユーザーで接続中です（クリックしてログオン）' }
        'checking' { $dot.Fill = Get-FtBrush 'IdleDotBrush'; $badge.ToolTip = '確認中…' }
        'empty'    { $dot.Fill = $null; $dot.Stroke = Get-FtBrush 'FaintBrush'; $badge.ToolTip = $null }
        default    { $dot.Fill = Get-FtBrush 'ErrorBrush'; $badge.ToolTip = '接続できません' }
    }
    $badge.IsEnabled = ($script:Phase -ne 'running') -and [bool]$Resolved.HostName -and (Test-FtHostName $Resolved.HostName)
}

function Update-FtView {
    $running = $script:Phase -eq 'running'
    $count = $script:Items.Count
    $ui.CountText.Text = if ($count -eq 0) { '' } elseif ($script:PendingSizes -gt 0) { "$count 件・計算中…" } else { "$count 件・" + [FileTransfer.FileItem]::FormatSize((Get-FtTotalBytes)) }
    $ui.ClearButton.Visibility = if ($count -gt 0 -and -not $running) { 'Visible' } else { 'Collapsed' }
    $ui.EmptyHint.Visibility = if ($count -eq 0) { 'Visible' } else { 'Collapsed' }
    $ui.FileList.Tag = if ($running) { 'locked' } else { $null }
    $ui.AddButton.IsEnabled = -not $running
    $ui.DestBox.IsEnabled = -not $running
    $ui.FolderBox.IsEnabled = -not $running

    $resolved = Resolve-FtCurrent
    Update-FtBadge $resolved
    Update-FtHint $resolved
    $folderInvalid = $resolved.Error -and (Get-FtFolderText) -and ($resolved.IsLocal -or ($resolved.HostName -and (Test-FtHostName $resolved.HostName)))
    # 編集できる ComboBox は枠の色を変えられないので、文字を赤くする
    $ui.FolderBox.Foreground = if ($folderInvalid) { Get-FtBrush 'ErrorBrush' } else { Get-FtBrush 'TextBrush' }

    $ui.StartButton.Visibility = if ($running) { 'Collapsed' } else { 'Visible' }
    $ui.ProgressPanel.Visibility = if ($running) { 'Visible' } else { 'Collapsed' }
    $ui.StartButton.IsEnabled = Test-FtCanStart
}

# 結果の行: Kind = ok | error | warn | info、Links = 表示するリンク（Open, Rdp, Logon, Detail）
function Set-FtResult {
    param([string]$Kind, [string]$Text, [string[]]$Links = @())
    if (-not $Kind) { $ui.ResultPanel.Visibility = 'Collapsed'; return }
    $glyph, $brush = switch ($Kind) {
        'ok'    { [char]0xE73E, (Get-FtBrush 'OkBrush') }
        'error' { [char]0xE783, (Get-FtBrush 'ErrorBrush') }
        'warn'  { [char]0xE7BA, (Get-FtBrush 'WarnBrush') }
        default { [char]0xE946, (Get-FtBrush 'MutedBrush') }
    }
    $ui.ResultIcon.Text = [string]$glyph
    $ui.ResultIcon.Foreground = $brush
    $ui.ResultText.Text = $Text
    $ui.ResultText.Foreground = $brush
    $ui.ResultText.ToolTip = $Text
    $ui.OpenLink.Visibility = if ($Links -contains 'Open') { 'Visible' } else { 'Collapsed' }
    $ui.RdpLink.Visibility = if ($Links -contains 'Rdp') { 'Visible' } else { 'Collapsed' }
    $ui.LogonLink.Visibility = if ($Links -contains 'Logon') { 'Visible' } else { 'Collapsed' }
    $ui.DetailLink.Visibility = if ($Links -contains 'Detail') { 'Visible' } else { 'Collapsed' }
    $ui.ResultPanel.Visibility = 'Visible'
}

# 一時的なお知らせ（6 秒で消える）
function Show-FtNotice {
    param([string]$Text, [string]$Kind = 'info', [string[]]$Links = @())
    if ($script:Phase -eq 'running') { return }
    Set-FtResult $Kind $Text $Links
    $script:NoticeUntil = (Get-Date).AddSeconds(6)
}

function Update-FtNotice {
    if ($script:Phase -eq 'idle' -and $script:NoticeUntil -ne [datetime]::MinValue -and (Get-Date) -gt $script:NoticeUntil) {
        $script:NoticeUntil = [datetime]::MinValue
        Set-FtResult $null
    }
}

# 完了・エラーの表示中に、送るファイルや送り先が変わったら元に戻す
function Exit-FtFinished {
    if ($script:Phase -ne 'done' -and $script:Phase -ne 'error') { return }
    $script:Phase = 'idle'
    foreach ($item in $script:Items) { $item.State = ''; $item.Progress = 0 }
    Set-FtResult $null
}

#endregion

#region 転送 --------------------------------------------------------------------

function Add-FtRunLog {
    param([string]$Line)
    $script:RunLog.Add($Line)
    Write-FtLog $Line
}

function Format-FtDuration {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ('{0:0.0} 秒' -f $Seconds) }
    return ('{0} 分 {1} 秒' -f [int][Math]::Floor($Seconds / 60), [int]($Seconds % 60))
}

function Save-FtSettings {
    try { Save-FtConfig $script:Config } catch { Write-FtLog "設定を保存できませんでした: $($_.Exception.Message)" }
}

function Save-FtHistory {
    $history = $script:Config.history
    $dest = Get-FtDestText
    if (-not (Test-FtLocalDestination $dest)) { $history.destinations = Add-FtHistory $history.destinations $dest.ToUpperInvariant() }
    $key = if ($script:DestKind -eq 'local') { 'localFolders' } else { 'serverFolders' }
    $history[$key] = Add-FtHistory $history[$key] (Get-FtFolderText)
    $script:Config.last = @{ destination = $dest; folder = (Get-FtFolderText) }
    Save-FtSettings
    Update-FtDestItems
    Update-FtFolderItems
}

function Start-FtTransfer {
    if (-not (Test-FtCanStart)) { return }
    $now = Get-Date
    $resolved = Resolve-FtCurrent $now
    if (-not $resolved.IsLocal -and $script:Check.Status -in 'auth', 'conflict') {
        Show-FtLogon -Resume
        return
    }

    # エラー後にやり直すときは、{datetime} を展開し直さず前回と同じフォルダへ送る
    $dest = $resolved.Path
    if ($script:Phase -eq 'error' -and $script:Run -and $script:Run.Key -eq (Get-FtDestKey)) {
        $dest = $script:Run.Dest
        $now = $script:Run.Now
    }

    $transfer = $script:Config.transfer
    $stage = ''
    if (-not $resolved.IsLocal -and $transfer.keepLocalCopy -and @($script:Items | Where-Object { $_.Path -like '\\*' }).Count -gt 0) {
        $stage = [Environment]::ExpandEnvironmentVariables((Expand-FtTemplate -Template "$($transfer.localCopyFolder)" -Now $now -HostName $resolved.HostName))
    }
    $items = @($script:Items | ForEach-Object { @{ Path = $_.Path; IsFolder = $_.IsFolder; Size = [long][Math]::Max(0, $_.Size) } })
    $steps = New-FtTransferPlan -Items $items -Destination $dest -StageFolder $stage -LargeThresholdBytes ([long]$transfer.unbufferedThresholdMB * 1MB)

    $sync = [hashtable]::Synchronized(@{
        Cancel          = $false
        ProcessId       = 0
        BytesTotal      = 0L
        BytesDone       = 0L
        CurrentItem     = $null
        CurrentFraction = 0.0
        StepIndex       = 0
        Completed       = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Log             = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Result          = $null
    })
    $script:Run = @{
        Sync      = $sync
        Dest      = $dest
        Now       = $now
        Key       = Get-FtDestKey
        HostName  = $resolved.HostName
        IsLocal   = $resolved.IsLocal
        Started   = Get-Date
        Samples   = New-Object System.Collections.Generic.List[object]
        ItemCount = $script:Items.Count
        Bytes     = Get-FtTotalBytes
    }
    foreach ($item in $script:Items) { $item.State = ''; $item.Progress = 0 }
    $script:RunLog.Clear()
    $script:LastError = $null
    $script:NoticeUntil = [datetime]::MinValue
    Add-FtRunLog ("転送開始: {0} 件（{1}）→ {2}" -f $script:Items.Count, [FileTransfer.FileItem]::FormatSize($script:Run.Bytes), $dest)
    if (-not $resolved.IsLocal) { Add-FtRunLog "  接続ユーザー: $(Get-FtHostUser $resolved.HostName)" }
    if ($stage) { Add-FtRunLog "  ローカルにもコピーを残す: $stage" }
    Save-FtHistory

    $script:Phase = 'running'
    Set-FtResult $null
    $ui.CancelButton.IsEnabled = $true
    $ui.TotalProgress.Value = 0
    $ui.ProgressText.Text = '接続しています…'
    Update-FtView

    Start-FtJob -Script 'param($Steps, $Sync, $RetryCount, $RetryWaitSec, $Threads) Invoke-FtTransferPlan -Steps $Steps -Sync $Sync -RetryCount $RetryCount -RetryWaitSec $RetryWaitSec -Threads $Threads' `
        -Parameters @{
            Steps        = $steps
            Sync         = $sync
            RetryCount   = [int]$transfer.retryCount
            RetryWaitSec = [int]$transfer.retryWaitSec
            Threads      = [int]$transfer.threadsForFolders
        } -OnComplete {
            param($value, $err, $context)
            Complete-FtTransfer $err
        }
}

# 転送中の進捗を画面に反映する（タイマーから呼ぶ）
function Update-FtRunProgress {
    if ($script:Phase -ne 'running' -or $null -eq $script:Run) { return }
    $sync = $script:Run.Sync

    $line = $null
    while ($sync.Log.TryDequeue([ref]$line)) { Add-FtRunLog $line }
    $path = $null
    while ($sync.Completed.TryDequeue([ref]$path)) {
        $item = Find-FtItem $path
        if ($item) { $item.State = 'done'; $item.Progress = 0 }
    }
    $current = $sync.CurrentItem
    foreach ($item in $script:Items) {
        if ($item.State -eq 'cur' -and $item.Path -ine $current) { $item.State = '' }
    }
    if ($current) {
        $item = Find-FtItem $current
        if ($item -and $item.State -ne 'done') { $item.State = 'cur'; $item.Progress = [double]$sync.CurrentFraction }
    }

    if ($sync.Cancel) { return }
    $total = [long]$sync.BytesTotal
    $done = [long]$sync.BytesDone
    $ui.TotalProgress.Value = if ($total -gt 0) { [Math]::Min(1, $done / $total) } else { 0 }

    # 直近 4 秒の平均速度
    $now = Get-Date
    $samples = $script:Run.Samples
    $samples.Add(@{ Time = $now; Bytes = $done })
    while ($samples.Count -gt 2 -and ($now - $samples[0].Time).TotalSeconds -gt 4) { $samples.RemoveAt(0) }
    $span = ($now - $samples[0].Time).TotalSeconds
    if ($done -le 0 -or $span -lt 0.5) {
        if ($done -le 0) { $ui.ProgressText.Text = '接続しています…' }
        return
    }
    $speed = ($done - $samples[0].Bytes) / $span
    $percent = if ($total -gt 0) { [int][Math]::Floor(100 * $done / $total) } else { 0 }
    $remaining = if ($speed -gt 0) { '残り ' + (Format-FtRemaining (($total - $done) / $speed)) } else { '' }
    $ui.ProgressText.Text = ('{0}%・{1}/s・{2}' -f $percent, [FileTransfer.FileItem]::FormatSize([long]$speed), $remaining).TrimEnd('・')
}

function Format-FtRemaining {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ('{0} 秒' -f [int][Math]::Max(1, [Math]::Ceiling($Seconds))) }
    return ('{0} 分 {1} 秒' -f [int][Math]::Floor($Seconds / 60), [int]($Seconds % 60))
}

function Complete-FtTransfer {
    param($JobError)
    Update-FtRunProgress
    $run = $script:Run
    $sync = $run.Sync
    $line = $null
    while ($sync.Log.TryDequeue([ref]$line)) { Add-FtRunLog $line }
    $result = $sync.Result
    if ($null -eq $result) {
        $message = if ($JobError) { $JobError.Message } else { '不明なエラー' }
        $result = @{ Status = 'failed'; Code = 0; Message = $message; Missing = @() }
    }
    $elapsed = ((Get-Date) - $run.Started).TotalSeconds

    switch ($result.Status) {
        'success' {
            $script:Phase = 'done'
            foreach ($item in $script:Items) { $item.State = 'done'; $item.Progress = 0 }
            $text = '{0} 件を転送しました（{1}・{2}）' -f $run.ItemCount, [FileTransfer.FileItem]::FormatSize($run.Bytes), (Format-FtDuration $elapsed)
            Add-FtRunLog "完了: $text"
            $links = @('Open')
            if (-not $run.IsLocal) { $links += 'Rdp' }
            Set-FtResult 'ok' $text $links
        }
        'canceled' {
            $script:Phase = 'idle'
            foreach ($item in $script:Items) { $item.State = ''; $item.Progress = 0 }
            Add-FtRunLog '中止しました'
            $script:LastError = @{ Detail = '転送を中止しました。送り先に、途中までコピーされたファイルが残っている可能性があります。' }
            Show-FtNotice '中止しました。送り先に途中までのファイルが残っている可能性があります' 'warn' @('Detail')
        }
        default {
            $script:Phase = 'error'
            foreach ($item in $script:Items) { if ($item.State -eq 'cur') { $item.State = ''; $item.Progress = 0 } }
            $target = if ($run.IsLocal) { '送り先' } else { $run.HostName }
            $info = Get-FtErrorInfo -Code ([int]$result.Code) -Target $target -Missing @($result.Missing) -Fallback "$($result.Message)" -Server:(-not $run.IsLocal)
            $script:LastError = $info
            Add-FtRunLog "エラー: $($info.Short)（終了コード $($result.ExitCode)）"
            $links = @()
            if ($info.NeedsLogon -and -not $run.IsLocal) { $links += 'Logon' }
            $links += 'Detail'
            Set-FtResult 'error' $info.Short $links
        }
    }
    Update-FtView
}

function Stop-FtTransfer {
    if ($script:Phase -ne 'running') { return }
    $sync = $script:Run.Sync
    $sync.Cancel = $true
    $ui.CancelButton.IsEnabled = $false
    $ui.ProgressText.Text = '中止しています…'
    $processId = [int]$sync.ProcessId
    if ($processId -gt 0) {
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            if ($process.ProcessName -ieq 'robocopy') { $process.Kill() }
        } catch { }
    }
}

#endregion

#region ダイアログ ----------------------------------------------------------------

function Submit-FtLogon {
    $state = $script:Logon
    $d = $state.D
    if ($state.Busy) { return }
    $user = $d.UserBox.Text.Trim()
    $message = if (-not $user) { 'ユーザー名を入力してください。' } elseif ($d.PassBox.SecurePassword.Length -eq 0) { 'パスワードを入力してください。' } else { '' }
    if ($message) {
        $d.ErrorText.Text = $message
        $d.ErrorText.Visibility = 'Visible'
        if (-not $user) { [void]$d.UserBox.Focus() } else { [void]$d.PassBox.Focus() }
        return
    }
    $state.Busy = $true
    $state.User = $user
    $state.Save = [bool]$d.SaveBox.IsChecked
    $d.ErrorText.Visibility = 'Collapsed'
    $d.OkButton.Content = '接続中…'
    foreach ($control in $d.OkButton, $d.UserBox, $d.PassBox, $d.SaveBox) { $control.IsEnabled = $false }
    Start-FtJob -Script 'param($HostName, $ShareRoot, $UserName, $Password, $Save) Connect-FtShare -HostName $HostName -ShareRoot $ShareRoot -UserName $UserName -Password $Password -Save:$Save' `
        -Parameters @{ HostName = $state.HostName; ShareRoot = $state.Root; UserName = $user; Password = $d.PassBox.SecurePassword.Copy(); Save = $state.Save } `
        -Context $state -OnComplete {
            param($value, $err, $context)
            $context.Busy = $false
            if (-not $context.Dialog.IsVisible) {
                # 接続中にキャンセルされた: 接続できていたら、終了時に切断する
                if ($value -and $value.Code -eq 0 -and -not $script:Connections.Contains($value.Root)) { $script:Connections.Add($value.Root) }
                return
            }
            $dd = $context.D
            $dd.OkButton.Content = 'OK'
            foreach ($control in $dd.OkButton, $dd.UserBox, $dd.PassBox, $dd.SaveBox) { $control.IsEnabled = $true }
            if ($err) {
                $dd.ErrorText.Text = $err.Message
            } elseif ($value.Code -eq 0) {
                $context.Result = $value
                $context.Dialog.DialogResult = $true
                return
            } else {
                $info = Get-FtErrorInfo -Code ([int]$value.Code) -Target $context.HostName -Server
                $dd.ErrorText.Text = $info.Short + "（エラー $($value.Code)）"
            }
            $dd.ErrorText.Visibility = 'Visible'
            [void]$dd.PassBox.Focus()
            $dd.PassBox.SelectAll()
        }
}

function Show-FtLogon {
    param([switch]$Resume)
    if ($script:Phase -eq 'running') { return }
    $resolved = Resolve-FtCurrent
    if ($resolved.IsLocal -or -not $resolved.HostName -or -not (Test-FtHostName $resolved.HostName)) { return }
    $hostName = $resolved.HostName
    $root = if ($resolved.ShareRoot) { $resolved.ShareRoot } else { "\\$hostName\C`$" }

    $dialog = Read-FtXaml 'LogonDialog.xaml'
    $dialog.Owner = $window
    $d = Get-FtNamedElements $dialog @('Heading', 'UserBox', 'UserPlaceholder', 'PassBox', 'ErrorText', 'SaveBox', 'OkButton', 'CancelButton')
    # ハンドラーからは $script:Logon で参照する（GetNewClosure を使うとスクリプトの関数が見えなくなるため）
    $script:Logon = @{ Result = $null; Busy = $false; Dialog = $dialog; D = $d; HostName = $hostName; Root = $root; User = ''; Save = $false }
    $state = $script:Logon

    $d.Heading.Text = "$hostName にログオン"
    $d.UserPlaceholder.Text = "$hostName\ユーザー名 または $env:USERDOMAIN\ユーザー名"
    $initialUser = if ($script:SessionUsers.ContainsKey($hostName)) { $script:SessionUsers[$hostName] } else { Get-FtSavedUser $hostName }
    $d.UserBox.Text = "$initialUser"
    $d.UserPlaceholder.Visibility = if ($d.UserBox.Text) { 'Collapsed' } else { 'Visible' }
    $d.UserBox.Add_TextChanged({
        $dd = $script:Logon.D
        $dd.UserPlaceholder.Visibility = if ($dd.UserBox.Text) { 'Collapsed' } else { 'Visible' }
    })
    $d.OkButton.Add_Click({ Submit-FtLogon })
    $dialog.Add_ContentRendered({
        $dd = $script:Logon.D
        if ($dd.UserBox.Text) { [void]$dd.PassBox.Focus() } else { [void]$dd.UserBox.Focus() }
    })
    [void]$dialog.ShowDialog()

    $value = $state.Result
    if ($null -eq $value) { return }
    $script:SessionUsers[$hostName] = $state.User
    if ($value.ConnectName -and $value.ConnectName -ine $hostName) { $script:HostAlias[$hostName] = $value.ConnectName }
    if (-not $script:Connections.Contains($value.Root)) { $script:Connections.Add($value.Root) }
    $script:Check.Seq++
    $script:Check.Status = 'ok'
    $script:Check.Code = 0
    $script:Check.User = $state.User
    $script:Check.Root = $value.Root
    $saved = if ($value.Saved) { '（資格情報を保存）' } else { '' }
    Write-FtLog "$hostName に $($state.User) でログオンしました$saved"
    if ($state.Save -and -not $value.Saved) { Show-FtNotice "資格情報を保存できませんでした（エラー $($value.SaveError)）" 'warn' }
    $retry = $Resume -or $script:Phase -eq 'error'
    Update-FtView
    if ($retry) { Start-FtTransfer }
}

function Show-FtDetails {
    $dialog = Read-FtXaml 'DetailsDialog.xaml'
    $dialog.Owner = $window
    $d = Get-FtNamedElements $dialog @('MessageText', 'LogBox', 'OpenLogButton', 'CloseButton')
    $d.MessageText.Text = if ($script:LastError) { $script:LastError.Detail } else { '' }
    $d.LogBox.Text = $script:RunLog -join "`r`n"
    $d.LogBox.ScrollToEnd()
    $d.OpenLogButton.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Get-FtLogFolder)) })
    # ［閉じる］は IsCancel なのでクリックで閉じる
    [void]$dialog.ShowDialog()
}

#endregion

#region イベント ------------------------------------------------------------------

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:Timer.Add_Tick({ Update-FtJobs; Update-FtRunProgress; Update-FtNotice })

$script:CheckTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CheckTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$script:CheckTimer.Add_Tick({ $script:CheckTimer.Stop(); Invoke-FtHostCheck })

$ui.AddButton.Add_Click({ Show-FtOpenDialog })
$ui.ClearButton.Add_Click({ Remove-FtItems @($script:Items) })
$ui.StartButton.Add_Click({ Start-FtTransfer })
$ui.CancelButton.Add_Click({ Stop-FtTransfer })
$ui.DestBadge.Add_Click({ Show-FtLogon })
$ui.LogonLink.Add_Click({ Show-FtLogon })
$ui.DetailLink.Add_Click({ Show-FtDetails })
$ui.OpenLink.Add_Click({ if ($script:Run) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:Run.Dest) } })
$ui.RdpLink.Add_Click({ if ($script:Run -and $script:Run.HostName) { Start-Process mstsc.exe -ArgumentList "/v:$($script:Run.HostName)" } })

# 一覧の行の ×
$ui.FileList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($sender, $e)
    $button = $e.OriginalSource
    if ($button -is [System.Windows.Controls.Button] -and $button.Tag -eq 'remove') {
        Remove-FtItems @($button.DataContext)
        $e.Handled = $true
    }
})
$ui.FileList.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Delete -and $ui.FileList.SelectedItems.Count -gt 0) {
        Remove-FtItems @($ui.FileList.SelectedItems)
        $e.Handled = $true
    }
})

$ui.DestBox.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler] {
    if (-not $script:Suppress) { Update-FtDestination }
})
$ui.DestBox.Add_DropDownClosed({ if (-not $script:Suppress) { Update-FtDestination -Immediate } })
$ui.FolderBox.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler] {
    if (-not $script:Suppress) { Update-FtFolder }
})

# ドラッグ＆ドロップ（ウィンドウのどこに落としてもよい）
$dragHandler = {
    param($sender, $e)
    $hasFiles = $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)
    $e.Effects = if ($hasFiles -and $script:Phase -ne 'running') { [System.Windows.DragDropEffects]::Copy } else { [System.Windows.DragDropEffects]::None }
    $e.Handled = $true
}
$window.Add_PreviewDragEnter($dragHandler)
$window.Add_PreviewDragOver($dragHandler)
$window.Add_PreviewDrop({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        Add-FtPaths @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
        $e.Handled = $true
    }
})

# Ctrl+V（エクスプローラーでコピーしたファイル）、Ctrl+Enter（転送開始）
$window.Add_PreviewKeyDown({
    param($sender, $e)
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if (-not $ctrl) { return }
    if ($e.Key -eq [System.Windows.Input.Key]::V -and [System.Windows.Clipboard]::ContainsFileDropList()) {
        Add-FtPaths @([System.Windows.Clipboard]::GetFileDropList())
        $e.Handled = $true
    } elseif ($e.Key -eq [System.Windows.Input.Key]::Return) {
        Start-FtTransfer
        $e.Handled = $true
    }
})

$window.Add_SourceInitialized({
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    [FileTransfer.Native]::RemoveMaximizeBox($handle)
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:Phase -eq 'running') {
        $answer = [System.Windows.MessageBox]::Show($window, '転送中です。中止して閉じますか？', 'FileTransfer', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        Stop-FtTransfer
    }
    if ($window.WindowState -eq 'Normal') {
        $script:Config.window = @{ left = [int]$window.Left; top = [int]$window.Top; height = [int]$window.Height }
    }
    $script:Config.last = @{ destination = (Get-FtDestText); folder = (Get-FtFolderText) }
    Save-FtSettings
})

$window.Add_Closed({
    $script:Timer.Stop()
    foreach ($root in $script:Connections) { Disconnect-FtShare $root }
})

# 想定外の例外はログに残して知らせる（アプリは落とさない）
$script:App.Add_DispatcherUnhandledException({
    param($sender, $e)
    Write-FtLog "予期しないエラー: $($e.Exception)"
    [System.Windows.MessageBox]::Show("予期しないエラーが発生しました。`n$($e.Exception.Message)", 'FileTransfer', 'OK', 'Error') | Out-Null
    $e.Handled = $true
})

#endregion

#region 起動 --------------------------------------------------------------------

function Initialize-FtWindow {
    $saved = $script:Config.window
    if ($saved -and $saved.ContainsKey('left') -and $saved.ContainsKey('top')) {
        $left = [double]$saved.left
        $top = [double]$saved.top
        $height = if ($saved.ContainsKey('height')) { [double]$saved.height } else { $window.Height }
        $screenRight = [System.Windows.SystemParameters]::VirtualScreenLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
        $screenBottom = [System.Windows.SystemParameters]::VirtualScreenTop + [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($left -ge [System.Windows.SystemParameters]::VirtualScreenLeft -and $left + 100 -le $screenRight -and
            $top -ge [System.Windows.SystemParameters]::VirtualScreenTop -and $top + 100 -le $screenBottom) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = $left
            $window.Top = $top
            $window.Height = [Math]::Max($window.MinHeight, $height)
        }
    }

    $last = $script:Config.last
    $destination = "$($last.destination)"
    if (-not $destination) { $destination = "$(@($script:Config.history.destinations)[0])" }
    $script:DestKind = if (Test-FtLocalDestination $destination) { 'local' } else { 'server' }
    if ($last.folder) { $script:LastFolder[$script:DestKind] = "$($last.folder)" }

    Update-FtDestItems
    Update-FtFolderItems
    Set-FtComboText $ui.DestBox $destination
    Set-FtComboText $ui.FolderBox $script:LastFolder[$script:DestKind]
    Request-FtHostCheck -Immediate
    $script:Timer.Start()
}

Initialize-FtWindow

if (-not $NoShow) {
    [void]$window.ShowDialog()
}

#endregion
