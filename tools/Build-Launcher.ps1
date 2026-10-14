#Requires -Version 5.1
<#
.SYNOPSIS
    launcher\Launcher.cs から FileTransfer.exe（コンソールを出さずに起動するランチャー）をビルドする
.DESCRIPTION
    Windows 標準の .NET Framework に含まれる C# コンパイラ（csc.exe）を使う。追加のインストールは不要。
#>
param([string]$OutputDirectory = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'launcher\Launcher.cs'
$icon = Join-Path $root 'FileTransfer.ico'
$output = Join-Path $OutputDirectory 'FileTransfer.exe'

$candidates = @(
    (Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'C# コンパイラ（csc.exe）が見つかりません。' }

$arguments = @('/nologo', '/target:winexe', '/optimize+', "/out:$output", '/reference:System.Windows.Forms.dll')
if (Test-Path -LiteralPath $icon) { $arguments += "/win32icon:$icon" }
$arguments += $source

$compilerOutput = & $csc @arguments 2>&1
if ($LASTEXITCODE -ne 0) { throw "FileTransfer.exe のビルドに失敗しました。`n$($compilerOutput -join "`n")" }
Write-Output $output
