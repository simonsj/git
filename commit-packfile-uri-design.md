# Commit-based packfile-URI design outline

This document summarizes how to extend Git’s experimental `uploadpack.blobPackfileUri` / `packfile-uris` feature so a **commit SHA** can stand in for a prebuilt pack served by URI, with upload-pack only dynamically generating the delta from that commit to the requested tips.

See also: `Documentation/technical/packfile-uri.adoc` (lists this under “Future work”).

## Goal

1. Prebuild a pack containing the full reachable closure of commit `C`.
2. Host that pack at a URI (e.g. CDN).
3. For a fetch/clone of tips `T`, compute objects for `T ^ C` (as if the client had sent `have C`).
4. Send a `packfile-uris` entry for the `C` pack, plus the small dynamic pack for the remainder.

## Why this fits existing machinery

upload-pack already feeds pack-objects wants and haves as:

```text
<want>...
--not
<have>...
```

pack-objects treats `--not` as `UNINTERESTING` and walks only the interesting side. A commit-based packfile URI is therefore less “filter each object against a map” and more “inject a synthetic have.”

## Why not extend `want_object_in_pack()`?

The current blob path looks up exact OIDs in `configured_exclusions`, returns 0 from `want_object_in_pack_mtime()`, and later emits one URI line per excluded blob.

Doing that for a commit would mean walking `C`’s entire closure into a giant oidset and testing every candidate object. That is memory-heavy, easy to get wrong with bitmaps/packed objects, and weaker for thin packs (you want `C` as a real uninteresting edge so deltas can use its objects as bases).

Reachability exclusion via `--not C` is the right primitive.

## Recommended design

### Config

```text
uploadpack.commitPackfileUri = <commit-oid> <pack-hash> <uri>
```

Operator builds the URI pack once:

```bash
git rev-list --objects <commit> | git pack-objects --stdout > base.pack
# publish base.pack; record its hash + URI in config
```

The pack must contain the **full object closure** of `C` (commits, trees, blobs), not just the commit object.

### Decision in `upload-pack` (before spawning pack-objects)

When the client requested `packfile-uris` with a matching protocol:

1. Load configured `(C, pack_hash, uri)` entries.
2. For each, decide whether it applies, e.g.:
   - **Apply** if `C` is an ancestor of some want.
   - **Skip** if the client already has `C` or a descendant of `C` (negotiation already covers it).
   - **Skip** if no want benefits (unrelated history), to avoid a useless download.
3. If it applies:
   - add `C` to the `--not` list sent to pack-objects (alongside real haves)
   - emit that pack’s `pack-hash uri` in the `packfile-uris` section

### Two ways to emit the URI

**Option A — upload-pack owns commit URIs (preferred for an MVP)**  
Keep blob URI emission in pack-objects. For commit bases, have upload-pack write the `packfile-uris` section itself, then run pack-objects with the synthetic `--not` and without `--uri-protocol` (normal `packfile` section).

**Option B — teach pack-objects a commit exclusion**  
New flag/config such as `--uri-commit=<oid> <pack-hash> <uri>`: pack-objects marks `C` uninteresting internally and writes the URI line like today’s excluded-blob output. upload-pack stays a thin relay.

### Thin packs

Keep `--thin`. With `--not C`, edge marking / preferred bases already let the dynamic pack delta against objects reachable from `C`. That is correct because the protocol requires the client to download and index URI packs before the inline pack.

## Correctness sketch

For tips `T` and base `C`:

| Set | Where it comes from |
|---|---|
| reachable from `T` but not from `C` | dynamic pack from upload-pack |
| reachable from both | URI pack (subset of `C`’s closure) |
| reachable from `C` only | URI pack (extra; unused for tip checkout) |

The client ends up with everything needed for `T`. No protocol change is required — only server policy for when to send URIs and what to put under `--not`.

## Practical caveats

1. **Ancestor gating matters.** Blindly always adding `--not C` + URI is wasteful on unrelated refs or already-negotiated fetches.
2. **Multiple bases.** Several snapshot commits can be supported; pick the newest applicable ancestor of the wants (or all applicable ones for layered CDN packs).
3. **History rewrite / force-push.** If `C` disappears from advertised history, config is stale; fall back to a full pack.
4. **Shallow / partial clone.** Synthetic haves can interact poorly with deepen and `--filter`; start with non-shallow full clones/fetches.
5. **Don’t reuse the blob OID map for this.** Blob filtering and commit-boundary exclusion are different problems; commit-based serving should go through the rev-walk.

## Minimal change map

1. **Config** — Parse `uploadpack.commitPackfileUri` in upload-pack; advertise `packfile-uris` when present (same trigger pattern as blob config).
2. **`create_pack_file()` / caller** — If a base commit applies, append `C` after `--not` and emit the corresponding URI in the `packfile-uris` section.
3. **pack-objects** — Ideally unchanged for Option A (upload-pack-owned commit URIs).
4. **Ops** — Prebuild closure packs with `rev-list --objects` + `pack-objects`; refresh when cutting a new CDN snapshot.
5. **Tests** — Extend `t/t5702-protocol-v2.sh` (or sibling): clone gets URI + small pack; fetch when the client already has `C` sends no URI.
