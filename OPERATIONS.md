# Operating a git.pp fleet

How to stand the system up on real machines: the Oracle box as the remote, the owner's machine,
and any number of bodies. Every shell block below that starts with `# [machine]` is executed
verbatim, in order, by `test-ops.sh`, so this guide is tested on every push.

Conventions in the blocks:

- `$REMOTE` is the fleet remote as the other machines reach it, for example
  `oracle:fleet.git` over SSH. On the Oracle box itself it is `~/fleet.git`.
- `$GITPP` is a checkout of this repository on that machine.
- Each machine has its own signing key at `~/.ssh/fleet`.

Requirements on every machine: git 2.34 or newer (SSH signing), OpenSSH 8.2 or newer
(`ssh-keygen -Y`), `flock`, any POSIX `sh` and `awk`, and Python 3.8 or newer for the judgment
tools. Debian, Ubuntu, WSL and the Uno Q's Debian all qualify.

## 1. Keys

Every machine that will write makes one key. Only the public half ever leaves the machine.

```sh
# [casey] make the owner's signing key
mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N '' -C casey -f ~/.ssh/fleet
```

```sh
# [oracle] make the Oracle body's signing key
mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N '' -C oracle -f ~/.ssh/fleet
```

```sh
# [laptop] make the laptop body's signing key
mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N '' -C laptop -f ~/.ssh/fleet
```

Send each body's `~/.ssh/fleet.pub` to the owner, who saves it as `~/<body>.pub`.

## 2. The remote

The Oracle box is always on, so it holds the bare repository everyone pushes to.

```sh
# [oracle] create the bare remote
git init -q --bare -b main ~/fleet.git
```

## 3. Genesis

The owner writes the constitution: who may sign, the owner, the lease, the coordinate system,
the first question, and the judge manifests: the owner as labeller, the student model, and the
laptop's agent. On a v2 log line a judge is named by its manifest's blob hash. Everything in `soul/` stays owner-only.

```sh
# [casey] write and sign the genesis commit
git clone -q "$REMOTE" ~/fleet 2>/dev/null; cd ~/fleet
git config gpg.format ssh && git config user.signingkey ~/.ssh/fleet
git config user.name casey && git config user.email casey@fleet
for f in tick.sh project.sh agent-exec.sh jlog.py audit.py gate.py ledger.py gatekeep.py shipgate.py forecast.py window.py; do
  cp "$GITPP/$f" .
done
mkdir -p soul judges questions && cp "$GITPP/soul/axes" soul/axes
echo "casey $(cut -d' ' -f1,2 ~/.ssh/fleet.pub)" > soul/allowed_signers
printf 'owner: casey\nlease: 3600\naccept: default 0.02\nexplore: 0.02\nbypass: 0.005\n' > soul/policy
printf 'Is this good?\n' > questions/root.md
printf 'name: casey\nkind: human\nrole: labeller\n' > judges/casey.md
printf 'name: intuition-student-v1\nkind: model\nrole: judge\n' > judges/student.md
printf 'name: laptop-agent\nkind: agent\nrole: judge\n' > judges/laptop-agent.md
git add -A && git commit -qS -m genesis && git push -q origin main
```

Then the remote gets its law. Hooks are installed by hand: a push can never change them.

```sh
# [oracle] install the hooks on the remote
cp "$GITPP/pre-receive" "$GITPP/post-receive" ~/fleet.git/hooks/
chmod +x ~/fleet.git/hooks/pre-receive ~/fleet.git/hooks/post-receive
```

## 4. Admitting bodies

A body exists once its key is in `soul/allowed_signers`. Only the owner can add it.

```sh
# [casey] admit the oracle and laptop bodies
cd ~/fleet && git pull -q
for b in oracle laptop; do echo "$b $(cut -d' ' -f1,2 ~/$b.pub)" >> soul/allowed_signers; done
git add soul/allowed_signers && git commit -qS -m "admit oracle, laptop" && git push -q origin main
```

Each body then clones once and configures signing. The clone belongs to the tick: every sync
hard-resets it and runs `git clean -fdx`, so never keep anything else in it.

```sh
# [laptop] join the fleet
git clone -q "$REMOTE" ~/fleet && cd ~/fleet
git config gpg.format ssh && git config user.signingkey ~/.ssh/fleet
AGENT_ID=laptop CAPS="cpu gpu" sh tick.sh
```

