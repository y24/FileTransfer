# コマンドラインからの実行（画面を出さずに転送する）
#   FileTransfer.bat -Destination SV-APP01,SV-APP02 -Folder 'C:\work\{datetime}' \\fs01\patches\*.msu
# 終了コード: 0 成功 / 1 転送に失敗（一部の送り先を含む）/ 2 指定の誤り・接続できない・空き容量が足りない
# Ctrl+C で止めると、実行中の robocopy も止める

$script:Usage = @'
使い方:
  FileTransfer.bat -Destination <送り先> -Folder <フォルダ> <送るファイル...>

  -Destination  ホスト名（カンマ区切りで複数可）または このPC
  -Folder       送り先のフォルダ。サーバーなら C:\work\{datetime} のようにサーバー上のパスで書く
  送るファイル   ファイルやフォルダのパス（* ? も使える）。スペースを含むときは "" で囲む

  -Credential <ユーザー名>  ログオンが必要なサーバーに、このアカウントで接続する（パスワードを聞かれる）
  -SaveCredential          そのアカウントを Windows 資格情報マネージャーに保存する
  -KeepLocalCopy           共有のファイルを、この PC にもコピーして残す
  -DisconnectExisting      別のユーザーで接続中（エラー 1219）のサーバーは、その接続を切断してからログオンし直す
  -SkipSpaceCheck          送り先の空き容量が足りなくても転送する
  -Method SMB|WinRM        サーバーへの転送方法（省略すると設定画面で選んだ方法。既定は SMB）
                           WinRM は SMB（ファイル共有）で接続できないサーバー向け。PowerShell リモートで送る
  -WhatIf                  送り先・空き容量・robocopy のコマンドを表示するだけで、転送しない
                           （接続できないサーバーや空き容量の不足があれば、それも表示して終了コード 2）

終了コード: 0 成功 / 1 転送に失敗（一部の送り先を含む）/ 2 指定の誤り・接続できない・空き容量が足りない

例:
  FileTransfer.bat -Destination SV-APP01,SV-APP02 -Folder C:\work\{datetime} \\fs01\patches\2026-10\*.msu
  FileTransfer.bat -Destination このPC -Folder D:\Transfer\{date} \\fs01\release\app\setup.exe
  FileTransfer.bat -Destination SV-APP01 -Folder C:\work\{datetime} -Method WinRM D:\build\app
'@

function Write-FtCli {
    param([string]$Message, [string]$Color = '')
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
}

