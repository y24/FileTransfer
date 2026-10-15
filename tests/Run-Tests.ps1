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
$modulePaths = @('Config', 'PathResolver', 'Connection', 'TransferEngine', 'WinRm', 'Distribution', 'Log', 'Cli') | ForEach-Object { Join-Path $root "lib\$_.psm1" }
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

Section 'Resolve (WinRM)'
$r = Resolve-FtDestination -Destination 'sv-app01' -Folder 'C:\Work\{datetime}' -Now $now -Method winrm
Assert-Equal 'C:\Work\20261015_1432|SV-APP01|winrm' ('{0}|{1}|{2}' -f $r.Path, $r.HostName, $r.Method) 'WinRM keeps the server path'
Assert-True ($null -eq $r.ShareRoot) 'WinRM has no share root'
$r = Resolve-FtDestination -Destination 'SV-LEGACY01' -Folder 'C:\Work\x' -Now $now -Mappings $mappings -Method winrm
Assert-Equal 'C:\Work\x' $r.Path 'WinRM ignores share mappings'
$r = Resolve-FtDestination -Destination 'SV-APP01' -Folder 'D:\' -Now $now -Method winrm
Assert-Equal 'D:\' $r.Path 'WinRM drive root'
Assert-True ((Resolve-FtDestination -Destination 'SV-APP01' -Folder '\\SV-APP01\Deploy$\x' -Method winrm).Error -like '*WinRM*') 'WinRM rejects a UNC folder'
$r = Resolve-FtDestinations -Destination 'SV-APP01, SV-APP02' -Folder 'C:\Work\{datetime}' -Now $now -Method winrm
Assert-True (-not $r.Error -and $r.Targets.Count -eq 2 -and $r.Targets[1].Path -eq 'C:\Work\20261015_1432') 'WinRM: the same server path on several servers is fine'
$r = Resolve-FtDestinations -Destination 'このPC' -Folder 'D:\Transfer' -Now $now -Method winrm
Assert-True ($r.IsLocal -and $r.Targets[0].Method -eq 'local') 'this PC is not affected by WinRM'

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
Assert-Equal 'smb' (Get-FtTransferMethod $config) 'transfer method defaults to SMB'
Set-FtUserSetting -Section 'transfer' -Name 'method' -Value 'winrm'
$config = Get-FtConfig -AppRoot $root
Assert-Equal 'winrm' (Get-FtTransferMethod $config) 'the settings screen value is read back'
$userFile = Get-Content -LiteralPath $env:FILETRANSFER_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($userFile.transfer.method -eq 'winrm' -and $userFile.transfer.keepLocalCopy -and $null -eq $userFile.transfer.retryCount) 'only the changed setting is written (others keep the distributed defaults)'
Assert-True (@($userFile.history.destinations) -contains 'SV-APP01') 'history is kept when a setting is saved'
Set-FtUserSetting -Section 'transfer' -Name 'method' -Value 'smb'
Assert-Equal 'smb' (Get-FtTransferMethod @{ transfer = @{ method = 'bogus' } }) 'unknown method falls back to SMB'
$winrmOptions = Get-FtWinRmOptions $config
Assert-True (-not $winrmOptions.UseSsl -and $winrmOptions.Port -eq 0 -and $winrmOptions.ChunkBytes -eq 2MB) 'WinRM defaults'
Assert-Equal 4MB (Get-FtWinRmOptions @{ winrm = @{ chunkSizeMB = 16 } }).ChunkBytes 'WinRM chunk size is capped (the server receives at most 10 MB per object)'
Assert-Equal 5985 (Get-FtWinRmPort $winrmOptions) 'WinRM HTTP port'
Assert-Equal 5986 (Get-FtWinRmPort @{ UseSsl = $true }) 'WinRM HTTPS port'

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
Assert-True ((Get-FtErrorInfo -Code 5 -Server -Method winrm).Detail -notlike '*管理共有*' -and (Get-FtErrorInfo -Code 5 -Server -Method winrm).NeedsLogon) 'WinRM access denied does not mention admin shares'
Assert-True ((Get-FtErrorInfo -Code 53 -Server -Method winrm).Detail -like '*WinRM*') 'WinRM unreachable mentions WinRM'
$info = Get-FtErrorInfo -Code 0 -Target 'SV-APP01' -Server -Method winrm -Fallback "TrustedHosts に登録されていません`n詳しい説明"
Assert-Equal 'SV-APP01：TrustedHosts に登録されていません' $info.Short 'WinRM message: the first line is the summary'

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
$connectionList = @('Z:|\\SV-APP01\Share', '|\\sv-app01\IPC$', '|\\SV-APP01.corp.example\C$', 'Y:|\\fs01\work', 'broken')
$selected = Select-FtHostConnections -Connections $connectionList -Names @('SV-APP01')
Assert-Equal 'Z:|\\SV-APP01\Share;|\\sv-app01\IPC$' (($selected | ForEach-Object { "$($_.Local)|$($_.Remote)" }) -join ';') 'connections to the server (case-insensitive)'
$selected = Select-FtHostConnections -Connections $connectionList -Names @('SV-APP01', 'sv-app01.corp.example')
Assert-Equal 3 $selected.Count 'aliases are included'
Assert-Equal 'Z:（\\SV-APP01\Share）' (Format-FtConnection @{ Local = 'Z:'; Remote = '\\SV-APP01\Share' }) 'format a drive connection'
Assert-True ($null -ne [FileTransfer.Native]::GetConnections()) 'enumerating connections works'
$none = Disconnect-FtHostConnections -HostName 'ft-nonexistent-host.invalid'
Assert-True ($none.Closed.Count -eq 0 -and $none.Failed.Count -eq 0) 'nothing to disconnect for an unknown server'
$conflict = Get-FtErrorInfo -Code 1219 -Target 'SV-APP01' -Server
Assert-True ($conflict.NeedsDisconnect -and $conflict.NeedsLogon -and $conflict.Detail -like '*切断して再試行*') 'error 1219 offers disconnect and logon'
Assert-True (-not (Get-FtErrorInfo -Code 5 -Server).NeedsDisconnect) 'access denied does not offer disconnect'
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

