#!/bin/sh
# project.sh -- views(commit) -> refs/pp/*.  Runs anywhere there is an object store, bare or not.
#
#   project.sh [COMMIT]          build every view in COMMIT's soul/axes and point refs/pp/<view> at it
#   project.sh build [COMMIT]    the same, but only print "<view> <hash>" and move no ref
#   project.sh verify [REMOTE]   fetch REMOTE's refs/pp/*, rebuild them from the commit they name
#                                using that commit's own project.sh, and compare hashes
#
# A view is a tree over the SAME blobs as the source commit, addressed by axes instead of by path.
# It costs tree objects only. It is a pure function of the commit: fixed author, the source's date,
# no signature. So nobody has to be trusted for it -- anyone can recompute it and compare one hash.
set -u; export LC_ALL=C
export GIT_AUTHOR_NAME=pp GIT_AUTHOR_EMAIL=pp@agent GIT_COMMITTER_NAME=pp GIT_COMMITTER_EMAIL=pp@agent
G=$(git rev-parse --absolute-git-dir) || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; TAB=$(printf '\t')
die() { echo "project: $*" >&2; exit 1; }

# The whole projection: read soul/axes, then one cell per line, and write one file per view.
PROJECT='
function fail(msg) { print "project: " msg | "cat 1>&2"; err = 1 }

