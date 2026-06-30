# bcache 内核模块代码仓库综合分析

> 仓库地址：`/home/yujrchyang/opensrc/bcache`（Linux 内核 `drivers/md/bcache` 的独立构建版）
> 规模：约 18,500 行 C 代码，分布在 `src/` 下 21 个 `.c` 文件和 12 个 `.h` 文件
> 模块输出：`bcache.ko`（块设备缓存层，支持 writeback / writethrough / writearound / passthrough）

---

## 一、整体架构

bcache 是一个 **Linux 块设备缓存层**，位于内核块层（block layer）与底层存储设备之间。它把高速 SSD 作为缓存设备（cache device），为慢速后端设备（backing device）提供透明加速。核心抽象：

```
┌──────────────────────────────────────────────────────────┐
│  应用 / 文件系统                                          │
│         │ bio                                            │
│         ▼                                                │
│  ┌──────────────────┐    gendisk->submit_bio             │
│  │ bcache 块设备    │  (bcache_cached_ops/flash_ops)     │
│  │ (bcache_device)  │                                    │
│  └────────┬─────────┘                                    │
│           │ struct search (closure 状态机)                │
│           ▼                                               │
│  ┌──────────────────┐  ┌──────────────────┐              │
│  │ Btree 索引       │  │ Journal (批量     │              │
│  │ (key→ptr 映射)   │  │  叶子更新)        │              │
│  └────────┬─────────┘  └────────┬─────────┘              │
│           │                      │                        │
│           ▼                      ▼                        │
│  ┌──────────────────────────────────────────┐            │
│  │ Bucket 分配器 (alloc.c)                   │            │
│  │  + GC (btree.c) + Moving GC (movinggc.c) │            │
│  │  + Writeback (writeback.c)               │            │
│  └──────────────────────────────────────────┘            │
│           │                                                │
│           ▼                                                │
│  ┌──────────────┐      ┌──────────────┐                  │
│  │ Cache 设备   │      │ Backing 设备 │                  │
│  │ (SSD, ca)    │      │ (HDD, dc)    │                  │
│  └──────────────┘      └──────────────┘                  │
└──────────────────────────────────────────────────────────┘
```

### 核心数据对象关系

| 对象 | 字段位置 | 角色 |
|------|---------|------|
| `struct cache_set` | `bcache.h:511` | 缓存集合，包含 btree root、journal、分配器状态；管理多个 cache 和 backing device |
| `struct cache` | `bcache.h:411` | 单个缓存设备（SSD），持有 buckets、FIFO、prio 数据 |
| `struct cached_dev` | `bcache.h:299` | 后端设备（HDD），嵌入 `bcache_device`，含 writeback 状态 |
| `struct bcache_device` | `bcache.h:249` | 抽象块设备前端，持有 gendisk、closure、bio_split |
| `struct btree` | `btree.h:117` | Btree 节点（内存），含 rw_semaphore、bset 集合、double-buffered writes |
| `struct bucket` | `bcache.h:197` | 单个 bucket 描述符：gen/prio/gc_mark/pin |
| `struct closure` | `closure.h:143` | 异步原语：refcount + continuation + parent 链 |

关系链：`cache_set` ↔ `cache`（`c->cache`/`ca->set`）；`cache_set` ↔ `bcache_device`（`c->devices[id]`/`d->c`）；`cached_dev` 嵌入 `bcache_device`（`dc->disk`）。

```
                       bch_cache_sets (全局链表, super.c:46)
                              │
                         ┌────▼─────┐
                         │ cache_set │  bch_cache_set_ktype (sysfs.c:983)
                         │   (c)     │  release = bch_cache_set_release (super.c:1671)
                         └────┬──────┘
            ┌─────────────────┼──────────────────┬──────────────┐
            │                  │                  │              │
       ┌────▼─────┐      ┌────▼─────┐      ┌────▼────┐    ┌────▼─────┐
       │  cache   │      │ caching   │      │ devices[]│    │ cached_  │
       │  (ca)    │      │ closure+  │      │  [id]    │    │ devs list│
       │ c->cache │      │ attached_ │      └────┬─────┘    └────┬─────┘
       └────┬─────┘      │ dev_nr    │           │               │
            │            └───────────┘      ┌────▼─────┐   ┌─────▼──────┐
       ┌────▼─────┐                         │bcache_   │   │ cached_dev │
       │ cache_sb │                         │device   │◀──┤   (dc)     │
       │ buckets[]│                         │ (d)      │   │  bch_cached│
       │ FIFOs    │                         │ disk.cl  │   │  _dev_ktype│
       │ prio     │                         │ gendisk  │   └─────┬──────┘
       └──────────┘                         └────┬─────┘         │
                                                │ id=c->uuids[id]│
                                           bcache_cached_ops     │ bdev
                                           或 bcache_flash_ops   │ cache_sb
                                                                  │ sb_disk
```

---

## 二、入口点

### 1. 模块加载 `bcache_init()` — `super.c:2867-2930`

按序初始化：

| 步骤 | 位置 | 设施 |
|------|------|------|
| `check_module_parameters()` | `super.c:2876` (def `2842-2865`) | 校验 `bch_cutoff_writeback[_sync]` |
| `mutex_init(&bch_register_lock)` | `super.c:2878` | 全局注册锁 |
| `register_reboot_notifier(&reboot)` | `super.c:2880` | reboot 通知（优先级 `INT_MAX`） |
| `register_blkdev(0, "bcache")` | `super.c:2882` | 动态主设备号 → `bcache_major` |
| `bch_btree_init()` | `super.c:2889` → `btree.c:2795` | `bch_btree_io` workqueue（`WQ_MEM_RECLAIM`） |
| `alloc_workqueue("bcache", WQ_MEM_RECLAIM, 0)` | `super.c:2892` | `bcache_wq` — 主延迟工作 |
| `alloc_workqueue("bch_flush", 0, 0)` | `super.c:2905` | `bch_flush_wq` — 故意不加 `WQ_MEM_RECLAIM`（避免 stall） |
| `alloc_workqueue("bch_journal", WQ_MEM_RECLAIM, 0)` | `super.c:2909` | `bch_journal_wq` |
| `kobject_create_and_add("bcache", fs_kobj)` | `super.c:2913` | `bcache_kobj` — 创建 `/sys/fs/bcache/` |
| `bch_request_init()` | `super.c:2917` → `request.c:1343` | `KMEM_CACHE(search, 0)` slab |
| `sysfs_create_files(bcache_kobj, files)` | `super.c:2918` | 注册 `register`/`register_quiet`/`pendings_cleanup` |
| `bch_debug_init()` | `super.c:2921` → `debug.c:254` | `debugfs_create_dir("bcache", NULL)` |

### 2. 设备注册入口 — `register_bcache()` — `super.c:2538-2670`

用户通过 `echo <dev> > /sys/fs/bcache/register` 触发：

