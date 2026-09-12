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
