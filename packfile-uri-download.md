# Parallel / hook-based packfile-URI downloads

A sketch for making `packfile-uris` downloads fast enough for
commit-closure CDN packs: discover the object size, then fetch it with
many parallel HTTP range requests. Also: whether that download step
can be a “hook.”

Builds on `commit-packfile-uri-design.md` (large prebuilt packs),
`thin-pack-and-packfile-uri.md` (URI pack must be local before
`--fix-thin`), and `packfile-uri-with-idx-extension.md` (install a
published `.idx` and skip client-side `index-pack`). Protocol
background: `Documentation/technical/packfile-uri.adoc` and
`Documentation/gitprotocol-v2.adoc`.

## Why this matters now

Today each URI is a **single sequential GET**. `do_fetch_pack_v2()`
spawns, one URI at a time:

```text
git http-fetch --packfile=<hash> --index-pack-arg=... <uri>
```

`http-fetch` calls `new_direct_http_pack_request()`, which opens
`objects/pack/pack-<hash>.pack.temp` and GETs the whole URL into it,
then `finish_http_pack_request()` pipes that tempfile through
`index-pack`. The only existing `Range` use is resume: if the tempfile
already has `N` bytes, libcurl is given `CURLOPT_RANGE` of `N-`
(`http_opt_request_remainder()`). There is no split, no parallelism
within one file, and `http.maxRequests` (default 5) is unused for this
path.

That is fine for the blob-URI MVP (one blob per URL). It is the wrong
shape for a commit-closure pack: one multi-gigabyte object on a CDN,
one TCP/TLS stream, one client core waiting on `index-pack` afterward.

The idx extension removes the `index-pack` scan from the critical
path. What remains is **getting the bytes**. CDN throughput for a
single GET is often a small fraction of what the same client can do
with many ranged GETs against the same URL (the aria2 / `curl
--parallel` / S3 multipart pattern).

`Documentation/technical/packfile-uri.adoc` already lists “Byte range
support” under protocol-changing future work, and “resumption of
clone” under work that needs no protocol change. Parallel ranges are
the same mechanism as resumption, just with many outstanding holes
instead of one suffix.

## Goal

For each advertised URI pack (and, separately, its small idx):

1. Learn the byte length, or learn that the server will not tell us.
2. If the server honors `Range` and the file is large enough, download
   it as many concurrent slices.
3. Reassemble into one file whose trailer matches the advertised
   `<pack-hash>`.
4. Hand that file back to the existing install path (`.keep`, optional
   published idx, packed-git refresh, then `--fix-thin` / connectivity).

No change to how upload-pack chooses URIs or how the inline pack is
generated. Blob URIs keep working; they simply do not benefit.

## Size discovery

Need two facts, not one: **length** and **whether ranges work**.

| Method | Length | Range proof | Extra RTT | Failure modes |
|---|---|---|---|---|
| HTTP `HEAD` | `Content-Length` | `Accept-Ranges: bytes` (advisory) | 1 | Some CDNs omit `HEAD`, lie about length, or strip `Accept-Ranges` |
| `GET` with `Range: bytes=0-0` | `Content-Range: bytes 0-0/TOTAL` | `206` is proof | 1 | Some origins ignore `Range` and send `200` + the whole file |
| First full `GET`, read `Content-Length` | yes, after start | unknown | 0 | Cannot shard from byte 0; at best open more streams for the tail |
| Advertise size on the Git wire | yes, before any HTTP | still unknown | 0 | Needs a protocol tweak; CDN may still refuse ranges |

Recommendation: **probe with a one-byte range**, not `HEAD`. `206` plus
a `Content-Range` total is the only cheap proof that sharding will
work. If the probe returns `200`, treat the body as the whole object
(or abort the probe if it starts streaming more than a tiny reply) and
fall back to today’s single GET. If it returns `403`/`405`/`416`,
fall back.

`HEAD` is a reasonable first try when the operator has already
measured that their CDN answers it correctly. Do not rely on it as
the only probe.

Advertising length on the wire is optional sugar: it saves the probe
RTT and lets the client preallocate. It does **not** replace the
`206` check. A size line that does not match the CDN is a hard error.

### Wire size (optional protocol addition)

Today:

```text
packfile-uri = PKT-LINE(hash SP uri LF)
```

The URI field may contain spaces, so a trailing size is ambiguous. A
leading sibling line, same style as the idx extension:

```text
size <pack-hash> <decimal-byte-length>
```

Example:

```text
packfile-uris
<pack-hash> https://cdn.example/base.pack
idx <pack-hash> https://cdn.example/base.idx
size <pack-hash> 4294967296
```

