#Requires -Version 5.1
<#
.SYNOPSIS
    アプリを画面外に表示して操作し、各状態の画面を PNG に保存する（画面まわりの結合テスト）
.DESCRIPTION
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\Render-Screens.ps1 -OutDir <出力先>
    このPC への転送と、自分自身の管理共有（\\<このPCの名前>\C$）経由の「サーバー」転送を実際に行う。
#>
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$WorkDir = (Join-Path $env:TEMP ('FileTransferScreens_' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Path $OutDir, $WorkDir -Force | Out-Null
$env:FILETRANSFER_CONFIG = Join-Path $WorkDir 'config\settings.json'
$env:FILETRANSFER_LOGDIR = Join-Path $WorkDir 'logs'

. (Join-Path $root 'FileTransfer.ps1') -NoShow

$script:Passed = 0
$script:Failed = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:Passed++ } else { $script:Failed++; Write-Host "FAIL: $Name" -ForegroundColor Red }
}

# UI スレッドのメッセージを処理しながら待つ（タイマーやバックグラウンド処理の完了通知が動く）
function Wait-Ui {
    param([int]$Milliseconds = 100)
    $script:WaitFrame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.Add_Tick({ $script:WaitFrame.Continue = $false })
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($script:WaitFrame)
    $timer.Stop()
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutMs = 30000, [string]$What = 'condition')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($watch.ElapsedMilliseconds -gt $TimeoutMs) { throw "Timed out waiting for $What" }
        Wait-Ui 100
    }
}

function Save-Screen {
    param([System.Windows.Window]$Target, [string]$Name)
    Wait-Ui 200
    $Target.UpdateLayout()
    $client = [System.Windows.Media.VisualTreeHelper]::GetChild($Target, 0)
    $width = [int][Math]::Ceiling($client.ActualWidth)
    $height = [int][Math]::Ceiling($client.ActualHeight)
    $visual = New-Object System.Windows.Media.DrawingVisual
    $context = $visual.RenderOpen()
    $rect = New-Object System.Windows.Rect 0, 0, $width, $height
    $context.DrawRectangle($Target.Background, $null, $rect)
    $context.DrawRectangle((New-Object System.Windows.Media.VisualBrush $client), $null, $rect)
    $context.Close()
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $width, $height, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Create((Join-Path $OutDir "$Name.png"))
    try { $encoder.Save($stream) } finally { $stream.Close() }
    Write-Host "  saved $Name.png"
}

function Show-Offscreen {
    param([System.Windows.Window]$Target)
    $Target.WindowStartupLocation = 'Manual'
    $Target.Left = -32000
    $Target.Top = -32000
    $Target.ShowActivated = $false
    $Target.ShowInTaskbar = $false
    $Target.Show()
}

function Set-Destination {
    param([string]$Destination, [string]$Folder)
    $ui.DestBox.Text = $Destination
    Update-FtDestination -Immediate
    if ($null -ne $Folder) { $ui.FolderBox.Text = $Folder; Update-FtFolder }
    if ($script:CheckTimer.IsEnabled) { $script:CheckTimer.Stop(); Invoke-FtHostCheck }
    Wait-Until { @($script:Checks.Values | Where-Object { $_.Status -eq 'checking' }).Count -eq 0 } -What 'host check'
}

$thisHost = $env:COMPUTERNAME.ToUpperInvariant()

# テスト用のファイル
$src = Join-Path $WorkDir 'src'
New-Item -ItemType Directory -Path "$src\patches", "$src\other", "$src\modules\sub" -Force | Out-Null
$big = Join-Path $src 'patches\KB5031234-x64.msu'
$stream = [IO.File]::Create($big); $stream.SetLength(1536MB); $stream.Close()
$exe = Join-Path $src 'patches\setup_v2.4.1.exe'
$stream = [IO.File]::Create($exe); $stream.SetLength(48MB); $stream.Close()
[IO.File]::WriteAllText("$src\other\設定_20261015.zip", 'zip')
[IO.File]::WriteAllText("$src\other\setup_v2.4.1.exe", 'same name, different folder')
[IO.File]::WriteAllText("$src\modules\a.dll", 'a')
[IO.File]::WriteAllText("$src\modules\sub\b.dll", 'bb')

Show-Offscreen $window
Wait-Ui 300

