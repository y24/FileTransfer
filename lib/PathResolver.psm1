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
# Method が winrm のときは、サーバーへは PowerShell リモートで送るので、サーバー上のパス（C:\Work\...）のまま返す
# 戻り値: @{ Path; Error; IsLocal; HostName; ShareRoot; Method }（Method は このPC なら local、それ以外は smb | winrm）
function Resolve-FtDestination {
    param(
        [string]$Destination,
        [string]$Folder,
        [datetime]$Now = (Get-Date),
        [object[]]$Mappings = @(),
        [hashtable]$HostAlias = @{},
        [string]$UserName = $env:USERNAME,
        [ValidateSet('smb', 'winrm')][string]$Method = 'smb'
    )
    $isLocal = Test-FtLocalDestination $Destination
    $hostName = if ($isLocal) { '' } else { "$Destination".Trim().ToUpperInvariant() }
    $result = @{ Path = $null; Error = $null; IsLocal = $isLocal; HostName = $hostName; ShareRoot = $null; Method = $(if ($isLocal) { 'local' } else { $Method }) }
    $winrm = -not $isLocal -and $Method -eq 'winrm'

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
        if ($winrm) { $result.Error = 'WinRM で送るときは、フォルダをサーバー上のパス（C:\Work など）で入力してください'; return $result }
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

    if ($isLocal -or $winrm) {
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

# 送り先欄の値を送り先ごとに分ける（カンマ・セミコロン・読点・空白区切り、大文字小文字を区別せず重複を除く）
function Split-FtDestinations {
    param([string]$Destination)
    $normalized = "$Destination" -replace 'この\s+PC', 'このPC'
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in ($normalized -split '[,;、\s]+')) {
        if (-not $name) { continue }
        if (-not ($names | Where-Object { $_ -ieq $name })) { $names.Add($name) }
    }
    return , $names.ToArray()
}

# 送り先欄（複数可）とフォルダ欄から、送り先ごとの実際のパスを求める
# 戻り値: @{ Targets = Resolve-FtDestination の結果の配列; Names; Error; IsLocal; IsMulti }
function Resolve-FtDestinations {
    param(
        [string]$Destination,
        [string]$Folder,
        [datetime]$Now = (Get-Date),
        [object[]]$Mappings = @(),
        [hashtable]$HostAlias = @{},
        [string]$UserName = $env:USERNAME,
        [ValidateSet('smb', 'winrm')][string]$Method = 'smb'
    )
    $names = Split-FtDestinations $Destination
    $locals = @($names | Where-Object { Test-FtLocalDestination $_ })
    $result = @{ Targets = @(); Names = $names; Error = $null; IsLocal = ($locals.Count -gt 0); IsMulti = ($names.Count -gt 1) }
    if ($names.Count -eq 0) {
        # ホスト名が空のときも、フォルダ欄のチェック結果は返す
        $empty = Resolve-FtDestination -Destination '' -Folder $Folder -Now $Now -Mappings $Mappings -HostAlias $HostAlias -UserName $UserName -Method $Method
        $result.Error = $empty.Error
        return $result
    }
    if ($locals.Count -gt 0 -and $names.Count -gt 1) {
        $result.Error = '「このPC」とサーバーは一緒に指定できません'
        return $result
    }
    $targets = @()
    foreach ($name in $names) {
        $target = Resolve-FtDestination -Destination $name -Folder $Folder -Now $Now -Mappings $Mappings -HostAlias $HostAlias -UserName $UserName -Method $Method
        if ($target.Error) {
            $result.Error = if ($target.Error -eq 'ホスト名が正しくありません') { "ホスト名が正しくありません: $name" } else { $target.Error }
            return $result
        }
        $targets += $target
    }
    if ($targets.Count -gt 1) {
        # WinRM ではパス（C:\Work\...）が全台で同じになるので、ホスト名と組みにして比べる
        $paths = @($targets | ForEach-Object { "$($_.HostName)|$($_.Path)".ToLowerInvariant() } | Select-Object -Unique)
        if ($paths.Count -lt $targets.Count) {
            $result.Error = '複数のサーバーに送るときは、フォルダを C:\Work のようなサーバー上のパスで指定してください'
            return $result
        }
    }
    $result.Targets = $targets
    return $result
}

# 送り先欄に書く形（大文字、カンマ区切り）
function Format-FtDestinations {
    param([string[]]$Names)
    return (@($Names | ForEach-Object { if (Test-FtLocalDestination $_) { $script:LocalLabel } else { $_.ToUpperInvariant() } }) -join ', ')
}

Export-ModuleMember -Function Get-FtLocalLabel, Test-FtLocalDestination, Test-FtHostName, Expand-FtTemplate, Get-FtShareRoot, Get-FtUncHost, Resolve-FtDestination, Split-FtDestinations, Resolve-FtDestinations, Format-FtDestinations
