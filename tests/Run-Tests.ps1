#Requires -Version 5.1
<#
.SYNOPSIS
    FileTransfer の自動テスト（Pester 不要）
.DESCRIPTION
    Windows PowerShell 5.1 で実行する:
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
    一時フォルダの中で実際に robocopy を動かす。サーバーへの接続は行わない。
#>
param([string]$WorkDir = (Join-Path $env:TEMP ('FileTransferTests_' + [guid]::NewGuid().ToString('N').Substring(0, 8))))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:FILETRANSFER_CONFIG = Join-Path $WorkDir 'config\settings.json'
$env:FILETRANSFER_LOGDIR = Join-Path $WorkDir 'logs'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

if (-not ('FileTransfer.Native' -as [type])) {
    Add-Type -Path (Join-Path $root 'lib\Native.cs'), (Join-Path $root 'lib\Models.cs')
}
$modulePaths = @('Config', 'PathResolver', 'Connection', 'TransferEngine', 'Distribution', 'Log', 'Cli') | ForEach-Object { Join-Path $root "lib\$_.psm1" }
foreach ($modulePath in $modulePaths) { Import-Module $modulePath -Force -DisableNameChecking }
# 自分自身の管理共有（\\127.0.0.1\C$）経由で読めるときは、UNC のコピー元として使う
$uncWorkDir = if ($WorkDir -match '^[Cc]:\\' -and [FileTransfer.Native]::GetPathError('\\127.0.0.1\C$\') -eq 0) { '\\127.0.0.1\C$' + $WorkDir.Substring(2) } else { $null }

$script:Passed = 0
$script:Failed = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ("$Expected" -ceq "$Actual") { $script:Passed++ }
    else { $script:Failed++; Write-Host "FAIL: $Name`n  expected: [$Expected]`n  actual:   [$Actual]" -ForegroundColor Red }
}
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:Passed++ } else { $script:Failed++; Write-Host "FAIL: $Name" -ForegroundColor Red }
}
function Section { param([string]$Name) Write-Host "--- $Name" -ForegroundColor Cyan }

$now = [datetime]'2026-10-15 14:32:10'

Section 'Expand-FtTemplate'
Assert-Equal '20261015_1432' (Expand-FtTemplate '{datetime}' -Now $now) 'datetime'
Assert-Equal '20261015' (Expand-FtTemplate '{date}' -Now $now) 'date'
Assert-Equal '1432' (Expand-FtTemplate '{time}' -Now $now) 'time'
Assert-Equal '2026-10-15_143210' (Expand-FtTemplate '{now:yyyy-MM-dd_HHmmss}' -Now $now) 'now:format'
Assert-Equal 'C:\Work\20261015_KB5031234' (Expand-FtTemplate 'C:\Work\{date}_KB5031234' -Now $now) 'fixed text'
Assert-Equal 'yamada_SV-APP01' (Expand-FtTemplate '{user}_{host}' -Now $now -HostName 'SV-APP01' -UserName 'yamada') 'user/host'
Assert-Equal '{unknown}' (Expand-FtTemplate '{unknown}' -Now $now) 'unknown token is kept'
Assert-Equal '20261015' (Expand-FtTemplate '{DATE}' -Now $now) 'case-insensitive'