```sh
# [oracle] join the fleet as a body too
git clone -q ~/fleet.git ~/fleet && cd ~/fleet
git config gpg.format ssh && git config user.signingkey ~/.ssh/fleet
AGENT_ID=oracle CAPS="cpu" sh tick.sh
```

The first tick publishes the body's manifest (`bodies/<id>/manifest`) and its heartbeat.

## 5. Work

Anyone who can sign drops a task into `inbox/`. A task can require capabilities with a
`needs:` line.

```sh
# [casey] drop a task
cd ~/fleet && git pull -q && mkdir -p inbox     # git keeps no empty directories
printf '# Say hello\nneeds: gpu\n\nWrite one line greeting the fleet.\n' > inbox/001-hello
git add inbox/001-hello && git commit -qS -m "task 001-hello" && git push -q origin main
```

A body works one task per tick. `agent-exec.sh` compiles the task's window, gives it to the
agent command on stdin, and keeps it beside the result. Replace `AGENT_CMD` with the real model
call; it runs in the result directory and writes its files there.

```sh
# [laptop] tick: claim the task, run the agent, deliver
cd ~/fleet && AGENT_ID=laptop CAPS="cpu gpu" EXEC="$PWD/agent-exec.sh" AGENT_CMD='echo "hello, fleet" > answer' sh tick.sh
```

```sh
# [casey] read the result and what the agent knew
cd ~/fleet && git pull -q && cat done/001-hello/answer
git log -1 --format=%B | grep '^Window: '
```

## 6. Checking the views

The remote rebuilds `refs/pp/*` after every push. Any body can check them by recomputing.

```sh
# [laptop] verify the derived views
cd ~/fleet && sh project.sh verify origin
```

## 7. Judgments

The student keeps writing its local log; a cron job moves new lines into the body's log ref.

```sh
# [oracle] move the local judgment log into git
cd ~/fleet && printf '2026-10-07T08:00:00\t%s\t%s\tintuition-student-v1\t0.0400\t0.1100\t0.8500\n' \
  "$(printf 'hello' | git hash-object --stdin)" "$(git rev-parse HEAD:questions/root.md)" > ~/judgment-log.tsv
python3 jlog.py sync --body oracle ~/judgment-log.tsv
python3 jlog.py sync --body oracle ~/judgment-log.tsv
```

The second run prints `up to date`: lines already in the log are never appended twice.

## 8. Audits

The Oracle is the auditor. Each period it commits to a secret seed and a time window, selects
items first judged inside the window, and reveals the seed when the period closes; anyone can
then verify the selection. The example audits everything (`--rate 1`); a real fleet samples a
few percent, more in strata it worries about.

```sh
# [oracle] run one audit period
cd ~/fleet && python3 audit.py commit --period w41 --auditor oracle --rate 1 \
  --start 2026-10-05T00:00:00 --end 2026-10-12T00:00:00
python3 audit.py select --period w41 --auditor oracle
python3 audit.py reveal --period w41 --auditor oracle
```

```sh
# [laptop] verify the auditor
cd ~/fleet && python3 audit.py verify --period w41 --auditor oracle
```

## 9. The gate

The gate operator decides, for each judgment, whether to act, explore or escalate. A judge with
no audited track record in a region never acts there: its verdicts go to people as review tasks
in `inbox/`, which is how the record starts. Call it once per tick with the tick's whole batch.

```sh
# [oracle] gate a batch of judgments
cd ~/fleet && git fetch -q && Q=$(git rev-parse origin/main:questions/root.md)
ST=$(git rev-parse origin/main:judges/student.md)
printf '%s %s %s 0.02 0.03 0.95\n' "$(printf 'deploy' | git hash-object --stdin)" "$Q" "$ST" > ~/batch
AGENT_ID=oracle python3 gatekeep.py --batch ~/batch
```

A body's agent reaches the gate through `agent-exec.sh`: whatever it writes to `judgments` in
its result directory is gated as one batch, and the decisions are kept beside the result.

