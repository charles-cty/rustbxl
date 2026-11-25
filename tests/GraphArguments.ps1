function Test-GraphArguments([string]$Project, [string]$StateRoot, $Config) {
    $layout = Get-Layout $StateRoot 'arguments' 'main' $Config
    $graphDirectory = Join-Path $StateRoot 'argument-graph'
    New-Item -ItemType Directory -Path $graphDirectory -Force | Out-Null
    $samples = [Collections.Generic.List[string[]]]::new()
    $samples.Add(@('', 'plain', 'two words', '中文路径', 'C:\ends with slash\'))
    $samples.Add(@('a"b', 'a\"b', '--remap-path-prefix=C:\space 中文\=/_/target', '${data}', ('line1' + [char]10 + 'line2')))
    $random = [Random]::new(2147)
    $alphabet = 'ab "\中'
    for ($sample = 0; $sample -lt 20; $sample++) {
        $values = @(for ($argument = 0; $argument -lt 5; $argument++) {
            $characters = for ($character = 0; $character -lt $random.Next(0, 30); $character++) {
                $alphabet[$random.Next($alphabet.Length)]
            }
            -join $characters
        })
        $samples.Add([string[]]$values)
    }
    $nodes = @(for ($index = 0; $index -lt $samples.Count; $index++) {
        $output = Join-Path $layout.Target "arguments\$index"
        @{
            id = "arguments-$index"; kind = 'process'
            tool = @{kind='file'; path=(Get-Helper)}
            arguments = @('write-arguments', (Join-Path $output 'actual.json')) + @($samples[$index])
            workingDirectory = $layout.Source
            environment = @(@{name='SystemRoot'; value=$env:SystemRoot})
            dependencies = @(); outputDirectories = @($output); untrackedFiles = @()
            disableCacheLookup = $true
        }
    })
    Write-Json @{version=1; nodes=$nodes} (Join-Path $graphDirectory 'graph.json')
    $bxl = Get-BuildXL $StateRoot
    Invoke-BuildXL $bxl $graphDirectory $layout.Run $Project $layout $Config $StateRoot 'arguments' | Out-Host
    for ($index = 0; $index -lt $samples.Count; $index++) {
        $path = Join-Path $layout.PhysicalTarget "arguments\$index\actual.json"
        $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -NoEnumerate
        $expected = $samples[$index]
        if ($actual.Count -ne $expected.Count) { throw "BuildXL argument count changed in sample $index." }
        for ($argument = 0; $argument -lt $expected.Count; $argument++) {
            if ($actual[$argument] -cne $expected[$argument]) { throw "BuildXL argument $argument changed in sample $index." }
        }
    }
    $samples.Count
}
