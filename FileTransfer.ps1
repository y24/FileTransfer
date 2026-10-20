#Requires -Version 5.1
<#
.SYNOPSIS
    FileTransfer - 共有フォルダ・この PC・サーバーの間でファイルを転送する

.DESCRIPTION
    送るファイルを選び、送り先（「このPC」またはサーバーのホスト名。カンマ区切りで複数可）とフォルダを指定して転送する。
    転送は robocopy で行い、サーバーへは管理共有（\\HOST\C$ など）に SMB で直接書き込む。
    引数なしで起動すると画面を表示し、-Destination などを指定するとコマンドラインで転送する。
    設計: docs\design.md

.PARAMETER Destination
    （コマンドライン）送り先。ホスト名（カンマ区切りで複数可）または このPC

.PARAMETER Folder
    （コマンドライン）送り先のフォルダ。サーバーなら C:\work\{datetime} のようにサーバー上のパスで書く

.PARAMETER Source
    （コマンドライン）送るファイル・フォルダ。* ? も使える。-Source を書かずに末尾に並べてもよい

.PARAMETER Credential
    （コマンドライン）ログオンが必要なサーバーに、このアカウントで接続する

.PARAMETER SaveCredential
    （コマンドライン）-Credential のアカウントを Windows 資格情報マネージャーに保存する

.PARAMETER KeepLocalCopy
    （コマンドライン）共有のファイルを、この PC にもコピーして残す

.PARAMETER SkipSpaceCheck
    （コマンドライン）送り先の空き容量が足りなくても転送する

.PARAMETER DisconnectExisting
    （コマンドライン）サーバーに別のユーザーで接続中（エラー 1219）なら、その接続を切断してからログオンし直す

.PARAMETER Method
    （コマンドライン）サーバーへの転送方法。SMB（ファイル共有）または WinRM（PowerShell リモート）。省略すると設定画面で選んだ方法

.PARAMETER NoShow
    画面を表示せずに初期化だけ行う（tests\ から読み込むため）

.EXAMPLE
    FileTransfer.ps1 -Destination SV-APP01,SV-APP02 -Folder 'C:\work\{datetime}' \\fs01\patches\2026-10\*.msu

.EXAMPLE
    FileTransfer.ps1 -Destination このPC -Folder 'D:\Transfer\{date}' \\fs01\release\app\setup.exe -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Cli')][Alias('To')][string]$Destination,
    [Parameter(ParameterSetName = 'Cli')][string]$Folder,
    [Parameter(ParameterSetName = 'Cli', Position = 0, ValueFromRemainingArguments)][string[]]$Source,
    [Parameter(ParameterSetName = 'Cli')][System.Management.Automation.Credential()][pscredential]$Credential,
    [Parameter(ParameterSetName = 'Cli')][switch]$SaveCredential,
    [Parameter(ParameterSetName = 'Cli')][switch]$KeepLocalCopy,
    [Parameter(ParameterSetName = 'Cli')][switch]$SkipSpaceCheck,
    [Parameter(ParameterSetName = 'Cli')][switch]$DisconnectExisting,
    [Parameter(ParameterSetName = 'Cli')][ValidateSet('SMB', 'WinRM')][string]$Method,
    [Parameter(ParameterSetName = 'Gui')][switch]$NoShow
)

$ErrorActionPreference = 'Stop'
$script:AppRoot = $PSScriptRoot
$script:IsCli = $PSCmdlet.ParameterSetName -eq 'Cli'
# -WhatIf は「計画を表示するだけ」として扱い、ほかのコマンドには効かせない
$script:PlanOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false

# 起動に失敗したらログに残して知らせる（画面表示後の例外は DispatcherUnhandledException で扱う）
trap {
    $logDir = Join-Path $env:LOCALAPPDATA 'FileTransfer\logs'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $entry = "[{0}] {1}`r`n{2}`r`n" -f (Get-Date), $_, $_.ScriptStackTrace
        [System.IO.File]::AppendAllText((Join-Path $logDir 'startup-error.log'), $entry, [System.Text.Encoding]::UTF8)
    } catch { }
    if ($NoShow) { break }
    if ($script:IsCli) { Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
    try { [System.Windows.MessageBox]::Show("FileTransfer を起動できませんでした。`n$($_.Exception.Message)", 'FileTransfer', 'OK', 'Error') | Out-Null } catch { }
    exit 1
}

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

Import-FtTypes
$script:ModulePaths = @('Config', 'PathResolver', 'Connection', 'TransferEngine', 'WinRm', 'Distribution', 'Log', 'Cli', 'Update') |
    ForEach-Object { Join-Path $script:AppRoot "lib\$_.psm1" }
foreach ($modulePath in $script:ModulePaths) { Import-Module $modulePath -Force -DisableNameChecking }

$script:Config = Get-FtConfig -AppRoot $script:AppRoot
Remove-FtOldLogs -RetentionDays ([int]$script:Config.log.retentionDays)

# コマンドライン
if ($script:IsCli) {
    $code = Invoke-FtCli -Source $Source -Destination $Destination -Folder $Folder -Credential $Credential `
        -SaveCredential:$SaveCredential -KeepLocalCopy:$KeepLocalCopy -PlanOnly:$script:PlanOnly `
        -SkipSpaceCheck:$SkipSpaceCheck -DisconnectExisting:$DisconnectExisting -Method $Method `
        -Config $script:Config -ModulePaths $script:ModulePaths
    exit $code
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

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
# タイムアウトした接続も終わるまで Runspace を使い続けるので、少し多めにしておく
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 16, $sessionState, $Host)
$script:Pool.Open()

#endregion

#region 状態 --------------------------------------------------------------------

$script:Items = New-Object 'System.Collections.ObjectModel.ObservableCollection[FileTransfer.FileItem]'
$script:Phase = 'idle'                  # idle | running | done | error
$script:Checks = @{}                    # ホスト名 → @{ Status; Code; User; Root }（Status: checking|ok|auth|conflict|unreachable|noshare|error）
$script:CheckSeq = 0
$script:DestKind = 'server'             # server | local
$script:LastFolder = @{
    server = @($script:Config.history.serverFolders)[0]
    local  = @($script:Config.history.localFolders)[0]
}
$script:HostAlias = @{}                 # ホスト名 → 実際に接続した名前（FQDN など）
$script:SessionUsers = @{}              # ホスト名 → このセッションでログオンしたユーザー
$script:SessionCreds = @{}              # ホスト名 → このセッションでログオンした資格情報（WinRM 用。SMB は Windows が接続を覚えている）
$script:Connections = New-Object System.Collections.Generic.List[string]
$script:Run = $null
$script:RunLog = New-Object System.Collections.Generic.List[string]
$script:LastError = $null
$script:LogonTarget = $null             # 結果の行の［ログオン…］で開くサーバー
$script:DisconnectTargets = @()         # 結果の行の［切断して再試行］で切断するサーバー
$script:RetryAfterCheck = $false        # 切断のあと、接続確認が終わったら送り直す
$script:NoticeUntil = [datetime]::MinValue
$script:PendingSizes = 0
$script:Suppress = $false
$script:Jobs = New-Object System.Collections.ArrayList

#endregion

#region 画面 --------------------------------------------------------------------

$window = Read-FtXaml 'MainWindow.xaml'
$ui = Get-FtNamedElements $window @(
    'CountText', 'ClearButton', 'AddFolderButton', 'AddButton', 'FileList', 'EmptyHint',
    'MethodBadge', 'MethodText', 'SettingsButton',
    'DestBox', 'DestBadge', 'DestDot', 'DestPcIcon', 'FolderBox', 'HintText',
    'ResultPanel', 'ResultIcon', 'ResultText', 'OpenLink', 'RdpLink', 'DisconnectLink', 'LogonLink', 'DetailLink',
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
# TimeoutMs を付けると、その時間で待つのをやめて OnComplete に TimeoutException を渡す
#   接続（WNetAddConnection2、WinRM）は途中で止められないので、処理自体はそのまま裏で終わるのを待つ
#   遅れて終わったら OnLate（param($value, $context)）を呼ぶ（張れてしまった接続の後始末など）
function Start-FtJob {
    param([string]$Script, [hashtable]$Parameters = @{}, [scriptblock]$OnComplete, $Context = $null, [int]$TimeoutMs = 0, [scriptblock]$OnLate)
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($Script)
    foreach ($key in $Parameters.Keys) { [void]$ps.AddParameter($key, $Parameters[$key]) }
    $handle = $ps.BeginInvoke()
    $deadline = if ($TimeoutMs -gt 0) { (Get-Date).AddMilliseconds($TimeoutMs) } else { [datetime]::MaxValue }
    [void]$script:Jobs.Add(@{ PowerShell = $ps; Handle = $handle; OnComplete = $OnComplete; Context = $Context; Deadline = $deadline; OnLate = $OnLate; TimedOut = $false })
}

function Update-FtJobs {
    # OnComplete の中でダイアログを出すと、その間もタイマーからここが呼ばれるので、終わったものを先に一覧から外しておく
    $completed = @($script:Jobs | Where-Object { $_.Handle.IsCompleted })
    foreach ($job in $completed) { $script:Jobs.Remove($job) }
    $now = Get-Date
    $expired = @($script:Jobs | Where-Object { -not $_.TimedOut -and $now -gt $_.Deadline })
    foreach ($job in $expired) { $job.TimedOut = $true }
    foreach ($job in $completed) {
        $value = $null
        $err = $null
        try {
            $output = $job.PowerShell.EndInvoke($job.Handle)
            if ($output.Count -gt 0) { $value = $output[$output.Count - 1] }
        } catch {
            $err = $_.Exception
        }
        $job.PowerShell.Dispose()
        if ($job.TimedOut) {
            if ($job.OnLate -and -not $err) { & $job.OnLate $value $job.Context }
        } elseif ($job.OnComplete) {
            & $job.OnComplete $value $err $job.Context
        }
    }
    foreach ($job in $expired) {
        if ($job.OnComplete) { & $job.OnComplete $null (New-Object System.TimeoutException 'サーバーから応答がありません') $job.Context }
    }
}

#endregion

#region 送り先 ------------------------------------------------------------------

function Get-FtDestText { "$($ui.DestBox.Text)".Trim() }
function Get-FtFolderText { "$($ui.FolderBox.Text)".Trim() }
# サーバーへの転送方法（smb | winrm。設定画面で切り替える）
function Get-FtMethod { Get-FtTransferMethod $script:Config }
function Get-FtDestKey { (Format-FtDestinations (Split-FtDestinations (Get-FtDestText))) + '|' + (Get-FtFolderText) + '|' + (Get-FtMethod) }

function Resolve-FtCurrent {
    param([datetime]$Now = (Get-Date))
    return Resolve-FtDestinations -Destination (Get-FtDestText) -Folder (Get-FtFolderText) -Now $Now `
        -Mappings @($script:Config.serverShareMappings) -HostAlias $script:HostAlias -Method (Get-FtMethod)
}