Write-Host '01 empty'
Assert-True ($script:Items.Count -eq 0) 'starts with no files'
Assert-True (-not $ui.StartButton.IsEnabled) 'start is disabled without files'
Save-Screen $window '01-empty'

Write-Host '02 files + server (this PC through its admin share)'
Add-FtPaths @($big, $exe, "$src\other\設定_20261015.zip", "$src\modules")
Wait-Until { $script:PendingSizes -eq 0 } -What 'folder size'
Assert-True ($script:Items.Count -eq 4) 'four items added'
Assert-True ($ui.CountText.Text -like '4 件・*') "count text ($($ui.CountText.Text))"
$serverFolder = Join-Path $WorkDir 'server\{datetime}'   # サーバー上のパスとして C:\... を書く（→ \\<このPC>\C$\...）
Set-Destination $env:COMPUTERNAME $serverFolder
Assert-True ((Get-FtCheck $thisHost).Status -eq 'ok') "host check is ok ($((Get-FtCheck $thisHost).Status))"
Assert-True ($ui.HintText.Text -like "→ \\$($env:COMPUTERNAME)\C$\*") "hint shows the UNC path ($($ui.HintText.Text))"
Assert-True $ui.StartButton.IsEnabled 'start is enabled'
Save-Screen $window '02-server-ready'

Write-Host '03 duplicate name notice'
Add-FtPaths @("$src\other\setup_v2.4.1.exe")
Assert-True ($script:Items.Count -eq 4) 'same name from another folder is not added'
Assert-True ($ui.ResultPanel.Visibility -eq 'Visible') 'notice is shown'
Save-Screen $window '03-duplicate-notice'

Write-Host '04 running, then cancel'
Set-Destination (Get-FtLocalLabel) (Join-Path $WorkDir 'local\{datetime}')
Start-FtTransfer
Wait-Until { $script:Run.Dist -and $script:Run.Dist.Hosts[0].Sync.BytesDone -gt 0 } -What 'progress' -TimeoutMs 20000
Wait-Ui 300
Assert-True ($script:Phase -eq 'running') 'phase is running'
Assert-True ($ui.ProgressPanel.Visibility -eq 'Visible' -and $ui.StartButton.Visibility -eq 'Collapsed') 'progress replaces the start button'
Save-Screen $window '04-running'
Stop-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'cancel'
Assert-True ($script:Phase -eq 'idle') "canceled ($($script:Phase))"
Save-Screen $window '05-canceled'

Write-Host '06 server transfer completes'
Set-Destination $env:COMPUTERNAME $serverFolder
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'transfer' -TimeoutMs 120000
Assert-True ($script:Phase -eq 'done') "server transfer done ($($script:Phase); $($ui.ResultText.Text))"
$dest = $script:Run.Dist.Hosts[0].Dest
Assert-True ($dest -like "\\$($env:COMPUTERNAME)\C$\*") "destination is the admin share ($dest)"
Assert-True ($null -eq $script:Run.Dist.Stage) 'one server: shared files are relayed without staging'
Assert-True (Test-Path -LiteralPath (Join-Path $dest 'KB5031234-x64.msu')) 'big file arrived'
Assert-True (Test-Path -LiteralPath (Join-Path $dest '設定_20261015.zip')) 'Japanese file name arrived'
Assert-True (Test-Path -LiteralPath (Join-Path $dest 'modules\sub\b.dll')) 'folder arrived'
Assert-True (@($script:Items | Where-Object { $_.State -ne 'done' }).Count -eq 0) 'all rows are marked done'
Assert-True ($ui.OpenLink.Visibility -eq 'Visible' -and $ui.RdpLink.Visibility -eq 'Visible') 'open and RDP links'
$history = Get-Content -LiteralPath $env:FILETRANSFER_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (@($history.history.destinations) -contains $env:COMPUTERNAME.ToUpperInvariant()) 'destination saved to history'
Save-Screen $window '06-done'

