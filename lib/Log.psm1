# 転送ログ: %LOCALAPPDATA%\FileTransfer\logs\yyyyMMdd.log に 1 日 1 ファイルで追記する

# FILETRANSFER_LOGDIR はテスト用
$script:LogFolder = if ($env:FILETRANSFER_LOGDIR) { $env:FILETRANSFER_LOGDIR } else { Join-Path $env:LOCALAPPDATA 'FileTransfer\logs' }

function Get-FtLogFolder { $script:LogFolder }

function Get-FtLogPath { Join-Path $script:LogFolder ((Get-Date).ToString('yyyyMMdd') + '.log') }

function Write-FtLog {
    param([string[]]$Lines)
    if (-not $Lines) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:LogFolder)) { New-Item -ItemType Directory -Path $script:LogFolder -Force | Out-Null }
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $text = ($Lines | ForEach-Object { "[$stamp] $_" }) -join "`r`n"
        [System.IO.File]::AppendAllText((Get-FtLogPath), $text + "`r`n", [System.Text.Encoding]::UTF8)
    } catch { }
}

function Remove-FtOldLogs {
    param([int]$RetentionDays = 30)
    if ($RetentionDays -le 0 -or -not (Test-Path -LiteralPath $script:LogFolder)) { return }
    $limit = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $script:LogFolder -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-FtLogFolder, Get-FtLogPath, Write-FtLog, Remove-FtOldLogs