FILENAME == ARGV[1] {                                  # ---- soul/axes
  gsub(/\r/, ""); sub(/#.*/, ""); n = split($0, w, " "); if (!n) next
  if (w[1] == "view") {
    if (n < 3 || w[2] !~ /^[a-z0-9][a-z0-9-]*$/ || (w[2] in named)) fail("bad view line: " $0)
    named[w[2]] = ++V; vname[V] = w[2]; vn[V] = n - 2; vdom[V] = "T"
    for (i = 3; i <= n; i++) { vax[V, i - 2] = w[i]; if (w[i] == "seq") vdom[V] = "H" }
    printf "" > (D "/v." w[2])
  } else {
    pat[++P] = w[1]; pk[P] = n - 1; m = split(w[1], q, "/")
    for (i = 1; i <= m; i++)
      if ((q[i] ~ /[<>]/ && q[i] !~ /^[^<>]*<[a-z][a-z0-9_]*>[^<>]*$/ && (i < m || q[i] !~ /^<[a-z][a-z0-9_]*\.\.\.>$/)) ||
          q[i] ~ /<(hash|path|seq)(\.\.\.)?>/) fail("bad pattern: " w[1])
    for (i = 2; i <= n; i++) { pc[P, i - 1] = w[i]; if (w[i] !~ /^[a-z][a-z0-9_]*=./ || w[i] ~ /^(hash|path|seq)=/) fail("bad constant: " w[i]) }
  }
  if (err) exit; next
}

function bind(p,    q, m, i, j, seg, lt, gt, name, pre, suf, val, rest, e) {   # does path s[1..np] fit pattern p?
  m = split(pat[p], q, "/"); nb = 0; rest = 0
  for (i = 1; i <= m && !rest; i++) {
    if (i > np) return 0
    seg = q[i]; val = s[i]; lt = index(seg, "<"); gt = index(seg, ">")
    if (!lt) { if (val != seg) return 0; continue }
    name = substr(seg, lt + 1, gt - lt - 1); pre = substr(seg, 1, lt - 1); suf = substr(seg, gt + 1)
    if (name ~ /\.\.\.$/) { rest = 1; sub(/\.\.\.$/, "", name); for (j = i + 1; j <= np; j++) val = val "/" s[j] }
    else if (length(val) <= length(pre suf) || substr(val, 1, length(pre)) != pre ||
             substr(val, length(val) - length(suf) + 1) != suf) return 0
    else val = substr(val, length(pre) + 1, length(val) - length(pre suf))
    bn[++nb] = name; bv[nb] = val
  }
  if (!rest && np != m) return 0
  for (i = 1; i <= nb; i++) ax[bn[i]] = bv[i]
  for (i = 1; i <= pk[p]; i++) { e = index(pc[p, i], "="); ax[substr(pc[p, i], 1, e - 1)] = substr(pc[p, i], e + 1) }
  return 1
}

function cell(dom, mode, hash, path,    p, v, i, k, n, a, out, pre) {          # one blob at one coordinate
  if (path ~ /^"/) { fail("path cannot be projected: " path); return }
  for (k in ax) delete ax[k]
  ax["hash"] = substr(hash, 1, 2) "/" substr(hash, 3); ax["path"] = path; if (dom == "H") ax["seq"] = seq
  np = split(path, s, "/"); for (p = 1; p <= P; p++) if (bind(p)) break
  for (v = 1; v <= V; v++) {
    if (vdom[v] != dom || !(vax[v, 1] in ax)) continue
    out = ""; for (i = 1; i <= vn[v]; i++) if (vax[v, i] in ax) out = out (out == "" ? "" : "/") ax[vax[v, i]]
    if ((v, out) in leaf) fail("view " vname[v] ": " path " and " leaf[v, out] " both land on " out)
    leaf[v, out] = path; n = split(out, a, "/"); pre = ""
    for (i = 1; i < n; i++) { pre = pre (i > 1 ? "/" : "") a[i]; dir[v, pre] = 1 }
    print mode " " hash "\t" out > (D "/v." vname[v])
  }
}

/^C /  { seq = sprintf("%06d-%s", ++count, substr($0, 3, 12)); next }           # ---- history: git log --raw
/^:/   { split($1, f, " "); if (f[5] != "D") cell("H", f[2], f[4], $2); next }
/^$/   { next }
       { split($1, f, " "); cell("T", f[1], f[3], $2) }                         # ---- the tip: git ls-tree -r

END    { for (k in leaf) if (k in dir) { split(k, a, SUBSEP); fail("view " vname[a[1]] ": " a[2] " is both a file and a directory") }
         exit err }
'

build() { # build <commit> -> prints "<view> <hash>" per view, sorted. Writes objects, moves no ref.
  src=$(git rev-parse -q --verify "$1^{commit}") || die "no such commit: $1"
  git show "$src:soul/axes" >"$T/axes" 2>/dev/null || die "$src has no soul/axes"
  rm -f "$T"/v.*
  { git -c core.quotePath=false ls-tree -r "$src"
    git -c core.quotePath=false log --reverse --first-parent -m --no-renames --root --raw --no-abbrev \
        --format='C %H' "$src"; } >"$T/cells"
  ${AWK:-awk} -F"$TAB" -v D="$T" "$PROJECT" "$T/axes" "$T/cells" || die "views of $src not built"
  when=$(git log -1 --format=%ct "$src")
  for f in "$T"/v.*; do
    [ -f "$f" ] || continue; name=${f##*/v.}; rm -f "$T/index"
    GIT_INDEX_FILE="$T/index" git update-index --index-info <"$f" &&
      tree=$(GIT_INDEX_FILE="$T/index" git write-tree) || die "view $name: cannot write tree"
    echo "$name $(printf 'pp/%s\n\nSource: %s\n' "$name" "$src" |
      GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" git -c i18n.commitEncoding=UTF-8 commit-tree "$tree")"
  done
}

publish() { # all views move together or none do; views no longer declared are removed
  exec 9>"$G/pp.lock"; flock 9
  build "${1:-refs/heads/main}" >"$T/built" || exit 1
  { sed 's|^\([^ ]*\) |update refs/pp/\1 |' "$T/built"
    git for-each-ref --format='%(refname)' refs/pp/ | while read -r r; do
      grep -q "^${r#refs/pp/} " "$T/built" || echo "delete $r"; done
  } | git update-ref --stdin && cat "$T/built"
}

verify() { # trust nothing but main: the views must be exactly what their source commit computes
  remote=${1:-origin}
  trust=$(git rev-parse -q --verify "${TRUST:-refs/verified/main}" ||
          git rev-parse -q --verify "refs/remotes/$remote/main") || die "no trusted main to verify against"
  git fetch -q --prune "$remote" '+refs/pp/*:refs/pp-seen/*' || die "cannot reach $remote"
  git for-each-ref --format='%(refname:lstrip=2) %(objectname)' refs/pp-seen/ >"$T/theirs"
  [ -s "$T/theirs" ] || die "$remote publishes no views"
  src=$(while read -r _ c; do git log -1 --format=%B "$c" | sed -n 's/^Source: //p'; done <"$T/theirs" | sort -u)
  # the source's projector is about to be executed, so it must be a commit we already trust
  [ "$(echo "$src" | wc -l)" -eq 1 ] && git merge-base --is-ancestor "$src" "$trust" 2>/dev/null ||
    die "views do not name a single commit on trusted main"
  git show "$src:project.sh" >"$T/projector" 2>/dev/null || die "$src has no project.sh"
  sh "$T/projector" build "$src" >"$T/ours" || die "cannot rebuild the views of $src"
  ${AWK:-awk} 'NR == FNR { ours[$1] = $2; next }
       { seen[$1]; if (!($1 in ours)) { print "UNDECLARED " $1; bad = 1 }
                   else if (ours[$1] != $2) { print "MISMATCH " $1 ": published " $2 ", recomputed " ours[$1]; bad = 1 } }
       END { for (n in ours) if (!(n in seen)) { print "MISSING " n; bad = 1 }; exit bad }' "$T/ours" "$T/theirs" || exit 1
  echo "verified $(wc -l <"$T/ours" | tr -d ' ') views of $src ($(git rev-list --count "$src..$trust") behind main)"
}

case ${1:-} in
  build)  build "${2:-refs/heads/main}" ;;
  verify) verify "${2:-}" ;;
  *)      publish "${1:-}" ;;
esac
