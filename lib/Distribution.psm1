# 1 台または複数台への転送をまとめて進める
#   1. （必要なら）共有にあるファイルを、この PC に 1 回だけ取得する
#   2. 送り先ごとに robocopy を実行する（最大 ParallelHosts 台ずつ並列）
# 画面のタイマーやコマンドラインのループから Step-FtDistribution を繰り返し呼んで進める。
# 各送り先の実処理は Runspace プール上で Invoke-FtTransferPlan（TransferEngine.psm1）が行う。

function New-FtSync {
    return [hashtable]::Synchronized(@{
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
}

function Get-FtStepsBytes {
    param([object[]]$Steps)
    $total = 0L
    foreach ($step in $Steps) { $total += [long]$step.Bytes }
    return $total
}

# この PC に取得してから配るか。取得するならそのフォルダを返す
#   複数台に配る: 共有を何度も読まないように、一時フォルダへ取得する（終わったら消す）
#   keepLocalCopy: 設定のフォルダへ取得して残す
# 戻り値: $null または @{ Folder; Temporary }
function Get-FtStageFolder {
    param(
        [object[]]$Items,
        [int]$TargetCount,
        [bool]$IsLocal,
        [bool]$KeepLocalCopy,
        [string]$LocalCopyFolder,
        [datetime]$Now
    )
    if ($IsLocal) { return $null }
    if (@($Items | Where-Object { $_.Path -like '\\*' }).Count -eq 0) { return $null }
    if ($KeepLocalCopy) {
        $folder = [Environment]::ExpandEnvironmentVariables((Expand-FtTemplate -Template $LocalCopyFolder -Now $Now))
        return @{ Folder = $folder; Temporary = $false }
    }
    if ($TargetCount -gt 1) {
        return @{ Folder = (Join-Path (Get-FtStageRoot) ('stage_' + $Now.ToString('yyyyMMdd_HHmmss'))); Temporary = $true }
    }
    return $null
}

function Get-FtStageRoot { Join-Path $env:TEMP 'FileTransfer' }

# 一時フォルダ（Get-FtStageFolder の Temporary）を消す。それ以外の場所は消さない
function Remove-FtStageFolder {
    param([string]$Folder)
    if (-not $Folder) { return }
    $root = (Get-FtStageRoot).TrimEnd('\') + '\stage_'
    if (-not $Folder.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return }
    if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue }
}

# 転送の取りまとめを作る
#   Items:   @{ Path; IsFolder; Size }
#   Targets: @{ Name; HostName; IsLocal; Dest }（Name は画面やログに出す名前）
#   Options: RetryCount, RetryWaitSec, Threads, LargeThresholdBytes, ParallelHosts
function New-FtDistribution {
    param(
        [object[]]$Items,
        [object[]]$Targets,
        [string]$StageFolder = '',
        [switch]$ReuseStage,
        [hashtable]$Options = @{},
        $Pool
    )
    $threshold = if ($Options.LargeThresholdBytes) { [long]$Options.LargeThresholdBytes } else { 256MB }
    $stage = $null
    if ($StageFolder) {
        $stageSteps = New-FtTransferPlan -Items $Items -StageFolder $StageFolder -StageOnly -LargeThresholdBytes $threshold
        if ($stageSteps.Count -gt 0) {
            $reused = $ReuseStage -and (Test-Path -LiteralPath $StageFolder)
            $stage = @{
                Name = 'この PC へ取得'; Steps = $stageSteps; Sync = (New-FtSync); Job = $null
                Status = $(if ($reused) { 'success' } else { 'pending' }); Reused = $reused
                Result = $null; Bytes = $(if ($reused) { 0L } else { Get-FtStepsBytes $stageSteps }); Started = $null; Elapsed = 0.0
            }
        } else {
            $StageFolder = ''
        }
    }
    $hosts = New-Object System.Collections.Generic.List[object]
    foreach ($target in $Targets) {
        $steps = if ($StageFolder) {
            New-FtTransferPlan -Items $Items -Destination $target.Dest -StageFolder $StageFolder -FromStage -LargeThresholdBytes $threshold
        } else {
            New-FtTransferPlan -Items $Items -Destination $target.Dest -LargeThresholdBytes $threshold
        }
        $hosts.Add(@{
            Name = $target.Name; HostName = $target.HostName; IsLocal = [bool]$target.IsLocal; Dest = $target.Dest
            Steps = $steps; Sync = (New-FtSync); Job = $null; Status = 'pending'; Result = $null
            Bytes = (Get-FtStepsBytes $steps); Started = $null; Elapsed = 0.0
            Done = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        })
    }
    $parallel = if ($Options.ParallelHosts -gt 0) { [int]$Options.ParallelHosts } else { 3 }
    return @{
        Items = $Items; Stage = $stage; StageFolder = $StageFolder; Hosts = $hosts.ToArray(); Options = $Options
        Pool = $Pool; Parallel = $parallel; Cancel = $false; Status = 'running'; Started = (Get-Date)
    }
}

function Get-FtDistributionUnits {
    param([hashtable]$Distribution)
    $units = @()
    if ($Distribution.Stage) { $units += $Distribution.Stage }
    $units += $Distribution.Hosts
    return $units
}

function Stop-FtRobocopyProcess {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($process.ProcessName -ieq 'robocopy') { $process.Kill() }
    } catch { }
}

function Start-FtUnit {
    param([hashtable]$Distribution, [hashtable]$Unit)
    $options = $Distribution.Options
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Distribution.Pool
    [void]$ps.AddScript('param($Steps, $Sync, $RetryCount, $RetryWaitSec, $Threads) Invoke-FtTransferPlan -Steps $Steps -Sync $Sync -RetryCount $RetryCount -RetryWaitSec $RetryWaitSec -Threads $Threads')
    [void]$ps.AddParameter('Steps', $Unit.Steps)
    [void]$ps.AddParameter('Sync', $Unit.Sync)
    [void]$ps.AddParameter('RetryCount', $(if ($null -ne $options.RetryCount) { [int]$options.RetryCount } else { 2 }))
    [void]$ps.AddParameter('RetryWaitSec', $(if ($null -ne $options.RetryWaitSec) { [int]$options.RetryWaitSec } else { 3 }))
    [void]$ps.AddParameter('Threads', $(if ($null -ne $options.Threads) { [int]$options.Threads } else { 8 }))
    $Unit.Job = @{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
    $Unit.Status = 'running'
    $Unit.Started = Get-Date
}

function Complete-FtUnit {
    param([hashtable]$Unit)
    $message = ''
    try { [void]$Unit.Job.PowerShell.EndInvoke($Unit.Job.Handle) } catch { $message = $_.Exception.Message }
    $Unit.Job.PowerShell.Dispose()
    $Unit.Job = $null
    $Unit.Elapsed = ((Get-Date) - $Unit.Started).TotalSeconds
    $result = $Unit.Sync.Result
    if ($null -eq $result) { $result = @{ Status = 'failed'; ExitCode = 0; Code = 0; Message = $message; Missing = @() } }
    $Unit.Result = $result
    $Unit.Status = switch ($result.Status) { 'success' { 'success' } 'canceled' { 'canceled' } default { 'failed' } }
}

# 少しずつ進める（終わったジョブを回収し、次のジョブを始める）。終わったら Status が 'done' になる
function Step-FtDistribution {
    param([hashtable]$Distribution)
    $d = $Distribution
    if ($d.Status -ne 'running') { return }
    $units = Get-FtDistributionUnits $d

    if ($d.Cancel) {
        foreach ($unit in $units) {
            if ($unit.Status -eq 'running') { $unit.Sync.Cancel = $true; Stop-FtRobocopyProcess ([int]$unit.Sync.ProcessId) }
            elseif ($unit.Status -eq 'pending') { $unit.Status = 'canceled' }
        }
    }
    foreach ($unit in $units) {
        if ($unit.Status -eq 'running' -and $unit.Job.Handle.IsCompleted) { Complete-FtUnit $unit }
    }

    $stage = $d.Stage
    if ($stage) {
        if ($stage.Status -eq 'pending' -and -not $d.Cancel) { Start-FtUnit $d $stage }
        if ($stage.Status -eq 'running') { return }
        if ($stage.Status -ne 'success') {
            # 取得に失敗・中止したら、送り先には送らない
            foreach ($unit in $d.Hosts) { if ($unit.Status -eq 'pending') { $unit.Status = $(if ($stage.Status -eq 'canceled') { 'canceled' } else { 'skipped' }) } }
        }
    }

    $running = @($d.Hosts | Where-Object { $_.Status -eq 'running' }).Count
    if (-not $d.Cancel) {
        foreach ($unit in $d.Hosts) {
            if ($running -ge $d.Parallel) { break }
            if ($unit.Status -eq 'pending') { Start-FtUnit $d $unit; $running++ }
        }
    }
    if (@($units | Where-Object { $_.Status -in 'pending', 'running' }).Count -eq 0) { $d.Status = 'done' }
}

# 実行中のジョブを止めて、終わるまで待つ（最大 TimeoutMs）
function Stop-FtDistribution {
    param([hashtable]$Distribution, [int]$TimeoutMs = 10000)
    $Distribution.Cancel = $true
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Distribution.Status -eq 'running' -and $watch.ElapsedMilliseconds -lt $TimeoutMs) {
        Step-FtDistribution $Distribution
        if ($Distribution.Status -eq 'running') { Start-Sleep -Milliseconds 100 }
    }
}

# 新しいログの行（送り先が複数のとき、または取得があるときは [名前] を付ける）
function Read-FtDistributionLog {
    param([hashtable]$Distribution)
    $lines = New-Object System.Collections.Generic.List[string]
    $prefixed = $Distribution.Hosts.Count -gt 1 -or $null -ne $Distribution.Stage
    foreach ($unit in (Get-FtDistributionUnits $Distribution)) {
        $line = $null
        while ($unit.Sync.Log.TryDequeue([ref]$line)) {
            if ($prefixed) { $lines.Add("[$($unit.Name)] $line") } else { $lines.Add($line) }
        }
    }
    return , $lines.ToArray()
}

# 進み具合
#   Items: 項目のパス → @{ State = '' | 'cur' | 'done'; Fraction }（Fraction は全送り先の平均）
function Get-FtDistributionProgress {
    param([hashtable]$Distribution)
    $d = $Distribution
    $total = 0L
    $done = 0L
    foreach ($unit in (Get-FtDistributionUnits $d)) {
        $total += [long]$unit.Bytes
        switch ($unit.Status) {
            'success' { $done += [long]$unit.Bytes }
            'pending' { }
            'skipped' { }
            default   { $done += [Math]::Min([long]$unit.Sync.BytesDone, [long]$unit.Bytes) }
        }
    }
    foreach ($unit in $d.Hosts) {
        $path = $null
        while ($unit.Sync.Completed.TryDequeue([ref]$path)) { [void]$unit.Done.Add($path) }
    }

    $hostCount = [Math]::Max(1, $d.Hosts.Count)
    $items = @{}
    foreach ($item in $d.Items) {
        $sum = 0.0
        $current = $false
        $allDone = $true
        foreach ($unit in $d.Hosts) {
            if ($unit.Status -eq 'success' -or $unit.Done.Contains($item.Path)) { $sum += 1; continue }
            $allDone = $false
            if ($unit.Status -eq 'running' -and "$($unit.Sync.CurrentItem)" -ieq $item.Path) {
                $sum += [double]$unit.Sync.CurrentFraction
                $current = $true
            }
        }
        $fraction = $sum / $hostCount
        if ($d.Stage -and $d.Stage.Status -eq 'running' -and "$($d.Stage.Sync.CurrentItem)" -ieq $item.Path) {
            $current = $true
            $fraction = [double]$d.Stage.Sync.CurrentFraction
        }
        $state = if ($allDone) { 'done' } elseif ($current) { 'cur' } else { '' }
        $items[$item.Path] = @{ State = $state; Fraction = $fraction }
    }
    return @{
        BytesTotal     = $total
        BytesDone      = $done
        HostsTotal     = $d.Hosts.Count
        HostsSucceeded = @($d.Hosts | Where-Object { $_.Status -eq 'success' }).Count
        HostsRunning   = @($d.Hosts | Where-Object { $_.Status -eq 'running' }).Count
        Staging        = [bool]($d.Stage -and $d.Stage.Status -eq 'running')
        Items          = $items
    }
}

# 結果のまとめ
#   Status: success | partial（一部の送り先だけ成功）| failed | canceled
#   Failed: 失敗した単位（取得に失敗したときは取得の単位）
function Get-FtDistributionSummary {
    param([hashtable]$Distribution)
    $d = $Distribution
    $succeeded = @($d.Hosts | Where-Object { $_.Status -eq 'success' })
    $failed = @($d.Hosts | Where-Object { $_.Status -eq 'failed' })
    $stageFailed = $d.Stage -and $d.Stage.Status -eq 'failed'
    if ($stageFailed) { $failed = @($d.Stage) + $failed }
    $status = if ($d.Cancel) { 'canceled' }
              elseif ($failed.Count -eq 0 -and $succeeded.Count -eq $d.Hosts.Count) { 'success' }
              elseif ($succeeded.Count -gt 0) { 'partial' }
              else { 'failed' }
    return @{
        Status      = $status
        Succeeded   = $succeeded
        Failed      = $failed
        StageFailed = [bool]$stageFailed
        Elapsed     = ((Get-Date) - $d.Started).TotalSeconds
    }
}

# パスのうち、実在するいちばん近いフォルダ（送り先フォルダはまだないことが多いため）
function Get-FtExistingFolder {
    param([string]$Path)
    $current = $Path.TrimEnd('\')
    if ($current -match '^[A-Za-z]:$') { $current += '\' }
    while ($current) {
        if ([System.IO.Directory]::Exists($current)) { return $current }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
    return $null
}

# 送り先に必要な容量。同じ名前・同じサイズのファイルが既にあれば（やり直しのとき）数えない
function Get-FtRequiredBytes {
    param([object[]]$Items, [string]$Dest)
    $total = 0L
    foreach ($item in $Items) {
        $size = [long]$item.Size
        if (-not $item.IsFolder -and [System.IO.Directory]::Exists($Dest)) {
            $existing = Join-Path $Dest ([System.IO.Path]::GetFileName($item.Path))
            if ([System.IO.File]::Exists($existing) -and (New-Object System.IO.FileInfo $existing).Length -eq $size) { continue }
        }
        $total += $size
    }
    return $total
}

# 転送前に、送り先（と取得用のフォルダ）の空き容量を確かめる（バックグラウンドで呼ぶ）
# 戻り値: @{ Name; Path; Volume; Free; Required; Short } の配列。Free が -1 なら確認できなかった
function Test-FtFreeSpace {
    param(
        [object[]]$Items,
        [object[]]$Targets,
        [string]$StageFolder = '',
        [switch]$StageReused
    )
    $checks = @()
    if ($StageFolder -and -not $StageReused) {
        $required = 0L
        foreach ($item in $Items) { if ($item.Path -like '\\*') { $required += [long]$item.Size } }
        if ($required -gt 0) { $checks += @{ Name = 'この PC（取得用）'; Path = $StageFolder; Required = $required } }
    }
    foreach ($target in $Targets) {
        $checks += @{ Name = $target.Name; Path = $target.Dest; Required = (Get-FtRequiredBytes -Items $Items -Dest $target.Dest) }
    }
    $results = @()
    foreach ($check in $checks) {
        $folder = Get-FtExistingFolder $check.Path
        $free = if ($folder) { [FileTransfer.Native]::GetFreeBytes($folder.TrimEnd('\') + '\') } else { -1L }
        $results += @{
            Name     = $check.Name
            Path     = $check.Path
            Volume   = [System.IO.Path]::GetPathRoot($check.Path).TrimEnd('\')
            Free     = $free
            Required = [long]$check.Required
            Short    = ($free -ge 0 -and $free -lt $check.Required)
        }
    }
    return , $results
}

# 「SV-APP02（\\SV-APP02\C$）：空き 1.20 GB ／ 必要 3.50 GB」
function Format-FtFreeSpace {
    param([hashtable]$Result)
    $free = if ($Result.Free -ge 0) { [FileTransfer.FileItem]::FormatSize($Result.Free) } else { '不明' }
    return '{0}（{1}）：空き {2} ／ 必要 {3}' -f $Result.Name, $Result.Volume, $free, [FileTransfer.FileItem]::FormatSize($Result.Required)
}

Export-ModuleMember -Function Get-FtExistingFolder, Get-FtRequiredBytes, Test-FtFreeSpace, Format-FtFreeSpace, New-FtSync, Get-FtStageFolder, Get-FtStageRoot, Remove-FtStageFolder, New-FtDistribution, Step-FtDistribution, Stop-FtDistribution, Read-FtDistributionLog, Get-FtDistributionProgress, Get-FtDistributionSummary
