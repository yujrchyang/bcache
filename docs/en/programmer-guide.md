# The Programmer's Guide to bcache

## Introduction

The core abstraction in bcache is a key value store ("the btree"). To the btree code the keys it indexes are just large, fixed sized bitstrings/integers, with opaque variable sized values.

Aside from some low level machinery, essentially all metadata is stored as key/value pairs:

- Extents are one type of key where the value is a list of pointers to the actual data.
- Inodes are stored indexed by inode number, where the value is the inode struct.
- Dirents and xattrs are stored with one key per dirent/xattr.

The bulk of the complexity in bcache is in the implementation of the btree; posix filesystem semantics are implemented directly on top of it, with the btree doing all the heavy lifting with respect to e.g. locking and on disk consistency.

In general, bcache eschews heavyweight transactions in favor of ordering filesystem updates. In this, bcachefs's implementation is in spirit not unlike softupdates - however, since bcachefs is working with logical index updates and not physical disk writes, it works out to be drastically simpler. The btree guarantees that ordering is preserved of all index updates, without ever needing flushes - see the section on [sequential consistency](#locking).

We use this approach is used for creating/deleting files and links, and for logical atomicity of appends/truncates. For those unfamiliar with softupdates, this means that when creating files, we create the inode and then create the dirent, and when creating a hardlink we increment i_nlinks and then create the new dirent - and the order is reversed on deletion. On unclean shutdown we might leak inode references - but this is easily handled with a garbage collection pass.

We do have some support for transactional updates, however - primarily for rename().

### Keys (bkey and bpos)

We have separate structs for a search key (`struct bpos`), and the outer container that holds a key and a value (`struct bkey`).

Here are their definitions:

```C++
    struct bpos {
            u64         inode;
            u64         offset;
            u32         snapshot;
    };

    struct bkey {
            u8          u64s;
            u8          format;
            u8          type;

            u8          pad;
            u32         version;
            u32         size;
            struct bpos p;
    };
```

The high bits of the search key are the inode field and the low bits are the snapshot field (note that on little endian the order in the struct will actually be reversed).

Not all code uses all fields of the search key (and snapshot is currently unused), and some code uses the fields in different ways; it's up to the user of the btree code to use the fields however they see fit. However, the inode field generally corresponds to an inode number (of a file in a filesystem), and for extents the offset field corresponds to the offset within that file.

Some notes on the bkey fields:

- The u64s field is the size of the combined key and value, in units of u64s. It's not generally used directly: use `bkey_val_u64s()` or `bkey_val_bytes()` for a higher level interface.
- The format field is internal to the btree implementation. It's for packed bkeys - bkeys are not usually stored in the btree in the in memory. Only very low level btree code need be concerned with this, however.
- The type field denotes the type of the value. For example, the directory entry code defines two different value types, `bch_dirent` (type `BCH_DIRENT`, 128) and `bch_dirent_whiteout` (`BCH_DIRENT_WHITEOUT`, 129).
- The size field is only used by extents (0 for all other keys)

### Values

Values are stored inline with bkeys. Each value type (for all the types that have nonempty values) will have a struct definition, and then macros generate a variety of accessor functions and wrapper types.

Also, while values are _stored_ inline with the keys, due to packing they aren't typically passed around that way; when accessing a key stored in the btree the btree code will unpack the key and return a wrapper type that contains pointers to the unpacked key and the value.

The scheme for the wrapper types is:

```C++
    bkey_i          key with inline value
    bkey_s          key with split value (wrapper with pointers to key and value)
    bkey_s_c        constent key with split value
```

The code has the wrapper types above for generic keys with values, and value types have the corresponding wrapper types generated with pointers to the value of the correct type.

For example, here's the struct definition for extended attributes:

```C++
    struct bch_xattr {
            struct bch_val      v;
            u8                  x_type;
            u8                  x_name_len;
            u16                 x_val_len;
            u8                  x_name[];
    };
```

The wrapper types will be `bkey_i_xattr`, `bkey_s_xattr`, and `bkey_s_c_xattr`. When the xattr code is doing a lookup in the btree, the btree iterator will return (via e.g. `btree_iter_peek()`) a key of type `bkey_s_c`, and then the xattr code will use `bkey_s_c_to_xattr(k)` (after switching on the type field) to get to the xattr itself.

