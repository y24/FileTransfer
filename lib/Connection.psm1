# サーバーへの接続確認と資格情報（ログオン）
# FileTransfer.Native（lib\Native.cs）が読み込まれている前提

# Win32 エラーコード → 接続状態
function Get-FtAccessStatus {
    param([int]$Code)
    switch ($Code) {
        0 { return 'ok' }
        { $_ -in 5, 86, 1326, 1327, 1330, 1331, 1385, 1907, 1909, 2242 } { return 'auth' }
        67 { return 'noshare' }
        1219 { return 'conflict' }
        { $_ -in 51, 53, 64, 121, 1231, 1232 } { return 'unreachable' }
        default { return 'error' }
    }
}

function Test-FtTcpPort {
    param([string]$HostName, [int]$Port = 445, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

# \\host\share にアクセスできるか確認する（バックグラウンドで呼ぶ）
# 戻り値: @{ Status = ok|auth|noshare|conflict|unreachable|error; Code }
function Test-FtShareAccess {
    param([string]$ShareRoot, [int]$TimeoutMs = 2000)
    $hostName = ([regex]::Match($ShareRoot, '^\\\\([^\\]+)')).Groups[1].Value
    if (-not (Test-FtTcpPort -HostName $hostName -Port 445 -TimeoutMs $TimeoutMs)) {
        return @{ Status = 'unreachable'; Code = 53 }
    }
    $code = [FileTransfer.Native]::GetPathError($ShareRoot.TrimEnd('\') + '\')
    return @{ Status = (Get-FtAccessStatus $code); Code = $code }
}

function Get-FtCurrentUser { "$env:USERDOMAIN\$env:USERNAME" }

# 保存済みの資格情報のユーザー名（なければ $null）
function Get-FtSavedUser {
    param([string]$Target)
    return [FileTransfer.Native]::ReadCredentialUser($Target)
}

function Get-FtHostAliases {
    param([string]$HostName)
    $aliases = New-Object System.Collections.Generic.List[string]
    try {
        $entry = [System.Net.Dns]::GetHostEntry($HostName)
        if ($entry.HostName -and $entry.HostName -ine $HostName) { $aliases.Add($entry.HostName) }
        foreach ($address in $entry.AddressList) {
            if ($address.AddressFamily -eq 'InterNetwork') { $aliases.Add($address.ToString()); break }
        }
    } catch { }
    return , $aliases.ToArray()
}

# 指定したユーザーで \\host\share に接続する（バックグラウンドで呼ぶ）
# 同じサーバーに別のユーザーで接続済み（エラー 1219）のときは、FQDN や IP アドレスで接続し直す
# 戻り値: @{ Code; Status; ConnectName; Root; Saved; SaveError }
function Connect-FtShare {
    param(
        [string]$HostName,
        [string]$ShareRoot,
        [string]$UserName,
        [System.Security.SecureString]$Password,
        [switch]$Save
    )
    $root = $ShareRoot.TrimEnd('\')
    $connectName = $HostName
    $code = [FileTransfer.Native]::AddConnection($root, $UserName, $Password)
    if ($code -eq 1219) {
        # このアプリが以前に別ユーザーで張った接続なら切って再試行
        [void][FileTransfer.Native]::CancelConnection($root, $true)
        $code = [FileTransfer.Native]::AddConnection($root, $UserName, $Password)
    }
    if ($code -eq 1219) {
        $rootHost = ([regex]::Match($root, '^\\\\([^\\]+)')).Groups[1].Value
        foreach ($alias in (Get-FtHostAliases $rootHost)) {
            $aliasRoot = $root -replace '^\\\\[^\\]+', ('\\' + $alias)
            $aliasCode = [FileTransfer.Native]::AddConnection($aliasRoot, $UserName, $Password)
            if ($aliasCode -ne 1219) {
                $code = $aliasCode
                $root = $aliasRoot
                $connectName = $alias
                break
            }
        }
    }

    $result = @{ Code = $code; Status = (Get-FtAccessStatus $code); ConnectName = $connectName; Root = $root; Saved = $false; SaveError = 0 }
    if ($code -eq 0 -and $Save) {
        $saveCode = [FileTransfer.Native]::WriteCredential($HostName, $UserName, $Password)
        $result.Saved = ($saveCode -eq 0)
        $result.SaveError = $saveCode
    }
    return $result
}

function Disconnect-FtShare {
    param([string]$Root)
    [void][FileTransfer.Native]::CancelConnection($Root, $false)
}

# 別のサーバーに同じアカウントで接続するときのユーザー名
#   ローカルアカウント（SV-APP01\Administrator、.\Administrator）→ SV-APP02\Administrator
#   ドメインアカウント（CORP\yamada、yamada@corp.example）→ そのまま
function Convert-FtUserForHost {
    param([string]$UserName, [string]$FromHost, [string]$ToHost)
    $index = $UserName.IndexOf('\')
    if ($index -gt 0) {
        $prefix = $UserName.Substring(0, $index)
        if ($prefix -eq '.' -or $prefix -ieq $FromHost) { return "$ToHost\" + $UserName.Substring($index + 1) }
    }
    return $UserName
}

# 1 台目にログオンし、成功したら残りのサーバーにも同じアカウントで接続する（バックグラウンドで呼ぶ）
# Targets: @{ HostName; ShareRoot } の配列（先頭がログオンダイアログを開いたサーバー）
# 戻り値: Connect-FtShare の結果に HostName と UserName を加えたものの配列
function Connect-FtShareGroup {
    param(
        [object[]]$Targets,
        [string]$UserName,
        [System.Security.SecureString]$Password,
        [switch]$Save
    )
    $first = $Targets[0].HostName
    $results = @()
    foreach ($target in $Targets) {
        $user = Convert-FtUserForHost -UserName $UserName -FromHost $first -ToHost $target.HostName
        $result = Connect-FtShare -HostName $target.HostName -ShareRoot $target.ShareRoot -UserName $user -Password $Password -Save:$Save
        $result.HostName = $target.HostName
        $result.UserName = $user
        $results += $result
        if ($results.Count -eq 1 -and $result.Code -ne 0) { break }
    }
    return , $results
}

# 接続一覧（"ローカル名|リモート名"）から、指定したホスト名（別名を含む）への接続を選ぶ
function Select-FtHostConnections {
    param([string[]]$Connections, [string[]]$Names)
    $selected = @()
    foreach ($entry in @($Connections)) {
        $parts = "$entry".Split([char[]]'|', 2)
        if ($parts.Count -lt 2) { continue }
        if ($parts[1] -notmatch '^\\\\([^\\]+)') { continue }
        $hostName = $Matches[1]
        if (@($Names | Where-Object { $_ -ieq $hostName }).Count -gt 0) {
            $selected += @{ Local = $parts[0]; Remote = $parts[1] }
        }
    }
    return , $selected
}

# この PC からそのサーバーへの「net use」の接続（ネットワーク ドライブを含む）
# IncludeAliases を付けると FQDN・IP アドレスでの接続も探す（名前解決をするので少し遅い）
function Get-FtHostConnections {
    param([string]$HostName, [switch]$IncludeAliases)
    $names = @($HostName)
    if ($IncludeAliases) { $names += Get-FtHostAliases $HostName }
    return , (Select-FtHostConnections -Connections ([FileTransfer.Native]::GetConnections()) -Names $names)
}

function Format-FtConnection {
    param([hashtable]$Connection)
    if ($Connection.Local) { return "$($Connection.Local)（$($Connection.Remote)）" }
    return $Connection.Remote
}

# エラー 1219（別のユーザーで接続中）を解消するため、そのサーバーへの接続を切断する（バックグラウンドで呼ぶ）
# 使用中のファイルがある接続は無理に切らない（force = false）。ネットワーク ドライブの登録自体は残る
# 戻り値: @{ HostName; Closed = 切断した接続の説明; Failed = 切断できなかった接続の説明 }
function Disconnect-FtHostConnections {
    param([string]$HostName)
    $closed = @()
    $failed = @()
    foreach ($connection in (Get-FtHostConnections -HostName $HostName -IncludeAliases)) {
        $name = if ($connection.Local) { $connection.Local } else { $connection.Remote }
        $code = [FileTransfer.Native]::CancelConnection($name, $false)
        if ($code -eq 0) { $closed += Format-FtConnection $connection }
        else { $failed += "$(Format-FtConnection $connection)（エラー $code）" }
    }
    return @{ HostName = $HostName; Closed = $closed; Failed = $failed }
}

Export-ModuleMember -Function Get-FtAccessStatus, Test-FtTcpPort, Test-FtShareAccess, Get-FtCurrentUser, Get-FtSavedUser, Get-FtHostAliases, Connect-FtShare, Disconnect-FtShare, Convert-FtUserForHost, Connect-FtShareGroup, Select-FtHostConnections, Get-FtHostConnections, Format-FtConnection, Disconnect-FtHostConnections