function Write-FtCliError {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

function Write-FtCliDisconnect {
    param([hashtable]$Result)
    foreach ($connection in $Result.Closed) { Write-FtCli "  $($Result.HostName): 接続を切断しました - $connection" }
    foreach ($connection in $Result.Failed) { Write-FtCliError "  $($Result.HostName): 使用中のため切断できませんでした - $connection" }
    if ($Result.Closed.Count -eq 0 -and $Result.Failed.Count -eq 0) { Write-FtCli "  $($Result.HostName): 切断できる接続はありませんでした" }
    if ($Result.Closed.Count -gt 0) { Write-FtLog ("切断しました: " + ($Result.Closed -join '、')) }
}

# エラー 1219 のときの案内（今ある接続と、-DisconnectExisting）
function Get-FtCliConflictHint {
    param([string]$HostName)
    $connections = @(Get-FtHostConnections -HostName $HostName | ForEach-Object { Format-FtConnection $_ })
    $list = if ($connections.Count -gt 0) { "（接続中: $($connections -join '、')）" } else { '' }
    return "$list -DisconnectExisting を付けると、その接続を切断してから接続し直します。"
}

# 送るファイルの指定を、実在するパスの一覧にする（* ? を展開）
# 戻り値: @{ Items = @{ Path; IsFolder; Size } の配列; Errors }
function Resolve-FtCliSources {
    param([string[]]$Source)
    $items = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($raw in $Source) {
        $spec = "$raw".Trim().Trim('"')
        if (-not $spec) { continue }
        if ($spec.StartsWith('-')) { $errors.Add("不明なオプションです: $spec"); continue }
        $paths = @()
        if ($spec -match '[*?]') {
            $paths = @(Get-ChildItem -Path $spec -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            if ($paths.Count -eq 0) { $errors.Add("一致するファイルがありません: $spec"); continue }
        } else {
            $path = $spec.TrimEnd('\')
            if (-not (Test-Path -LiteralPath $path)) { $errors.Add("見つかりません: $spec"); continue }
            $paths = @((Get-Item -LiteralPath $path -Force).FullName)
        }
        foreach ($path in $paths) {
            if ($seen.ContainsKey($path)) { continue }
            $seen[$path] = $true
            $isFolder = [System.IO.Directory]::Exists($path)
            $name = [System.IO.Path]::GetFileName($path.TrimEnd('\'))
            if (@($items | Where-Object { [System.IO.Path]::GetFileName($_.Path) -ieq $name }).Count -gt 0) {
                $errors.Add("同じ名前のファイルを 2 つ指定しています: $name")
                continue
            }
            $size = if ($isFolder) { (Measure-FtFolder $path).Bytes } else { (New-Object System.IO.FileInfo $path).Length }
            $items.Add(@{ Path = $path; IsFolder = $isFolder; Size = [long]$size })
        }
    }
    return @{ Items = $items.ToArray(); Errors = $errors.ToArray() }
}

function Format-FtCliSeconds {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return ('{0:0.0} 秒' -f $Seconds) }
    return ('{0} 分 {1} 秒' -f [int][Math]::Floor($Seconds / 60), [int]($Seconds % 60))
}

function Invoke-FtCli {
    param(
        [string[]]$Source,
        [string]$Destination,
        [string]$Folder,
        [pscredential]$Credential,
        [switch]$SaveCredential,
        [switch]$KeepLocalCopy,
        [switch]$PlanOnly,
        [switch]$SkipSpaceCheck,
        [switch]$DisconnectExisting,
        [string]$Method,
        [hashtable]$Config,
        [string[]]$ModulePaths
    )
    if (-not $Destination -or -not $Folder -or -not $Source) {
        if ($Destination -or $Folder -or $Source) { Write-FtCliError '-Destination、-Folder、送るファイルをすべて指定してください。' }
        Write-FtCli $script:Usage
        return 2
    }
    # サーバーへの転送方法: -Method > 設定（画面の設定・settings.default.json）
    $method = if ($Method) { $Method.ToLowerInvariant() } else { Get-FtTransferMethod $Config }
    if ($method -notin 'smb', 'winrm') { Write-FtCliError "-Method には SMB か WinRM を指定してください: $Method"; return 2 }
    $winrm = Get-FtWinRmOptions $Config

    # 送るファイル
    $sources = Resolve-FtCliSources $Source
    if ($sources.Errors.Count -gt 0) { $sources.Errors | ForEach-Object { Write-FtCliError $_ }; return 2 }
    $items = $sources.Items
    $totalBytes = 0L
    foreach ($item in $items) { $totalBytes += $item.Size }

    # 送り先
    $now = Get-Date
    $alias = @{}
    $mappings = @($Config.serverShareMappings)
    $resolved = Resolve-FtDestinations -Destination $Destination -Folder $Folder -Now $now -Mappings $mappings -HostAlias $alias -Method $method
    if ($resolved.Error) { Write-FtCliError $resolved.Error; return 2 }
    if ($resolved.IsLocal) { $method = 'local' }

    $connections = New-Object System.Collections.Generic.List[string]
    $credentials = @{}     # WinRM: ホスト名 → 接続に使う資格情報
    $pool = $null
    $distribution = $null
    $stage = $null
    try {
        # 接続確認（必要ならログオン）。-WhatIf のときはログオンも切断もせず、問題は警告として出して計画は表示する
        $problems = @()
        if ($method -eq 'winrm') {
            # WinRM: -Credential のアカウント > 保存済みの資格情報 > Windows のログオンユーザー で接続できるか確かめる
            foreach ($target in $resolved.Targets) {
                $hostName = $target.HostName
                $credential = if ($Credential) {
                    $user = Convert-FtUserForHost -UserName $Credential.UserName -FromHost $resolved.Targets[0].HostName -ToHost $hostName
                    New-Object System.Management.Automation.PSCredential -ArgumentList $user, $Credential.Password
                } else {
                    Get-FtWinRmSavedCredential $hostName
                }
                $access = Test-FtWinRmAccess -HostName $hostName -Credential $credential -WinRm $winrm
                if ($access.Status -eq 'ok') {
                    $credentials[$hostName] = $credential
                    Write-FtCli "  ${hostName}: WinRM で接続できます（$($access.User)）"
                    if ($Credential -and $SaveCredential -and -not $PlanOnly) {
                        $saveCode = Save-FtWinRmCredential -HostName $hostName -Credential $credential
                        if ($saveCode -ne 0) { Write-FtCliError "  ${hostName}: 資格情報を保存できませんでした（エラー $saveCode）" }
                    }
                    continue
                }
                $problems += switch ($access.Status) {
                    'auth' {
                        if ($Credential) { "${hostName}: $($access.Message)（$($credential.UserName)）" }
                        else { "${hostName}: ログオンが必要です。画面でログオンして資格情報を保存するか、-Credential を指定してください。" }
                    }
                    default { "${hostName}: $($access.Message)" }
                }
            }
            if ($problems.Count -gt 0 -and -not $PlanOnly) { $problems | ForEach-Object { Write-FtCliError $_ }; return 2 }
        } elseif (-not $resolved.IsLocal) {
            foreach ($target in $resolved.Targets) {
                $hostName = $target.HostName
                $access = Test-FtShareAccess -ShareRoot $target.ShareRoot
                if ($access.Status -eq 'conflict' -and $DisconnectExisting -and -not $PlanOnly) {
                    Write-FtCliDisconnect (Disconnect-FtHostConnections -HostName $hostName)
                    $access = Test-FtShareAccess -ShareRoot $target.ShareRoot
                }
                if ($access.Status -in 'auth', 'conflict' -and $Credential -and $PlanOnly) {
                    $problems += "${hostName}: ログオンが必要です（実行時に -Credential のアカウントでログオンします）"
                    continue
                }
                if ($access.Status -in 'auth', 'conflict' -and $Credential) {
                    $user = Convert-FtUserForHost -UserName $Credential.UserName -FromHost $resolved.Targets[0].HostName -ToHost $hostName
                    $logon = Connect-FtShare -HostName $hostName -ShareRoot $target.ShareRoot -UserName $user -Password $Credential.Password -Save:$SaveCredential
                    if ($logon.Code -eq 1219 -and $DisconnectExisting) {
                        # 別のユーザーで接続中: その接続を切断してからもう一度
                        Write-FtCliDisconnect (Disconnect-FtHostConnections -HostName $hostName)
                        $logon = Connect-FtShare -HostName $hostName -ShareRoot $target.ShareRoot -UserName $user -Password $Credential.Password -Save:$SaveCredential
                    }
                    if ($logon.Code -eq 0) {
                        $connections.Add($logon.Root)
                        if ($logon.ConnectName -ine $hostName) { $alias[$hostName] = $logon.ConnectName }
                        Write-FtCli "  ${hostName}: $user でログオンしました"
                        continue
                    }
                    $info = Get-FtErrorInfo -Code $logon.Code -Target $hostName -Server
                    $hint = if ($logon.Code -eq 1219 -and -not $DisconnectExisting) { Get-FtCliConflictHint $hostName } else { '' }
                    $problems += "${hostName}: $($info.Short)（エラー $($logon.Code)）$hint"
                    continue
                }
                switch ($access.Status) {
                    'ok'          { }
                    'auth'        { $problems += "${hostName}: ログオンが必要です。画面でログオンして資格情報を保存するか、-Credential を指定してください。" }
                    'conflict'    { $problems += "${hostName}: 別のユーザーで接続中です。-Credential を指定してください。$(Get-FtCliConflictHint $hostName)" }
                    'unreachable' { $problems += "$($target.HostName): 接続できません（ホスト名と、ファイル共有の 445 番ポートを確認してください）" }
                    'noshare'     { $problems += "$($target.HostName): $($target.ShareRoot) が見つかりません（管理共有が無効の可能性があります）" }
                    default       { $problems += "$($target.HostName): 確認でエラーが発生しました（エラー $($access.Code)）" }
                }
            }
            if ($problems.Count -gt 0 -and -not $PlanOnly) { $problems | ForEach-Object { Write-FtCliError $_ }; return 2 }
            if ($alias.Count -gt 0) {
                $resolved = Resolve-FtDestinations -Destination $Destination -Folder $Folder -Now $now -Mappings $mappings -HostAlias $alias
            }
        }

        $targets = @($resolved.Targets | ForEach-Object {
            @{
                Name = $(if ($_.IsLocal) { Get-FtLocalLabel } else { $_.HostName }); HostName = $_.HostName; IsLocal = $_.IsLocal; Dest = $_.Path
                Method = $method; Credential = $credentials[$_.HostName]
            }
        })
        $transfer = $Config.transfer
        $stage = Get-FtStageFolder -Items $items -TargetCount $targets.Count -IsLocal $resolved.IsLocal `
            -KeepLocalCopy ($KeepLocalCopy -or [bool]$transfer.keepLocalCopy) -LocalCopyFolder "$($transfer.localCopyFolder)" -Now $now
        $options = @{
            RetryCount          = [int]$transfer.retryCount
            RetryWaitSec        = [int]$transfer.retryWaitSec
            Threads             = [int]$transfer.threadsForFolders
            LargeThresholdBytes = [long]$transfer.unbufferedThresholdMB * 1MB
            ParallelHosts       = [int]$transfer.parallelHosts
            WinRm               = $winrm
        }

        $via = if ($method -eq 'winrm') { '（WinRM）' } else { '' }
        Write-FtCli ("{0} 件（{1}）→ {2} か所{3}" -f $items.Count, [FileTransfer.FileItem]::FormatSize($totalBytes), $targets.Count, $via) 'Cyan'
        foreach ($target in $targets) { Write-FtCli "  $($target.Name): $($target.Dest)" }
        if ($stage) { Write-FtCli "  （共有のファイルは、先にこの PC に取得します: $($stage.Folder)）" }

        # 空き容量（WinRM で接続できなかった台は確認しない）
        $spaceTargets = @($targets | Where-Object { $_.Method -ne 'winrm' -or $credentials.ContainsKey($_.HostName) })
        $space = Test-FtFreeSpace -Items $items -Targets $spaceTargets -StageFolder $(if ($stage) { $stage.Folder } else { '' }) -WinRm $winrm
        $shortages = @($space | Where-Object { $_.Short })
        foreach ($result in @($space | Where-Object { $_.Free -lt 0 })) { Write-FtLog "空き容量を確認できませんでした: $($result.Name) $($result.Path)" }
        if ($PlanOnly) {
            Write-FtCli ''
            Write-FtCli '空き容量:' 'Cyan'
            foreach ($result in $space) { Write-FtCli ("  " + (Format-FtFreeSpace $result)) $(if ($result.Short) { 'Yellow' } else { '' }) }
            foreach ($shortage in $shortages) { $problems += '空き容量が足りません：' + (Format-FtFreeSpace $shortage) }
        } elseif ($shortages.Count -gt 0) {
            foreach ($shortage in $shortages) { Write-FtLog "空き容量不足: $(Format-FtFreeSpace $shortage)" }
            if ($SkipSpaceCheck) {
                foreach ($shortage in $shortages) { Write-FtCli ('空き容量が足りませんが、-SkipSpaceCheck のため転送します：' + (Format-FtFreeSpace $shortage)) 'Yellow' }
            } else {
                foreach ($shortage in $shortages) { Write-FtCliError ('空き容量が足りません：' + (Format-FtFreeSpace $shortage)) }
                Write-FtCliError '足りなくても転送するときは -SkipSpaceCheck を付けてください。'
                return 2
            }
        }

        if ($PlanOnly) {
            $plan = New-FtDistribution -Items $items -Targets $targets -StageFolder $(if ($stage) { $stage.Folder } else { '' }) -Options $options
            Write-FtCli ''
            $heading = if ($method -eq 'winrm') { '実行する転送（-WhatIf のため実行しません）:' } else { '実行する robocopy（-WhatIf のため実行しません）:' }
            Write-FtCli $heading 'Cyan'
            if ($plan.Stage) { foreach ($step in $plan.Stage.Steps) { Write-FtCli ("  [{0}] robocopy {1}" -f $plan.Stage.Name, (Get-FtRobocopyArguments -Step $step -RetryCount $options.RetryCount -RetryWaitSec $options.RetryWaitSec -Threads $options.Threads)) } }
            foreach ($unit in $plan.Hosts) {
                foreach ($step in $unit.Steps) {
                    $line = if ($unit.Method -eq 'winrm') { Format-FtWinRmStep $step } else { 'robocopy ' + (Get-FtRobocopyArguments -Step $step -RetryCount $options.RetryCount -RetryWaitSec $options.RetryWaitSec -Threads $options.Threads) }
                    Write-FtCli ("  [{0}] {1}" -f $unit.Name, $line)
                }
            }
            if ($problems.Count -gt 0) {
                Write-FtCli ''
                Write-FtCli '問題（このままでは転送できません）:' 'Yellow'
                $problems | ForEach-Object { Write-FtCli "  $_" 'Yellow' }
                return 2
            }
            return 0
        }

        # 転送
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
        $sessionState.ImportPSModule($ModulePaths)
        $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(2, $options.ParallelHosts + 1), $sessionState, $Host)
        $pool.Open()
        $distribution = New-FtDistribution -Items $items -Targets $targets -StageFolder $(if ($stage) { $stage.Folder } else { '' }) -Options $options -Pool $pool
        Write-FtLog ("コマンドラインで転送開始: {0} 件（{1}）→ {2}" -f $items.Count, [FileTransfer.FileItem]::FormatSize($totalBytes), (($targets | ForEach-Object { $_.Dest }) -join ', '))
        foreach ($item in $items) { Write-FtLog "  $($item.Path)" }

        $reported = @{}
        while ($distribution.Status -eq 'running') {
            Step-FtDistribution $distribution
            $lines = Read-FtDistributionLog $distribution
            if ($lines.Count -gt 0) { Write-FtLog $lines; $lines | ForEach-Object { Write-FtCli $_ 'DarkGray' } }
            foreach ($unit in $distribution.Hosts) {
                if ($unit.Status -in 'success', 'failed' -and -not $reported.ContainsKey($unit.Name)) {
                    $reported[$unit.Name] = $true
                    if ($unit.Status -eq 'success') { Write-FtCli ("{0}: 完了（{1}）" -f $unit.Name, (Format-FtCliSeconds $unit.Elapsed)) 'Green' }
                    else {
                        $info = Get-FtErrorInfo -Code ([int]$unit.Result.Code) -Target $unit.Name -Missing @($unit.Result.Missing) -Fallback "$($unit.Result.Message)" -Server:(-not $unit.IsLocal) -Method $unit.Method
                        Write-FtCliError ("{0}: 失敗 - {1}" -f $unit.Name, $info.Short)
                    }
                }
            }
            $progress = Get-FtDistributionProgress $distribution
            if ($progress.BytesTotal -gt 0) {
                $percent = [int][Math]::Floor(100 * $progress.BytesDone / $progress.BytesTotal)
                $status = if ($progress.Staging) { 'この PC へ取得中' } else { "{0}/{1} か所完了" -f $progress.HostsSucceeded, $progress.HostsTotal }
                Write-Progress -Activity 'FileTransfer' -Status "$percent%・$status" -PercentComplete ([Math]::Min(100, $percent))
            }
            if ($distribution.Status -eq 'running') { Start-Sleep -Milliseconds 200 }
        }
        Write-Progress -Activity 'FileTransfer' -Completed
        $lines = Read-FtDistributionLog $distribution
        if ($lines.Count -gt 0) { Write-FtLog $lines; $lines | ForEach-Object { Write-FtCli $_ 'DarkGray' } }

        $summary = Get-FtDistributionSummary $distribution
        if ($summary.StageFailed) {
            $info = Get-FtErrorInfo -Code ([int]$distribution.Stage.Result.Code) -Target 'この PC' -Missing @($distribution.Stage.Result.Missing) -Fallback "$($distribution.Stage.Result.Message)"
            Write-FtCliError "この PC への取得に失敗しました - $($info.Short)"
        }
        $elapsed = Format-FtCliSeconds $summary.Elapsed
        switch ($summary.Status) {
            'success' {
                Write-FtCli ("完了: {0} 件を {1} か所に転送しました（{2}）" -f $items.Count, $targets.Count, $elapsed) 'Green'
                Write-FtLog "完了（コマンドライン）: $($targets.Count) か所・$elapsed"
                return 0
            }
            default {
                Write-FtCliError ("失敗: {0} か所中 {1} か所で失敗しました（{2}）" -f $targets.Count, ($targets.Count - $summary.Succeeded.Count), $elapsed)
                Write-FtLog "失敗（コマンドライン）: 成功 $($summary.Succeeded.Count) / $($targets.Count) か所"
                return 1
            }
        }
    } finally {
        # Ctrl+C で止められたときも robocopy を止める
        if ($distribution -and $distribution.Status -eq 'running') {
            Write-FtCliError '中止しています…'
            Stop-FtDistribution $distribution
            Write-FtLog '中止しました（コマンドライン）'
        }
        if ($pool) { $pool.Close(); $pool.Dispose() }
        foreach ($root in $connections) { Disconnect-FtShare $root }
        if ($stage -and $stage.Temporary -and -not $PlanOnly) { Remove-FtStageFolder $stage.Folder }
    }
}

Export-ModuleMember -Function Invoke-FtCli, Resolve-FtCliSources
