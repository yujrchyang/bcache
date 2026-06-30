## Kernel Module Build

- Build: `make` (out-of-tree module against `/lib/modules/$(uname -r)/build`)
- Clean: `make clean`
- Generate `compile_commands.json` for clangd: `make clangd` (runs `make compile_commands.json` first)
- Output: `src/bcache.ko`
- Module object list: `src/Makefile` (`obj-m := bcache.o`)

## Language Server

- `.clangd` strips `-mabi=lp64` from kernel compile flags

## What This Is

This is **classic bcache** (Linux `drivers/md/bcache`), standalone-built. It is **not** bcachefs. Ignore `docs/programmer-guide-en.md` — it describes bcachefs concepts (SIX locks, `bkey` packing, `KEY_TYPE_DELETED`, linked iterators, `bpos`) that do **not** exist in this codebase. The authoritative design doc is `docs/overview.md`.

Concretely, things that differ from bcachefs docs:
- Btree nodes use `struct rw_semaphore lock` (`btree.h:125`) and a `struct mutex write_lock` for bset writes — no SIX/intent locks
- `struct bkey` is a fixed `{high, low, ptr[]}` 64-bit-packed struct (uapi `linux/bcache.h`), not `bkey_packed`/`bpos`
- Deletion is not "insert KEY_TYPE_DELETED"; cache-miss slot reservation uses a sentinel key with `PTR_CHECK_DEV` via `bch_btree_insert_check_key` (`btree.c:2399`)
- No linked iterators; multi-btree ops use `struct btree_op` passed through `bch_btree_map_leaf_nodes`

## Closure Async System

Closures (`closure.c`/`closure.h`) are the primary async primitive, not `completion`/workqueue. Read `closure.h` header comment before touching async code.

- A running closure holds one self-reference (`remaining = 1 | CLOSURE_RUNNING`)
- **`continue_at()` / `continue_at_nobarrier()` / `closure_return()` MUST be followed by an immediate `return`** — the caller no longer holds a reference and the closure memory may be freed before the next statement (`closure.h:36-38`)
- `closure_sync()` for synchronous wait; `continue_at(cl, fn, wq)` for async continuation
- Parent chain: `closure_init(cl, parent)` takes a parent ref; `closure_return` returns it. Refcount propagates up the tree
- In-flight bios bracket the closure: `closure_bio_submit` does `closure_get(cl)` + `submit_bio_noacct`; the endio does `closure_put(cl)`

## Btree

- Log-structured COW b+tree. Nodes are large (~bucket-sized, 128K–2M); each node holds up to `MAX_BSETS=4` appended bsets sharing one `seq` (`bset.h`)
- Written bsets are immutable; inserts go into the last unwritten bset. `bch_btree_sort_lazy` merges sets lazily
- Lookup: `bcache_btree_root()` macro (`btree.h:328-367`) loops with `-EINTR` retry; node search uses an auxiliary `bkey_float` binary tree for written sets and a flat cacheline table for the unwritten set (`bset.c`)
- Node writes are double-buffered (`writes[2]`, `btree.h:144`); old bsets are never modified in place
- `b->seq` (`btree.h:124`) increments on write-lock changes and is used for cache-miss race detection, not seqlock-style lock dropping
- Split (`btree.c:2209`) is synchronous; **parent updates are not journaled** (written synchronously). `make_btree_freeing_key` increments bucket gen to invalidate old nodes
- Btree cache cannibalize (`btree.c:860`) takes a global `btree_cache_alloc_lock` — only one thread reclaims LRU nodes at a time

## Key / Extent Semantics

- `bkey` fields are bitfield accessors on `high`/`low` (uapi `linux/bcache.h`): `KEY_INODE`, `KEY_SIZE`, `KEY_OFFSET`, `KEY_PTRS`, `KEY_DIRTY`
- **`KEY_OFFSET` is the END position, not the start.** Extents are half-open intervals `[KEY_START, KEY_OFFSET)`; `KEY_START(k) = KEY_OFFSET(k) - KEY_SIZE(k)` (uapi `bcache.h:83`). Getting this backwards breaks every lookup
- Pointers carry `gen` that must match the target bucket's generation or the pointer is stale

