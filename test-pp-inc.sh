#!/bin/bash
# test-pp-inc.sh -- property test: views extended push by push equal views rebuilt from nothing.
#   ./test-pp-inc.sh [N]     (N random commits, default 40; AWK selects the awk)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); N=${1:-40}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cd "$W" && git init -q -b main . && mkdir soul && cp "$HERE/soul/axes" soul/axes && cp "$HERE/project.sh" .
printf 'view life  task seq state body part effect\n' >> soul/axes
git add -A && git commit -qm genesis
RANDOM=7; extended=0; mismatches=0; axes_changed=0
for i in $(seq 1 "$N"); do
  b=b$((RANDOM % 3))
  if [ "$i" -eq $((N / 2)) ]; then echo "view hist2  hash seq" >> soul/axes; axes_changed=1    # forces a full rebuild
  else case $((RANDOM % 6)) in
    0|1) mkdir -p inbox; echo "task $((RANDOM % 9))" > "inbox/t$i" ;;                      # new task (contents repeat)
    2) f=$(ls inbox 2>/dev/null | head -1); [ -n "$f" ] && mkdir -p "claimed/$b" && git mv "inbox/$f" "claimed/$b/" ;;
    3) f=$(ls -d claimed/*/* 2>/dev/null | head -1); [ -n "$f" ] && t=${f##*/} && mkdir -p "done/$t" && git mv "$f" "done/$t/task" && echo 0 > "done/$t/status" ;;
    4) mkdir -p "bodies/$b"; echo "caps: cpu $i" > "bodies/$b/manifest" ;;
    5) f=$(git ls-files done | head -1); [ -n "$f" ] && git rm -q "$f" ;;                      # a deletion
  esac; fi
  git add -A; git commit -qm "step $i" --allow-empty
  PP_DEBUG=1 sh ./project.sh >/dev/null 2>"$W/err" || { echo "publish failed at step $i: $(cat "$W/err")"; exit 1; }
  grep -q extending "$W/err" && extended=$((extended + 1))
  want=$(sh ./project.sh build); got=$(git for-each-ref --format='%(refname:lstrip=2) %(objectname)' refs/pp/)
  [ "$want" = "$got" ] || { mismatches=$((mismatches + 1)); echo "  MISMATCH at step $i"; }
done
# names that look like numbers must merge as names: 00, 0, 000, 0e1, 1
sed -n '/^merge_trees() (/,/^)$/p' "$HERE/project.sh" > "$W/mt.sh"; export T=$(mktemp -d) TAB=$(printf '\t')
mk() { i=$(mktemp -u); for p in "$@"; do printf '100644 %s\t%s\n' "$(echo "$p" | git hash-object -w --stdin)" "$p"; done |
       GIT_INDEX_FILE=$i git update-index --index-info; GIT_INDEX_FILE=$i git write-tree; rm -f "$i"; }
old=$(mk 00/a 0/b 000/c 0e1/d 1/e); new=$(mk 00/z 2/f); want=$(mk 00/a 00/z 0/b 000/c 0e1/d 1/e 2/f)
got=$(. "$W/mt.sh"; merge_trees "$old" "$new" t)
[ "$got" = "$want" ] && echo "numeric-looking names merge correctly" || { echo "  MISMATCH merging numeric-looking names"; mismatches=$((mismatches + 1)); }
echo "$N commits: $extended published by extending, $mismatches mismatches against a full rebuild (axes changed midway: $axes_changed)"
rm -rf "$W"; [ "$mismatches" = 0 ] && [ "$extended" -gt $((N / 2)) ] && [ "$extended" -lt "$N" ]
