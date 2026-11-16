# rustbxl

Build stable Rust workspaces with BuildXL on Windows x64. Capture an offline Cargo
build once, generate separate compiler, linker, build-script, and directive
preparation pips, then replay those pips with a shared local content cache.
Cargo runs during preparation and discovery. Replay executes the generated graph.
The graph is JSON data. The committed BuildXL frontend reads it and creates pips.
Capture and replay do not construct DScript or Rust source text.

The CLI, process adapters, and test fixture are in this repository. No file,
script, binary, or state from another experiment repository is required.
Source files remain in their worktrees. Build outputs and configuration stay in
an external sidecar directory. Existing Cargo `target` directories are preserved.

## Requirements

Use Windows x64, PowerShell 7.4+, .NET 9 SDK, Git for Windows, stable Rust with
`x86_64-pc-windows-msvc`, Visual Studio C++ x64 tools, Windows SDK, a
[BuildXL checkout](https://github.com/microsoft/BuildXL), and
[bindmount](https://github.com/charles-cty/bindmount).
Keep the checkout, workspaces, and sidecar on local NTFS, on the same volume.
The Windows host must support bindmount job silos and permit their creation.
The CLI finds Visual Studio with `vswhere.exe`.

Supply BuildXL and bindmount paths at initialization, or set `BUILDXL_ROOT` and
`BINDMOUNT_EXE`. A bindmount executable on PATH also works. `prepare` downloads
Cargo dependencies from the project's configured registry. The first command
that needs BuildXL downloads the public LKG package selected by its checkout.
Installed Rust, MSVC, the Windows SDK, and the selected BuildXL package determine
the build environment. The capture contract detects changes to Rust/Cargo versions
and the BuildXL package. This repository pins its .NET SDK feature band and test
Cargo lockfile; it does not provision or freeze the whole Windows installation.

## Start

Run these commands from this checkout in PowerShell. Set the four paths for
your machine. Keep `$state` outside `$project` and give rustbxl its own state
directory.

```powershell
$project = Read-Host 'Cargo workspace directory'
$state = Read-Host 'External sidecar directory'
$buildxl = Read-Host 'BuildXL checkout directory'
$bindmount = Read-Host 'bindmount.exe path'

.\scripts\build.ps1
.\rustbxl.ps1 init -Project $project -State $state -BuildXLRoot $buildxl -BindMount $bindmount
.\rustbxl.ps1 prepare -State $state
.\rustbxl.ps1 capture -State $state
```

The workspace must already have `Cargo.lock`. Preparation uses `cargo fetch
--locked` with its own `CARGO_HOME`. It does not generate or update the project's
lockfile. Capture is offline and removes only the selected sidecar instance's
outputs to ensure discovery sees every process.

Start the cache in a second PowerShell terminal and keep it running:

```powershell
.\rustbxl.ps1 cache-start -State $state
```

Build from the first terminal:

```powershell
.\rustbxl.ps1 build -State $state
.\rustbxl.ps1 status -State $state
```

Read the output path from `BUILD_RESULT`, `status`, or
`<state>\instances\main\run\result.json`. Stop the cache after clients exit:

```powershell
.\rustbxl.ps1 cache-stop -State $state
```

`pwsh.exe -File .\rustbxl.ps1 help` lists the complete command interface.
Use explicit script paths when the CLI is called from another directory.

## Configuration and worktrees

`init` writes `<state>\rustbxl.json`. Defaults are stable Rust, workspace build,
the `dev` profile, `x86_64-pc-windows-msvc`, no default features, and no Cargo
incremental compilation. Select packages, features, profile, or a stable Rust
release with `init` options, or edit the external JSON before capture:

```json
"build": {
  "toolchain": "stable",
  "target": "x86_64-pc-windows-msvc",
  "profile": "dev",
  "packages": [],
  "features": [],
  "defaultFeatures": false,
  "rustFlags": [],
  "environment": {}
}
```

`rustFlags` is an array of additional rustc arguments. `environment` contains
explicit build-script environment values. Cargo resolves project configuration
and rustflags during capture; the wrapper then appends path remapping and the
additional arguments. The discovery process has an explicit environment.
Ambient Cargo/Rust overrides are cleared for preparation and metadata commands;
set build options in the sidecar configuration. Cargo configuration files are
part of the capture contract.
The compilation PATH keeps the current PowerShell runtime directory at a fixed
first position so shell nesting does not invalidate capture. Other search paths
retain their order and remain capture inputs.

Run different worktrees concurrently in separate PowerShell processes:

```powershell
.\rustbxl.ps1 build -State $state -Project $worktreeA -Instance branch-a
.\rustbxl.ps1 build -State $state -Project $worktreeB -Instance branch-b
```

Each instance has its own output directory, bindmount silo, engine state, and
logs. Both see common logical source and output paths. The cache service sees
the physical output path through BuildXL's substitution mapping. No source-tree
copy is needed. Give a worktree a stable, distinct instance name. File locks
reject concurrent use of the same instance and block dependency preparation or
capture while compilation clients use the dependency store.

Compatible worktrees can use the default `main` capture despite ordinary source
differences. If manifests or lockfiles diverge, prepare that worktree and select
a named capture:

```powershell
.\rustbxl.ps1 prepare -State $state -Project $worktreeB
.\rustbxl.ps1 capture -State $state -Project $worktreeB -Instance branch-b -Capture branch-b
.\rustbxl.ps1 build -State $state -Project $worktreeB -Instance branch-b -Capture branch-b
```

Manifest, lockfile, toolchain, build options, environment, Cargo configuration, or
BuildXL package changes require capture. Ordinary Rust edits, new modules read
by existing compiler invocations, build-script source edits, observed file
changes, absent-file creation, and directory membership changes invalidate
individual pips without capture. A change that requires a new process or an
unmodeled generated-file producer needs capture or a process adapter. A failed
capture invalidates its contract, so an incomplete graph cannot be replayed.

## Scope

This release supports `cargo build` for Windows x64, workspace-contained path
dependencies, crates.io dependencies, proc macros, and supported Rust build
scripts. Custom Cargo profiles and feature/package selection use configuration.
Unsupported child processes, such as an unmodeled CMake or bindgen invocation,
fail with an adapter error. Cargo `links` metadata also needs an adapter. Tests,
benches, examples, other targets, external path dependencies, and arbitrary
native build systems need extensions. There is no whole-Cargo replay fallback.
Run the project's own tests before using outputs in a release workflow.

BuildXL process caching, sandbox observation, inferred dependencies, graph disk
caching, and local parallel execution are enabled. BuildXL server, incremental
scheduling, and rustc query incremental compilation remain disabled. A cache
miss recompiles the corresponding crate. Small hot builds can be slower than
Cargo because engine startup and graph checks have a cost; this CLI makes no
unmeasured speed claim.

The local CAS has a configurable size quota, default 4096 MiB. Its eviction
policy does not bound instance outputs, capture state, dependency sources, or
logs. Remove stale instances only when their clients have stopped. Do not run
Cargo against rustbxl output directories: cache materialization can use NTFS
hardlinks. No sidecar-wide automatic cleanup policy is implemented.

## Verify from a fresh checkout

```powershell
.\tests\Integration.ps1 -BuildXLRoot $buildxl -BindMount $bindmount
```

The integration test builds the helper, prepares its own dependency store,
downloads its own BuildXL package, and creates six Git worktrees from the
committed fixture. It compares replay outputs with clean offline Cargo builds
in the same namespace. Cases cover shell nesting, shared hits, partial rebuilds,
newly read modules, dynamic inputs, restoration hits, concurrent isolation, feature
recapture, preserved project targets, and unchanged dependency sources.
Argument arrays also pass through the actual JSON frontend and BuildXL process
execution. The Win32 argument check uses 505 asymmetric and randomized cases.

Evidence is written to `.test\integration`. Use `-RunRoot` with an empty
directory for another run. The test stops its cache service in `finally`.
See [implementation notes](docs/implementation.md) for the graph and boundaries.
See [validation notes](docs/validation.md) for verified results and resolved issues.
