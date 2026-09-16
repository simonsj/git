# What goes into a Git bundle file?

A bundle is a small **text header** followed by a **packfile**. That
is the entire format. There is no pack index (`.idx`) in the file,
no reverse index, and no extra trailer after the pack.

Canonical spec: `Documentation/gitformat-bundle.adoc`. Writer and
reader: `bundle.c` (`create_bundle()`, `read_bundle_header_fd()`,
`unbundle()`). Pack bytes: `Documentation/gitformat-pack.adoc`.

How this payload shows up on a CDN vs a bundle *list* is in
`bundle-payloads-explained.md`. Why the client then rebuilds an
idx, and why a published idx could skip that, is in
`bundle-uri-history-and-rationale-for-slow-reverify-on-the-client-side.md`.

---

## Short answers

**What is in a `.bundle`?** A signature line, optional v3
capabilities, prerequisite OIDs, tip refs, a blank line, then a
normal Git pack (`PACK` … objects … pack checksum). The pack is
exactly the stream `git pack-objects --stdout --thin
--delta-base-offset` would emit for those tips and exclusions.

**Can that same stream also carry the corresponding `.idx`?**
Not in today’s format, and not in a way old Git would *use*. The
bytes after the blank line must be a pack and nothing else.
`unbundle()` always runs `git index-pack --stdin --fix-thin`,
which *builds* `pack-<hash>.idx` from the pack. You can publish
the idx as a **sidecar** (a second URI) without touching the
bundle file; stuffing it into the bundle itself needs a new
format or a wrapper, and both need new clients.

---

## Layout on disk

v2 (SHA-1 only):

```text
# v2 git bundle
- <prereq-oid> <optional comment>
<tip-oid> refs/heads/main
<tip-oid> refs/tags/v1.0
                             ← blank line ends the header
PACK\0…                      ← ordinary packfile through its trailer
```

v3 (required for SHA-256 and for `--filter`):

```text
# v3 git bundle
@object-format=sha256
@filter=blob:none
- <prereq-oid> <optional comment>
<tip-oid> refs/heads/main

PACK\0…
```

ABNF from the spec, slightly condensed:

```text
v2:  "# v2 git bundle" LF  *prerequisite  *reference  LF  pack
v3:  "# v3 git bundle" LF  *capability    *prerequisite  *reference  LF  pack
```

`read_bundle_header_fd()` reads lines until a blank one, then
leaves the fd sitting on the first byte of `PACK`. Everything
from there to EOF is handed to `index-pack`.

`git bundle create` writes those pieces in order (`bundle.c`):

1. Signature (`# v2 git bundle\n` or `# v3 git bundle\n`).
2. v3 only: `@object-format=<algo>` and, if a filter was
   requested, `@filter=<spec>`.
3. Prerequisite lines from the revision walk’s boundary commits.
4. Tip lines from the named refs (at least one; empty bundles
   are refused).
5. A single `\n`.
6. `pack-objects --stdout --thin --delta-base-offset`, with the
   pending OIDs (and `^` exclusions) on its stdin.

If the path is `-`, that whole sequence goes to stdout. There is
no second file.

---

## The header, line by line

### Signature

Must be exactly `# v2 git bundle` or `# v3 git bundle` plus LF.
Anything else is not a bundle. `is_bundle()` is this parse;
bundle-uri uses it to tell a bundle from a config list.

### Capabilities (v3 only)

`@key` or `@key=value`. Unknown keys are **fatal**: there is no
negotiation, so `git bundle` aborts (`gitformat-bundle.adoc`).
Today only:

| Capability | Meaning |
|---|---|
| `object-format` | Hash algorithm (`sha1` / `sha256`), same values as `extensions.objectFormat`. Default for v2 is SHA-1. |
| `filter` | Object filter as in `git rev-list --filter`. After unbundle the pack is marked `.promisor`. |

These are ASCII. They are not a place to stash binary metadata.

### Prerequisites

`-` + object id, optional SP + comment, LF. The comment is
usually the one-line subject; readers must ignore it.

These are objects the pack **does not contain** and the reader
**must already have**. Deltas in the pack may be against them
(that is why unbundle always passes `--fix-thin`). A *thick*
clone bundle (`git bundle create repo.bundle --all` with no
`--since` / range exclusions) has an empty prerequisite list.

