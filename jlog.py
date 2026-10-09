#!/usr/bin/env python3
"""jlog.py -- the judgment log: one append-only ref per body, never checked out.

  jlog.py append [--body ID] [--remote R] [FILE]   validate lines (FILE or stdin) and push them as
                                                    one new batch to refs/log/judgments/<body>
  jlog.py cat [--no-fetch] [--remote R] [BODY...]  print every line of every log (or the named
                                                    bodies' logs) as body<TAB>line, oldest first
  jlog.py validate [FILE]                          check lines without writing anything

Line format, tab-separated (ARCHITECTURE.md, layer 3):
  v2:  ts subject question judge neg zero pos sel prop [key=value ...]
  v0:  ts subject question judge neg zero pos              (read as sel=stream prop=1)

The remote's pre-receive hook enforces the same rules, so a line this script accepts is a line
the remote accepts. Writing uses plumbing only: no working tree is touched, nothing is checked out.
Standard library only.
"""
import os, re, subprocess, sys, time
from collections import namedtuple

SELS = ("stream", "shadow", "explore", "audit", "drill", "appeal", "flag")
TS = re.compile(r"^\d{4}-[01]\d-[0-3]\dT[0-2]\d:[0-5]\d:[0-6]\d(Z|[+-]\d\d:?\d\d)?$")
PROB = re.compile(r"^(0(\.\d+)?|1(\.0+)?)$")
NAME = re.compile(r"^[A-Za-z0-9._-]+$")
EXTRA = re.compile(r"^[a-z][a-z0-9_]*=.")

Judgment = namedtuple("Judgment", "ts subject question judge p sel prop extra")


def _hex(s):
    return len(s) in (40, 64) and not re.search(r"[^0-9a-f]", s)


def validate(line):
    """Return None if the line is a valid v0 or v2 judgment, else the reason it is not."""
    f = line.rstrip("\n").split("\t")
    n = len(f)
    if n != 7 and n < 9:
        return "expected 7 or 9+ tab-separated fields, got %d" % n
    if not TS.match(f[0]):
        return "timestamp"
    if not (_hex(f[1]) and _hex(f[2])):
        return "subject and question must be blob hashes"
    if not (NAME.match(f[3]) if n == 7 else _hex(f[3])):
        return "judge"
    if not all(PROB.match(x) for x in f[4:7]):
        return "probabilities"
    s = sum(float(x) for x in f[4:7])
    if not 0.999 <= s <= 1.001:
        return "probabilities sum to %g" % s
    if n == 7:
        return None
    if f[7] not in SELS:
        return "sel"
    if not PROB.match(f[8]) or float(f[8]) <= 0:
        return "prop must be in (0, 1]"
    for i, x in enumerate(f[9:], 10):
        if not EXTRA.match(x):
            return "extra field %d" % i
    return None


def parse(line):
    """A valid line as a Judgment. v0 lines get sel=stream, prop=1."""
    f = line.rstrip("\n").split("\t")
    p = tuple(float(x) for x in f[4:7])
    if len(f) == 7:
        return Judgment(f[0], f[1], f[2], f[3], p, "stream", 1.0, {})
    extra = dict(x.split("=", 1) for x in f[9:])
    return Judgment(f[0], f[1], f[2], f[3], p, f[7], float(f[8]), extra)


def utc(ts):
    """A judgment timestamp as naive UTC 'YYYY-MM-DDTHH:MM:SS' (v0 lines carry no zone: read as UTC)."""
    from datetime import datetime, timezone
    d = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    if d.tzinfo:
        d = d.astimezone(timezone.utc).replace(tzinfo=None)
    return d.strftime("%Y-%m-%dT%H:%M:%S")


def format_line(subject, question, judge, p, sel="stream", prop=1.0, ts=None, **extra):
    """A v2 line, with the probabilities rounded to four decimals and renormalised to sum to 1."""
    r = [round(x, 4) for x in p]
    r[max(range(3), key=lambda i: r[i])] += round(1 - sum(r), 4)
    ts = ts or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    prop_s = ("%.6f" % prop).rstrip("0").rstrip(".")
    if not 0 < float(prop_s) <= 1:
        raise ValueError("prop must be in (0, 1] at six decimals, got %r" % prop)
    fields = [ts, subject, question, judge] + ["%.4f" % x for x in r] + [sel, prop_s]
    fields += ["%s=%s" % kv for kv in sorted(extra.items())]
    return "\t".join(fields)


def git(repo, *args, data=None, env=None, check=True):
    r = subprocess.run(["git", "-C", repo, *args], input=data, capture_output=True,
                       env={**os.environ, **(env or {})})
    if check and r.returncode:
        raise RuntimeError("git %s: %s" % (" ".join(args[:2]), r.stderr.decode().strip()[:300]))
    return r.stdout.decode()


def ref_of(body):
    if not NAME.match(body):
        raise ValueError("bad body name: %r" % body)
    return "refs/log/judgments/" + body


def remote_tip(repo, remote, ref):
    """Fetch one log ref; return its commit, or None if the remote has no such log yet."""
    out = git(repo, "ls-remote", remote, ref).split()
    if not out:
        return None
    git(repo, "fetch", "-q", remote, "+%s:%s" % (ref, ref))
    return out[0]