```
register_bcache()                          super.c:2538
  ├─ try_module_get(THIS_MODULE)          super.c:2555
  ├─ blkdev_get_by_path(FMODE_EXCL)      super.c:2576
  ├─ read_super(sb, bdev, &sb_disk)       super.c:2600   (def 167)
  │     ├─ read_cache_page_gfp(SB_OFFSET) super.c:175
  │     ├─ 校验 magic/csum/uuid/geometry  super.c:200-214
  │     └─ 按版本分派 (CDEV/BDEV/_FEATURES)
  │
  ├─ if SB_IS_BDEV (v1/4/6):              super.c:2626
  │     register_bdev()                   super.c:1458
  │       ├─ cached_dev_init()            super.c:1406   (分配 gendisk, closure, kobj)
  │       ├─ list_add(&uncached_devices)  super.c:1483
  │       └─ bch_cached_dev_attach()      super.c:1485   (匹配 set_uuid)
  │
  └─ else (CDEV v0/3/5):                  super.c:2638
        register_cache()                  super.c:2354
          ├─ cache_alloc()                super.c:2241   (分配 buckets/FIFO/heap)
          └─ register_cache_set()         super.c:2159
              ├─ bch_cache_set_alloc()    super.c:1868   (构造 cache_set)
              └─ run_cache_set()         super.c:1983
                    ├─ bch_journal_read/replay   super.c:2002,2076
                    ├─ bch_btree_check()         super.c:2044
                    ├─ bcache_write_super()      super.c:2132
                    └─ set_bit(CACHE_SET_RUNNING) super.c:2143
```

**超级块 on-disk 格式** — `struct cache_sb_disk`（uapi `linux/bcache.h:162-217`）：

```c
struct cache_sb_disk {
    __le64  csum;            /* CRC64 */
    __le64  offset;          /* SB_SECTOR = 8 */
    __le64  version;         /* BCACHE_SB_VERSION_* */
    __u8    magic[16];       /* bcache_magic */
    __u8    uuid[16];        /* 设备 UUID */
    __u8    set_uuid[16];    /* 缓存集 UUID */
    __u8    label[SB_LABEL_SIZE];
    __le64  flags;
    __le64  seq;             /* 每次写入递增 */
    __le64  feature_compat/ro_compat/incompat;
    union {
        struct { /* cache 设备 */
            __le64 nbuckets;
            __le16  block_size, bucket_size;
            __le16  nr_in_set, nr_this_dev;
        };
        struct { /* backing 设备 */
            __le64  data_offset;  /* 默认 16 sector */
        };
    };
    __le32  last_mount;
    __le16  first_bucket;
    __le16  njournal_buckets / keys;
    __le64  d[SB_JOURNAL_BUCKETS];  /* 256 个 journal bucket */
};
```

### 3. IO 入口（gendisk `submit_bio` 回调）

- **后端设备读/写**：`cached_dev_submit_bio` — `request.c:1172`
- **Flash-only 卷读/写**：`flash_dev_submit_bio` — `request.c:1282`

两者都从 `c->search` mempool 分配 `struct search`（`request.c:716`），构造 closure 状态机后异步处理。

```c
static const struct block_device_operations bcache_cached_ops = {
    .submit_bio = cached_dev_submit_bio,   /* request.c:1172 */
    .open       = open_dev,
    .release    = release_dev,
    .ioctl      = ioctl_dev,
    .owner      = THIS_MODULE,
};
```

---

## 三、关键代码流追踪

### A. 读取路径（缓存命中）

```
cached_dev_submit_bio()              request.c:1172
  ├─ check_should_bypass()           request.c:1221 → 363  (顺序 IO / 拥塞检测)
  ├─ search_alloc()                  request.c:716        (mempool, closure_init)
  └─ cached_dev_read()               request.c:950
       └─ closure_call(&s->iop.cl, cache_lookup, NULL, cl)  request.c:954
            cache_lookup()           request.c:578
              └─ bch_btree_map_keys() request.c:587 → btree.c:2581
                   └─ cache_lookup_fn() request.c:513
                        ├─ [miss 前段] s->d->cache_miss()  request.c:530
                        ├─ bio_next_split()                 request.c:550
                        ├─ bch_bkey_copy_single_ptr()       request.c:555
                        └─ __bch_submit_bbio()              request.c:574 → io.c:34
                             └─ closure_bio_submit()        bcache.h:931
            closure_return()         request.c:616
       └─ continue_at(cl, cached_dev_read_done_bh)          request.c:955
            └─ bch_mark_cache_accounting()                  request.c:867
            └─ cached_dev_bio_complete() → search_free()    request.c:753 → 702
```

**关键点**：`bkey` 的 offset 表示 **extent 结束位置**（半开区间 `[START, OFFSET)`，uapi `bcache.h:83`），这让查找时无需额外计算 end。

### B. 缓存未命中（数据流：backing → cache）

`cached_dev_cache_miss()` — `request.c:879-948` 是最复杂路径：

1. `bch_btree_insert_check_key()`（`btree.c:2399`）插入哨兵 key（`PTR_CHECK_DEV`）锁定槽位
2. 分配 `cache_bio`，从 backing 设备读取数据
3. `bio_copy_data(cache_miss, iop.bio)` 把数据复制回原始 bio（`request.c:841`）
4. `closure_call(&s->iop.cl, bch_data_insert, NULL, cl)` 把数据写入缓存（`request.c:856`）

完整流程：

```
cache_lookup_fn                  request.c:513
  s->d->cache_miss (= cached_dev_cache_miss)  request.c:530 → 879
    bch_btree_insert_check_key    request.c:904 → btree.c:2399   (插入哨兵)
    bio_next_split                request.c:910
    bio_alloc_bioset (cache_bio)  request.c:916
    bch_bio_alloc_pages           request.c:930
    closure_bio_submit(cache_bio) request.c:937 → backing 设备 READ
    return -EINTR                 request.c:914   (重启 btree 遍历)
  [btree 遍历重启, 完成; cache_bio 经 backing_request_endio 完成]
closure_return (iop.cl)           request.c:616
cached_dev_read_done_bh           request.c:862   (hit=false)
  cached_dev_read_done            request.c:820
    bio_copy_data(cache_miss, iop.bio)   request.c:841   (backing→orig 复制)
    bio_complete(s)               request.c:851   (orig_bio 完成!)
    closure_call(iop.cl, bch_data_insert)   request.c:856
      bch_data_insert             request.c:308 → bch_data_insert_start 187
        bch_alloc_sectors         request.c:222 → alloc.c:606
        bch_submit_bbio           request.c:248 → io.c:45   (写缓存)
        bch_data_insert_keys      request.c:252 → 58
          bch_journal             request.c:66 → journal.c:929
          bch_btree_insert        request.c:69 → btree.c:2457
          closure_return          request.c:87
    cached_dev_cache_miss_done    request.c:805 → closure_put(d->cl)
  cached_dev_bio_complete         request.c:817 → search_free
```

### C. 写入路径（三种模式）

| 模式 | 触发条件 | 数据流向 |
|------|---------|---------|
| **Bypass** | `check_should_bypass` 返回 true，或 DISCARD | 直接写 backing + 失效缓存区段（`bch_data_invalidate`）|
| **Writethrough** | `should_writeback` 返回 false | 克隆 bio：一份写 backing，一份写 cache（clean key）|
| **Writeback** | `should_writeback` 返回 true（`writeback.h:102`）| 仅写 cache（dirty key），backing 由 writeback 线程延迟写 |

