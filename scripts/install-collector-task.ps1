[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:ProgramData 'DocumentAudit'),
    [string]$TaskName = 'DocumentAuditCollector'
)

$ErrorActionPreference = 'Stop'
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Откройте PowerShell от имени администратора и запустите скрипт снова.'
}

$configurationPath = Join-Path $DataDirectory 'monitoring.json'
if (-not [IO.File]::Exists($configurationPath)) {
    throw "Не найдена конфигурация $configurationPath. Сначала настройте папки через scripts\setup-audit.ps1."
}

$collectorPath = Join-Path $PSScriptRoot 'collect-events.ps1'
$powerShellPath = Join-Path $PSHOME 'powershell.exe'
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -DataDirectory "{1}"' -f $collectorPath, $DataDirectory
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description 'Читает события аудита файлов из журнала Windows Security и сохраняет их в локальный JSONL-журнал.' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Задача $TaskName зарегистрирована и запущена от имени SYSTEM." -ForegroundColor Green
Write-Host "Состояние журнала проверяйте в панели; данные: $DataDirectory"
Write-Host "Отключить автозапуск: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false" -ForegroundColor Yellow
