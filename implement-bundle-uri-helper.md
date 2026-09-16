# Plan: `fetch.bundleUriHelper`

Implement **only** the optional download helper from
`bundle-uri-extended-to-include-idx.md` (“Download helper”). Git already
downloads each advertised URI through `copy_uri_to_file()` in
`bundle-uri.c`. This work replaces that GET with an external byte-fetcher
when the user opts in.

This is **not** the sidecar-`.idx` fast path, **not**
`fetch.packfileUriHelper`, and **not** a built-in ranged downloader.
Those stay later patches. The helper contract is written so a later idx
(or packfile-uri) helper can speak the same stdin language.

## Goal

A user or admin can set:

```text
fetch.bundleUriHelper = /usr/local/libexec/git-bundle-uri-helper
```

When that key is present in **protected configuration**, Git stops using
`git-remote-https` `get` (and does not use libcurl itself) for
`http://` / `https://` bundle-URI downloads. The helper writes the dest
file Git names. Git still decides whether the bytes are a bundle or a
bundle list, still calls `unbundle()`, still writes `refs/bundles/*`,
and still falls back to the origin fetch if that URI fails.

Unset helper → today’s `copy_uri_to_file()` unchanged.

## Non-goals (this patch series)

- `bundle.<id>.idx`, `transfer.bundleURIIdx`, synthesis of `.idx` URLs,
  or skipping `index-pack`.
- Parallel `Range` GETs inside Git.
- Forwarding `http.*` credentials, cookies, or extra headers into the
  helper. Helpers are for **public or pre-signed** CDN URLs. Authenticated
  Git-HTTP stays on `git-remote-https`.
- A `$GIT_DIR/hooks/` hook. Clone’s hook directory is a template;
  this is transport config, not a repo policy hook.
- Batching several URIs into one helper process. Today’s consume path
  downloads one URI, then inspects it (`is_bundle()` vs config list),
  then recurses. Batching needs the idx work (Git then knows both URIs
  up front). The **stdin format** still allows multiple records so that
  later patch does not bump the helper.

## Why this is the right slice

`copy_uri_to_file()` is already the single choke point for every bundle
URI consume path:

| Caller | How it gets here |
|---|---|
| `git clone --bundle-uri=` | `builtin/clone.c` → `fetch_bundle_uri()` |
| protocol-v2 advertised list | `transport_get_remote_bundle_uri()` → `fetch_bundle_list()` |
| incremental `fetch.bundleURI` | `builtin/fetch.c` → `fetch_bundle_uri()` |

All three end in `fetch_bundle_uri_internal()` → `copy_uri_to_file()`.
HTTP uses `download_https_uri_to_file()` (`git-remote-https` `get`);
`file://` and plain paths use `copy_file()`. One helper branch in
`copy_uri_to_file()` covers clone, fetch, and v2 advertise without
touching those callers.

## Config

**Key.** `fetch.bundleUriHelper` (docs camelCase; lookup is
case-insensitive `fetch.bundleurihelper`).

**Value.** A **shell command**, same family as `core.sshCommand` and
`uploadpack.packObjectsHook`. Git does **not** append extra argv (unlike
`packObjectsHook`, which appends `git pack-objects …`). Typical values:

```text
fetch.bundleUriHelper = /usr/local/libexec/git-bundle-uri-helper
fetch.bundleUriHelper = /usr/bin/my-cdn-get --profile=clone
```

Use `git_config_string()`, not `git_config_pathname()`. Spawn with
`use_shell = 1`.

**Scope.** Protected configuration only (`git_protected_config()`, same
pattern as `uploadpack.packObjectsHook` in `upload-pack.c`):

- Honored: system, global/`includeIf`, command-line `-c` /
  `GIT_CONFIG_COUNT`.
- Ignored: `$GIT_DIR/config` and `config.worktree`.

This is load-bearing. A later `git fetch` in a repo whose `.git/config`
was written by an untrusted clone must not exec a helper the remote
nominated. `read_protected_config()` already sets `ignore_repo` /
`ignore_worktree` and still reads command-line config, which is what
the tests want (`git -c fetch.bundleUriHelper=… clone …`).

**Schemes.** Invoke the helper only for `http://` and `https://`.
`file://` and plain paths keep `copy_file()`. A helper that only
understands HTTP must not break `git clone --bundle-uri=./local.bundle`.