# 接続確認の対象（@{ HostName; Root }）。フォルダ欄が正しくないときも、ホストの確認はしておく
# Root は SMB なら確認する共有（\\HOST\C$）。WinRM はフォルダによらないので winrm:HOST
function Get-FtCheckTargets {
    param($Resolved = (Resolve-FtCurrent))
    if ($Resolved.IsLocal) { return @() }
    $winrm = (Get-FtMethod) -eq 'winrm'
    if (-not $Resolved.Error -and $Resolved.Targets.Count -gt 0) {
        return @($Resolved.Targets | ForEach-Object { @{ HostName = $_.HostName; Root = $(if ($winrm) { "winrm:$($_.HostName)" } else { $_.ShareRoot }) } })
    }
    $list = @()
    foreach ($name in $Resolved.Names) {
        $hostName = $name.ToUpperInvariant()
        if (-not (Test-FtHostName $hostName)) { continue }
        $connectName = if ($script:HostAlias.ContainsKey($hostName)) { $script:HostAlias[$hostName] } else { $hostName }
        $root = if ($winrm) { "winrm:$hostName" } else { "\\$connectName\C`$" }
        $list += @{ HostName = $hostName; Root = $root }
    }
    return $list
}

function Get-FtCheck {
    param([string]$HostName)
    $check = $script:Checks[$HostName]
    if ($check) { return $check }
    return @{ Status = 'checking'; Code = 0; User = ''; Root = ''; Message = '' }
}

# WinRM で使う資格情報: このセッションでログオンしたもの > 保存済みのもの > なし（Windows のログオンユーザーで接続）
function Get-FtWinRmCredential {
    param([string]$HostName)
    if ($script:SessionCreds.ContainsKey($HostName)) { return $script:SessionCreds[$HostName] }
    return Get-FtWinRmSavedCredential $HostName
}

# 状態ごとのホスト名
function Get-FtCheckGroups {
    param([object[]]$Targets)
    $groups = @{ ok = @(); auth = @(); conflict = @(); checking = @(); unreachable = @(); noshare = @(); error = @() }
    foreach ($target in $Targets) {
        $status = (Get-FtCheck $target.HostName).Status
        if (-not $groups.ContainsKey($status)) { $status = 'error' }
        $groups[$status] += $target.HostName
    }
    return $groups
}

# 「SV-APP01」「SV-APP01 ほか 2 台」
function Join-FtHostNames {
    param([string[]]$Names)
    if ($Names.Count -le 1) { return "$($Names[0])" }
    return "$($Names[0]) ほか $($Names.Count - 1) 台"
}

function Get-FtStatusText {
    param([hashtable]$Check)
    switch ($Check.Status) {
        'ok'          { "接続OK：$($Check.User)" }
        'auth'        { 'ログオンが必要です' }
        'conflict'    { '別のユーザーで接続中です' }
        'checking'    { '確認中…' }
        'unreachable' { '接続できません' }
        'noshare'     { '共有が見つかりません' }
        default       { if ($Check.Message) { "確認でエラーが発生しました（$($Check.Message)）" } else { "確認でエラーが発生しました（エラー $($Check.Code)）" } }
    }
}

