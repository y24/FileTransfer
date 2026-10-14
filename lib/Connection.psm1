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

Export-ModuleMember -Function Get-FtAccessStatus, Test-FtTcpPort, Test-FtShareAccess, Get-FtCurrentUser, Get-FtSavedUser, Get-FtHostAliases, Connect-FtShare, Disconnect-FtShare
