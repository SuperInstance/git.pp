#!/usr/bin/env python3
"""audit.py -- the audit stream: independent labels, selected so no judge can predict them.

  audit.py commit --period P [--rate R] [--rate-for QUESTION R ...] [--start TS] [--end TS]
      Make a fresh secret seed, keep it in .git/audit/P.seed, and publish
      bodies/<auditor>/audit/P.commit on main: the seed's SHA-256, the time window and the rates.
      --seed HEX fixes the seed instead (64 hex digits), for reproducible tests. The commitment,
      not the seed's origin, is what keeps judges from predicting it; still, let it be random.
  audit.py select --period P
      Select every judged (subject, question) in the window whose keyed hash falls under its
      rate, and drop each as a blind task in inbox/. Selection reads only the content key, never
      a verdict, so suppressed and abstained items are sampled like any other.
  audit.py reveal --period P
      Publish bodies/<auditor>/audit/P.reveal with the seed, once the window has closed.
  audit.py drill --period P --judge J [--n K] [--tau T]
      Fault drills: pick up to K items where judge J was confidently wrong on a resolved audit,
      and drop each as a review task that SHOWS the judge's verdict, named like any other review.
      The drill list stays secret (in .git/audit/P.drills) until the reveal.
  audit.py drills --period P --auditor A
      After the reveal: for each reviewer, the share of drills where they did not follow the
      wrong verdict they were shown. A falling share is the deskilling alarm.
  audit.py verify --period P --auditor A
      Anyone: check the seed against its commitment, recompute the selection from the logs, and
      compare it with the audit tasks the auditor actually created. Reports skipped and
      cherry-picked items.

The auditor is AGENT_ID (or --auditor). Labellers answer a task by logging, with jlog.py,
a judgment with sel=audit, prop=<the task's rate>, seed=<period> and blind=1. Reviewers answer
review tasks (real escalations and drills look the same) with sel=appeal and review=<task name>.
Standard library only.
"""
import hashlib, hmac, os, re, secrets, subprocess, sys, time
import jlog

TASK_PREFIX = "audit-"


def git(repo, *args, **kw):
    return jlog.git(repo, *args, **kw)


def key_hash(seed_hex, subject, question):
    """Uniform in [0, 1): keyed by the secret seed and the content key only."""
    d = hmac.new(bytes.fromhex(seed_hex), ("%s:%s" % (subject, question)).encode(), hashlib.sha256).digest()
    return int.from_bytes(d, "big") / float(1 << 256)


