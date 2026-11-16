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
share its local content and memoization stores. BuildXL server and incremental
scheduling remain disabled. No sidecar-wide output or log lifetime policy has
been added.
