#Requires -Version 5.1
<#
.SYNOPSIS
    FileTransfer を、ログオン中のユーザーにインストールする（管理者権限は不要）
.DESCRIPTION
    %LOCALAPPDATA%\Programs\FileTransfer にファイルをコピーし、FileTransfer.exe をビルドして、
    デスクトップとスタートメニューにショートカットを作る。もう一度実行すると上書き更新する。
.PARAMETER Uninstall
    プログラムとショートカットを削除する（設定 %APPDATA%\FileTransfer とログは残す）
.PARAMETER WaitProcessId
    （アプリの［更新］から呼ぶとき）このプロセスが終わるのを待ってから更新する
.PARAMETER Restart
    （アプリの［更新］から呼ぶとき）更新が終わったら FileTransfer を起動する。失敗はメッセージボックスで知らせる
#>
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\FileTransfer'),
    [switch]$Uninstall,
    [int]$WaitProcessId = 0,
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot

# アプリから呼ばれたときは画面が出ていないので、失敗をメッセージボックスで知らせる
trap {
    if (-not $Restart) { break }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("FileTransfer を更新できませんでした。`n$($_.Exception.Message)`n`nコピー元の install.bat を実行して更新してください:`n$source",
        'FileTransfer', 'OK', 'Error') | Out-Null
    exit 1
}

Import-Module (Join-Path $source 'lib\Update.psm1') -Force -DisableNameChecking
$contents = Get-FtAppContents
$shortcutPaths = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'FileTransfer.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'FileTransfer.lnk')
)

if ($Uninstall) {
    foreach ($path in $shortcutPaths) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    Write-Host 'FileTransfer を削除しました。（設定は %APPDATA%\FileTransfer に残っています）'
    return
}

# 更新を始めたアプリと、それを起動したランチャー（FileTransfer.exe。使用中だと作り直せない）が終わるのを待つ
if ($WaitProcessId -gt 0) {
    Wait-Process -Id $WaitProcessId -Timeout 30 -ErrorAction SilentlyContinue
    $launcher = Join-Path $Destination 'FileTransfer.exe'
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and
        @(Get-Process -Name FileTransfer -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $launcher }).Count -gt 0) {
        Start-Sleep -Milliseconds 300
    }
}

if (Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq 'FileTransfer' }) {
    throw 'FileTransfer が起動中です。閉じてからもう一度実行してください。'
}

# 本体をコピーする（lib と ui は古いファイルが残らないように入れ替える）
if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
$hash = Get-FtSourceHash -Root $source
foreach ($folder in $contents.Folders) {
    $target = Join-Path $Destination $folder
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $source $folder) -Destination $target -Recurse -Force
}
foreach ($file in $contents.Files) {
    $path = Join-Path $source $file
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $Destination -Force }
}

# ランチャー（コンソールを出さずに起動する FileTransfer.exe）をビルドする
$exe = Join-Path $Destination 'FileTransfer.exe'
try {
    & (Join-Path $Destination 'tools\Build-Launcher.ps1') -OutputDirectory $Destination | Out-Null
} catch {
    Write-Warning "FileTransfer.exe を作れなかったため、PowerShell から直接起動するショートカットにします。`n$($_.Exception.Message)"
    $exe = $null
}

# ショートカット
$shell = New-Object -ComObject WScript.Shell
foreach ($path in $shortcutPaths) {
    $shortcut = $shell.CreateShortcut($path)
    if ($exe) {
        $shortcut.TargetPath = $exe
        $shortcut.Arguments = ''
    } else {
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments = '-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $Destination 'FileTransfer.ps1')
    }
    $shortcut.WorkingDirectory = $Destination
    $icon = Join-Path $Destination 'FileTransfer.ico'
    if (Test-Path -LiteralPath $icon) { $shortcut.IconLocation = $icon }
    $shortcut.Description = '共有フォルダ・この PC・サーバーの間でファイルを転送する'
    $shortcut.Save()
}

# 起動時に、コピー元が更新されたかどうかを調べるため
Save-FtInstallInfo -Destination $Destination -Source $source -Hash $hash

if ($Restart) {
    if ($exe) {
        Start-Process -FilePath $exe -WorkingDirectory $Destination
    } else {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WorkingDirectory $Destination `
            -ArgumentList ('-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $Destination 'FileTransfer.ps1'))
    }
    return
}

Write-Host "FileTransfer をインストールしました: $Destination"
Write-Host 'デスクトップとスタートメニューの「FileTransfer」から起動できます。'
