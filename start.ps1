[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4173,
    [string]$DataDirectory = (Join-Path $env:ProgramData 'DocumentAudit')
)

$ErrorActionPreference = 'Stop'
$applicationRoot = $PSScriptRoot
$configurationPath = Join-Path $DataDirectory 'monitoring.json'
$powerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1} -DataDirectory "{2}"' -f $PSCommandPath, $Port, $DataDirectory
    try {
        Start-Process -FilePath $powerShellPath -Verb RunAs -ArgumentList $arguments
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show('Для настройки аудита нужны права администратора. Подтвердите запрос Windows или запустите Start-Audit.cmd снова.', 'Аудит файлов', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    exit
}

if (-not [IO.File]::Exists($configurationPath)) {
    & (Join-Path $applicationRoot 'scripts\configure-audit.ps1') -DataDirectory $DataDirectory -NoStartPanel
}

if (-not [IO.File]::Exists($configurationPath)) {
    throw 'Аудит не настроен. Запустите Start-Audit.cmd и выберите хотя бы одну папку.'
}
$configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
$logsDirectory = if ($configuration.logsDirectory) { [IO.Path]::GetFullPath([string]$configuration.logsDirectory) } else { [IO.Path]::GetFullPath($DataDirectory) }
[IO.Directory]::CreateDirectory($logsDirectory) | Out-Null

$task = Get-ScheduledTask -TaskName 'DocumentAuditCollector' -ErrorAction SilentlyContinue
if (-not $task) {
    & (Join-Path $applicationRoot 'scripts\install-collector-task.ps1') -DataDirectory $DataDirectory
} else {
    $collectorPath = Join-Path $applicationRoot 'scripts\collect-events.ps1'
    $expectedCollectorVersion = (Get-FileHash -LiteralPath $collectorPath -Algorithm SHA256).Hash
    $collectorStatusPath = Join-Path $DataDirectory 'collector-status.json'
    $installedCollectorVersion = $null
    try {
        $collectorStatus = Get-Content -LiteralPath $collectorStatusPath -Raw | ConvertFrom-Json
        $installedCollectorVersion = [string]$collectorStatus.collectorVersion
    } catch { }
    if ($task.State -eq 'Running' -and $installedCollectorVersion -ne $expectedCollectorVersion) {
        Stop-ScheduledTask -TaskName 'DocumentAuditCollector'
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 250
            $task = Get-ScheduledTask -TaskName 'DocumentAuditCollector'
            if ($task.State -ne 'Running') { break }
        }
        if ($task.State -eq 'Running') { throw 'Не удалось остановить старую версию сборщика аудита.' }
    }
    if ($task.State -ne 'Running') {
        Start-ScheduledTask -TaskName 'DocumentAuditCollector'
    }
}

[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
$serverPath = Join-Path $applicationRoot 'server.ps1'
$serverVersion = (Get-FileHash -LiteralPath $serverPath -Algorithm SHA256).Hash
$serverLog = Join-Path $logsDirectory 'server.log'
$serverErrorLog = Join-Path $logsDirectory 'server-error.log'
$serverPidPath = Join-Path $DataDirectory 'server.pid'
$url = "http://127.0.0.1:$Port/"
$serverReady = $false

try { $health = Invoke-RestMethod -Uri "${url}api/status" -TimeoutSec 1 -ErrorAction Stop } catch { $health = $null }
if ($health -and $health.app -eq 'document-audit') {
    if ($health.serverVersion -eq $serverVersion -and [string]::Equals([string]$health.serverLogDirectory, $logsDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        $serverReady = $true
    } else {
        if (-not [IO.File]::Exists($serverPidPath)) {
            throw 'Запущена старая версия панели, но файл server.pid не найден. Закройте старый процесс сервера и повторите запуск.'
        }
        $existingPid = 0
        if (-not [int]::TryParse([IO.File]::ReadAllText($serverPidPath).Trim(), [ref]$existingPid)) {
            throw 'Запущена старая версия панели, но в server.pid указан некорректный PID.'
        }
        $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
        $pidFileTime = [IO.File]::GetLastWriteTimeUtc($serverPidPath)
        if (-not $existingProcess -or $existingProcess.ProcessName -notin @('powershell', 'pwsh') -or
            [Math]::Abs(($existingProcess.StartTime.ToUniversalTime() - $pidFileTime).TotalSeconds) -gt 30) {
            throw 'Не удалось безопасно определить процесс старой панели. Закройте его и повторите запуск.'
        }
        Stop-Process -Id $existingPid -Force -ErrorAction Stop
        $existingProcess.WaitForExit(5000) | Out-Null
    }
}

if (-not $serverReady) {
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Port {1} -DataDirectory "{2}" -LogDirectory "{3}"' -f $serverPath, $Port, $DataDirectory, $logsDirectory
    $serverProcess = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverLog -RedirectStandardError $serverErrorLog
    [IO.File]::WriteAllText($serverPidPath, [string]$serverProcess.Id, [Text.Encoding]::ASCII)

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 350
        try {
            $health = Invoke-RestMethod -Uri "${url}api/status" -TimeoutSec 2 -ErrorAction Stop
            if ($health.app -eq 'document-audit') { $serverReady = $true; break }
        } catch { }
        if ($serverProcess.HasExited) { break }
    }
}

if (-not $serverReady) {
    Add-Type -AssemblyName System.Windows.Forms
    $message = "Не удалось запустить локальную панель на порту $Port.`n`nПроверьте журнал:`n$serverErrorLog"
    [System.Windows.Forms.MessageBox]::Show($message, 'Аудит файлов', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    throw "Локальная панель не запустилась. Подробности: $serverErrorLog"
}

Start-Process $url
Write-Output "Панель аудита открыта в браузере: $url"