Section 'Resolve-FtDestination'
$r = Resolve-FtDestination -Destination 'SV-APP01' -Folder 'C:\Work\{datetime}' -Now $now
Assert-Equal '\\SV-APP01\C$\Work\20261015_1432' $r.Path 'server path'
Assert-Equal '\\SV-APP01\C$' $r.ShareRoot 'server share root'
Assert-True (-not $r.IsLocal) 'server is not local'
$r = Resolve-FtDestination -Destination 'sv-app01' -Folder 'd:\deploy\' -Now $now
Assert-Equal '\\SV-APP01\D$\deploy' $r.Path 'lowercase host / drive / trailing backslash'
$r = Resolve-FtDestination -Destination 'SV-APP01' -Folder 'C:\' -Now $now
Assert-Equal '\\SV-APP01\C$' $r.Path 'server drive root'
$r = Resolve-FtDestination -Destination 'SV-APP01' -Folder 'C:/Work/x' -Now $now
Assert-Equal '\\SV-APP01\C$\Work\x' $r.Path 'forward slashes'
$mappings = @(@{ host = 'SV-LEGACY01'; serverPath = 'C:\Work'; share = '\\SV-LEGACY01\Work$' })
$r = Resolve-FtDestination -Destination 'SV-LEGACY01' -Folder 'C:\Work\{date}' -Now $now -Mappings $mappings
Assert-Equal '\\SV-LEGACY01\Work$\20261015' $r.Path 'share mapping'
Assert-Equal '\\SV-LEGACY01\Work$' $r.ShareRoot 'share mapping root'
$r = Resolve-FtDestination -Destination 'SV-LEGACY01' -Folder 'C:\Workspace' -Now $now -Mappings $mappings
Assert-Equal '\\SV-LEGACY01\C$\Workspace' $r.Path 'mapping matches whole folder names only'
$r = Resolve-FtDestination -Destination 'SV-APP01' -Folder '\\SV-APP01\Deploy$\{date}' -Now $now
Assert-Equal '\\SV-APP01\Deploy$\20261015' $r.Path 'server with UNC folder'
$r = Resolve-FtDestination -Destination 'SV-WEB01' -Folder 'C:\Work' -Now $now -HostAlias @{ 'SV-WEB01' = 'sv-web01.corp.example' }
Assert-Equal '\\sv-web01.corp.example\C$\Work' $r.Path 'host alias'
$r = Resolve-FtDestination -Destination 'このPC' -Folder 'D:\Transfer\{date}' -Now $now
Assert-Equal 'D:\Transfer\20261015' $r.Path 'local path'
Assert-True $r.IsLocal 'local flag'
$r = Resolve-FtDestination -Destination ' localhost ' -Folder '\\fs01\work\yamada\{date}' -Now $now
Assert-Equal '\\fs01\work\yamada\20261015' $r.Path 'local UNC (share)'
$r = Resolve-FtDestination -Destination 'このPC' -Folder '%USERPROFILE%\x' -Now $now
Assert-Equal "$env:USERPROFILE\x" $r.Path 'environment variable (local only)'
$r = Resolve-FtDestination -Destination 'このPC' -Folder 'D:\' -Now $now
Assert-Equal 'D:\' $r.Path 'local drive root'
Assert-True ([bool](Resolve-FtDestination -Destination '' -Folder 'C:\Work').Error) 'empty host is an error'
Assert-True ([bool](Resolve-FtDestination -Destination 'SV APP' -Folder 'C:\Work').Error) 'invalid host is an error'
Assert-True ([bool](Resolve-FtDestination -Destination 'SV-APP01' -Folder '').Error) 'empty folder is an error'
Assert-True ([bool](Resolve-FtDestination -Destination 'SV-APP01' -Folder 'C:\Work\a?b').Error) 'invalid character'
Assert-True ([bool](Resolve-FtDestination -Destination 'SV-APP01' -Folder 'Work').Error) 'relative path'
Assert-True ([bool](Resolve-FtDestination -Destination 'SV-APP01' -Folder 'C:\Work\{now:HH:mm}' -Now $now).Error) 'template that produces a colon'
Assert-True ([bool](Resolve-FtDestination -Destination 'このPC' -Folder 'Transfer').Error) 'local relative path'

Section 'Multiple destinations'
Assert-Equal 'SV-APP01|sv-app02|SV-DB02' ((Split-FtDestinations 'SV-APP01, sv-app02;SV-DB02  sv-app01') -join '|') 'split by comma, semicolon, space; duplicates removed'
Assert-Equal 'このPC' ((Split-FtDestinations 'この PC') -join '|') 'この PC with a space'
Assert-Equal 'SV-APP01, SV-APP02' (Format-FtDestinations @('sv-app01', 'SV-APP02')) 'format'
$r = Resolve-FtDestinations -Destination 'SV-APP01, SV-APP02' -Folder 'C:\Work\{datetime}' -Now $now
Assert-Equal '\\SV-APP01\C$\Work\20261015_1432|\\SV-APP02\C$\Work\20261015_1432' (($r.Targets | ForEach-Object { $_.Path }) -join '|') 'one path per server, same timestamp'
Assert-True ($r.IsMulti -and -not $r.IsLocal -and -not $r.Error) 'multi flags'
$r = Resolve-FtDestinations -Destination 'SV-APP01,SV-APP02' -Folder '\\{host}\Deploy$\{date}' -Now $now
Assert-Equal '\\SV-APP01\Deploy$\20261015|\\SV-APP02\Deploy$\20261015' (($r.Targets | ForEach-Object { $_.Path }) -join '|') 'UNC with {host} differs per server'
Assert-True ([bool](Resolve-FtDestinations -Destination 'SV-APP01,SV-APP02' -Folder '\\fs01\work\x').Error) 'same UNC for every server is an error'
Assert-True ((Resolve-FtDestinations -Destination 'このPC, SV-APP01' -Folder 'C:\Work').Error -like '*このPC*') 'this PC and servers cannot be mixed'
Assert-True ((Resolve-FtDestinations -Destination 'SV-APP01, SV_APP 02!' -Folder 'C:\Work').Error -like '*02!*') 'invalid host name is named'
$r = Resolve-FtDestinations -Destination 'このPC' -Folder 'D:\Transfer\{date}' -Now $now
Assert-True ($r.IsLocal -and $r.Targets.Count -eq 1 -and $r.Targets[0].Path -eq 'D:\Transfer\20261015') 'single local destination'
Assert-True ([bool](Resolve-FtDestinations -Destination '' -Folder 'C:\Work').Error) 'empty destination'

