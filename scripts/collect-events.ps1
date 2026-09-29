[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $env:ProgramData 'DocumentAudit'),
    [ValidateRange(2, 300)]
    [int]$PollSeconds = 10,
    [ValidateRange(1, 5000)]
    [int]$BatchSize = 1000
)

$ErrorActionPreference = 'Stop'
$dataDirectory = [IO.Path]::GetFullPath($DataDirectory)
$configurationPath = Join-Path $dataDirectory 'monitoring.json'
$statePath = Join-Path $dataDirectory 'collector-state.json'
$statusPath = Join-Path $dataDirectory 'collector-status.json'
$maximumLogBytes = 25MB
$computerName = $env:COMPUTERNAME
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$collectorVersion = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$filterVersion = 'all-files-v1'
$knownEventIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

if (-not [IO.File]::Exists($configurationPath)) {
    throw "Не найдена конфигурация $configurationPath. Сначала запустите scripts\setup-audit.ps1 от имени администратора."
}

$configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
$logsDirectory = if ($configuration.logsDirectory) { [IO.Path]::GetFullPath([string]$configuration.logsDirectory) } else { $dataDirectory }
$eventsPath = Join-Path $logsDirectory 'events.jsonl'
$watchedPaths = @($configuration.paths | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\') })
if (-not $watchedPaths.Count) {
    throw "В $configurationPath нет папок под наблюдением. Повторно выполните scripts\setup-audit.ps1."
}

[IO.Directory]::CreateDirectory($dataDirectory) | Out-Null
[IO.Directory]::CreateDirectory($logsDirectory) | Out-Null

$lockStream = $null
try {
    $lockStream = [IO.File]::Open((Join-Path $dataDirectory 'collector.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch {
    throw 'Сборщик уже запущен. Проверьте задачу DocumentAuditCollector в планировщике Windows.'
}

function Write-AtomicJson {
    param([string]$Target, [object]$Value)
    $temporary = "$Target.$PID.tmp"
    $json = ConvertTo-Json -InputObject $Value -Depth 6
    [IO.File]::WriteAllText($temporary, $json, $utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Target -Force
}

function Test-WatchedFile {
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $false }
    if ([IO.Directory]::Exists($FilePath)) { return $false }
    $logsPrefix = if ($logsDirectory.EndsWith('\')) { $logsDirectory } else { "$logsDirectory\" }
    if ($FilePath.StartsWith($logsPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($watchedRoot in $watchedPaths) {
        $root = [string]$watchedRoot
        $rootPrefix = if ($root.EndsWith('\')) { $root } else { "$root\" }
        if ($FilePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Convert-AccessMask {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [UInt64]0 }
    $value = $Text.Trim()
    try {
        if ($value.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
            return [Convert]::ToUInt64($value.Substring(2), 16)
        }
        return [Convert]::ToUInt64($value, 10)
    } catch {
        return [UInt64]0
    }
}

function Get-AuditOperation {
    param([UInt64]$Mask)
    if (($Mask -band [UInt64]0x4) -ne 0) { return 'Дополнение' }
    return 'Изменение'
}

function Get-HandleKey {
    param([hashtable]$Fields)
    $handle = [string]$Fields.HandleId
    if ([string]::IsNullOrWhiteSpace($handle) -or $handle -eq '0x0') { return $null }
    return '{0}|{1}|{2}|{3}' -f $Fields.SubjectUserSid, $Fields.SubjectLogonId, $Fields.ProcessId, $handle
}

function Add-AuditEvents {
    param([object[]]$Items)
    if (-not $Items.Count) { return 0 }

    $records = [Collections.Generic.List[string]]::new()
    $newIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $latestEvent = $null
    $highestRecordId = 0L

    foreach ($item in $Items) {
        $recordId = [Int64]$item.RecordId
        if ($recordId -gt $highestRecordId) { $highestRecordId = $recordId }
        try {
            [xml]$eventXml = $item.ToXml()
            $fields = @{}
            foreach ($field in $eventXml.Event.EventData.Data) {
                $fields[[string]$field.Name] = [string]$field.InnerText
            }

            $eventId = [int]$eventXml.Event.System.EventID
            $timestamp = [DateTimeOffset]::Parse([string]$eventXml.Event.System.TimeCreated.SystemTime).ToUniversalTime().ToString('o')
            $handleKey = Get-HandleKey -Fields $fields
            if ($eventId -eq 4660) {
                if (-not $handleKey -or -not $pendingDeletes.ContainsKey($handleKey)) { continue }
                $candidate = $pendingDeletes[$handleKey]
                $pendingDeletes.Remove($handleKey) | Out-Null
                $entry = [ordered]@{
                    id = "$computerName-$recordId"
                    time = $timestamp
                    user = $candidate.user
                    domain = $candidate.domain
                    path = $candidate.path
                    operation = 'Удаление'
                    process = $candidate.process
                    computer = $computerName
                    eventId = 4660
                    recordId = $recordId
                    accessMask = '0x10000'
                }
                if ($knownEventIds.Contains($entry.id) -or -not $newIds.Add($entry.id)) { continue }
                $records.Add((ConvertTo-Json -InputObject $entry -Compress -Depth 4))
                $latestEvent = $timestamp
                continue
            }
            if ($eventId -ne 4663) { continue }

            $filePath = [string]$fields.ObjectName
            if (-not (Test-WatchedFile -FilePath $filePath)) { continue }
            $mask = Convert-AccessMask -Text ([string]$fields.AccessMask)
            $writes = ([UInt64]0x2 -bor [UInt64]0x4 -bor [UInt64]0x10 -bor [UInt64]0x100 -bor [UInt64]0x40000000)
            if (($mask -band $writes) -eq 0 -and ($mask -band [UInt64]0x10000) -eq 0) { continue }

            $subject = [string]$fields.SubjectUserName
            if ($subject -eq 'SYSTEM' -or $subject -eq 'LOCAL SERVICE' -or $subject -eq 'NETWORK SERVICE' -or $subject.EndsWith('$')) { continue }
            if ([string]::IsNullOrWhiteSpace($subject) -or $subject -eq '-') { $subject = 'неизвестный пользователь' }
            if (($mask -band [UInt64]0x10000) -ne 0 -and $handleKey) {
                $pendingDeletes[$handleKey] = [ordered]@{
                    key = $handleKey
                    time = $timestamp
                    user = $subject
                    domain = [string]$fields.SubjectDomainName
                    path = $filePath
                    process = [string]$fields.ProcessName
                }
            }
            if (($mask -band $writes) -eq 0) { continue }
            $entry = [ordered]@{
                id = "$computerName-$recordId"
                time = $timestamp
                user = $subject
                domain = [string]$fields.SubjectDomainName
                path = $filePath
                operation = Get-AuditOperation -Mask $mask
                process = [string]$fields.ProcessName
                computer = $computerName
                eventId = $eventId
                recordId = $recordId
                accessMask = [string]$fields.AccessMask
            }
            if ($knownEventIds.Contains($entry.id) -or -not $newIds.Add($entry.id)) { continue }
            $records.Add((ConvertTo-Json -InputObject $entry -Compress -Depth 4))
            $latestEvent = $timestamp
        } catch {
            Write-Warning "Пропущено некорректное событие $recordId : $($_.Exception.Message)"
        }
    }

    if ($records.Count) {
        if ([IO.File]::Exists($eventsPath) -and ([IO.FileInfo]::new($eventsPath).Length + ($records -join "`n").Length) -gt $maximumLogBytes) {
            $archiveName = 'events.{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -LiteralPath $eventsPath -Destination (Join-Path $logsDirectory $archiveName)
        }
        $payload = ($records -join "`n") + "`n"
        [IO.File]::AppendAllText($eventsPath, $payload, $utf8NoBom)
        foreach ($id in $newIds) { $knownEventIds.Add($id) | Out-Null }
    }

    return [pscustomobject]@{ RecordId = $highestRecordId; LastEvent = $latestEvent; Count = $records.Count }
}

$savedState = $null
try { $savedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { }
$lastRecordId = if ($savedState -and $savedState.recordId -ge 0) { [Int64]$savedState.recordId } else { 0L }
$lastEvent = if ($savedState) { [string]$savedState.lastEvent } else { $null }
$recentLogCutoff = [DateTime]::UtcNow.AddHours(-2)
foreach ($logFile in @(Get-ChildItem -LiteralPath $logsDirectory -Filter 'events*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $recentLogCutoff })) {
    try {
        foreach ($line in [IO.File]::ReadLines($logFile.FullName, $utf8NoBom)) {
            if ($line -match '"id":"([^"\\]+)"') { $knownEventIds.Add($matches[1]) | Out-Null }
        }
    } catch { Write-Warning "Не удалось прочитать старый журнал $($logFile.Name): $($_.Exception.Message)" }
}
$needsBackfill = $savedState -and $savedState.filterVersion -ne $filterVersion
if ($needsBackfill) {
    $recentQuery = '*[System[TimeCreated[timediff(@SystemTime) <= 3600000] and ((EventID=4663) or (EventID=4660))]]'
    $firstRecent = Get-WinEvent -LogName Security -FilterXPath $recentQuery -Oldest -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($firstRecent -and [Int64]$firstRecent.RecordId -le $lastRecordId) {
        $lastRecordId = [Math]::Max(0L, [Int64]$firstRecent.RecordId - 1L)
        Write-Host 'Обновлён фильтр: повторно проверяю события за последний час.' -ForegroundColor Cyan
    }
}
$pendingDeletes = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
if (-not $needsBackfill -and $savedState -and $savedState.pendingDeletes) {
    foreach ($candidate in @($savedState.pendingDeletes)) {
        if ($candidate.key -and $candidate.path) { $pendingDeletes[[string]$candidate.key] = $candidate }
    }
}

Write-Host "Сборщик аудита запущен на $computerName. Опрос каждые $PollSeconds сек." -ForegroundColor Green
Write-Host "Папки: $($watchedPaths -join ', ')"
Write-Host 'Для остановки нажмите Ctrl+C.'

try {
    while ($true) {
        $pollTime = [DateTime]::UtcNow.ToString('o')
        $newRecords = 0
        $batchWasFull = $false
        try {
            $latest = Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop
            if ([Int64]$latest.RecordId -lt $lastRecordId) {
                Write-Warning 'Обнаружена очистка журнала Security; продолжаю с начала текущего журнала.'
                $lastRecordId = 0L
            }

            $query = "*[System[((EventID=4663) or (EventID=4660)) and (EventRecordID > $lastRecordId)]]"
            $batch = @(Get-WinEvent -LogName Security -FilterXPath $query -Oldest -MaxEvents $BatchSize -ErrorAction SilentlyContinue | Sort-Object RecordId)
            $batchWasFull = $batch.Count -ge $BatchSize
            if ($batch.Count) {
                $result = Add-AuditEvents -Items $batch
                if ($result.RecordId -gt $lastRecordId) { $lastRecordId = $result.RecordId }
                if ($result.LastEvent) { $lastEvent = $result.LastEvent }
                $newRecords = $result.Count
            }
            if ($newRecords -gt 0) {
                Write-Host "Добавлено событий: $newRecords · $([DateTime]::Now.ToString('HH:mm:ss'))"
            }
            $referenceTime = [DateTimeOffset]::UtcNow
            if ($batch.Count -and $batch[-1].TimeCreated) {
                $referenceTime = [DateTimeOffset]$batch[-1].TimeCreated
            }
            foreach ($key in @($pendingDeletes.Keys)) {
                try {
                    $candidateTime = [DateTimeOffset]::Parse([string]$pendingDeletes[$key].time)
                    if ($candidateTime -lt $referenceTime.AddMinutes(-10)) { $pendingDeletes.Remove($key) | Out-Null }
                } catch { $pendingDeletes.Remove($key) | Out-Null }
            }
        } catch {
            Write-Warning "Не удалось прочитать журнал Security: $($_.Exception.Message)"
        }

        $checkpoint = [ordered]@{
            recordId = $lastRecordId
            lastEvent = $lastEvent
            lastPoll = $pollTime
            computer = $computerName
            paths = @($watchedPaths)
            logsDirectory = $logsDirectory
            collectorVersion = $collectorVersion
            filterVersion = $filterVersion
            pendingDeletes = @($pendingDeletes.Values)
        }
        try {
            Write-AtomicJson -Target $statePath -Value $checkpoint
            Write-AtomicJson -Target $statusPath -Value $checkpoint
        } catch {
            Write-Warning "Не удалось сохранить состояние сборщика: $($_.Exception.Message)"
        }
        if (-not $batchWasFull) {
            Start-Sleep -Seconds $PollSeconds
        }
    }
} finally {
    if ($lockStream) { $lockStream.Dispose() }
}