Write-Host '07 local transfer error (access denied)'
Remove-FtItems @($script:Items | Where-Object { $_.Name -ne '設定_20261015.zip' })
# 書き込みを拒否したフォルダを送り先にする
$denied = Join-Path $WorkDir 'denied'
New-Item -ItemType Directory -Path $denied -Force | Out-Null
$acl = Get-Acl -LiteralPath $denied
$denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'CreateFiles, CreateDirectories', 'ContainerInherit, ObjectInherit', 'None', 'Deny')
$acl.AddAccessRule($denyRule)
Set-Acl -LiteralPath $denied -AclObject $acl
Set-Destination (Get-FtLocalLabel) (Join-Path $denied '{date}')
Assert-True ($script:Phase -eq 'idle') 'changing destination leaves the done state'
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'transfer'
Assert-True ($script:Phase -eq 'error') "error state ($($script:Phase))"
Assert-True ($ui.ResultText.Text -like '*アクセスが拒否されました*') "error message ($($ui.ResultText.Text))"
Assert-True ($ui.DetailLink.Visibility -eq 'Visible' -and $ui.LogonLink.Visibility -eq 'Collapsed') 'details link without logon (local)'
Save-Screen $window '07-error'

Write-Host '08 server needs logon (simulated status)'
Set-Destination $env:COMPUTERNAME 'C:\Work\{datetime}'
$script:Checks[$thisHost].Status = 'auth'
Update-FtView
Assert-True ($ui.HintText.Text -like '*ログオンが必要です*') 'logon hint'
Save-Screen $window '08-needs-logon'

Write-Host '09 invalid folder'
$ui.FolderBox.Text = 'C:\Work\a?b'
Update-FtFolder
Assert-True (-not $ui.StartButton.IsEnabled) 'start disabled for invalid folder'
Assert-True ($ui.FolderBox.Foreground -eq (Get-FtBrush 'ErrorBrush')) 'invalid folder text is red'
Save-Screen $window '09-invalid-folder'

Write-Host '10 logon dialog'
$dialog = Read-FtXaml 'LogonDialog.xaml'
$d = Get-FtNamedElements $dialog @('Heading', 'UserBox', 'UserPlaceholder', 'PassBox', 'ErrorText')
$d.Heading.Text = 'SV-DB02 にログオン'
$d.UserBox.Text = 'SV-DB02\Administrator'
$d.UserPlaceholder.Visibility = 'Collapsed'
$d.PassBox.Password = 'password'
$d.ErrorText.Text = 'ユーザー名またはパスワードが正しくありません（エラー 1326）'
$d.ErrorText.Visibility = 'Visible'
Show-Offscreen $dialog
Save-Screen $dialog '10-logon-dialog'
$dialog.Close()

Write-Host '11 details dialog'
$script:LastError = Get-FtErrorInfo -Code 5 -Target 'SV-WEB01' -Server
$dialog = Read-FtXaml 'DetailsDialog.xaml'
$d = Get-FtNamedElements $dialog @('MessageText', 'LogBox')
$d.MessageText.Text = $script:LastError.Detail
$d.LogBox.Text = $script:RunLog -join "`r`n"
Show-Offscreen $dialog
Save-Screen $dialog '11-details-dialog'
$dialog.Close()

# ---- 複数台（このPC 自身に、名前と 127.0.0.1 の 2 通りで届くことを使う）----
$uncSrc = '\\127.0.0.1\C$' + $src.Substring(2)
$multiHosts = "$thisHost, 127.0.0.1"
$multiFolder = Join-Path $WorkDir 'multi\{host}\{datetime}'

Write-Host '12 two servers ready'
Remove-FtItems @($script:Items)
Add-FtPaths @("$uncSrc\patches\setup_v2.4.1.exe", "$src\other\設定_20261015.zip", "$src\modules")
Wait-Until { $script:PendingSizes -eq 0 } -What 'folder size'
Set-Destination $multiHosts $multiFolder
Assert-True ($script:Checks.Count -eq 2 -and @($script:Checks.Values | Where-Object { $_.Status -eq 'ok' }).Count -eq 2) 'both servers checked'
Assert-True ($ui.HintText.Text -like '*ほか 1 台*') "hint shows the second server ($($ui.HintText.Text))"
Assert-True $ui.StartButton.IsEnabled 'start enabled for two servers'
Save-Screen $window '12-multi-ready'