Section 'Config'
Assert-Equal 'b|a|c' ((Add-FtHistory @('a', 'B', 'c') 'b') -join '|') 'history moves an existing item to the top (case-insensitive)'
Assert-Equal 3 (Add-FtHistory @('a', 'b', 'c', 'd') 'x' -Max 3).Count 'history max'
Assert-Equal 'a' ((Add-FtHistory @('a') '  ') -join '|') 'blank is ignored'
$merged = Merge-FtConfig @{ a = 1; nested = @{ x = 1; y = 2 } } @{ nested = @{ y = 3 }; b = 2 }
Assert-Equal '1|1|3|2' ('{0}|{1}|{2}|{3}' -f $merged.a, $merged.nested.x, $merged.nested.y, $merged.b) 'deep merge'
$config = Get-FtConfig -AppRoot $root
Assert-True ($config.history.serverFolders -contains 'C:\Work\{datetime}') 'settings.default.json is read'
$config.history.destinations = @('SV-APP01')
$config.last = @{ destination = 'SV-APP01'; folder = 'C:\Work\{date}' }
Save-FtConfig $config
$reloaded = Get-FtConfig -AppRoot $root
Assert-Equal 'SV-APP01' (@($reloaded.history.destinations) -join '|') 'single-item array survives a save'
Assert-Equal 'C:\Work\{date}' $reloaded.last.folder 'save and reload'
$userFile = Get-Content -LiteralPath $env:FILETRANSFER_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($null -eq $userFile.transfer) 'transfer settings are not copied into the user file'
# ユーザーが自分で書いた項目は保存しても残る
$custom = ConvertTo-FtHashtable $userFile
$custom.transfer = @{ keepLocalCopy = $true }
[IO.File]::WriteAllText($env:FILETRANSFER_CONFIG, ($custom | ConvertTo-Json -Depth 8), [Text.Encoding]::UTF8)
$config = Get-FtConfig -AppRoot $root
Assert-True ($config.transfer.keepLocalCopy -and $config.transfer.retryCount -eq 2) 'user override merges with defaults'
Save-FtConfig $config
Assert-True ((Get-Content -LiteralPath $env:FILETRANSFER_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json).transfer.keepLocalCopy) 'user override is kept on save'

Section 'FileItem'
Assert-Equal '0 KB' ([FileTransfer.FileItem]::FormatSize(0)) 'size 0'
Assert-Equal '1 KB' ([FileTransfer.FileItem]::FormatSize(10)) 'size 10 B'
Assert-Equal '2.1 MB' ([FileTransfer.FileItem]::FormatSize(2.1MB)) 'size MB'
Assert-Equal '1.50 GB' ([FileTransfer.FileItem]::FormatSize(1.5GB)) 'size GB'
$item = New-Object FileTransfer.FileItem 'C:\x\a.zip', $false
$changed = New-Object System.Collections.Generic.List[string]
$item.add_PropertyChanged({ param($s, $e) $changed.Add($e.PropertyName) })
$item.State = 'done'
Assert-Equal ([string][char]0xE73E) $item.Glyph 'done glyph'
Assert-True ($changed.Contains('Glyph')) 'Glyph change is notified'
Assert-Equal 'a.zip' $item.Name 'name'

Section 'robocopy output'
$line = ConvertFrom-FtRobocopyLine "`t    New File  `t`t314572800`tC:\src\big file.bin"
Assert-Equal 'file|314572800|C:\src\big file.bin|New File' ('{0}|{1}|{2}|{3}' -f $line.Type, $line.Size, $line.Path, $line.Class) 'file line'
Assert-Equal 'progress|12.3' ('{0}|{1}' -f (ConvertFrom-FtRobocopyLine '  12.3%').Type, (ConvertFrom-FtRobocopyLine '  12.3%').Percent) 'progress line'
Assert-Equal 100 (ConvertFrom-FtRobocopyLine '100%  ').Percent 'progress 100%'
$line = ConvertFrom-FtRobocopyLine '2026/10/15 03:10:05 ERROR 5 (0x00000005) Copying File C:\src\a.txt'
Assert-Equal 'error|5' ('{0}|{1}' -f $line.Type, $line.Code) 'error line'
$line = ConvertFrom-FtRobocopyLine '2026/10/15 03:10:05 エラー 53 (0x00000035) コピー先ディレクトリにアクセスしています \\x\y'
Assert-Equal 'error|53' ('{0}|{1}' -f $line.Type, $line.Code) 'localized error line'
Assert-Equal 'text' (ConvertFrom-FtRobocopyLine 'Access is denied.').Type 'text line'