三者在 `cached_dev_write()`（`request.c:969-1051`）后统一调用 `closure_call(&s->iop.cl, bch_data_insert, NULL, cl)`（`request.c:1049`）。

**`should_writeback`**（`writeback.h:102-126`）决策：
- `in_use > cutoff_writeback_sync`（70%）→ 全部 bypass
- `in_use > cutoff_writeback`（40%）→ 仅 sync/meta/prio 写 writeback
- `in_use <= 40%` → 全部缓存

### D. 数据插入与 Btree 索引更新

```
bch_data_insert_start()             request.c:187
  循环每个 bio chunk:
    ├─ bch_alloc_sectors()          request.c:222 → alloc.c:606  (分配 bucket 空间)
    ├─ bio_next_split()             request.c:227
    ├─ bch_submit_bbio()           request.c:248 → io.c:45      (写 cache 设备)
    └─ bch_keylist_push()
  continue_at(cl, bch_data_insert_keys)  request.c:252

bch_data_insert_keys()              request.c:58
  ├─ bch_journal(c, keys, cl)      request.c:66 → journal.c:929  (日志记录)
  ├─ bch_btree_insert(c, keys, ref, replace)  request.c:69 → btree.c:2457
  │     └─ bch_btree_map_leaf_nodes(btree_insert_fn)  btree.c:2473
  │           └─ bch_btree_insert_node()              btree.c:2343
  │                 ├─ bch_btree_insert_keys()       btree.c:2167
  │                 ├─ bch_btree_leaf_dirty(b, ref)   btree.c:2368  (标记脏 + journal pin)
  │                 └─ [满] btree_split()              btree.c:2209
  └─ atomic_dec_bug(journal_ref)    request.c:78
```

---

## 四、核心子系统详解

### 1. Closure 异步原语（`closure.c` / `closure.h`）

bcache 的**自研异步框架**，区别于标准内核 `completion`/`workqueue`。

#### `struct closure` 定义（`closure.h:143-167`）

```c
struct closure {
    union {
        struct {
            struct workqueue_struct *wq;
            struct closure_syncer   *s;
            struct llist_node        list;
            closure_fn              *fn;
        };
        struct work_struct          work;   /* 与 fn 地址相同 */
    };
    struct closure      *parent;
    atomic_t            remaining;
};
```

#### 状态位（`closure.h:114-141`）

```c
CLOSURE_DESTRUCTOR = (1U << 26)   /* 运行 fn 作为析构器 */
CLOSURE_WAITING    = (1U << 28)   /* 在 waitlist 上 */
CLOSURE_RUNNING    = (1U << 30)   /* 运行中持有 1 ref */
CLOSURE_REMAINING_MASK = 低 26 位  /* refcount */
```

#### 核心宏

```c
// 丢弃运行 ref，空闲时在 wq 上运行 fn  (closure.h:315)
#define continue_at(_cl, _fn, _wq)                  \
    set_closure_fn(_cl, _fn, _wq);                   \
    closure_sub(_cl, CLOSURE_RUNNING + 1);

// 完成：fn=NULL，通知 parent  (closure.h:329)
#define closure_return(_cl)  continue_at((_cl), NULL, NULL)

// 析构完成：运行 destructor 后通知 parent  (closure.h:357)
#define closure_return_with_destructor(_cl, _destructor)              \
    set_closure_fn(_cl, _destructor, NULL);                          \
    closure_sub(_cl, CLOSURE_RUNNING - CLOSURE_DESTRUCTOR + 1);

// 尾调用：移交当前 ref 给 fn，立即排队  (closure.h:341)
#define continue_at_nobarrier(_cl, _fn, _wq)         \
    set_closure_fn(_cl, _fn, _wq);                    \
    closure_queue(_cl);

// 派生子闭包  (closure.h:370)
closure_init(cl, parent);          // ref=1|RUNNING, parent+1
continue_at_nobarrier(cl, fn, wq);
```

#### 核心不变量

- 运行中的 closure 持有 **1 个自引用**（`remaining = 1 | CLOSURE_RUNNING`）
- **`continue_at` 后必须立即 `return`**（`closure.h:36-38`）：caller 不再持有 ref，闭包内存可能在下一语句前被释放
- `closure_get`/`closure_put` 配对用于括起在途 bio：`closure_bio_submit` 做 `closure_get(cl)` + `submit_bio_noacct`，endio 中 `closure_put`
- parent 链：`closure_init(cl, parent)` 取 parent ref；`closure_return` 时归还

#### Closure 树示例（缓存未命中读）

```
s->cl (root, parent=NULL)
  │   fn 序列 (via continue_at on s->cl):
  │     cached_dev_read_done_bh        request.c:862
  │     cached_dev_read_done            request.c:820
  │     cached_dev_cache_miss_done     request.c:805
  │     cached_dev_bio_complete       request.c:753
  │       └─ search_free              request.c:702
  │
  ├── child: s->iop.cl  (parent=s->cl)
  │     closure_call(&s->iop.cl, cache_lookup, NULL, cl)  request.c:954
  │     (later) closure_call(&s->iop.cl, bch_data_insert, NULL, cl)  request.c:856
  │
  └── 在途 bios 持有 s->cl 的 ref (closure_bio_submit → closure_get)
```

#### 与标准内核原语对比

| 方面 | `struct closure` | `struct completion` | wait_queue |
|------|------------------|---------------------|------------|
| 计数对象 | refcount + 状态位 | done 计数 | 条件 + 等待者列表 |
| 续延 | 一等公民：`cl->fn` | 无 | 无 |
| 同步/异步混合 | 显式设计目标 | 仅同步 | 仅同步 |
| parent 层级 | 一等公民：ref 沿树传播 | 无 | 无 |
| waitlist | 每个 waiter 持 ref | 不持 ref | 不持 ref |

### 2. Btree 实现（`btree.c` / `bset.c`）

> **注意**：这是经典 bcache（非 bcachefs），使用标准 `rw_semaphore` 而非 SIX lock。

#### On-disk 结构

**`struct bkey`**（uapi `linux/bcache.h:23-27`）：

```c
struct bkey {
    __u64 high;
    __u64 low;
    __u64 ptr[];   /* 指针数组 */
};
```

字段（位域访问器 uapi `bcache.h:29-90`）：

| 字段 | 位置 | 位数 | 含义 |
|------|------|------|------|
| `KEY_PTRS` | high[60:63] | 3 | 指针数量 |
| `KEY_DIRTY` | high[36] | 1 | 脏数据（writeback） |
| `KEY_SIZE` | high[20:36] | 16 | 大小（sector） |
| `KEY_INODE` | high[0:20] | 20 | 后端设备 id |
| `KEY_OFFSET` | low | 64 | **结束**偏移（sector） |

Key 是半开区间 `[KEY_START, KEY_OFFSET)`（uapi `bcache.h:83`）：
```c
#define KEY_START(k)   (KEY_OFFSET(k) - KEY_SIZE(k))
```