# 接続に使われるユーザー: このセッションでログオンした人 > 保存済みの資格情報 > Windows のログオンユーザー
function Get-FtHostUser {
    param([string]$HostName)
    if ($script:SessionUsers.ContainsKey($HostName)) { return $script:SessionUsers[$HostName] }
    $saved = if ((Get-FtMethod) -eq 'winrm') { Get-FtWinRmSavedUser $HostName } else { Get-FtSavedUser $HostName }
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

function Get-FtDestKind {
    $names = Split-FtDestinations (Get-FtDestText)
    if ($names.Count -gt 0 -and @($names | Where-Object { -not (Test-FtLocalDestination $_) }).Count -eq 0) { return 'local' }
    return 'server'
}

# 送り先の種類（このPC / サーバー）が変わったら、フォルダ欄をその種類で前回使った値に戻す
function Update-FtDestKind {
    $kind = Get-FtDestKind
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
    $script:CheckSeq++
    $targets = Get-FtCheckTargets
    $script:Checks = @{}
    foreach ($target in $targets) { $script:Checks[$target.HostName] = @{ Status = 'checking'; Code = 0; User = ''; Root = $target.Root; Message = '' } }
    if ($targets.Count -gt 0) {
        if ($Immediate) { Invoke-FtHostCheck } else { $script:CheckTimer.Start() }
    }
    Update-FtView
}

# サーバーごとに並列で確認する
#   SMB: 445 番ポートと共有（\\HOST\C$）にアクセスできるか
#   WinRM: PowerShell リモートで接続できるか（保存済みの資格情報があれば、そのアカウントで）
function Invoke-FtHostCheck {
    $targets = Get-FtCheckTargets
    $seq = ++$script:CheckSeq
    $script:Checks = @{}
    $winrm = (Get-FtMethod) -eq 'winrm'
    foreach ($target in $targets) {
        $script:Checks[$target.HostName] = @{ Status = 'checking'; Code = 0; User = ''; Root = $target.Root; Message = '' }
        if ($winrm) {
            $jobScript = 'param($HostName, $Credential, $WinRm) Test-FtWinRmAccess -HostName $HostName -Credential $Credential -WinRm $WinRm'
            $parameters = @{ HostName = $target.HostName; Credential = (Get-FtWinRmCredential $target.HostName); WinRm = (Get-FtWinRmOptions $script:Config) }
        } else {
            $jobScript = 'param($ShareRoot) Test-FtShareAccess -ShareRoot $ShareRoot'
            $parameters = @{ ShareRoot = $target.Root }
        }
        Start-FtJob -Script $jobScript -Parameters $parameters -Context @{ Seq = $seq; HostName = $target.HostName } -TimeoutMs 45000 -OnComplete {
                param($value, $err, $context)
                if ($context.Seq -ne $script:CheckSeq) { return }
                $check = $script:Checks[$context.HostName]
                if (-not $check) { return }
                if ($err -or $null -eq $value) {
                    $check.Status = 'error'
                    $check.Code = 0
                    $check.Message = if ($err) { $err.Message } else { '' }
                } else {
                    $check.Status = $value.Status
                    $check.Code = $value.Code
                    $check.Message = "$($value.Message)"
                }
                # WinRM はサーバーが答えたユーザー（ドメイン\名前）を出す
                $check.User = if ($value -and $value.User) { "$($value.User)" } else { Get-FtHostUser $context.HostName }
                Update-FtView
                # ［切断して再試行］のあと、全台の確認が終わったら送り直す
                if ($script:RetryAfterCheck -and @($script:Checks.Values | Where-Object { $_.Status -eq 'checking' }).Count -eq 0) {
                    $script:RetryAfterCheck = $false
                    if ($script:Phase -eq 'error') { Start-FtTransfer }
                }
            }
    }
    Update-FtView
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
    $changed = $false
    foreach ($target in (Get-FtCheckTargets)) {
        $check = $script:Checks[$target.HostName]
        if (-not $check -or $check.Root -ine $target.Root) { $changed = $true }
    }
    if ($changed) { Request-FtHostCheck } else { Update-FtView }
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
    if ($added -gt 0) { Save-FtItems }
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
    Save-FtItems
    Update-FtView
}

# 送るファイルの一覧を設定に保存する（次に起動したときに復元する）
function Save-FtItems {
    if ($script:Config.last -isnot [hashtable]) { $script:Config.last = @{} }
    $script:Config.last.items = [string[]]@($script:Items | ForEach-Object { $_.Path })
    Save-FtSettings
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

# フォルダを選ぶ（複数可）。フォルダは中のファイルをサブフォルダごと、フォルダの構成のまま送る
function Show-FtFolderDialog {
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    $folders = @([FileTransfer.Native]::PickFolders($handle, '送るフォルダを選択（中のファイルをフォルダごと送ります）', "$($script:Config.history.lastOpenDir)"))
    if ($folders.Count -eq 0) { return }
    # 次に開くときは、選んだフォルダがあるフォルダから
    $parent = [System.IO.Path]::GetDirectoryName($folders[0].TrimEnd('\'))
    $script:Config.history.lastOpenDir = if ($parent) { $parent } else { $folders[0] }
    Save-FtSettings
    Add-FtPaths $folders
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
    if ($resolved.Error -or $resolved.Targets.Count -eq 0) { return $false }
    if ($resolved.IsLocal) { return $true }
    foreach ($target in $resolved.Targets) {
        if ((Get-FtCheck $target.HostName).Status -notin 'ok', 'auth', 'conflict', 'error') { return $false }
    }
    return $true
}

function Set-FtHint {
    param([string]$Kind, [string]$Text, [switch]$WithLogon, [switch]$WithSmbScript, [string[]]$DisconnectHosts = @(), [int]$More = 0, [string]$ToolTip = '', [string]$Note = '')
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
        if ($More -gt 0) { $hint.Inlines.Add((New-Object System.Windows.Documents.Run "  ほか $More 台")) }
        if ($Note) { $hint.Inlines.Add((New-Object System.Windows.Documents.Run "  $Note")) }
        $hint.ToolTip = if ($ToolTip) { $ToolTip } else { $Text }
        return
    }
    $hint.Foreground = switch ($Kind) { 'warn' { Get-FtBrush 'WarnBrush' } 'error' { Get-FtBrush 'ErrorBrush' } default { Get-FtBrush 'MutedBrush' } }
    $hint.Inlines.Add((New-Object System.Windows.Documents.Run $Text))
    if ($ToolTip) { $hint.ToolTip = $ToolTip }
    if ($DisconnectHosts.Count -gt 0) {
        $hint.Inlines.Add((New-Object System.Windows.Documents.Run '  '))
        $link = New-Object System.Windows.Documents.Hyperlink (New-Object System.Windows.Documents.Run '切断して再試行')
        $link.Foreground = Get-FtBrush 'AccentBrush'
        $link.Tag = [string[]]$DisconnectHosts
        $link.ToolTip = 'この PC からそのサーバーへの接続（ネットワーク ドライブなど）を切断して、接続し直す'
        $link.Add_Click({ param($sender, $e) Request-FtDisconnect $sender.Tag })
        $hint.Inlines.Add($link)
    }
    if ($WithLogon) {
        $hint.Inlines.Add((New-Object System.Windows.Documents.Run '  '))
        $link = New-Object System.Windows.Documents.Hyperlink (New-Object System.Windows.Documents.Run 'ログオン…')
        $link.Foreground = Get-FtBrush 'AccentBrush'
        $link.Add_Click({ Request-FtLogon })
        $hint.Inlines.Add($link)
    }
    if ($WithSmbScript) {
        $hint.Inlines.Add((New-Object System.Windows.Documents.Run '  '))
        $link = New-Object System.Windows.Documents.Hyperlink (New-Object System.Windows.Documents.Run '有効化スクリプトをコピー')
        $link.Foreground = Get-FtBrush 'AccentBrush'
        $link.ToolTip = "サーバーで SMB（ファイル共有）を有効にするスクリプト（EnableSMB.bat）をクリップボードにコピーします。`nサーバーに RDP で接続してデスクトップなどに Ctrl+V で貼り付け、ダブルクリックで実行してください（管理者権限で実行されます）"
        $link.Add_Click({ Copy-FtSmbScript })
        $hint.Inlines.Add($link)
    }
}

# ［有効化スクリプトをコピー］: tools\EnableSMB.bat をファイルとしてクリップボードに置く（RDP 先で Ctrl+V で貼り付けられる）
function Copy-FtSmbScript {
    $path = Join-Path $script:AppRoot 'tools\EnableSMB.bat'
    if (-not (Test-Path -LiteralPath $path)) {
        Show-FtNotice "スクリプトが見つかりません：$path" 'error'
        return
    }
    $files = New-Object System.Collections.Specialized.StringCollection
    [void]$files.Add($path)
    # ほかのアプリがクリップボードを開いていると失敗することがあるので、少し待って何回か試す
    for ($i = 0; $i -lt 5; $i++) {
        try {
            [System.Windows.Clipboard]::SetFileDropList($files)
            Write-FtLog "クリップボードにコピーしました: $path"
            Show-FtNotice 'コピーしました。RDP 先で貼り付けて実行してください' 'ok'
            return
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    Show-FtNotice 'クリップボードにコピーできませんでした。もう一度お試しください' 'error'
}

function Update-FtHint {
    param($Resolved, [object[]]$Targets)
    if (-not $Resolved.IsLocal -and $Resolved.Names.Count -eq 0) { Set-FtHint 'muted' 'ホスト名を入力するか、▾ から選んでください'; return }
    if ($Resolved.Error) { Set-FtHint 'error' $Resolved.Error; return }
    $winrm = -not $Resolved.IsLocal -and (Get-FtMethod) -eq 'winrm'
    if (-not $Resolved.IsLocal) {
        $groups = Get-FtCheckGroups $Targets
        $statusLines = ($Targets | ForEach-Object { "$($_.HostName): $(Get-FtStatusText (Get-FtCheck $_.HostName))" }) -join "`n"
        if ($groups.checking.Count) { Set-FtHint 'muted' '接続を確認しています…'; return }
        if ($groups.unreachable.Count) {
            $port = Get-FtWinRmPort (Get-FtWinRmOptions $script:Config)
            if ($winrm) {
                Set-FtHint 'error' "$(Join-FtHostNames $groups.unreachable) に接続できません（ホスト名と、サーバーで WinRM（$port 番ポート）が有効か確認してください）" -ToolTip $statusLines
            } else {
                # ホスト名が正しければ、サーバーで SMB が有効になっていないことが多いので、有効化スクリプトを渡せるようにする
                Set-FtHint 'error' "$(Join-FtHostNames $groups.unreachable) に接続できません" -WithSmbScript -ToolTip $statusLines
            }
            return
        }
        if ($groups.noshare.Count) {
            $first = $groups.noshare[0]
            $text = if ($Targets.Count -eq 1) { "$((Get-FtCheck $first).Root) が見つかりません（管理共有が無効の可能性があります）" } else { "$(Join-FtHostNames $groups.noshare) の共有が見つかりません（管理共有が無効の可能性があります）" }
            Set-FtHint 'error' $text -WithSmbScript -ToolTip $statusLines
            return
        }
        $needLogon = @($groups.auth) + @($groups.conflict)
        if ($needLogon.Count) {
            $text = if ($needLogon.Count -eq 1 -and $groups.conflict.Count -eq 1) { "$($needLogon[0]) には別のユーザーで接続中です" } else { "$(Join-FtHostNames $needLogon) へのログオンが必要です" }
            Set-FtHint 'warn' $text -WithLogon -DisconnectHosts @($groups.conflict) -ToolTip $statusLines
            return
        }
        if ($groups.error.Count) {
            # WinRM は理由（TrustedHosts に登録されていない など）がわかるので、それを出す
            $message = (Get-FtCheck $groups.error[0]).Message
            $text = if ($message) { "$(Join-FtHostNames $groups.error)：$message" } else { "$(Join-FtHostNames $groups.error) の確認でエラーが発生しました" }
            Set-FtHint 'warn' $text -ToolTip $statusLines
            return
        }
    }
    if ($winrm) {
        # WinRM ではサーバー上のパスのまま送る（ツールチップは「ホスト名: パス」）
        $paths = @($Resolved.Targets | ForEach-Object { "$($_.HostName): $($_.Path)" })
        Set-FtHint 'path' $Resolved.Targets[0].Path -More ($paths.Count - 1) -Note '（WinRM）' -ToolTip ($paths -join "`n")
        return
    }
    $paths = @($Resolved.Targets | ForEach-Object { $_.Path })
    Set-FtHint 'path' $paths[0] -More ($paths.Count - 1) -ToolTip ($paths -join "`n")
}

function Update-FtBadge {
    param($Resolved, [object[]]$Targets)
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
    $badge.IsEnabled = ($script:Phase -ne 'running') -and $Targets.Count -gt 0
    if ($Targets.Count -eq 0) {
        $dot.Fill = $null
        $dot.Stroke = Get-FtBrush 'FaintBrush'
        $badge.ToolTip = $null
        return
    }
    $groups = Get-FtCheckGroups $Targets
    $dot.Fill = if ($groups.unreachable.Count -or $groups.noshare.Count -or $groups.error.Count) { Get-FtBrush 'ErrorBrush' }
                elseif ($groups.checking.Count) { Get-FtBrush 'IdleDotBrush' }
                elseif ($groups.auth.Count -or $groups.conflict.Count) { Get-FtBrush 'WarnDotBrush' }
                else { Get-FtBrush 'OkDotBrush' }
    if ($Targets.Count -eq 1) {
        $check = Get-FtCheck $Targets[0].HostName
        $badge.ToolTip = switch ($check.Status) {
            'ok'       { "$(Get-FtStatusText $check)（クリックでアカウントを変更）" }
            'auth'     { 'ログオンが必要です（クリックしてログオン）' }
            'conflict' { '別のユーザーで接続中です（クリックしてログオン）' }
            default    { Get-FtStatusText $check }
        }
    } else {
        $badge.ToolTip = (@($Targets | ForEach-Object { "$($_.HostName): $(Get-FtStatusText (Get-FtCheck $_.HostName))" }) + '（クリックでアカウントを変更）') -join "`n"
    }
}

function Update-FtView {
    $running = $script:Phase -eq 'running'
    $count = $script:Items.Count
    $ui.CountText.Text = if ($count -eq 0) { '' } elseif ($script:PendingSizes -gt 0) { "$count 件・計算中…" } else { "$count 件・" + [FileTransfer.FileItem]::FormatSize((Get-FtTotalBytes)) }
    $ui.ClearButton.Visibility = if ($count -gt 0 -and -not $running) { 'Visible' } else { 'Collapsed' }
    $ui.EmptyHint.Visibility = if ($count -eq 0) { 'Visible' } else { 'Collapsed' }
    $ui.FileList.Tag = if ($running) { 'locked' } else { $null }
    $ui.AddButton.IsEnabled = -not $running
    $ui.AddFolderButton.IsEnabled = -not $running
    $ui.SettingsButton.IsEnabled = -not $running
    $ui.DestBox.IsEnabled = -not $running
    $ui.FolderBox.IsEnabled = -not $running
    # 既定（SMB）以外の方法で送るときは、送り先の見出しの右に出しておく
    if ((Get-FtMethod) -eq 'winrm') {
        $ui.MethodBadge.Visibility = 'Visible'
        $ui.MethodBadge.ToolTip = 'サーバーへは WinRM（PowerShell リモート）で送ります。右の歯車の設定で変えられます'
    } else {
        $ui.MethodBadge.Visibility = 'Collapsed'
    }

    $resolved = Resolve-FtCurrent
    $targets = Get-FtCheckTargets $resolved
    Update-FtBadge $resolved $targets
    Update-FtHint $resolved $targets
    $folderInvalid = $resolved.Error -and (Get-FtFolderText) -and ($resolved.IsLocal -or $targets.Count -gt 0) -and $resolved.Error -notlike 'ホスト名*' -and $resolved.Error -notlike '「このPC」*'
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
    $ui.DisconnectLink.Visibility = if ($Links -contains 'Disconnect') { 'Visible' } else { 'Collapsed' }
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

# 一時フォルダに取得したもの（複数台に配るとき）を消す
function Clear-FtRunStage {
    if ($script:Run -and $script:Run.Stage -and $script:Run.Stage.Temporary) { Remove-FtStageFolder $script:Run.Stage.Folder }
}

# 完了・エラーの表示中に、送るファイルや送り先が変わったら元に戻す
function Exit-FtFinished {
    $script:RetryAfterCheck = $false
    if ($script:Phase -ne 'done' -and $script:Phase -ne 'error') { return }
    if ($script:Phase -eq 'error') { Clear-FtRunStage }
    $script:Phase = 'idle'
    foreach ($item in $script:Items) { $item.State = ''; $item.Progress = 0 }
    Set-FtResult $null
}

# 複数のサーバーから 1 台を選ぶメニュー（Kind: logon | open | rdp）
function Show-FtHostMenu {
    param($Anchor, [string]$Kind)
    $menu = New-Object System.Windows.Controls.ContextMenu
    $entries = @()
    switch ($Kind) {
        'logon' {
            foreach ($target in (Get-FtCheckTargets)) {
                $entries += @{ Header = "$($target.HostName)（$(Get-FtStatusText (Get-FtCheck $target.HostName))）"; Tag = @{ Kind = 'logon'; HostName = $target.HostName } }
            }
        }
        default {
            foreach ($unit in @($script:Run.Dist.Hosts | Where-Object { $_.Status -eq 'success' })) {
                $header = if ($Kind -eq 'open') { "$($unit.Name)：$($unit.Dest)" } else { "$($unit.Name) に接続" }
                $entries += @{ Header = $header; Tag = @{ Kind = $Kind; HostName = $unit.HostName; Dest = $unit.Dest } }
            }
        }
    }
    foreach ($entry in $entries) {
        $menuItem = New-Object System.Windows.Controls.MenuItem
        $menuItem.Header = $entry.Header
        $menuItem.Tag = $entry.Tag
        $menuItem.Add_Click({ param($sender, $e) Invoke-FtHostAction $sender.Tag })
        [void]$menu.Items.Add($menuItem)
    }
    $menu.PlacementTarget = $Anchor
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = $true
}

function Invoke-FtHostAction {
    param([hashtable]$Action)
    switch ($Action.Kind) {
        'logon' { Request-FtLogon $Action.HostName }
        'open'  { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Action.Dest) }
        'rdp'   { Start-Process mstsc.exe -ArgumentList "/v:$($Action.HostName)" }
    }
}

# 結果の行の［開く］［RDP］: 1 か所ならそのまま、複数ならメニュー
function Invoke-FtResultLink {
    param($Anchor, [string]$Kind)
    if (-not $script:Run -or -not $script:Run.Dist) { return }
    $hosts = @($script:Run.Dist.Hosts | Where-Object { $_.Status -eq 'success' })
    if ($hosts.Count -eq 1) {
        Invoke-FtHostAction @{ Kind = $Kind; HostName = $hosts[0].HostName; Dest = $hosts[0].Dest }
    } elseif ($hosts.Count -gt 1) {
        Show-FtHostMenu $Anchor $Kind
    }
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

function Format-FtRemaining {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ('{0} 秒' -f [int][Math]::Max([double]1, [Math]::Ceiling($Seconds))) }
    return ('{0} 分 {1} 秒' -f [int][Math]::Floor($Seconds / 60), [int]($Seconds % 60))
}

function Save-FtSettings {
    try { Save-FtConfig $script:Config } catch { Write-FtLog "設定を保存できませんでした: $($_.Exception.Message)" }
}

function Save-FtHistory {
    $history = $script:Config.history
    $names = Split-FtDestinations (Get-FtDestText)
    $dest = Format-FtDestinations $names
    if ($script:DestKind -ne 'local') { $history.destinations = Add-FtHistory $history.destinations $dest }
    $key = if ($script:DestKind -eq 'local') { 'localFolders' } else { 'serverFolders' }
    $history[$key] = Add-FtHistory $history[$key] (Get-FtFolderText)
    $script:Config.last = @{ destination = $dest; folder = (Get-FtFolderText) }
    Save-FtSettings
    Update-FtDestItems
    Update-FtFolderItems
}

function Start-FtTransfer {
    if (-not (Test-FtCanStart)) { return }

    # ログオンが必要なサーバーがあれば、先にログオンしてもらう
    foreach ($target in (Get-FtCheckTargets)) {
        if ((Get-FtCheck $target.HostName).Status -in 'auth', 'conflict') {
            if (-not (Show-FtLogon -HostName $target.HostName)) { Update-FtView; return }
        }
    }

    # エラー後のやり直しは、{datetime} を展開し直さずに、失敗した送り先へだけ送る
    $retry = $script:Phase -eq 'error' -and $script:Run -and $script:Run.Key -eq (Get-FtDestKey) -and $script:Run.FailedNames.Count -gt 0
    $now = if ($retry) { $script:Run.Now } else { Get-Date }
    $resolved = Resolve-FtCurrent $now
    if ($resolved.Error) { Update-FtView; return }
    $method = if ($resolved.IsLocal) { 'local' } else { Get-FtMethod }
    $allTargets = @($resolved.Targets | ForEach-Object {
        @{
            Name = $(if ($_.IsLocal) { Get-FtLocalLabel } else { $_.HostName }); HostName = $_.HostName; IsLocal = $_.IsLocal; Dest = $_.Path
            Method = $method; Credential = $(if ($method -eq 'winrm') { Get-FtWinRmCredential $_.HostName } else { $null })
        }
    })
    $targets = if ($retry) { @($allTargets | Where-Object { $script:Run.FailedNames -contains $_.Name }) } else { $allTargets }
    if ($targets.Count -eq 0) { $targets = $allTargets; $retry = $false }

    # [Math]::Max(0, long) は Int32 版が選ばれて 2 GB を超えると失敗するので、long 同士で比べる
    $items = @($script:Items | ForEach-Object { @{ Path = $_.Path; IsFolder = $_.IsFolder; Size = [Math]::Max([long]0, [long]$_.Size) } })
    $transfer = $script:Config.transfer
    $stage = if ($retry) { $script:Run.Stage } else {
        Get-FtStageFolder -Items $items -TargetCount $allTargets.Count -IsLocal $resolved.IsLocal `
            -KeepLocalCopy ([bool]$transfer.keepLocalCopy) -LocalCopyFolder "$($transfer.localCopyFolder)" -Now $now
    }
    $options = @{
        RetryCount          = [int]$transfer.retryCount
        RetryWaitSec        = [int]$transfer.retryWaitSec
        Threads             = [int]$transfer.threadsForFolders
        LargeThresholdBytes = [long]$transfer.unbufferedThresholdMB * 1MB
        ParallelHosts       = [int]$transfer.parallelHosts
        WinRm               = Get-FtWinRmOptions $script:Config
    }
    $stageReused = $retry -and $stage -and (Test-Path -LiteralPath $stage.Folder)

    $script:Run = @{
        Dist            = $null              # 空き容量の確認が済んでから作る
        Pending         = @{ Items = $items; Targets = $targets; Stage = $stage; Retry = $retry; StageReused = $stageReused; Options = $options }
        CancelRequested = $false
        Now             = $now
        Key             = Get-FtDestKey
        Stage           = $stage
        IsLocal         = $resolved.IsLocal
        Method          = $method
        Started         = Get-Date
        Samples         = New-Object System.Collections.Generic.List[object]
        ItemCount       = $script:Items.Count
        Bytes           = Get-FtTotalBytes
        FailedNames     = @()
    }
    foreach ($item in $script:Items) { $item.State = ''; $item.Progress = 0 }
    $script:RunLog.Clear()
    $script:LastError = $null
    $script:LogonTarget = $null
    $script:DisconnectTargets = @()
    $script:NoticeUntil = [datetime]::MinValue

    $script:Phase = 'running'
    Set-FtResult $null
    $ui.CancelButton.IsEnabled = $true
    $ui.TotalProgress.Value = 0
    $ui.ProgressText.Text = '空き容量を確認しています…'
    Update-FtView

    # 送り先の空き容量を確かめてから転送する（サーバーに問い合わせるので、画面が固まらないように裏で行う）
    Start-FtJob -Script 'param($Items, $Targets, $StageFolder, $StageReused, $WinRm) Test-FtFreeSpace -Items $Items -Targets $Targets -StageFolder $StageFolder -StageReused:$StageReused -WinRm $WinRm' `
        -Parameters @{ Items = $items; Targets = $targets; StageFolder = $(if ($stage) { $stage.Folder } else { '' }); StageReused = $stageReused; WinRm = $options.WinRm } `
        -Context $script:Run -OnComplete {
            param($value, $err, $context)
            if (-not [object]::ReferenceEquals($context, $script:Run)) { return }
            Resume-FtTransfer -SpaceResults @($value) -SpaceError $err
        }
}

# 空き容量が足りないときに、このまま転送するか聞く（テストでは差し替える）
function Confirm-FtLowSpace {
    param([object[]]$Shortages)
    $lines = @($Shortages | ForEach-Object { Format-FtFreeSpace $_ })
    $message = "次の送り先の空き容量が足りません。`n`n" + ($lines -join "`n") + "`n`nこのまま転送しますか？"
    return ([System.Windows.MessageBox]::Show($window, $message, 'FileTransfer', 'YesNo', 'Warning') -eq 'Yes')
}

# 空き容量の確認が済んだら、転送を始める
function Resume-FtTransfer {
    param([object[]]$SpaceResults, $SpaceError)
    $run = $script:Run
    if ($run.CancelRequested) {
        $script:Phase = 'idle'
        Clear-FtRunStage
        Show-FtNotice '中止しました'
        Update-FtView
        return
    }
    if ($SpaceError) { Write-FtLog "空き容量を確認できませんでした: $($SpaceError.Message)" }
    foreach ($result in @($SpaceResults | Where-Object { $_ -and $_.Free -lt 0 })) { Write-FtLog "空き容量を確認できませんでした: $($result.Name) $($result.Path)" }
    $shortages = @($SpaceResults | Where-Object { $_ -and $_.Short })
    if ($shortages.Count -gt 0) {
        foreach ($shortage in $shortages) { Write-FtLog "空き容量不足: $(Format-FtFreeSpace $shortage)" }
        if (-not (Confirm-FtLowSpace $shortages)) {
            $script:Phase = 'idle'
            Clear-FtRunStage
            Show-FtNotice '空き容量が足りないため、転送をやめました' 'warn'
            Update-FtView
            return
        }
    }

    $pending = $run.Pending
    $stage = $pending.Stage
    $run.Dist = New-FtDistribution -Items $pending.Items -Targets $pending.Targets -StageFolder $(if ($stage) { $stage.Folder } else { '' }) `
        -ReuseStage:$pending.Retry -Options $pending.Options -Pool $script:Pool
    $run.Started = Get-Date
    $label = if ($pending.Retry) { '再送開始' } else { '転送開始' }
    Add-FtRunLog ("{0}: {1} 件（{2}）→ {3}" -f $label, $run.ItemCount, [FileTransfer.FileItem]::FormatSize($run.Bytes), (($pending.Targets | ForEach-Object { $_.Dest }) -join ', '))
    foreach ($item in $pending.Items) { Add-FtRunLog "  $($item.Path)" }
    foreach ($target in $pending.Targets) {
        if ($target.IsLocal) { continue }
        $via = if ($target.Method -eq 'winrm') { '（WinRM）' } else { '' }
        Add-FtRunLog "  $($target.Name) の接続ユーザー: $(Get-FtHostUser $target.HostName)$via"
    }
    if ($stage) {
        $note = if ($stage.Temporary) { '共有のファイルを一時フォルダに取得してから配ります' } else { 'この PC にもコピーを残します' }
        Add-FtRunLog "  $note`: $($stage.Folder)"
    }
    foreach ($shortage in $shortages) { Add-FtRunLog "  空き容量が足りないまま転送: $(Format-FtFreeSpace $shortage)" }
    Save-FtHistory

    $ui.ProgressText.Text = '接続しています…'
    Update-FtView
    Step-FtDistribution $run.Dist
}

# 転送中の進捗を画面に反映する（タイマーから呼ぶ）
function Update-FtRunProgress {
    if ($script:Phase -ne 'running' -or $null -eq $script:Run -or $null -eq $script:Run.Dist) { return }
    $distribution = $script:Run.Dist
    Step-FtDistribution $distribution
    foreach ($line in (Read-FtDistributionLog $distribution)) { Add-FtRunLog $line }

    $progress = Get-FtDistributionProgress $distribution
    foreach ($item in $script:Items) {
        $state = $progress.Items[$item.Path]
        if (-not $state) { continue }
        if ($item.State -ne $state.State) { $item.State = $state.State }
        $item.Progress = if ($state.State -eq 'cur') { $state.Fraction } else { 0 }
    }
    if ($distribution.Status -ne 'running') { Complete-FtTransfer; return }
    if ($distribution.Cancel) { return }

    $total = [long]$progress.BytesTotal
    $done = [long]$progress.BytesDone
    $ui.TotalProgress.Value = if ($total -gt 0) { [Math]::Min([double]1, [double]$done / $total) } else { 0 }

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
    $ui.ProgressText.Text = Format-FtProgressText -Done $done -Total $total -Speed $speed `
        -Staging $progress.Staging -HostsTotal $progress.HostsTotal -HostsSucceeded $progress.HostsSucceeded
}

# 「45%・1/3 台完了・98.2 MB/s・残り 6 秒」
function Format-FtProgressText {
    param([long]$Done, [long]$Total, [double]$Speed, [bool]$Staging = $false, [int]$HostsTotal = 1, [int]$HostsSucceeded = 0)
    $percent = [int][Math]::Floor(100.0 * $Done / [Math]::Max([long]1, $Total))
    $parts = @("$percent%")
    if ($Staging) { $parts += 'この PC へ取得中' }
    elseif ($HostsTotal -gt 1) { $parts += ('{0}/{1} 台完了' -f $HostsSucceeded, $HostsTotal) }
    $parts += ('{0}/s' -f [FileTransfer.FileItem]::FormatSize([long]$Speed))
    if ($Speed -gt 0) { $parts += '残り ' + (Format-FtRemaining (($Total - $Done) / $Speed)) }
    return $parts -join '・'
}

function Get-FtUnitErrorInfo {
    param([hashtable]$Unit, [bool]$IsStage)
    $result = $Unit.Result
    $target = if ($IsStage) { 'この PC' } elseif ($Unit.IsLocal) { '送り先' } else { $Unit.Name }
    $method = if ($IsStage -or -not $Unit.Method) { 'smb' } else { $Unit.Method }
    return Get-FtErrorInfo -Code ([int]$result.Code) -Target $target -Missing @($result.Missing) -Fallback "$($result.Message)" -Server:(-not $IsStage -and -not $Unit.IsLocal) -Method $method
}

function Complete-FtTransfer {
    $run = $script:Run
    $distribution = $run.Dist
    foreach ($line in (Read-FtDistributionLog $distribution)) { Add-FtRunLog $line }
    $summary = Get-FtDistributionSummary $distribution
    $hosts = $distribution.Hosts
    $elapsed = Format-FtDuration $summary.Elapsed

    switch ($summary.Status) {
        'success' {
            $script:Phase = 'done'
            foreach ($item in $script:Items) { $item.State = 'done'; $item.Progress = 0 }
            $text = if ($hosts.Count -gt 1) {
                '{0} 件を {1} 台に転送しました（{2}・{3}）' -f $run.ItemCount, $hosts.Count, [FileTransfer.FileItem]::FormatSize($run.Bytes), $elapsed
            } else {
                '{0} 件を転送しました（{1}・{2}）' -f $run.ItemCount, [FileTransfer.FileItem]::FormatSize($run.Bytes), $elapsed
            }
            Add-FtRunLog "完了: $text"
            # WinRM で送ったサーバーは、エクスプローラーで開けない（ファイル共有が使えない）ので［開く］を出さない
            $links = @()
            if ($run.Method -ne 'winrm') { $links += 'Open' }
            if (-not $run.IsLocal) { $links += 'Rdp' }
            Set-FtResult 'ok' $text $links
            Clear-FtRunStage
        }
        'canceled' {
            $script:Phase = 'idle'
            foreach ($item in $script:Items) { $item.State = ''; $item.Progress = 0 }
            Add-FtRunLog '中止しました'
            $script:LastError = @{ Detail = '転送を中止しました。送り先に、途中までコピーされたファイルが残っている可能性があります。' }
            Show-FtNotice '中止しました。送り先に途中までのファイルが残っている可能性があります' 'warn' @('Detail')
            Clear-FtRunStage
        }
        default {
            $script:Phase = 'error'
            foreach ($item in $script:Items) { if ($item.State -eq 'cur') { $item.State = ''; $item.Progress = 0 } }
            $first = @($summary.Failed)[0]
            $info = if ($first) { Get-FtUnitErrorInfo $first $summary.StageFailed } else { Get-FtErrorInfo -Code 0 }
            $succeeded = $summary.Succeeded.Count
            $failedHosts = @($hosts | Where-Object { $_.Status -ne 'success' })
            $short = if ($summary.StageFailed) { "この PC への取得に失敗しました：$($info.Short)" }
                     elseif ($hosts.Count -eq 1) { $info.Short }
                     elseif ($failedHosts.Count -eq 1) { if ($succeeded) { "$($info.Short)（ほか $succeeded 台は完了）" } else { $info.Short } }
                     elseif ($succeeded) { "$($failedHosts.Count) 台で失敗しました（$succeeded 台は完了）" }
                     else { "$($failedHosts.Count) 台とも失敗しました" }

            # ［詳細］: 送り先ごとの結果と、最初の失敗の説明
            $detail = $info.Detail
            if ($hosts.Count -gt 1 -or $distribution.Stage) {
                $lines = @()
                $units = @()
                if ($distribution.Stage -and -not $distribution.Stage.Reused) { $units += $distribution.Stage }
                $units += $hosts
                foreach ($unit in $units) {
                    $isStage = $unit -eq $distribution.Stage
                    $lines += switch ($unit.Status) {
                        'success'  { "$($unit.Name): 完了（$(Format-FtDuration $unit.Elapsed)）" }
                        'failed'   { "$($unit.Name): $((Get-FtUnitErrorInfo $unit $isStage).Short)" }
                        'skipped'  { "$($unit.Name): 取得に失敗したため送っていません" }
                        'canceled' { "$($unit.Name): 中止" }
                        default    { "$($unit.Name): 未実行" }
                    }
                }
                $detail = ($lines -join "`n") + "`n`n" + $info.Detail
            }
            $script:LastError = @{ Short = $short; Detail = $detail }
            $script:Run.FailedNames = @($failedHosts | ForEach-Object { $_.Name })

            # ［ログオン…］は、ログオンで直りそうな失敗をしたサーバーに出す
            # ［切断して再試行］は、別のユーザーで接続中（エラー 1219）で失敗したサーバーに出す
            $script:LogonTarget = $null
            $script:DisconnectTargets = @()
            foreach ($unit in $failedHosts) {
                if ($unit.Status -ne 'failed' -or $unit.IsLocal) { continue }
                $unitInfo = Get-FtUnitErrorInfo $unit $false
                if ($unitInfo.NeedsLogon -and -not $script:LogonTarget) { $script:LogonTarget = $unit.HostName }
                if ($unitInfo.NeedsDisconnect) { $script:DisconnectTargets += $unit.HostName }
            }
            Add-FtRunLog "エラー: $short"
            $links = @()
            if ($script:DisconnectTargets.Count -gt 0) { $links += 'Disconnect' }
            if ($script:LogonTarget) { $links += 'Logon' }
            $links += 'Detail'
            Set-FtResult 'error' $short $links
        }
    }
    Update-FtView
}

function Stop-FtTransfer {
    if ($script:Phase -ne 'running') { return }
    $ui.CancelButton.IsEnabled = $false
    $ui.ProgressText.Text = '中止しています…'
    if ($null -eq $script:Run.Dist) {
        # 空き容量の確認中: 確認が終わったところで止める
        $script:Run.CancelRequested = $true
        return
    }
    $script:Run.Dist.Cancel = $true
    Step-FtDistribution $script:Run.Dist
}

# ［切断して再試行］: そのサーバーへの接続を切断して、接続を確認し直す。エラーの表示中なら、確認が済んだら送り直す
function Request-FtDisconnect {
    param([string[]]$HostNames)
    $HostNames = @($HostNames | Where-Object { $_ })
    if ($HostNames.Count -eq 0 -or $script:Phase -eq 'running') { return }
    $retry = $script:Phase -eq 'error'
    $ui.DisconnectLink.IsEnabled = $false
    Start-FtJob -Script 'param($HostNames) , @(foreach ($name in $HostNames) { Disconnect-FtHostConnections -HostName $name })' `
        -Parameters @{ HostNames = [string[]]$HostNames } -Context @{ Retry = $retry; HostNames = $HostNames } -OnComplete {
            param($value, $err, $context)
            $ui.DisconnectLink.IsEnabled = $true
            $closed = @()
            $failed = @()
            foreach ($result in @($value)) {
                if (-not $result) { continue }
                $closed += @($result.Closed)
                $failed += @($result.Failed)
            }
            if ($err) { $failed += $err.Message }
            if ($closed.Count -gt 0) { Write-FtLog ('切断しました: ' + ($closed -join '、')) }
            if ($failed.Count -gt 0) { Write-FtLog ('切断できませんでした: ' + ($failed -join '、')) }
            $hosts = Join-FtHostNames $context.HostNames
            $message = $null
            if ($failed.Count -gt 0) {
                $message = '使用中のため切断できない接続があります：' + ($failed -join '、')
            } elseif ($closed.Count -eq 0) {
                $message = "$hosts への切断できる接続はありませんでした。エクスプローラーで開いているウィンドウを閉じて、数分待ってから再試行してください"
            }
            # 切断できたら、接続を確認し直してから送り直す（ログオンが必要になっていれば、ログオンダイアログが出る）
            $canRetry = $context.Retry -and $script:Phase -eq 'error' -and -not $message
            $script:RetryAfterCheck = $canRetry
            Request-FtHostCheck -Immediate
            if (-not $canRetry) {
                $kind = if ($message) { 'warn' } else { 'info' }
                if (-not $message) { $message = "$hosts への接続を切断しました：" + ($closed -join '、') }
                if ($script:Phase -eq 'error') { Set-FtResult $kind $message @('Detail') } else { Show-FtNotice $message $kind }
            }
        }
}

#endregion

#region ダイアログ ----------------------------------------------------------------

# ログオンダイアログの［OK］。Disconnect を付けると（［切断して再試行］）、先にそのサーバーへの接続を切断する
function Submit-FtLogon {
    param([switch]$Disconnect)
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
    $targets = @(@{ HostName = $state.HostName; ShareRoot = $state.Root })
    if ($d.ApplyOthersBox.Visibility -eq 'Visible' -and $d.ApplyOthersBox.IsChecked) { $targets += $state.Others }
    $d.ErrorText.Visibility = 'Collapsed'
    $d.DisconnectButton.Visibility = 'Collapsed'
    $d.OkButton.Content = if ($Disconnect) { '切断中…' } else { '接続中…' }
    foreach ($control in $d.OkButton, $d.UserBox, $d.PassBox, $d.SaveBox, $d.ApplyOthersBox) { $control.IsEnabled = $false }
    $jobScript = @'
param($Targets, $UserName, $Password, $Save, $Disconnect, $Method, $WinRm)
if ($Method -eq 'winrm') {
    return @{ Disconnected = $null; Results = (Connect-FtWinRmGroup -Targets $Targets -UserName $UserName -Password $Password -Save:$Save -WinRm $WinRm) }
}
$disconnected = if ($Disconnect) { Disconnect-FtHostConnections -HostName $Targets[0].HostName } else { $null }
@{ Disconnected = $disconnected; Results = (Connect-FtShareGroup -Targets $Targets -UserName $UserName -Password $Password -Save:$Save) }
'@
    Start-FtJob -Script $jobScript `
        -Parameters @{
            Targets = $targets; UserName = $user; Password = $d.PassBox.SecurePassword.Copy(); Save = $state.Save; Disconnect = [bool]$Disconnect
            Method = $state.Method; WinRm = (Get-FtWinRmOptions $script:Config)
        } `
        -Context $state -TimeoutMs 45000 -OnLate {
            # タイムアウトのあとで接続できていたら、終了時に切断する
            param($value, $context)
            foreach ($result in @($value.Results)) {
                if ($result -and $result.Status -eq 'ok' -and $result.Root -and -not $script:Connections.Contains($result.Root)) { $script:Connections.Add($result.Root) }
            }
        } -OnComplete {
            param($value, $err, $context)
            $context.Busy = $false
            $results = if ($value) { @($value.Results) } else { @() }
            $disconnected = if ($value) { $value.Disconnected } else { $null }
            if ($disconnected) {
                if ($disconnected.Closed.Count -gt 0) { Write-FtLog ("切断しました: " + ($disconnected.Closed -join '、')) }
                if ($disconnected.Failed.Count -gt 0) { Write-FtLog ("切断できませんでした: " + ($disconnected.Failed -join '、')) }
            }
            if (-not $context.Dialog.IsVisible) {
                # 接続中にキャンセルされた: 接続できていたら、終了時に切断する（WinRM は接続を残さない）
                foreach ($result in $results) {
                    if ($result -and $result.Status -eq 'ok' -and $result.Root -and -not $script:Connections.Contains($result.Root)) { $script:Connections.Add($result.Root) }
                }
                return
            }
            $dd = $context.D
            $dd.OkButton.Content = 'OK'
            foreach ($control in $dd.OkButton, $dd.UserBox, $dd.PassBox, $dd.SaveBox, $dd.ApplyOthersBox) { $control.IsEnabled = $true }
            if ($err -is [System.TimeoutException]) {
                $dd.ErrorText.Text = "$($context.HostName) から応答がありません（タイムアウト）。サーバーが起動しているか、ホスト名やネットワークの設定を確認して、もう一度お試しください。"
            } elseif ($err -or $results.Count -eq 0) {
                $dd.ErrorText.Text = if ($err) { $err.Message } else { '接続できませんでした。' }
            } elseif ($results[0].Status -eq 'ok') {
                $context.Result = $results
                $context.Dialog.DialogResult = $true
                return
            } elseif ($context.Method -eq 'winrm' -and $results[0].Message) {
                $codeText = if ($results[0].Code) { "（エラー $($results[0].Code)）" } else { '' }
                $dd.ErrorText.Text = "$($results[0].Message)$codeText"
            } elseif ($results[0].Code -eq 1219) {
                # 別のユーザーで接続中: 今ある接続を見せて［切断して再試行］を出す
                $lines = @("$($context.HostName) には、この PC から別のユーザーで接続中です（エラー 1219）。")
                if ($disconnected) {
                    if ($disconnected.Failed.Count -gt 0) { $lines += '使用中のため切断できませんでした：' + ($disconnected.Failed -join '、') }
                    elseif ($disconnected.Closed.Count -gt 0) { $lines += '切断しましたが、まだ接続が残っています。エクスプローラーでこのサーバーを開いているウィンドウを閉じて、数分待ってから再試行してください。' }
                    else { $lines += '切断できる接続はありませんでした。エクスプローラーでこのサーバーを開いているウィンドウを閉じて、数分待ってから再試行してください。' }
                } else {
                    $connections = @(Get-FtHostConnections -HostName $context.HostName | ForEach-Object { Format-FtConnection $_ })
                    if ($connections.Count -gt 0) { $lines += '接続中：' + ($connections -join '、') }
                }
                $dd.ErrorText.Text = $lines -join "`n"
                $dd.DisconnectButton.Visibility = 'Visible'
            } else {
                $info = Get-FtErrorInfo -Code ([int]$results[0].Code) -Target $context.HostName -Server
                $dd.ErrorText.Text = $info.Short + "（エラー $($results[0].Code)）"
            }
            $dd.ErrorText.Visibility = 'Visible'
            [void]$dd.PassBox.Focus()
            $dd.PassBox.SelectAll()
        }
}

