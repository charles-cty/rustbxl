function Test-ContractFiles([string]$RunRoot) {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Contract.ps1')
    $testRoot = Join-Path $RunRoot 'contract-files'
    $project = Join-Path $testRoot 'workspace'
    $cargoHome = Join-Path $testRoot 'cargo-home'
    $external = Join-Path $testRoot 'linked-dependency'
    New-Item -ItemType Directory -Path $project, $cargoHome, $external -Force | Out-Null

    $empty = Get-CargoFiles $project $cargoHome
    Assert (@($empty.Keys | Where-Object { $_.StartsWith('workspace:') }).Count -eq 0) 'Empty scan returned workspace files.'
    [IO.File]::WriteAllText((Join-Path $project 'Cargo.toml'), '[workspace]')
    $single = Get-CargoFiles $project $cargoHome
    Assert (@($single.Keys | Where-Object { $_.StartsWith('workspace:') }).Count -eq 1) 'Single-manifest scan lost its file.'

    $expected = [ordered]@{
        'Cargo.toml' = '[workspace]'
        'child\Cargo.lock' = 'version = 4'
        '.hidden\rust-toolchain.toml' = '[toolchain]'
        'nested\deep\rust-toolchain' = 'stable'
    }
    foreach ($relative in $expected.Keys) {
        $path = Join-Path $project $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, $expected[$relative])
    }
    $hidden = [IO.DirectoryInfo]::new((Join-Path $project '.hidden'))
    $hidden.Attributes = $hidden.Attributes -bor [IO.FileAttributes]::Hidden
    foreach ($relative in @('.git\Cargo.toml','target\Cargo.lock','child\target\Cargo.toml','Cargo.toml.orig')) {
        $path = Join-Path $project $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'excluded')
    }
    [IO.File]::WriteAllText((Join-Path $external 'Cargo.toml'), 'excluded-junction')
    New-Item -ItemType Junction -Path (Join-Path $project 'linked') -Target $external | Out-Null
    foreach ($directory in @($project, $testRoot)) {
        New-Item -ItemType Directory -Path (Join-Path $directory '.cargo') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory '.cargo\config.toml'), $directory)
    }
    [IO.File]::WriteAllText((Join-Path $cargoHome 'config'), 'cargo-home-config')

    $files = Get-CargoFiles $project $cargoHome
    $keys = @($files.Keys | Where-Object { $_.StartsWith('workspace:') })
    Assert ($keys.Count -eq $expected.Count) 'Scan included an excluded path or omitted a manifest.'
    foreach ($relative in $expected.Keys) {
        $key = 'workspace:' + $relative
        Assert ($files.Contains($key)) "Scan omitted $relative."
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($files[$key]))
        Assert ($text -ceq $expected[$relative]) "Scan changed file contents: $relative."
    }
    foreach ($item in @(
        @{Key='ancestor:0/.cargo\config.toml'; Text=$project}
        @{Key='ancestor:1/.cargo\config.toml'; Text=$testRoot}
        @{Key='cargo-home:config'; Text='cargo-home-config'}
    )) {
        Assert ($files.Contains($item.Key)) "Scan omitted config $($item.Key)."
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($files[$item.Key]))
        Assert ($text -ceq $item.Text) "Scan changed config $($item.Key)."
    }
    Assert ($files.Contains('cargo-home:config.toml') -and $null -eq $files['cargo-home:config.toml']) 'Missing config was not recorded as absent.'

    $added = Join-Path $project 'child\Cargo.toml'
    [IO.File]::WriteAllText($added, '[package]')
    $afterAdd = Get-CargoFiles $project $cargoHome
    Assert ($afterAdd.Contains('workspace:child\Cargo.toml')) 'Scan missed a newly added manifest.'
    [IO.File]::WriteAllText($added, '[workspace]')
    $afterEdit = Get-CargoFiles $project $cargoHome
    Assert ($afterEdit['workspace:child\Cargo.toml'] -cne $afterAdd['workspace:child\Cargo.toml']) 'Scan missed a manifest content edit.'
    Remove-Item -LiteralPath $added
    $afterDelete = Get-CargoFiles $project $cargoHome
    Assert (-not $afterDelete.Contains('workspace:child\Cargo.toml')) 'Scan retained a removed manifest.'

    # Git worktrees use a .git file instead of a directory.
    Remove-Item -LiteralPath (Join-Path $project '.git') -Recurse
    [IO.File]::WriteAllText((Join-Path $project '.git'), 'gitdir: external')
    $worktreeFiles = Get-CargoFiles $project $cargoHome
    Assert ((ConvertTo-Json -InputObject $files -Compress) -ceq (ConvertTo-Json -InputObject $worktreeFiles -Compress)) 'Git worktree metadata changed the contract.'
    return $expected.Count
}