Client opts in with a token (`size`, next to `idx`) on the existing
`packfile-uris http,https,…` request line. Old clients never send it
and never see the line.

This is the protocol change `packfile-uri.adoc` was pointing at —
**advertising** size/range metadata — not the HTTP `Range` header
itself. Ranged GETs against a CDN URL need no Git-protocol change.

Server config can carry an optional length next to the URIs, or the
server can `HEAD` its own CDN object once and cache it. For an MVP
the operator who published the pack already knows the size.

## Parallel range download (built-in sketch)

Once length `L` is known and `206` worked:

1. Pick a slice size `S` (config, default on the order of 8–16 MiB)
   and a concurrency `N` (new `http.packfileUriMaxRequests` or reuse
   `http.maxRequests`; 5 is too timid for this, 32–64 is the usual
   CDN-friendly band, HTTP/2 multiplexing can share one connection).
2. Preallocate `objects/pack/pack-<hash>.pack.partial` to `L` (or
   write slices to `*.part-<i>` and concatenate; preallocate +
   `pwrite` is simpler and resume-friendly).
3. Issue `GET` with `Range: bytes=a-b` for each outstanding hole.
   Require `206` and a `Content-Range` that matches the request. A
   mid-transfer `200` is a protocol violation by the origin; abort
   that slice and retry as a single GET, or fail.
4. On success, the file is `L` bytes. Verify the pack trailer equals
   the advertised hash (same check `http-fetch` already does after
   `index-pack` prints `keep\t<hash>`).
5. Rename into `pack-<hash>.pack`, write `.keep`, install idx if
   present.

Resume of an interrupted clone is the same loop: stat the
`.partial`, treat already-present runs of `S` as filled (or keep a
sidecar bitmap of completed slices), fetch only holes. That is the
resumability item in `packfile-uri.adoc`, obtained for free.

The idx is tens of bytes per object. One GET. Do not shard it.

Fallback table:

| Situation | Behavior |
|---|---|
| File smaller than one slice | Single GET, as today |
| Probe is not `206` | Single GET |
| Any slice fails after retries | Fail the URI (do not silently stitch a short file) |
| Trailer ≠ advertised hash | Fail; delete `.partial` |
| `transfer.fsckObjects` | Download method unchanged; still run `index-pack --fsck-objects` on the result |

Implementation home if this stays in Git: `http-fetch --packfile=` /
`new_direct_http_pack_request()`. The caller in `fetch-pack.c` does
not need to know about slices. Overlap with the inline pack stays as
in the idx doc: parse `packfile-uris`, buffer the inline stream,
download/install URI pack(s), then `--fix-thin`.

## The hook idea

Speculation: do not put aria2-shaped machinery in Git. Make the
**download step** a hook. Git gives it enough information to fetch
the bytes and a contract for where those bytes must land. The hook
owns HEAD/probe, ranges, process pools, CDN-specific SDKs, etc.

### Verdict

**Feasible — but not as a `$GIT_DIR/hooks/` hook.** Feasible as a
**configured download helper**, in the same family as
`core.sshCommand`, `uploadpack.packObjectsHook`, and credential
helpers.

A traditional githook is the wrong insertion point:

- Clone is the important case. The destination repo’s
  `$GIT_DIR/hooks` is a fresh template, not where an org would
  configure a download accelerator.
- Githooks are repo-local policy gates (`pre-commit`, `pre-push`).
  This is a **transport** replacement and wants user / system /
  `/etc/gitconfig` scope, including during `git clone` before any
  local hook is interesting.
- `core.hooksPath` still would not help a clone of an arbitrary URL.

A config key is the right shape:

```text
fetch.packfileUriHelper = /usr/local/libexec/git-packfile-uri-helper
```

or a command-replacement style closer to `packObjectsHook`:

```text
fetch.packfileUriCommand = aria2c --optimize-concurrent-downloads …
```

Protected-scope rules (like `uploadpack.packObjectsHook`) are worth
borrowing if the helper can be set in a malicious repo’s config;
clone from an untrusted remote should not exec a helper that the
remote’s `.git/config` nominated. User and system config only, or
`includeIf` on the client side.

The subprocess boundary already exists: `fetch-pack` does not download
anything itself, it execs `http-fetch`. Replacing *that* child is a
small patch. The open question is the **contract**, not whether Git
can spawn a program.

### What the helper must not own

If the helper replaces `http-fetch --packfile=` wholesale, it inherits
today’s full job: download, run `index-pack` (or install a published
idx), print `keep\t<hash>\n`, optionally emit `.gitmodules` OIDs for
`parse_gitmodules_oids()`. That is a lot of Git-specific knowledge
for a download accelerator, and it forks again the idx-extension
install path.