## Bucket Allocation & Generations

- Buckets are the COW unit: allocated once, written sequentially, never written in-place. Reuse increments the 8-bit generation number, which invalidates stale pointers without seeks
- `struct bucket` (`bcache.h:197`): `gen` (8-bit), `last_gc`, `prio` (16-bit LRU), `pin`, `gc_mark`
- Wraparound guard: `BUCKET_GC_GEN_MAX = 96` (`bcache.h:915`); `can_inc_bucket_gen` refuses invalidation past it and sets `invalidate_needs_gc` to force GC
- Reserve tiers (`alloc.c`): `RESERVE_BTREE` / `RESERVE_PRIO` / `RESERVE_MOVINGGC` / `RESERVE_NONE` — prevent key subsystems from starving on free buckets
- `free_inc` holds newly-invalidated buckets whose gen is not yet persisted; `bch_prio_write` flushes (prio,gen) to disk before they move to `free[]`
- **At startup, `run_cache_set` must walk the extents btree (`bch_btree_check`) to rebuild per-bucket sector counts before any allocation can happen**
- Allocator thread (`alloc.c:317`) holds `bucket_lock`; GC sets `gc_mark_valid=0` and the allocator blocks until GC finishes (`alloc.c:355`)

## Journal

- **Pure performance optimization, not a consistency mechanism** (`bcache.h:152-177`). Coalesces random leaf updates so they flush asynchronously instead of forcing near-empty btree writes
- Only **leaf** btree updates are journaled; parent/split updates are synchronous writes
- Pin system: each open journal entry has an `atomic_t` in a FIFO (`JOURNAL_PIN=20000`). A journal entry is reclaimable only after all btree writes holding its pin complete (`btree_complete_write`, `btree.c:288`)
- `btree_flush_write` (`journal.c:417`): when the journal fills, it force-flushes up to `BTREE_FLUSH_NR=8` oldest dirty btree nodes to release pins
- Recovery replays bkeys in `seq` order via the normal insert path (`bch_journal_replay`, idempotent)

## Writeback / GC

- Writeback maintains LBA ordering: reads may complete out of order, but writes are dispatched in sequence via `dc->writeback_ordering_wait` (`writeback.c:395-442`)
- `should_writeback` (`writeback.h:102`): `in_use > cutoff_sync (70%)` → bypass all; `> cutoff (40%)` → only sync/meta/prio writeback; else cache all
- Three GC layers coordinate via `gc_mark_valid` / `GC_MARK_DIRTY` / `pin`: regular GC rebuilds bucket state, moving GC compacts partially-full buckets, writeback flushes dirty data. Writeback buckets are marked DIRTY in `bch_btree_gc_finish` so the allocator won't reclaim them

## Code Organization

All source in `src/`. Entry points:
- `super.c:bcache_init` — module load; `super.c:register_bcache` — device registration via `/sys/fs/bcache/register`
- `request.c:cached_dev_submit_bio` / `flash_dev_submit_bio` — IO entry (gendisk `submit_bio`)
- `request.c` — IO state machine (`struct search` closure), read/write/cache-miss paths
- `btree.c` / `bset.c` — btree ops, GC, node read/write, split, iterators
- `closure.c` / `closure.h` — async framework
- `alloc.c` — bucket allocator, invalidation, LRU priorities
- `journal.c` — journal write/replay/reclaim
- `writeback.c` — writeback thread + PI rate controller
- `movinggc.c` — moving GC
- `extents.c` — extent insert_fixup (trim/split overlapping extents)
- `sysfs.c` — full runtime tunable surface
- `bcache.h` — architecture comment + all core struct definitions; read first
- On-disk format (uapi): `linux/bcache.h` — `cache_sb`, `bkey`, `bset`, `jset`

## Reference

- `docs/overview.md` — comprehensive architecture analysis with line-number citations (Chinese). Trust this over any bcachefs-flavored doc
- `src/bcache.h` header comment — design rationale
- `src/closure.h` header comment — closure usage rules