Section 'Free space'
Assert-True ([FileTransfer.Native]::GetFreeBytes("$WorkDir\") -gt 0) 'free bytes of a local folder'
Assert-Equal -1 ([FileTransfer.Native]::GetFreeBytes('\\ft-nonexistent-host.invalid\C$\')) 'unknown server: -1'
Assert-Equal $WorkDir (Get-FtExistingFolder "$WorkDir\not\yet\created") 'nearest existing folder'
$spaceDest = Join-Path $WorkDir 'space'
New-Item -ItemType Directory -Path $spaceDest -Force | Out-Null
Copy-Item -LiteralPath "$src\日本語ファイル.txt" -Destination $spaceDest
$spaceItems = @(
    @{ Path = "$src\日本語ファイル.txt"; IsFolder = $false; Size = (Get-Item -LiteralPath "$src\日本語ファイル.txt").Length },
    @{ Path = $big; IsFolder = $false; Size = 40MB },
    @{ Path = "$src\folder"; IsFolder = $true; Size = 3 }
)
Assert-Equal (40MB + 3) (Get-FtRequiredBytes -Items $spaceItems -Dest $spaceDest) 'files already at the destination with the same size are not counted'
$hugeItem = @(@{ Path = '\\fs01\patches\huge.bin'; IsFolder = $false; Size = 1PB })
$space = Test-FtFreeSpace -Items $hugeItem -Targets @(@{ Name = 'このPC'; Dest = "$WorkDir\space\new" }) -StageFolder "$WorkDir\stage"
Assert-Equal 2 $space.Count 'the staging folder and the destination are checked'
Assert-True ($space[0].Short -and $space[1].Short -and $space[0].Name -like '*取得*') '1 PB does not fit'
Assert-True ((Format-FtFreeSpace $space[1]) -like 'このPC（C:）：空き * ／ 必要 1,024.00 TB' -or $WorkDir -notlike 'C:*') "format ($(Format-FtFreeSpace $space[1]))"
Assert-Equal '1.50 TB' ([FileTransfer.FileItem]::FormatSize(1.5TB)) 'size TB'
$space = Test-FtFreeSpace -Items $hugeItem -Targets @(@{ Name = 'このPC'; Dest = "$WorkDir\space\new" }) -StageFolder "$WorkDir\stage" -StageReused
Assert-Equal 1 $space.Count 'a reused staging folder is not checked again'
$space = Test-FtFreeSpace -Items @($spaceItems[0]) -Targets @(@{ Name = 'x'; Dest = '\\ft-nonexistent-host.invalid\C$\Work' })
Assert-True ($space[0].Free -eq -1 -and -not $space[0].Short) 'unknown free space is not reported as a shortage'

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

Section 'WinRM errors and credentials'
$transportError = New-Object System.Management.Automation.Remoting.PSRemotingTransportException 'Access is denied.'
$transportError.ErrorCode = 5
Assert-Equal 'auth|5' ('{0}|{1}' -f (ConvertFrom-FtWinRmError $transportError).Status, (ConvertFrom-FtWinRmError $transportError).Code) 'access denied needs logon'
$transportError.ErrorCode = 1326
Assert-Equal 'auth|1326' ('{0}|{1}' -f (ConvertFrom-FtWinRmError $transportError).Status, (ConvertFrom-FtWinRmError $transportError).Code) 'bad password needs logon'
$transportError.ErrorCode = -2144108316   # 0x803380E4: TrustedHosts
$converted = ConvertFrom-FtWinRmError $transportError
Assert-True ($converted.Status -eq 'error' -and $converted.Message -like '*TrustedHosts*' -and $converted.Detail -like '*Set-Item WSMan*') 'TrustedHosts is explained'
$transportError.ErrorCode = -2144108526   # 0x80338012: cannot connect
Assert-Equal 'unreachable|53' ('{0}|{1}' -f (ConvertFrom-FtWinRmError $transportError).Status, (ConvertFrom-FtWinRmError $transportError).Code) 'WinRM service not reachable'
$converted = ConvertFrom-FtWinRmError (New-Object System.Exception "first line`nsecond line")
Assert-True ($converted.Status -eq 'error' -and $converted.Message -like '*first line' -and $converted.Detail -like '*second line*') 'unknown error keeps the original message'
$watch = [Diagnostics.Stopwatch]::StartNew()
$access = Test-FtWinRmAccess -HostName 'ft-nonexistent-host.invalid' -TimeoutMs 1500
Assert-True ($access.Status -eq 'unreachable' -and $watch.ElapsedMilliseconds -lt 5000) "unknown host is unreachable over WinRM ($($access.Status), $($watch.ElapsedMilliseconds) ms)"
Assert-True ($null -eq (Get-FtWinRmSavedCredential 'FT-TEST-NO-SUCH-CREDENTIAL')) 'no saved WinRM credential'
# 汎用資格情報の保存と読み出し（テスト用の名前で書いて、すぐ消す）
$testHost = 'FT-TEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
    $testPassword = ConvertTo-SecureString 'p@ss wörd' -AsPlainText -Force
    $code = Save-FtWinRmCredential -HostName $testHost -Credential (New-Object System.Management.Automation.PSCredential "$testHost\Administrator", $testPassword)
    $readBack = Get-FtWinRmSavedCredential $testHost.ToLowerInvariant()
    Assert-True ($code -eq 0 -and $readBack.UserName -eq "$testHost\Administrator" -and $readBack.GetNetworkCredential().Password -eq 'p@ss wörd') 'WinRM credential round trip'
    Assert-Equal "$testHost\Administrator" (Get-FtWinRmSavedUser $testHost) 'saved WinRM user'
} finally {
    [void][FileTransfer.Native]::DeleteGenericCredential((Get-FtWinRmCredentialTarget $testHost))
}
Assert-True ($null -eq (Get-FtWinRmSavedCredential $testHost)) 'test credential removed'

# ここからは、この PC に起動した別の PowerShell をサーバーの代わりにする（リモートと同じく値はシリアル化される）
$env:FILETRANSFER_TEST_WINRM_LOCAL = '1'

Section 'WinRM transfer (this PC stands in for the server)'
New-Item -ItemType Directory -Path "$src\folder\empty" -Force | Out-Null
[IO.File]::WriteAllBytes("$src\folder\zero.bin", [byte[]]@())
$random = New-Object byte[] (3MB + 77)
(New-Object Random 7).NextBytes($random)
$chunked = Join-Path $src 'chunked.bin'
[IO.File]::WriteAllBytes($chunked, $random)
$winrmItems = @(
    @{ Path = $chunked; IsFolder = $false; Size = $random.Length },
    @{ Path = "$src\日本語ファイル.txt"; IsFolder = $false; Size = 5 },
    @{ Path = "$src\folder"; IsFolder = $true; Size = 3 }
)
$winrmDest = Join-Path $WorkDir 'winrm\20261015_1432'
$sync = New-TestSync
$result = Invoke-FtWinRmTransferPlan -Steps (New-FtTransferPlan -Items $winrmItems -Destination $winrmDest) -Sync $sync -HostName 'TEST' -WinRm @{ ChunkBytes = 1MB }
Assert-Equal 'success' $result.Status "WinRM transfer succeeds ($($result.Message))"
Assert-Equal (Get-FileHash -LiteralPath $chunked).Hash (Get-FileHash -LiteralPath "$winrmDest\chunked.bin").Hash 'a file larger than the chunk size arrives intact'
Assert-True (Test-Path -LiteralPath "$winrmDest\日本語ファイル.txt") 'Japanese file name over WinRM'
Assert-True ((Test-Path -LiteralPath "$winrmDest\folder\sub\b.txt") -and (Test-Path -LiteralPath "$winrmDest\folder\empty") -and (Test-Path -LiteralPath "$winrmDest\folder\zero.bin")) 'folder structure (with empty folders and empty files) over WinRM'
Assert-True ((Get-Item -LiteralPath "$winrmDest\chunked.bin").LastWriteTimeUtc -eq (Get-Item -LiteralPath $chunked).LastWriteTimeUtc) 'modified time is kept'
Assert-Equal 0 @(Get-ChildItem -LiteralPath $winrmDest -Recurse -Filter '*.ftpart').Count 'no partial files left'
Assert-Equal $sync.BytesTotal $sync.BytesDone 'WinRM progress reaches 100%'
$completed = @($sync.Completed.ToArray())
Assert-True ($completed -contains $chunked -and $completed -contains "$src\folder") 'WinRM reports completed items'
Assert-True (@($sync.Log.ToArray() | Where-Object { $_ -like '*送信*chunked.bin*' }).Count -gt 0) 'WinRM log lists sent files'

$sync = New-TestSync
$result = Invoke-FtWinRmTransferPlan -Steps (New-FtTransferPlan -Items $winrmItems -Destination $winrmDest) -Sync $sync -HostName 'TEST' -WinRm @{ ChunkBytes = 1MB }
Assert-True ($result.Status -eq 'success' -and @($sync.Log.ToArray() | Where-Object { $_ -like '*送信 *' }).Count -eq 0) 'second WinRM run skips files that are already there'
Assert-True (@($sync.Log.ToArray() | Where-Object { $_ -like '*同じ内容のファイルがあるため省略: 3 ファイル' }).Count -eq 1) 'skipped files are summarized in the log'
[IO.File]::WriteAllText("$src\folder\a.txt", 'changed')
$sync = New-TestSync
$result = Invoke-FtWinRmTransferPlan -Steps (New-FtTransferPlan -Items @($winrmItems[2]) -Destination $winrmDest) -Sync $sync -HostName 'TEST'
Assert-True ($result.Status -eq 'success' -and [IO.File]::ReadAllText("$winrmDest\folder\a.txt") -eq 'changed' -and @($sync.Log.ToArray() | Where-Object { $_ -like '*送信 *' }).Count -eq 1) 'a changed file is sent again (and only that one)'
[IO.File]::WriteAllText("$src\folder\a.txt", 'a')

$sync = New-TestSync
$result = Invoke-FtWinRmTransferPlan -Steps (New-FtTransferPlan -Items $missingItems -Destination $winrmDest) -Sync $sync -HostName 'TEST'
Assert-Equal 'failed|deleted.txt' ('{0}|{1}' -f $result.Status, ($result.Missing -join ',')) 'WinRM: missing source file is reported'
$sync = New-TestSync
$result = Invoke-FtWinRmTransferPlan -Steps (New-FtTransferPlan -Items @(@{ Path = "$WorkDir\no-such-dir"; IsFolder = $true; Size = 1 }) -Destination $winrmDest) -Sync $sync -HostName 'TEST'
Assert-Equal 'failed|3' ('{0}|{1}' -f $result.Status, $result.Code) 'WinRM: missing source folder gives error 3'

# 書き込みを拒否したフォルダに送る
$winrmDenied = Join-Path $WorkDir 'winrm-denied'
New-Item -ItemType Directory -Path $winrmDenied -Force | Out-Null
$acl = Get-Acl -LiteralPath $winrmDenied
$acl.AddAccessRule($denyRule)
Set-Acl -LiteralPath $winrmDenied -AclObject $acl
$sync = New-TestSync
$result = Invoke-FtWinRmTransferPlan -Steps (New-FtTransferPlan -Items @($winrmItems[1]) -Destination "$winrmDenied\x") -Sync $sync -HostName 'TEST'
Assert-Equal 'failed|5' ('{0}|{1}' -f $result.Status, $result.Code) 'WinRM: access denied on the server gives error 5'
$acl = Get-Acl -LiteralPath $winrmDenied
[void]$acl.RemoveAccessRule($denyRule)
Set-Acl -LiteralPath $winrmDenied -AclObject $acl

$space = Test-FtFreeSpace -Items $winrmItems -Targets @(@{ Name = 'TEST'; HostName = 'TEST'; Method = 'winrm'; Dest = $winrmDest })
Assert-True ($space.Count -eq 1 -and $space[0].Free -gt 0 -and $space[0].Required -eq 3) "WinRM free space counts only what is not there yet ($($space[0].Required) bytes)"
Assert-Equal ([IO.Path]::GetPathRoot($WorkDir).TrimEnd('\')) $space[0].Volume 'WinRM free space volume is the server drive'
$access = Test-FtWinRmAccess -HostName 'TEST'
Assert-True ($access.Status -eq 'ok' -and $access.User -eq [Security.Principal.WindowsIdentity]::GetCurrent().Name) "WinRM access check reports the remote user ($($access.User))"

Section 'WinRM cancel while copying'
$sync = New-TestSync
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$ps = [powershell]::Create()
$ps.Runspace = $runspace
[void]$ps.AddScript({
    param($Root, $ModulePaths, $Steps, $Sync)
    $env:FILETRANSFER_TEST_WINRM_LOCAL = '1'
    Add-Type -Path (Join-Path $Root 'lib\Native.cs'), (Join-Path $Root 'lib\Models.cs') -ErrorAction SilentlyContinue
    foreach ($modulePath in $ModulePaths) { Import-Module $modulePath -DisableNameChecking }
    Invoke-FtWinRmTransferPlan -Steps $Steps -Sync $Sync -HostName 'TEST' -WinRm @{ ChunkBytes = 1MB }
}).AddArgument($root).AddArgument([string[]]$modulePaths).AddArgument((New-FtTransferPlan -Items @(@{ Path = $huge; IsFolder = $false; Size = 2GB }) -Destination "$WorkDir\winrm-cancel")).AddArgument($sync)
$handle = $ps.BeginInvoke()
$watch = [Diagnostics.Stopwatch]::StartNew()
while ([long]$sync.BytesDone -lt 3MB -and -not $handle.IsCompleted -and $watch.ElapsedMilliseconds -lt 30000) { Start-Sleep -Milliseconds 50 }
$progressSeen = [long]$sync.BytesDone
$sync.Cancel = $true
[void]$handle.AsyncWaitHandle.WaitOne(30000)
$ps.Dispose(); $runspace.Dispose()
Assert-Equal 'canceled' $sync.Result.Status 'WinRM cancel while copying'
Assert-True ($progressSeen -gt 0 -and [double]$sync.CurrentFraction -ge 0) "WinRM progress was reported before cancel ($progressSeen bytes)"
Assert-True (-not (Test-Path -LiteralPath "$WorkDir\winrm-cancel\huge.bin") -and @(Get-ChildItem -LiteralPath "$WorkDir\winrm-cancel" -Filter '*.ftpart' -ErrorAction SilentlyContinue).Count -eq 0) 'canceling removes the partial file on the server'

Section 'WinRM distribution (two servers)'
$winrmTargets = @(
    @{ Name = 'A'; HostName = 'A'; IsLocal = $false; Method = 'winrm'; Dest = "$WorkDir\winrm-dist\A" },
    @{ Name = 'B'; HostName = 'B'; IsLocal = $false; Method = 'winrm'; Dest = "$WorkDir\winrm-dist\B" }
)
$stageFolder = Join-Path (Get-FtStageRoot) ('stage_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$distribution = New-FtDistribution -Items $distItems -Targets $winrmTargets -StageFolder $stageFolder -Options @{ ParallelHosts = 2; WinRm = @{ ChunkBytes = 1MB } } -Pool $pool
Assert-True (@($distribution.Hosts | Where-Object { $_.Method -eq 'winrm' }).Count -eq 2) 'hosts use WinRM'
Wait-Distribution $distribution -TimeoutMs 120000
$summary = Get-FtDistributionSummary $distribution
Assert-Equal 'success' $summary.Status "WinRM distribution to two servers ($(@($summary.Failed | ForEach-Object { $_.Result.Message }) -join '; '))"
Assert-True ((Test-Path -LiteralPath "$WorkDir\winrm-dist\A\日本語ファイル.txt") -and (Test-Path -LiteralPath "$WorkDir\winrm-dist\B\folder\sub\b.txt")) 'both WinRM servers received the files'
$progress = Get-FtDistributionProgress $distribution
Assert-Equal $progress.BytesTotal $progress.BytesDone 'WinRM distribution progress reaches 100%'
Remove-FtStageFolder $stageFolder
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
Assert-True ($cli.Code -eq 0 -and -not (Test-Path -LiteralPath "$WorkDir\cli3") -and $cli.Output -like '*robocopy*' -and $cli.Output -like '*空き容量:*') "-WhatIf only shows the plan and free space (exit $($cli.Code))"
# 見かけだけ 1 TB のファイル（スパースファイル。ディスクは使わない）で、空き容量の不足を起こす
$sparse = Join-Path $WorkDir 'sparse\huge-sparse.bin'
New-Item -ItemType Directory -Path (Split-Path $sparse) -Force | Out-Null
[IO.File]::WriteAllBytes($sparse, [byte[]]@())
& fsutil.exe sparse setflag $sparse | Out-Null
$stream = [IO.File]::Open($sparse, 'Open', 'ReadWrite'); $stream.SetLength(1TB); $stream.Close()
if ([FileTransfer.Native]::GetFreeBytes("$WorkDir\") -lt 1TB) {
    $cli = Invoke-Cli @('-Destination', 'このPC', '-Folder', "$WorkDir\cli7", $sparse)
    Assert-True ($cli.Code -eq 2 -and $cli.Output -like '*空き容量が足りません*' -and $cli.Output -like '*-SkipSpaceCheck*' -and -not (Test-Path -LiteralPath "$WorkDir\cli7")) "not enough free space stops before copying (exit $($cli.Code))"
    $cli = Invoke-Cli @('-Destination', 'このPC', '-Folder', "$WorkDir\cli7", $sparse, '-WhatIf')
    Assert-True ($cli.Code -eq 2 -and $cli.Output -like '*問題*空き容量が足りません*') "-WhatIf reports the shortage (exit $($cli.Code))"
} else {
    Write-Host '    (info) more than 1 TB free; shortage test skipped' -ForegroundColor Yellow
}
[IO.File]::Delete($sparse)
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
# WinRM（FILETRANSFER_TEST_WINRM_LOCAL により、この PC の別の PowerShell がサーバーの代わりになる）
$cli = Invoke-Cli @('-Destination', $env:COMPUTERNAME, '-Folder', "$WorkDir\cliw\{host}", '-Method', 'WinRM', "$src\日本語ファイル.txt", "$src\folder")
Assert-True ($cli.Code -eq 0 -and (Test-Path -LiteralPath "$WorkDir\cliw\$($env:COMPUTERNAME.ToUpperInvariant())\日本語ファイル.txt") -and (Test-Path -LiteralPath "$WorkDir\cliw\$($env:COMPUTERNAME.ToUpperInvariant())\folder\sub\b.txt")) "-Method WinRM copies files and folders (exit $($cli.Code))`n$($cli.Output)"
$cli = Invoke-Cli @('-Destination', $env:COMPUTERNAME, '-Folder', "$WorkDir\cliw2", '-Method', 'winrm', "$src\日本語ファイル.txt", '-WhatIf')
Assert-True ($cli.Code -eq 0 -and $cli.Output -like '*WinRM "*' -and $cli.Output -like '*空き容量:*' -and -not (Test-Path -LiteralPath "$WorkDir\cliw2")) "-Method WinRM -WhatIf shows the plan (exit $($cli.Code))"
$cli = Invoke-Cli @('-Destination', 'SV-APP01', '-Folder', '\\SV-APP01\Deploy$\x', '-Method', 'WinRM', "$src\日本語ファイル.txt")
Assert-True ($cli.Code -eq 2 -and $cli.Output -like '*WinRM*サーバー上のパス*') "-Method WinRM rejects a UNC folder (exit $($cli.Code))"

$bat = Join-Path $root 'FileTransfer.bat'
$output = & cmd.exe /c "`"$bat`" -Destination このPC -Folder `"$WorkDir\cli5`" `"$src\日本語ファイル.txt`"" 2>&1 | Out-String
Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath "$WorkDir\cli5\日本語ファイル.txt")) "FileTransfer.bat passes arguments to the command line mode (exit $LASTEXITCODE)"

Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
exit $script:Failed
