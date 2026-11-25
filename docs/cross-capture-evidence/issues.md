# Cross-capture fingerprint implementation issues

The first run under `F:\Temp\rbc1116a` passed the identical-capture check:
26 process cache hits and zero executions. Its added-dependency check failed
because no build-script runner had an identical serialized graph definition.
Adding the package inserted a copy task before existing aliases. Their sequential
`alias0`, `alias1`, and later identifiers shifted, changing producer references
even when paths and execution plans were equal. Copy-task identifiers now derive
from their destination paths. Executable publication tasks use the same rule.

Independent graph inspection also found that the target `engine` and
`probe_support` compilations gained dependencies on the added package. The
compiler observed extra files in Cargo's common dependency directory. The test
now requires unchanged host library and script definitions, and compares their
actual BuildXL weak fingerprints and cache hits. It also checks a changed
metadata consumer plan. All observed dependency edges remain in the graph.

The second run under `F:\Temp\rbc1116b` reused 20 process tasks after adding the
dependency and executed 11. Its negative-boundary assertion expected a changed
metadata consumer to keep its old task ID. Cargo changed that consumer's
`OUT_DIR` identity when a new `links` provider was added. The check now locates
the consumer by package, verifies the added metadata input and changed plan path,
and requires execution rather than an old cache hit. The production plan was
already correct; the assertion was too specific.

One patch included stale documentation context and was rejected before applying.
The next patch used the current scoped context.

No compiler failure, process-tree termination, dependency installation, proxy
change, or instruction exception occurred during this implementation. Failed
test state is retained for diagnosis. Tests run with native Windows tools and
Windows-local paths.

The original tool session was unavailable when review resumed. The retained
`results.json` contains all 30 passing cases, and the cache service log records
its normal shutdown. The Windows event log query covers the test window.
