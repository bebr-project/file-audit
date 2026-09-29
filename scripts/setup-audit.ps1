[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('Path')]
    [string[]]$Paths,

    [string]$DataDirectory = (Join-Path $env:ProgramData 'DocumentAudit'),

    [string]$LogsDirectory
)

$ErrorActionPreference = 'Stop'

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Откройте PowerShell от имени администратора и запустите скрипт снова.'
}

$resolvedPaths = @(
    foreach ($candidate in $Paths) {
        $fullPath = [IO.Path]::GetFullPath($candidate.Trim())
        if (-not [IO.Directory]::Exists($fullPath)) {
            throw "Каталог не найден: $fullPath"
        }
        $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
        if ([string]::Equals($fullPath, $volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $fullPath
        } else {
            $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        }
    }
) | Select-Object -Unique

if (-not $resolvedPaths.Count) {
    throw 'Укажите хотя бы одну папку для аудита.'
}

$configurationPath = Join-Path $DataDirectory 'monitoring.json'
$previousLogsDirectory = [IO.Path]::GetFullPath($DataDirectory)
if ([IO.File]::Exists($configurationPath)) {
    try {
        $oldConfiguration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
        if ($oldConfiguration.logsDirectory) {
            $previousLogsDirectory = [IO.Path]::GetFullPath([string]$oldConfiguration.logsDirectory)
        }
    } catch {
        throw "Не удалось прочитать настройки аудита: $configurationPath"
    }
}
if ([string]::IsNullOrWhiteSpace($LogsDirectory)) { $LogsDirectory = $previousLogsDirectory }
if (-not [IO.Path]::IsPathRooted($LogsDirectory) -or $LogsDirectory.StartsWith('\\')) {
    throw 'Для журнала выберите папку на локальном диске сервера.'
}
$logsRoot = [IO.Path]::GetFullPath($LogsDirectory.Trim())
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($logsRoot))
if ($drive.DriveType -ne [IO.DriveType]::Fixed -or -not $drive.IsReady) {
    throw 'Для журнала нужен доступный локальный диск сервера. Подключённые сетевые диски не поддерживаются.'
}
foreach ($watchedPath in $resolvedPaths) {
    $logPrefix = if ($logsRoot.EndsWith('\')) { $logsRoot } else { "$logsRoot\" }
    if ([string]::Equals($logsRoot.TrimEnd('\'), ([string]$watchedPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
        ([string]$watchedPath).StartsWith($logPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Папка журнала должна отличаться от наблюдаемой папки и не может содержать её внутри себя.'
    }
}

# File System subcategory GUID is stable across Windows display languages.
$subcategory = '{0CCE921D-69AE-11D9-BED3-505054503030}'
& auditpol.exe /set "/subcategory:$subcategory" /success:enable /failure:disable | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Windows не включила аудит файловой системы. Проверьте права администратора и локальную политику аудита.'
}

$everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
$rights = [Security.AccessControl.FileSystemRights]::WriteData -bor
    [Security.AccessControl.FileSystemRights]::AppendData -bor
    [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
    [Security.AccessControl.FileSystemRights]::Delete
$inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
    [Security.AccessControl.InheritanceFlags]::ObjectInherit
$propagation = [Security.AccessControl.PropagationFlags]::None
$auditFlags = [Security.AccessControl.AuditFlags]::Success

foreach ($root in $resolvedPaths) {
    Write-Host "Настраиваю правила аудита: $root" -ForegroundColor Cyan
    $acl = Get-Acl -LiteralPath $root -Audit
    $exists = @($acl.GetAuditRules($true, $true, [Security.Principal.SecurityIdentifier])) | Where-Object {
        $_.IdentityReference -eq $everyone -and
        $_.FileSystemRights -eq $rights -and
        $_.InheritanceFlags -eq $inheritance -and
        $_.PropagationFlags -eq $propagation -and
        $_.AuditFlags -eq $auditFlags
    } | Select-Object -First 1

    if (-not $exists) {
        $rule = [Security.AccessControl.FileSystemAuditRule]::new(
            $everyone,
            $rights,
            $inheritance,
            $propagation,
            $auditFlags
        )
        $acl.AddAuditRule($rule)
        Set-Acl -LiteralPath $root -AclObject $acl
    }
}

[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null
if (-not [string]::Equals($previousLogsDirectory.TrimEnd('\'), $logsRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    foreach ($oldLog in @(Get-ChildItem -LiteralPath $previousLogsDirectory -Filter 'events*.jsonl' -File -ErrorAction SilentlyContinue)) {
        $target = Join-Path $logsRoot $oldLog.Name
        if ([IO.File]::Exists($target)) {
            $sameContents = ([IO.FileInfo]::new($target).Length -eq $oldLog.Length) -and
                ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $oldLog.FullName -Algorithm SHA256).Hash)
            if ($sameContents) { continue }
            $suffix = 1
            do {
                $target = Join-Path $logsRoot ('events.migrated-{0}-{1}.jsonl' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $suffix)
                $suffix++
            } while ([IO.File]::Exists($target))
        }
        [IO.File]::Copy($oldLog.FullName, $target, $false)
    }
}
$configuration = [ordered]@{
    paths = @($resolvedPaths)
    logsDirectory = $logsRoot
    updatedAt = [DateTime]::UtcNow.ToString('o')
}
$configurationJson = $configuration | ConvertTo-Json -Depth 4
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($configurationPath, $configurationJson, $utf8NoBom)

Write-Host ''
Write-Host 'Аудит файловой системы включён.' -ForegroundColor Green
Write-Host "Папок под наблюдением: $($resolvedPaths.Count)"
Write-Host "Папка журнала: $logsRoot"
Write-Host "Конфигурация сборщика: $(Join-Path $DataDirectory 'monitoring.json')"
Write-Host 'Следующим шагом зарегистрируйте сборщик: .\scripts\install-collector-task.ps1' -ForegroundColor Yellow
