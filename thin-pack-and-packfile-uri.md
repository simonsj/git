# Thin packs and why URI packs come first

Answers to two questions raised by `commit-packfile-uri-design.md`:

> Keep `--thin`. With `--not C`, edge marking / preferred bases already let
> the dynamic pack delta against objects reachable from `C`. That is correct
> because the protocol requires the client to download and index URI packs
> before the inline pack.

## What is a thin pack?

A **thin pack** is a packfile whose deltas are allowed to name **base
objects that are not stored in that same pack**. Those missing bases are
assumed to already exist at the receiving end.

Git usually stores an object either in full, or as a delta against another
object (the *base*). In a normal on-disk pack, every delta base must also
be in that pack so the file is self-contained. A thin pack drops that
rule: a `REF_DELTA` can point at an object the receiver already has (or
is about to have from another pack). The sender therefore omits those
common / uninteresting objects and only ships the remainder.

That is why fetch and push use `--thin`: after negotiation, the client
already has the shared history, so the server can emit deltas against
those objects instead of resending them. The same idea appears in
bundles created with revision exclusions.

A thin pack is not a valid stored pack by itself. The receiver must
**thicken** it — typically with `git index-pack --fix-thin` — by copying
the missing bases into the pack so it becomes self-contained. A client
that cannot do that must not request the `thin-pack` capability.

Canonical wording from `Documentation/gitprotocol-capabilities.adoc`:

> A thin pack is one with deltas which reference base objects not
> contained within the pack (but are known to exist at the receiving
> end).

`pack-objects --thin` implements this by treating objects marked
`UNINTERESTING` (the `--not` / have side) as **preferred bases**: they
may be used as delta bases, but they are not written into the pack. With
`--not C`, anything reachable from `C` becomes such a base.

## Why download and index URI packs before the inline pack?

Two packs are in play:

| Pack | What it contains |
|---|---|
| **URI pack** | Prebuilt pack at a CDN (or similar). In the commit-based design, this is the full object closure of commit `C`. |
| **Inline pack** | The `packfile` section of the fetch response — the dynamically generated remainder (`T ^ C`). |

The server is allowed to send a **thin** inline pack whose delta bases
live only in the URI pack. That is the whole point of `--thin` plus
`--not C`: new objects can be encoded against trees and blobs already
present in `C`’s closure, without putting those objects in the inline
pack.

A thin pack’s contract is that those bases “exist at the receiving end”
by the time the receiver resolves or thickens it. On a clone the client
does not already have `C`. The only place those bases come from is the
URI pack. So the client must download and index the URI pack **before**
it can:

1. Resolve `REF_DELTA` entries in the inline pack whose bases are in `C`.
2. Run `index-pack --fix-thin` on the inline pack (it looks up missing
   bases in the local object store and copies them in).
3. Pass the connectivity check that every fetched tip is fully reachable.

If the inline pack were indexed first, `--fix-thin` would see unresolved
deltas and fail: the bases are not in the inline pack and not yet in the
ODB.

That is also why the protocol talks about URI packs in those terms.
`Documentation/technical/packfile-uri.adoc` says clients must download
and index the URI packs **and** the inline pack **before the connectivity
check**. `Documentation/gitprotocol-v2.adoc` says the same: download from
all given URIs before the connectivity check. The design document’s
stronger “URI packs before the inline pack” statement is the thin-pack
consequence of that rule: the URI objects have to be local *before* the
inline pack is treated as something the client already has the bases for.

The current blob-based `uploadpack.blobPackfileUri` path is weaker here.
It omits configured blobs from the sent pack and emits a URI for each,
but it does not mark them `UNINTERESTING`, so pack-objects does not treat
them as real thin-pack bases. The current client therefore streams and
indexes the inline pack first, then fetches the URI packs, and only then
runs the connectivity check. That works for “here is a blob, go get it
elsewhere.” It would not be enough if the inline pack were allowed to
delta against those excluded objects.

The commit-based design *does* inject `C` as a real `--not` edge, so the
dynamic pack may be thin against the URI pack. That is only correct if
the client has already downloaded and indexed the URI pack — which is
what the protocol requires the client to be able to do before it relies
on the inline pack.

## Can the server send an index and skip client-side indexing?

The previous section said the client must “download and index” the URI
pack before it can thicken the inline pack. Those are two different
jobs, and only one of them is strictly required for `--fix-thin`.

### What `--fix-thin` actually needs

`index-pack --fix-thin` does not scan the URI pack. For each unresolved
`REF_DELTA` in the *inline* pack it calls `odb_read_object()` on the
base OID (`builtin/index-pack.c`, `fix_unresolved_deltas()`). That is
an ordinary object-database lookup:

1. Find which local pack (or loose object) contains that OID.
2. Read and inflate the bytes.
3. Copy the reconstructed object into the inline pack so the thin pack
   becomes self-contained.

