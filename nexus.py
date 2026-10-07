#!/usr/bin/env python3
"""nexus.py -- the hash->coordinates reverse index for git.pp.

git stores name->hash (a path points to a blob). The nexus is the
transpose: given a blob hash, list every coordinate where that exact
content occurs -- every commit, every ref, every path.

Coordinates are parsed per the git.pp scheme (tick.sh + soul/axes):
  inbox/<task>            -> (inbox, -, <task>)
  claimed/<body>/<task>   -> (claimed, <body>, <task>)
  done/<task>/...         -> (done, -, <task>)
  bodies/<body>/manifest  -> (bodies, <body>, manifest)
  soul/<file>             -> (soul, -, <file>)
  anything else           -> (tree, -, <path>)

Usage:
  nexus.py query <repo> <blob> [--ref all]
  nexus.py build <repo> [--ref refs/pp/nexus]   # full reverse index as a tree
  nexus.py verify <repo> [--ref refs/pp/nexus]  # recompute, compare hashes

The build output is deterministic: same history -> same tree hash,
so a second body can verify by recomputation (Opus's proof criterion).
"""
import subprocess, sys, os, re, hashlib

def git(repo, *args, **kwargs):
    r = subprocess.run(["git", "-C", repo] + list(args),
                       capture_output=True, text=True, **kwargs)
    if r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), r.stderr.strip()[:200]))
    return r.stdout

def parse_coord(path):
    """Parse a repo path into a (state, body, task) coordinate."""
    p = path.strip()
    m = re.match(r"^inbox/([^/]+)$", p)
    if m: return ("inbox", "-", m.group(1))
    m = re.match(r"^claimed/([^/]+)/([^/]+?)(?:\.md)?(?:\.fx)?$", p)
    if m: return ("claimed", m.group(1), m.group(2))
    m = re.match(r"^claimed/([^/]+)/(.+)$", p)
    if m: return ("claimed", m.group(1), m.group(2))
    m = re.match(r"^done/([^/]+)(?:/.*)?$", p)
    if m: return ("done", "-", m.group(1))
    m = re.match(r"^bodies/([^/]+)/(.+)$", p)
    if m: return ("bodies", m.group(1), m.group(2))
    m = re.match(r"^soul/(.+)$", p)
    if m: return ("soul", "-", m.group(1))
    return ("tree", "-", p)

def commits_with_blob(repo, blob):
    """Commits (any non-pp ref) whose tree contains blob. Uses --find-object."""
    refs = [r for r in git(repo, "for-each-ref", "--format=%(refname)").split()
            if not r.startswith("refs/pp/")]
    out = git(repo, "log", *refs, "--find-object=" + blob,
              "--format=%H%x00%D")
    commits = []
    for line in out.splitlines():
        if not line.strip(): continue
        h, _, refs = line.partition("\x00")
        commits.append((h, refs.strip()))
    return commits

def paths_for_blob(repo, commit, blob):
    """Paths in <commit>'s tree pointing at blob."""
    out = git(repo, "ls-tree", "-r", "--full-tree", commit)
    paths = []
    for line in out.splitlines():
        # "<mode> <type> <hash>\t<path>"
        parts = line.split("\t", 1)
        if len(parts) != 2: continue
        meta, path = parts
        if meta.split()[2] == blob if len(meta.split()) > 2 else False:
            paths.append(path)
    return paths

def query(repo, blob, ref="all"):
    """Print every coordinate where blob appears."""
    blob = blob.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", blob):
        # allow short hashes: resolve
        full = git(repo, "rev-parse", blob).strip()
        blob = full
    results = []
    for commit, refs in commits_with_blob(repo, blob):
        for path in paths_for_blob(repo, commit, blob):
            state, body, task = parse_coord(path)
            results.append((commit, refs, path, state, body, task))
    return blob, results

def cmd_query(args):
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("repo"); p.add_argument("blob")
    a = p.parse_args(args)
    blob, results = query(a.repo, a.blob)
    print("# nexus query: blob %s" % blob)
    print("# occurrences: %d" % len(results))
    for commit, refs, path, state, body, task in results:
        print("%s\t%s\t%s\t(coord: %s/%s/%s)" % (
            commit[:12], refs or "-", path, state, body, task))

