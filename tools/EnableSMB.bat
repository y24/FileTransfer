@echo off
rem ============================================================
rem  EnableSMB.bat - Prepare a destination server for FileTransfer's SMB transfer.
rem
rem  Usage: copy this file to the destination server (VM) and double-click it.
rem         If it is not running as administrator, it relaunches itself elevated (UAC prompt).
rem
rem  What it does (items that are already OK are left unchanged):
rem    1. Server service (LanmanServer): startup type Automatic, and start it
rem    2. Administrative shares (C$ etc.): AutoShareServer / AutoShareWks
rem    3. SMB2/3 protocol
rem    4. Firewall: inbound rules of "File and Printer Sharing" (TCP 445)
rem    5. LocalAccountTokenFilterPolicy = 1, so local accounts other than the
rem       built-in Administrator can connect to administrative shares
rem
rem  The original value of each item it changes is recorded under
rem  HKLM\SOFTWARE\FileTransfer\EnableSMB, so DisableSMB.bat can restore it.
rem  Running it again keeps the first recorded values.
rem
rem  Save this file as ASCII (or UTF-8 without BOM), CRLF.
rem  Everything after the marker line is a PowerShell script; cmd never reaches it
rem  because of "exit /b" below.
rem ============================================================
setlocal
set "SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = [IO.File]::ReadAllText($env:SELF, [Text.Encoding]::UTF8); Invoke-Expression $t.Substring($t.IndexOf('#__PS_' + 'BEGIN__')); exit $global:ExitCode"
set "RC=%ERRORLEVEL%"
rem 10 = relaunched as administrator; the elevated window shows the result
if "%RC%"=="10" exit /b 0
echo.
pause
exit /b %RC%

#__PS_BEGIN__
$ErrorActionPreference = 'Stop'
$global:ExitCode = 0
$global:Changed = New-Object System.Collections.Generic.List[string]
$global:RestartServer = $false

function Write-Ok([string]$msg)   { Write-Host "  [OK]      $msg" -ForegroundColor Green }
function Write-Done([string]$msg) { Write-Host "  [CHANGED] $msg" -ForegroundColor Cyan; $global:Changed.Add($msg) }
function Write-Ng([string]$msg)   { Write-Host "  [FAILED]  $msg" -ForegroundColor Red; $global:ExitCode = 1 }
function Invoke-Step([string]$title, [scriptblock]$body) {
    Write-Host ''
    Write-Host "* $title"
    try { & $body } catch { Write-Ng $_.Exception.Message }
}