Write-Host '13 two servers done (shared file staged once)'
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'multi transfer' -TimeoutMs 120000
Assert-True ($script:Phase -eq 'done') "multi transfer done ($($script:Phase); $($ui.ResultText.Text))"
Assert-True ($ui.ResultText.Text -like '*2 台に転送しました*') "multi result text ($($ui.ResultText.Text))"
$multiDests = @($script:Run.Dist.Hosts | ForEach-Object { $_.Dest })
Assert-True (@($multiDests | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'modules\sub\b.dll') }).Count -eq 2) 'both servers received the folder'
Assert-True (@($multiDests | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'setup_v2.4.1.exe') }).Count -eq 2) 'both servers received the shared file'
Assert-True ($null -ne $script:Run.Dist.Stage -and $script:Run.Stage.Temporary) 'shared file was staged in a temporary folder'
Assert-True (-not (Test-Path -LiteralPath $script:Run.Stage.Folder)) 'temporary staging folder removed after success'
$history = Get-Content -LiteralPath $env:FILETRANSFER_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (@($history.history.destinations)[0] -eq "$thisHost, 127.0.0.1") "multi destination saved as one history entry ($(@($history.history.destinations)[0]))"
Save-Screen $window '13-multi-done'

Write-Host '14 one of two servers fails, then retry only that one'
$deniedMulti = Join-Path $WorkDir 'multi2\127.0.0.1'
New-Item -ItemType Directory -Path $deniedMulti -Force | Out-Null
$acl = Get-Acl -LiteralPath $deniedMulti
$acl.AddAccessRule($denyRule)
Set-Acl -LiteralPath $deniedMulti -AclObject $acl
$script:Config.transfer.retryCount = 0
Set-Destination $multiHosts (Join-Path $WorkDir 'multi2\{host}\{datetime}')
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'partial transfer' -TimeoutMs 120000
Assert-True ($script:Phase -eq 'error') "partial failure is an error ($($script:Phase))"
Assert-True ($ui.ResultText.Text -like '127.0.0.1*ほか 1 台は完了*') "partial result text ($($ui.ResultText.Text))"
Assert-True ($ui.LogonLink.Visibility -eq 'Visible' -and $script:LogonTarget -eq '127.0.0.1') 'logon link points at the failed server'
Assert-True ($script:LastError.Detail -like "*$($thisHost): 完了*" -and $script:LastError.Detail -like '*127.0.0.1: *アクセスが拒否*') 'details list every server'
Assert-True (Test-Path -LiteralPath $script:Run.Stage.Folder) 'staged copy is kept for the retry'
Save-Screen $window '14-multi-partial'
$firstStage = $script:Run.Stage.Folder
$acl = Get-Acl -LiteralPath $deniedMulti
[void]$acl.RemoveAccessRule($denyRule)
Set-Acl -LiteralPath $deniedMulti -AclObject $acl
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'retry' -TimeoutMs 120000
Assert-True ($script:Phase -eq 'done') "retry succeeded ($($script:Phase); $($ui.ResultText.Text))"
Assert-True ($script:Run.Dist.Hosts.Count -eq 1 -and $script:Run.Dist.Hosts[0].Name -eq '127.0.0.1') 'retry sent only to the failed server'
Assert-True ($script:Run.Stage.Folder -eq $firstStage -and $script:Run.Dist.Stage.Reused) 'retry reused the staged copy and the same timestamp'
Assert-True ($script:RunLog[0] -like '再送開始*') 'log says it was a retry'
Assert-True (-not (Test-Path -LiteralPath $firstStage)) 'staging folder removed after the retry succeeded'

Write-Host '15 logon dialog for several servers'
$dialog = Read-FtXaml 'LogonDialog.xaml'
$d = Get-FtNamedElements $dialog @('Heading', 'UserBox', 'UserPlaceholder', 'PassBox', 'ApplyOthersBox', 'ApplyOthersText')
$d.Heading.Text = 'SV-APP01 にログオン'
$d.UserBox.Text = 'SV-APP01\Administrator'
$d.UserPlaceholder.Visibility = 'Collapsed'
$d.PassBox.Password = 'password'
$d.ApplyOthersText.Text = 'ログオンが必要なほかの 2 台（SV-APP02、SV-APP03）にも、同じアカウントで接続する'
$d.ApplyOthersBox.Visibility = 'Visible'
Show-Offscreen $dialog
Save-Screen $dialog '15-logon-multi'
$dialog.Close()

# ---- 空き容量の確認（確認ダイアログは差し替える）----
function Confirm-FtLowSpace {
    param([object[]]$Shortages)
    $script:LowSpaceAsked = $Shortages
    return $script:LowSpaceAnswer
}
$script:Config.transfer.retryCount = 2

