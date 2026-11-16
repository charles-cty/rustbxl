function Invoke-ArtifactCompression([string]$StateRoot, $Config, [string[]]$ActiveInstances,
    [string[]]$ExcludePaths, [int]$MinimumAgeDays, [long]$MinimumBytes, [switch]$Apply) {
    $instances = Join-Path $StateRoot 'instances'
    $known = @(if (Test-Path -LiteralPath $instances) {
        Get-ChildItem -LiteralPath $instances -Directory | Where-Object { -not $_.LinkType } | ForEach-Object Name
    })
    if ($ActiveInstances.Count -eq 0) { $ActiveInstances = @($known) }
    foreach ($name in $ActiveInstances) {
        if ($name -notin $known) { throw "Active instance does not exist: $name" }
    }
    $excludes = @(foreach ($path in $ExcludePaths) {
        $full = [IO.Path]::GetFullPath($path, $StateRoot)
        if (-not (Test-Within $full $StateRoot)) { throw 'Compression exclusions must be inside the state directory.' }
        if (-not (Test-Path -LiteralPath $full)) { throw "Compression exclusion does not exist: $path" }
        $full
    })
    # Hold the cache endpoint while the maintenance lock excludes CLI clients.
    $endpoint = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Config.cache.port)
    try {
        try { $endpoint.Start() }
        catch [Net.Sockets.SocketException] { throw 'Stop the cache service before artifact compression.' }
        $directory = Join-Path $StateRoot 'maintenance'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $request = Join-Path $directory 'compression-request.json'
        Write-Json @{
            StateRoot=$StateRoot; Scenario=$Config.cache.scenario; ActiveInstances=@($ActiveInstances)
            ExcludePaths=$excludes; MinimumAgeDays=$MinimumAgeDays; MinimumBytes=$MinimumBytes; Apply=$Apply.IsPresent
        } $request
        $output = @(& (Get-Helper) compress-artifacts $request) -join [char]10
        $result = $output | ConvertFrom-Json -AsHashtable
        Write-Json $result (Join-Path $directory 'compression-result.json')
        $output
    } finally { $endpoint.Stop() }
}
