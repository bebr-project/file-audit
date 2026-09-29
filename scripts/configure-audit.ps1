[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:ProgramData 'DocumentAudit'),
    [switch]$LogsOnly,
    [switch]$NoStartPanel
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $powerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -DataDirectory "{1}"' -f $PSCommandPath, $DataDirectory
    if ($LogsOnly) { $arguments += ' -LogsOnly' }
    if ($NoStartPanel) { $arguments += ' -NoStartPanel' }
    Start-Process -FilePath $powerShellPath -Verb RunAs -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName System.Windows.Forms
$configurationPath = Join-Path $DataDirectory 'monitoring.json'
$selectedPaths = [Collections.Generic.List[string]]::new()
$logsDirectory = [IO.Path]::GetFullPath($DataDirectory)
if ([IO.File]::Exists($configurationPath)) {
    try {
        $saved = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
        foreach ($path in @($saved.paths)) {
            if ($path -and -not $selectedPaths.Contains([string]$path)) { $selectedPaths.Add([string]$path) }
        }
        if ($saved.logsDirectory) { $logsDirectory = [IO.Path]::GetFullPath([string]$saved.logsDirectory) }
    } catch {
        [System.Windows.Forms.MessageBox]::Show('Не удалось прочитать настройки аудита. Исправьте файл monitoring.json или обратитесь к администратору.', 'Аудит файлов', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        exit 1
    }
}

$initialPath = if ($selectedPaths.Count) { $selectedPaths[0] } else { [Environment]::GetFolderPath('MyDocuments') }
$dialogResult = if ($LogsOnly) { [System.Windows.Forms.DialogResult]::No } else { [System.Windows.Forms.DialogResult]::Yes }
while ($dialogResult -eq [System.Windows.Forms.DialogResult]::Yes) {
    $picker = [System.Windows.Forms.FolderBrowserDialog]::new()
    $picker.Description = 'Выберите папку с файлами для аудита.'
    $picker.ShowNewFolderButton = $false
    if ($initialPath -and [IO.Directory]::Exists($initialPath)) { $picker.SelectedPath = $initialPath }
    $result = $picker.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { break }

    $fullPath = [IO.Path]::GetFullPath($picker.SelectedPath)
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::Equals($fullPath, $volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    $duplicate = $false
    foreach ($existing in $selectedPaths) {
        if ([string]::Equals($existing, $fullPath, [StringComparison]::OrdinalIgnoreCase)) { $duplicate = $true; break }
    }
    if (-not $duplicate) { $selectedPaths.Add($fullPath) }
    $initialPath = $fullPath
    $dialogResult = [System.Windows.Forms.MessageBox]::Show(
        "Папка добавлена:`n$fullPath`n`nДобавить ещё одну папку?",
        'Аудит файлов',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
}

if (-not $selectedPaths.Count) {
    [System.Windows.Forms.MessageBox]::Show('Для запуска выберите хотя бы одну папку с файлами.', 'Аудит файлов', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit 1
}

$logPicker = [System.Windows.Forms.FolderBrowserDialog]::new()
$logPicker.Description = 'Выберите локальную папку сервера для сохранения журнала аудита.'
$logPicker.ShowNewFolderButton = $true
if ([IO.Directory]::Exists($logsDirectory)) { $logPicker.SelectedPath = $logsDirectory }
$logResult = $logPicker.ShowDialog()
if ($logResult -eq [System.Windows.Forms.DialogResult]::OK) {
    $logsDirectory = [IO.Path]::GetFullPath($logPicker.SelectedPath)
} elseif ($LogsOnly) {
    exit
}

$setupPath = Join-Path $PSScriptRoot 'setup-audit.ps1'
$taskPath = Join-Path $PSScriptRoot 'install-collector-task.ps1'
try {
    $existingTask = Get-ScheduledTask -TaskName 'DocumentAuditCollector' -ErrorAction SilentlyContinue
    if ($existingTask -and $existingTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName 'DocumentAuditCollector' -ErrorAction SilentlyContinue
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 250
            $existingTask = Get-ScheduledTask -TaskName 'DocumentAuditCollector' -ErrorAction SilentlyContinue
            if (-not $existingTask -or $existingTask.State -ne 'Running') { break }
        }
    }
    & $setupPath -Paths $selectedPaths.ToArray() -DataDirectory $DataDirectory -LogsDirectory $logsDirectory
    & $taskPath -DataDirectory $DataDirectory
    [System.Windows.Forms.MessageBox]::Show(
        "Аудит настроен для $($selectedPaths.Count) папок. Журнал сохраняется в:`n$logsDirectory`n`nСбор событий запущен в фоне.",
        'Аудит файлов',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    if (-not $NoStartPanel) {
        & (Join-Path (Split-Path $PSScriptRoot -Parent) 'start.ps1') -DataDirectory $DataDirectory
    }
} catch {
    if ($existingTask) {
        try { Start-ScheduledTask -TaskName 'DocumentAuditCollector' -ErrorAction SilentlyContinue } catch { }
    }
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Не удалось настроить аудит', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