# ログオンダイアログ。ログオンできたら $true を返す
function Show-FtLogon {
    param([string]$HostName)
    if ($script:Phase -eq 'running' -or -not $HostName) { return $false }
    $targets = Get-FtCheckTargets
    $target = $targets | Where-Object { $_.HostName -eq $HostName } | Select-Object -First 1
    $root = if ($target) { $target.Root } else { "\\$HostName\C`$" }
    $others = @($targets | Where-Object { $_.HostName -ne $HostName -and (Get-FtCheck $_.HostName).Status -in 'auth', 'conflict' } |
        ForEach-Object { @{ HostName = $_.HostName; ShareRoot = $_.Root } })

    $method = Get-FtMethod
    $dialog = Read-FtXaml 'LogonDialog.xaml'
    $dialog.Owner = $window
    $d = Get-FtNamedElements $dialog @('Heading', 'UserBox', 'UserPlaceholder', 'PassBox', 'ErrorText', 'DisconnectButton', 'SaveBox', 'ApplyOthersBox', 'ApplyOthersText', 'OkButton', 'CancelButton')
    # ハンドラーからは $script:Logon で参照する（GetNewClosure を使うとスクリプトの関数が見えなくなるため）
    $script:Logon = @{ Result = $null; Busy = $false; Dialog = $dialog; D = $d; HostName = $HostName; Root = $root; Others = $others; User = ''; Save = $false; Method = $method }
    $state = $script:Logon

    $d.Heading.Text = if ($method -eq 'winrm') { "$HostName にログオン（WinRM）" } else { "$HostName にログオン" }
    $d.UserPlaceholder.Text = "$HostName\ユーザー名 または $env:USERDOMAIN\ユーザー名"
    # 前回のユーザー名: このセッションでログオンした人 > WinRM 用に保存したもの > SMB 用に保存したもの
    $initialUser = if ($script:SessionUsers.ContainsKey($HostName)) { $script:SessionUsers[$HostName] }
                   elseif ($method -eq 'winrm' -and (Get-FtWinRmSavedUser $HostName)) { Get-FtWinRmSavedUser $HostName }
                   else { Get-FtSavedUser $HostName }
    $d.UserBox.Text = "$initialUser"
    $d.UserPlaceholder.Visibility = if ($d.UserBox.Text) { 'Collapsed' } else { 'Visible' }
    if ($others.Count -gt 0) {
        $names = ($others | ForEach-Object { $_.HostName }) -join '、'
        $d.ApplyOthersText.Text = "ログオンが必要なほかの $($others.Count) 台（$names）にも、同じアカウントで接続する"
        $d.ApplyOthersBox.Visibility = 'Visible'
    }
    $d.UserBox.Add_TextChanged({
        $dd = $script:Logon.D
        $dd.UserPlaceholder.Visibility = if ($dd.UserBox.Text) { 'Collapsed' } else { 'Visible' }
    })
    $d.OkButton.Add_Click({ Submit-FtLogon })
    $d.DisconnectButton.Add_Click({ Submit-FtLogon -Disconnect })
    $dialog.Add_ContentRendered({
        $dd = $script:Logon.D
        if ($dd.UserBox.Text) { [void]$dd.PassBox.Focus() } else { [void]$dd.UserBox.Focus() }
    })
    [void]$dialog.ShowDialog()

    $results = $state.Result
    if ($null -eq $results) { return $false }
    $failures = @()
    foreach ($result in $results) {
        if ($result.Status -ne 'ok') {
            $reason = if ($method -eq 'winrm' -and $result.Message) { $result.Message } else { (Get-FtErrorInfo -Code ([int]$result.Code) -Target $result.HostName -Server -Method $method).Short }
            $failures += "$($result.HostName)（$reason）"
            continue
        }
        $hostName = $result.HostName
        $script:SessionUsers[$hostName] = $result.UserName
        if ($method -eq 'winrm') {
            # WinRM は接続を残さないので、転送のたびにこの資格情報で接続する
            $script:SessionCreds[$hostName] = $result.Credential
            $script:Checks[$hostName] = @{ Status = 'ok'; Code = 0; User = $result.UserName; Root = "winrm:$hostName"; Message = '' }
        } else {
            if ($result.ConnectName -and $result.ConnectName -ine $hostName) { $script:HostAlias[$hostName] = $result.ConnectName }
            if (-not $script:Connections.Contains($result.Root)) { $script:Connections.Add($result.Root) }
            $script:Checks[$hostName] = @{ Status = 'ok'; Code = 0; User = $result.UserName; Root = $result.Root; Message = '' }
        }
        $saved = if ($result.Saved) { '（資格情報を保存）' } else { '' }
        $via = if ($method -eq 'winrm') { '（WinRM）' } else { '' }
        Write-FtLog "$hostName に $($result.UserName) でログオンしました$via$saved"
        if ($state.Save -and -not $result.Saved) { $failures += "$hostName（資格情報を保存できませんでした: エラー $($result.SaveError)）" }
    }
    if ($failures.Count -gt 0) { Show-FtNotice ('ログオンできなかったサーバーがあります：' + ($failures -join '、')) 'warn' }
    Update-FtView
    return $true
}