```sh
# [casey] drop a task that needs judging
cd ~/fleet && git pull -q
printf '# Check the deploy\n\nIs the deploy plan safe?\n' > inbox/002-check
git add inbox/002-check && git commit -qS -m "task 002-check" && git push -q origin main
```

```sh
# [oracle] tick: the agent judges, the gate decides
cd ~/fleet && git fetch -q && export ST=$(git rev-parse origin/main:judges/student.md) Q=$(git rev-parse origin/main:questions/root.md)
AGENT_ID=oracle CAPS=cpu EXEC="$PWD/agent-exec.sh" \
  AGENT_CMD='printf "%s %s %s 0.10 0.10 0.80\n" "$(git hash-object window.md)" "$Q" "$ST" > judgments' sh tick.sh
git pull -q && cat done/002-check/gate.jsonl
```

## 10. Forecasts

An agent's work is scored by the world, not by itself. When it makes something it publishes a
forecast of how it will turn out; later a `world` judge (a test run, or a person recording what
happened) resolves it, and the agent enters the same ledger as every judge. The owner first
names who may speak for the world.

```sh
# [casey] admit a world judge
cd ~/fleet && git pull -q
printf 'name: casey-world\nkind: human\nrole: world\n' > judges/casey-world.md
git add judges && git commit -qS -m "world judge" && git push -q origin main
```

```sh
# [laptop] forecast that the greeting will land
cd ~/fleet && git pull -q
AGENT_ID=laptop python3 forecast.py make --judge "$(git rev-parse HEAD:judges/laptop-agent.md)" --made done/001-hello/answer \
  --criterion "the owner reads it as a greeting" --p 0.9 --slug hello
```

```sh
# [casey] resolve the forecast
cd ~/fleet && git pull -q && python3 forecast.py open
AGENT_ID=casey python3 forecast.py resolve --judge "$(git rev-parse HEAD:judges/casey-world.md)" \
  --forecast bodies/laptop/forecasts/hello.md --outcome yes
python3 forecast.py open | wc -l
```

## 11. Schedules

Run the tick from cron (or a systemd timer) on every body. Intervals follow the body's nature:
fast where it is cheap, slow where it is expensive. The lease in `soul/policy` must be longer
than the slowest body's interval.

```
# laptop: every 5 minutes
*/5 * * * *  cd ~/fleet && AGENT_ID=laptop CAPS="cpu gpu" EXEC=$HOME/fleet/agent-exec.sh AGENT_CMD='…' sh tick.sh >>~/.fleet.log 2>&1
# kimi: every 30 minutes
*/30 * * * * cd ~/fleet && AGENT_ID=kimi CAPS="cpu net" EXEC=$HOME/fleet/agent-exec.sh AGENT_CMD='…' sh tick.sh >>~/.fleet.log 2>&1
# oracle: every 5 minutes, reaping dead claims; judgments every 5; audits daily and weekly
*/5 * * * *  cd ~/fleet && AGENT_ID=oracle CAPS=cpu REAP=1 sh tick.sh >>~/.fleet.log 2>&1
*/5 * * * *  cd ~/fleet && python3 jlog.py sync --body oracle ~/judgment-log.tsv >>~/.fleet.log 2>&1
17 3 * * *   cd ~/fleet && python3 audit.py select --period "$(date +\%G-w\%V)" --auditor oracle >>~/.fleet.log 2>&1
```

At the start of each ISO week commit the new period, and reveal the old one once its last
select has run.

## Troubleshooting

- **A push is rejected with `no signature trusted by its parent`.** The body's key is not in
  `soul/allowed_signers` at the parent commit, or `gpg.format`/`user.signingkey` is not set in
  its clone.
- **`tick: untrusted commit` and the body halts.** Something on main is unsigned or signed by
  an unknown key. Nothing will happen on that body until a human looks; that is intended.
- **A body is reaped while working.** Its heartbeat is older than the lease: a sleeping
  laptop, or a clock that ran behind (WSL after sleep). Lengthen the lease or fix the clock.
- **`push refused: ... line 1: judge`.** A v2 judgment line names its judge by the blob hash of
  a manifest under `judges/` on main. Names are accepted only on v0 lines from `jlog.py sync`.
- **`refs/pp` views are behind.** A push changed `soul/axes` to something not one-to-one; the
  pusher was told why. `project.sh verify` reports how many commits behind they are.