Write-Host '16 not enough free space: stop / continue'
Remove-FtItems @($script:Items)
Add-FtPaths @("$src\other\設定_20261015.zip")
$script:Items[0].Size = 1PB   # 見かけのサイズだけ大きくする（実際に送るのは小さいファイル）
$lowSpaceFolder = Join-Path $WorkDir 'lowspace\{date}'
Set-Destination (Get-FtLocalLabel) $lowSpaceFolder
$script:LowSpaceAsked = $null
$script:LowSpaceAnswer = $false
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'space check'
Assert-True ($null -ne $script:LowSpaceAsked -and @($script:LowSpaceAsked)[0].Required -eq 1PB) 'the user is asked when space is short'
Assert-True ($script:Phase -eq 'idle' -and $ui.ResultText.Text -like '*空き容量が足りないため*') "declining stops the transfer ($($ui.ResultText.Text))"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $WorkDir 'lowspace'))) 'nothing was copied'
Save-Screen $window '16-low-space-declined'
$script:LowSpaceAnswer = $true
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'transfer after confirming'
Assert-True ($script:Phase -eq 'done') "continuing transfers anyway ($($script:Phase); $($ui.ResultText.Text))"
Assert-True (@($script:RunLog | Where-Object { $_ -like '*空き容量が足りないまま転送*' }).Count -gt 0) 'the log notes the shortage'
$script:LowSpaceAsked = $null
$script:Items[0].Size = (Get-Item -LiteralPath "$src\other\設定_20261015.zip").Length
Set-Destination (Get-FtLocalLabel) (Join-Path $WorkDir 'lowspace2')
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'normal transfer'
Assert-True ($null -eq $script:LowSpaceAsked -and $script:Phase -eq 'done') 'no question when there is enough space'
# 2 GB を超える値（Int32 を超える）でも進捗の文字列を作れるか
$progressText = Format-FtProgressText -Done 2GB -Total 4GB -Speed 100MB -HostsTotal 3 -HostsSucceeded 1
Assert-True ($progressText -eq '50%・1/3 台完了・100.0 MB/s・残り 21 秒') "progress text with large sizes ($progressText)"
Assert-True ((Format-FtProgressText -Done 3TB -Total 4TB -Speed 1GB -Staging $true) -like '75%・この PC へ取得中・1.00 GB/s・残り *') 'progress text while staging'

Write-Host '16b transfer a file larger than 2 GB'
$largeFile = Join-Path $src 'large-3gb.bin'
$stream = [IO.File]::Create($largeFile); $stream.SetLength(3GB); $stream.Close()
Remove-FtItems @($script:Items)
Add-FtPaths @($largeFile)
Set-Destination (Get-FtLocalLabel) (Join-Path $WorkDir 'large')
$script:ProgressTexts = New-Object System.Collections.Generic.List[string]
Start-FtTransfer
while ($script:Phase -eq 'running') {
    Wait-Ui 100
    if ($ui.ProgressText.Text -like '*%*') { $script:ProgressTexts.Add($ui.ProgressText.Text) }
}
Assert-True ($script:Phase -eq 'done') "3 GB transfer done ($($script:Phase); $($ui.ResultText.Text))"
Assert-True ((Get-Item -LiteralPath (Join-Path $WorkDir 'large\large-3gb.bin')).Length -eq 3GB) '3 GB file arrived'
Write-Host "    (info) progress samples: $(($script:ProgressTexts | Select-Object -Unique -First 3) -join ' | ')"
[IO.File]::Delete($largeFile)
[IO.File]::Delete((Join-Path $WorkDir 'large\large-3gb.bin'))

Write-Host '17 connected as another user: hint and disconnect'
Set-Destination $env:COMPUTERNAME 'C:\Work\{datetime}'
$script:Checks[$thisHost].Status = 'conflict'
Update-FtView
Assert-True ($ui.HintText.Text -like '*別のユーザーで接続中です*切断して再試行*ログオン…*') "conflict hint offers disconnect and logon ($($ui.HintText.Text))"
Save-Screen $window '17-conflict-hint'
Request-FtDisconnect @($thisHost)
Wait-Until { $ui.ResultPanel.Visibility -eq 'Visible' -and @($script:Checks.Values | Where-Object { $_.Status -eq 'checking' }).Count -eq 0 } -What 'disconnect'
Assert-True ($ui.ResultText.Text -like '*切断できる接続はありませんでした*') "nothing to disconnect is reported ($($ui.ResultText.Text))"
Assert-True ((Get-FtCheck $thisHost).Status -eq 'ok') 'the server is checked again after disconnecting'

