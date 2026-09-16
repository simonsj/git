# Why `git index-pack` can be slow on huge packs

`git index-pack` does not “read a pack and write a small table.”
It rebuilds every object’s identity from compressed bytes, then
writes the `.idx` (and usually a `.rev`) that Git needs before it
will *use* that pack. On a humongous repository the work is
linear in **object count**, **inflated size**, and **delta-chain
depth**, and the first pass cannot be parallelized. That is why
indexing a multi-gigabyte, tens-of-millions-of-objects pack is
minutes to hours of CPU even when the file is already on local
disk.

Canonical sources: `builtin/index-pack.c`, `pack-write.c`
(`write_idx_file()`, `write_rev_file()`),
`Documentation/git-index-pack.adoc`,
`Documentation/gitformat-pack.adoc`. How this shows up after a
bundle or packfile-URI download is in
`bundle-uri-history-and-rationale-for-slow-reverify-on-the-client-side.md`.

---

## What the command is for

Git will not look up objects in a `.pack` that has no `.idx`.
`add_packed_git()` only accepts an idx path; the pack is then
opened beside it. The idx is:

- OID → byte offset in the pack
- per-object CRC32 of the packed bytes (idx v2)
- the pack checksum in the trailer

None of those OIDs are stored next to deltified objects. A pack
entry is a type/size header, an optional base (OID or relative
offset), and a zlib stream. The object’s name is `hash(type +
size + reconstructed content)`. For a delta, “reconstructed
content” means: inflate the delta, apply it to a fully
reconstructed base, then hash. That is the job.

So `index-pack` is not optional bookkeeping. It is “turn a pack
*stream* into a usable pack+idx,” the same work a clone does
while the pack arrives. A publisher who already has the idx can
skip it; the client that only has the pack cannot.

---

## The pack format forces a sequential first pass

A pack is `PACK` + version + object count, then **concatenated
objects**, then a trailer hash of everything before it
(`gitformat-pack.adoc`).

The object header stores **uncompressed** size, not compressed
size. There is no length prefix that would let you skip to object
`N+1`. The only way to find the next object is to inflate this
one to `Z_STREAM_END`. That is why `parse_pack_objects()` is a
single `for` loop over `nr_objects` with a 128 KiB sliding
buffer (`DEFAULT_IO_BUFFER_SIZE`). Threads cannot split the
stream.

During that loop, for **every** object (base *and* delta):

1. Parse the type/size header and any REF/OFS base.
2. Inflate the zlib payload (`unpack_entry_data()`).
3. CRC32 the packed bytes (header + base + compressed data) for
   the idx.
4. Feed the same bytes into a running pack-hash
   (`input_ctx` in `flush()` / `use()`).
5. If `--stdin`, **write those bytes again** to
   `objects/pack/tmp_pack_XXXXXX`.

Then, only for non-deltas: hash `header + inflated content` to
get the OID (`sha1_object()`). Deltas are inflated just to
consume the stream and record `{offset, size, crc, base}`; the
inflated delta instructions are `free()`d. Large blobs above
`core.bigFileThreshold` (default 512 MiB) are hashed in an 8 KiB
ring so the first pass does not hold the whole blob.

At the end of the pass it checks the pack trailer against
`input_ctx`. If the input is a regular file, it also checks there
is no junk after the trailer.

That is already a full inflate of the pack, a CRC of every packed
object, a cryptographic hash of the whole file, and a
cryptographic hash of every non-delta object. On `--stdin` it is
also a second full write of the pack. None of it overlaps with
the second pass.

On a normal `git clone`, this pass is titled **Receiving
objects** and runs while the network fills stdin, so inflate can
hide behind download. On an already-downloaded huge pack (bundle
unbundle, `index-pack pack-….pack`, `verify-pack`) there is
nothing to hide behind: it is pure CPU and sequential disk.

---

## The second pass reconstructs every delta — and re-inflates

After the first pass, Git still does not know the OIDs of
deltified objects. `resolve_deltas()`:

1. Sorts the OFS-delta table by base offset and the REF-delta
   table by base OID.
2. Walks non-delta objects. If one is a base, inflates it **again**
   from disk (`get_data_from_pack()` → `pread` + inflate).
3. For each child: inflate the delta instructions **again**,
   `patch_delta()` against the base, then
   `hash_object_file()` to name the result (`resolve_delta()`).
4. Recurses: that result may itself be a base
   (`threaded_second_pass()`).

This is the **Resolving deltas** progress bar. In a typical
packed history the large majority of objects are deltas
(`pack.depth` defaults to 50). First-pass inflate of those
objects was thrown away, so the expensive objects are inflated
twice: once to find boundaries, once to apply.

