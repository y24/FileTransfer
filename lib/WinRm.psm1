# WinRM（PowerShell リモート）での転送: SMB（ファイル共有）で接続できないサーバーへ送る
#   - サーバーに PowerShell リモートで接続し、ファイルを少しずつ（既定 2 MB ずつ）送って書き込む。小さいファイルはまとめて送る
#   - 送り先はサーバー上のパス（C:\Work\...）。フォルダはサブフォルダごと、フォルダの構成のまま作る（空のフォルダも作る）
#   - 送り先に同じサイズ・同じ更新日時のファイルがあれば送らない（robocopy と同じく、やり直しのときに届いている分を省く）
#   - 書き込み中は「名前.ftpart」に書き、書き終わってから名前を変える（中止・失敗しても書きかけのファイルを残さない）
#   - 資格情報は Windows 資格情報マネージャーの「汎用資格情報」（FileTransfer:WinRM:ホスト名）に保存する
#     （SMB 用の「Windows 資格情報」はパスワードを読み出せず、WinRM では使えないため）
# 進捗は TransferEngine.psm1 の Invoke-FtTransferPlan と同じ共有状態（Sync）に書く。
# FILETRANSFER_TEST_WINRM_LOCAL を設定すると、サーバーの代わりにこの PC の Runspace で動かす（テスト用）

$script:CredentialPrefix = 'FileTransfer:WinRM:'
$script:BatchMaxFiles = 200      # 小さいファイルを 1 回にまとめて送る数の上限
$script:PrepareBatch = 1000      # フォルダ作成・同じファイルの確認を 1 回で行う数の上限

# サーバー側で動かす処理。接続ごとに 1 回送って $global:FtAgent に置き、コマンド名と引数（ハッシュテーブル）で呼ぶ。
# 戻り値は @{ Ok = $true; ... } か @{ Ok = $false; Code = Win32 のエラーコード; Message }。
# Windows Server 2012 R2（PowerShell 4.0）以前でも動くように、PowerShell 3.0 の書き方だけを使う。
$script:AgentSource = @'
param([string]$Command, $Arguments)
$ErrorActionPreference = 'Stop'
if ($null -eq $global:FtAgentState) { $global:FtAgentState = @{ Stream = $null; Temp = ''; Final = '' } }
$state = $global:FtAgentState

function Get-FtAgentErrorCode {
    param($Exception)
    if ($Exception -is [System.UnauthorizedAccessException]) { return 5 }
    $hr = [System.Runtime.InteropServices.Marshal]::GetHRForException($Exception)
    if (($hr -band 0xFFFF0000) -eq 0x80070000) { return ($hr -band 0xFFFF) }
    return 0
}

function Close-FtAgentStream {
    if ($state.Stream) { try { $state.Stream.Dispose() } catch { }; $state.Stream = $null }
    if ($state.Temp -and [System.IO.File]::Exists($state.Temp)) { try { [System.IO.File]::Delete($state.Temp) } catch { } }
    $state.Temp = ''
}

