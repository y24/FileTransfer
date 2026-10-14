# 送り先の解決: テンプレート展開、サーバー上のパス → UNC 変換、入力チェック

$script:LocalNames = @('このPC', 'この PC', 'localhost', '.')
$script:LocalLabel = 'このPC'

function Get-FtLocalLabel { $script:LocalLabel }

# 送り先欄の値が「このPC」を指すか
function Test-FtLocalDestination {
    param([string]$Destination)
    $value = "$Destination".Trim()
    foreach ($name in $script:LocalNames) { if ($value -ieq $name) { return $true } }
    return $false
}

function Test-FtHostName {
    param([string]$HostName)
    return "$HostName" -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# {datetime} {date} {time} {now:書式} {user} {host} を展開する
function Expand-FtTemplate {
    param(
        [string]$Template,
        [datetime]$Now = (Get-Date),
        [string]$HostName = '',
        [string]$UserName = $env:USERNAME
    )
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        $name = $match.Groups['name'].Value.ToLowerInvariant()
        $format = $match.Groups['format'].Value
        switch ($name) {
            'datetime' { return $Now.ToString('yyyyMMdd_HHmm') }
            'date'     { return $Now.ToString('yyyyMMdd') }
            'time'     { return $Now.ToString('HHmm') }
            'now'      { if ($format) { return $Now.ToString($format) } else { return $Now.ToString('yyyyMMdd_HHmm') } }
            'user'     { return $UserName }
            'host'     { return $HostName }
            default    { return $match.Value }
        }
    }
    return [regex]::Replace("$Template", '\{(?<name>[A-Za-z]+)(?::(?<format>[^}]+))?\}', $evaluator)
}

# \\host\share\... から \\host\share を取り出す
function Get-FtShareRoot {
    param([string]$UncPath)
    if ("$UncPath" -match '^(\\\\[^\\]+\\[^\\]+)') { return $Matches[1] }
    return $null
}

function Get-FtUncHost {
    param([string]$UncPath)
    if ("$UncPath" -match '^\\\\([^\\]+)\\') { return $Matches[1] }
    return $null
}

# 送り先とフォルダ欄の値から、実際にコピーする先のパスを求める
# 戻り値: @{ Path; Error; IsLocal; HostName; ShareRoot }
function Resolve-FtDestination {
    param(
        [string]$Destination,
        [string]$Folder,
        [datetime]$Now = (Get-Date),
        [object[]]$Mappings = @(),
        [hashtable]$HostAlias = @{},
        [string]$UserName = $env:USERNAME
    )
    $isLocal = Test-FtLocalDestination $Destination
    $hostName = if ($isLocal) { '' } else { "$Destination".Trim().ToUpperInvariant() }
    $result = @{ Path = $null; Error = $null; IsLocal = $isLocal; HostName = $hostName; ShareRoot = $null }

    if (-not $isLocal) {
        if (-not $hostName) { $result.Error = 'ホスト名を入力するか、▾ から選んでください'; return $result }
        if (-not (Test-FtHostName $hostName)) { $result.Error = 'ホスト名が正しくありません'; return $result }
    }

    $raw = "$Folder".Trim()
    if (-not $raw) { $result.Error = 'フォルダを入力してください'; return $result }
    $expanded = Expand-FtTemplate -Template $raw -Now $Now -HostName $hostName -UserName $UserName
    if ($isLocal) { $expanded = [Environment]::ExpandEnvironmentVariables($expanded) }
    $expanded = $expanded -replace '/', '\'

    # ドライブ名（C:）や UNC の先頭（\\）を除いた部分に、フォルダ名に使えない文字がないか
    $body = $expanded -replace '^[A-Za-z]:', '' -replace '^\\\\', ''
    if ($body -match '[:*?"<>|]') {
        $result.Error = 'フォルダ名に使えない文字があります（: * ? " < > |）'
        return $result
    }

    if ($expanded -match '^\\\\[^\\]+\\[^\\]+') {
        $result.Path = $expanded.TrimEnd('\')
        $result.ShareRoot = Get-FtShareRoot $result.Path
        if (-not $isLocal) { $result.HostName = (Get-FtUncHost $result.Path).ToUpperInvariant() }
        return $result
    }

    if ($expanded -notmatch '^(?<drive>[A-Za-z]):(?<rest>\\.*)?$') {
        $result.Error = if ($isLocal) { 'D:\… または \\サーバー\共有\… の形式で入力してください' } else { 'サーバー上のパスを C:\Work のように入力してください' }
        return $result
    }
    $drive = $Matches['drive'].ToUpperInvariant()
    $rest = "$($Matches['rest'])".TrimEnd('\')

    if ($isLocal) {
        $result.Path = if ($rest) { "${drive}:$rest" } else { "${drive}:\" }
        return $result
    }

    # 設定ファイルの serverShareMappings（例: SV-LEGACY01 の C:\Work → \\SV-LEGACY01\Work$）
    $serverPath = "${drive}:$rest"
    foreach ($mapping in @($Mappings)) {
        if ($null -eq $mapping) { continue }
        $mapHost = "$($mapping.host)"
        $mapPath = "$($mapping.serverPath)".TrimEnd('\')
        if ($mapHost -ine $hostName -or -not $mapPath) { continue }
        if ($serverPath -ieq $mapPath -or $serverPath.StartsWith("$mapPath\", [StringComparison]::OrdinalIgnoreCase)) {
            $share = "$($mapping.share)".TrimEnd('\')
            $result.Path = $share + $serverPath.Substring($mapPath.Length)
            $result.ShareRoot = Get-FtShareRoot $result.Path
            return $result
        }
    }

    # 同じサーバーに別のユーザーで接続済みのときは、別名（FQDN など）で接続している
    $connectName = if ($HostAlias.ContainsKey($hostName)) { $HostAlias[$hostName] } else { $hostName }
    $result.ShareRoot = "\\$connectName\$drive`$"
    $result.Path = $result.ShareRoot + $rest
    return $result
}

Export-ModuleMember -Function Get-FtLocalLabel, Test-FtLocalDestination, Test-FtHostName, Expand-FtTemplate, Get-FtShareRoot, Get-FtUncHost, Resolve-FtDestination
