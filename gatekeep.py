#!/usr/bin/env python3
"""gatekeep.py -- the gate operator: take one judgment, decide, and leave a record that keeps
the system able to learn about the regions it avoids.

  gatekeep.py --subject FILE|--subject-hash H --question Q --judge J --p NEG ZERO POS
              [--regions r1,r2] [--class CLASS] [--reversible]
  gatekeep.py --batch FILE [--class CLASS] [--reversible]
      FILE has one judgment per line: subject question judge neg zero pos [regions]. The
      ledger is read once and every decision goes to the log in one batch: the way a tick
      should call it.

For one (subject, question) judged by J with probabilities p:
  1. A small, logged share of items bypasses the judge entirely (`bypass:` in soul/policy):
     the only unfiltered view of what the judge would otherwise have suppressed.
  2. Otherwise gate.decide: act on an audited conformal singleton, explore (reversible actions
     only, `explore:`), or escalate.
  3. Log the judgment on the body's log with why it exists and what was decided:
       act      sel=stream   gate=act
       explore  sel=explore  prop=<eps>  gate=explore
       escalate sel=shadow   gate=escalate, plus a review task in inbox/ showing the verdict
       bypass   sel=stream   gate=bypass gate_p=<eps>
     Every line carries regions= (so the ledger never has to guess later where it belonged)
     and cfg= (a hash of the gate configuration, so partial rollouts are visible).

soul/policy lines read here (all optional):
  accept: <class> <rate>   accepted error rate for an action class (default class: default 0.02)
  explore: <eps>           bypass: <eps>           tau: <confidence>      alpha: <conformal alpha>
Prints the decision as one JSON line. Standard library only.
"""
import hashlib, json, os, sys
import audit, gate, jlog, ledger

DEFAULTS = {"explore": "0.02", "bypass": "0.005", "tau": "0.8", "alpha": "0.05", "confidence": "0.95"}


def read_policy(text):
    pol, accept = dict(DEFAULTS), {"default": 0.02}
    for line in (text or "").splitlines():
        if ":" not in line:
            continue
        k, v = (x.strip() for x in line.split(":", 1))
        if k == "accept":
            c, r = v.split()
            accept[c] = float(r)
        elif k in DEFAULTS:
            pol[k] = v
    pol["accept"] = accept
    cfg_src = "\n".join("%s=%s" % (k, pol[k]) for k in sorted(DEFAULTS)) + "".join(
        "\naccept %s=%s" % kv for kv in sorted(accept.items()))
    pol["cfg"] = hashlib.sha1(cfg_src.encode()).hexdigest()[:12]
    return pol


def plan(p, regions, led, pol, judge, question, subject, action_class="default", reversible=False):
    """Pure: the decision and the log line to write. Nothing is written here."""
    coin = gate.explore_coin(subject, question, salt="bypass")
    eps_bypass = float(pol["bypass"])
    extra = {"regions": ",".join(regions), "cfg": pol["cfg"]}
    if eps_bypass > 0 and coin < eps_bypass:
        d = gate.Decision("bypass", None, eps_bypass, "bypass", None, None)
        return d, jlog.format_line(subject, question, judge, p, "stream", 1.0, gate="bypass",
                                   gate_p="%g" % eps_bypass, **extra)
    rec = led.gate_record(judge, question, lambda q: max(q) >= led.tau)
    qh = led.qhats(judge, question, float(pol["alpha"]))
    accept = pol["accept"].get(action_class, pol["accept"]["default"])
    d = gate.decide(p, regions, rec, qh, accept, float(pol["confidence"]), reversible,
                    float(pol["explore"]), subject, question)
    sel, prop = {"act": ("stream", 1.0), "explore": ("explore", d.prop), "escalate": ("shadow", 1.0)}[d.action]
    return d, jlog.format_line(subject, question, judge, p, sel, prop, gate=d.action, **extra)


def escalation_review(repo, subject, question, line, judge_name):
    name = "review-" + hashlib.sha256(("esc:%s:%s" % (subject, question)).encode()).hexdigest()[:12]
    return name, audit.review_task(repo, "", name, subject, question, jlog.parse(line), judge_name)


def main(argv):
    opts, flags, it = {"remote": "origin", "class": "default"}, set(), iter(argv)
    for a in it:
        if a == "--reversible":
            flags.add("reversible")
        elif a == "--p":
            opts["p"] = tuple(float(next(it)) for _ in range(3))
        elif a.startswith("--"):
            opts[a[2:]] = next(it)
    single = "p" in opts and "question" in opts and "judge" in opts and ({"subject", "subject-hash"} & set(opts))
    if not single and "batch" not in opts:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    repo, remote = os.getcwd(), opts["remote"]
    body = opts.get("body") or os.environ.get("AGENT_ID")
    if not body:
        print("need --body or AGENT_ID", file=sys.stderr)
        return 2
    if single:
        subject = opts.get("subject-hash") or jlog.git(repo, "hash-object", "-w", opts["subject"]).strip()
        items = [(subject, opts["question"], opts["judge"], opts["p"], [r for r in opts.get("regions", "").split(",") if r])]
    else:
        items = []
        for l in open(opts["batch"]).read().splitlines():
            f = l.split()
            if len(f) >= 6:
                items.append((f[0], f[1], f[2], tuple(float(x) for x in f[3:6]), f[6].split(",") if len(f) > 6 else []))
    jlog.git(repo, "fetch", "-q", remote, "+refs/heads/main:refs/remotes/%s/main" % remote)
    pol = read_policy(audit.main_file(repo, "soul/policy", remote))
    mans = ledger.manifests(repo, remote)
    led = ledger.Ledger(jlog.iter_log(repo, remote=remote), ledger.roles_of(mans), tau=float(pol["tau"]))
    lines, reviews, outs = [], {}, []
    for subject, question, judge, p, extra_regions in items:
        regions = ["all", "q:" + question[:12]] + extra_regions
        d, line = plan(p, regions, led, pol, judge, question, subject, opts["class"], "reversible" in flags)
        lines.append(line)
        out = {"subject": subject, "action": d.action, "verdict": d.verdict, "reason": d.reason, "region": d.region,
               "bound": None if d.bound is None else round(d.bound, 4), "cfg": pol["cfg"]}
        if d.action == "escalate":
            name, task = escalation_review(repo, subject, question, line, mans.get(judge, {}).get("name", judge[:12]))
            if audit.main_file(repo, "inbox/" + name, remote) is None:
                reviews["inbox/" + name] = task
            out["review"] = name
        outs.append(out)
    if lines:
        jlog.append(repo, body, lines, remote)
    if reviews:
        audit.publish(repo, body, reviews, "escalate %d items" % len(reviews), remote)
    for out in outs:
        print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
