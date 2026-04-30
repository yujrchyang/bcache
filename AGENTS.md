## Kernel Module Build

- Build: `make` (compiles against running kernel's build dir at /lib/modules/$(uname -r)/build)
- Clean: `make clean`
- Generate compile_commands.json: `make compile_commands.json` then `make clangd`
- Output: bcache.ko module in src/ directory

## Language Server

- clangd configured in .clangd to remove -mabi=lp64 flag

## Critical Architecture Patterns

### Closure Async System

- Closures are the primary async primitive for tracking in-flight operations
- Always `return` immediately after `continue_at()` macro calls
- `closure_sync()` for synchronous waits, `continue_at()` for async continuation
- Read closure.h for patterns - this differs from standard kernel async mechanisms

### Btree Iterators and Locking

- Btree uses SIX locks (shared/intent/exclusive), not standard rw locks
- Key iterator rule: drop read locks on parent nodes before taking intent locks on child nodes
- Linked iterators via `bch_btree_iter_link()` for atomic multi-btree updates
- Offset field in bpos represents end position, not start (extents are half-open intervals)
- Deletion is insertion of KEY_TYPE_DELETED - no explicit delete primitive
- Iterator locks have embedded sequence numbers for aggressive lock dropping

### Code Organization

- All source in src/ directory
- Main header: bcache.h (contains architecture documentation)
- Core subsystems:
  - btree.c/btree.h: btree operations and iterators
  - closure.c/closure.h: async operation tracking
  - alloc.c: bucket allocation
  - extents.c/extents.h: extent management
  - io.c: IO path
  - journal.c: journaling
  - sysfs.c: runtime configuration via sysfs
- Programmer documentation: docs/programmer-guide.md

## Bucket Allocation System

- Buckets are COW units (128K-2M typical), allocated once, never written in-place
- Generation numbers invalidate pointers without expensive seeks
- 8-bit generation prevents stale pointer issues
- At startup, must walk extents btree to rebuild sector counts before allocation