Write-Host '18 transfer failed with error 1219'
$fakeHost = @{
    Name = $thisHost; HostName = $thisHost; IsLocal = $false; Dest = "\\$thisHost\C`$\Work\x"; Status = 'failed'; Elapsed = 1.0
    Result = @{ Status = 'failed'; Code = 1219; ExitCode = 16; Message = ''; Missing = @() }
    Sync = (New-FtSync); Bytes = 0L; Done = New-Object 'System.Collections.Generic.HashSet[string]'
}
$script:Run = @{
    Dist = @{ Items = @(); Stage = $null; StageFolder = ''; Hosts = @($fakeHost); Cancel = $false; Status = 'done'; Started = (Get-Date) }
    Now = (Get-Date); Key = (Get-FtDestKey); Stage = $null; IsLocal = $false; Started = (Get-Date)
    Samples = New-Object System.Collections.Generic.List[object]; ItemCount = 1; Bytes = 1L; FailedNames = @()
}
$script:Phase = 'running'
Complete-FtTransfer
Assert-True ($script:Phase -eq 'error' -and $ui.ResultText.Text -like '*別のユーザーで接続中*') "1219 result ($($ui.ResultText.Text))"
Assert-True ($ui.DisconnectLink.Visibility -eq 'Visible' -and $ui.LogonLink.Visibility -eq 'Visible' -and $script:DisconnectTargets -contains $thisHost) 'disconnect and logon links'
Save-Screen $window '18-conflict-error'
Request-FtDisconnect $script:DisconnectTargets
Wait-Until { $ui.ResultText.Text -like '*切断できる接続はありませんでした*' } -What 'disconnect in error state'
Assert-True ($script:Phase -eq 'error' -and -not $script:RetryAfterCheck) 'no retry when nothing was disconnected'

Write-Host '19 logon dialog: connected as another user'
$dialog = Read-FtXaml 'LogonDialog.xaml'
$d = Get-FtNamedElements $dialog @('Heading', 'UserBox', 'UserPlaceholder', 'PassBox', 'ErrorText', 'DisconnectButton')
$d.Heading.Text = 'SV-APP01 にログオン'
$d.UserBox.Text = 'SV-APP01\Administrator'
$d.UserPlaceholder.Visibility = 'Collapsed'
$d.PassBox.Password = 'password'
$d.ErrorText.Text = "SV-APP01 には、この PC から別のユーザーで接続中です（エラー 1219）。`n接続中：Z:（\\SV-APP01\Share）、\\SV-APP01\IPC`$"
$d.ErrorText.Visibility = 'Visible'
$d.DisconnectButton.Visibility = 'Visible'
Show-Offscreen $dialog
Save-Screen $dialog '19-logon-conflict'
$dialog.Close()

Write-Host '20 wider window, folder button'
Remove-FtItems @($script:Items)
Add-FtPaths @("$src\other\設定_20261015.zip", "$src\modules")
Wait-Until { $script:PendingSizes -eq 0 } -What 'folder size'
Set-Destination $env:COMPUTERNAME 'C:\Work\{datetime}'
$window.Width = 680
Wait-Ui 200
Assert-True ($window.ActualWidth -ge 670) "the window can be made wider ($($window.ActualWidth))"
Assert-True ($ui.AddFolderButton.IsEnabled -and $ui.AddFolderButton.Visibility -eq 'Visible') 'folder button is shown'
Assert-True ($ui.MethodBadge.Visibility -eq 'Collapsed') 'no method badge for SMB (the default)'
Save-Screen $window '20-wide'
$window.Width = 400

Write-Host '21 settings dialog'
$dialog = Read-FtXaml 'SettingsDialog.xaml'
$d = Get-FtNamedElements $dialog @('SmbRadio', 'WinRmRadio')
$d.WinRmRadio.IsChecked = $true
Show-Offscreen $dialog
Assert-True (-not $d.SmbRadio.IsChecked) 'the radio buttons are one group'
Save-Screen $dialog '21-settings'
$dialog.Close()

# ---- WinRM（この PC に起動した別の PowerShell をサーバーの代わりにする）----
$env:FILETRANSFER_TEST_WINRM_LOCAL = '1'

