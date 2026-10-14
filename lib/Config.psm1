# 設定と履歴の読み書き
# 優先順位: 組み込みの既定値 < 配布フォルダの settings.default.json < %APPDATA%\FileTransfer\settings.json

# FILETRANSFER_CONFIG はテスト用（ユーザーの設定を書き換えないため）
$script:UserConfigPath = if ($env:FILETRANSFER_CONFIG) { $env:FILETRANSFER_CONFIG } else { Join-Path $env:APPDATA 'FileTransfer\settings.json' }

function Get-FtBuiltinConfig {
    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    @{
        version = 1
        history = @{
            destinations  = @()
            serverFolders = @('C:\Work\{datetime}')
            localFolders  = @("$downloads\Transfer\{datetime}")
            lastOpenDir   = ''
        }
        last = @{
            destination = ''
            folder      = ''
        }
        window = @{}
        serverShareMappings = @()
        transfer = @{
            retryCount            = 2
            retryWaitSec          = 3
            unbufferedThresholdMB = 256
            threadsForFolders     = 8
            parallelHosts         = 3
            keepLocalCopy         = $false
            localCopyFolder       = "$downloads\Transfer\{datetime}"
        }
        log = @{
            retentionDays = 30
        }
    }
}

# ConvertFrom-Json の結果（PSCustomObject）をハッシュテーブルに変換する（PS 5.1 には -AsHashtable がない）
function ConvertTo-FtHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-FtHashtable $property.Value
        }
        return $table
    }
    if ($InputObject -is [System.Collections.IList] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-FtHashtable $_ })
    }
    return $InputObject
}

# Overlay の値で Base を上書きした新しいハッシュテーブルを返す（ハッシュテーブル同士は再帰的にマージ）
function Merge-FtConfig {
    param([hashtable]$Base, [hashtable]$Overlay)
    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    if ($null -eq $Overlay) { return $result }
    foreach ($key in $Overlay.Keys) {
        if ($result[$key] -is [hashtable] -and $Overlay[$key] -is [hashtable]) {
            $result[$key] = Merge-FtConfig $result[$key] $Overlay[$key]
        } else {
            $result[$key] = $Overlay[$key]
        }
    }
    return $result
}

function Read-FtJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ConvertTo-FtHashtable ($text | ConvertFrom-Json)
    } catch {
        Write-Warning "設定ファイルを読み込めませんでした: $Path ($($_.Exception.Message))"
        return $null
    }
}

function Get-FtConfig {
    param([string]$AppRoot, [string]$UserConfigPath = $script:UserConfigPath)
    $config = Get-FtBuiltinConfig
    if ($AppRoot) {
        $config = Merge-FtConfig $config (Read-FtJsonFile (Join-Path $AppRoot 'settings.default.json'))
    }
    $userConfig = Read-FtJsonFile $UserConfigPath
    # 初回起動時は配布側の履歴を使い、2 回目以降はユーザーの履歴をそのまま使う
    return Merge-FtConfig $config $userConfig
}

# ユーザーの設定ファイルには、履歴・前回の値・ウィンドウ位置だけを書く。
# transfer や serverShareMappings などは書かないので、配布側の settings.default.json を更新すれば全員に届く
# （ユーザーが自分で settings.json に書いた項目は消さずに残す）
$script:UserStateKeys = @('history', 'last', 'window')

function Save-FtConfig {
    param([hashtable]$Config, [string]$UserConfigPath = $script:UserConfigPath)
    $userConfig = Read-FtJsonFile $UserConfigPath
    if ($null -eq $userConfig) { $userConfig = @{} }
    $userConfig['version'] = 1
    foreach ($key in $script:UserStateKeys) {
        if ($Config.ContainsKey($key)) { $userConfig[$key] = $Config[$key] }
    }
    $dir = Split-Path -Parent $UserConfigPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $userConfig | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($UserConfigPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

# 履歴の先頭に Value を追加する（大文字小文字を区別せず重複を除き、最大 Max 件）
function Add-FtHistory {
    param([object[]]$List, [string]$Value, [int]$Max = 10)
    if ([string]::IsNullOrWhiteSpace($Value)) { return , @($List) }
    $items = New-Object System.Collections.Generic.List[string]
    $items.Add($Value.Trim())
    foreach ($item in @($List)) {
        if ($null -eq $item -or "$item" -eq '') { continue }
        if (-not $items.Contains("$item") -and -not ($items | Where-Object { $_ -ieq "$item" })) { $items.Add("$item") }
        if ($items.Count -ge $Max) { break }
    }
    return , $items.ToArray()
}

Export-ModuleMember -Function Get-FtConfig, Save-FtConfig, Add-FtHistory, Merge-FtConfig, ConvertTo-FtHashtable, Get-FtBuiltinConfig