# 画面からのログオン（ヒントの［ログオン…］、● のメニュー、結果の行の［ログオン…］）
# エラーの表示中なら、ログオンできたらそのまま送り直す
function Request-FtLogon {
    param([string]$HostName)
    if (-not $HostName) {
        $targets = Get-FtCheckTargets
        $first = $targets | Where-Object { (Get-FtCheck $_.HostName).Status -in 'auth', 'conflict' } | Select-Object -First 1
        if (-not $first) { $first = $targets | Select-Object -First 1 }
        if (-not $first) { return }
        $HostName = $first.HostName
    }
    if ((Show-FtLogon -HostName $HostName) -and $script:Phase -eq 'error') { Start-FtTransfer }
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

# 設定（サーバーへの転送方法）。変えたらユーザーの設定ファイルに保存して、接続を確認し直す
function Show-FtSettings {
    if ($script:Phase -eq 'running') { return }
    $dialog = Read-FtXaml 'SettingsDialog.xaml'
    $dialog.Owner = $window
    $d = Get-FtNamedElements $dialog @('SmbRadio', 'WinRmRadio', 'WinRmText', 'OkButton')
    $current = Get-FtMethod
    $d.SmbRadio.IsChecked = $current -ne 'winrm'
    $d.WinRmRadio.IsChecked = $current -eq 'winrm'
    $port = Get-FtWinRmPort (Get-FtWinRmOptions $script:Config)
    if ($port -ne 5985) { $d.WinRmText.Text = $d.WinRmText.Text -replace '5985 番ポート', "$port 番ポート" }
    $d.OkButton.Add_Click({ param($sender, $e) [System.Windows.Window]::GetWindow($sender).DialogResult = $true })
    if (-not $dialog.ShowDialog()) { return }
    $selected = if ($d.WinRmRadio.IsChecked) { 'winrm' } else { 'smb' }
    Set-FtMethod $selected
}

function Set-FtMethod {
    param([ValidateSet('smb', 'winrm')][string]$Method)
    if ($Method -eq (Get-FtMethod)) { return }
    $script:Config.transfer.method = $Method
    try { Set-FtUserSetting -Section 'transfer' -Name 'method' -Value $Method } catch { Write-FtLog "設定を保存できませんでした: $($_.Exception.Message)" }
    Write-FtLog "サーバーへの転送方法を $(if ($Method -eq 'winrm') { 'WinRM' } else { 'SMB' }) にしました"
    # 前の方法での完了・エラーの表示は消し（次の［転送開始］は新しい転送になる）、接続を確認し直す
    Exit-FtFinished
    Request-FtHostCheck -Immediate
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
$ui.AddFolderButton.Add_Click({ Show-FtFolderDialog })
$ui.SettingsButton.Add_Click({ Show-FtSettings })
$ui.ClearButton.Add_Click({ Remove-FtItems @($script:Items) })
$ui.StartButton.Add_Click({ Start-FtTransfer })
$ui.CancelButton.Add_Click({ Stop-FtTransfer })
$ui.DestBadge.Add_Click({
    $targets = Get-FtCheckTargets
    if ($targets.Count -gt 1) { Show-FtHostMenu $ui.DestBadge 'logon' } else { Request-FtLogon }
})
$ui.LogonLink.Add_Click({ Request-FtLogon $script:LogonTarget })
$ui.DisconnectLink.Add_Click({ Request-FtDisconnect $script:DisconnectTargets })
$ui.DetailLink.Add_Click({ Show-FtDetails })
$ui.OpenLink.Add_Click({ Invoke-FtResultLink $ui.OpenLink 'open' })
$ui.RdpLink.Add_Click({ Invoke-FtResultLink $ui.RdpLink 'rdp' })

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

$window.Add_Closing({
    param($sender, $e)
    if ($script:Phase -eq 'running') {
        $answer = [System.Windows.MessageBox]::Show($window, '転送中です。中止して閉じますか？', 'FileTransfer', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        if ($script:Run.Dist) { Stop-FtDistribution $script:Run.Dist -TimeoutMs 5000 }
    }
    if ($window.WindowState -eq 'Normal') {
        $script:Config.window = @{ left = [int]$window.Left; top = [int]$window.Top; width = [int]$window.Width; height = [int]$window.Height }
    }
    $script:Config.last = @{ destination = (Get-FtDestText); folder = (Get-FtFolderText); items = [string[]]@($script:Items | ForEach-Object { $_.Path }) }
    Save-FtSettings
})

$window.Add_Closed({
    $script:Timer.Stop()
    foreach ($root in $script:Connections) { Disconnect-FtShare $root }
    Clear-FtRunStage
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
        $width = if ($saved.ContainsKey('width')) { [double]$saved.width } else { $window.Width }
        $screenRight = [System.Windows.SystemParameters]::VirtualScreenLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
        $screenBottom = [System.Windows.SystemParameters]::VirtualScreenTop + [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($left -ge [System.Windows.SystemParameters]::VirtualScreenLeft -and $left + 100 -le $screenRight -and
            $top -ge [System.Windows.SystemParameters]::VirtualScreenTop -and $top + 100 -le $screenBottom) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = $left
            $window.Top = $top
            $window.Height = [Math]::Max($window.MinHeight, $height)
            $window.Width = [Math]::Max($window.MinWidth, [Math]::Min($width, [System.Windows.SystemParameters]::VirtualScreenWidth))
        }
    }

    $last = $script:Config.last
    $destination = "$($last.destination)"
    if (-not $destination) { $destination = "$(@($script:Config.history.destinations)[0])" }
    $names = Split-FtDestinations $destination
    $script:DestKind = if ($names.Count -gt 0 -and @($names | Where-Object { -not (Test-FtLocalDestination $_) }).Count -eq 0) { 'local' } else { 'server' }
    if ($last.folder) { $script:LastFolder[$script:DestKind] = "$($last.folder)" }

    Update-FtDestItems
    Update-FtFolderItems
    Set-FtComboText $ui.DestBox $destination
    Set-FtComboText $ui.FolderBox $script:LastFolder[$script:DestKind]
    Request-FtHostCheck -Immediate
    $script:Timer.Start()

    # 前回の送るファイルを復元する（消えたもの・読めなくなったものは Add-FtPaths が飛ばし、一覧から外れる）
    $savedItems = @($last.items | Where-Object { $_ })
    if ($savedItems.Count -gt 0) {
        Add-FtPaths $savedItems
        if ($script:Items.Count -ne $savedItems.Count) { Save-FtItems }
    }
}

# コピー元（install.bat を実行したフォルダ）が更新されていたら、更新するか尋ねる
# コピー元が共有フォルダで応答しないこともあるので、裏で調べて 15 秒で諦める
function Request-FtUpdateCheck {
    Start-FtJob -Script 'param($AppRoot) Test-FtUpdate -AppRoot $AppRoot' -Parameters @{ AppRoot = $script:AppRoot } -TimeoutMs 15000 -OnComplete {
        param($value, $err, $context)
        if ($err) { Write-FtLog "更新の確認に失敗しました: $($err.Message)"; return }
        if (-not $value -or $script:Phase -eq 'running') { return }
        $message = "新しいバージョンの FileTransfer があるため、更新を行います。`n［OK］を押すと自動で再起動します。`n`nSource: $($value.Source)"
        [void][System.Windows.MessageBox]::Show($window, $message, 'FileTransfer', 'OK', 'Information')
        if ($script:Phase -eq 'running') { return }
        Write-FtLog "更新します: $($value.Source)"
        $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -WaitProcessId {1} -Restart' -f $value.Installer, $PID
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden
        $window.Close()
    }
}

Initialize-FtWindow

if (-not $NoShow) {
    Request-FtUpdateCheck
    [void]$window.ShowDialog()
    # 応答のない接続が裏で残っていると、PowerShell が終わらないことがあるので、待たずに終了する
    if (@($script:Jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) { [System.Environment]::Exit(0) }
}

#endregion