Step 1 is the constraint. Git’s object database discovers packs by
their **`.idx` files**, then opens the matching `.pack`
(`add_packed_git()` refuses a path that is not an `.idx`). A `.pack`
sitting in `objects/pack/` with no index is invisible. There is no
OID-to-offset map, so `odb_read_object()` cannot find a base that lives
only in that pack.

So “index the URI pack” here means **make the URI pack’s objects
lookupable by OID**. Computing a fresh `.idx` on the client is one way
to do that. It is not the only way.

You cannot skip *having* an index. You can skip *generating* it, if
someone hands you a usable one.

### A server-supplied `.idx` is enough for lookup

The URI pack is prebuilt. The operator who ran `pack-objects` already
has (or can keep) the corresponding `pack-<hash>.idx` that
`index-pack` would have written. That file is a deterministic
OID-to-offset table plus CRC32s and a trailer that repeats the pack
checksum (`Documentation/gitformat-pack.adoc`).

A workable scheme:

1. Host `base.pack` and `base.idx` (CDN, or a second URI).
2. Advertise the pack hash as today (`<pack-hash> <uri>`).
3. Client downloads both, checks that the pack trailer equals the
   advertised hash and that the idx trailer names that same pack
   checksum.
4. Install them as `objects/pack/pack-<hash>.{pack,idx}` (plus a
   `.keep` so `gc` does not delete them before refs move).
5. Refresh the packed-git list.
6. Run `index-pack --fix-thin` on the inline pack. Bases in `C` now
   resolve through the installed idx.

This is not hypothetical. Dumb HTTP already works that way:
`git http-fetch` downloads published `pack-*.pack` **and** `pack-*.idx`
and does not regenerate the index. The current `packfile-uris` client
does the opposite: `http-fetch --packfile=` always pipes the download
through `index-pack` and never fetches an idx.

The idx is small relative to the pack (on the order of a few dozen
bytes per object). Sending it from upload-pack itself, rather than the
CDN, would still be cheap. Serving it next to the pack on the CDN
needs either a naming convention (`<pack-uri>.idx`) or a protocol
extension (today’s `packfile-uris` line is only `<hash> <uri>`).
`Documentation/technical/packfile-uri.adoc` already lists “different
file formats referenced by URIs” as something that would need a
protocol change.

Alternatives that avoid an idx are worse, not better: unpacking the URI
pack into loose objects, or linearly scanning the pack on every lookup,
are just more expensive ways of building the same map.

### What you give up if you skip `index-pack`

Lookup and verification are different.

`index-pack` does not only write an `.idx`. It walks every object,
resolves internal deltas, and checks that the inflated content hashes
to the claimed OID. After that, Git treats the pack as trusted and does
not re-hash on every later read.

A downloaded idx can be self-consistent (its own checksum is valid, its
trailer names the advertised pack) and still be a **lie about the
pack**: the OID-to-offset table is not cryptographically bound to the
bytes at those offsets. The only way to prove the idx describes that
pack is to scan the pack — i.e. index it, or run `verify-pack` /
`index-pack --verify`.

`--fix-thin` does re-check `check_object_signature` for each **base it
copies into the inline pack**. Those particular objects get verified.
Everything else taken from the URI pack later (checkout, merge,
connectivity) inherits the weaker “we trusted the publisher’s idx”
model.

So: **yes, you can skip client-side indexing for the purpose of
thickening the inline pack**, if you install a server-supplied idx.
You should not treat that as a substitute for integrity checking unless
you trust the CDN and the operator the way dumb HTTP already does.

#### When does `verify-pack` / `index-pack --verify` usually run?

Almost never as part of clone, fetch, or `packfile-uris`. They are
on-demand checkers for an *existing* pack+idx pair, not the transfer
path.

`git verify-pack` is a thin wrapper: it execs `git index-pack --verify`
(or `--verify-stat`) on each named pack (`builtin/verify-pack.c`).
`index-pack --verify` requires a pack filename and an already-written
`.idx`. It re-walks the pack, rebuilds the index in memory, and checks
that it matches the file on disk (`WRITE_IDX_VERIFY` in
`builtin/index-pack.c`). That is exactly the “prove this idx describes
this pack” scan the previous paragraphs talked about.

Nothing in `fetch-pack`, clone, or `http-fetch --packfile=` invokes
that mode. The verification that *does* run on a normal fetch or clone
is ordinary `index-pack` (no `--verify`): it *creates* the `.idx` while
hashing every object. Same class of work, different command. For
packs below `fetch.unpackLimit`, the client uses `unpack-objects`
instead, which also reconstructs and hashes objects, just as loose
objects rather than a pack+idx.

