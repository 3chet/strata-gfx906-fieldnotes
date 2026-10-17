# How to publish this repository

**Status: published** at <https://github.com/3chet/strata-gfx906-fieldnotes>.
This file is kept as the runbook — what was done, and the six things that went wrong on the way,
so the next push (or the next person) takes minutes instead of an evening.

The original plan assumed no `git` and no `gh` on the machine. Both turned out to be true, and two
routes are still documented below. What actually worked was a third one, in
[`Route C`](#route-c--what-actually-worked-ssh-over-443--cached-token) — read that first.

---

## Before anything: the redaction gate must pass

```powershell
cd D:\github\strata-gfx906-fieldnotes
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\audit-redaction.ps1
```

It must print `PASS - nothing sensitive found`. If it prints `FAIL`, do not push.

What has already been scrubbed from these files:

| Removed | Replaced with |
|---|---|
| private IP `192.168.x.x` | `<host>`, or `127.0.0.1` in examples |
| Linux home path `/home/<user>/…` | `<path>` |
| container name | `<container>` |
| systemd unit name | `<unit>` |
| production port | `<port>` |
| domain name | *(deleted entirely)* |
| user names | *(deleted entirely)* |

**Your Git identity will still be public** (the e-mail on your commits, and the account name).
If that matters, use a noreply address — GitHub Settings → Emails → *Keep my email private*,
which gives you `ID+username@users.noreply.github.com`. Set it before the first commit:

```powershell
git config --global user.name  "your-handle"
git config --global user.email "ID+your-handle@users.noreply.github.com"
```

You do not have to look the numeric ID up by hand — the public API returns it:

```powershell
(Invoke-RestMethod https://api.github.com/users/<your-handle> -Headers @{'User-Agent'='x'}).id
```

---

## Route A — install Git, then push (recommended)

### A1. Install

**If you are in mainland China, do not use the official GitHub download** — it times out or crawls.
Measured on one connection (1 MB range request, 2026-10):

| source | measured |
|---|---|
| `github.com/…/releases/download/…` | **timeout** |
| `ghfast.top/https://github.com/…` | 76 KB/s |
| `gh-proxy.com/https://github.com/…` | 109 KB/s |
| **`registry.npmmirror.com/-/binary/git-for-windows/`** | **1,717 KB/s** ← 15–22× faster |

So either:

```powershell
# domestic mirror: fetch the installer at full speed, then run it
# (browse the folder first to pick the newest version)
#   https://registry.npmmirror.com/-/binary/git-for-windows/
```

or, if `winget` happens to be fast for you:

```powershell
winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
```

**Rule of thumb:** if a download has not reached ~200 KB/s within 30 seconds, switch source
immediately rather than waiting. For large files use a multi-connection downloader
(`aria2c -x16 -s16 <url>`).

Close and reopen the terminal afterwards (PATH is updated for new shells only), then verify:

```powershell
git --version
```

Optionally also the GitHub CLI, which makes repo creation one line:

```powershell
winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
gh auth login          # choose: GitHub.com → HTTPS → login with a browser
```

### A2. Initialise and make the first commit

```powershell
cd D:\github\strata-gfx906-fieldnotes
git init -b main
git add -A
git status                     # review: nothing unexpected, nothing large
git commit -m "Strata on 2x Radeon Pro VII (gfx906): baselines, A/B methodology, rejected settings"
```

If `git status` shows a file you did not expect, stop and fix `.gitignore` before committing.
`git commit --amend` will let you correct the first commit if you catch it immediately.

### A3. Create the remote and push

**With `gh`:**

```powershell
gh repo create strata-gfx906-fieldnotes --public --source=. --remote=origin `
  --description "Measured tuning notes for Strata on 2x Radeon Pro VII (gfx906): baseline numbers, an A/B protocol that accounts for cold-start bias, and the settings we measured and rejected"
git push -u origin main
```

**Without `gh`** — create it in the browser first: <https://github.com/new>
(repository name `strata-gfx906-fieldnotes`, **Public**, do **not** initialise with a README —
you already have one), then:

```powershell
git remote add origin https://github.com/<your-handle>/strata-gfx906-fieldnotes.git
git push -u origin main
```

`git push` will prompt for credentials. Use a **personal access token** as the password
(GitHub no longer accepts account passwords): Settings → Developer settings → Personal access
tokens → Fine-grained → *Repository access: your repo* → *Contents: Read and write*.
Paste the token when Git asks for a password; do not save it into any file.

---

## Route B — no Git at all (browser upload)

Works, but you lose history and you will re-upload on every edit. Fine for a one-shot publish.

1. Redaction gate passes (`audit-redaction.ps1`).
2. <https://github.com/new> → name `strata-gfx906-fieldnotes` → **Public** → **Create repository**.
3. On the empty repo page: **uploading an existing file**.
4. Drag the **contents** of `D:\github\strata-gfx906-fieldnotes` — not the folder itself —
   so that `README.md`, `docs/`, `scripts/`, `results/`, `LICENSE`, `.gitignore` land at the root.
5. Commit message, then **Commit changes**.

Caveats of Route B:

- **`.gitignore` may be hidden** in Explorer (files starting with a dot). Enable
  *View → Show → Hidden items*, or skip it — it only matters once you start using Git.
- **Directory structure is preserved** only if you drag folders; dragging loose files flattens them.
- **No `.git`**, so later edits mean re-uploading through the web UI or switching to Route A anyway.
- GitHub's web UI caps a single upload batch; this repo is ~60 KB, so no issue.

---

## Route C — what actually worked (SSH over 443 + cached token)

No `gh`, no web clicks, no manual token creation. The whole publish was three steps.

### C1. SSH over port 443, not 22

Port 22 to `github.com` is unreliable on many networks (here it reset mid-handshake). GitHub
serves SSH on **`ssh.github.com:443`** as well. Add a dedicated key and route it there:

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_ed25519_github -N '""' -C "yourlabel"
Get-Content $env:USERPROFILE\.ssh\id_ed25519_github.pub   # paste this into GitHub
```

Append to `~/.ssh/config` (create it if absent):

```
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
    ServerAliveInterval 30
```

Then add the public key at <https://github.com/settings/ssh/new> and verify:

```powershell
ssh -T git@github.com
# Hi <user>! You've successfully authenticated, but GitHub does not provide shell access.
```

The `-v` output should say `Connecting to ssh.github.com [<ip>] port 443` — if it says port 22,
the config block did not take effect.

### C2. Reuse the cached credential to create the repo

`git-credential-manager` already had a token for github.com (from an earlier HTTPS login), so
creating the repo needed no interaction. Ask it, then call the API — never print the value:

```powershell
$gcm  = "C:\Program Files\Git\mingw64\bin\git-credential-manager.exe"
$resp = "protocol=https`nhost=github.com`n`n" | & $gcm get
$tok  = ($resp -split "`r?`n" | Where-Object { $_ -match '^password=' }) -replace '^password=',''
$h    = @{ Authorization = "token $tok"; 'User-Agent' = 'x' }

# who am I, and what may I do
(Invoke-RestMethod https://api.github.com/user -Headers $h).login
(Invoke-WebRequest https://api.github.com/user -Headers $h).Headers['x-oauth-scopes']

# create (once; a second call returns 422 "already exists")
Invoke-RestMethod https://api.github.com/user/repos -Method Post -Headers $h `
  -ContentType 'application/json' `
  -Body '{"name":"strata-gfx906-fieldnotes","private":false,"auto_init":false}'
```

`auto_init` **must be false** — otherwise GitHub creates a README and your first push is rejected
as a non-fast-forward.

### C3. Push

```powershell
cd D:\github\strata-gfx906-fieldnotes
git remote add origin git@github.com:<user>/strata-gfx906-fieldnotes.git
git push -u origin main
```

### Metadata afterwards

`PATCH /repos/{owner}/{repo}` for the description and `PUT /repos/{owner}/{repo}/topics` for
topics both need the same token. **On this network those two calls hung indefinitely** while
`GET` and `raw.githubusercontent.com` were fine. If that happens, set them in the web UI
(repo → About → gear) and do not retry the API — for a one-off publish the UI is 20 seconds and
the API is an evening.

---

## The six things that went wrong

Kept because each cost real time, and five of them are not specific to this repo.

**1. `winget install Git.Git` took 8 minutes.** GitHub-hosted downloads time out here.
Measure before waiting: fetch 1 MB from each candidate and switch on the spot.
`registry.npmmirror.com/-/binary/git-for-windows/` measured **1,717 KB/s** against 76–109 KB/s
from the GitHub proxies, and **a flat timeout** from `github.com` itself.
Rule: under ~200 KB/s or no progress in 30 s ⇒ change source, do not retry.

**2. `github.com:443` looks down but is not.** `Test-NetConnection` succeeded three times in a
row (1.6 s, then 0.1 s) while `git ls-remote` failed twice with `Failed to connect ... after
21063 ms`. TCP connect and TLS/HTTP are interfered with differently. **Do not conclude "GitHub is
blocked" from one probe** — and conversely, do not conclude it works from one either. The
reliable transport here was SSH.

**3. `GIT_SSH_COMMAND` with a quoted path breaks the spawn.** Setting it to
`"C:\Program Files\Git\usr\bin\ssh.exe -o ..."` produced:

```
error: cannot spawn C:/Program : No such file or directory
fatal: unable to fork
```

The space in `Program Files` is split by Git's own spawn. **Do not set `GIT_SSH_COMMAND` for
this** — Git bundles its own `ssh` and reads `~/.ssh/config`, which is where the port-443 route
belongs. (Setting `core.sshCommand` fails the same way.)

**4. `gh` would not install, and was not needed.** `winget install GitHub.cli` ended with
`InternetOpenUrl() failed 0x80072efd` — the same blocked download. Route C needs no `gh`.

**5. Windows PowerShell 5.1 mangles UTF-8 in two different ways.**
   - A script containing **Chinese text plus `$()` interpolation** is a parser error
     (`表达式或语句中包含意外的标记`). Write the script **pure ASCII**.
   - `Get-Content` decodes UTF-8-without-BOM as ANSI, so a correct file **displays** as mojibake
     (`Host github.com` looked fine but its comment did not). The file is not damaged — verify with
     `[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)` before "fixing" anything.
   - Also: use `powershell`, not `pwsh`; `pwsh` is not installed here.

**6. CRLF will break the shell scripts.** Git on Windows checks out CRLF by default, and a `.sh`
with CRLF fails on Linux with a confusing `bad interpreter`. `.gitattributes` in this repo pins
`*.sh text eol=lf`; keep it. Verify with:

```powershell
$b = [IO.File]::ReadAllBytes("scripts\measure_steady.sh")
($b | Where-Object { $_ -eq 13 }).Count   # 0 expected (no CR bytes)
```

---

## Day-to-day: pushing later changes

SSH is configured, so no authentication is needed again:

```powershell
cd D:\github\strata-gfx906-fieldnotes
git add -A
git commit -m "describe the change"
git push
```

Run `scripts\audit-redaction.ps1` before committing if the change touched host-specific text.



```
[ ] audit-redaction.ps1 prints PASS
[ ] git status contained nothing unexpected and nothing > 1 MiB
[ ] README renders on GitHub (check the TL;DR table and the relative links)
[ ] docs/02-methodology.md links resolve (it is linked from README and from docs/06)
[ ] repository description + topics set, e.g.:
      strata, llm, amd, rocm, gfx906, radeon-pro-vii, benchmark, moe, quantization
[ ] Issues enabled (default)
[ ] licence line matches: MIT
```

Topics matter more than they look: they are how someone with a Radeon Pro VII finds this.

---

## Optional second step: a report PR upstream

The Strata maintainers accept community benchmark reports in `bench/results/`, with a defined
format — see their
[COMMUNITY_BENCHMARKS.md](https://github.com/Niko1221/Strata/blob/main/docs/COMMUNITY_BENCHMARKS.md).
There is already a **single-card** Radeon Pro VII report there; a **dual-card, IQ3_XXS, 131072-context**
entry with this measurement discipline would be a genuinely different data point.

That is a separate piece of work (their template, their directory naming, their PR flow) and is
**not** included in this repository. Do it after this one is live, so the PR can link back to the
methodology.

---

## If you later change your mind about something in here

The claims in `docs/` are tied to the CSVs in `results/`. If you re-measure and get a different
number, amend the doc **and** add the new CSV — do not overwrite the old one. A public record that
silently changes its numbers is worth less than one that shows its corrections.
