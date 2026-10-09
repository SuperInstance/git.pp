#!/usr/bin/env python3
"""forecast.py -- an agent's commitments, written as forecasts the world later resolves.

An agent that only makes files is never told whether they worked. So each thing it makes
registers the question that will resolve it, with the agent's own probability, and the agent
enters the same scoring ledger as every judge:

  forecast.py make --judge J --made FILE --criterion TEXT --p P [--slug NAME]
      Publish bodies/<body>/forecasts/<slug>.md ("Will FILE meet: TEXT?") on main and log the
      agent's forecast on its own judgment log: subject = the made file's blob, question = the
      forecast file's blob, probabilities (1 - P, 0, P).
  forecast.py resolve --judge W --forecast PATH --outcome yes|no|neither
      Log the outcome as judge W, which must be a `world` judge (a test run, an override, a
      person recording what happened): only outcomes the agent did not produce can score it.
  forecast.py open
      List forecasts with no outcome yet.

The body is AGENT_ID (or --body). Standard library only.
"""
import os, re, sys
import audit, jlog, ledger

OUTCOMES = {"yes": (0.0, 0.0, 1.0), "no": (1.0, 0.0, 0.0), "neither": (0.0, 1.0, 0.0)}


def question_text(made_path, made_blob, criterion):
    return "Will %s (blob %s) meet this criterion?\n\n%s\n" % (made_path, made_blob, criterion.strip())


def forecasts_on_main(repo, remote="origin"):
    """[(path, blob)] for every forecast file of every body on main."""
    out = jlog.git(repo, "ls-tree", "-r", "%s/main" % remote, "--", "bodies/", check=False)
    return [(l.split("\t")[1], l.split()[2]) for l in out.splitlines() if "/forecasts/" in l and l.endswith(".md")]


def subject_of(repo, blob):
    m = re.search(r"\(blob ([0-9a-f]{40,64})\)", jlog.git(repo, "cat-file", "-p", blob))
    return m.group(1) if m else None


def main(argv):
    opts, args, it = {"remote": "origin"}, [], iter(argv)
    for a in it:
        if a.startswith("--"):
            opts[a[2:]] = next(it)
        else:
            args.append(a)
    if not args or args[0] not in ("make", "resolve", "open"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    repo, remote = os.getcwd(), opts["remote"]
    body = opts.get("body") or os.environ.get("AGENT_ID")
    jlog.git(repo, "fetch", "-q", remote, "+refs/heads/main:refs/remotes/%s/main" % remote)

    if args[0] == "open":
        mans = ledger.manifests(repo, remote)
        led = ledger.Ledger(jlog.iter_log(repo, remote=remote), ledger.roles_of(mans))
        for path, blob in forecasts_on_main(repo, remote):
            s = subject_of(repo, blob)
            if s and (s, blob) not in led.resolution:
                print(path)
        return 0

    if not body:
        print("need --body or AGENT_ID", file=sys.stderr)
        return 2
    if args[0] == "make":
        made = opts["made"]
        blob = jlog.git(repo, "hash-object", "-w", made).strip()
        slug = opts.get("slug") or re.sub(r"[^A-Za-z0-9._-]+", "-", os.path.splitext(os.path.basename(made))[0]).strip("-")
        path = "bodies/%s/forecasts/%s.md" % (body, slug)
        if audit.main_file(repo, path, remote) is not None:
            print("forecast %s exists already: forecasts are never rewritten" % path, file=sys.stderr)
            return 1
        text = question_text(made, blob, opts["criterion"])
        audit.publish(repo, body, {path: text}, "forecast " + slug, remote)
        q = jlog.git(repo, "hash-object", "--stdin", data=text.encode()).strip()
        p = float(opts["p"])
        jlog.append(repo, body, [jlog.format_line(blob, q, opts["judge"], (1 - p, 0.0, p), forecast=slug)], remote)
        print(path)
        return 0

    # resolve
    mans = ledger.manifests(repo, remote)
    if mans.get(opts["judge"], {}).get("role") != "world":
        print("only a judge with role: world can resolve a forecast", file=sys.stderr)
        return 1
    text = audit.main_file(repo, opts["forecast"], remote)
    if text is None:
        print("no forecast at %s" % opts["forecast"], file=sys.stderr)
        return 1
    q = jlog.git(repo, "hash-object", "--stdin", data=text.encode()).strip()
    s = subject_of(repo, q)
    jlog.append(repo, body, [jlog.format_line(s, q, opts["judge"], OUTCOMES[opts["outcome"]], outcome=opts["outcome"])], remote)
    print("resolved %s: %s" % (opts["forecast"], opts["outcome"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
