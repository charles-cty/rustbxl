# Four-worktree experiment evidence

`summary.json` contains the audited final measurements and execution records.
Per-project directories retain the storage inputs and NTFS hardlink evidence.
`shared-source-v3.patch` is experimental review material; it was not applied to
the original checkout. The updated generator passed `integration-results.json`.
Large runs used stable helper binaries and the graph transformations in the
retained experiment.

The script copies require the original layout at
`F:\Temp\rustbxl-large-20261116`, including its `driver-shared` checkout and
temporary `Edit-Probe.ps1`. Run them from that retained layout. The source-editing
probe remains outside this codebase. A fresh warm comparison needs a new marker
prefix and result filename to force compiler cache misses.

The previous compression trial is retained only in the external experiment.
This evidence measures uncompressed BuildXL shared CAS and four worktrees per
project. See [the report](../large-worktree-experiment.md) for scope and limits.
