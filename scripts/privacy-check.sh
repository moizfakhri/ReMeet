#!/usr/bin/env bash
set -euo pipefail

exec python3 - "$@" <<'PY'
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".icns", ".pdf",
    ".wav", ".m4a", ".caf", ".aiff", ".mp3", ".flac", ".opus",
    ".sqlite", ".sqlite-wal", ".sqlite-shm", ".zip", ".tgz",
}
SKIP_FILES = {"Packages/ReMeetKit/Package.resolved"}

ALLOWED_EMAIL_DOMAINS = {
    "acme.io",
    "example.com",
    "example.edu",
    "example.org",
    "stripe.com",
    "google.com",
    "resource.calendar.google.com",
    "users.noreply.github.com",
    "noreply.github.com",
}
ALLOWED_EXACT_EMAILS = {"noreply@github.com"}

ALLOWED_ZOOM_SUBDOMAINS = {
    "www", "us02web", "us04web", "us05web", "us06web", "example",
}

STOPWORDS = {
    "about", "action", "active", "actual", "added", "admin", "after", "again",
    "agent", "agents", "alert", "alvarez", "always", "amazon", "apple", "audio",
    "audit", "based", "before", "being", "below", "between", "brief", "brooks",
    "build", "calendar", "calls", "carter", "check", "chen", "chris", "class", "classes", "clear",
    "client", "cloud", "color", "commit", "common", "contact", "context", "control",
    "count", "create", "custom", "daily", "david", "debug", "default", "design",
    "detail", "device", "draft", "elena", "email", "emails", "empty", "enable",
    "error", "event", "events", "example", "export", "external", "extra", "files",
    "filter", "first", "focus", "folder", "folders", "follow", "found", "general",
    "github", "global", "google", "group", "groups", "guest", "guide", "handle",
    "header", "health", "hello", "helper", "icloud", "import", "index", "input",
    "inside", "install", "issues", "items", "john", "jordan", "kim", "label", "labels", "large",
    "launch", "lee", "level", "light", "limit", "lin", "links", "listed", "lists", "local",
    "macro", "macos", "marco", "match", "maya", "meeting", "meetings", "memory", "merge",
    "method", "metrics", "micro", "middle", "mobile", "model", "models", "moment",
    "moments", "month", "morgan", "music", "names", "native", "never", "notes",
    "notice", "office", "online", "other", "others", "panel", "patel", "people",
    "person", "personal", "phase", "phone", "place", "plain", "player", "point",
    "points", "portal", "priya", "private", "process", "product", "project",
    "projects", "prompt", "public", "query", "quick", "quote", "radar", "range",
    "ray", "reading", "record", "release", "remote", "remove", "reminder", "reminders",
    "rename", "report", "reset", "result", "review", "reyes", "route", "routing",
    "sam", "sample", "scale", "schedule", "screen", "script", "search", "second", "section",
    "select", "server", "service", "session", "setup", "share", "shared", "shell",
    "short", "should", "shown", "shows", "sidebar", "signal", "simple", "since",
    "single", "slack", "smith", "sound", "source", "space", "speaker", "speakers",
    "split", "stage", "staging", "start", "state", "status", "store", "stream",
    "string", "struct", "studio", "style", "summary", "support", "swift", "switch",
    "system", "table", "target", "teams", "tests", "their", "theme", "there",
    "these", "thing", "think", "third", "those", "three", "through", "title",
    "today", "token", "tom", "tools", "track", "tracks", "transcript", "trash", "under",
    "update", "using", "value", "verify", "video", "voice", "waiting", "watch",
    "webex", "website", "weekly", "where", "which", "while", "window", "words",
    "works", "world", "write", "wrote", "yesterday", "young", "yours",
}