Bases that have several children are kept in a process-wide
delta-base cache (`core.deltaBaseCacheLimit`, default **96 MiB
per thread**). If the cache fills, `prune_base_data()` drops
inflated bases. The next child then calls `get_base_data()`,
which walks **up the chain to the nearest cached ancestor (or
the ultimate base)** and reapplies every delta in between. Deep
chains plus a cache that is small relative to inflated working
set means repeated reconstruction of the same objects. Git 2.55
kept child bases in that cache longer instead of freeing them
immediately; that helps, it does not remove the bound.

REF deltas whose bases are **not in the pack** need `--fix-thin`:
read the base from the object database, deflate it, append it,
fix the pack header and trailer (`conclude_pack()` /
`fix_unresolved_deltas()`). A thick clone pack should not hit
this. A thin incremental pack can, and each appended base can
unlock a tree of further deltas.

---

## Why “humongous” makes this much worse than linear bytes

Two size axes, both huge in a monorepo:

| Axis | What it costs |
|---|---|
| **Pack bytes** | First-pass inflate + CRC + pack-hash (+ stdin copy). zlib of many gigabytes. |
| **Object count** | Per-object header parse, two inflates for deltas, one hash of reconstructed content, metadata RAM, idx sort/write. |
| **Delta depth / fan-out** | `patch_delta` CPU; cache misses replay whole chains; `pread` of compressed slices. |
| **Inflated size** | Trees and blobs can be much larger than their packed form. Hashing and `patch_delta` run on *that* size. |

Object count is the sharper knife. A 20 GiB pack of 50 million
objects is not “20 GiB of memcpy.” It is tens of millions of
tiny zlib streams, tens of millions of SHA-1 (or SHA-256)
object hashes, and tens of millions of delta applications.

Default SHA-1 in Git is **SHA-1DC** (collision detection), which
is slower than a raw SHA-1. SHA-256 repos hash more bytes per
object and a longer pack trailer. Every non-delta is hashed in
pass 1; every reconstructed delta is hashed in pass 2. That is
one full-content hash per object, plus the pack-level hash.

`pread` in pass 2 is not a sequential scan. `pack-objects`
clusters a window of similar objects, so OFS deltas are often
nearby and cache well. A huge pack that does not fit in the
page cache, REF deltas against distant bases, and cache-evicted
deep chains turn this into random reads across tens of
gigabytes.

---

## RAM: a metadata table per object, before any inflate cache

`cmd_index_pack()` does:

```c
CALLOC_ARRAY(objects, nr_objects + 1);
CALLOC_ARRAY(ofs_deltas, nr_objects);   /* worst-case size */
```

Each `object_entry` holds a `pack_idx_entry` (OID, CRC, offset)
plus size and type — on the order of **64 bytes**. Each
`ofs_delta_entry` is ~16 bytes, allocated for *every* object even
though only deltas use it. Then a pointer array for
`write_idx_file()`, plus `ref_deltas` grown to the REF-delta
count.

Order-of-magnitude for 50 million objects:

- `objects[]` ≈ 3 GiB
- `ofs_deltas[]` ≈ 0.8 GiB
- idx pointer array ≈ 0.4 GiB

That is already several gigabytes **before** the 96 MiB ×
`nr_threads` inflate cache, and before `patch_delta` output
buffers. On a machine that then swaps, “CPU-bound indexing”
becomes disk-bound. 32-bit Git historically died here entirely
(`1.5.3.6` RelNotes: index-pack choked on a huge pack). The pack
header’s object count is a 32-bit field, so a single pack cannot
exceed 4 G objects; the painful range is well below that.

---

## Threads help pass 2 only, and not much past a few cores

`--threads` / `pack.threads` apply to **delta resolution**, not
to `parse_pack_objects()`. Auto-detect caps hard at **20**, and
usually at `online_cpus()/2` (to ignore hyperthreads), never
below the old default of 3 (`jk/index-pack-w-more-threads`, Git
2.29). Experiments in-tree: going above 20 does not help.

Pass 2 shares one work stack and one base cache, guarded by
`work_mutex`. Taking a child, and sometimes reloading a pruned
base (`get_base_data()` inside the lock — called out as
NEEDSWORK in the source), is serialized. Collision checks and
fsck take `read_mutex`. So more cores do not give linear
speedup, and they **multiply** the base-cache budget
(`base_cache_limit = delta_base_cache_limit * nr_threads`),
which is RAM, not free parallelism.

