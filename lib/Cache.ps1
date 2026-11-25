function Test-CacheService($Config) {
    $client = [Net.Sockets.TcpClient]::new()
    try { $client.Connect([Net.IPAddress]::Loopback, $Config.cache.port); $true }
    catch [Net.Sockets.SocketException] { $false }
    finally { $client.Dispose() }
}

function Invoke-DiscoveryCacheTransfer([string]$BuildXL, $Config, [string]$Verb, [string]$Path, [string]$Hash) {
    $application = Join-Path (Split-Path $BuildXL) 'ContentStoreApp.exe'
    $arguments = @($Verb, '/cacheName:DEFAULT', "/grpcPort:$($Config.cache.port)", "/scenario:$($Config.cache.scenario)",
        "/path:$Path", '/hashType:SHA256', '/realizationMode:Copy')
    if ($Verb -eq 'placeFile') { $arguments += @("/hash:$Hash", '/accessMode:Write') }
    try {
        $message = & $application @arguments 2>&1
        $message -join [char]10
    } catch {
        Write-Warning "Discovery cache transfer failed: $_"
    }
}

function Invoke-CacheService([string]$StateRoot, $Config, [switch]$Stop) {
    $bxl = Get-BuildXL $StateRoot
    $application = Join-Path (Split-Path $bxl) 'ContentStoreApp.exe'
    $cache = $Config.cache
    if ($Stop) { & $application service /stop "/scenario:$($cache.scenario)"; return }
    $directory = Join-Path $StateRoot 'cache-service'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $cache.port)
    try { $probe.Start() } finally { $probe.Stop() }
    Initialize-Msvc
    $client = @{
        Assembly = 'BuildXL.Cache.MemoizationStoreAdapter'
        Type = 'BuildXL.Cache.MemoizationStoreAdapter.MemoizationStoreCacheFactory'
        CacheId = 'RustBxlCache'; CacheName = 'DEFAULT'
        CacheLogPath = '[BuildXLSelectedLogPath]'; CacheRootPath = '[BuildXLSelectedRootPath]'
        EnableContentServer = $true; EnableMetadataServer = $true
        GrpcPort = $cache.port; ScenarioName = $cache.scenario; RetryIntervalSeconds = 1; RetryCount = 3
    }
    Write-Json $client (Join-Path $directory 'client.json')
    $arguments = @('service', '/names:DEFAULT', "/paths:$(Join-Path $StateRoot 'cache')",
        "/dataRootPath:$directory", "/grpcPort:$($cache.port)", "/grpcPortFileName:$($cache.scenario)",
        "/scenario:$($cache.scenario)", '/enableMetadata', "/maxSizeQuotaMB:$($cache.maxSizeMiB)",
        "/logDirectoryPath:$(Join-Path $directory 'logs')", '/logSeverity:Warning')
    $telemetry = Start-MsvcTelemetry
    try { & $application @arguments }
    finally { Stop-MsvcTelemetry $telemetry }
}