def append(repo, body, lines, remote="origin", retries=5):
    """Push lines as one new batch file on the body's log ref. Returns the new commit."""
    lines = [l.rstrip("\n") for l in lines if l.strip()]
    if not lines:
        raise ValueError("nothing to append")
    data = ("\n".join(lines) + "\n").encode()
    ref = ref_of(body)
    who = {"GIT_AUTHOR_NAME": body, "GIT_AUTHOR_EMAIL": body + "@agent",
           "GIT_COMMITTER_NAME": body, "GIT_COMMITTER_EMAIL": body + "@agent"}
    blob = git(repo, "hash-object", "-w", "--stdin", data=data).strip()
    for _ in range(retries):
        tip = remote_tip(repo, remote, ref)
        index = os.path.join(git(repo, "rev-parse", "--absolute-git-dir").strip(), "jlog.index")
        env = {"GIT_INDEX_FILE": index}
        if tip:
            git(repo, "read-tree", tip, env=env)
        else:
            git(repo, "read-tree", "--empty", env=env)
        stem, k = time.strftime("%Y/%m/%d/%H%M%S", time.gmtime()), 0
        while True:                                   # batch names never collide: files are add-only
            path = "%s%s.tsv" % (stem, "-%d" % k if k else "")
            if not tip or subprocess.run(["git", "-C", repo, "cat-file", "-e", "%s:%s" % (tip, path)],
                                         capture_output=True).returncode:
                break
            k += 1
        git(repo, "update-index", "--add", "--cacheinfo", "100644,%s,%s" % (blob, path), env=env)
        tree = git(repo, "write-tree", env=env).strip()
        os.remove(index)
        parents = ["-p", tip] if tip else []
        commit = git(repo, "commit-tree", "-S", *parents, "-m", "judgments: %d lines" % len(lines), tree,
                     env=who).strip()
        r = subprocess.run(["git", "-C", repo, "push", "-q", remote, "%s:%s" % (commit, ref)], capture_output=True)
        if r.returncode == 0:
            git(repo, "update-ref", ref, commit)
            return commit
        if b"non-fast-forward" not in r.stderr and b"fetch first" not in r.stderr:
            raise RuntimeError("push refused: " + r.stderr.decode().strip()[:500])
    raise RuntimeError("could not append after %d attempts" % retries)


def log_tips(repo, remote="origin", fetch=True):
    """{body: commit} for every judgment log, after fetching them all."""
    if fetch:
        git(repo, "fetch", "-q", remote, "+refs/log/judgments/*:refs/log/judgments/*")
    out = git(repo, "for-each-ref", "--format=%(refname) %(objectname)", "refs/log/judgments/")
    return {r.rsplit("/", 1)[1]: c for r, c in (l.split() for l in out.splitlines())}


def iter_log(repo, bodies=None, remote="origin", fetch=True, with_time=False, tips=None):
    """Yield (body, line) for every line in the logs, each body's batches oldest first.
    With with_time, yield (body, commit_time, line): when the batch reached the log.
    With tips ({body: commit}), read each log only up to that commit: the logs as they stood then."""
    tips = tips if tips is not None else log_tips(repo, remote, fetch)
    for body in sorted(tips):
        ref = tips[body]
        if bodies and body not in bodies:
            continue
        raw = git(repo, "log", "--reverse", "--no-renames", "--root", "--raw", "--no-abbrev", "--format=C %ct", ref)
        blobs, times, t = [], [], 0
        for l in raw.splitlines():
            if l.startswith("C "):
                t = int(l.split()[1])
            elif l.startswith(":"):
                blobs.append(l.split()[3]); times.append(t)
        if not blobs:
            continue
        out = git(repo, "cat-file", "--batch", data=("\n".join(blobs) + "\n").encode())
        pos = 0
        for t in times:
            nl = out.index("\n", pos)
            size = int(out[pos:nl].split()[2])
            for line in out[nl + 1:nl + 1 + size].splitlines():
                yield (body, t, line) if with_time else (body, line)
            pos = nl + 2 + size


def main(argv):
    args, opts = [], {"remote": "origin"}
    it = iter(argv)
    for a in it:
        if a in ("--body", "--remote"):
            opts[a[2:]] = next(it)
        elif a == "--no-fetch":
            opts["fetch"] = False
        elif a == "--no-validate":
            opts["novalidate"] = True
        else:
            args.append(a)
    if not args or args[0] not in ("append", "cat", "validate"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, rest = args[0], args[1:]
    repo = os.getcwd()
    if cmd == "cat":
        for body, line in iter_log(repo, rest or None, opts["remote"], opts.get("fetch", True)):
            print("%s\t%s" % (body, line))
        return 0
    text = open(rest[0]).read() if rest else sys.stdin.read()
    lines = [l[:-1] if l.endswith("\r") else l for l in text.split("\n")]   # Windows line endings are fine
    bad = [(i, why) for i, l in enumerate(lines, 1) if l.strip() for why in [validate(l)] if why]
    if bad and not opts.get("novalidate"):
        for i, why in bad[:20]:
            print("line %d: %s" % (i, why), file=sys.stderr)
        return 1
    if cmd == "validate":
        print("%d lines ok" % sum(1 for l in lines if l.strip()))
        return 0
    body = opts.get("body") or os.environ.get("AGENT_ID")
    if not body:
        print("append needs --body or AGENT_ID", file=sys.stderr)
        return 2
    print(append(repo, body, lines, opts["remote"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
