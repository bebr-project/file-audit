[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 4173,
    [string]$DataDirectory = (Join-Path $env:ProgramData 'DocumentAudit'),
    [string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$dataRoot = [IO.Path]::GetFullPath($DataDirectory)
$serverLogDirectory = if ($LogDirectory) { [IO.Path]::GetFullPath($LogDirectory) } else { $dataRoot }
$utf8 = [System.Text.UTF8Encoding]::new($false)
$serverVersion = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$script:eventCache = @()
$script:eventCacheUpdated = [DateTime]::MinValue
$script:eventCacheSignature = ''

function Get-LogsDirectory {
    $configurationPath = Join-Path $dataRoot 'monitoring.json'
    try {
        $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
        if ($configuration.logsDirectory) { return [IO.Path]::GetFullPath([string]$configuration.logsDirectory) }
    } catch { }
    return $dataRoot
}

function Get-CollectorStatus {
    $statusPath = Join-Path $dataRoot 'collector-status.json'
    $statusData = $null
    try { $statusData = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } catch { }

    $lastPoll = $null
    $state = 'stopped'
    if ($statusData -and $statusData.lastPoll) {
        try {
            $lastPollDate = [DateTimeOffset]::Parse([string]$statusData.lastPoll)
            $lastPoll = $lastPollDate.ToString('o')
            $state = if (([DateTimeOffset]::UtcNow - $lastPollDate.ToUniversalTime()).TotalSeconds -le 45) { 'running' } else { 'stale' }
        } catch { $state = 'stale' }
    }

    $lastEvent = if ($statusData) { [string]$statusData.lastEvent } else { $null }
    $computer = if ($statusData) { [string]$statusData.computer } else { $null }
    $collectorVersion = if ($statusData) { [string]$statusData.collectorVersion } else { $null }
    $paths = @()
    if ($statusData -and $statusData.paths) {
        $paths = @($statusData.paths)
    } else {
        $configurationPath = Join-Path $dataRoot 'monitoring.json'
        try {
            $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
            if ($configuration.paths) { $paths = @($configuration.paths) }
        } catch { }
    }
    $recordId = if ($statusData -and $null -ne $statusData.recordId) { [long]$statusData.recordId } else { $null }

    return [ordered]@{
        state = $state
        lastPoll = $lastPoll
        lastEvent = $lastEvent
        computer = $computer
        collectorVersion = $collectorVersion
        paths = $paths
        recordId = $recordId
    }
}

function Get-AuditEvents {
    $logsRoot = Get-LogsDirectory
    $files = @(Get-ChildItem -LiteralPath $logsRoot -Filter 'events*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = { $_.Name -eq 'events.jsonl' }; Descending = $true }, @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true })
    $signature = $logsRoot + '|' + (($files | ForEach-Object { '{0}:{1}:{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join '|')
    if ($script:eventCacheSignature -eq $signature -and ([DateTime]::UtcNow - $script:eventCacheUpdated).TotalSeconds -lt 3) {
        return $script:eventCache
    }

    $unique = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        try { $lines = [IO.File]::ReadAllLines($file.FullName, $utf8) } catch { continue }
        for ($index = $lines.Length - 1; $index -ge 0; $index--) {
            if ([string]::IsNullOrWhiteSpace($lines[$index])) { continue }
            try { $event = $lines[$index] | ConvertFrom-Json } catch { continue }
            if (-not $event.path -or -not $event.time) { continue }
            if ($event.eventId -eq 4663 -and $event.operation -eq 'Удаление') {
                $event.operation = 'Операция с именем'
            }
            $fallbackKey = '{0}:{1}|{2}|{3}' -f $event.computer, $event.recordId, $event.path, $event.user
            $key = if ($event.id) { [string]$event.id } else { $fallbackKey }
            if (-not $unique.ContainsKey($key)) { $unique.Add($key, $event) }
            if ($unique.Count -ge 20000) { break }
        }
        if ($unique.Count -ge 20000) { break }
    }

    $script:eventCache = @($unique.Values | Sort-Object { try { [DateTimeOffset]::Parse([string]$_.time) } catch { [DateTimeOffset]::MinValue } } -Descending)
    $script:eventCacheSignature = $signature
    $script:eventCacheUpdated = [DateTime]::UtcNow
    return $script:eventCache
}

function Send-HttpResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Body
    )

    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentEncoding = $utf8
    $response.ContentLength64 = $Body.Length
    $response.Headers['Cache-Control'] = 'no-store, max-age=0'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['X-Frame-Options'] = 'DENY'
    $response.Headers['Referrer-Policy'] = 'no-referrer'
    $response.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
    if ($Context.Request.HttpMethod -ne 'HEAD' -and $Body.Length -gt 0) {
        $response.OutputStream.Write($Body, 0, $Body.Length)
    }
    $response.Close()
}

function Send-Json {
    param([System.Net.HttpListenerContext]$Context, [int]$StatusCode, [object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    Send-HttpResponse -Context $Context -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body $utf8.GetBytes($json)
}

function Handle-Request {
    param([System.Net.HttpListenerContext]$Context)

    $request = $Context.Request
    $remote = $request.RemoteEndPoint.Address
    $hostHeader = [string]$request.Headers['Host']
    if (-not [IPAddress]::IsLoopback($remote) -or $hostHeader -notmatch '^(localhost|127\.0\.0\.1|\[::1\])(:\d{1,5})?$') {
        Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'Сервер доступен только на этом компьютере.' }
        return
    }
    if ($request.HttpMethod -notin @('GET', 'HEAD')) {
        $Context.Response.Headers['Allow'] = 'GET, HEAD'
        Send-Json -Context $Context -StatusCode 405 -Value @{ error = 'Метод не поддерживается.' }
        return
    }

    $pathname = [Uri]::UnescapeDataString($request.Url.AbsolutePath)
    if ($request.HttpMethod -eq 'GET' -and $pathname -eq '/api/status') {
        $collector = Get-CollectorStatus
        Send-Json -Context $Context -StatusCode 200 -Value @{
            ok = $true
            app = 'document-audit'
            serverVersion = $serverVersion
            computer = [Environment]::MachineName
            collector = $collector
            dataDirectory = $dataRoot
            logsDirectory = (Get-LogsDirectory)
            serverLogDirectory = $serverLogDirectory
        }
        return
    }
    if ($request.HttpMethod -eq 'GET' -and $pathname -eq '/api/events') {
        $limit = 20000
        $requested = 0
        if ([int]::TryParse([string]$request.QueryString['limit'], [ref]$requested) -and $requested -gt 0) {
            $limit = [Math]::Min(20000, $requested)
        }
        $events = @(Get-AuditEvents | Select-Object -First $limit)
        Send-Json -Context $Context -StatusCode 200 -Value @{ ok = $true; count = $events.Count; events = $events }
        return
    }
    if ($pathname.StartsWith('/api/')) {
        Send-Json -Context $Context -StatusCode 404 -Value @{ error = 'Метод API не найден.' }
        return
    }

    $relative = if ($pathname -eq '/') { 'index.html' } else { $pathname.TrimStart('/') }
    $filePath = [IO.Path]::GetFullPath((Join-Path $appRoot $relative))
    if (-not $filePath.StartsWith("$appRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'Доступ запрещён.' }
        return
    }
    if (-not [IO.File]::Exists($filePath)) {
        Send-Json -Context $Context -StatusCode 404 -Value @{ error = 'Файл не найден.' }
        return
    }

    $contentTypes = @{
        '.html' = 'text/html; charset=utf-8'
        '.css' = 'text/css; charset=utf-8'
        '.js' = 'text/javascript; charset=utf-8'
        '.svg' = 'image/svg+xml'
    }
    $extension = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
    if (-not $contentTypes.ContainsKey($extension)) {
        Send-Json -Context $Context -StatusCode 415 -Value @{ error = 'Тип файла не поддерживается.' }
        return
    }
    $body = [IO.File]::ReadAllBytes($filePath)
    Send-HttpResponse -Context $Context -StatusCode 200 -ContentType $contentTypes[$extension] -Body $body
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
    Write-Output "Document Audit слушает http://127.0.0.1:$Port/"
    while ($listener.IsListening) {
        $context = $null
        try {
            $context = $listener.GetContext()
            Handle-Request -Context $context
        } catch [System.Net.HttpListenerException] {
            if ($listener.IsListening) { Write-Error $_ }
        } catch {
            Write-Error $_
            if ($context -and $context.Response.OutputStream) {
                try { Send-Json -Context $context -StatusCode 500 -Value @{ error = 'Ошибка локального сервера.' } } catch { }
            }
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