**Caching.** Read once per process via `git_protected_config()` into a
static `char *`. Do not re-parse on every URI in a list.

## Helper contract

Git is the parser/installer. The helper is a **byte-fetcher**. Success
means: every dest `path` exists, is complete, and is the advertised
`size` when that field was sent.

### Invocation

```text
argv:   $fetch.bundleUriHelper     # via the shell; no extra args
cwd:    whatever Git’s other children use (repo / $GIT_DIR)
env:    normal Git child env (GIT_DIR, GIT_OBJECT_DIRECTORY, …)
stdin:  records (below)
stdout: machine lines (below); Git drains this pipe
stderr: inherited; human progress and diagnostics
exit:   0 = every record written; nonzero = this URI failed
```

Git currently spawns **one helper process per URI** and writes **one
record**. Helpers **must** accept one or more records in a single run
(blank line between records, EOF after the last). A later idx patch
will send `kind=bundle` and `kind=idx` together so one process can
overlap those two GETs.

### stdin records

Credential-helper style `key=value` lines. Unknown keys are ignored
(forward compatible with `fetch.packfileUriHelper`’s `hash=`). Values
must not contain newline. Git will not send a key whose value fails
that rule.

```text
id=full
uri=https://cdn.example/base.bundle
path=/abs/path/to/objects/bundles/tmp_uri_XXXXXX
kind=bundle
size=4294967296

```

| Key | Required | This slice | Notes |
|---|---|---|---|
| `uri` | yes | advertised URI, unmodified | After Git’s existing space/newline rejection |
| `path` | yes | **absolute** dest filename | Git has already `unlink()`d the mkstemp probe file. Helper creates/truncates `path`. Helper does **not** rename into `pack-*.pack` |
| `kind` | yes | always `bundle` | Hint for download strategy. `idx` is reserved. Bundle **lists** (config text) are also `kind=bundle`: Git does not know the payload type until after the GET. Helpers that shard should only shard after a large `206` |
| `id` | no | bundle-list id when present | Empty/`""` for a lone `--bundle-uri`. For helper logs / `ok` lines |
| `size` | no | **omitted** | No size advertisement exists until the idx/list-key work. Helpers must not require it. When present later, it is decimal bytes of the object at `uri` |

End of record: a blank line. End of job: EOF. Do not send a trailing
record after the last blank line.

`path` must be made absolute with `absolute_pathdup()` (or equivalent)
before writing the record. `odb_mkstemp(…, "bundles/tmp_uri_XXXXXX")`
can be relative to the clone dest; helpers cannot rely on cwd.

### stdout

Reserved for a small machine protocol. Git **must drain stdout** so a
chatty helper cannot deadlock on a full pipe. This slice may discard
the bytes; a later slice can feed `progress` into `display_progress`.

```text
progress <bytes-so-far> <bytes-total-or-0>
ok bundle
```

Rules:

- Exit status is authoritative. Empty stdout + exit 0 + dest exists →
  success. Wrapping `curl`/`aria2` must not be forced to speak this
  dialect.
- `progress` lines are optional. `<bytes-total-or-0>` is `0` when
  unknown.
- `ok` / `ok <kind>` / `ok <id> <kind>` are optional. Git does not
  require them in this slice.
- Unknown stdout lines are ignored.
- Do not print `keep\t`. That is packfile-uri / `http-fetch` output,
  not this helper.

### What the helper must not do

- Parse the bundle header, run `index-pack`, write refs, write `.keep`,
  or install `pack-<hash>.{pack,idx}`.
- Expect Git `http.*` state (proxy, `extraHeader`, credential helper,
  NTLM, client certs). If it needs auth, it uses a pre-signed URL or
  its own config.
- Shard an `idx` object (reserved for later). It **may** shard a
  `kind=bundle` object with parallel `Range` GETs after a one-byte
  `206` probe.

### Failure

Nonzero exit, spawn failure (ENOENT), or dest missing/empty after exit
0 → treat as a failed `get`:

- `fetch_bundle_uri_internal()` already `unlink()`s `bundle->file` and
  returns an error.
- Callers already warn and continue (`clone` / `fetch` fall back to
  the origin). `BUNDLE_MODE_ANY` already tries the next list entry.

**Do not** fall back to `git-remote-https` for the same URI. If the
operator set a helper, they asked to take that path. Silent fallback
would hide helper bugs and skip the CDN policy they wanted.