Prerequisites are not a shallow-clone boundary. v2 cannot
represent a shallow repo.

### References

`oid SP refname` LF. These are the tips the reader can fetch
from the bundle — what becomes `refs/bundles/*` on the
bundle-uri path, or ordinary refs when you `git clone` /
`git fetch` a bundle file directly.

Objects that sit in the pack but are not named here are
invisible to later negotiation. The header is the ref
advertisement; the pack is the object payload.

### Blank line

Required. Parser stops. Pack starts.

---

## The pack (everything after the blank line)

Same bytes as `$GIT_DIR/objects/pack/pack-<hash>.pack`:

```text
4-byte  "PACK"
4-byte  version (Git writes 2)
4-byte  object count (network order)
        N object entries (type/size, then zlib data;
        OBJ_OFS_DELTA / OBJ_REF_DELTA allowed)
hashsz  pack checksum of all of the above
```

That is `gitformat-pack.adoc`. The checksum is SHA-1 or SHA-256
to match the bundle’s object-format.

`--thin` is always on when writing. For a thick bundle it is a
no-op: there are no excluded bases, so every delta base is in
the pack. For an incremental bundle (`master~10..master`,
`--since=…`) the pack may omit bases the reader is assumed to
have; `--fix-thin` on the client copies those bases in and
**rewrites the pack hash**.

`--delta-base-offset` prefers `OBJ_OFS_DELTA` (relative offset)
over `OBJ_REF_DELTA` (base OID). That is a pack encoding choice,
not extra bundle metadata.

`--stdout` means pack-objects streams the pack into the bundle
and does **not** install `pack-<hash>.{pack,idx}` in the
writer’s object database. Creating a bundle does not leave a
sibling idx on disk. Whoever wants an idx of the inner pack
must `index-pack` those pack bytes themselves (or write a pack
file some other way and wrap it).

---

## What is *not* in a bundle

| Thing | Why it is absent |
|---|---|
| `pack-<hash>.idx` | Derived lookup table. Built on consume by `index-pack`. |
| `pack-<hash>.rev` | Reverse index; optional, also derived. |
| `pack-<hash>.mtimes` | cruft-pack only. |
| `packed-refs` / loose refs | Replaced by the header’s reference lines. |
| Repo config, hooks, worktree | Bundle is refs + objects, not a full `$GIT_DIR`. |
| A checksum of the *bundle file* | Integrity is the inner pack trailer (and, after index-pack, the idx trailer). |

The idx that “corresponds” to a bundle is an index of the
**inner pack** (offsets measured from the `PACK` magic), not of
the bundle file. The header’s variable-length text would make a
bundle-file idx a different object.

Git cannot use a pack in `objects/pack/` without an idx. That
is why unbundle always creates one:

```text
read_bundle_header()          → fd at PACK
verify_bundle()               → prereqs exist (no-op if none)
git index-pack --stdin --fix-thin
                              → writes pack-<hash>.pack
                                *and* pack-<hash>.idx
```

(`bundle.h`: “We’ll invoke `git index-pack --stdin --fix-thin`
for you.”) `--filter` adds `--promisor=from-bundle`.
`transfer.fsckObjects` adds `--fsck-objects`.

---

## Can the idx ride in the same stream / payload?

Three different questions get mixed together. They have different
answers.

### 1. In today’s `.bundle` file: no

The spec is `header LF pack`. After the blank line the next four
bytes must be `PACK`. There is no length-prefixed sidecar, no
second section, no “idx follows” capability.

`git bundle create` never writes an idx into that file.
`git bundle unbundle` never looks for one.

### 2. Smuggle it into the existing format anyway?

**v3 capability.** No. Capabilities are `@key=value` text.
Unknown keys abort the whole bundle, so you cannot add
`@idx=…` without breaking every current v3 reader. A multi-megabyte
binary idx does not belong on a header line in any case.

**Bytes before `PACK`.** No. `index-pack` would not see a pack
header. Every existing client fails.

**Bytes after the pack trailer.** The pack is self-contained once
you have walked every object (count is in the 12-byte pack
header; each object is variable-length compressed, so you cannot
skip to the trailer without parsing). Trailing junk is not part
of the pack.