Section 'Plan'
Assert-Equal 'C:\' (Get-FtParentPath 'C:\a.txt') 'parent of a file in a drive root'
Assert-Equal '\\h\s' (Get-FtParentPath '\\h\s\a.txt') 'parent in a share root'
Assert-Equal '"C:\."' (ConvertTo-FtRobocopyPath 'C:\') 'drive root is quoted safely'
Assert-Equal '"D:\x"' (ConvertTo-FtRobocopyPath 'D:\x\') 'trailing backslash removed'
$items = @(
    @{ Path = '\\fs01\patches\KB1.msu'; IsFolder = $false; Size = 300MB },
    @{ Path = 'C:\Users\u\Downloads\config.zip'; IsFolder = $false; Size = 2MB },
    @{ Path = '\\fs01\patches\KB2.msu'; IsFolder = $false; Size = 10MB },
    @{ Path = 'C:\build\app'; IsFolder = $true; Size = 50MB }
)
$steps = New-FtTransferPlan -Items $items -Destination '\\SV\C$\Work\x'
Assert-Equal 3 $steps.Count 'files grouped by parent folder, folder separately'
Assert-Equal 'KB1.msu|KB2.msu' ($steps[0].Files -join '|') 'group keeps both files from the same folder'
Assert-True $steps[0].Large 'large flag'
Assert-True (-not $steps[1].Large) 'small group is not large'
Assert-Equal '\\SV\C$\Work\x\app' $steps[2].Dest 'folder goes into a subfolder with the same name'
$arguments = Get-FtRobocopyArguments -Step $steps[0]
Assert-True ($arguments -like '"\\fs01\patches" "\\SV\C$\Work\x" "KB1.msu" "KB2.msu" /R:2 /W:3 /J *') 'file arguments'
Assert-True ((Get-FtRobocopyArguments -Step $steps[2]) -like '* /E /MT:8 *') 'folder arguments'
$staged = New-FtTransferPlan -Items $items -Destination '\\SV\C$\Work\x' -StageFolder 'D:\Transfer\x'
# 1: 共有 → ローカル（KB1, KB2）  2: ローカルのコピー → サーバー（KB1, KB2）  3: config.zip  4: app フォルダ
Assert-Equal 4 $staged.Count 'staging adds one step'
Assert-True (-not $staged[0].Final -and $staged[0].Dest -eq 'D:\Transfer\x' -and ($staged[0].Files -join '|') -eq 'KB1.msu|KB2.msu') 'staging step goes to the local folder'
Assert-True ($staged[1].Final -and $staged[1].Source -eq 'D:\Transfer\x' -and ($staged[1].Files -join '|') -eq 'KB1.msu|KB2.msu') 'final step reads from the local copy'
Assert-Equal 'C:\Users\u\Downloads' $staged[2].Source 'local files are not staged'
Assert-True ($staged[1].Items -contains '\\fs01\patches\KB1.msu') 'final step still reports the original items'
$stageOnly = New-FtTransferPlan -Items $items -StageFolder 'D:\Transfer\x' -StageOnly
Assert-True ($stageOnly.Count -eq 1 -and -not $stageOnly[0].Final) '-StageOnly makes only the staging step'
$fromStage = New-FtTransferPlan -Items $items -Destination '\\SV\C$\Work\x' -StageFolder 'D:\Transfer\x' -FromStage
Assert-True ($fromStage.Count -eq 3 -and $fromStage[0].Source -eq 'D:\Transfer\x' -and $fromStage[0].Final) '-FromStage reads shared files from the local copy'
Assert-True ($null -eq (Get-FtStageFolder -Items $items -TargetCount 1 -IsLocal $false -KeepLocalCopy $false -LocalCopyFolder 'x' -Now $now)) 'one server: no staging'
$stageInfo = Get-FtStageFolder -Items $items -TargetCount 2 -IsLocal $false -KeepLocalCopy $false -LocalCopyFolder 'x' -Now $now
Assert-True ($stageInfo.Temporary -and $stageInfo.Folder -like '*\FileTransfer\stage_20261015_143210') 'two servers: temporary staging'
$stageInfo = Get-FtStageFolder -Items $items -TargetCount 1 -IsLocal $false -KeepLocalCopy $true -LocalCopyFolder 'D:\Transfer\{date}' -Now $now
Assert-True (-not $stageInfo.Temporary -and $stageInfo.Folder -eq 'D:\Transfer\20261015') 'keepLocalCopy: kept staging folder'
Assert-True ($null -eq (Get-FtStageFolder -Items @($items[1]) -TargetCount 3 -IsLocal $false -KeepLocalCopy $false -LocalCopyFolder 'x' -Now $now)) 'no shared files: no staging'

Section 'Error messages'
Assert-True ((Get-FtErrorInfo -Code 5 -Target 'SV-WEB01' -Server).Short -like 'SV-WEB01*') 'access denied'
Assert-True (Get-FtErrorInfo -Code 5 -Server).NeedsLogon 'access denied on a server offers logon'
Assert-True (-not (Get-FtErrorInfo -Code 5).NeedsLogon) 'access denied on this PC does not offer logon'
Assert-True ((Get-FtErrorInfo -Code 5).Detail -notlike '*管理共有*') 'local access denied does not mention admin shares'
Assert-True (-not (Get-FtErrorInfo -Code 112).NeedsLogon) 'disk full does not offer logon'
Assert-True ((Get-FtErrorInfo -Code 0 -Missing @('a.txt')).Detail -like '*a.txt*') 'missing files listed'
Assert-True ((Get-FtErrorInfo -Code 9999).Short -like '*9999*') 'unknown code'

Section 'Connection'
Assert-Equal 'auth' (Get-FtAccessStatus 1326) 'logon failure'
Assert-Equal 'auth' (Get-FtAccessStatus 5) 'access denied'
Assert-Equal 'unreachable' (Get-FtAccessStatus 53) 'bad net path'
Assert-Equal 'noshare' (Get-FtAccessStatus 67) 'bad net name'
Assert-Equal 'conflict' (Get-FtAccessStatus 1219) 'credential conflict'
Assert-Equal 'SV-APP02\Administrator' (Convert-FtUserForHost 'SV-APP01\Administrator' 'SV-APP01' 'SV-APP02') 'local account follows the server name'
Assert-Equal 'SV-APP02\Administrator' (Convert-FtUserForHost '.\Administrator' 'SV-APP01' 'SV-APP02') '.\ local account'
Assert-Equal 'CORP\yamada' (Convert-FtUserForHost 'CORP\yamada' 'SV-APP01' 'SV-APP02') 'domain account is unchanged'
Assert-Equal 'yamada@corp.example' (Convert-FtUserForHost 'yamada@corp.example' 'SV-APP01' 'SV-APP02') 'UPN is unchanged'
$watch = [Diagnostics.Stopwatch]::StartNew()
$access = Test-FtShareAccess '\\ft-nonexistent-host.invalid\C$' -TimeoutMs 1500
Assert-Equal 'unreachable' $access.Status 'unknown host is unreachable'
Assert-True ($watch.ElapsedMilliseconds -lt 5000) "unknown host check returns quickly ($($watch.ElapsedMilliseconds) ms)"
Assert-True ($null -eq (Get-FtSavedUser 'FT-TEST-NO-SUCH-CREDENTIAL')) 'no saved credential'
Write-Host ("    (info) \\localhost\C$ : {0}" -f (Test-FtShareAccess '\\localhost\C$').Status)

Section 'Transfer (local robocopy)'
$src = Join-Path $WorkDir 'src'
New-Item -ItemType Directory -Path "$src\folder\sub" -Force | Out-Null
$big = Join-Path $src 'big file.bin'
$stream = [IO.File]::Create($big); $stream.SetLength(40MB); $stream.Close()
[IO.File]::WriteAllText("$src\日本語ファイル.txt", 'hello')
[IO.File]::WriteAllText("$src\folder\a.txt", 'a')
[IO.File]::WriteAllText("$src\folder\sub\b.txt", 'bb')
$measure = Measure-FtFolder "$src\folder"
Assert-Equal '2|3' ('{0}|{1}' -f $measure.Files, $measure.Bytes) 'Measure-FtFolder'

function New-TestSync {
    [hashtable]::Synchronized(@{
        Cancel = $false; ProcessId = 0; BytesTotal = 0L; BytesDone = 0L; CurrentItem = $null; CurrentFraction = 0.0; StepIndex = 0
        Completed = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Result = $null
    })
}
$transferItems = @(
    @{ Path = $big; IsFolder = $false; Size = 40MB },
    @{ Path = "$src\日本語ファイル.txt"; IsFolder = $false; Size = 5 },
    @{ Path = "$src\folder"; IsFolder = $true; Size = 3 }
)
$dest = Join-Path $WorkDir 'dest\20261015_1432'
$sync = New-TestSync
$result = Invoke-FtTransferPlan -Steps (New-FtTransferPlan -Items $transferItems -Destination $dest -LargeThresholdBytes 10MB) -Sync $sync
Assert-Equal 'success' $result.Status 'transfer succeeds'
Assert-True (Test-Path -LiteralPath "$dest\big file.bin") 'big file copied'
Assert-True (Test-Path -LiteralPath "$dest\日本語ファイル.txt") 'Japanese file name copied'
Assert-True (Test-Path -LiteralPath "$dest\folder\sub\b.txt") 'folder copied recursively'
Assert-Equal $sync.BytesTotal $sync.BytesDone 'progress reaches 100%'
$completed = @($sync.Completed.ToArray())
Assert-True ($completed -contains $big -and $completed -contains "$src\folder") 'completed items reported'
$logLines = @($sync.Log.ToArray())
Assert-True (@($logLines | Where-Object { $_ -like '*big file.bin*' }).Count -gt 0) 'log contains copied files'
Assert-True (@($logLines | Where-Object { $_ -like '*日本語ファイル.txt*' }).Count -gt 0) 'log decodes Japanese file names'

$sync = New-TestSync
$result = Invoke-FtTransferPlan -Steps (New-FtTransferPlan -Items $transferItems -Destination $dest) -Sync $sync
Assert-Equal 'success' $result.Status 'second run (all files same) succeeds'

$sync = New-TestSync
$missingItems = @(@{ Path = "$src\deleted.txt"; IsFolder = $false; Size = 1 })
$result = Invoke-FtTransferPlan -Steps (New-FtTransferPlan -Items $missingItems -Destination $dest) -Sync $sync
Assert-Equal 'failed|deleted.txt' ('{0}|{1}' -f $result.Status, ($result.Missing -join ',')) 'missing source file is reported'

$sync = New-TestSync
$result = Invoke-FtTransferPlan -Steps (New-FtTransferPlan -Items @(@{ Path = "$WorkDir\no-such-dir\x.txt"; IsFolder = $false; Size = 1 }) -Destination $dest) -Sync $sync
Assert-Equal 'failed|2' ('{0}|{1}' -f $result.Status, $result.Code) 'missing source folder gives error 2'

$sync = New-TestSync
$sync.Cancel = $true
$result = Invoke-FtTransferPlan -Steps (New-FtTransferPlan -Items $transferItems -Destination "$WorkDir\dest2") -Sync $sync
Assert-Equal 'canceled' $result.Status 'cancel before start'

Section 'Cancel while copying (background runspace, like the app)'
$huge = Join-Path $src 'huge.bin'
$stream = [IO.File]::Create($huge); $stream.SetLength(2GB); $stream.Close()
$sync = New-TestSync
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$ps = [powershell]::Create()
$ps.Runspace = $runspace
[void]$ps.AddScript({
    param($Root, $Steps, $Sync)
    Add-Type -Path (Join-Path $Root 'lib\Native.cs'), (Join-Path $Root 'lib\Models.cs') -ErrorAction SilentlyContinue
    Import-Module (Join-Path $Root 'lib\TransferEngine.psm1') -DisableNameChecking
    Invoke-FtTransferPlan -Steps $Steps -Sync $Sync
}).AddArgument($root).AddArgument((New-FtTransferPlan -Items @(@{ Path = $huge; IsFolder = $false; Size = 2GB }) -Destination "$WorkDir\dest3" -LargeThresholdBytes 1GB)).AddArgument($sync)
$handle = $ps.BeginInvoke()
$watch = [Diagnostics.Stopwatch]::StartNew()
while ($sync.ProcessId -eq 0 -and $watch.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 50 }
while ([long]$sync.BytesDone -eq 0 -and -not $handle.IsCompleted -and $watch.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50 }
$progressSeen = [long]$sync.BytesDone
$sync.Cancel = $true
try { (Get-Process -Id $sync.ProcessId -ErrorAction Stop).Kill() } catch { }
[void]$handle.AsyncWaitHandle.WaitOne(15000)
$ps.Dispose(); $runspace.Dispose()
if ($null -ne $sync.Result -and $sync.Result.Status -eq 'success') {
    Write-Host '    (info) copy finished before cancel; cancel path not exercised' -ForegroundColor Yellow
} else {
    Assert-Equal 'canceled' $sync.Result.Status 'cancel while copying'
    Assert-True ($progressSeen -gt 0) "progress was reported before cancel ($progressSeen bytes)"
}

Section 'Distribution (two destinations, staging, partial failure)'
$sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
$sessionState.ImportPSModule([string[]]$modulePaths)
$pool = [runspacefactory]::CreateRunspacePool(1, 4, $sessionState, $Host)
$pool.Open()
function Wait-Distribution {
    param([hashtable]$Distribution, [int]$TimeoutMs = 60000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($Distribution.Status -eq 'running') {
        if ($watch.ElapsedMilliseconds -gt $TimeoutMs) { throw 'distribution timed out' }
        Step-FtDistribution $Distribution
        Start-Sleep -Milliseconds 100
    }
}
$sharedSrc = if ($uncWorkDir) { "$uncWorkDir\src" } else { $src }
if (-not $uncWorkDir) { Write-Host '    (info) \\127.0.0.1\C$ is not available; staging uses a local source' -ForegroundColor Yellow }
$distItems = @(
    @{ Path = "$sharedSrc\日本語ファイル.txt"; IsFolder = $false; Size = 5 },
    @{ Path = "$src\folder"; IsFolder = $true; Size = 3 }
)
$stageFolder = Join-Path (Get-FtStageRoot) ('stage_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$distTargets = @(
    @{ Name = 'A'; HostName = 'A'; IsLocal = $true; Dest = "$WorkDir\dist\A" },
    @{ Name = 'B'; HostName = 'B'; IsLocal = $true; Dest = "$WorkDir\dist\B" }
)
$distribution = New-FtDistribution -Items $distItems -Targets $distTargets -StageFolder $stageFolder -Options @{ ParallelHosts = 2 } -Pool $pool
Assert-True ($null -ne $distribution.Stage -eq [bool]$uncWorkDir) 'staging only when there are shared (UNC) files'
Wait-Distribution $distribution
$summary = Get-FtDistributionSummary $distribution
Assert-Equal 'success' $summary.Status 'distribution to two destinations'
Assert-True ((Test-Path -LiteralPath "$WorkDir\dist\A\日本語ファイル.txt") -and (Test-Path -LiteralPath "$WorkDir\dist\B\folder\sub\b.txt")) 'both destinations received the files'
if ($uncWorkDir) { Assert-True (Test-Path -LiteralPath "$stageFolder\日本語ファイル.txt") 'shared file was staged once' }
$progress = Get-FtDistributionProgress $distribution
Assert-True (@($progress.Items.Values | Where-Object { $_.State -ne 'done' }).Count -eq 0) 'all rows done'
Assert-Equal $progress.BytesTotal $progress.BytesDone 'distribution progress reaches 100%'
$distLog = Read-FtDistributionLog $distribution
Assert-True (@($distLog | Where-Object { $_ -like '`[A`] robocopy*' }).Count -gt 0 -and @($distLog | Where-Object { $_ -like '`[B`] robocopy*' }).Count -gt 0) 'log lines are prefixed with the destination'

$reused = New-FtDistribution -Items $distItems -Targets @($distTargets[1]) -StageFolder $stageFolder -ReuseStage -Pool $pool
if ($uncWorkDir) { Assert-True ($reused.Stage.Status -eq 'success' -and $reused.Stage.Reused) 'retry reuses the staged copy' }
Remove-FtStageFolder $stageFolder
Assert-True (-not (Test-Path -LiteralPath $stageFolder)) 'temporary staging folder removed'
New-Item -ItemType Directory -Path "$WorkDir\stage_keep" -Force | Out-Null
Remove-FtStageFolder "$WorkDir\stage_keep"
Assert-True (Test-Path -LiteralPath "$WorkDir\stage_keep") 'folders outside the staging root are never removed'

# B だけ書き込みを拒否して、一部だけ失敗させる
$deniedRoot = Join-Path $WorkDir 'dist2\B'
New-Item -ItemType Directory -Path $deniedRoot -Force | Out-Null
$acl = Get-Acl -LiteralPath $deniedRoot
$denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'CreateFiles, CreateDirectories', 'ContainerInherit, ObjectInherit', 'None', 'Deny')
$acl.AddAccessRule($denyRule)
Set-Acl -LiteralPath $deniedRoot -AclObject $acl
$partialTargets = @(
    @{ Name = 'A'; HostName = 'A'; IsLocal = $true; Dest = "$WorkDir\dist2\A\x" },
    @{ Name = 'B'; HostName = 'B'; IsLocal = $true; Dest = "$deniedRoot\x" }
)
$distribution = New-FtDistribution -Items @($distItems[1]) -Targets $partialTargets -Options @{ ParallelHosts = 2; RetryCount = 0; RetryWaitSec = 0 } -Pool $pool
Wait-Distribution $distribution
$summary = Get-FtDistributionSummary $distribution
Assert-Equal 'partial|B|5' ('{0}|{1}|{2}' -f $summary.Status, $summary.Failed[0].Name, $summary.Failed[0].Result.Code) 'one destination fails with access denied'
$acl = Get-Acl -LiteralPath $deniedRoot
[void]$acl.RemoveAccessRule($denyRule)
Set-Acl -LiteralPath $deniedRoot -AclObject $acl

$distribution = New-FtDistribution -Items @($distItems[1]) -Targets $distTargets -Options @{ ParallelHosts = 1 } -Pool $pool
Stop-FtDistribution $distribution
Assert-Equal 'canceled' (Get-FtDistributionSummary $distribution).Status 'cancel before any destination starts'
$pool.Close()

Section 'Command line'
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$mainScript = Join-Path $root 'FileTransfer.ps1'
function Invoke-Cli {
    param([string[]]$Arguments)
    $output = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $mainScript @Arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}
$cli = Invoke-Cli @('-Destination', 'このPC')
Assert-True ($cli.Code -eq 2 -and $cli.Output -like '*使い方*') "missing arguments show usage (exit $($cli.Code))"
$cli = Invoke-Cli @('-Destination', 'このPC', '-Folder', "$WorkDir\cli0", "$WorkDir\no-such-file.txt")
Assert-True ($cli.Code -eq 2 -and $cli.Output -like '*見つかりません*') "missing source (exit $($cli.Code))"
$cli = Invoke-Cli @('-Destination', 'このPC', '-Folder', "$WorkDir\cli0", "$src\日本語ファイル.txt", '-Bogus')
Assert-True ($cli.Code -eq 2) "unknown option (exit $($cli.Code))"
$cli = Invoke-Cli @('-Destination', 'このPC', '-Folder', "$WorkDir\cli1\{date}", "$src\日本語ファイル.txt", "$src\folder")
$today = (Get-Date).ToString('yyyyMMdd')
Assert-True ($cli.Code -eq 0 -and (Test-Path -LiteralPath "$WorkDir\cli1\$today\日本語ファイル.txt") -and (Test-Path -LiteralPath "$WorkDir\cli1\$today\folder\sub\b.txt")) "copy to this PC (exit $($cli.Code))"
$cli = Invoke-Cli @('-Destination', 'このPC', '-Folder', "$WorkDir\cli2", "$src\*.txt")
Assert-True ($cli.Code -eq 0 -and (Test-Path -LiteralPath "$WorkDir\cli2\日本語ファイル.txt")) "wildcard source (exit $($cli.Code))"
$cli = Invoke-Cli @('-Destination', 'このPC', '-Folder', "$WorkDir\cli3", "$src\日本語ファイル.txt", '-WhatIf')
Assert-True ($cli.Code -eq 0 -and -not (Test-Path -LiteralPath "$WorkDir\cli3") -and $cli.Output -like '*robocopy*') "-WhatIf only shows the plan (exit $($cli.Code))"
$cli = Invoke-Cli @('-Destination', 'ft-nonexistent-host.invalid', '-Folder', 'C:\Work', "$src\日本語ファイル.txt")
Assert-True ($cli.Code -eq 2 -and $cli.Output -like '*接続できません*') "unreachable server (exit $($cli.Code))"
$cli = Invoke-Cli @('-Destination', 'ft-nonexistent-host.invalid', '-Folder', 'C:\Work\{date}', "$src\日本語ファイル.txt", '-WhatIf')
Assert-True ($cli.Code -eq 2 -and $cli.Output -like '*robocopy*' -and $cli.Output -like '*接続できません*') "-WhatIf shows the plan and the connection problem (exit $($cli.Code))"
if ($uncWorkDir) {
    $stagesBefore = @(Get-ChildItem -LiteralPath (Get-FtStageRoot) -Directory -Filter 'stage_*' -ErrorAction SilentlyContinue).Count
    $cli = Invoke-Cli @('-Destination', "$env:COMPUTERNAME,127.0.0.1", '-Folder', "$WorkDir\cli4\{host}", "$uncWorkDir\src\日本語ファイル.txt", "$src\folder")
    Assert-True ($cli.Code -eq 0) "two servers through admin shares (exit $($cli.Code))`n$($cli.Output)"
    Assert-True ((Test-Path -LiteralPath "$WorkDir\cli4\$($env:COMPUTERNAME)\日本語ファイル.txt") -and (Test-Path -LiteralPath "$WorkDir\cli4\127.0.0.1\folder\sub\b.txt")) 'both servers received the files'
    $stagesAfter = @(Get-ChildItem -LiteralPath (Get-FtStageRoot) -Directory -Filter 'stage_*' -ErrorAction SilentlyContinue).Count
    Assert-Equal $stagesBefore $stagesAfter 'temporary staging folder is removed after the command'

    # Ctrl+C と同じ仕組み（パイプラインの停止）で止めたとき、robocopy を止めて一時フォルダを消すか
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param($Root, $ModulePaths, $Destination, $Folder, $Source)
        foreach ($modulePath in $ModulePaths) { Import-Module $modulePath -DisableNameChecking }
        Invoke-FtCli -Source $Source -Destination $Destination -Folder $Folder -Config (Get-FtConfig -AppRoot $Root) -ModulePaths $ModulePaths
    }).AddArgument($root).AddArgument([string[]]$modulePaths).AddArgument("$env:COMPUTERNAME,127.0.0.1").AddArgument("$WorkDir\cli6\{host}").AddArgument([string[]]@("$uncWorkDir\src\huge.bin"))
    $handle = $ps.BeginInvoke()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Get-Process robocopy -ErrorAction SilentlyContinue) -and -not $handle.IsCompleted -and $watch.ElapsedMilliseconds -lt 20000) { Start-Sleep -Milliseconds 50 }
    $wasCopying = [bool](Get-Process robocopy -ErrorAction SilentlyContinue)
    $ps.Stop()
    Start-Sleep -Milliseconds 500
    $ps.Dispose(); $runspace.Dispose()
    if ($wasCopying) {
        Assert-True (-not (Get-Process robocopy -ErrorAction SilentlyContinue)) 'stopping the command line run stops robocopy'
        Assert-Equal $stagesBefore @(Get-ChildItem -LiteralPath (Get-FtStageRoot) -Directory -Filter 'stage_*' -ErrorAction SilentlyContinue).Count 'stopping removes the temporary staging folder'
    } else {
        Write-Host '    (info) copy finished before stop; stop path not exercised' -ForegroundColor Yellow
    }
}
$bat = Join-Path $root 'FileTransfer.bat'
$output = & cmd.exe /c "`"$bat`" -Destination このPC -Folder `"$WorkDir\cli5`" `"$src\日本語ファイル.txt`"" 2>&1 | Out-String
Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath "$WorkDir\cli5\日本語ファイル.txt")) "FileTransfer.bat passes arguments to the command line mode (exit $LASTEXITCODE)"

Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
exit $script:Failed