**`struct bset`**（uapi `linux/bcache.h:419-430`）：

```c
struct bset {
    __u64 csum;      /* CRC64 */
    __u64 magic;     /* sb->set_magic ^ BSET_MAGIC */
    __u64 seq;       /* 节点内所有 bset 共享 */
    __u32 version;
    __u32 keys;      /* bkey 数量（u64 为单位） */
    struct bkey start[0];
};
```

**无 `struct btree_node`**：bucket 内是 bset 的日志式追加，所有 bset 共享同一 `seq`。

#### In-memory 节点（`btree.h:117-146`）

```c
struct btree {
    struct hlist_node hash;        /* 哈希到 c->bucket_hash */
    BKEY_PADDED(key);             /* 定位此节点 on-disk 的 key/pointer */
    unsigned long   seq;           /* 写锁变更时递增（cache-miss 竞争检测）*/
    struct rw_semaphore lock;      /* 节点读写锁（非 six_lock） */
    struct btree *parent;
    struct mutex write_lock;       /* 序列化 bset 写入 */
    uint16_t written;              /* 已写的 block 数 */
    uint8_t  level;                /* 0 = 叶子 */
    struct btree_keys keys;        /* 排序集机制 */
    struct closure io;             /* 在途 btree 写 */
    struct semaphore io_mutex;     /* 仅一个写在途 */
    struct delayed_work work;      /* 30s 延迟写 */
    struct btree_write writes[2];  /* 双缓冲 */
    struct bio *bio;
};
```

#### Log-structured 特性（`bset.h:157-232`）

```c
#define MAX_BSETS 4
struct bset_tree {
    unsigned int size;       /* 辅助搜索树节点数 */
    struct bkey end;          /* 此 set 最后一个 key 的副本 */
    struct bkey_float *tree; /* 辅助二叉搜索树 */
    uint8_t  *prev;           /* written: 前驱 key u64s; write: 平坦查找表 */
    struct bset *data;        /* on-disk bset 本身 */
};
struct btree_keys {
    uint8_t nsets;            /* 最后一个 set 的索引 */
    unsigned last_set_unwritten:1;
    struct bset_tree set[MAX_BSETS];
};
```

- `set[0].data` 指向整个 bucket；后续 `set[i]` 是后来追加的 bset
- 查找需对每个 set 做二分，但 `bch_btree_sort_lazy` 会惰性合并

#### Btree 迭代器（`bset.h:317-325`）

```c
struct btree_iter {
    size_t size, used;
    struct btree_iter_set { struct bkey *k, *end; } data[];
};
```

**min-heap**，每个 bset 一个条目，按 `bkey_cmp` 排序。迭代节点即合并至多 `MAX_BSETS` 个排序集。

#### 查找算法（root → leaf）

```
bcache_btree_root()              btree.h:348-367  (循环, -EINTR 重试)
  bcache_btree(fn) macro          btree.h:328-340
    _w = l <= op->lock             (决定读/写锁)
    bch_btree_node_get()          btree.c:981
      ├─ mca_find()               btree.c:829     (RCU hash 查找)
      └─ [miss] mca_alloc()       btree.c:898     (分配 + 从磁盘读)
           bch_btree_node_read()  btree.c:243
             bch_btree_sort_and_fix_extents()     (合并排序所有 set)
```

**节点内搜索** `__bch_bset_search`（`bset.c:1015-1076`）：
1. written set：`bset_search_tree`（4 字节 `bkey_float` 二叉树，失败回退到 `bkey_cmp`）
2. unwritten set：`bset_search_write_set`（平坦查找表二分）
3. 最终线性扫描到第一个严格大于 search 的 key

#### 插入路径

`bch_btree_insert`（`btree.c:2457-2489`）→ `bch_btree_map_leaf_nodes(btree_insert_fn)` → `bch_btree_insert_node`（`btree.c:2343-2397`）：

1. `mutex_lock(&b->write_lock)`
2. 容量检查，不够则 `goto split`
3. `bch_btree_insert_keys`（`btree.c:2167`）：仅修改最后一个 unwritten set
4. 叶子 → `bch_btree_leaf_dirty(b, journal_ref)`（30s 延迟写 + journal pin）
5. 内部节点 → `bch_btree_node_write`（同步写）

**单 key 插入** `bch_btree_insert_key`（`bset.c:876-931`）：
- 先调用 `ops->insert_fixup`（extents: `bch_extent_insert_fixup`，裁剪/分裂重叠 extent）
- 线性扫描到插入点
- 尝试 BACK_MERGE / FRONT_MERGE / INSERT

**两种模式**：
- **Overwrite**（`replace_key == NULL`）：裁剪重叠 extent 腾出空间
- **Replace**（`replace_key != NULL`）：cmpxchg，仅当现有 key 匹配 `replace_key` 时才替换

#### 节点分裂（`btree.c:2209-2341`）

同步，**parent 更新不经 journal**：

1. 分配替代节点 `n1`，排序所有 key
2. 若 >80% 满 → 分裂：分配 `n2`，若为根则分配 `n3`（新根）
3. 按 60/40 分割 key
4. 非根分裂：`make_btree_freeing_key`（增加 bucket gen）+ 插入 parent
5. 返回 `-EINTR` 重启若有剩余 key

#### 节点写（COW）

```
bch_btree_leaf_dirty(b, journal_ref)  btree.c:475
  ├─ set BTREE_NODE_dirty
  ├─ schedule b->work (30s 延迟写)
  └─ pin journal_ref 到 btree_current_write(b)->journal

__bch_btree_node_write(b, parent)     btree.c:403
  ├─ down(&b->io_mutex)               (仅一个写在途)
  ├─ closure_init(&b->io, parent)
  ├─ toggle BTREE_NODE_write_idx
  └─ do_btree_node_write()            btree.c:338
       ├─ btree_csum_set()             btree.c:139  (CRC64, XOR ~0, seed = b->key.ptr[0])
       ├─ bch_bio_alloc_pages()       (复制后提交, async)
       │   └─ continue_at(btree_node_write_done)
       └─ [失败] 直接映射 bio, closure_sync + continue_at_nobarrier
```

旧 bset 永不原地修改；节点替换（分裂/GC）通过 `make_btree_freeing_key` 增加 gen 使旧节点失效。

#### Btree 缓存与 Cannibalize

- **Hash 表**：`c->bucket_hash`（`bcache.h:736`），`mca_find`（`btree.c:829`）RCU 查找
- **`mca_alloc`**（`btree.c:898`）：按优先级：hash 命中 → `btree_cache_freeable` → `btree_cache_freed` → 新分配 → **cannibalize**
- **Cannibalize**（`btree.c:860`）：全局 `btree_cache_alloc_lock`，仅一个线程可回收 LRU 节点
- **Reserve**：`btree_check_reserve`（`btree.c:1179`）保证 `(root->level - b->level)*2 + 1` 个 free btree bucket

### 3. Bucket 分配（`alloc.c`）

#### `struct bucket`（`bcache.h:197-203`）