**Keep the helper as a byte-fetcher.** Git keeps:

- choosing dest paths
- pack-trailer / idx-trailer checks
- `.keep` and `pack_lockfiles`
- `index-pack` vs published-idx
- `transfer.fsckObjects`
- packed-git refresh and `--fix-thin` ordering

The helper’s only success condition is: the dest path exists, is the
expected length if known, and is complete. Git will still hash-check
the trailer.

### Proposed contract (helper, not githook)

**Invocation.** One helper process per URI pack (simple), or one
process given every URI (better connection pool). Prefer one process
and stdin listing, so a single aria2/curl-multi pool can fetch pack
and idx together and can overlap several URI packs.

```text
# environment
GIT_DIR, GIT_OBJECT_DIRECTORY, GIT_PROTOCOL, …
# plus whatever Git already exports to children

# argv
$fetch.packfileUriHelper
```

**stdin** (credential-helper style `key=value`, one record per file,
blank line between records):

```text
hash=<pack-hash>
uri=https://cdn.example/base.pack
path=/path/to/objects/pack/pack-<hash>.pack.partial
size=4294967296          # omitted if unknown
kind=pack                # pack | idx

hash=<pack-hash>
uri=https://cdn.example/base.idx
path=/path/to/objects/pack/pack-<hash>.idx.partial
kind=idx
```

`path` is an absolute filename Git has chosen. The helper **writes
that file** (create/truncate or fill a preallocated file). It does
not rename into `pack-<hash>.pack`. It does not write `.keep`.

`size` is present when the wire advertised it or when Git already
probed. The helper may ignore it and probe itself. If both are
present and disagree after download, Git fails.

**stdout.** Progress and result, one line at a time:

```text
progress <hash> <bytes-so-far> <bytes-total-or-0>
ok <hash> <kind>
```

or, on failure, exit non-zero; Git unlinks the partials. No need to
print `keep\t` — that stays Git’s output from the install step, so
`do_fetch_pack_v2()`’s existing reader can move to “after helper +
install” or `http-fetch` becomes a thin wrapper: helper, then
verify/install, then `keep\t`.

**Exit codes.** `0` = every record written. Non-zero = Git aborts the
fetch (same as `http-fetch` dying today). No “partial success across
URIs” in the MVP.

**cwd.** Repository root or `$GIT_DIR`, same as other Git children.
Paths on stdin are absolute, so cwd does not matter.

### What Git must pass for the helper to actually work

This is the feasibility constraint.

CDN packs that are **public or pre-signed URLs** (the design we
want) need nothing but the URI. The helper can be aria2, a Go
downloader, or a cloud SDK. That path is clean.

CDN packs that need **the same credentials Git would use** are
awkward:

- `http.extraHeader`, cookies, `http.proxy`, `http.sslCAInfo`,
  `http.version`, credential helpers, negotiate/NTLM, `GIT_SSL_*`
- `Documentation/technical/packfile-uri.adoc` already lists
  “Additional HTTP headers (e.g. authentication)” as a protocol
  change. That is about the *Git server* adding authn to URI lines,
  not about the client helper seeing `http.*`.

A helper that shells out to `curl` will not automatically inherit
libcurl state from `http.c`. Options:

1. **Document that helpers are for unauthenticated or self-contained
   URLs** (signed query strings, public CDN). This matches the
   commit-packfile-URI story. Feasible, honest, sufficient for the
   feature.
2. Git writes a small sidecar (env or a second fd) listing relevant
   `http.*` keys and a resolved bearer token. Messy, easy to leak
   into `ps`/logs.
3. Git only offers a helper for the **byte pump**, and keeps its own
   downloader for authenticated `http://` / `https://` using the
   existing slot code.

Do (1) + a built-in ranged downloader for (3). The helper is an
escape hatch, not the only engine.

Other helper-shaped problems, all solvable:

| Issue | How to handle |
|---|---|
| Progress | `progress` lines on stdout; Git feeds `display_progress` |
| Cancel / Ctrl-C | Kill the helper; leave `.partial` for resume |
| Windows | Same as credential helpers; absolute paths |
| Tests | `fetch.packfileUriHelper` pointing at a `test-tool` that copies a fixture into `path` |
| Security | Ignore the key unless it comes from protected config |
| Multiple protocols | Helper is only invoked for `http`/`https`; unknown schemes still rejected by `fetch.uriprotocols` |

### Why this is still attractive