`index-pack --stdin` stops at the pack checksum. It may
over-read into a 128 KiB buffer (`DEFAULT_IO_BUFFER_SIZE`), then
dumps that leftover to **stdout**. `unbundle()` sets
`no_stdout`, so those bytes are discarded. Anything still unread
on the fd is left behind. A current client will usually *succeed*
on a bundle-with-junk-appended and simply ignore the junk. It
will not install it as an idx.

A new client could, in principle, splice “pack then idx” if it
knew the split. Finding that split without a length in the
header means parsing the whole pack — which is most of the
work you were trying to avoid — or putting `@pack-size=` /
`@idx-size=` in v3, which old clients reject. And for thin
bundles `--fix-thin` changes the pack hash, so a pre-fix idx is
the wrong file.

So: appending is tolerated as garbage, not specified as a
feature, and does not help old or new clients skip `index-pack`
without extra framing.

**A new signature (`# v4 git bundle`) or a wrapper (tar,
multipart, custom mux).** Possible as a *new* payload. Old
`git bundle` rejects the signature. bundle-uri’s sniff is only
“v2/v3 bundle, else config list, else ignore”
(`bundle-payloads-explained.md`). A wrapped body is neither, so
today’s clone/fetch would skip it and fetch from origin. You
would still be writing a new format and a new consume path.

### 3. Same HTTP GET, not the same file: still a new payload

bundle-uri downloads a URI and sniffs the body. If you want one
GET to carry pack + idx, you are inventing payload type 3. Old
clients will not take the fast path; they will either unbundle
the pack and ignore trailing bytes (append case) or fail the
sniff (wrapper case).

The idx-of-inner-pack is also the wrong thing to concatenate
*as a bundle-file idx*: offsets are from `PACK`, not from byte
0 of the download.

### What actually works: sidecar, not stuffing

Keep the bundle file as it is. Publish the idx that
`index-pack` would have built for the inner pack, as a second
object:

```text
bundle.<id>.uri = https://cdn.example/base.bundle
bundle.<id>.idx = https://cdn.example/base.idx
```

New clients that opt in can `lseek` past the header, check
trailers, and install `pack-<hash>.{pack,idx}` without
`index-pack`. Old clients ignore the unknown list key and
unbundle as today. That is the point of
`bundle-uri-extended-to-include-idx.md`: **do not change the
bundle file format.** Limit the fast path to thick bundles
(empty prerequisite list), because `--fix-thin` would invalidate
the published idx.

Bare pack+idx without a header is not a drop-in replacement
either: you would still need the tip refs (and any
prerequisites) from somewhere — the bundle header, or list keys
such as the reserved `oid=` / `prerequisite=` sketched in
`gitprotocol-v2.adoc`.

---

## Operator view

```bash
# Thick snapshot: header + complete pack. No "-" lines.
git bundle create base.bundle --all

# Incremental: header names prereqs; pack may be thin.
git bundle create daily.bundle master~10..master
```

Verify / inspect without touching the object database:

```bash
git bundle verify base.bundle     # header + prereq connectivity
git bundle list-heads base.bundle # the reference lines
```

To *get* the idx that matches the inner pack today, extract and
index it (the client already does the second step on every
unbundle):

```bash
# After the header, the rest is a pack:
git index-pack --stdin < pack-bytes-from-bundle
# → objects/pack/pack-<hash>.pack and pack-<hash>.idx
```

The `.idx` is a v2 pack index (`\377tOc` magic): fan-out, sorted
names, CRC32s, offsets, copy of the pack checksum, idx
checksum. It does not contain objects. It is what makes “is OID
X in this pack, at what offset?” O(log n) instead of a linear
inflate.

---

## Takeaway

A bundle file is **refs + objects** encoded as **text header +
pack**. The matching `.idx` is a derived companion of that pack,
produced on the reader by `index-pack`, not stored in the
bundle. Putting the idx in the same byte stream means a new
format or a wrapper; today’s readers will not consume it as an
idx. Shipping it next to the bundle (second URI, same inner-pack
hash) keeps the existing file valid and is the only approach
that old clients can ignore safely.