```c
struct bucket {
    atomic_t    pin;       /* 在途引用计数 */
    uint16_t    prio;      /* 16-bit LRU 优先级 */
    uint8_t     gen;       /* 8-bit generation */
    uint8_t     last_gc;   /* btree 中最旧的 gen */
    uint16_t    gc_mark;   /* 位域：GC_MARK(2) | GC_SECTORS_USED(13) | GC_MOVE(1) */
};
```

#### 分配 FIFO 与 Reserve

```c
enum alloc_reserve {
    RESERVE_BTREE,     /* btree 节点分配 */
    RESERVE_PRIO,      /* prio/gen 数据 */
    RESERVE_MOVINGGC,  /* moving GC */
    RESERVE_NONE,      /* 普通数据写入 */
    RESERVE_NR,
};
```

- `free[RESERVE_NR]`：已就绪 bucket（gen 已持久化）
- `free_inc`：新失效 bucket（gen 未写盘，需 `bch_prio_write` 后移至 `free[]`）

#### Bucket 生命周期

```
free[RESERVE_*] (gen 已持久化, pin=1)
  │ bch_bucket_alloc()  alloc.c:392
  │   (标记 GC_MARK, 设置 prio: BTREE_PRIO 或 INITIAL_PRIO)
  ▼
ALLOCATED (in use, pin=1)
  │ bch_alloc_sectors()  alloc.c:606  (通过 open_bucket 写数据)
  │ key 插入 btree, bkey_put 递减 pin
  │
  │ [数据失效/覆盖] GC 标记为 RECLAIMABLE
  │ bch_bucket_free()  alloc.c:480  (仅清 GC_MARK，不增 gen)
  ▼
RECLAIMABLE / EMPTY (GC_MARK=0 或 RECLAIMABLE, pin=0)
  │ __bch_invalidate_one_bucket()  alloc.c:140
  │   bch_inc_gen() → gen++  (alloc.c:78)
  │   prio = INITIAL_PRIO, pin = 1
  │   push free_inc
  ▼
free_inc (gen 未持久化, pin=1)
  │ bch_prio_write()  super.c:614
  │   打包 (prio,gen) 到 prio_set on disk
  │   分配 RESERVE_PRIO bucket 存储
  │   写 journal meta 指向 prio_buckets[0]
  │   释放旧 prio_last_buckets
  │   pin--  (super.c:671)
  ▼
free_inc → free[] (allocator thread, alloc.c:329)
  │   (可选 blkdev_issue_discard)
  │   bch_allocator_push → free[RESERVE_PRIO] first
  ▼
回到 free[RESERVE_*] (READY)
```

#### `bch_bucket_alloc`（`alloc.c:392-467`）

1. IO-disable 检查
2. Fastpath：`fifo_pop(RESERVE_NONE)` → `fifo_pop(reserve)`
3. 阻塞慢路径：`wait_event(bucket_wait)`
4. 初始化：`GC_SECTORS_USED = bucket_size`，`GC_MARK = META/RECLAIMABLE`，`prio = BTREE_PRIO/INITIAL_PRIO`

#### `bch_alloc_sectors`（`alloc.c:606-693`）— 扇区分配

使用 **open_bucket**（最多 128 个，`alloc.c:72`）：

1. `pick_data_bucket`（`alloc.c:565`）：按 write_point 分流（避免不同 IO 流混合）
2. 分配新 bucket（若需）
3. 设置 `KEY_OFFSET`/`KEY_SIZE`，推进 `PTR_OFFSET`
4. `sectors_free -= sectors`；若 < block_size 则关闭

#### 8-bit Generation 防回绕

```c
static inline uint8_t bucket_gc_gen(struct bucket *b) {
    return b->gen - b->last_gc;   // bcache.h:910
}
#define BUCKET_GC_GEN_MAX 96U     // bcache.h:915
```

`can_inc_bucket_gen`（`alloc.c:125`）在 `bucket_gc_gen >= 96` 时拒绝失效，设置 `invalidate_needs_gc` 强制 GC（`alloc.c:207`）。GC 重写 stale 节点会刷新 `last_gc`。

#### LRU 优先级系统

**`bch_rescale_priorities`**（`alloc.c:86-116`）：
- `c->rescale` 累积 IO 量，变负时触发
- 每个非 metadata、非 pinned bucket 的 `prio--`
- 重新计算 `min_prio`

**`bucket_prio`**（`alloc.c:169`）：
```c
#define bucket_prio(b)  (b->prio - min_prio + offset) * GC_SECTORS_USED(b)
```
优先级 × 活跃扇区数，使近空高优 bucket 可被选中。

#### Allocator 线程（`alloc.c:317-388`）

```
bch_allocator_thread()  (持有 bucket_lock)
  Phase A:  drain free_inc → free[]
    ├─ 可选 blkdev_issue_discard
    ├─ bch_allocator_push (RESERVE_PRIO first)
    └─ wake_up(bucket_wait, btree_cache_wait)
  Phase B:  invalidate → refill free_inc
    ├─ wait(gc_mark_valid && !invalidate_needs_gc)
    ├─ invalidate_buckets() (LRU/FIFO/RANDOM)
    └─ bch_prio_write() (持久化 gen/prio)
```

### 4. Journal（`journal.c`）

**纯性能优化，非一致性保障**（`bcache.h:152-177`）。批量叶子更新为 4KB 块，避免每个随机写都触发 btree 叶子节点的近空写入。

#### On-disk 格式 — `struct jset`（uapi `bcache.h:345`）

```c
struct jset {
    __u64 csum, magic, seq;
    __u32 version, keys;
    __u64 last_seq;                 /* 最旧的仍 open 的 journal entry */
    BKEY_PADDED(uuid_bucket);       /* "频繁写入的超级块" */
    BKEY_PADDED(btree_root);
    __u16 btree_level, pad[3];
    __u64 prio_bucket[MAX_CACHES_PER_SET];
    struct bkey start[0];           /* journaled bkeys */
};
```

循环 bucket 缓冲区（`SB_JOURNAL_BUCKETS = 256`），三个游标：
- `cur_idx`：当前写入 bucket
- `last_idx`：最旧含 open entry 的 bucket
- `discard_idx`：下一个 discard bucket

#### 写入路径

```
bch_journal(c, keys, parent)     journal.c:929
  ├─ journal_wait_for_write()    journal.c:855   (等待空间, 可能触发 btree_flush_write)
  ├─ memcpy keys → w->data
  ├─ atomic_inc(pin)             journal.c:949   (caller 的 pin ref)
  └─ [sync] closure_wait + journal_try_write
     [async] schedule delayed_work (100ms)

journal_write_unlocked()        journal.c:751
  ├─ 填充 jset header (btree_root, uuid, prio)
  ├─ REQ_FUA|REQ_PREFLUSH 写入   journal.c:804
  ├─ atomic_dec_bug(pin back)    journal.c:819   (丢弃 writer pin)
  ├─ bch_journal_next()          journal.c:697   (旋转双缓冲, ++seq, push 新 pin)
  ├─ journal_reclaim()           journal.c:652
  └─ submit bios, continue_at(journal_write_done)
```

#### Pin 系统

