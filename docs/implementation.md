# Process graph and BuildXL frontend

The capture adapter records process invocations and BuildXL file accesses.
`GraphGenerator` assigns generated files to their producer, separates compiler
and linker execution, and orders the process nodes by those dependencies.
It serializes `ProcessGraph` records to `replay/graph.json` with
`System.Text.Json`. The graph contains no executable source text.

The committed `frontend/config.dsc`, `module.config.dsc`, and `graph.dsc` are
fixed source files. BuildXL reads their runtime paths from tracked environment
variables. `Sdk.Json.read` parses the process graph. The frontend converts its
records to `Transformer.execute` and `Transformer.copyFile` calls. It resolves
references to producer directories, asserted output files, captured stdout,
and copied executable aliases. Discovery uses the same frontend with one
uncacheable capture node. Replay contains the individual process nodes.

Arguments remain arrays of complete strings through capture, JSON storage, and
frontend evaluation. Each argument reaches `Cmd.argument` once. BuildXL applies
Windows argument escaping. Environment entries retain their names and values;
tool search paths use path arrays. Logical roots are equal across instances in
one state directory. Embedded logical paths in argument strings therefore stay
equal too. State-directory relocation requires a new capture.

BuildXL also has `PipGraphFragmentBuilder` and `PipGraphFragmentSerializer` for
direct binary graph construction. They require references to BuildXL engine
assemblies and matching serialization APIs. The fixed DScript adapter uses the
SDK packaged with the selected BuildXL engine and keeps this CLI's helper free
of engine assembly dependencies.

## Correctness checks

The high-risk boundaries are argument escaping, producer references, dynamic
inputs, and namespace/cache translation. A value can contain spaces, Unicode,
quotes, trailing backslashes, or DScript-looking text. It must stay data and
reach the process unchanged. Argument tests run structured samples through the
actual BuildXL frontend and compare the received argument arrays. A separate
505-case test checks the Win32 quote/parser round trip.

The integration test compares outputs with clean offline Cargo builds. Its
oracle uses a committed PowerShell script and a JSON request. Static fixture
variants provide source edits and newly added modules. Test code copies those
files; it does not construct or replace source text. The fixture's build script
copies a committed Rust include file, and its proc macro parses a committed
token expansion.

The test checks both sides of invalidation boundaries: an observed input edit
must execute affected pips; source restoration must reuse cached pips. New
files, directory members, and newly read module files must work without capture.
A feature change must reject the old capture and work after a new capture.
Equal worktrees must share all process pips; concurrent source variants must
produce their own expected outputs. The original Cargo target sentinel and
dependency-source timestamps must remain unchanged.

## Storage and process lifetime

Each instance has a physical output tree mapped to the common logical target.
BuildXL's substitution mapping translates cache placements to that physical
tree. A separate directory translation maps physical source paths to the common
logical source path. The graph includes declared generated-file dependencies;
BuildXL observes source reads, absent probes, and directory enumeration at run
time. Arbitrary dependency-store writes are not declared compilation outputs.

The CLI uses operating-system file handles for dependency, capture, and instance
locks. The cache service runs in a separate terminal. Concurrent BuildXL engines
share its local content and memoization stores. BuildXL server mode remains
disabled. Replay enables incremental scheduling with per-instance engine state.
Discovery disables
incremental scheduling. The dependency graph and its declared inputs are unchanged
by this scheduling policy. No sidecar-wide output or log lifetime policy has been
added.

The capture contract enumerates source directories through .NET filesystem APIs.
It includes hidden Cargo/toolchain files and retains the existing exclusions for
`.git`, `target`, and directory reparse points. Each replay still checks file
contents and ancestor/Cargo-home configuration, including previously absent files.

## Optional artifact compression

`compress` is an explicit maintenance operation. It takes the exclusive
`maintenance.lock`; normal CLI clients and the foreground cache service hold
shared handles. It also takes the dependency lock and reserves the cache TCP
endpoint to detect clients or services from an older driver. It requires the cache
and compilation clients to exit before either preview or apply.

The helper inventories instance files and the configured cache's
`Shared/<hash-type>/<prefix>/*.blob` content. It groups names by NTFS volume serial
number and file ID. Protection on any alias wins over eligibility on another.
The recorded hardlink count must equal the number of names inventoried; an alias
outside those roots therefore prevents compression. Directory reparse points are
not traversed. An instance is active unless the caller supplies an explicit active
list. Last-write age filters candidates, while active-instance identity protects
old libraries that are still frequently read. Last-access time is not a reliable
activity signal and is not used.

Apply opens each file exclusively, rechecks identity, hardlink count, length, and
last-write time, and calls `FSCTL_SET_COMPRESSION` with native LZNT1 compression.
It keeps the file and every hardlink in place. `FileStandardInfo.AllocationSize`
measures allocation once per identity, including partial-cluster allocation on
uncompressed files. BuildXL CAS content can deny Everyone
`WriteData | AppendData`. For that exact explicit deny rule, the helper holds a
security-only handle that prevents file replacement, saves the DACL, removes the
rule, opens the exclusive data handle, and restores the original DACL through the
security handle before compression. A failed data open also restores the DACL.
Other deny rules are retained. Preview never changes compression or permissions.
DACL restoration uses `finally`; forced process termination during the short
permission transition can bypass that restoration. Let maintenance exit normally.

Compression changes physical allocation. The cache still manages its existing
logical content quota and eviction policy. Engine state, RocksDB metadata,
incremental state, and dependency sources stay outside the eligible scope.