def parse_kv(text):
    out, rates = {}, {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        k, v = (x.strip() for x in line.split(":", 1))
        if k == "rate":
            q, r = v.split()
            rates[q] = float(r)
        else:
            out[k] = v
    out["rates"] = rates
    return out


def rate_for(spec, question):
    return spec["rates"].get(question, spec["rates"].get("*", 0.0))


def task_name(period, subject, question):
    return "%s%s-%s-%s" % (TASK_PREFIX, period, subject[:12], question[:12])


def publish(repo, body, files, msg, remote="origin", retries=5):
    """Add or replace files on main with one signed commit, using plumbing only. The pre-receive
    hook lets a body write only under bodies/<body>/ and add new tasks to inbox/."""
    who = {"GIT_AUTHOR_NAME": body, "GIT_AUTHOR_EMAIL": body + "@agent",
           "GIT_COMMITTER_NAME": body, "GIT_COMMITTER_EMAIL": body + "@agent"}
    gd = git(repo, "rev-parse", "--absolute-git-dir").strip()
    for _ in range(retries):
        git(repo, "fetch", "-q", remote, "+refs/heads/main:refs/remotes/%s/main" % remote)
        tip = git(repo, "rev-parse", "%s/main" % remote).strip()
        env = {"GIT_INDEX_FILE": os.path.join(gd, "audit.index")}
        git(repo, "read-tree", tip, env=env)
        for path, data in files.items():
            blob = git(repo, "hash-object", "-w", "--stdin", data=data.encode()).strip()
            git(repo, "update-index", "--add", "--cacheinfo", "100644,%s,%s" % (blob, path), env=env)
        tree = git(repo, "write-tree", env=env).strip()
        os.remove(env["GIT_INDEX_FILE"])
        if tree == git(repo, "rev-parse", tip + "^{tree}").strip():
            return tip                                  # nothing new to say
        commit = git(repo, "commit-tree", "-S", "-p", tip, "-m", msg, tree, env=who).strip()
        r = subprocess.run(["git", "-C", repo, "push", "-q", remote, commit + ":refs/heads/main"], capture_output=True)
        if r.returncode == 0:
            return commit
        if b"non-fast-forward" not in r.stderr and b"fetch first" not in r.stderr:
            raise RuntimeError("push refused: " + r.stderr.decode().strip()[:500])
    raise RuntimeError("could not publish after %d attempts" % retries)


def main_file(repo, path, remote="origin"):
    r = subprocess.run(["git", "-C", repo, "show", "%s/main:%s" % (remote, path)], capture_output=True)
    return r.stdout.decode() if r.returncode == 0 else None


def judged_keys(repo, start, end, remote="origin", fetch=True, tips=None):
    """Every (subject, question) first judged inside [start, end) by a non-audit mechanism,
    reading the logs only up to `tips` ({body: commit}) when given."""
    first = {}
    for _, line in jlog.iter_log(repo, remote=remote, fetch=fetch, tips=tips):
        if jlog.validate(line):
            continue
        j = jlog.parse(line)
        if j.sel in ("audit", "drill"):
            continue
        k = (j.subject, j.question)
        ts = jlog.utc(j.ts)
        if k not in first or ts < first[k]:
            first[k] = ts
    return sorted(k for k, ts in first.items() if start <= ts < end)


def selection(repo, spec, seed, remote="origin", fetch=True, tips=None):
    keys = judged_keys(repo, spec["start"], spec["end"], remote, fetch, tips)
    return [(s, q, rate_for(spec, q)) for s, q in keys if key_hash(seed, s, q) < rate_for(spec, q)]


def blind_task(repo, period, subject, question, rate, remote="origin"):
    """The labeller sees the content and the question, never a verdict."""
    q_text = git(repo, "cat-file", "-p", question, check=False).strip() or "(question %s)" % question
    content = subprocess.run(["git", "-C", repo, "cat-file", "-p", subject], capture_output=True)
    body = content.stdout.decode(errors="replace") if content.returncode == 0 else ""
    shown = body if body and len(body) <= 20000 else "(content not in this repository: blob %s)" % subject
    return """# Audit %s: label one item, blind
to: any
needs: label
audit-period: %s
subject: %s
question: %s
rate: %s

Answer the question about the content below. Give your own probabilities for -1 (no), 0
(neither / nothing here) and +1 (yes) before looking at anything any judge said about it.

## Question

%s

## Content

%s

## Done when
- one line is logged with `jlog.py append`, judge = your judge manifest hash, sel=audit,
  prop=%s, and extra fields seed=%s blind=1
""" % (period, period, subject, question, rate, q_text, shown, rate, period)


def review_name(period, seed, subject, question):
    """Review tasks carry neither key nor period in their name, so a drill looks exactly like the
    review of a real escalation (gatekeep.py names those from a hash of the key)."""
    return "review-" + hmac.new(bytes.fromhex(seed), ("%s:%s:%s" % (period, subject, question)).encode(),
                                hashlib.sha256).hexdigest()[:12]


def review_task(repo, period, name, subject, question, judgment, judge_name):
    q_text = git(repo, "cat-file", "-p", question, check=False).strip() or "(question %s)" % question
    content = subprocess.run(["git", "-C", repo, "cat-file", "-p", subject], capture_output=True)
    body = content.stdout.decode(errors="replace") if content.returncode == 0 else ""
    shown = body if body and len(body) <= 20000 else "(content not in this repository: blob %s)" % subject
    neg, zero, pos = judgment.p
    return """# Review: check a verdict
to: any
needs: review
subject: %s
question: %s

%s answered this item with -1: %.2f, 0: %.2f, +1: %.2f. Decide for yourself whether that is right.

## Question

%s

## Content

%s

## Done when
- one line is logged with `jlog.py append`, judge = your judge manifest hash, sel=appeal,
  prop=1, and extra field review=%s
""" % (subject, question, judge_name, neg, zero, pos, q_text, shown, name)


def audit_tasks_in_history(repo, period, remote="origin"):
    """Every audit task for this period ever added to main, wherever it is now."""
    names = git(repo, "log", "%s/main" % remote, "--diff-filter=A", "--name-only", "--format=").split()
    stem = TASK_PREFIX + period + "-"
    found = set()
    for path in names:
        for part in path.split("/"):
            if part.startswith(stem):
                found.add(part)
    return found


def main(argv):
    opts, rates, it = {"remote": "origin"}, {}, iter(argv)
    args = []
    for a in it:
        if a == "--rate-for":
            q = next(it); rates[q] = float(next(it))
        elif a.startswith("--"):
            opts[a[2:]] = next(it)
        else:
            args.append(a)
    if not args or args[0] not in ("commit", "select", "reveal", "verify", "drill", "drills") or "period" not in opts:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, period, remote, repo = args[0], opts["period"], opts["remote"], os.getcwd()
    if not jlog.NAME.match(period):
        print("bad period name", file=sys.stderr)
        return 2
    auditor = opts.get("auditor") or os.environ.get("AGENT_ID")
    if not auditor:
        print("need --auditor or AGENT_ID", file=sys.stderr)
        return 2
    base = "bodies/%s/audit/%s" % (auditor, period)
    seed_file = os.path.join(git(repo, "rev-parse", "--absolute-git-dir").strip(), "audit", period + ".seed")
    git(repo, "fetch", "-q", remote, "+refs/heads/main:refs/remotes/%s/main" % remote)

    if cmd == "commit":
        if main_file(repo, base + ".commit") is not None:
            print("period %s is already committed" % period, file=sys.stderr)
            return 1
        seed = opts.get("seed") or secrets.token_hex(32)
        if not re.fullmatch(r"[0-9a-f]{64}", seed):
            print("--seed must be 64 hex digits", file=sys.stderr)
            return 2
        os.makedirs(os.path.dirname(seed_file), exist_ok=True)
        with open(seed_file, "w") as f:
            f.write(seed + "\n")
        os.chmod(seed_file, 0o600)
        now = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
        lines = ["period: " + period, "seed_sha256: " + hashlib.sha256(bytes.fromhex(seed)).hexdigest(),
                 "start: " + jlog.utc(opts.get("start", now)), "end: " + jlog.utc(opts.get("end", "9999-12-31T00:00:00")),
                 "rate: * %s" % opts.get("rate", "0.02")]
        lines += ["rate: %s %s" % (q, r) for q, r in sorted(rates.items())]
        print(publish(repo, auditor, {base + ".commit": "\n".join(lines) + "\n"}, "audit commit " + period, remote))
        return 0

    spec_text = main_file(repo, base + ".commit")
    if spec_text is None:
        print("no commitment for period %s by %s" % (period, auditor), file=sys.stderr)
        return 1
    spec = parse_kv(spec_text)

    if cmd == "select":
        seed = open(seed_file).read().strip()
        chosen = selection(repo, spec, seed, remote)
        have = audit_tasks_in_history(repo, period, remote)
        files = {"inbox/" + task_name(period, s, q): blind_task(repo, period, s, q, r)
                 for s, q, r in chosen if task_name(period, s, q) not in have}
        if files:
            publish(repo, auditor, files, "audit select %s: %d items" % (period, len(files)), remote)
        print("%d selected, %d new tasks" % (len(chosen), len(files)))
        return 0

    if cmd == "drill":
        import ledger
        seed = open(seed_file).read().strip()
        judge, n_max = opts["judge"], int(opts.get("n", "5"))
        mans = ledger.manifests(repo, remote)
        roles = ledger.roles_of(mans)
        led = ledger.Ledger(jlog.iter_log(repo, remote=remote), roles, tau=float(opts.get("tau", "0.8")))
        wrong = [(s, q, j) for jd, q, _, j, label, _ in led.scored() for s in [j.subject]
                 if jd == judge and max(j.p) >= led.tau and ledger.argmax(j.p) != label]
        wrong.sort(key=lambda x: key_hash(seed, x[0], x[1]))
        drills_file = seed_file[:-len(".seed")] + ".drills"
        known = set(open(drills_file).read().split("\n")) if os.path.exists(drills_file) else set()
        files, chosen = {}, []
        for s, q, j in wrong[:n_max]:
            name = review_name(period, seed, s, q)
            chosen.append("%s %s %s %s" % (s, q, judge, name))
            files["inbox/" + name] = review_task(repo, period, name, s, q, j, mans.get(judge, {}).get("name", judge[:12]))
        with open(drills_file, "w") as f:
            f.write("\n".join(sorted(known | set(chosen))) + "\n")
        if files:
            publish(repo, auditor, files, "review tasks %s: %d" % (period, len(files)), remote)
        print("%d drills from %d confidently wrong verdicts" % (len(files), len(wrong)))
        return 0

    if cmd == "drills":
        import ledger
        reveal = main_file(repo, base + ".reveal")
        if reveal is None:
            print("period %s is not revealed yet" % period, file=sys.stderr)
            return 1
        drills = {}
        for l in reveal.splitlines():
            if l.startswith("drill: "):
                s, q, judge, name = l.split()[1:5]
                drills[name] = (s, q, judge)
        shown = {}
        caught = {}
        lines = list(jlog.iter_log(repo, remote=remote))
        for _, line in lines:
            if jlog.validate(line):
                continue
            j = jlog.parse(line)
            if j.sel == "stream" and any(j.subject == s and j.question == q and j.judge == jd for s, q, jd in drills.values()):
                shown[(j.subject, j.question, j.judge)] = ledger.argmax(j.p)
        for _, line in lines:
            if jlog.validate(line):
                continue
            j = jlog.parse(line)
            name = j.extra.get("review")
            if j.sel == "appeal" and name in drills:
                s, q, jd = drills[name]
                c = caught.setdefault(j.judge, [0, 0])
                c[0] += 1
                c[1] += int(ledger.argmax(j.p) != shown.get((s, q, jd)))
        mans = ledger.manifests(repo, remote)
        for reviewer, (n, ok) in sorted(caught.items()):
            print("%-20s caught %d of %d drills (%.0f%%)" % (mans.get(reviewer, {}).get("name", reviewer[:12]), ok, n, 100.0 * ok / n))
        if not caught:
            print("no drill answered yet (%d drills)" % len(drills))
        return 0

    if cmd == "reveal":
        seed = open(seed_file).read().strip()
        # record the logs as they stand now: verification reads them only up to here
        tips = jlog.log_tips(repo, remote)
        text = "period: %s\nseed: %s\n" % (period, seed) + "".join("log: %s %s\n" % kv for kv in sorted(tips.items()))
        drills_file = seed_file[:-len(".seed")] + ".drills"
        if os.path.exists(drills_file):
            text += "".join("drill: %s\n" % l for l in open(drills_file).read().split("\n") if l.strip())
        print(publish(repo, auditor, {base + ".reveal": text}, "audit reveal " + period, remote))
        return 0

    reveal = main_file(repo, base + ".reveal")
    if reveal is None:
        print("period %s is not revealed yet" % period, file=sys.stderr)
        return 1
    seed = parse_kv(reveal)["seed"]
    if hashlib.sha256(bytes.fromhex(seed)).hexdigest() != spec["seed_sha256"]:
        print("FAIL: the revealed seed does not match its commitment")
        return 1
    # judgments that reached the logs after the reveal could not have been selected: read the logs
    # only as they stood at the reveal
    tips = dict(l.split()[1:3] for l in reveal.splitlines() if l.startswith("log: "))
    jlog.log_tips(repo, remote)                         # make sure every recorded commit is here
    want = {task_name(period, s, q) for s, q, _ in selection(repo, spec, seed, remote, tips=tips)}
    have = audit_tasks_in_history(repo, period, remote)
    skipped, extra = sorted(want - have), sorted(have - want)
    for t in skipped:
        print("SKIPPED " + t)
    for t in extra:
        print("CHERRY-PICKED " + t)
    print("%s: %d selected, %d skipped, %d cherry-picked" % (
        "ok" if not (skipped or extra) else "FAIL", len(want), len(skipped), len(extra)))
    return 0 if not (skipped or extra) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