Pass 1 remains one core, one inflate stream, one hash of the
pack.

---

## Writing the idx (and `.rev`) is extra, usually not the long pole

After every OID is known:

1. Sort all `nr_objects` OIDs (`QSORT` + `oidcmp` in
   `write_idx_file()`).
2. Write v2 idx: 256-entry fanout, OID table, CRC table, 32-bit
   offsets, optional 64-bit offsets for objects past 2 GiB,
   pack checksum, idx checksum. `FSYNC_COMPONENT_PACK_METADATA`.
3. By default also write a reverse index (`.rev`): another
   permutation, pack-order of the OID-sorted table
   (`pack.writeReverseIndex`, on unless `--no-rev-index`).
4. On `--stdin`, `fsync` the pack itself
   (`FSYNC_COMPONENT_PACK`) and rename `tmp_pack_*` to
   `pack-<hash>.pack`.

The sort is `O(n log n)` hash comparisons. For tens of millions
of objects that is noticeable, and the idx of a huge pack is
hundreds of megabytes, but it is still small next to
inflate + `patch_delta` + per-object hashing. The fsync of a
multi-gigabyte `--stdin` pack can be a real stall on some
filesystems; indexing a pack that is *already* named
`pack-<hash>.pack` skips that copy and that fsync.

---

## Flags and situations that add another full walk

Default `index-pack` already hashed every object. These make it
slower still:

| Extra | What it does |
|---|---|
| `--stdin` | Copy pack to a tempfile while hashing; fsync; rename. Bundle `unbundle()` always uses this. |
| `--fix-thin` | ODB lookups + deflate + append for missing REF_DELTA bases; pack hash changes. Cheap on a thick pack, expensive on a very thin one against a huge existing ODB. |
| `--fsck-objects` / `--strict` | Parse trees/commits/tags, run fsck, optionally walk links (`check_objects()`). Needs inflated content; this is why an “install a published idx” fast path must refuse fsck. |
| Collision check | If `odb_has_object()` is true, read the existing object and `memcmp` with the new bytes (`sha1_object()`). Empty clone: almost free. Fetch of a large overlapping pack into an already-huge repo: a second full read of every duplicate. |
| `--verify` | Rebuild as above and compare to the existing idx (`WRITE_IDX_VERIFY`). `git verify-pack` uses this. |
| `--promisor` | Record outgoing links; possibly `pack-objects` a follow-up promisor pack (`repack_local_links()`). |

---

## What usually is *not* the bottleneck

- **Writing the `.idx` format itself**, once OIDs are known.
- **`--fix-thin` on a thick pack.** The scan still runs; no
  bases are appended.
- **Network**, when the pack is already local. Then index-pack
  *is* the wait.
- **Ref updates / checkout.** Those start after the pack+idx
  exist. Checkout has its own cost, but it is a different
  command.

The progress bars that correspond to this document are
**Receiving objects** / **Indexing objects** (pass 1) and
**Resolving deltas** (pass 2). If the second one sits there on a
huge clone after the download has finished, that is expected:
the network is gone and the CPU is applying millions of deltas.

---

## Why a published `.idx` skips all of this

The publisher’s `pack-objects` / `index-pack` already performed
the inflate/hash walk. The idx they wrote *is* the OID table.
Installing `pack-<hash>.{pack,idx}` after a trailer match
(pack checksum ↔ idx trailer) is enough for `add_packed_git()`.
That check is milliseconds; it does not prove that offset N
contains object X (same trust model as dumb HTTP’s published
idx). Clients that set `transfer.fsckObjects` still need this
walk.

That is the clone-time motivation in
`bundle-uri-extended-to-include-idx.md` and
`packfile-uri-with-idx-extension.md`. The slowness described
here is exactly what those designs are trying not to repeat on
the client.

---

## Related reading in this tree

- `builtin/index-pack.c` — `parse_pack_objects()`,
  `resolve_deltas()`, `threaded_second_pass()`,
  `resolve_delta()`, `get_base_data()`, `conclude_pack()`.
- `Documentation/gitformat-pack.adoc` — why compressed size is
  absent; CRC32 and trailer hashes.
- `Documentation/config/core.adoc` — `core.deltaBaseCacheLimit`,
  `core.bigFileThreshold`.
- `bundle-uri-history-and-rationale-for-slow-reverify-on-the-client-side.md`
  — why bundle consume always runs `index-pack --stdin --fix-thin`,
  and why that is sequential with the CDN GET.
- `what-goes-into-a-bundle.md` — bundle = header + this same
  pack stream.