# Original values for DisableSMB.bat. A value that is already recorded is not overwritten.
$global:StateKey = 'HKLM:\SOFTWARE\FileTransfer\EnableSMB'
function Save-Original([string]$name, [string]$value) {
    if (-not (Test-Path $global:StateKey)) { New-Item -Path $global:StateKey -Force | Out-Null }
    if ($null -eq (Get-ItemProperty -Path $global:StateKey -Name $name -ErrorAction SilentlyContinue)) {
        New-ItemProperty -Path $global:StateKey -Name $name -Value $value -PropertyType String | Out-Null
    }
}
function Add-OriginalList([string]$name, [string[]]$items) {
    if (-not (Test-Path $global:StateKey)) { New-Item -Path $global:StateKey -Force | Out-Null }
    $current = @((Get-ItemProperty -Path $global:StateKey -Name $name -ErrorAction SilentlyContinue).$name)
    $merged = @($current + $items | Where-Object { $_ } | Sort-Object -Unique)
    Set-ItemProperty -Path $global:StateKey -Name $name -Value ([string[]]$merged) -Type MultiString
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Elevated {
    Write-Host 'Restarting as administrator. Click "Yes" in the User Account Control prompt.'
    try {
        Start-Process -FilePath $env:SELF -Verb RunAs
        $global:ExitCode = 10
    } catch {
        Write-Host ''
        Write-Host 'Could not start as administrator. Right-click this file and choose "Run as administrator".' -ForegroundColor Red
        $global:ExitCode = 1
    }
}

function Enable-Smb {
    Write-Host '============================================================'
    Write-Host ' Configuring this server to accept SMB (file sharing) transfers'
    Write-Host " Computer name: $env:COMPUTERNAME"
    Write-Host '============================================================'

    $lanmanParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'

    Invoke-Step 'Administrative shares (C$ etc.)' {
        foreach ($name in 'AutoShareServer', 'AutoShareWks') {
            $value = (Get-ItemProperty -Path $lanmanParams -Name $name -ErrorAction SilentlyContinue).$name
            if ($null -ne $value -and $value -eq 0) {
                Save-Original $name '0'
                Set-ItemProperty -Path $lanmanParams -Name $name -Value 1 -Type DWord
                Write-Done "Set $name to 1"
                $global:RestartServer = $true
            }
        }
        if (-not $global:RestartServer) { Write-Ok 'Not disabled' }
    }

    Invoke-Step 'SMB2/3 protocol' {
        if (-not (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue)) {
            Write-Ok 'Check skipped on this OS'
            return
        }
        if ((Get-SmbServerConfiguration).EnableSMB2Protocol) {
            Write-Ok 'Enabled'
        } else {
            Save-Original 'SMB2Disabled' '1'
            Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force -Confirm:$false
            Write-Done 'Enabled SMB2/3'
            $global:RestartServer = $true
        }
    }

    Invoke-Step 'Server service (LanmanServer)' {
        $svc = Get-WmiObject Win32_Service -Filter "Name='LanmanServer'"
        if ($svc.StartMode -ne 'Auto') {
            Save-Original 'LanmanServerStartMode' $svc.StartMode
            Set-Service -Name LanmanServer -StartupType Automatic
            Write-Done "Changed startup type to Automatic (was: $($svc.StartMode))"
        } else {
            Write-Ok 'Startup type is Automatic'
        }
        $svc = Get-Service -Name LanmanServer
        if ($svc.Status -ne 'Running') {
            Save-Original 'LanmanServerStopped' '1'
            Start-Service -Name LanmanServer
            Write-Done 'Started the service'
        } elseif ($global:RestartServer) {
            # Restart (with dependent services) to apply the share / SMB2 settings
            Restart-Service -Name LanmanServer -Force
            Write-Done 'Restarted the service to apply the settings'
        } else {
            Write-Ok 'Running'
        }
    }

    Invoke-Step 'Firewall (File and Printer Sharing inbound rules)' {
        if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
            # The display group name depends on the OS language, so use the resource name
            $rules = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -ErrorAction SilentlyContinue |
                       Where-Object { $_.Direction -eq 'Inbound' })
            if ($rules.Count -eq 0) { throw 'No "File and Printer Sharing" rules found' }
            $disabled = @($rules | Where-Object { $_.Enabled -ne 'True' })
            if ($disabled.Count -gt 0) {
                Add-OriginalList 'FirewallRules' @($disabled | ForEach-Object { $_.Name })
                $disabled | Enable-NetFirewallRule
                Write-Done "Enabled $($disabled.Count) inbound rule(s)"
            } else {
                Write-Ok 'Inbound rules are enabled'
            }
        } else {
            Save-Original 'NetshRule' '1'
            $out = netsh advfirewall firewall add rule name="FileTransfer SMB-In" dir=in action=allow protocol=TCP localport=445
            if ($LASTEXITCODE -ne 0) { throw "netsh failed: $out" }
            Write-Done 'Added a rule to allow inbound TCP 445'
        }
    }

    Invoke-Step 'Local accounts on administrative shares (LocalAccountTokenFilterPolicy)' {
        $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $value = (Get-ItemProperty -Path $policy -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
        if ($value -eq 1) {
            Write-Ok 'Already set'
        } else {
            Save-Original 'LocalAccountTokenFilterPolicy' $(if ($null -eq $value) { '(none)' } else { [string]$value })
            Set-ItemProperty -Path $policy -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
            Write-Done 'Set LocalAccountTokenFilterPolicy to 1'
        }
    }

    Invoke-Step 'Verification' {
        # C$ may take a moment to appear after the service (re)starts
        $share = $null
        for ($i = 0; $i -lt 10 -and -not $share; $i++) {
            $share = Get-WmiObject Win32_Share -Filter 'Name="C$"'
            if (-not $share) { Start-Sleep -Seconds 1 }
        }
        if ($share) { Write-Ok "Administrative share C$ exists ($($share.Path))" } else { Write-Ng 'Administrative share C$ not found' }

        $listen = netstat -an -p TCP | Select-String -Pattern ':445\s+\S+\s+LISTEN'
        if ($listen) { Write-Ok 'Listening on TCP 445' } else { Write-Ng 'Not listening on TCP 445' }

        $ips = @(Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' |
                 ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        Write-Host "  IP address(es) of this server: $($ips -join ', ')"
    }

    Write-Host ''
    Write-Host '============================================================'
    if ($global:ExitCode -eq 0) {
        Write-Host ' Done. Enter the following as the destination in FileTransfer:' -ForegroundColor Green
        Write-Host "   $env:COMPUTERNAME  (or the IP address above if the name cannot be resolved)"
        if ($global:Changed.Count -eq 0) { Write-Host ' (Nothing was changed; everything was already enabled.)' }
    } else {
        Write-Host ' Some settings failed. Check the [FAILED] lines above.' -ForegroundColor Red
        Write-Host ' If the firewall or sharing is managed by Group Policy, ask your administrator.'
    }
    Write-Host '============================================================'
}

if (Test-Admin) { Enable-Smb } else { Start-Elevated }
