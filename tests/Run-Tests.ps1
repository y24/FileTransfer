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
foreach ($name in 'Config', 'PathResolver', 'Connection', 'TransferEngine', 'Log') {
    Import-Module (Join-Path $root "lib\$name.psm1") -Force -DisableNameChecking
}

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

Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
exit $script:Failed