Write-Host '22 WinRM ready'
Set-FtMethod 'winrm'
$userSettings = Get-Content -LiteralPath $env:FILETRANSFER_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($userSettings.transfer.method -eq 'winrm') 'the method is saved to the user settings'
$winrmFolder = Join-Path $WorkDir 'winrm\{datetime}'   # サーバー上のパス（ここではこの PC のパス）
Set-Destination $env:COMPUTERNAME $winrmFolder
Assert-True ((Get-FtCheck $thisHost).Status -eq 'ok' -and (Get-FtCheck $thisHost).Root -eq "winrm:$thisHost") "WinRM host check is ok ($((Get-FtCheck $thisHost).Status) $((Get-FtCheck $thisHost).Message))"
Assert-True ($ui.HintText.Text -like "→ $WorkDir\winrm\*（WinRM）") "hint shows the server path ($($ui.HintText.Text))"
Assert-True ($ui.MethodBadge.Visibility -eq 'Visible') 'method badge is shown for WinRM'
Assert-True $ui.StartButton.IsEnabled 'start is enabled for WinRM'
Save-Screen $window '22-winrm-ready'

Write-Host '23 WinRM transfer completes'
Start-FtTransfer
Wait-Until { $script:Phase -ne 'running' } -What 'WinRM transfer' -TimeoutMs 120000
Assert-True ($script:Phase -eq 'done') "WinRM transfer done ($($script:Phase); $($ui.ResultText.Text))"
$dest = $script:Run.Dist.Hosts[0].Dest
Assert-True ($script:Run.Dist.Hosts[0].Method -eq 'winrm' -and $dest -like "$WorkDir\winrm\*") "sent with WinRM to the server path ($dest)"
Assert-True ((Test-Path -LiteralPath (Join-Path $dest '設定_20261015.zip')) -and (Test-Path -LiteralPath (Join-Path $dest 'modules\sub\b.dll'))) 'files and folders arrived over WinRM'
Assert-True ($ui.OpenLink.Visibility -eq 'Collapsed' -and $ui.RdpLink.Visibility -eq 'Visible') 'no open link for WinRM (no file sharing), RDP is offered'
Assert-True (@($script:RunLog | Where-Object { $_ -like '*（WinRM）*' }).Count -gt 0) 'the log says WinRM was used'
Save-Screen $window '23-winrm-done'

Write-Host '24 WinRM needs logon'
$script:Checks[$thisHost].Status = 'auth'
Update-FtView
Assert-True ($ui.HintText.Text -like '*ログオンが必要です*ログオン…*') "WinRM logon hint ($($ui.HintText.Text))"
$group = Connect-FtWinRmGroup -Targets @(@{ HostName = $thisHost }) -UserName "$thisHost\Administrator" -Password (ConvertTo-SecureString 'x' -AsPlainText -Force)
Assert-True ($group[0].Status -eq 'ok' -and $group[0].Credential.UserName -eq "$thisHost\Administrator") 'WinRM logon returns the credential to keep for this session'
$script:Checks[$thisHost].Status = 'error'
$script:Checks[$thisHost].Message = 'この PC の WinRM の TrustedHosts に登録されていないため、接続できません'
Update-FtView
Assert-True ($ui.HintText.Text -like "$thisHost：*TrustedHosts*") "WinRM error reason is shown ($($ui.HintText.Text))"
Save-Screen $window '24-winrm-error'
Set-Destination $thisHost '\\{host}\C$\x'
Assert-True ($ui.HintText.Text -like '*WinRM*サーバー上のパス*' -and -not $ui.StartButton.IsEnabled) "UNC folder is rejected for WinRM ($($ui.HintText.Text))"

Write-Host '25 back to SMB'
Set-FtMethod 'smb'
Set-Destination $env:COMPUTERNAME 'C:\Work\{datetime}'
Assert-True ($ui.MethodBadge.Visibility -eq 'Collapsed' -and (Get-FtCheck $thisHost).Root -like '\\*') 'SMB again after switching back'
$env:FILETRANSFER_TEST_WINRM_LOCAL = $null

$window.Close()
$acl = Get-Acl -LiteralPath $denied
[void]$acl.RemoveAccessRule($denyRule)
Set-Acl -LiteralPath $denied -AclObject $acl
Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
exit $script:Failed
