# 更新の確認: インストール時にコピー元とファイル一式のハッシュを install.json に記録し、
# 起動時にコピー元のハッシュと比べて、変わっていたら更新があると判断する

# インストール時にコピーするもの（tools\Install.ps1 もこの一覧を使う）
$script:AppFolders = @('lib', 'ui', 'launcher', 'tools')
$script:AppFiles = @('FileTransfer.ps1', 'FileTransfer.bat', 'FileTransfer.ico', 'settings.default.json')
$script:InstallInfoName = 'install.json'

function Get-FtAppContents { @{ Folders = $script:AppFolders; Files = $script:AppFiles } }

# コピーするファイル一式の SHA-256（相対パスと中身から計算する）
function Get-FtSourceHash {
    param([Parameter(Mandatory)][string]$Root)
    $root = $Root.TrimEnd('\')
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $script:AppFolders) {
        $path = Join-Path $root $folder
        if (Test-Path -LiteralPath $path) {
            Get-ChildItem -LiteralPath $path -Recurse -File | ForEach-Object { $paths.Add($_.FullName) }
        }
    }
    foreach ($file in $script:AppFiles) {
        $path = Join-Path $root $file
        if (Test-Path -LiteralPath $path) { $paths.Add($path) }
    }
    $lines = foreach ($path in $paths) {
        $relative = $path.Substring($root.Length + 1).ToLowerInvariant()
        '{0}:{1}' -f $relative, (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $text = (@($lines) | Sort-Object) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function Save-FtInstallInfo {
    param([Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Hash)
    $info = [ordered]@{ source = $Source; hash = $Hash; installedAt = (Get-Date).ToString('s') }
    [System.IO.File]::WriteAllText((Join-Path $Destination $script:InstallInfoName), ($info | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
}

function Get-FtInstallInfo {
    param([Parameter(Mandatory)][string]$AppRoot)
    $path = Join-Path $AppRoot $script:InstallInfoName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return [System.IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return $null }
}

# 更新があれば @{ Source; Installer } を返す。インストールされていない（リポジトリから直接起動した）とき、
# コピー元が見つからないとき、変わっていないときは $null
function Test-FtUpdate {
    param([Parameter(Mandatory)][string]$AppRoot)
    $info = Get-FtInstallInfo -AppRoot $AppRoot
    if (-not $info -or -not $info.source -or -not $info.hash) { return $null }
    $installer = Join-Path $info.source 'tools\Install.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { return $null }
    if ((Get-FtSourceHash -Root $info.source) -eq $info.hash) { return $null }
    return @{ Source = "$($info.source)"; Installer = $installer }
}

Export-ModuleMember -Function Get-FtAppContents, Get-FtSourceHash, Save-FtInstallInfo, Get-FtInstallInfo, Test-FtUpdate