## Git-side control flow

Today:

```text
copy_uri_to_file(filename, uri)
  http/https → download_https_uri_to_file()  # git-remote-https get
  file:// or path → copy_file()
```

Target:

```text
copy_uri_to_file(filename, uri)
  validate uri (space / newline) and filename (newline)
  if http/https AND helper is set:
        download_with_helper(filename, uri, kind=bundle, id, size=0)
  else if http/https:
        download_https_uri_to_file()
  else:
        copy_file()
```

Keep the existing `strpbrk(uri, " \n")` / `strchr(file, '\n')` checks
**before** spawning the helper. CVE-2025-48385 is URI injection into
`git-remote-https`; the helper stdin is also line-oriented, so newline
in `uri` or `path` is still command injection into the record stream.
Space in URI is not a delimiter for `key=value`, but keep the check
anyway so advertised URIs stay uniformly hostile-validated.

Suggested helpers (all static in `bundle-uri.c` unless a second
callsite appears):

1. `load_bundle_uri_helper()` — `git_protected_config()` callback
   storing `fetch.bundleurihelper`.
2. `download_with_helper(path, uri, kind, id)` — `CHILD_PROCESS_INIT`,
   `use_shell = 1`, `in = -1`, `out = -1`, write one record, `fclose`
   stdin, drain stdout, `finish_command()`, `stat()` dest.
3. Trace2 region `bundle-uri` / `helper` around (2).

No public API change in `bundle-uri.h`. Callers stay as they are.

`find_temp_filename()` stays the dest chooser. Helper never picks the
path.

## Documentation

1. **`Documentation/config/fetch.adoc`** — new `fetch.bundleUriHelper`
   paragraph next to `fetch.bundleURI`:
   - what it replaces (`git-remote-https` `get` for bundle URIs)
   - protected-scope warning (`<<SCOPES>>`, copy the sentence from
     `uploadpack.packObjectsHook`)
   - public / pre-signed URL limitation
   - pointer to the technical doc for the stdin contract
2. **`Documentation/technical/bundle-uri.adoc`** — a “Download helper”
   section under the consume-path discussion: invocation, record
   format, stdout, exit codes, “Git still unbundles”, no githook.
   This is the helper-author spec.
3. No new clone flag. `git clone --bundle-uri=` and `fetch.bundleURI`
   pick the helper up from config automatically.

## Tests

t5558 is already large and owns general `--bundle-uri` behavior. Add a
focused script:

**`t/t5559-bundle-uri-helper.sh`**

Needs `lib-httpd.sh` / `start_httpd` because the helper is http(s)-only.
Reuse the same fixture style as t5558: a small bundle on
`$HTTPD_DOCUMENT_ROOT_PATH`, origin at `$HTTPD_URL/smart/fetch.git`.

Use `write_script` helpers (see `t/t5544-pack-objects-hook.sh`), not a
new `test-tool` binary, unless stdin parsing gets too awkward in shell.

### Helper scripts

A copying helper (the happy path):

- Dump stdin to `helper.stdin` (and argv to `helper.args` if useful).
- Parse `uri=` / `path=` from the record.
- `curl` / `wget` the URI into `path`, **or** map `$HTTPD_URL` back to
  `$HTTPD_DOCUMENT_ROOT_PATH` and `cp` (avoids depending on libcurl in
  the script).
- Exit 0. Do not print `ok` in at least one test, to prove Git does not
  require it.

A failing helper: dump stdin, exit 1, write nothing (or write a
partial).

A sentinel helper used only to detect invocation (echo to stderr /
touch a file).

### Cases

