# How to publish this repository

Written for **this machine**, which has **no `git` and no `gh` installed**. Two routes are given;
Route A is the one I recommend.

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

## After publishing — checklist

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