每个 open journal entry 对应 `journal.pin` FIFO 中一个 `atomic_t`（`JOURNAL_PIN = 20000`，`journal.h:165`）。三类持有者：

1. **Writer**：`bch_journal_next` 取 ref（`journal.c:710`），`journal_write_unlocked` 丢弃（`journal.c:819`）
2. **Caller**（如 `bch_data_insert_keys`）：`bch_journal` 取（`journal.c:949`），btree insert 返回后丢（`request.c:78`）
3. **btree_write**：`bch_btree_leaf_dirty` 取（`btree.c:504`），`btree_complete_write` 丢弃（`btree.c:288`）

`btree_write.journal` 始终指向节点中**最旧**的 journal pin（`btree.c:491-506`）。

#### Journal Reclaim（`journal.c:652-695`）

```
journal_reclaim(c)
  ├─ 弹出 refcount=0 的 pin slot (advance last_seq)
  ├─ 推进 last_idx (ja->seq < last_seq 的 bucket)
  ├─ do_journal_discard (异步 TRIM)
  ├─ 若需新 bucket: cur_idx++, 分配, blocks_free = bucket_size
  └─ wake_up(&c->journal.wait) if !journal_full
```

#### 回放（启动时）

```
bch_journal_read()     journal.c:171    (扫描所有 bucket, 按 seq 排序)
bch_journal_mark()     journal.c:294    (标记 bucket, 分配 pin slot)
bch_journal_next()     journal.c:697    (旋转缓冲)
bch_journal_replay()   journal.c:350    (按 seq 顺序重新插入每个 bkey)
```

#### `btree_flush_write`（`journal.c:417-568`）— Journal 满时刷新 btree

当 journal 满（`blocks_free == 0` 或 `fifo_free(pin) <= 1`）：
1. 读取最旧 pin（FIFO front）及其 refcount
2. 逆 LRU 扫描 btree cache，找 pin 此 jset 的脏节点（最多 `BTREE_FLUSH_NR = 8`）
3. `__bch_btree_node_write` 强制写盘
4. btree 写完成 → `btree_complete_write` → `atomic_dec_bug(pin)` → wake journal wait

### 5. Writeback（`writeback.c`）

#### 发现脏数据

`bch_sectors_dirty_init`（`writeback.c:967`）启动多线程（最多 12 个，`BCH_DIRTY_INIT_THRD_MAX`）遍历 btree，填充：

```c
struct bcache_device {
    int nr_stripes;
    unsigned int stripe_size;           /* 最小 4MB */
    atomic_t *stripe_sectors_dirty;     /* 每 stripe 脏扇区数 */
    unsigned long *full_dirty_stripes; /* 完全脏的 stripe 位图 */
};
```

#### Writeback 线程（`writeback.c:728`）

```
bch_writeback_thread()
  循环:
    ├─ refill_dirty()              writeback.c:690   (扫描 btree 填充 keybuf)
    │     ├─ refill_full_stripes() writeback.c:641    (RAID 优化: 优先满条带)
    │     └─ bch_refill_keybuf()   btree.c:2657
    └─ read_dirty()                writeback.c:466
          循环每个 dirty key:
            ├─ 聚合最多 5 个连续 key (MAX_WRITEBACKS_IN_PASS)
            ├─ dirty_init()         writeback.c:321   (READ bio from cache)
            └─ closure_call(read_dirty_submit)
                 read_dirty_submit() writeback.c:457
                   write_dirty()    writeback.c:395   (LBA 顺序保证)
                     └─ [sequence 匹配] 写 backing 设备
                        write_dirty_finish() writeback.c:343
                          └─ bch_btree_insert(replace_key)  writeback.c:366
                               (原子替换 dirty key → clean key)
```

#### LBA 顺序保证（`writeback.c:395-442`）

```c
if (atomic_read(&dc->writeback_sequence_next) != io->sequence) {
    closure_wait(&dc->writeback_ordering_wait, cl);   // writeback.c:405
    continue_at(cl, write_dirty, writeback_write_wq);  // writeback.c:415
    return;
}
// ... 写 backing 设备 ...
atomic_set(&dc->writeback_sequence_next, next_sequence);
closure_wake_up(&dc->writeback_ordering_wait);         // writeback.c:439
```

读完成乱序，但写按 LBA 顺序派发。

#### PI 速率控制器（`writeback.c:61-158`）

```
target  = __calc_target_rate(dc)   (cache_sectors * writeback_percent * bdev_share)
dirty   = bcache_dev_sectors_dirty(&dc->disk)
error   = dirty - target

P = error / p_term_inverse          (默认 40, 即 40 秒清空)

碎片化启发式 (in_use > 50%):
  fragment = (dirty_buckets * bucket_size) / dirty
  fp_term = 系数 * (in_use - threshold)
  若 fragment > 3 且 fp > P → 覆盖 P

I += error * update_seconds         (反卷绕: 仅 error<0 且 I>0 时减少)
I_scaled = I / i_term_inverse       (默认 10000)

rate = clamp(P + I_scaled, minimum=8, NSEC_PER_SEC)
```

#### Idle / Max Rate

- `idle_counter` 每 5s（`update_writeback_rate`）递增
- 超过 `dev_nr * dev_nr * 6` 时触发 `set_at_max_writeback_rate`（`writeback.c:207`）
- 新 IO 到达时重置（`request.c:1188-1201`）

### 6. Moving GC（`movinggc.c`）

在每次常规 GC 结束时调用（`btree.c:1839`）：

```
bch_moving_gc()            movinggc.c:197
  ├─ 构建 min-heap (按 GC_SECTORS_USED)
  │   选取最空的非空非满 bucket (移动代价最低)
  ├─ 裁剪至 RESERVE_MOVINGGC 容量
  └─ SET_GC_MOVE(b, 1)

read_moving()              movinggc.c:126
  循环:
    ├─ bch_keybuf_next_rescan + moving_pred (指向 GC_MOVE bucket 的 key)
    ├─ 分配 moving_io
    └─ closure_call(read_moving_submit)
         read_moving_submit() movinggc.c:116
           bch_submit_bbio() (从旧 bucket 读)
           continue_at(write_moving)
         write_moving()      movinggc.c:92
           op->replace = true, replace_key = w->key
           closure_call(bch_data_insert)  (写入新 bucket)
         write_moving_finish() movinggc.c:45
           bch_keybuf_del, up(moving_in_flight)
```

**原子替换**：`bch_data_insert` → `bch_btree_insert(replace_key)` 用新 pointer 的 key 覆盖旧 key，旧 bucket 指针失效。

### 7. 常规 GC（`btree.c:1798`）