def build_index(repo):
    """Walk all commits; return {blob: set of (commit, path)}.
    Excludes refs/pp/* (our own projections) so the build is idempotent."""
    index = {}
    # all refs except our projection namespace
    refs = [r for r in git(repo, "for-each-ref", "--format=%(refname)").split()
            if not r.startswith("refs/pp/")]
    if not refs:
        return {}, []
    commits = git(repo, "rev-list", *refs).split()
    for c in commits:
        out = git(repo, "ls-tree", "-r", "--full-tree", c)
        for line in out.splitlines():
            parts = line.split("\t", 1)
            if len(parts) != 2: continue
            meta, path = parts
            fields = meta.split()
            if len(fields) < 3 or fields[1] != "blob": continue
            blob = fields[2]
            index.setdefault(blob, set()).add((c, path))
    return index, commits

def cmd_build(args):
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("repo")
    p.add_argument("--ref", default="refs/pp/nexus")
    a = p.parse_args(args)
    index, commits = build_index(a.repo)
    # Serialize deterministically: shard by 2-char prefix, one file per
    # blob listing "commit path (state/body/task)" lines, sorted.
    import tempfile, shutil
    tmp = tempfile.mkdtemp(prefix="nexus-build-")
    try:
        for blob in sorted(index):
            shard = os.path.join(tmp, blob[:2])
            os.makedirs(shard, exist_ok=True)
            lines = []
            for commit, path in sorted(index[blob]):
                state, body, task = parse_coord(path)
                lines.append("%s %s  # %s/%s/%s" % (commit, path, state, body, task))
            with open(os.path.join(shard, blob[2:]), "w") as f:
                f.write("\n".join(lines) + "\n")
        # hash-object -t tree over the dir -> deterministic tree
        tree = git(a.repo, "hash-object", "-t", "tree", "--stdin",
                   stdin=open(os.devnull)).strip() if False else None
        # write-tree via git --work-tree trick: use git write-tree in a temp index
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(tmp, "idx"),
                   GIT_DIR=os.path.join(a.repo, ".git"),
                   GIT_AUTHOR_NAME="nexus", GIT_AUTHOR_EMAIL="nexus@git.pp",
                   GIT_COMMITTER_NAME="nexus", GIT_COMMITTER_EMAIL="nexus@git.pp")
        subprocess.run(["git", "add", "-A"], cwd=tmp, env=env,
                       capture_output=True, check=True)
        tree = subprocess.run(["git", "write-tree"], env=env,
                              capture_output=True, text=True, check=True).stdout.strip()
        msg = "nexus: reverse index over %d commits, %d blobs" % (
            len(commits), len(index))
        commit = subprocess.run(
            ["git", "commit-tree", tree, "-m", msg],
            env=env, capture_output=True, text=True, check=True).stdout.strip()
        git(a.repo, "update-ref", a.ref, commit)
        print("built %s -> %s" % (a.ref, commit))
        print("blobs indexed: %d" % len(index))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

def cmd_verify(args):
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("repo")
    p.add_argument("--ref", default="refs/pp/nexus")
    a = p.parse_args(args)
    # rebuild into a temp ref and compare tree hashes
    import tempfile
    tmptest = "refs/pp/nexus-verify-%d" % os.getpid()
    cmd_build([a.repo, "--ref", tmptest])
    t1 = git(a.repo, "rev-parse", a.ref + "^{tree}").strip()
    t2 = git(a.repo, "rev-parse", tmptest + "^{tree}").strip()
    git(a.repo, "update-ref", "-d", tmptest)
    if t1 == t2:
        print("VERIFY OK: %s tree %s recomputes identically" % (a.ref, t1[:12]))
    else:
        print("VERIFY FAIL: %s != recomputed (%s vs %s)" % (a.ref, t1[:12], t2[:12]))
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    cmd, rest = sys.argv[1], sys.argv[2:]
    {"query": cmd_query, "build": cmd_build, "verify": cmd_verify}[cmd](rest)