RE_EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-/])([A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,}))")
RE_USERS_PATH = re.compile(r"/Users/([A-Za-z0-9._-]+)(?:/|\b)")
RE_ZOOM_SUB = re.compile(r"https?://([A-Za-z0-9-]+)\.zoom\.us/", re.IGNORECASE)
RE_ICS_URL = re.compile(r"(?:webcal://[A-Za-z0-9.-]+\.[A-Za-z]{2,}[^\s\"'<>]*|https?://[^\s\"'<>]+\.ics\b[^\s\"'<>]*)", re.IGNORECASE)
SECRET_PATTERNS = [
    ("Google API key", re.compile(r"AIza[0-9A-Za-z_-]{20,}")),
    ("Anthropic API key", re.compile(r"sk-ant-api[0-9A-Za-z_-]{20,}")),
    ("OpenAI API key", re.compile(r"sk-proj-[0-9A-Za-z_-]{20,}")),
    ("GitHub PAT", re.compile(r"ghp_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}")),
    ("Slack token", re.compile(r"xox[baprs]-[0-9A-Za-z-]{10,}")),
    ("Private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
]


def run_git(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def strip_owner_identifiers(text: str, rel_path: str) -> str:
    if rel_path == "LICENSE" and text.lstrip().startswith("Copyright (c)"):
        return ""
    cleaned = re.sub(r"com\.moizfakhri\.ReMeet(?:\.[A-Za-z0-9_.-]+)?", "", text)
    cleaned = cleaned.replace("github.com/moizfakhri/ReMeet", "")
    return cleaned


def load_local_blocklist() -> list[tuple[str, re.Pattern, str]]:
    blocklist_path = Path(
        os.environ.get("REMEET_PRIVACY_BLOCKLIST")
        or Path.home() / ".config/remeet/privacy-blocklist.txt"
    )
    if not blocklist_path.is_file():
        return []
    rules: list[tuple[str, re.Pattern, str]] = []
    for raw in blocklist_path.read_text(encoding="utf-8", errors="replace").splitlines():
        term = raw.strip()
        if not term or term.startswith("#"):
            continue
        if any(ch in term for ch in ("@", "/", ".")) and " " not in term:
            pat = re.compile(re.escape(term), re.IGNORECASE)
        else:
            pat = re.compile(r"(?<![A-Za-z0-9])" + re.escape(term) + r"(?![A-Za-z0-9])", re.IGNORECASE)
        rules.append(("local privacy-blocklist match", pat, f"blocklist:{len(rules) + 1}"))
    return rules


def load_local_remeet_terms() -> list[tuple[str, re.Pattern, str]]:
    base = Path.home() / "ReMeet"
    if not base.is_dir():
        return []
    phrases: set[str] = set()
    tokens: set[str] = set()

    people_path = base / "people.json"
    if people_path.is_file():
        try:
            data = json.loads(people_path.read_text(encoding="utf-8"))
            profiles = data.get("profiles", []) if isinstance(data, dict) else []
            for p in profiles:
                if not isinstance(p, dict):
                    continue
                email = (p.get("email") or "").strip()
                if "@" in email:
                    domain = email.split("@", 1)[1].lower()
                    if domain not in ALLOWED_EMAIL_DOMAINS:
                        phrases.add(email)
                for candidate in [p.get("name") or "", p.get("organization") or "", *(p.get("aliases") or [])]:
                    cand = candidate.strip()
                    if not cand:
                        continue
                    parts = [w.strip(".,()[]:;\"'") for w in cand.split() if w.strip(".,()[]:;\"'")]
                    significant_parts = [w.lower() for w in parts if len(w) >= 2]
                    if len(parts) >= 2 and len(cand) >= 6 and not all(w in STOPWORDS for w in significant_parts):
                        phrases.add(cand)
                    for tok in parts:
                        low = tok.lower()
                        if len(tok) >= 5 and low not in STOPWORDS and re.fullmatch(r"[A-Za-z'-]+", tok):
                            tokens.add(tok)
        except Exception:
            pass

    collections_path = base / "collections.json"
    if collections_path.is_file():
        try:
            cols = json.loads(collections_path.read_text(encoding="utf-8"))
            if isinstance(cols, list):
                for c in cols:
                    if not isinstance(c, dict):
                        continue
                    name = (c.get("name") or "").strip()
                    if len(name) >= 4 and name.lower() not in STOPWORDS:
                        phrases.add(name)
        except Exception:
            pass

    patterns: list[tuple[str, re.Pattern, str]] = []
    for p in sorted(phrases):
        if "@" in p:
            pat = re.compile(re.escape(p), re.IGNORECASE)
        else:
            pat = re.compile(r"(?<![A-Za-z0-9])" + re.escape(p) + r"(?![A-Za-z0-9])", re.IGNORECASE)
        patterns.append(("local ~/ReMeet contact/folder phrase", pat, "phrase"))
    for tok in sorted(tokens):
        pat = re.compile(r"(?<![A-Za-z0-9])" + re.escape(tok) + r"(?![A-Za-z0-9])", re.IGNORECASE)
        patterns.append(("local ~/ReMeet contact/folder token", pat, "token"))
    return patterns


def should_skip_path(rel_path: str) -> bool:
    if rel_path in SKIP_FILES:
        return True
    suffix = Path(rel_path).suffix.lower()
    return suffix in BINARY_EXTENSIONS


def scan_line(line: str, rel_path: str, line_ref: str, custom_rules: list[tuple[str, re.Pattern, str]]) -> list[str]:
    findings: list[str] = []
    scrubbed = strip_owner_identifiers(line, rel_path)
    if not scrubbed.strip():
        return findings

    for m in RE_USERS_PATH.finditer(scrubbed):
        user = m.group(1)
        if user != "me":
            findings.append(f"{rel_path}:{line_ref}: local /Users/{user}/ path exposed")

    for m in RE_EMAIL.finditer(scrubbed):
        email = m.group(1)
        domain = m.group(2).lower()
        if email.lower() in ALLOWED_EXACT_EMAILS:
            continue
        if any(domain.endswith(ext) for ext in BINARY_EXTENSIONS) or domain.endswith(".svg"):
            continue
        if domain not in ALLOWED_EMAIL_DOMAINS:
            findings.append(f"{rel_path}:{line_ref}: non-synthetic email '{email}'")
        elif domain.endswith(".edu") and domain != "example.edu":
            findings.append(f"{rel_path}:{line_ref}: real .edu email '{email}'")

    for m in RE_ZOOM_SUB.finditer(scrubbed):
        sub = m.group(1).lower()
        if sub not in ALLOWED_ZOOM_SUBDOMAINS:
            findings.append(f"{rel_path}:{line_ref}: organization Zoom subdomain '{sub}.zoom.us'")

    for m in RE_ICS_URL.finditer(scrubbed):
        url = m.group(0)
        low = url.lower()
        if (
            "calendar.google.com/calendar/ical/test/basic.ics" not in low
            and "calendar.google.com/calendar/ical/.../basic.ics" not in low
            and "example." not in low
        ):
            findings.append(f"{rel_path}:{line_ref}: non-placeholder calendar feed URL '{url}'")

    for label, pat in SECRET_PATTERNS:
        if pat.search(scrubbed):
            findings.append(f"{rel_path}:{line_ref}: potential {label}")

    for label, pat, _tag in custom_rules:
        if pat.search(scrubbed):
            findings.append(f"{rel_path}:{line_ref}: {label}")

    return findings


def parse_unified_diff(diff_text: str, custom_rules: list[tuple[str, re.Pattern, str]]) -> list[str]:
    findings: list[str] = []
    current_file: str | None = None
    new_line = 0
    for raw in diff_text.splitlines():
        if raw.startswith("+++ b/"):
            current_file = raw[6:]
            continue
        if raw.startswith("+++ /dev/null"):
            current_file = None
            continue
        if raw.startswith("@@ "):
            m = re.search(r"\+(\d+)", raw)
            new_line = int(m.group(1)) if m else 0
            continue
        if current_file is None or should_skip_path(current_file):
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            findings.extend(scan_line(raw[1:], current_file, str(new_line), custom_rules))
            new_line += 1
        elif not raw.startswith("-"):
            new_line += 1
    return findings


def check_commit_emails(rev_range: str) -> list[str]:
    if os.environ.get("REMEET_ALLOW_EMAIL") == "1":
        return []
    res = run_git(["log", rev_range, "--format=%H\t%ae\t%ce"], check=False)
    if res.returncode != 0:
        return []
    bad: list[str] = []
    for line in res.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        sha, ae, ce = parts
        for role, addr in (("author", ae.strip()), ("committer", ce.strip())):
            low = addr.lower()
            if not (low.endswith("@users.noreply.github.com") or low == "noreply@github.com"):
                bad.append(f"commit {sha[:7]}: {role} email '{addr}' is not a GitHub noreply address")
    return bad


def check_local_git_email() -> list[str]:
    if os.environ.get("REMEET_ALLOW_EMAIL") == "1" or os.environ.get("GITHUB_ACTIONS") == "true":
        return []
    res = run_git(["config", "user.email"], check=False)
    email = res.stdout.strip().lower()
    if email and not email.endswith("@users.noreply.github.com"):
        return [
            f"git config user.email '{email}' is not a GitHub noreply address. "
            "Run: git config user.email \"<id>+<username>@users.noreply.github.com\""
        ]
    return []


def check_filenames(paths: list[str], custom_rules: list[tuple[str, re.Pattern, str]]) -> list[str]:
    findings: list[str] = []
    for p in paths:
        if should_skip_path(p):
            continue
        for label, pat, _tag in custom_rules:
            if pat.search(p):
                findings.append(f"{p}: filename triggers {label}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description="ReMeet privacy guardrail checker")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--staged", action="store_true", help="Check staged changes (pre-commit)")
    group.add_argument("--push", action="store_true", help="Check outgoing commits (pre-push)")
    group.add_argument("--all", action="store_true", help="Check all tracked files in the repository")
    args = parser.parse_args()

    repo_root = Path(run_git(["rev-parse", "--show-toplevel"]).stdout.strip())
    os.chdir(repo_root)

    custom_rules = load_local_blocklist() + load_local_remeet_terms()
    findings: list[str] = []

    if args.staged:
        findings.extend(check_local_git_email())
        staged_names = run_git(["diff", "--cached", "--name-only", "--diff-filter=ACMR"]).stdout.splitlines()
        findings.extend(check_filenames(staged_names, custom_rules))
        diff = run_git(["diff", "--cached", "-U0", "--no-color", "--", ".", ":(exclude)*.png", ":(exclude)*.resolved"]).stdout
        findings.extend(parse_unified_diff(diff, custom_rules))

    elif args.push:
        upstream = run_git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], check=False)
        if upstream.returncode == 0:
            rev_range = f"{upstream.stdout.strip()}..HEAD"
        else:
            rev_range = "HEAD"
        findings.extend(check_commit_emails(rev_range))
        commits = run_git(["rev-list", rev_range], check=False).stdout.splitlines()
        for sha in commits:
            parent_check = run_git(["rev-parse", "--verify", f"{sha}^"], check=False)
            if parent_check.returncode == 0:
                diff = run_git(["diff", "-U0", "--no-color", f"{sha}^", sha, "--", ".", ":(exclude)*.png", ":(exclude)*.resolved"]).stdout
            else:
                diff = run_git(["show", "--format=", "-U0", "--no-color", sha, "--", ".", ":(exclude)*.png", ":(exclude)*.resolved"]).stdout
            findings.extend(parse_unified_diff(diff, custom_rules))

    elif args.all:
        findings.extend(check_local_git_email())
        if os.environ.get("GITHUB_ACTIONS") == "true":
            findings.extend(check_commit_emails("HEAD~20..HEAD" if run_git(["rev-parse", "--verify", "HEAD~20"], check=False).returncode == 0 else "HEAD"))
        tracked = run_git(["ls-files"]).stdout.splitlines()
        findings.extend(check_filenames(tracked, custom_rules))
        for rel in tracked:
            if should_skip_path(rel):
                continue
            p = repo_root / rel
            if not p.is_file():
                continue
            try:
                text = p.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for idx, line in enumerate(text.splitlines(), start=1):
                findings.extend(scan_line(line, rel, str(idx), custom_rules))

    if findings:
        sys.stderr.write("ERROR: Privacy check failed — review before committing/pushing:\n")
        for f in findings[:60]:
            sys.stderr.write(f"  - {f}\n")
        if len(findings) > 60:
            sys.stderr.write(f"  ... and {len(findings) - 60} more.\n")
        return 1

    print(f"Privacy check passed ({'staged' if args.staged else 'push' if args.push else 'all'}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