Git’s curl multi loop is built for **many independent objects**
(dumb HTTP, loose objects), not for **one object split into dozens
of ranges with resume metadata**. `http.maxRequests` default 5
reflects that. Getting “massive” parallelism right (HTTP/2 vs many
TLS sessions, slice size, fairness with the inline pack, resume
bitmaps) is a product of its own.

A helper lets that product live out of tree, be swapped per site
(`includeIf.gitdir`), and be implemented in a language with a
mature ranged-GET library. Git’s job shrinks to: name the files,
verify trailers, install, keep thin-pack order.

A built-in implementation can still be the default so clones work
with zero extra software. The two are not exclusive:

```text
                    packfile-uris parsed
                            │
              fetch.packfileUriHelper set?
                     /              \
                   yes               no
                    │                │
              spawn helper     built-in GET
              (probe+ranges    (today, then
               or aria2)        later: probe+ranges)
                    \              /
                     verify trailer
                     install pack[+idx]+keep
                     --fix-thin / connectivity
```

## Hook-shaped alternatives that are *not* worth it

- **`$GIT_DIR/hooks/packfile-uri-download`.** Wrong scope; skip.
- **Replace `http-fetch` binary via `PATH`.** Works today with no
  Git change, but the CLI (`--packfile` requires `--index-pack-arg`,
  stdout `keep\t`, index-pack child) is a hostile API for a
  downloader. Do not bless this.
- **Remote helper (`git-remote-https` rewrite).** Far too wide; it
  owns the whole smart HTTP conversation, not the CDN GET.
- **Long-running pkt-line process** (filter/process style). Only
  needed if we stream slices back to Git. We do not: the helper
  writes a file. Keep stdin records + stdout progress.

## Recommended shape

1. **Split download from install inside Git** (needed anyway for the
   idx extension). `http-fetch --packfile=` writes a complete pack
   file and verifies the trailer; a separate step installs
   `.pack`/`.idx`/`.keep` or runs `index-pack`. That split *is* the
   hook interface.
2. **Optional `size` line** on `packfile-uris` so the client can
   preallocate without probing. Token-gated, like `idx`.
3. **Built-in probe + parallel ranges** in `http-fetch` / `http.c`,
   gated on size and `206`. This is the default fast path and also
   implements clone resume. Reuse curl slots; raise the cap for this
   path separately from dumb-HTTP object fetching.
4. **Optional `fetch.packfileUriHelper`** with the file-placement
   contract above, protected-config only, intended for public/signed
   CDN URLs. Git still verifies and installs.
5. Do **not** add a githook.

(1) is a prerequisite of (3) and (4). (2) is small and useful to
both. (3) without (4) is already a complete feature. (4) without (3)
is also a complete feature if we accept “install aria2” as the way
to go fast. Both is the robust design: Git is fast out of the box,
and sites with a preferred downloader are not stuck inside libcurl.

## Feasibility summary

| Question | Answer |
|---|---|
| Can we go faster with size + parallel ranges? | Yes. The CDN already speaks HTTP; Git just does not shard. |
| Do we need a Git-protocol change to send `Range`? | No. We may want an optional `size` advertisement. |
| Is `HEAD` enough? | Sometimes. Prefer a one-byte `Range` probe; treat `HEAD` as optional. |
| Can this be a githook? | Poor fit (clone, scope, template hooks). |
| Can this be a configured helper? | Yes. Existing `http-fetch` child is the insertion point. |
| Should the helper install packs / run `index-pack`? | No. Bytes to a Git-chosen path; Git verifies and installs. |
| Hard part of the helper? | Auth/`http.*` inheritance. Restrict the helper to public or pre-signed URIs and keep a built-in downloader for the rest. |
| Does the helper block the idx / thin-pack work? | No. It is the download engine behind the same install-and-then-`--fix-thin` sequence. |

## Suggested sequence

1. Split `http-fetch --packfile=` into “get bytes + check trailer”
   and “install / index-pack / print `keep\t`.” Needed by the idx
   extension regardless.
2. Size probe + single-stream fallback (no parallelism yet). Tests
   for `HEAD`/`206`/`200` and trailer mismatch.
3. Parallel slices + `.partial` resume. Config for slice size and
   concurrency. Tests with a dumb HTTP server that serves ranges.
4. Optional `size <hash> <n>` protocol line (docs + token + emit +
   parse).
5. `fetch.packfileUriHelper` contract + `test-tool` helper + a
   protected-config check. Document public/signed-URL limitation.
6. Overlap URI download with buffering the inline pack (idx doc
   §6 / thin-pack doc). Independent of how bytes arrive.
