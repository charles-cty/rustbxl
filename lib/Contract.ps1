function Get-CargoFiles([string]$Project, [string]$CargoHome) {
    $paths = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push([IO.DirectoryInfo]::new($Project))
    while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($item in $directory.EnumerateFileSystemInfos()) {
            if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                if ($item.Name -notin @('.git', 'target') -and
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $pending.Push([IO.DirectoryInfo]$item)
                }
            } elseif ($item.Name -in @('Cargo.toml', 'Cargo.lock', 'rust-toolchain', 'rust-toolchain.toml')) {
                $paths.Add($item.FullName)
            }
        }
    }
    $files = [ordered]@{}
    foreach ($path in ($paths | Sort-Object)) {
        $files['workspace:' + [IO.Path]::GetRelativePath($Project, $path)] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
    }
    $directory = $Project
    $level = 0
    while ($directory) {
        foreach ($name in @('.cargo\config', '.cargo\config.toml')) {
            $path = Join-Path $directory $name
            $files["ancestor:$level/$name"] = if (Test-Path -LiteralPath $path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) } else { $null }
        }
        $directory = Split-Path -Parent $directory
        $level++
    }
    foreach ($name in @('config', 'config.toml')) {
        $path = Join-Path $CargoHome $name
        $files["cargo-home:$name"] = if (Test-Path -LiteralPath $path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) } else { $null }
    }
    $files
}

function Get-CaptureContract([string]$Project, [string]$StateRoot, $Config, $Layout, [string]$Bxl) {
    $environment = Get-BuildEnvironment $Config $StateRoot $Layout
    $versions = Invoke-WithEnvironment $environment {
        @{ rustc = (rustc.exe -vV) -join [char]10; cargo = cargo.exe --version }
    }
    [ordered]@{
        version = 1
        graphFormat = 1
        helperVersion = (Get-Item -LiteralPath (Get-Helper)).VersionInfo.FileVersion
        sourceNamespace = $Layout.Source
        targetNamespace = $Layout.Target
        build = $Config.build
        rustc = $versions.rustc
        cargo = $versions.cargo
        buildxlPackage = Split-Path (Split-Path $Bxl) -Leaf
        environment = $environment
        files = Get-CargoFiles $Project (Join-Path $StateRoot 'cargo-home')
    }
}

function Assert-CaptureContract([string]$Project, [string]$StateRoot, $Config, $Layout, [string]$Bxl) {
    $path = Join-Path $Layout.Capture 'contract.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Capture is missing. Run capture first.' }
    $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $current = Get-CaptureContract $Project $StateRoot $Config $Layout $Bxl
    foreach ($key in $current.Keys) {
        if (-not $saved.Contains($key)) { throw "Capture input changed: $key. Run capture for the current graph format." }
        $old = ConvertTo-Json -InputObject $saved[$key] -Depth 12 -Compress
        $new = ConvertTo-Json -InputObject $current[$key] -Depth 12 -Compress
        if ($old -cne $new) { throw "Capture input changed: $key. Run capture for this worktree and build configuration." }
    }
}

function Assert-ContainedDependencies([string]$Project, [string]$StateRoot, $Config, $Layout) {
    $environment = Get-BuildEnvironment $Config $StateRoot $Layout
    $environment.CARGO_TARGET_DIR = $Layout.PhysicalTarget
    $metadata = Invoke-WithEnvironment $environment {
        Push-Location $Project
        try { (cargo.exe metadata --format-version 1 --no-deps --offline --locked) -join [char]10 }
        finally { Pop-Location }
    } | ConvertFrom-Json -AsHashtable
    if ([IO.Path]::GetFullPath($metadata.workspace_root) -ne $Project) {
        throw "Use the Cargo workspace root: $($metadata.workspace_root)"
    }
    foreach ($package in $metadata.packages) {
        foreach ($dependency in $package.dependencies) {
            if ($dependency.ContainsKey('path') -and -not (Test-Within $dependency.path $Project)) {
                throw "Path dependency is outside the mapped workspace: $($dependency.path). An additional mapping adapter is required."
            }
        }
    }
}
