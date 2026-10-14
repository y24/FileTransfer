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
    Wait-Until { $script:Check.Status -ne 'checking' } -What 'host check'
}

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
Assert-True ($script:Check.Status -eq 'ok') "host check is ok ($($script:Check.Status))"
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
Wait-Until { $script:Run.Sync.BytesDone -gt 0 } -What 'progress' -TimeoutMs 20000
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
$dest = $script:Run.Dest
Assert-True ($dest -like "\\$($env:COMPUTERNAME)\C$\*") "destination is the admin share ($dest)"
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
$script:Check.Status = 'auth'
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

$window.Close()
$acl = Get-Acl -LiteralPath $denied
[void]$acl.RemoveAccessRule($denyRule)
Set-Acl -LiteralPath $denied -AclObject $acl
Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
exit $script:Failed
