#!/usr/bin/env python3
"""gate.py -- decide whether to act on a judgment, hold it, or escalate it.

A judge's own confidence is a first-order score; it says nothing about whether that confidence
can be trusted here. The gate trusts a verdict only where audits have checked verdicts like it:

  1. Conformal singleton. Act only if the prediction set at the calibrated threshold for this
     region and this kind of verdict is a single label (Mondrian conformal: one threshold per
     region and predicted verdict, so a bad record on one verdict does not blur the others).
     {0} is a verdict ("nothing here"); a set of two or three labels is "unsure".
  2. Audited bound in every region. For each region the item belongs to, take the audited
     record of this judge's confident verdicts of this kind there, and require the
     Clopper-Pearson upper bound on their error rate to be at or below the accepted rate.
     A region with no audits has a bound of 1, so the gate never acts there.
  3. Exploration. Where the gate would not act, an action marked reversible may still be taken
     with a small logged probability, so the value of acting there stays measurable.

Regions must not come from the judge itself (use source, task family, question, or clusters of
an embedding of different lineage): a judge's own clusters share its blind spots.

  gate.py bound N ERRORS [CONFIDENCE]   print the Clopper-Pearson upper bound on an error rate
Standard library only.
"""
import hashlib, math, sys
from collections import namedtuple

LABELS = (-1, 0, 1)
Decision = namedtuple("Decision", "action verdict prop reason region bound")


# --- the bound -----------------------------------------------------------------------------
def _binom_cdf(k, n, p):
    """P(X <= k) for X ~ Binomial(n, p)."""
    if p <= 0:
        return 1.0
    if p >= 1:
        return 1.0 if k >= n else 0.0
    lp, lq = math.log(p), math.log1p(-p)
    total = 0.0
    for i in range(k + 1):
        total += math.exp(math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1) + i * lp + (n - i) * lq)
    return min(total, 1.0)


def upper_bound(n, errors, confidence=0.95):
    """One-sided Clopper-Pearson upper bound on an error rate after `errors` in `n` checks.
    With no checks the bound is 1: nothing has been shown."""
    if n <= 0:
        return 1.0
    if errors >= n:
        return 1.0
    alpha = 1 - confidence
    lo, hi = errors / n, 1.0
    for _ in range(100):                               # bisection: P(X <= errors | hi) = alpha
        mid = (lo + hi) / 2
        if _binom_cdf(errors, n, mid) > alpha:
            lo = mid
        else:
            hi = mid
    return hi


# --- conformal sets ------------------------------------------------------------------------
def calibrate(scores, alpha=0.05):
    """Split-conformal threshold from nonconformity scores (1 - p[true label]) of audited items.
    Returns None when there are too few items to promise 1 - alpha coverage."""
    n = len(scores)
    rank = math.ceil((n + 1) * (1 - alpha))
    if n == 0 or rank > n:
        return None
    return sorted(scores)[rank - 1]


def prediction_set(p, qhat):
    """Labels whose nonconformity 1 - p is within the threshold. qhat None means 'unknown'."""
    if qhat is None:
        return set(LABELS)
    return {lab for lab, x in zip(LABELS, p) if 1 - x <= qhat + 1e-12}


# --- the gate ------------------------------------------------------------------------------
def explore_coin(subject, question, salt=""):
    """A deterministic, uniform [0, 1) draw per item, so exploration decisions replay exactly."""
    d = hashlib.sha256(("%s:%s:%s" % (salt, subject, question)).encode()).digest()
    return int.from_bytes(d[:8], "big") / float(1 << 64)


def decide(p, regions, record, qhats, accept, confidence=0.95, reversible=False, eps=0.0,
           subject="", question="", salt=""):
    """Decide what to do with one judgment.

    p        (neg, zero, pos) from the judge
    regions  the item's regions (judge-independent), e.g. ["all", "q:<hash>", "src:telegram"]
    record   {(region, verdict): (n_audited, n_wrong)} for this judge and question, counting
             only audited verdicts that cleared the same conformal test
    qhats    {(region, verdict): calibrated threshold or None}, verdict being the judge's top label
    accept   the error rate the owner accepts for this action
    """
    regions = list(regions) or ["all"]
    verdict = LABELS[max(range(3), key=lambda i: p[i])]
    # 1. conformal singleton, at the most conservative threshold among the item's regions
    known = [qhats.get((r, verdict)) for r in regions]
    qhat = None if any(q is None for q in known) else max(known)
    pset = prediction_set(p, qhat)
    if len(pset) == 1:
        verdict = next(iter(pset))
        # 2. audited bound in every region
        worst, worst_b = None, -1.0
        for r in regions:
            n, wrong = record.get((r, verdict), (0, 0))
            b = upper_bound(n, wrong, confidence)
            if b > worst_b:
                worst, worst_b = r, b
        if worst_b <= accept:
            return Decision("act", verdict, 1.0, "audited", worst, worst_b)
        reason, region, bound = "unaudited" if record.get((worst, verdict), (0, 0))[0] == 0 else "bound", worst, worst_b
    else:
        reason, region, bound = "unsure" if qhat is not None else "uncalibrated", None, 1.0
    # 3. exploration on reversible actions only
    if reversible and eps > 0 and explore_coin(subject, question, salt) < eps:
        return Decision("explore", verdict, eps, reason, region, bound)
    return Decision("escalate", verdict, 1.0, reason, region, bound)


def aci_step(qhat, covered, alpha=0.05, gamma=0.01):
    """Adaptive conformal update after one audited outcome: widen the threshold after a miss,
    narrow it slowly while the truth keeps landing inside the set."""
    q = (qhat if qhat is not None else 1.0) + gamma * ((0 if covered else 1) - alpha)
    return min(max(q, 0.0), 1.0)


# --- pricing ------------------------------------------------------------------------------
def choose(costs):
    """Pick the cheapest action. costs: {action: (expected_error_cost, ask_cost, info_value)};
    the price of an action is error + ask - value of what it would teach."""
    return min(sorted(costs), key=lambda a: costs[a][0] + costs[a][1] - costs[a][2])


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "bound":
        conf = float(sys.argv[4]) if len(sys.argv) > 4 else 0.95
        print("%.4f" % upper_bound(int(sys.argv[2]), int(sys.argv[3]), conf))
    else:
        print(__doc__.strip())