```
bch_btree_gc()
  ├─ btree_gc_start()           btree.c:1708   (gc_mark_valid=0, 重置 marks)
  │     for_each_bucket: b->last_gc = b->gen, 清 GC_MARK/GC_SECTORS_USED
  ├─ bcache_btree_root(gc_root) btree.c:1816
  │     └─ btree_gc_recurse()   btree.c:1582   (增量深度优先, sliding window=4)
  │           └─ btree_gc_mark_node()  btree.c:1281
  │                 └─ __bch_btree_mark_key()  btree.c:1202
  │                      ├─ 更新 last_gc
  │                      ├─ 设置 GC_MARK: METADATA(level>0)/DIRTY/RECLAIMABLE
  │                      └─ 累加 GC_SECTORS_USED (clamped to MAX_GC_SECTORS_USED=8191)
  ├─ bch_btree_gc_finish()      btree.c:1733
  │     ├─ gc_mark_valid = 1
  │     ├─ 标记 writeback bucket 为 DIRTY (btree.c:1761-1767)
  │     ├─ 标记 uuid/prio/journal bucket 为 METADATA
  │     └─ 计算 avail_nbuckets, need_gc
  ├─ wake_up_allocators()       btree.c:1828
  └─ bch_moving_gc()            btree.c:1839
```

**触发**：`gc_should_run`（`btree.c:1842`）检查 `invalidate_needs_gc` 或 `sectors_to_gc < 0`；有机触发由 `set_gc_sectors`（`btree.h:195`，约 6.25% 缓存容量写入后）。

### 8. 错误处理与停机

#### `bch_cache_set_error`（`super.c:1635-1668`）

```c
bool bch_cache_set_error(struct cache_set *c, const char *fmt, ...);
```
- 设置 `CACHE_SET_IO_DISABLE`（拒绝所有 IO）
- `on_error == ON_ERROR_PANIC` → `panic()`
- 否则 → `bch_cache_set_unregister(c)`

#### `conditional_stop_bcache_device`（`super.c:1782-1820`）

| `stop_when_cache_set_failed` | `has_dirty` | 停止？ |
|------------------------------|-------------|--------|
| `ALWAYS` | 0 或 1 | 是 |
| `AUTO` | 1（脏） | 是（先 `io_disable`） |
| `AUTO` | 0（干净） | 否（保持 passthrough） |

#### Closure 驱动的停机序列

```
bch_cache_set_stop(c)          super.c:1852
  set_bit(CACHE_SET_STOPPING)
  closure_queue(&c->caching)

__cache_set_unregister(cl)     super.c:1822
  ├─ 分离所有 backing device (若 UNREGISTERING)
  ├─ continue_at(cl, cache_set_flush)

cache_set_flush(cl)            super.c:1720
  ├─ 停止 gc_thread
  ├─ flush dirty btree nodes (若非 IO_DISABLE)
  ├─ 停止 alloc_thread
  ├─ flush journal
  └─ closure_return(cl)

cache_set_free(cl)             super.c:1679   (caching refcount 归零时)
  ├─ bch_btree_cache_free, bch_journal_free
  ├─ kobject_put(&ca->kobj) → bch_cache_release
  └─ kobject_put(&c->kobj) → bch_cache_set_release → kfree(c)
```

---

## 五、架构洞察

### 设计模式

1. **Closure 闭包树**：所有异步操作（IO、btree 写、journal 写、writeback）通过 parent 链组成树，refcount 传播保证 parent 在所有子操作完成后才继续。这比 `completion` + `wait_event` 更适合扇出密集的 IO 拓扑。

2. **COW 至 bucket 粒度**：btree 节点追加 bset（不原地修改），分裂时通过 `make_btree_freeing_key` 增加 bucket gen 使旧节点失效。数据 bucket 同理。

3. **Log-structured btree**：节点内 bset 日志式追加 + 惰性合并，避免大节点（~1MB）的频繁重写。辅助搜索树（`bkey_float`）使单 set 查找为 O(log) + cacheline 线性。

4. **分层 reserve**：`RESERVE_BTREE`/`PRIO`/`MOVINGGC`/`NONE` 确保关键操作（btree 分裂、prio 写）不会因普通数据写入耗尽 bucket 而死锁。

5. **Pin 驱动的生命周期**：bucket 的 `pin` 在失效时置 1，持久化后递减；journal 的 pin 由 btree_write 持有至节点持久化。两者都防止"数据仍被引用时被回收"。

6. **增量 GC**：`btree_gc_recurse` 使用 sliding window（`GC_MERGE_NODES=4`），当 `search_inflight` 且处理足够多节点时返回 `-EAGAIN` 让出 CPU（`btree.c:1556-1579`）。

### 关键不变量

- **bkey offset = extent 结束位置**（半开区间 `[START, OFFSET)`，uapi `bcache.h:83`）
- **运行中的 closure 持有 1 个自引用**（`closure.h:40-76`）
- **`continue_at` 后必须立即 `return`**（`closure.h:36-38`）
- **bucket 的 pin=1 在 free[] 中保持至分配**（`alloc.c:447`）
- **journal pin 仅在所有相关 btree_write 持久化后归零**（`btree.c:288`）
- **GC 期间 gc_mark_valid=0**，分配器等待 GC 完成（`alloc.c:355-356`）
- **writeback bucket 在 GC_finish 中标记 DIRTY**，防止分配器回收（`btree.c:1761-1767`）
- **parent 节点更新不经 journal**（同步写，`bcache.h:173-176`）

---

## 六、依赖与配置

### 外部依赖
- Linux 内核块层：`submit_bio_noacct`、`blk_alloc_disk`、`bio_split`、`blkdev_get_by_path`
- 内核基础设施：workqueue（`WQ_MEM_RECLAIM`）、kobject/sysfs、kthread、debugfs、mempool、slab
- CRC64（`crc64_be`）、红黑树、FIFO/heap 数据结构（自实现于 `util.h`）

### Sysfs 配置面

**后端设备**（`bch_cached_dev_files[]`，`sysfs.c:503-545`）：
- `cache_mode`：`writethrough|writeback|writearound|none`
- `sequential_cutoff`：顺序 IO 旁路阈值（默认 4MB）
- `writeback_percent`：脏数据目标比例（默认 10%）
- `writeback_rate_*`：PI 控制器参数（p_term_inverse=40, i_term_inverse=10000）
- `stop_when_cache_set_failed`：`auto|always`
- `attach`/`detach`/`stop`：操作入口
- `label`：设备标签（持久化到超级块）

**缓存集**（`bch_cache_set_files[]`，`sysfs.c:958-982`）：
- `journal_delay_ms`：journal 刷新延迟（默认 100ms）
- `congested_*_threshold_us`：拥塞阈值
- `errors`：`unregister|panic`
- `io_error_limit`：错误上限（默认 8）
- `io_disable`：禁用所有 IO
- `flash_vol_create`：创建 flash-only 卷
- `gc_after_writeback`：writeback 后自动 GC
- `trigger_gc`：手动触发 GC

**缓存集内部**（`bch_cache_set_internal_files[]`，`sysfs.c:985-1024`）：
- `active_journal_entries`、time stats（`btree_gc`/`btree_split`/`btree_sort`/`btree_read`）
- `btree_nodes`、`btree_used_percent`、`btree_cache_max_chain`
- `cache_read_races`、`writeback_keys_done/failed`
- `copy_gc_enabled`、`idle_max_writeback_rate`
- `feature_compat/ro_compat/incompat`

**缓存设备**（`bch_cache_files[]`，`sysfs.c:1185-1198`）：
- `discard`：TRIM 开关
- `cache_replacement_policy`：`lru|fifo|random`
- `priority_stats`：优先级分布统计
- `written`/`btree_written`/`metadata_written`：写入量