The other automatic cousin is `git fsck` ( `--full` is the default).
That calls the library `verify_pack()` in `pack-check.c` and walks
every local pack. It is a maintenance/fsck pass, not something fetch
runs. Admins and the test suite also call `git verify-pack` by hand
after a repack or when hunting corruption.

So if the client installs a server-supplied idx and skips `index-pack`,
**no existing Git path will spontaneously re-verify that pair** unless
someone later runs `git verify-pack`, `git index-pack --verify`, or
`git fsck`.

#### Can the usual `verify-pack` / `index-pack --verify` be disabled?

There is nothing to disable on the fetch/clone client: those commands
are not the usual path. No config key turns them on or off during
transfer.

What you can turn off, or already have off:

- **`transfer.fsckObjects` / `fetch.fsckObjects`** default to false.
  When true, fetch/clone pass `--fsck-objects` (or `--strict`) to
  `index-pack`. That is extra semantic checking (malformed objects,
  `.gitmodules`, and the rest of `fsck.<msg-id>`), not “does this idx
  match this pack?” Leaving them unset already skips that extra pass.
- **`git fsck --no-full`** or **`--connectivity-only`** skips or
  narrows the pack-content walk if you are running fsck yourself.
- There is no `fetch.verifyPack` (or similar) that means “after
  download, run `index-pack --verify`.”

You *cannot* disable the hash-every-object work of a normal
`index-pack` that is *building* an idx. Creating the index *is* that
scan. The only way to skip it is to not run `index-pack` at all —
which is the server-supplied-idx scheme. In that scheme the client
would opt in to a later `verify-pack` / `index-pack --verify` if it
wants the binding proof back; that step would be optional and, today,
manual.

### Clone versus fetch

The lookup rule is the same in both cases: `odb_read_object()` can use
a base only if that OID is already in the local ODB — loose, in some
existing pack+idx, or in the newly installed URI pack+idx. Clone versus
fetch changes **whether any of those bases are already local**, not
whether a new URI pack can be used without an idx.

**From-scratch clone (empty object store).**
Nothing is local. Every thin-pack base that `--not C` omitted lives
only in the URI pack. The client must have that pack *and some idx for
it* (computed or downloaded) before `--fix-thin` can succeed. The same
idx is required before the connectivity check, because objects in
`reachable(T) ∩ reachable(C)` are not in the inline pack at all; they
are the reason the URI pack was sent. Skipping client-side
`index-pack` is most tempting here (the URI pack is large; indexing is
CPU and I/O) and also the biggest integrity bet: this pack *is* the
new repository’s history.

**Fetch into an existing workspace.**
Negotiation may already have marked real haves. `--fix-thin` searches
the whole ODB, not “the URI pack only,” so any base the client already
has does not need the URI pack. Two consequences:

1. If the client already has `C` or a descendant, the design should
   not send a URI at all. There is nothing to index.
2. If the client lacks `C` but already has some of `C`’s closure
   (related branches, earlier partial history), some inline-pack bases
   resolve from existing packs. `--fix-thin` can succeed **without**
   the URI pack if *every* unresolved `REF_DELTA` base happens to be
   local. The URI pack is still required before the **connectivity**
   check for omitted objects the client does not have.

So on fetch you can sometimes thicken the inline pack first and only
then install the URI pack. On clone you cannot. In neither case can
you use a URI `.pack` with no `.idx`. A server-supplied idx substitutes
for client-side indexing equally well in both; fetch merely offers an
extra escape hatch when local state already covers the thin bases.

### Short answers

| Question | Answer |
|---|---|
| Must we *download* the URI pack before thickening the inline pack? | On clone, yes (those bytes are the missing bases). On fetch, only if some thin-pack base is not already local. |
| Must we *compute* an idx on the client? | No. A trustworthy idx from the server/CDN is enough to make the pack lookupable. |
| Must we *have* an idx before `--fix-thin`? | Yes, for every URI-pack object that `--fix-thin` or connectivity will ask for. Git will not see a pack without one. |
| Does clone vs fetch change that? | Clone has no local bases, so the URI pack+idx is on the critical path for both `--fix-thin` and connectivity. Fetch can thicken from existing objects and can skip the URI entirely when `C` is already had; it still needs an idx for any new URI pack it does install. |
| When does `verify-pack` / `index-pack --verify` usually run? | It doesn’t, on clone/fetch/`packfile-uris`. Those commands re-check an existing pack+idx on demand (`verify-pack` just runs `index-pack --verify`). Fetch/clone instead run plain `index-pack` to *create* the idx. `git fsck` walks packs later via `verify_pack()`. |
| Can the usual `verify-pack` / `index-pack --verify` be disabled on the client? | There is nothing to disable: fetch/clone never run them. `fetch.fsckObjects` is a separate, default-off semantic check. You cannot turn off the scan inside an `index-pack` that is building an idx; skipping that command (and installing a server idx) is what skips the scan. A later `verify-pack` would be optional and manual. |