Code should always `switch()` off of or check the bkey type field before converting to their particular type; the accessors all assert that the type field is the expected one, so you'll get a `BUG_ON()` if you don't.

### Btree interface

Keys are indexed in a small number of btrees: one btree for extents, another for inodes, another for dirents, etc.

We can add new btree types for new features without on disk format changes - many planned features will be added this way (e.g. for reed solomon/raid6, we'll be adding another btree to index stripes by physical device and lba. More on this later).

Some important properties/invariants:

- There are no duplicate keys; insertions implicitly overwrite existing keys.
    Related to this, deletion is not exposed as a primitive: instead, deletion is done by inserting a key of type `KEY_TYPE_DELETED`. (The btree code internally handles overwrites by setting the old key to `KEY_TYPE_DELETED`, which will then be deleted when the relevant btree node is compacted. Old deleted keys are never visible outside the btree code).
- Ordering of insertions/updates is _always_ preserved, across unclean shutdowns and without any need for flushes.
    This is important for the filesystem code. Creating a file or a new hardlink requires two operations:
  - create new inode/increment inode refcount
  - create new dirent
    By doing these operations in the correct order we can guarantee that after an unclean shutdown we'll never have dirents pointing to nonexistent inodes - we might leak inode references, but it's straightforward to garbage collect those at runtime.

Lookups/insertions are done via the btree iterator, defined in btree.h:

```C++
    struct btree_iter;

    void bch_btree_iter_init(struct btree_iter *,
                             struct cache_set *,
                             enum btree_id,
                             struct bpos);
    int bch_btree_iter_unlock(struct btree_iter *);

    struct bkey_s_c bch_btree_iter_peek(struct btree_iter *);
    void bch_btree_iter_advance_pos(struct btree_iter *);
```

- A "`cache_set`" corresponds to a single filesystem/volume - the name coming from bcache's starting point as a block cache, and turned into a `cache_set` instead of just a cache when it gained the ability to manage multiple devices.
- The `btree_id` is one of `BTREE_ID_EXTENTS`, `BTREE_ID_INODES`, etc.
- The bpos argument is the position to start iterating from.

`bch_btree_iter_unlock()` unlocks any btree nodes the iterator has locked; if there was an error reading in a btree node it'll be returned here.

`bch_btree_iter_peek()` returns the next key after the iterator's current position.

`bch_btree_iter_advance_pos()` advance's the iterator's position to immediately after the last key returned.

Lookup isn't provided as a primitive because most usage is geared more towards iterating from a given position, but we now have enough to implement it:

```C++
    int lookup(struct bpos search)
    {
            struct btree_iter iter;
            struct bkey_s_c k;
            int ret = 0;

            bch_btree_iter_init(&iter, c, BTREE_ID_EXAMPLE, search);

            k = bch_btree_iter_peek(&iter);
            if (!k.k || bkey_cmp(k.k->p, search)
                    ret = -EEXIST;

            bch_btree_iter_unlock(&iter);
            return ret;
    }
```

If we want to iterate over every key in the btree (or just from a given point), there's the convenience macro `for_each_btree_key()`:

```C++
    struct btree_iter iter;
    struct bkey_s_c k;

    for_each_btree_key(&iter, c, BTREE_ID_EXAMPLE, POS_MIN, k)
            printk("got %llu:%llu\n", k.k->p.inode, k.k->p.offset);

    bch_btree_iter_unlock(&iter);
```

#### Updates

Insertion is most often done with `bch_btree_insert_at()`, which takes an iterator and inserts at the iterator's current position. This is often used in conjunction with `bch_btree_iter_peek_with_holes()`, which returns a key representing every valid position (synthesizing one of `KEY_TYPE_DELETED` if nothing was found).

This is highly useful for the inode and dirent code. For example, to create a new inode, the inode code can search for an empty position and then use `bch_btree_insert_at()` when it finds one, and the btree node's lock will guard against races with other inode creations.

Note that it might not be possible to do the insert without dropping locks, e.g. if a split was required; the `BTREE_INSERT_ATOMIC` flag indicates that the insert shouldn't be done in this case and `bch_btree_insert_at()` will return `-EINTR` instead, and the caller will loop and retry the operation.

The extents code also uses a similar mechanism to implement a cmpxchg like operation which is used by things like copygc that move data around in the background - the index update will only succeed if the original key was present, which guards against races with foreground writes.

#### Linked iterators and multiple atomic updates

These mechanisms are quite new, and the interfaces will likely change and become more refined in the future:

Two or more iterators (up to a small fixed number) can be linked with `bch_btree_iter_link()` - this causes them to share locks, so that if they are used to take locks on the same node that would ordinarily conflict (e.g. holding a read lock on a leaf node with one iterator while updating the same node via another iterator) won't deadlock.

This makes it possible to get a consistent view of multiple positions in the btree (or different btrees) at the same time.

Furthermore, updates via one iterator will not invalidate linked iterators - but be careful, a /pointer/ returned via e.g. `bch_btree_iter_peek()` will still be invalidated by an update (via `bch_btree_insert_at()`). But the other iterator will be kept internally consistent, and it won't have to drop locks or redo any traversals to continue iterating.

Then, updates to multiple (linked) iterators may be performed with `bch_btree_insert_at_multi()`: it takes a list of iterators, and keys to insert at each iterator's position. Either all of the updates will be performed without dropping any locks, or else none of them (the `BTREE_INSERT_ATOMIC` flag is implicit here, as it makes no sense to use `bch_btree_insert_at_multi()` when it's not required). Additionally, the updates will all use the same journal reservation, so the update will be atomic on disk as well.