### Feature Flags（`features.h`）

```c
BCH_FEATURE_INCOMPAT_OBSO_LARGE_BUCKET   = 0x0001  /* 废弃的 32-bit bucket size */
BCH_FEATURE_INCOMPAT_LOG_LARGE_BUCKET_SIZE = 0x0002  /* 真实 bucket size = 1 << bucket_size */
```

未知 feature 在注册时拒绝（`features.h:93-106`，`super.c:69`）。

### 统计与调试

**统计**（`stats.c`）：
- 6 个原子计数器：`cache_hits`/`misses`/`bypass_hits`/`bypass_misses`/`miss_collisions`/`sectors_bypassed`
- 4 个窗口：`total`（绝对）/`five_minute`/`hour`/`day`（EWMA，半衰期 5min/1h/1d）
- 定时器每 5min 触发 22 次，`accounting_weight=32`（`pow(31/32, 22) ≈ 1/2`）

**调试**（`debug.c`）：
- `CONFIG_BCACHE_DEBUG`：`bch_btree_verify`（内存 vs 磁盘对比，mismatch → panic）、`bch_data_verify`（cache vs backing 字节对比）
- `CONFIG_DEBUG_FS`：`/sys/kernel/debug/bcache/bcache-<uuid>` 全 btree extent dump

**Trace**（`trace.c`）：
- 定义 23 个 tracepoint，覆盖 request/btree/journal/alloc/writeback/gc

### Util 工具（`util.h`）

- `DECLARE_HEAP`：二叉堆（分配器 LRU 选择、moving GC bucket 选择）
- `DECLARE_FIFO`：环形缓冲区（free[]、free_inc、journal.pin）
- `DECLARE_ARRAY_ALLOCATOR`：无锁固定大小池（keybuf freelist）
- `bch_crc64`：ECMA-182 reflected CRC-64
- `bch_ratelimit` + `bch_next_delay`：writeback 速率控制
- `struct time_stats`：EWMA 时间统计
- `bch_hprint`：人类可读数字（1.5k/2.3M）
- 红黑树助手：`RB_INSERT`/`RB_SEARCH`/`RB_GREATER`

---

## 七、观察与改进机会

### 优势

1. **Closure 模型**优雅地处理了扇出密集的 IO 异步性，parent 链天然支持层级操作
2. **Log-structured btree**在大节点下兼顾了写入效率与查找性能
3. **Pin 机制**精确地将 journal 生命周期与 btree 持久化绑定，避免数据丢失
4. **增量 GC + moving GC** 分离关注点：GC 重建状态，moving GC 回收空间
5. **Open bucket 分流**：按 write_point 隔离不同 IO 流，保持局部性
6. **双缓冲 btree write**（`writes[2]`）：允许在新 set 准备时旧写仍在途

### 潜在问题

1. **8-bit generation** 的回绕窗口仅 96（`BUCKET_GC_GEN_MAX`），高 churn 场景可能频繁触发 GC
2. **单 cache 设备**支持未完成（`bcache.h:10-11` 注释），多 cache 镜像仅 95% 打通
3. **Flash-only 卷**的 moving GC "needs more work"（`bcache.h:32-33`）
4. **writeback 的 LBA 顺序保证**通过 closure_waitlist 串行化，高并发下可能成为瓶颈
5. `cached_dev_status_update` 线程轮询 backing 设备离线（5s 超时，`super.c:1012`），响应较慢
6. 部分 `#if 0` 代码（如 `data_csum`，`sysfs.c:507-509`）表明校验和功能未完成
7. `bcache_reboot` 在无锁路径等待 10s（`super.c:2786-2801`），极端情况可能不够
8. **Journal 仅记录叶子更新**，parent 更新同步写（`btree_split`），频繁分裂时 journal 优化失效

---

## 八、必读文件清单

理解 bcache 必须阅读的文件（按优先级）：

| 优先级 | 文件 | 行数 | 关键内容 |
|--------|------|------|---------|
| ★★★ | `src/bcache.h` | 1046 | 架构文档注释 + 所有核心结构定义 + 前向声明 |
| ★★★ | `src/closure.h` | 378 | Closure 设计哲学 + 所有宏定义 |
| ★★★ | `src/btree.c` | 2802 | Btree 操作、GC、node 读写、分裂 |
| ★★★ | `src/request.c` | 1350 | IO 状态机、读写路径、cache miss |
| ★★ | `src/super.c` | 2946 | 模块初始化、设备注册、shutdown |
| ★★ | `src/alloc.c` | 736 | Bucket 分配、失效、LRU |
| ★★ | `src/bset.c` | 1390 | Bset 排序、搜索树、插入 |
| ★★ | `src/journal.c` | 1005 | Journal 写入、回放、reclaim |
| ★★ | `src/writeback.c` | 1087 | Writeback 线程、PI 控制器 |
| ★ | `src/extents.c` | 630 | Extent 操作、insert_fixup |
| ★ | `src/movinggc.c` | 252 | Moving GC 算法 |
| ★ | `src/io.c` | 174 | Bio 提交、错误计数、拥塞采样 |
| ★ | `src/sysfs.c` | 1199 | 完整可调参数面 |
| ★ | `src/util.h` | 591 | HEAP/FIFO/ARRAY_ALLOCATOR 宏、CRC64、ratelimit |
| ★ | `/usr/include/linux/bcache.h`（uapi） | - | On-disk 格式：`cache_sb`、`bkey`、`bset`、`jset` |

---

## 九、总结

bcache 是一个设计精巧的块设备缓存层，其核心创新在于：

1. **基于 closure 的异步框架**提供可组合的控制流，通过 parent 链天然支持层级操作的依赖追踪，每个在途 bio 通过 `closure_get`/`closure_put` 持有 ref，refcount 归零时自动触发续延。

2. **Log-structured btree** 兼顾大节点（~1MB）的写入效率与查找性能：节点内 bset 日志式追加 + 惰性合并，辅助搜索树（`bkey_float`）使单 set 查找为 O(log) + cacheline 线性，无需重写整个节点即可插入新 key。

3. **Generation number + pin 机制**实现高效的 bucket 回收与数据安全：8-bit gen 通过增量失效指针避免昂贵 seek，`can_inc_bucket_gen` 防止回绕，bucket/journal 的 pin 精确绑定生命周期。

4. **Journal 作为纯性能优化**绑定 btree_write 生命周期：仅记录叶子更新，通过 pin 系统确保 journal entry 仅在所有相关 btree 节点持久化后才可回收，`btree_flush_write` 在 journal 满时主动刷新最旧的脏节点。

5. **分层 GC**：常规 GC 重建 bucket 状态（mark + sweep），moving GC 回收部分填充的 bucket，writeback 延迟刷写脏数据，三者通过 `gc_mark_valid`、`GC_MARK_DIRTY`、`pin` 协调，避免相互干扰。

理解 **closure 模型**（`closure.h`）和 **btree 的 log-structured 特性**（`bset.h`）是修改此代码库的关键前提。