| Test | Assertion |
|---|---|
| Global config | `test_config_global fetch.bundleUriHelper ./helper` + `git clone --bundle-uri=$HTTPD_URL/B.bundle` installs `refs/bundles/heads/topic`; `helper.stdin` has `uri=…`, `path=…` (absolute), `kind=bundle` |
| `-c` | `git -c fetch.bundleUriHelper=./helper clone --bundle-uri=…` also runs the helper (`CONFIG_SCOPE_COMMAND` is protected) |
| Repo config ignored | Destination or a fetch repo has **local** `fetch.bundleUriHelper`; helper must **not** run. Then set global and confirm it does. Mirror t5544’s “hook does not run from repo config” |
| `file://` / path URI | With helper set globally, `git clone --bundle-uri=file://…` or a relative path still copies via `copy_file` — helper stdin dump is absent |
| Unset helper | Existing HTTP clone still works (no regression; can be a single case or rely on t5558) |
| Helper exit 1 | Clone warns `failed to download bundle from URI` (or the fetch-list equivalent) and still completes from origin; dest tempfile is gone |
| Helper missing | `fetch.bundleUriHelper = ./does-not-exist` → same as failed `get`; no crash |
| Empty dest + exit 0 | Helper exits 0 without creating `path` (or creates a 0-byte file) → Git treats as failure |
| Stdin shape | `grep '^kind=bundle$' helper.stdin`; `grep '^uri=http'`; `test_grep ! '^size='` (this slice omits size); `path=` is absolute (`test_path_is_absolute` or a `^path=/` check) |
| Bundle **list** | HTTP `bundle-list` that points at another HTTP bundle: helper runs **twice** (list, then bundle). Second record still `kind=bundle` |
| `fetch.bundleURI` | Clone with heuristic list stores `fetch.bundleURI`; a later `git fetch` with global helper downloads through the helper |
| URI injection | Keep the t5558 space/newline cases conceptually: a helper must not be spawned with a URI containing space or newline (Git errors first). One explicit case is enough here if t5558 already covers the built-in path |
| No silent fallback | Helper always fails; `GIT_TRACE=1` / a wrapper around `git-remote-https` is **not** required if we simply assert the clone did not get bundle refs from a URI only the helper could have fetched. Simpler: helper fails, bundle refs missing, origin clone still has `HEAD` |

Protocol-v2 advertised bundles (`t/t5732`) already download through
`copy_uri_to_file()`. One extra case there **or** a v2 case in t5559
(`uploadpack.advertiseBundleURIs` + `transfer.bundleURI=true` + helper)
is enough; do not duplicate the whole t5732 matrix.

## Implementation order

Small Git-style series. Docs can land in the same commit as the code if
the series stays at two patches; split if the contract text is long.

1. **Docs** — `fetch.bundleUriHelper` in `config/fetch.adoc` + contract
   section in `bundle-uri.adoc`. Write the stdin table first and treat
   it as the spec the C and the tests must match.
2. **Plumbing in `bundle-uri.c`**
   - Protected-config load.
   - `download_with_helper()`.
   - Branch in `copy_uri_to_file()` for http(s) + helper.
   - Absolute dest path; drain stdout; `stat()` dest; trace2.
   - Reuse the existing malformed-URI errors so t5558 injection tests
     keep passing.
3. **Tests** — `t/t5559-bundle-uri-helper.sh` as above.
4. **Manual check** (not a test): `git clone -c fetch.bundleUriHelper=…`
   against a real HTTP bundle, helper is `curl -fL -o "$path" "$uri"`
   wrapped in a tiny script that reads the record. Confirms the contract
   is usable outside the suite.

No changes expected in `builtin/clone.c`, `builtin/fetch.c`,
`transport.c`, or `bundle-uri.h`.

## Compatibility with later work

Leave these hooks in the contract, unimplemented here:

- Second stdin record `kind=idx` with an idx dest path, same process.
- Optional `size=` from `bundle.<id>.size`.
- Optional stdout `progress` → `display_progress`.
- Shared helper binary with `fetch.packfileUriHelper`: same
  `key=value` records; packfile-uri adds `hash=` and `kind=pack`.
  Helpers ignore unknown keys. Do **not** extract a common
  `run_uri_download_helper()` until the second caller exists.

## Files

| File | Change |
|---|---|
| `bundle-uri.c` | Load helper; spawn; stdin records; branch in `copy_uri_to_file()` |
| `Documentation/config/fetch.adoc` | Config key, protected scope, public-URL limit |
| `Documentation/technical/bundle-uri.adoc` | Helper-author contract |
| `t/t5559-bundle-uri-helper.sh` | New tests (httpd + `write_script`) |

## Done when

- Unset helper: t5558 / t5730–t5732 behavior unchanged.
- Protected helper: HTTP `--bundle-uri` clone fetches through the helper
  and still unbundles.
- Local `fetch.bundleUriHelper` is ignored.
- Helper failure degrades like a failed `get`, with no built-in retry
  of that URI.
- The stdin record format in the technical doc matches what Git writes
  and what t5559 greps for.
