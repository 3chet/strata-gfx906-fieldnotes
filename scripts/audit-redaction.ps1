# audit-redaction.ps1 -- run this BEFORE pushing to GitHub.
#
# Usage (from the repository root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\audit-redaction.ps1
#   ... add -Strict to exit non-zero when anything is found
#
# It checks for things that identify a real environment, not only secrets:
#   private IPs, hostnames/domains, user names, absolute paths, container names,
#   API keys, e-mail addresses, oversized files.
#
# This script is committed on purpose: letting others re-check your redaction is
# part of the job. It is pure ASCII so it runs on Windows PowerShell 5.1 too.

param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $root) { $root = (Get-Location).Path }

Write-Host "audit root: $root" -ForegroundColor Cyan
Write-Host ""

$selfName = 'audit-redaction.ps1'
$exts = @('.md', '.sh', '.ps1', '.py', '.csv', '.json', '.yml', '.yaml', '.txt', '')

$files = Get-ChildItem -Path $root -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\\.git\\' -and
    $_.Name -ne $selfName -and
    ($exts -contains $_.Extension)
}

if (-not $files) { Write-Host "no files to check" -ForegroundColor Yellow; exit 0 }
Write-Host ("files to check: {0}" -f $files.Count) -ForegroundColor DarkGray
Write-Host ""

# ---------- rules ----------
# Things that are legitimate placeholders are whitelisted per line.
# A line containing any of these is treated as an intentional placeholder.
# users.noreply.github.com is GitHub's own privacy alias, not a real address.
$placeholder = '<[A-Za-z0-9_\- ]+>|\$\{?[A-Z_][A-Z0-9_]*\}?|CHANGEME|REPLACE_ME|example\.(com|org|net)|noreply\.github\.com|@users\.noreply|127\.0\.0\.1|localhost|0\.0\.0\.0|YOUR_|your-|<model>|<host>|<container>|<unit>|<config>|<path>|<stamp>|<engine-pid>|<cfg>|<port>'

$rules = @(
    @{ Name = 'private IPv4';      Sev = 'HIGH';
       Pat  = '\b(10\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}|192\.168\.\d{1,3})\.\d{1,3}\b';
       Why  = 'reveals internal network layout' }

    @{ Name = 'public IPv4';       Sev = 'MEDIUM';
       Pat  = '\b(?!127\.|0\.|255\.)((?:[1-9]?\d|1\d\d|2[0-4]\d|25[0-5])\.){3}(?:[1-9]?\d|1\d\d|2[0-4]\d|25[0-5])\b';
       Why  = 'often maps to an ISP / region' }

    @{ Name = 'Windows user path'; Sev = 'HIGH';
       Pat  = '[A-Za-z]:\\+Users\\+[A-Za-z0-9._-]+';
       Why  = 'contains the local user name' }

    @{ Name = 'Linux home path';   Sev = 'HIGH';
       Pat  = '/home/[a-z][a-z0-9._-]{1,}/';
       Why  = 'contains the remote user name' }

    @{ Name = 'Bearer token';      Sev = 'HIGH';
       Pat  = 'Bearer\s+[A-Za-z0-9\-._~+/]{12,}';
       Why  = 'live credential' }

    @{ Name = 'API key pattern';   Sev = 'HIGH';
       Pat  = '\b(sk-[A-Za-z0-9]{12,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{12,}|xox[baprs]-[A-Za-z0-9-]{10,})\b';
       Why  = 'live credential' }

    @{ Name = 'assigned secret';   Sev = 'HIGH';
       Pat  = '(?i)(api[_-]?key|secret|password|passwd)\s*[:=]\s*["'']?[A-Za-z0-9\-._~+/]{16,}';
       Why  = 'hard-coded credential' }

    @{ Name = 'SSH private key';   Sev = 'HIGH';
       Pat  = '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----';
       Why  = 'must never be committed' }

    @{ Name = 'cloud access key';  Sev = 'HIGH';
       Pat  = '\bLTAI[A-Za-z0-9]{12,}\b|\bAKID[A-Za-z0-9]{13,}\b';
       Why  = 'cloud account credential' }

    @{ Name = 'e-mail address';    Sev = 'MEDIUM';
       Pat  = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}';
       Why  = 'personally identifying' }

    @{ Name = 'deployment names';  Sev = 'MEDIUM';
       Pat  = '\bstrata71[0-9]\b|strata-iq3_xxs|\bllmbox\b';
       Why  = 'specific deployment identifiers' }
)

$total = 0
$high = 0

foreach ($r in $rules) {
    $hits = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        $ln = 0
        try {
            foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                $ln++
                if ($line -match $r.Pat) {
                    if ($line -match $placeholder) { continue }
                    [void]$hits.Add([pscustomobject]@{ File = $rel; Line = $ln; Text = $line.Trim() })
                }
            }
        } catch { }
    }

    if ($hits.Count -gt 0) {
        $color = if ($r.Sev -eq 'HIGH') { 'Red' } else { 'Yellow' }
        Write-Host ("[{0}] {1} ({2}) -- {3} hit(s)" -f $r.Sev, $r.Name, $r.Why, $hits.Count) -ForegroundColor $color
        foreach ($h in ($hits | Select-Object -First 8)) {
            $t = $h.Text
            if ($t.Length -gt 130) { $t = $t.Substring(0, 130) + '...' }
            Write-Host ("    {0}:{1}  {2}" -f $h.File, $h.Line, $t) -ForegroundColor DarkGray
        }
        if ($hits.Count -gt 8) { Write-Host ("    ... {0} more" -f ($hits.Count - 8)) -ForegroundColor DarkGray }
        Write-Host ""
        $total += $hits.Count
        if ($r.Sev -eq 'HIGH') { $high += $hits.Count }
    }
}

# ---------- size ----------
Write-Host "size check (nothing over 1 MiB should be committed):" -ForegroundColor Cyan
$big = $files | Where-Object { $_.Length -gt 1MB }
if ($big) {
    foreach ($b in $big) {
        Write-Host ("    {0}  {1:N1} MiB" -f $b.Name, ($b.Length / 1MB)) -ForegroundColor Red
    }
    $total += $big.Count
    $high += $big.Count
} else {
    Write-Host "    none" -ForegroundColor DarkGray
}

# ---------- summary ----------
Write-Host ""
Write-Host "================ summary ================" -ForegroundColor Cyan
Write-Host ("  files checked : {0}" -f $files.Count)
Write-Host ("  total hits    : {0}" -f $total)
Write-Host ("  HIGH hits     : {0}" -f $high)
Write-Host ""

if ($total -eq 0) {
    Write-Host "  PASS - nothing sensitive found" -ForegroundColor Green
    exit 0
} elseif ($high -gt 0) {
    Write-Host "  FAIL - HIGH hits present, do not push yet" -ForegroundColor Red
    Write-Host "  fix: replace the concrete value with a placeholder, and let the" -ForegroundColor Yellow
    Write-Host "       scripts read it from an environment variable" -ForegroundColor Yellow
    if ($Strict) { exit 1 } else { exit 0 }
} else {
    Write-Host "  WARN - MEDIUM hits only, review each one" -ForegroundColor Yellow
    if ($Strict) { exit 1 } else { exit 0 }
}