There are some locking considerations that are not yet hidden/abstracted away yet:

- It is not permissible to hold a read lock on any btree node while taking an intent lock on another. This is because of a deadlock it would cause (an even more obscure version of the one documented in section on [locking](https://bcache.evilpiepirate.org/BcacheGuide/#index8h3) which I will hopefully document in the future).
    This is easy to work around - just traverse the iterator taking intent locks first (with peek(), or `bch_btree_iter_traverse()` directly if more convenient), and if looping unlock the iterator holding read locks before re-traversing the intent lock iterator. Since the iterator code will first attempt to relock nodes (checking the remembered sequence number against the lock's current sequence number), there's no real cost to unlocking the read iterator.
- If linked iterators are only being used to take read locks there are no ordering requirements, since read locks do not conflict with read locks - however, when taking intent locks the iterator pointing to the lower position must be traversed first.
    I haven't yet come up with a satisfactory way of having the iterator code handle this - currently it's up to the code using linked iterators. See `bch_dirent_rename()` for an example.

## Extents, pointers, and data

Bcache is extent based, not block based; its extents are much like extents in other filesystems that has them - a variable sized chunk of data. From the point of view of the index, they aren't positions, they're ranges or half open intervals (note that a 0 size extent doesn't overlap with anything).

Bcache's extents are indexed by inode:offset, and their size is stored in the size field in struct bkey. The offset and size are both in 512 byte sectors (as are the pointer offsets). The offset field denotes the _end_ position of the extent within the file - a key with offset 8 and size 8 points to the data for sectors 0 through 7.

(This oddity was a result of bcache's btree being designed for extents first, and non extent keys coming later - it makes searching for extents within a certain range cleaner when iterating in ascending order).

Inside the value is a list of one or more pointers - if there's more than one pointer, they point to replicated data (or possibly one of the copies is on a faster device and is considered cached).

Here's a simplified version (in the latest version the extent format has gotten considerably more complicated in order to incorporate checksums and compression information, but the concept is still the same):

```C++
    struct bch_extent_ptr {
            __u64                   offset:48,
                                    dev:8,
                                    gen:8;
    };

    struct bch_extent {
            struct bch_val          v;

            struct bch_extent_ptr   ptr[0]
    };
```

- The device field is the index of one of the devices in the cache set (i.e. volume/filesystem).
- The offset field is the offset of the start of the pointed-to data, counting from the start of the device in units of 512 byte sectors.
- "gen" is a generation number that must match the generation number of the bucket the pointer points into for the pointer to be consider valid (not stale).

### Buckets and generations

This mechanism comes from bcache's origins as just a block cache.

The devices bcache manages are divided up into fixed sized buckets (typically anywhere from 128k to 2M). The core of the allocator works in terms of buckets (there's a sector allocator on top, similar to how the slab allocator is built on top of the page allocator in Linux).

When a bucket is allocated, it is written to once sequentially: then, it is never written to again until the entire bucket is reused. When a bucket is reused, its generation number is incremented (and the new generation number persisted before discarding it or writing to it again). If the bucket still contained any cached data, incrementing the generation number is the mechanism that invalidates any still live pointers pointing into that bucket (in programming language terminology, bcache's pointers are weak pointers).

This has a number of implications:

- Invalidating clean cached data is very cheap - there's no cost to keeping a device full of clean cached data.
- We don't persist fine grained allocation information: we only persist the current generation number of each bucket, and at runtime we maintain in memory counts of the number of live dirty and cached sectors in each bucket - these counts are updated on the fly as the index is updated and old extents are overwritten and new ones added.
    This is a performance tradeoff - it's a fairly significant performance win at runtime but it costs us at startup time. Eventually, we'll probably implement a reserve that we can allocate out of at startup so we can do the initial mark and sweep in the background.
    This does mean that at startup we have to walk the extents btree once to repopulate these counts before we can do any allocation.
- If there's a lot of internal fragmentation, we do require copying garbage collection to compact data - rewriting it into new buckets.
- Since the generation number is only 8 bits, we do have to guard against wraparound - this isn't really a performance issue since wraparound requires rewriting the same bucket many times (and incoming writes will be distributed across many buckets). We do occasionally have to walk the extents to update the "oldest known generation number" for every bucket, but the mark and sweep GC code runs concurrently with everything else, except for the allocator if the freelist becomes completely drained before it finishes (the part of GC that updates per bucket sector counts mostly isn't required anymore, it may be removed at some point).

### IO path

XXX: describe what consumes bch_read() and bch_write()

The main entry points to the IO code are

- `bch_read()`
- `bch_read_extent()`
- `bch_write()`

The core read path starts in `bch_read()`, in io.c. The algorithm goes like:

- Iterate over the extents btree (with `for_each_btree_key_with_holes()`), starting from the first sector in the request.
- Check the type of the returned key:
  - Hole? (`KEY_TYPE_DELETED`) - just return zeroes
  - Extent? Check for a pointer we can read from.
    - If they're all stale, it was a cached extent (i.e. we were caching another block device), handle it like a hole.
    - If the relevant device is missing/not online, return an error.
    - Ok, we have a pointer we can read from. If the extent is smaller than the request, split the request (with `bio_split()`), and issue the request to the appropriate device:sector.
    - Iterate until entire request has been handled.

The write path is harder to follow because it's highly asynchronous, but the basic algorithm is fairly simple there too:

- Set up a key that'll represent the data we're going to write (not the pointers yet).
- Allocate some space to write to (with `bch_alloc_sectors()`); add the pointer(s) to the space we allocated to the key we set up previously.
- Were we able to allocate as much space as we wanted? If not, split both the key and the request.
- Issue the write to the space we just allocated
- Loop until we've allocated all the space we want, building up a list of keys to insert.
- Finally, after the data write(s) complete, insert the keys we created into the extents btree.

#### Checksumming/compression

As mentioned previously, bch_extent got more complicated with data checksumming and compression.

For data checksumming, what we want to do is store the checksum with the key and pointers, no the data - if you store the checksum with the data verifying the checksum only tells you that you got the checksum that goes with that data, it doesn't tell you if you got the data you actually wanted - perhaps the write never happened and you're reading old data. There's a number of subtle ways data can be corrupted that naively putting the checksum with the data won't protect against, and there are workarounds for most of them but it's fundamentally not the ideal approach.

So we want to store the checksum with the extent, but now we've got a different problem - partially overwritten extents. When an extent is partially overwritten, we don't have a checksum for the portion that's now live and we can't compute it without reading that data in, which would probably not be ideal.

So we need to remember what the original extent was, so that later when that data is read we can read in the entire original extent, checksum that, and then return only the part that was live.

Compression leads to a similar issue, where if the extent is compressed we won't be able to part of it and decompress it, we have to be able to read the entire extent.

One simplifying factor is that since buckets are reused all at once, as long as any part of the original extent is live the rest of it will still be there - we don't have to complicate our accounting and have two notions of live data to make sure the dead parts of the extent aren't overwritten.

So, for compressed or checksummed extents here's the additional information we'll need to store in struct bch_extent:

```C++
    struct bch_extent_crc32 {
            __u32                   type:1,
                                    offset:7,
                                    compressed_size:8,
                                    uncompressed_size:8,
                                    csum_type:4,
                                    compression_type:4;
            __u32                   csum;
    };
```

Now, when trimming an extent, instead of modifying the pointer offset to point to the start of the new live region (as we still do for non checksummed/compressed extents) we add to the offset field in the extent_crc struct - representing the offset into the extent for the currently live portion. The compressed_size and uncompressed_size fields store the original sizes of the extent, while the size field in the key continues to represent the size of the live portion of the extent.

There's another complicating factor is data migration, from copying garbage collection and tiering - in general, when they need to move some data we can't expect them to rewrite every replica of an extent at once (since copygc is needed for making forward progress, that would lead to nasty deadlocks).

But if we're moving one of the replicas of an extent (or making another copy, as in the case of promoting to a faster tier) we don't want to have to copy the dead portions too - we'd never be able to get rid of the dead portions! Thus, we need to handle extents where different pointers are in different formats.

Having one bch_extent_crc32 field per pointer (or bch_extent_crc64, for the case where the user is using 64 bit checksums) would make our metadata excessively large, unfortunately - if they're doing two or three way replication that would roughly double the size of the extents btree, or triple it for 64 bit checksums.

So the new format struct bch_extent is a list of mixed pointers and extent_crc fields: each extent_crc field corresponds to the pointers that come after it, until the next extent_crc field. See include/uapi/linux/bcache.h for the gory details, and extents.h for the various functions and macros for iterating over and working with extent pointers and crc fields.

#### RAID5/6/Erasure coding

This part hasn't been implemented yet - but here's the rough design for what will hopefully be implemented in the near future:

Background: In conventional RAID, people have long noted the "RAID hole" and wanted to solve it by moving RAID into the filesystem - this what ZFS does.

The hole is that it's impossible for block layer raid to atomically write a stripe: while writing a stripe, there's inevitably going to be a window where the P and Q blocks are inconsistent and recovery is impossible. The best that they can do is order the writes so that the data blocks are written first, then the P/Q blocks after, and then on unclean shutdown rebuild all the P/Q blocks (with perhaps a bitmap to avoid having to resync the whole device, as md does).

The approach that ZFS takes is to fragment incoming writes into (variable sized) stripes, so that it can write out the entire stripe all at once and never have a pointer in its index pointing to an incomplete/inconsistent stripe.

This works, but fragmenting IO is painful for performance. Not only writes are fragmented, but reads of the same data are fragmented too; and since the latency of the read has to be the latency of the slowest fragment, this drives your median latency to your tail latency. Worse, on disks you're spending a lot more seeks than you were before; even on flash it's not ideal because since the fragmenting is happening above all the scheduling, both on the host and the device you're still subject to the tail latency effect.

What we want is to be able to erasure encode unrelated data together - while avoiding update in place. This is problematic to do for foreground writes, but if we restrict ourselves to erasure encoding data in the background - perhaps even as it's being copied from the fast tier (flash) to the slow tier (disk) - the problem is much easier.

The idea is to still replicate foreground writes, but keep track of the buckets that contain replicated data. Then, a background job can take e.g. 5 buckets that contain unrelated data, allocate two new buckets, and then compute the p/q for the original five buckets and write them to the two new buckets. Then, for every extent that points into those first five buckets (either with an index scan, or by remembering keys from recent foreground writes), it'll update each extent dropping their extra replicas and adding pointers to the p/q buckets - with a bit set in each pointer telling the read path that to use those it has to do a reconstruct read (which will entail looking up the stripe mapping in another btree).

This does mean that we can't reuse any of the buckets in the stripe until each of them are empty - but this shouldn't be much trouble, we just have to teach copygc about it when it's considering which buckets to evacuate.

### Copying garbage collection

### Tiering

### Allocation

### Multiple devices

## Btree internals

At a high level, bcache's btree is a copy on write b+ tree. The main difference between bcache's b+ tree and others is the nodes are very large (256k is typical) and log structured. Like other COW b+ trees, updating a node may require recursively rewriting every node up to the root; however, most updates (to both leaf nodes and interior nodes) can be done with only an append, until we've written to the full amount of space we originally reserved for the node.

A single btree node log entry is represented as a header and a list of bkeys, where the bkeys are all contiguous in memory and in sorted order:

```C++
    struct bset {
            /* some fields ommitted */
            ...
            u16                     u64s;
            struct bkey_packed      start[0];
    };
```

Since bkeys are variable length, it's not possible to access keys randomly without other data structures - only iterate sequentially via `bkey_next()`.

A btree node thus contains multiple independent bsets that on lookup all must be searched and iterated over. At any given time there will be zero or more bsets that have been written out, and a single dirty bset that new keys are being inserted into.

As the btree is modified we must maintain the invariant in memory that there are no duplicates (keys that compare as equal), excluding keys marked as deleted. When an insertion overwrites an existing key, we will mark the existing key as deleted (by setting `k->type = KEY_TYPE_DELETED`) - but until the entire node is rewritten the old key will still exist on disk. To handle this, when a btree node is read, the first thing we do is a mergesort of all the bsets it contains, and as part of the mergesort duplicate keys are found and the older bkeys are dropped - carefully matching the same changes we made in memory when doing the insertions.

This hopefully explains how the lack of deletion as a primitive is a result of the way the btree is implemented - it's not possible to delete a key except by inserting a whiteout, which will be dropped when the btree node eventually fills up and is rewritten.

Once a bset has been written out it may also be sorted, in memory, with other bsets that have also been written out - we do so periodically so that a given btree node will have only a few (at most three) bsets in memory: the one being inserted into will be at most 8 or 16k, and the rest roughly forming a geometric progression size, so that sorting the entire node is relatively infrequent.

This resorting/compacting in memory is one of the main ways bcache is able to efficiently use such large btree nodes. The other main trick is to take advantage of the fact that bsets that have been written out are, aside from resorts, constant; we precompute lookup tables that would be too inefficient to use if they had to be modified for insertions. The bcache code refers to these lookup tables as the auxiliary search trees.

### Locking

Bcache doesn't use read/write locks for btree nodes - the locks it uses have three states: shared, intent and exclusive (SIX locks). Shared and exclusive correspond to read and write, while intent is sort of in the middle - intent locks conflict with other intent locks (like write locks), but they don't conflict with read locks.

The problem intent locks solve is that with a regular read/write lock, a read lock can't be upgraded to a write lock - that would lead to deadlock when multiple threads with read locks tried to upgrade. With a complicated enough data structure, updates will need to hold write locks for exclusion with other updates for much longer than the part where they do the actual modification that needs exclusion from readers.

For example, consider the case of a btree split. The update starts at a leaf node, and discovers it has to do a split. But before starting the split it has to acquire a write lock on the parent node, primarily to avoid a deadlock with other splits: it needs at least a read lock on the parent (roughly in order to lock the path to the child node), but it couldn't then upgrade that read lock to a write lock in order to update the parent with the pointers to the new children because that would deadlock with threads splitting sibling leaf nodes.

Intent locks solve this problem. When doing a split it suffices to acquire an intent lock on the parent - write locks are only ever held modifying the in memory btree contents (which is a much shorter duration than the entire split, which requires waiting for the new nodes to be written to disk).

Intent locks with only three states do introduce another deadlock, though:

```C++
    Thread A                        Thread B
    read            | Parent |      intent
    intent          | Child  |      intent
```

Thread B is splitting the child node: it's allocated new nodes and written them out, and now needs to take a write lock on the parent in order to add the pointers to the new nodes (after which it will free the old child).

Thread A just wants to insert into the child node - it has a read lock on the parent node and it's looked up the child node, and now it's waiting on thread B to get an intent lock on the child.

But thread A has blocked thread B from taking its write lock in order to update the parent node, and thread B can't drop its intent lock on the child until after the new nodes are visible and it has freed the child node.

The way this deadlock is handled is by enforcing (in `bch_btree_node_get()`) that we drop read locks on parent nodes _before_ taking intent locks on child nodes - this might cause us to race have the btree node freed out from under us before we lock it, so we check for that after grabbing the intent lock and redo the traversal if necessary.

One other thing worth mentioning is bcache's btree node locks have embedded sequence numbers, which are incremented when taking and releasing write locks (much like seqlocks). This allows us to aggressively drop locks (because we'll usually be able to retake the lock), and we also use it for a `try_upgrade()` - if we discover we need an intent lock (e.g. for a split, or because the caller is inserting into a leaf node they didn't get an intent lock for) we'll usually be able to get it without having to unwind and redo the traversal.

### Journaling

Bcache's journal is foremost an optimization for the btree. COW btrees do not require journals for on disk consistency - but having a journal allows us to coalesce random updates across multiple btree nodes and flush the nodes asynchronously.

The journal is a purely logical log, a list of insertions - bkeys - to reinsert on recovery in the same order they're present in the journal. Provided every index update is journaled (a critical invariant here), redoing those insertions is an idempotant operation. See `bch_journal_replay_key()` in journal.c - the journal uses the same insert path as everything else and doesn't know anything about the structure of the btree.

It's critical that keys appear in the journal in the same order as the insertions happened, so both are done under the btree node's write lock: see `bch_btree_insert_and_journal()` in btree.c, which calls `bch_bset_insert()` at the top (inserting into the btree node in memory) and `bch_journal_add_keys()` to journal the same key at the bottom.

At this point in the btree insertion path, we've already marked any key(s) that we overlapped with (possibly more than one for extents) as deleted - i.e. the btree node is inconsistent so the insertion must happen before dropping our write lock.

So we also have some machinery for journal reservations: we reserve some amount of space in the journal (in units of u64s, as always) midway through the insertion path (in `bch_btree_insert_keys()`). The journal reservation machinery (as well as adding the keys to the journal) is entirely lockless in the fastpath.

### Sequential consistency

As mentioned in the first section on indexing, bcache's b+ tree provides the guarantee that ordering of updates is always preserved - whether to different nodes or different btrees (i.e. dirents vs. inodes).

The journal helps here as well. Ordering is always preserved in the journal itself: if a key at time t made it to the journal and was present after unclean shutdown/recovery, all the keys journalled prior to time t will either be in the journal, or in btree nodes that were flushed to disk.

The btree by itself does not provide ordering though - if updates happened to two different leaf nodes, the leaf nodes could have been flushed in any order - and importantly, either of them could have been written before the last journal entry that contained keys for that btree node write.

That is, while typically the journal write will happen before the btree node is flushed - we don't prevent the btree node from being flushed right away, and we certainly don't want to: since flushing btree nodes is required both to reclaim memory and to reclaim space in the journal, just the mere though of the potential deadlocks is rather horrifying.

Instead, we have a rather neat trick: in struct bset (the common header for a single btree node write/log entry) we track the most recent sequence number of all the journal entries the keys in this bset went into.

Then, on recovery when we're first walking the btree if we find a bset with a higher journal sequence number than the most recent journal entry we actually found - we merely ignore it.

The bset we ignore will likely also contain keys in older journal entries - however, those journal entries will all be in the set we are replaying because they were considered dirty until after the bset was written, and they were marked as dirty on disk until a journal entry was written after the bset's write completed - which didn't happen. Thus, ignoring those bsets cannot cause us to lose anything that won't be replayed.

There is a decent amount of extra machinery required to make this scheme work - when we find bsets newer than the newest journal entry we have to blacklist the journal sequence number they referred to - and we have to mark it as blacklisted, so that on the next recovery we don't think there's a journal entry missing - but that is the central idea.

## Auxiliary search trees

The code for doing lookups, insertions, etc. within a btree node is relatively separated from the btree code itself, in bset.c - there's a struct btree_node_iter separate from struct btree_iter (the btree iterator contains one btree node iterator per level of the btree).

The bulk of the machinery is the auxiliary search trees - the data structures for efficiently searching within a bset.

There are two different data structures and lookup paths. For the bset that's currently being inserted into, we maintain a simple table in an array, with one entry per cacheline of data in the original bset, that tracks the offset of the first key in that cacheline. This is enough to do a binary search (and then a linear search when we're down to a single cacheline), and it's much cheaper to keep up to date.

For the const bsets, we construct a binary search tree in an array (same layout as is used for heaps) where each node corresponds to one cacheline of data in the original bset, and the first key within that cacheline (note that the auxiliary search tree is not full, i.e. not of size (2n) - 1). Walking down the auxilialy search tree thus corresponds roughly to doing a binary search on the original bset - but it has the advantage of much friendlier memory access patterns, since at every iteration the children of the current node are adjacent in memory (and all the grandchildren, and all the great grandchildren) - meaning unlike with a binary search it's possible to prefetch.

Then there are a couple tricks we use to make these nodes as small as possible:

- Because each node in the auxiliary search tree corresponds to precisely one cacheline, we don't have to store a full pointer to the original key - if we can compute given a node's position in the array/tree its index in an inorder traversal, we only have to store the key's offset within that cacheline.
    This is done by `to_inorder()` in bset.c, and it's mostly just shifts and bit operations.
- Observe that as we're doing the lookup and walking down the tree, we have constrained the keys we're going to compare against to lie within a certain range [l, r).
    Then l and r will be equal in some number of their high bits (possibly 0); the keys we'll be comparing against and our search key will all be equal in the same bits - meaning we don't have to compare against, or store, any bits after that position.
    We also don't have to store all the low bits, either - we need to store enough bits to correctly pivot on the key the current node points to (call it m); i.e. we need to store enough bits to tell m apart from the key immeditiately prior to m (call it p). We're not looking for strict equality comparisons here, we're going to follow this up with a linear search anyways.
    So the node in the auxiliary search tree (roughly) needs to store the bits from where l and r first differed to where m and p first differed - and usually that's not going to be very many bits. The full struct bkey has 160 bit keys, but 16 bit keys in the auxiliary search tree will suffice > 99% of the time.
    Lastly, since we'd really like these nodes to be fixed size - we just pick a size and then when we're constructing the auxiliary search tree check if we weren't able to construct a node, and flag it; the lookup code will fall back to comparing against the original key. Provided this happens rarely enough, the performance impact will be negligible.
    The auxiliary search trees were an enormous improvement to bcache's performance when they were introduced - before they were introduced the lookup code was a simple binary search (eons ago when keys were still fixed size). On random lookups with a large btree the auxiliary search trees are easily over an order of magnitude faster.

## Bkey packing

Bkeys have gotten rather large, with 64 bit inodes, 64 bit offsets, a snapshot field that isn't being used yet, a 32 bit size field that's only used by extents... That's a lot of wasted bits.

The packing mechanism was added to address this, and as an added bonus it should allow us to change or add fields to struct bkey (if we ever want to) without incompatible on disk format changes (forwards and backwards!).

The main constraint is lookup performance - any packing scheme that required an unpack for comparisons would probably be right out. So if we want to be able to compare packed keys, the requirement is that it be order preserving. That is, we need to define some function pack(), such that

```C++
    bkey_cmp(l, r) == bkey_cmp(pack(l), pack(r))
```

The way it works is for every btree node we define a packed format (and we recalculate a new packed format when splitting/rewriting nodes); then keys that are packed in the same format may be compared without unpacking them.

The packed format itself consists of, for each field in struct bkey

- the size of that field in the packed key, in bits
- an offset, to be subtracted before packing and when unpacking

Then, provided keys fit into the packed format (their key fields are not less than the field offset, and after subtracting the offset their fields fit into the number of bits in the packed keys) packing is order preserving - i.e. packing is allowed to fail.

Then in the lookup path, we pack the search key into the btree node's packed format - even better, this helps the auxiliary search tree code since it no longer has to deal with long strings of zeroes between the inode and the offset.

For extents, keys in the packed format are usually only 8 bytes - vs. 32 bytes for struct bkey. And with no replication, checksumming or compression, the value is only 8 bytes - so packing can reduce our metadata size by more than half.

The other interesting thing about this mechanism is that it makes our key format self describing - we aren't restricted to just defining a format for packed keys, we can define one for our in memory representation, struct bkey, as well (and we do).

Then as long as we have the format corresponding to a key, we can use it - we should just be careful not to drop fields it has that we don't understand (by converting it to our current in memory representation and back).

All that's left to do is to store formats (besides the btree node-local format) in the superblock. Right now the btree node local format is defined to be format 0 and the in memory format - struct bkey itself - is format 1, `BKEY_FORMAT_CURRENT`. Changing struct bkey would be as simple as defining a new format, and making sure the new format gets added to existing superblocks when it's used.

## Error handling

This section assumes we have no fallback via replication to try (i.e. retry the write to another device) - or we have, and that's failed: we're at the point where we're forced to return errors up the stack.

Error handling of data writes is nothing special - we can return an error for just the particular IO and be done with it.

Error handling for metadata IO is a more interesting topic. Fundamentally, if a metadata write fails (be it journal or btree), we can't fail return errors for some subset of the outstanding operations - we have to stop everything.

This isn't peculiar to bcache - other journaling filesystems have the same behaviour. There's a few reasons; partly it comes down to the fact that by the time we do the actual IO, the index update (dirent creation, inode update) has long completed so we can't return an error and unwind, and we can't realistically backtrack from the contents of a journal write or a btree node write to the in memory state that's now inconsistent.

So we have to consider the entire in memory state of the filesystem inconsistent with what's on disk, and the only thing we can really do is just emergency remount RO.

### Journal IO errors

### Btree IO errors