# 書き終えた一時ファイルを本来の名前にして、更新日時をコピー元に合わせる
function Complete-FtAgentFile {
    param([string]$Temp, [string]$Final, [long]$Time)
    if ([System.IO.File]::Exists($Final)) {
        [System.IO.File]::SetAttributes($Final, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::Delete($Final)
    }
    [System.IO.File]::Move($Temp, $Final)
    if ($Time -gt 0) { [System.IO.File]::SetLastWriteTimeUtc($Final, (New-Object System.DateTime -ArgumentList $Time, ([System.DateTimeKind]::Utc))) }
}

try {
    switch ($Command) {
        'info' {
            return @{ Ok = $true; User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name; Computer = $env:COMPUTERNAME; Version = "$($PSVersionTable.PSVersion)" }
        }
        'space' {
            # Path: 送り先フォルダ、Files: @{ Name; Size }（同じサイズのものが既にあれば数えない）、Bytes: そのほかに必要なバイト数
            $required = [long]$Arguments.Bytes
            foreach ($file in $Arguments.Files) {
                $existing = [System.IO.Path]::Combine("$($Arguments.Path)", "$($file.Name)")
                if ([System.IO.File]::Exists($existing) -and (New-Object System.IO.FileInfo $existing).Length -eq [long]$file.Size) { continue }
                $required += [long]$file.Size
            }
            $folder = "$($Arguments.Path)".TrimEnd('\')
            if ($folder -match '^[A-Za-z]:$') { $folder += '\' }
            while ($folder -and -not [System.IO.Directory]::Exists($folder)) { $folder = [System.IO.Path]::GetDirectoryName($folder) }
            $free = -1
            if ($folder) { $free = (New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($folder))).AvailableFreeSpace }
            return @{ Ok = $true; Free = [long]$free; Required = $required }
        }
        'prepare' {
            # Dirs: 作るフォルダ、Files: @{ Path; Size; Time } → Same: 送り先に同じもの（サイズと更新日時が同じ）があるか
            foreach ($dir in $Arguments.Dirs) { if ($dir) { [void][System.IO.Directory]::CreateDirectory($dir) } }
            $same = New-Object 'System.Collections.Generic.List[bool]'
            foreach ($file in $Arguments.Files) {
                $info = New-Object System.IO.FileInfo "$($file.Path)"
                $same.Add($info.Exists -and $info.Length -eq [long]$file.Size -and $info.LastWriteTimeUtc.Ticks -eq [long]$file.Time)
            }
            return @{ Ok = $true; Same = $same.ToArray() }
        }
        'put' {
            # 小さいファイルをまとめて書く。Files: @{ Path; Bytes; Time }
            foreach ($file in $Arguments.Files) {
                $state.Temp = "$($file.Path).ftpart"
                $bytes = [byte[]]$file.Bytes
                if ($null -eq $bytes) { $bytes = New-Object byte[] 0 }
                [System.IO.File]::WriteAllBytes($state.Temp, $bytes)
                Complete-FtAgentFile $state.Temp "$($file.Path)" ([long]$file.Time)
                $state.Temp = ''
            }
            return @{ Ok = $true }
        }
        'open' {
            # 大きいファイル: open → write（何回か）→ close。Path: 送り先のファイル、Size: 大きさ（先に領域を確保する）
            Close-FtAgentStream
            $state.Final = "$($Arguments.Path)"
            $state.Temp = "$($Arguments.Path).ftpart"
            $state.Stream = New-Object System.IO.FileStream -ArgumentList $state.Temp, ([System.IO.FileMode]::Create), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None), 1048576
            if ([long]$Arguments.Size -gt 0) { $state.Stream.SetLength([long]$Arguments.Size) }
            return @{ Ok = $true }
        }
        'write' {
            $bytes = [byte[]]$Arguments.Bytes
            $state.Stream.Write($bytes, 0, $bytes.Length)
            return @{ Ok = $true }
        }
        'close' {
            # 送った分の長さにそろえる（読んでいる間にコピー元が短くなったとき）
            $state.Stream.SetLength($state.Stream.Position)
            $state.Stream.Dispose()
            $state.Stream = $null
            Complete-FtAgentFile $state.Temp $state.Final ([long]$Arguments.Time)
            $state.Temp = ''
            return @{ Ok = $true }
        }
        'abort' {
            Close-FtAgentStream
            return @{ Ok = $true }
        }
        default { return @{ Ok = $false; Code = 0; Message = "unknown command: $Command" } }
    }
} catch {
    $exception = $_.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    Close-FtAgentStream
    return @{ Ok = $false; Code = (Get-FtAgentErrorCode $exception); Message = $exception.Message }
}
'@

#region 資格情報 ------------------------------------------------------------------

function Get-FtWinRmCredentialTarget {
    param([string]$HostName)
    return $script:CredentialPrefix + "$HostName".ToUpperInvariant()
}

# 保存済みの資格情報（なければ $null）
function Get-FtWinRmSavedCredential {
    param([string]$HostName)
    $user = $null
    $password = [FileTransfer.Native]::ReadGenericCredential((Get-FtWinRmCredentialTarget $HostName), [ref]$user)
    if ($null -eq $password -or -not $user) { return $null }
    return New-Object System.Management.Automation.PSCredential -ArgumentList $user, $password
}

function Get-FtWinRmSavedUser {
    param([string]$HostName)
    $credential = Get-FtWinRmSavedCredential $HostName
    if ($credential) { return $credential.UserName }
    return $null
}

# 戻り値: 0 または Win32 のエラーコード
function Save-FtWinRmCredential {
    param([string]$HostName, [pscredential]$Credential)
    return [FileTransfer.Native]::WriteGenericCredential((Get-FtWinRmCredentialTarget $HostName), $Credential.UserName, $Credential.Password)
}

#endregion

#region 接続 --------------------------------------------------------------------

function Test-FtWinRmLocalMode { return [bool]$env:FILETRANSFER_TEST_WINRM_LOCAL }

function Get-FtWinRmPort {
    param([hashtable]$WinRm = @{})
    if ([int]$WinRm.Port -gt 0) { return [int]$WinRm.Port }
    if ($WinRm.UseSsl) { return 5986 }
    return 5985
}

# スクリプトを Runspace（サーバーへの接続）で実行して、出力を返す
function Invoke-FtWinRmScript {
    param($Runspace, [string]$Script, [object[]]$Arguments = @())
    $ps = [powershell]::Create()
    try {
        $ps.Runspace = $Runspace
        [void]$ps.AddScript($Script)
        foreach ($argument in $Arguments) { [void]$ps.AddArgument($argument) }
        $output = $ps.Invoke()
        if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
        return , $output
    } finally {
        $ps.Dispose()
    }
}

# サーバー側の処理（AgentSource）を 1 回呼ぶ
function Invoke-FtWinRmAgent {
    param($Runspace, [string]$Command, [hashtable]$Arguments = @{})
    $output = Invoke-FtWinRmScript -Runspace $Runspace -Script 'param($Command, $Arguments) & $global:FtAgent $Command $Arguments' -Arguments @($Command, $Arguments)
    if ($output.Count -eq 0) { throw "サーバーから応答がありませんでした（$Command）" }
    return $output[$output.Count - 1].psobject.BaseObject
}

# サーバーに接続して、サーバー側の処理を送っておく
# 戻り値: @{ Session; Runspace }（テスト用のローカル実行では Session は $null）
function Open-FtWinRmConnection {
    param([string]$HostName, [pscredential]$Credential, [hashtable]$WinRm = @{}, [int]$OpenTimeoutMs = 20000)
    if (Test-FtWinRmLocalMode) {
        # この PC に別の PowerShell を起動して、サーバーの代わりにする（値の受け渡しはリモートと同じくシリアル化される）
        $runspace = [runspacefactory]::CreateOutOfProcessRunspace([System.Management.Automation.Runspaces.TypeTable]::LoadDefaultTypeFiles())
        $runspace.Open()
        $connection = @{ Session = $null; Runspace = $runspace }
    } else {
        $parameters = @{
            ComputerName  = $HostName
            SessionOption = (New-PSSessionOption -OpenTimeout $OpenTimeoutMs -CancelTimeout 5000)
            ErrorAction   = 'Stop'
        }
        if ($Credential) { $parameters.Credential = $Credential }
        if ($WinRm.UseSsl) { $parameters.UseSSL = $true }
        if ([int]$WinRm.Port -gt 0) { $parameters.Port = [int]$WinRm.Port }
        $session = New-PSSession @parameters
        $connection = @{ Session = $session; Runspace = $session.Runspace }
    }
    try {
        [void](Invoke-FtWinRmScript -Runspace $connection.Runspace -Script 'param($Text) $global:FtAgent = [scriptblock]::Create($Text)' -Arguments @($script:AgentSource))
    } catch {
        Close-FtWinRmConnection $connection
        throw
    }
    return $connection
}

function Close-FtWinRmConnection {
    param($Connection)
    if (-not $Connection) { return }
    try {
        if ($Connection.Session) { Remove-PSSession -Session $Connection.Session -ErrorAction SilentlyContinue }
        elseif ($Connection.Runspace) { $Connection.Runspace.Dispose() }
    } catch { }
}

# 接続・転送の例外を、画面に出す形にする
# 戻り値: @{ Status = auth | unreachable | error; Code（Win32 のエラーコード。わからなければ 0）; Message（1 行の要約）; Detail（説明）}
function ConvertFrom-FtWinRmError {
    param($ErrorRecord)
    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $fqid = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { "$($ErrorRecord.FullyQualifiedErrorId)" } else { '' }
    $transport = $exception
    while ($transport -and $transport -isnot [System.Management.Automation.Remoting.PSRemotingTransportException]) { $transport = $transport.InnerException }
    $code = if ($transport) { [int]$transport.ErrorCode } else { 0 }
    $original = "$($exception.Message)".Trim()

    # 5 = アクセス拒否、0x8009030C = ログオン拒否、0x8009030E = 資格情報がない（ほかはログオン失敗の Win32 コード）
    if ($fqid -like 'AccessDenied*' -or $fqid -like 'LogonFailure*' -or $code -in @(5, 86, 1326, 1327, 1330, 1331, 1385, 1907, 1909, -2146893044, -2146893042)) {
        $win32 = if ($code -in @(86, 1326, 1327, 1330, 1331, 1385, 1907, 1909)) { $code } else { 5 }
        return @{ Status = 'auth'; Code = $win32; Message = 'ユーザー名またはパスワードが正しくないか、WinRM で接続する権限がありません'; Detail = $original }
    }
    # 0x803380E4 / 0x8033809D = TrustedHosts に登録されていない（ドメイン外のサーバー・IP アドレスでの接続）
    if ($fqid -like 'ServerNotTrusted*' -or $code -in @(-2144108316, -2144108387)) {
        return @{
            Status = 'error'; Code = 0
            Message = 'この PC の WinRM の TrustedHosts に登録されていないため、接続できません'
            Detail = "ドメインに参加していないサーバーや、IP アドレスで接続するときは、この PC の WinRM の TrustedHosts にサーバーを登録するか（管理者の PowerShell で Set-Item WSMan:\localhost\Client\TrustedHosts -Value <ホスト名> -Concatenate）、HTTPS で接続する（settings.default.json の winrm.useSsl）必要があります。`n`n$original"
        }
    }
    # 0x80338012 = 接続できない、0x80338126 = ネットワーク エラー、0x803381B9 = 名前を解決できない、0x80338029 = タイムアウト
    if ($fqid -like 'CannotConnect*' -or $fqid -like 'WinRMOperationTimeout*' -or $code -in @(53, 64, 121, 1231, 1232, 1722, -2144108526, -2144108250, -2144108103, -2144108503)) {
        return @{ Status = 'unreachable'; Code = 53; Message = 'WinRM で接続できません（ホスト名と、サーバーで WinRM が有効か確認してください）'; Detail = $original }
    }
    # 0x80090322 = Kerberos のサーバー名が合わない（IP アドレスや別名で接続したときなど）
    if ($code -eq -2146893022) {
        return @{ Status = 'error'; Code = 0; Message = 'Kerberos で認証できませんでした（ホスト名を確認してください）'; Detail = $original }
    }
    $first = @($original -split "`r?`n" | Where-Object { $_.Trim() })[0]
    return @{ Status = 'error'; Code = 0; Message = "WinRM でエラーが発生しました：$first"; Detail = $original }
}

# サーバーに WinRM で接続できるか確認する（バックグラウンドで呼ぶ）
# 戻り値: @{ Status = ok | auth | unreachable | error; Code; User（サーバーで使われるユーザー）; Message; Detail }
function Test-FtWinRmAccess {
    param([string]$HostName, [pscredential]$Credential, [hashtable]$WinRm = @{}, [int]$TimeoutMs = 2000)
    $port = Get-FtWinRmPort $WinRm
    if (-not (Test-FtWinRmLocalMode) -and -not (Test-FtTcpPort -HostName $HostName -Port $port -TimeoutMs $TimeoutMs)) {
        return @{ Status = 'unreachable'; Code = 53; User = ''; Message = "WinRM（$port 番ポート）に接続できません"; Detail = '' }
    }
    $connection = $null
    try {
        $connection = Open-FtWinRmConnection -HostName $HostName -Credential $Credential -WinRm $WinRm
        $info = Invoke-FtWinRmAgent -Runspace $connection.Runspace -Command 'info'
        if (-not $info.Ok) { return @{ Status = 'error'; Code = [int]$info.Code; User = ''; Message = "$($info.Message)"; Detail = '' } }
        return @{ Status = 'ok'; Code = 0; User = "$($info.User)"; Message = ''; Detail = '' }
    } catch {
        $converted = ConvertFrom-FtWinRmError $_
        return @{ Status = $converted.Status; Code = $converted.Code; User = ''; Message = $converted.Message; Detail = $converted.Detail }
    } finally {
        Close-FtWinRmConnection $connection
    }
}

# 1 台目にログオンし、成功したら残りのサーバーにも同じアカウントで接続できるか確かめる（バックグラウンドで呼ぶ）
# Targets: @{ HostName } の配列（先頭がログオンダイアログを開いたサーバー）
# 戻り値: @{ HostName; UserName; Status; Code; Message; Credential; Saved; SaveError } の配列（Connect-FtShareGroup と同じ形）
function Connect-FtWinRmGroup {
    param(
        [object[]]$Targets,
        [string]$UserName,
        [System.Security.SecureString]$Password,
        [switch]$Save,
        [hashtable]$WinRm = @{}
    )
    $first = $Targets[0].HostName
    $results = @()
    foreach ($target in $Targets) {
        $user = Convert-FtUserForHost -UserName $UserName -FromHost $first -ToHost $target.HostName
        $credential = New-Object System.Management.Automation.PSCredential -ArgumentList $user, $Password
        $access = Test-FtWinRmAccess -HostName $target.HostName -Credential $credential -WinRm $WinRm
        $result = @{
            HostName = $target.HostName; UserName = $user; Status = $access.Status; Code = $access.Code; Message = $access.Message
            Credential = $credential; Saved = $false; SaveError = 0; ConnectName = $target.HostName; Root = ''
        }
        if ($access.Status -eq 'ok' -and $Save) {
            $saveCode = Save-FtWinRmCredential -HostName $target.HostName -Credential $credential
            $result.Saved = ($saveCode -eq 0)
            $result.SaveError = $saveCode
        }
        $results += $result
        if ($results.Count -eq 1 -and $access.Status -ne 'ok') { break }
    }
    return , $results
}

#endregion

#region 空き容量 ------------------------------------------------------------------

# 送り先（サーバー上のパス）の空き容量と、必要な容量。戻り値は Test-FtFreeSpace の 1 件と同じ形（Free が -1 なら確認できなかった）
function Get-FtWinRmFreeSpace {
    param([string]$Name, [string]$HostName, [pscredential]$Credential, [string]$Path, [object[]]$Items, [hashtable]$WinRm = @{})
    $files = @()
    $folderBytes = 0L
    $required = 0L
    foreach ($item in $Items) {
        $required += [long]$item.Size
        if ($item.IsFolder) { $folderBytes += [long]$item.Size }
        else { $files += @{ Name = [System.IO.Path]::GetFileName($item.Path); Size = [long]$item.Size } }
    }
    $free = -1L
    $connection = $null
    try {
        $connection = Open-FtWinRmConnection -HostName $HostName -Credential $Credential -WinRm $WinRm
        $space = Invoke-FtWinRmAgent -Runspace $connection.Runspace -Command 'space' -Arguments @{ Path = $Path; Files = $files; Bytes = $folderBytes }
        if ($space.Ok) {
            $free = [long]$space.Free
            $required = [long]$space.Required
        }
    } catch {
    } finally {
        Close-FtWinRmConnection $connection
    }
    return @{
        Name     = $Name
        Path     = $Path
        Volume   = [System.IO.Path]::GetPathRoot($Path).TrimEnd('\')
        Free     = $free
        Required = $required
        Short    = ($free -ge 0 -and $free -lt $required)
    }
}

#endregion

#region 転送 --------------------------------------------------------------------

# -WhatIf で出す 1 行
function Format-FtWinRmStep {
    param([hashtable]$Step)
    if ($Step.Kind -eq 'files') {
        return 'WinRM "{0}" → "{1}"  {2}' -f $Step.Source, $Step.Dest, (@($Step.Files | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    }
    return 'WinRM "{0}" → "{1}"（サブフォルダを含む）' -f $Step.Source, $Step.Dest
}

# この PC 側の例外（コピー元を読めないなど）の Win32 エラーコード
function Get-FtExceptionCode {
    param($Exception)
    while ($Exception.InnerException) { $Exception = $Exception.InnerException }
    if ($Exception -is [System.UnauthorizedAccessException]) { return 5 }
    $hr = [System.Runtime.InteropServices.Marshal]::GetHRForException($Exception)
    if (($hr -band 0xFFFF0000) -eq 0x80070000) { return ($hr -band 0xFFFF) }
    return 0
}

function Join-FtWinRmPath {
    param([string]$Parent, [string]$Child)
    return $Parent.TrimEnd('\') + '\' + $Child
}

function Open-FtSourceFile {
    param([string]$Path)
    return New-Object System.IO.FileStream -ArgumentList $Path, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]'ReadWrite, Delete'), 1048576
}

function Read-FtSourceFile {
    param([string]$Path)
    $stream = Open-FtSourceFile $Path
    try {
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        if ($offset -lt $bytes.Length) {
            $shorter = New-Object byte[] $offset
            [Array]::Copy($bytes, $shorter, $offset)
            return , $shorter
        }
        return , $bytes
    } finally {
        $stream.Dispose()
    }
}

# 1 つの実行単位（New-FtTransferPlan の Step）で送るファイルと、作るフォルダの一覧
# 戻り値: @{ Files = @{ Source; Dest; Size; Time; Item } の一覧; Dirs; Missing; Code; Message }
function Get-FtWinRmStepEntries {
    param([hashtable]$Step)
    $entries = @{ Files = (New-Object System.Collections.Generic.List[object]); Dirs = (New-Object System.Collections.Generic.List[string]); Missing = @(); Code = 0; Message = '' }
    $entries.Dirs.Add($Step.Dest)
    if ($Step.Kind -eq 'files') {
        if (-not [System.IO.Directory]::Exists($Step.Source)) {
            $entries.Code = 3
            $entries.Message = "コピー元のフォルダが見つかりません: $($Step.Source)"
            return $entries
        }
        $byName = @{}
        foreach ($itemPath in $Step.Items) { $byName[[System.IO.Path]::GetFileName($itemPath.TrimEnd('\'))] = $itemPath }
        foreach ($name in $Step.Files) {
            $info = New-Object System.IO.FileInfo (Join-FtWinRmPath $Step.Source $name)
            if (-not $info.Exists) { $entries.Missing += $name; continue }
            $item = $byName[$name]
            if ($null -eq $item) { $item = $Step.Items[0] }
            $entries.Files.Add(@{ Source = $info.FullName; Dest = (Join-FtWinRmPath $Step.Dest $name); Size = $info.Length; Time = $info.LastWriteTimeUtc.Ticks; Item = $item; Same = $false })
        }
        return $entries
    }

    # フォルダ: サブフォルダごと（ジャンクションなどは辿らない。robocopy の /XJ と同じ）
    if (-not [System.IO.Directory]::Exists($Step.Source)) {
        $entries.Code = 3
        $entries.Message = "コピー元のフォルダが見つかりません: $($Step.Source)"
        return $entries
    }
    $pending = New-Object 'System.Collections.Generic.Stack[object]'
    $pending.Push(@{ Source = $Step.Source; Dest = $Step.Dest })
    while ($pending.Count -gt 0) {
        $pair = $pending.Pop()
        try {
            $info = New-Object System.IO.DirectoryInfo $pair.Source
            foreach ($file in $info.EnumerateFiles()) {
                $entries.Files.Add(@{ Source = $file.FullName; Dest = (Join-FtWinRmPath $pair.Dest $file.Name); Size = $file.Length; Time = $file.LastWriteTimeUtc.Ticks; Item = $Step.Items[0]; Same = $false })
            }
            foreach ($sub in $info.EnumerateDirectories()) {
                if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $subDest = Join-FtWinRmPath $pair.Dest $sub.Name
                $entries.Dirs.Add($subDest)
                $pending.Push(@{ Source = $sub.FullName; Dest = $subDest })
            }
        } catch {
            # 読めないフォルダがあっても残りは送り、最後に失敗として知らせる（robocopy と同じ）
            if (-not $entries.Code) {
                $entries.Code = Get-FtExceptionCode $_.Exception
                $entries.Message = "フォルダを読めません: $($pair.Source)"
            }
        }
    }
    return $entries
}

# 1 つの実行単位を送る。戻り値: @{ Code; Message; Missing; Canceled }
function Invoke-FtWinRmStep {
    param([hashtable]$Step, [hashtable]$Sync, $Runspace, [long]$ChunkBytes, [long]$DoneBase)
    $outcome = @{ Code = 0; Message = ''; Missing = @(); Canceled = $false }
    $entries = Get-FtWinRmStepEntries $Step
    $outcome.Missing = $entries.Missing
    if ($entries.Code -and $entries.Files.Count -eq 0 -and $entries.Dirs.Count -le 1) {
        $outcome.Code = $entries.Code
        $outcome.Message = $entries.Message
        return $outcome
    }
    $files = $entries.Files
    $dirs = $entries.Dirs

    # フォルダを作り、送り先に同じもの（サイズと更新日時が同じ）があるか調べる
    for ($start = 0; $start -lt [Math]::Max($dirs.Count, $files.Count); $start += $script:PrepareBatch) {
        $dirBatch = if ($start -lt $dirs.Count) { $dirs.GetRange($start, [Math]::Min($script:PrepareBatch, $dirs.Count - $start)).ToArray() } else { @() }
        $fileBatch = New-Object System.Collections.Generic.List[object]
        $fileCount = if ($start -lt $files.Count) { [Math]::Min($script:PrepareBatch, $files.Count - $start) } else { 0 }
        for ($j = 0; $j -lt $fileCount; $j++) {
            $file = $files[$start + $j]
            $fileBatch.Add(@{ Path = $file.Dest; Size = [long]$file.Size; Time = [long]$file.Time })
        }
        $answer = Invoke-FtWinRmAgent -Runspace $Runspace -Command 'prepare' -Arguments @{ Dirs = [string[]]$dirBatch; Files = $fileBatch.ToArray() }
        if (-not $answer.Ok) {
            $outcome.Code = [int]$answer.Code
            $outcome.Message = "送り先にフォルダを作れません: $($answer.Message)"
            Write-FtSyncLog $Sync "  エラー $($answer.Code): $($answer.Message)"
            return $outcome
        }
        $same = @($answer.Same)
        for ($j = 0; $j -lt $fileCount; $j++) { $files[$start + $j].Same = [bool]$same[$j] }
    }

    $stepBytes = [long]$Step.Bytes
    $progress = @{ Done = 0L; Skipped = 0 }
    $reportFinal = $Step.Kind -eq 'files' -and $Step.Final

    # 進捗を書き込む（Partial: 今のファイルで送った分、Fraction: 今のファイルの進み具合）
    $report = {
        param([long]$Partial, [double]$Fraction, $Item)
        $inStep = $progress.Done + $Partial
        if ($inStep -gt $stepBytes) { $inStep = $stepBytes }
        $Sync.CurrentItem = $Item
        $Sync.BytesDone = $DoneBase + $inStep
        if ($Step.Kind -eq 'folder') { $Sync.CurrentFraction = if ($stepBytes -gt 0) { $inStep / $stepBytes } else { 0 } }
        else { $Sync.CurrentFraction = $Fraction }
    }
    # 1 ファイル終わった（Skipped: 送り先に同じものがあったので送らなかった。ログには件数だけ出す）
    $finish = {
        param($File, [bool]$Skipped)
        $progress.Done += [long]$File.Size
        if ($Skipped) { $progress.Skipped++ }
        else { Write-FtSyncLog $Sync ("  送信  {0}  ({1})" -f $File.Source, [FileTransfer.FileItem]::FormatSize([long]$File.Size)) }
        if ($reportFinal) { $Sync.Completed.Enqueue($File.Item) }
        & $report 0 0 $File.Item
    }

    # 小さいファイルはまとめて送る
    $batch = New-Object System.Collections.Generic.List[object]
    $batchBytes = 0L
    $flush = {
        if ($batch.Count -eq 0) { return $null }
        & $report 0 0 $batch[$batch.Count - 1].File.Item
        $answer = Invoke-FtWinRmAgent -Runspace $Runspace -Command 'put' -Arguments @{ Files = @($batch | ForEach-Object { @{ Path = $_.File.Dest; Bytes = $_.Bytes; Time = [long]$_.File.Time } }) }
        if (-not $answer.Ok) { return $answer }
        foreach ($entry in $batch) { & $finish $entry.File $false }
        $batch.Clear()
        return $null
    }

    $current = $null
    try {
        foreach ($file in $files) {
            if ($Sync.Cancel) { $outcome.Canceled = $true; break }
            $current = $file
            if ($file.Same) { & $finish $file $true; continue }

            if ([long]$file.Size -le $ChunkBytes) {
                if ($batch.Count -gt 0 -and ($batchBytes + [long]$file.Size -gt $ChunkBytes -or $batch.Count -ge $script:BatchMaxFiles)) {
                    $failed = & $flush
                    $batchBytes = 0L
                    if ($failed) { $outcome.Code = [int]$failed.Code; $outcome.Message = "$($failed.Message)"; break }
                }
                $bytes = Read-FtSourceFile $file.Source
                $batch.Add(@{ File = $file; Bytes = $bytes })
                $batchBytes += $bytes.Length
                continue
            }

            # 大きいファイル: 少しずつ送る
            $failed = & $flush
            $batchBytes = 0L
            if ($failed) { $outcome.Code = [int]$failed.Code; $outcome.Message = "$($failed.Message)"; break }
            $answer = Invoke-FtWinRmAgent -Runspace $Runspace -Command 'open' -Arguments @{ Path = $file.Dest; Size = [long]$file.Size }
            if (-not $answer.Ok) { $outcome.Code = [int]$answer.Code; $outcome.Message = "$($answer.Message)"; break }
            $stream = Open-FtSourceFile $file.Source
            try {
                $sent = 0L
                while ($true) {
                    if ($Sync.Cancel) { $outcome.Canceled = $true; break }
                    $buffer = New-Object byte[] ([int]$ChunkBytes)
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    if ($read -lt $buffer.Length) {
                        $data = New-Object byte[] $read
                        [Array]::Copy($buffer, $data, $read)
                    } else {
                        $data = $buffer
                    }
                    $answer = Invoke-FtWinRmAgent -Runspace $Runspace -Command 'write' -Arguments @{ Bytes = $data }
                    if (-not $answer.Ok) { $outcome.Code = [int]$answer.Code; $outcome.Message = "$($answer.Message)"; break }
                    $sent += $read
                    $partial = [Math]::Min($sent, [long]$file.Size)
                    & $report $partial ($(if ([long]$file.Size -gt 0) { $partial / [double]$file.Size } else { 1.0 })) $file.Item
                }
            } finally {
                $stream.Dispose()
            }
            if ($outcome.Canceled -or $outcome.Code -or $outcome.Message) {
                try { [void](Invoke-FtWinRmAgent -Runspace $Runspace -Command 'abort') } catch { }
                break
            }
            $answer = Invoke-FtWinRmAgent -Runspace $Runspace -Command 'close' -Arguments @{ Time = [long]$file.Time }
            if (-not $answer.Ok) { $outcome.Code = [int]$answer.Code; $outcome.Message = "$($answer.Message)"; break }
            & $finish $file $false
        }
        if (-not $outcome.Canceled -and -not $outcome.Code -and -not $outcome.Message -and -not $Sync.Cancel) {
            $failed = & $flush
            if ($failed) { $outcome.Code = [int]$failed.Code; $outcome.Message = "$($failed.Message)" }
        }
    } catch {
        # この PC 側でコピー元を読めないときは、その送り先の失敗にする（接続が切れたなどは呼び出し元で扱う）
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -isnot [System.IO.IOException] -and $inner -isnot [System.UnauthorizedAccessException]) { throw }
        try { [void](Invoke-FtWinRmAgent -Runspace $Runspace -Command 'abort') } catch { }
        $outcome.Code = Get-FtExceptionCode $inner
        $outcome.Message = "コピー元を読めません: $(if ($current) { $current.Source })（$($inner.Message)）"
    }
    if ($Sync.Cancel) { $outcome.Canceled = $true }
    if ($progress.Skipped -gt 0) { Write-FtSyncLog $Sync "  送り先に同じ内容のファイルがあるため省略: $($progress.Skipped) ファイル" }
    if ($outcome.Code -or $outcome.Message) {
        $target = if ($current) { " $($current.Dest)" } else { '' }
        Write-FtSyncLog $Sync "  エラー $($outcome.Code): $($outcome.Message)$target"
    } elseif ($entries.Code) {
        # 読めないサブフォルダがあった
        $outcome.Code = $entries.Code
        $outcome.Message = $entries.Message
        Write-FtSyncLog $Sync "  エラー $($outcome.Code): $($outcome.Message)"
    }
    return $outcome
}

# 実行計画（New-FtTransferPlan の Steps）を WinRM で実行する（バックグラウンドの Runspace で呼ぶ）
# Sync への書き込みは Invoke-FtTransferPlan と同じ。Sync.Cancel が $true になったら、書きかけのファイルを消して止める
function Invoke-FtWinRmTransferPlan {
    param(
        [object[]]$Steps,
        [hashtable]$Sync,
        [string]$HostName,
        [pscredential]$Credential,
        [hashtable]$WinRm = @{}
    )
    $total = 0L
    foreach ($step in $Steps) { $total += [long]$step.Bytes }
    $Sync.BytesTotal = $total
    $Sync.BytesDone = 0L
    $chunk = if ([long]$WinRm.ChunkBytes -gt 0) { [long]$WinRm.ChunkBytes } else { 2MB }
    $result = @{ Status = 'success'; ExitCode = 0; Code = 0; Message = ''; Missing = @(); FailedStep = -1 }
    $connection = $null
    $doneBase = 0L
    try {
        Write-FtSyncLog $Sync "WinRM: $HostName に接続しています"
        $connection = Open-FtWinRmConnection -HostName $HostName -Credential $Credential -WinRm $WinRm
        $info = Invoke-FtWinRmAgent -Runspace $connection.Runspace -Command 'info'
        Write-FtSyncLog $Sync "  接続しました（$($info.User)、PowerShell $($info.Version)）"
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            if ($Sync.Cancel) { $result.Status = 'canceled'; break }
            $step = $Steps[$i]
            $Sync.StepIndex = $i
            Write-FtSyncLog $Sync (Format-FtWinRmStep $step)
            $outcome = Invoke-FtWinRmStep -Step $step -Sync $Sync -Runspace $connection.Runspace -ChunkBytes $chunk -DoneBase $doneBase
            if ($outcome.Canceled) { $result.Status = 'canceled'; break }
            if ($outcome.Code -or $outcome.Message -or $outcome.Missing.Count -gt 0) {
                $result.Status = 'failed'
                $result.Code = [int]$outcome.Code
                $result.Message = $outcome.Message
                $result.Missing = $outcome.Missing
                $result.FailedStep = $i
                break
            }
            $doneBase += [long]$step.Bytes
            $Sync.BytesDone = $doneBase
            if ($step.Final) { foreach ($itemPath in $step.Items) { $Sync.Completed.Enqueue($itemPath) } }
        }
    } catch {
        $converted = ConvertFrom-FtWinRmError $_
        $result.Status = 'failed'
        $result.Code = $converted.Code
        $result.Message = if ($converted.Detail -and $converted.Detail -ne $converted.Message) { "$($converted.Message)`n$($converted.Detail)" } else { $converted.Message }
        Write-FtSyncLog $Sync "  エラー: $($result.Message)"
    } finally {
        Close-FtWinRmConnection $connection
        $Sync.CurrentItem = $null
        $Sync.ProcessId = 0
        $Sync.Result = $result
    }
    return $result
}

#endregion

Export-ModuleMember -Function Get-FtWinRmCredentialTarget, Get-FtWinRmSavedCredential, Get-FtWinRmSavedUser, Save-FtWinRmCredential, Get-FtWinRmPort, Open-FtWinRmConnection, Close-FtWinRmConnection, Invoke-FtWinRmAgent, ConvertFrom-FtWinRmError, Test-FtWinRmAccess, Connect-FtWinRmGroup, Get-FtWinRmFreeSpace, Format-FtWinRmStep, Invoke-FtWinRmTransferPlan
