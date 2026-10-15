# 転送エンジン: 送るファイルを robocopy の実行単位にまとめ、実行して進捗を共有状態（Sync）に書き込む
# FileTransfer.Native（lib\Native.cs）が読み込まれている前提

$script:CommonOptions = @('/BYTES', '/FP', '/NDL', '/NJH', '/NJS', '/XJ', '/XX')

# フォルダの合計サイズとファイル数（アクセスできないサブフォルダは飛ばす）
function Measure-FtFolder {
    param([string]$Path)
    $bytes = 0L
    $files = 0
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        try {
            $info = New-Object System.IO.DirectoryInfo $dir
            foreach ($file in $info.EnumerateFiles()) { $bytes += $file.Length; $files++ }
            foreach ($sub in $info.EnumerateDirectories()) {
                # ジャンクション・シンボリックリンクは辿らない（robocopy の /XJ と合わせる）
                if (-not ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $pending.Push($sub.FullName) }
            }
        } catch { }
    }
    return @{ Bytes = $bytes; Files = $files }
}

function Get-FtParentPath {
    param([string]$Path)
    $trimmed = $Path.TrimEnd('\')
    $index = $trimmed.LastIndexOf('\')
    if ($index -lt 0) { return $trimmed }
    $parent = $trimmed.Substring(0, $index)
    if ($parent -match '^[A-Za-z]:$') { $parent += '\' }
    return $parent
}

function Join-FtPath {
    param([string]$Parent, [string]$Child)
    return $Parent.TrimEnd('\') + '\' + $Child
}

# Entries（@{ Item; Parent }）を robocopy の実行単位（Step）にまとめて Steps に追加する
# ファイルは親フォルダごとに 1 回、フォルダは 1 つずつ /E で実行する
function Add-FtSteps {
    param(
        [System.Collections.Generic.List[object]]$Steps,
        [object[]]$Entries,
        [string]$Destination,
        [bool]$Final,
        [long]$LargeThresholdBytes,
        [int]$MaxArgumentLength
    )
    $openGroups = @{}
    foreach ($entry in $Entries) {
        $item = $entry.Item
        $name = [System.IO.Path]::GetFileName($item.Path.TrimEnd('\'))
        if ($item.IsFolder) {
            $Steps.Add(@{
                Kind   = 'folder'
                Source = Join-FtPath $entry.Parent $name
                Dest   = Join-FtPath $Destination $name
                Files  = @()
                Items  = @($item.Path)
                Bytes  = [long]$item.Size
                Large  = $false
                Final  = $Final
            })
            continue
        }
        $key = $entry.Parent.ToLowerInvariant()
        $group = $openGroups[$key]
        if ($null -eq $group -or ($group.ArgLength + $name.Length + 3) -gt $MaxArgumentLength) {
            $group = @{
                Kind      = 'files'
                Source    = $entry.Parent
                Dest      = $Destination
                Files     = New-Object System.Collections.Generic.List[string]
                Items     = New-Object System.Collections.Generic.List[string]
                Bytes     = 0L
                Large     = $false
                Final     = $Final
                ArgLength = $entry.Parent.Length + $Destination.Length + 200
            }
            $openGroups[$key] = $group
            $Steps.Add($group)
        }
        $group.Files.Add($name)
        $group.Items.Add($item.Path)
        $group.Bytes += [long]$item.Size
        $group.ArgLength += $name.Length + 3
        if ([long]$item.Size -ge $LargeThresholdBytes) { $group.Large = $true }
    }
}

# 送るファイル（@{ Path; IsFolder; Size }）から実行計画を作る
# StageFolder を指定すると、UNC（共有・サーバー）にあるものを先にそこへコピーしてから送る
#   -StageOnly: StageFolder へのコピーだけ（複数の送り先に配るとき、最初に 1 回だけ実行する）
#   -FromStage: StageFolder にコピー済みのものを送り先へ送る部分だけ
function New-FtTransferPlan {
    param(
        [object[]]$Items,
        [string]$Destination = '',
        [string]$StageFolder = '',
        [long]$LargeThresholdBytes = 256MB,
        [int]$MaxArgumentLength = 28000,
        [switch]$StageOnly,
        [switch]$FromStage
    )
    $steps = New-Object System.Collections.Generic.List[object]
    $staged = @{}
    if ($StageFolder) {
        $stageEntries = @()
        foreach ($item in $Items) {
            if ($item.Path -like '\\*') {
                $stageEntries += @{ Item = $item; Parent = (Get-FtParentPath $item.Path) }
                $staged[$item.Path] = $true
            }
        }
        if ($stageEntries.Count -and -not $FromStage) {
            Add-FtSteps -Steps $steps -Entries $stageEntries -Destination $StageFolder -Final $false -LargeThresholdBytes $LargeThresholdBytes -MaxArgumentLength $MaxArgumentLength
        }
    }
    if ($StageOnly) { return , $steps.ToArray() }
    $finalEntries = @()
    foreach ($item in $Items) {
        $parent = if ($staged.ContainsKey($item.Path)) { $StageFolder } else { Get-FtParentPath $item.Path }
        $finalEntries += @{ Item = $item; Parent = $parent }
    }
    Add-FtSteps -Steps $steps -Entries $finalEntries -Destination $Destination -Final $true -LargeThresholdBytes $LargeThresholdBytes -MaxArgumentLength $MaxArgumentLength
    return , $steps.ToArray()
}

# robocopy に渡すパス。末尾の \ は閉じ引用符をエスケープしてしまうので取り除く（C:\ は C:\. にする）
function ConvertTo-FtRobocopyPath {
    param([string]$Path)
    $value = $Path.TrimEnd('\')
    if ($value -match '^[A-Za-z]:$') { $value += '\.' }
    return '"' + $value + '"'
}

function Get-FtRobocopyArguments {
    param([hashtable]$Step, [int]$RetryCount = 2, [int]$RetryWaitSec = 3, [int]$Threads = 8)
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add((ConvertTo-FtRobocopyPath $Step.Source))
    $arguments.Add((ConvertTo-FtRobocopyPath $Step.Dest))
    if ($Step.Kind -eq 'files') {
        foreach ($file in $Step.Files) { $arguments.Add('"' + $file + '"') }
    } else {
        $arguments.Add('/E')
        if ($Threads -gt 1) { $arguments.Add("/MT:$Threads") }
    }
    $arguments.Add("/R:$RetryCount")
    $arguments.Add("/W:$RetryWaitSec")
    if ($Step.Large) { $arguments.Add('/J') }
    foreach ($option in $script:CommonOptions) { $arguments.Add($option) }
    return ($arguments -join ' ')
}

# robocopy の出力 1 行を解釈する
#   file:     "\t    New File  \t\t314572800\tC:\src\big.bin"（/BYTES /FP）
#   progress: "  12.3%"
#   error:    "2026/10/15 14:32:10 ERROR 5 (0x00000005) Copying File ..."（表示言語によらずコードの書式は同じ）
function ConvertFrom-FtRobocopyLine {
    param([string]$Line)
    if ($Line -match '^\s*(?<pct>\d{1,3}(?:\.\d+)?)%\s*$') {
        return @{ Type = 'progress'; Percent = [double]::Parse($Matches['pct'], [Globalization.CultureInfo]::InvariantCulture) }
    }
    if ($Line -match '^\t\s*(?<class>[^\t]*?)\s*\t+\s*(?<size>\d+)\t(?<path>.+)$') {
        return @{ Type = 'file'; Class = $Matches['class']; Size = [long]$Matches['size']; Path = $Matches['path'].Trim() }
    }
    if ($Line -match '\s(?<code>\d+) \(0x[0-9A-Fa-f]{8}\)\s*(?<text>.*)$') {
        return @{ Type = 'error'; Code = [int]$Matches['code']; Text = $Matches['text'].Trim() }
    }
    return @{ Type = 'text'; Text = $Line.Trim() }
}

function Write-FtSyncLog {
    param([hashtable]$Sync, [string]$Message)
    if ($Sync.ContainsKey('Log') -and $null -ne $Sync.Log) { $Sync.Log.Enqueue($Message) }
}

# robocopy を 1 回実行し、出力を読みながら Sync に進捗を書き込む
function Invoke-FtRobocopyStep {
    param(
        [hashtable]$Step,
        [hashtable]$Sync,
        [string]$Arguments,
        [System.Text.Encoding]$Encoding,
        [long]$DoneBase
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\robocopy.exe'), $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Encoding
    $psi.StandardErrorEncoding = $Encoding
    $process = [System.Diagnostics.Process]::Start($psi)
    $Sync.ProcessId = $process.Id
    $stderrTask = $process.StandardError.ReadToEndAsync()

    # ファイル名 → 一覧の項目（ファイル転送では 1 ファイル = 1 項目）
    $byName = @{}
    foreach ($itemPath in $Step.Items) { $byName[[System.IO.Path]::GetFileName($itemPath.TrimEnd('\'))] = $itemPath }

    $stepBytes = [long]$Step.Bytes
    $stepDone = 0L
    $currentSize = 0L
    $currentFraction = 0.0
    $currentItem = $null
    $errorCode = 0
    $errorText = ''
    $expectDescription = $false

    $buffer = New-Object char[] 8192
    $carry = ''
    while ($true) {
        $count = $process.StandardOutput.Read($buffer, 0, $buffer.Length)
        $lines = @()
        if ($count -gt 0) {
            $parts = ($carry + [string]::new($buffer, 0, $count)) -split '[\r\n]'
            $carry = $parts[-1]
            if ($parts.Count -gt 1) { $lines = $parts[0..($parts.Count - 2)] }
        } else {
            if ($carry) { $lines = @($carry) }
            $carry = ''
        }

        foreach ($line in $lines) {
            if (-not $line.Trim()) { continue }
            $parsed = ConvertFrom-FtRobocopyLine $line
            switch ($parsed.Type) {
                'progress' {
                    $currentFraction = $parsed.Percent / 100
                }
                'file' {
                    if ($null -ne $currentItem) {
                        $stepDone += $currentSize
                        if ($Step.Kind -eq 'files' -and $Step.Final) { $Sync.Completed.Enqueue($currentItem) }
                    }
                    $currentSize = $parsed.Size
                    $currentFraction = 0.0
                    if ($Step.Kind -eq 'folder') {
                        $currentItem = $Step.Items[0]
                    } else {
                        $leaf = [System.IO.Path]::GetFileName($parsed.Path)
                        $currentItem = $byName[$leaf]
                        if ($null -eq $currentItem) { $currentItem = $Step.Items[0] }
                    }
                    Write-FtSyncLog $Sync ("  {0}  {1}  ({2})" -f $parsed.Class, $parsed.Path, [FileTransfer.FileItem]::FormatSize($parsed.Size))
                }
                'error' {
                    if (-not $errorCode) { $errorCode = $parsed.Code; $errorText = $parsed.Text }
                    Write-FtSyncLog $Sync ("  " + $line.Trim())
                    $expectDescription = $true
                }
                default {
                    Write-FtSyncLog $Sync ("  " + $parsed.Text)
                    if ($expectDescription) { $errorText = "$errorText`n$($parsed.Text)".Trim(); $expectDescription = $false }
                }
            }
        }

        # 進捗を書き込む
        $Sync.CurrentItem = $currentItem
        $inStep = $stepDone + [long]($currentSize * $currentFraction)
        if ($inStep -gt $stepBytes) { $inStep = $stepBytes }
        $Sync.BytesDone = $DoneBase + $inStep
        if ($Step.Kind -eq 'folder') {
            $Sync.CurrentFraction = if ($stepBytes -gt 0) { $inStep / $stepBytes } else { 0 }
        } else {
            $Sync.CurrentFraction = $currentFraction
        }

        if ($count -le 0) { break }
    }
    $process.WaitForExit()
    $stderr = $stderrTask.Result
    if ($stderr -and $stderr.Trim()) { Write-FtSyncLog $Sync ("  " + $stderr.Trim()) }
    $exitCode = $process.ExitCode
    $process.Dispose()

    # robocopy は存在しないファイル名を指定されてもエラーにしないので、届いたかを確認する
    $missing = @()
    if ($exitCode -lt 8 -and $Step.Kind -eq 'files' -and -not $Sync.Cancel) {
        foreach ($file in $Step.Files) {
            if (-not (Test-Path -LiteralPath (Join-FtPath $Step.Dest $file))) { $missing += $file }
        }
    }
    return @{ ExitCode = $exitCode; ErrorCode = $errorCode; ErrorText = $errorText; Missing = $missing }
}

# 実行計画を順に実行する（バックグラウンドの Runspace で呼ぶ）
# Sync に書き込むもの: BytesTotal, BytesDone, CurrentItem, CurrentFraction, ProcessId, Completed（キュー）, Log（キュー）, Result
# Sync.Cancel が $true になったら中止する（実行中の robocopy は UI 側が終了させる）
function Invoke-FtTransferPlan {
    param(
        [object[]]$Steps,
        [hashtable]$Sync,
        [int]$RetryCount = 2,
        [int]$RetryWaitSec = 3,
        [int]$Threads = 8
    )
    $total = 0L
    foreach ($step in $Steps) { $total += [long]$step.Bytes }
    $Sync.BytesTotal = $total
    $Sync.BytesDone = 0L
    $encoding = [System.Text.Encoding]::GetEncoding([FileTransfer.Native]::OemCodePage())
    $result = @{ Status = 'success'; ExitCode = 0; Code = 0; Message = ''; Missing = @(); FailedStep = -1 }
    $doneBase = 0L
    try {
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            if ($Sync.Cancel) { $result.Status = 'canceled'; break }
            $step = $Steps[$i]
            $Sync.StepIndex = $i
            $arguments = Get-FtRobocopyArguments -Step $step -RetryCount $RetryCount -RetryWaitSec $RetryWaitSec -Threads $Threads
            Write-FtSyncLog $Sync "robocopy $arguments"
            $outcome = Invoke-FtRobocopyStep -Step $step -Sync $Sync -Arguments $arguments -Encoding $encoding -DoneBase $doneBase
            if ($Sync.Cancel) { $result.Status = 'canceled'; break }
            Write-FtSyncLog $Sync "  終了コード $($outcome.ExitCode)"
            if ($outcome.ExitCode -ge 8 -or $outcome.Missing.Count -gt 0) {
                $result.Status = 'failed'
                $result.ExitCode = $outcome.ExitCode
                $result.Code = $outcome.ErrorCode
                $result.Message = $outcome.ErrorText
                $result.Missing = $outcome.Missing
                $result.FailedStep = $i
                break
            }
            $doneBase += [long]$step.Bytes
            $Sync.BytesDone = $doneBase
            if ($step.Final) { foreach ($itemPath in $step.Items) { $Sync.Completed.Enqueue($itemPath) } }
        }
    } catch {
        $result.Status = 'failed'
        $result.Message = $_.Exception.Message
        Write-FtSyncLog $Sync "  例外: $($_.Exception.Message)"
    } finally {
        $Sync.CurrentItem = $null
        $Sync.ProcessId = 0
        $Sync.Result = $result
    }
    return $result
}

# エラーコード → 画面に出す文言
#   Short: 結果の行に出す要約 / Detail: ［詳細］に出す説明 / NeedsLogon: ［ログオン…］を出すか
#   Method: winrm のときは、ファイル共有（445 番ポート・管理共有）ではなく WinRM の説明にする
function Get-FtErrorInfo {
    param([int]$Code, [string]$Target = '送り先', [string[]]$Missing = @(), [string]$Fallback = '', [switch]$Server, [string]$Method = 'smb')
    $winrm = $Server -and $Method -eq 'winrm'
    $info = switch ($Code) {
        { $_ -in 2, 3 } { @{ Short = 'コピー元が見つかりません'; Detail = "コピー元のファイルまたはフォルダが見つかりません（エラー $Code）。移動や削除をされていないか確認してください。" } }
        5 {
            if ($winrm) {
                @{ Short = "${Target}：アクセスが拒否されました"; NeedsLogon = $true; Detail = "アクセスが拒否されました（エラー 5）。`nWinRM で接続できる権限（サーバーの Administrators など）と、送り先のフォルダに書き込む権限があるアカウントか確認してください。`n［ログオン…］から別のアカウントで接続し直せます。`n$Fallback".Trim() }
            } elseif ($Server) {
                @{ Short = "${Target}：アクセスが拒否されました"; NeedsLogon = $true; Detail = "書き込みが拒否されました（エラー 5）。`n管理者権限のあるアカウントで接続しているか確認してください。ローカルアカウントの場合、組み込みの Administrator 以外は管理共有（C$ など）に接続できないことがあります。`n［ログオン…］から別のアカウントで接続し直せます。" }
            } else {
                @{ Short = "${Target}：アクセスが拒否されました"; Detail = "書き込みが拒否されました（エラー 5）。送り先のフォルダに書き込む権限があるか確認してください。" }
            }
        }
        { $_ -in 32, 33 } { @{ Short = 'ファイルが使用中です'; Detail = "ほかのプログラムがファイルを使用しているため、コピーできません（エラー $Code）。" } }
        { $_ -in 51, 53, 64, 121, 1231, 1232 } {
            if ($winrm) {
                @{ Short = "${Target} に接続できません"; Detail = "WinRM で接続できないか、接続が切れました。`nホスト名と、サーバーで WinRM（PowerShell リモート。5985 番ポート）が有効か確認してください。`n$Fallback".Trim() }
            } else {
                @{ Short = "${Target} に接続できません"; Detail = "ネットワーク パスが見つからないか、接続が切れました（エラー $Code）。`nホスト名と、サーバーでファイル共有（445 番ポート）が許可されているか確認してください。" }
            }
        }
        67 { @{ Short = '共有が見つかりません'; Detail = "共有フォルダが見つかりません（エラー 67）。サーバーの管理共有（C$ など）が無効になっている可能性があります。" } }
        112 { @{ Short = 'ディスクの空き容量が足りません'; Detail = "送り先のディスクの空き容量が足りません（エラー 112）。" } }
        1219 { @{ Short = "${Target}：別のユーザーで接続中です"; NeedsLogon = $true; NeedsDisconnect = $true; Detail = "このサーバーには、別のユーザーで接続中です（エラー 1219）。`n［切断して再試行］で、この PC からそのサーバーへの接続（ネットワーク ドライブなど）を切断して接続し直せます。それでも直らないときは、エクスプローラーでそのサーバーを開いているウィンドウを閉じ、数分待ってから再試行してください。" } }
        { $_ -in 86, 1326 } { @{ Short = 'ユーザー名またはパスワードが正しくありません'; NeedsLogon = $true; Detail = "ユーザー名またはパスワードが正しくありません（エラー $Code）。" } }
        1311 { @{ Short = 'ログオン サーバーに接続できません'; Detail = "ドメインのログオン サーバーに接続できません（エラー 1311）。" } }
        1331 { @{ Short = 'アカウントが無効です'; NeedsLogon = $true; Detail = "このアカウントは無効になっています（エラー 1331）。" } }
        { $_ -in 1330, 1907 } { @{ Short = 'パスワードの有効期限が切れています'; NeedsLogon = $true; Detail = "パスワードの有効期限が切れているか、変更が必要です（エラー $Code）。" } }
        1909 { @{ Short = 'アカウントがロックされています'; Detail = "アカウントがロックされています（エラー 1909）。しばらく待つか、管理者に解除を依頼してください。" } }
        default { $null }
    }
    if ($null -eq $info) {
        if ($Missing.Count -gt 0) {
            $info = @{ Short = '一部のファイルが送り先に届いていません'; Detail = "次のファイルが送り先に見つかりません。コピー元から移動・削除されていないか確認してください。`n" + ($Missing -join "`n") }
        } elseif ($winrm -and $Fallback) {
            # WinRM のエラーは、1 行目が要約になっている（WinRm.psm1 の ConvertFrom-FtWinRmError）
            $first = @($Fallback -split "`r?`n" | Where-Object { $_.Trim() })[0]
            $codeText = if ($Code) { "（エラー $Code）" } else { '' }
            $info = @{ Short = "${Target}：$first$codeText"; Detail = $Fallback }
        } elseif ($Code) {
            $info = @{ Short = "転送に失敗しました（エラー $Code）"; Detail = "転送に失敗しました（エラー $Code）。`n$Fallback".Trim() }
        } else {
            $info = @{ Short = '転送に失敗しました'; Detail = "転送に失敗しました。`n$Fallback".Trim() }
        }
    }
    if (-not $info.ContainsKey('NeedsLogon')) { $info.NeedsLogon = $false }
    if (-not $info.ContainsKey('NeedsDisconnect')) { $info.NeedsDisconnect = $false }
    return $info
}

Export-ModuleMember -Function Measure-FtFolder, Get-FtParentPath, New-FtTransferPlan, ConvertTo-FtRobocopyPath, Get-FtRobocopyArguments, ConvertFrom-FtRobocopyLine, Write-FtSyncLog, Invoke-FtRobocopyStep, Invoke-FtTransferPlan, Get-FtErrorInfo
