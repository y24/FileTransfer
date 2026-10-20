@echo off
rem ============================================================
rem  DisableSMB.bat - Undo what EnableSMB.bat changed on a destination server.
rem
rem  Usage: copy this file to the destination server (VM) and double-click it.
rem         If it is not running as administrator, it relaunches itself elevated (UAC prompt).
rem
rem  If EnableSMB.bat recorded the original values (HKLM\SOFTWARE\FileTransfer\EnableSMB),
rem  only the items it changed are restored, and the record is deleted.
rem  Without a record, it only blocks access from other computers:
rem    - Firewall: disables the inbound rules of "File and Printer Sharing" (TCP 445)
rem    - Deletes LocalAccountTokenFilterPolicy (back to the Windows default)
rem  The Server service and administrative shares are left as they are in that case.
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
$global:RestartServer = $false

function Write-Ok([string]$msg)   { Write-Host "  [OK]      $msg" -ForegroundColor Green }
function Write-Done([string]$msg) { Write-Host "  [CHANGED] $msg" -ForegroundColor Cyan }
function Write-Ng([string]$msg)   { Write-Host "  [FAILED]  $msg" -ForegroundColor Red; $global:ExitCode = 1 }
function Invoke-Step([string]$title, [scriptblock]$body) {
    Write-Host ''
    Write-Host "* $title"
    try { & $body } catch { Write-Ng $_.Exception.Message }
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

$global:StateKey = 'HKLM:\SOFTWARE\FileTransfer\EnableSMB'
$global:PolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$global:LanmanParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
$global:FpsGroup = '@FirewallAPI.dll,-28502'   # "File and Printer Sharing" (language independent)

function Restore-FromRecord($state) {
    Invoke-Step 'Local accounts on administrative shares (LocalAccountTokenFilterPolicy)' {
        $orig = $state.LocalAccountTokenFilterPolicy
        if ($null -eq $orig) {
            Write-Ok 'Not changed by EnableSMB.bat'
        } elseif ($orig -eq '(none)') {
            Remove-ItemProperty -Path $global:PolicyKey -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
            Write-Done 'Deleted LocalAccountTokenFilterPolicy'
        } else {
            Set-ItemProperty -Path $global:PolicyKey -Name LocalAccountTokenFilterPolicy -Value ([int]$orig) -Type DWord
            Write-Done "Set LocalAccountTokenFilterPolicy back to $orig"
        }
    }

    Invoke-Step 'Firewall' {
        $names = @($state.FirewallRules | Where-Object { $_ })
        if ($names.Count -gt 0) {
            $rules = @($names | ForEach-Object { Get-NetFirewallRule -Name $_ -ErrorAction SilentlyContinue })
            $rules | Disable-NetFirewallRule
            Write-Done "Disabled $($rules.Count) inbound rule(s) that EnableSMB.bat enabled"
        }
        if ($state.NetshRule -eq '1') {
            $out = netsh advfirewall firewall delete rule name="FileTransfer SMB-In"
            if ($LASTEXITCODE -ne 0) { throw "netsh failed: $out" }
            Write-Done 'Deleted the rule "FileTransfer SMB-In"'
        }
        if ($names.Count -eq 0 -and $state.NetshRule -ne '1') { Write-Ok 'Not changed by EnableSMB.bat' }
    }

    Invoke-Step 'Administrative shares (C$ etc.)' {
        $any = $false
        foreach ($name in 'AutoShareServer', 'AutoShareWks') {
            $orig = $state.$name
            if ($null -ne $orig) {
                Set-ItemProperty -Path $global:LanmanParams -Name $name -Value ([int]$orig) -Type DWord
                Write-Done "Set $name back to $orig"
                $global:RestartServer = $true
                $any = $true
            }
        }
        if (-not $any) { Write-Ok 'Not changed by EnableSMB.bat' }
    }

    Invoke-Step 'SMB2/3 protocol' {
        if ($state.SMB2Disabled -eq '1') {
            Set-SmbServerConfiguration -EnableSMB2Protocol $false -Force -Confirm:$false
            Write-Done 'Disabled SMB2/3'
            $global:RestartServer = $true
        } else {
            Write-Ok 'Not changed by EnableSMB.bat'
        }
    }

    Invoke-Step 'Server service (LanmanServer)' {
        $mode = $state.LanmanServerStartMode
        if ($state.LanmanServerStopped -eq '1') {
            Stop-Service -Name LanmanServer -Force
            Write-Done 'Stopped the service (and its dependent services)'
        } elseif ($global:RestartServer -and (Get-Service -Name LanmanServer).Status -eq 'Running') {
            Restart-Service -Name LanmanServer -Force
            Write-Done 'Restarted the service to apply the settings'
        }
        if ($null -ne $mode) {
            $type = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Disabled' }[$mode]
            if (-not $type) { throw "Unknown original startup type: $mode" }
            Set-Service -Name LanmanServer -StartupType $type
            Write-Done "Set startup type back to $type"
        } elseif ($state.LanmanServerStopped -ne '1' -and -not $global:RestartServer) {
            Write-Ok 'Not changed by EnableSMB.bat'
        }
    }

    if ($global:ExitCode -eq 0) {
        Remove-Item -Path $global:StateKey -Recurse -Force
        $parent = Split-Path $global:StateKey -Parent
        if (-not (Get-ChildItem -Path $parent) -and -not (Get-Item -Path $parent).Property) {
            Remove-Item -Path $parent -Force
        }
    }
}

function Disable-WithoutRecord {
    Write-Host ''
    Write-Host ' No record from EnableSMB.bat was found. Blocking access from other computers only.' -ForegroundColor Yellow

    Invoke-Step 'Firewall (File and Printer Sharing inbound rules)' {
        if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
            $enabled = @(Get-NetFirewallRule -Group $global:FpsGroup -ErrorAction SilentlyContinue |
                         Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' })
            if ($enabled.Count -gt 0) {
                $enabled | Disable-NetFirewallRule
                Write-Done "Disabled $($enabled.Count) inbound rule(s)"
            } else {
                Write-Ok 'Inbound rules are already disabled'
            }
        }
        $null = netsh advfirewall firewall show rule name="FileTransfer SMB-In"
        if ($LASTEXITCODE -eq 0) {
            $null = netsh advfirewall firewall delete rule name="FileTransfer SMB-In"
            Write-Done 'Deleted the rule "FileTransfer SMB-In"'
        }
    }

    Invoke-Step 'Local accounts on administrative shares (LocalAccountTokenFilterPolicy)' {
        $value = (Get-ItemProperty -Path $global:PolicyKey -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
        if ($null -eq $value) {
            Write-Ok 'Not set (Windows default)'
        } else {
            Remove-ItemProperty -Path $global:PolicyKey -Name LocalAccountTokenFilterPolicy
            Write-Done "Deleted LocalAccountTokenFilterPolicy (was: $value)"
        }
    }
}

function Disable-Smb {
    Write-Host '============================================================'
    Write-Host ' Undoing the SMB (file sharing) settings made by EnableSMB.bat'
    Write-Host " Computer name: $env:COMPUTERNAME"
    Write-Host '============================================================'

    if (Test-Path $global:StateKey) {
        Restore-FromRecord (Get-ItemProperty -Path $global:StateKey)
    } else {
        Disable-WithoutRecord
    }

    Invoke-Step 'Status' {
        $listen = netstat -an -p TCP | Select-String -Pattern ':445\s+\S+\s+LISTEN'
        Write-Host "  Listening on TCP 445: $(if ($listen) { 'yes' } else { 'no' })"
        if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
            $on = @(Get-NetFirewallRule -Group $global:FpsGroup -ErrorAction SilentlyContinue |
                    Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' })
            Write-Host "  Enabled File and Printer Sharing inbound rules: $($on.Count)"
        }
    }

    Write-Host ''
    Write-Host '============================================================'
    if ($global:ExitCode -eq 0) {
        Write-Host ' Done.' -ForegroundColor Green
    } else {
        Write-Host ' Some settings failed. Check the [FAILED] lines above.' -ForegroundColor Red
        Write-Host ' The record from EnableSMB.bat was kept, so you can run this again.'
    }
    Write-Host '============================================================'
}

if (Test-Admin) { Disable-Smb } else { Start-Elevated }
