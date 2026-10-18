#!/bin/bash
# evidence-guard.sh — the output-path guard for a controlled run's evidence (M6-D1b). Source it from a run script; every
# path a script writes, and every destination it hands to a WSL or Windows subprocess, goes through one of the functions
# below. Prior evidence roots are read-only inputs: a destination that does not resolve PHYSICALLY under the active run
# root or the declared state root is refused before anything is written.
#
#   evg_claim  <run-root> [<state-root>]   creates the run root EXCLUSIVELY (an existing directory is refused: choose a new
#                                          run identifier, never clean or reuse), creates the state root exclusively when
#                                          given, writes the claim record <run-root>/.evidence-root (never rewritten)
#   evg_attach <run-root> [<state-root>]   a later script of the same run: requires the claim record; sets the active roots;
#                                          refuses a SEALED root (its final manifest sha256.txt present)
#   evg_check  <path>                      validates a destination (WSL or Windows form) and prints its canonical WSL path:
#                                          the Windows form is converted first; "." and ".." are normalized; symlinks in the
#                                          existing part are followed; the deepest existing ancestor is then walked up
#                                          PHYSICALLY (device:inode against the active roots), so an alias, a short name, a
#                                          link or a traversal that lands outside the roots is refused; exit 2 on refusal
#   evg_out    <path>                      a finalized capture: evg_check, then the file is created exclusively (no-clobber;
#                                          an existing file is refused, never truncated); prints the canonical path
#   evg_log    <path>                      a live append log of this attempt: evg_check only (the file may exist)
#   evg_dir    <path>                      a directory under the roots: evg_check + mkdir (existing allowed)
#   evg_win    <path>                      evg_check and print the Windows form, for a destination passed to a Windows
#                                          subprocess (cmd.exe, powershell.exe)
#   evg_attempt <phase>                    a fresh attempt directory <run-root>/<phase>-attempt<N> (N = the next free number,
#                                          created exclusively); prints the path. A retry never reuses an earlier attempt.
#   evg_label  <label>                     refuses a capture label whose files <run-root>/<label>-* already exist
#
# Nothing here deletes, renames or truncates. The guard is a tooling safeguard, not an evidence-storage subsystem: it does
# not hash, seal or manage evidence; the run's manifest is still written last by the run's own verification.
# Requires bash, realpath, stat, wslpath (for Windows forms). Exit codes: 0 ok, 2 refused, 3 usage / not attached.

EVG_RUN_ROOT=""; EVG_STATE_ROOT=""; EVG_RUN_ID=""

_evg_err() { echo "evidence-guard: REFUSED: $*" >&2; }
_evg_id() { stat -c '%d:%i' -- "$1" 2>/dev/null; }

# the canonical WSL form of a destination given in WSL or Windows form (nothing is touched)
_evg_canon() {
  local p=$1 u
  case "$p" in
    '') _evg_err "empty path"; return 2;;
    [A-Za-z]:[\\/]*|\\\\*) u=$(wslpath -u -- "$p" 2>/dev/null) || { _evg_err "Windows path does not convert: $p"; return 2; };;
    *\\*) _evg_err "a backslash in a non-Windows path: $p"; return 2;;
    /*) u=$p;;
    *) u=$PWD/$p;;
  esac
  realpath -m -- "$u"
}

# is the deepest existing ancestor of <abs> physically under <root>? (device:inode walk-up; symlinks, aliases and short
# names all resolve to the same directory identity)
_evg_under() {
  local abs=$1 root=$2 d=$1 rid cur id
  rid=$(_evg_id "$root") || return 1
  while [ ! -e "$d" ]; do d=$(dirname -- "$d"); done
  [ -d "$d" ] || d=$(dirname -- "$d")
  cur=$(cd -P -- "$d" 2>/dev/null && pwd -P) || return 1
  while :; do
    id=$(_evg_id "$cur") || return 1
    [ "$id" = "$rid" ] && return 0
    [ "$cur" = / ] && return 1
    cur=$(cd -P -- "$cur/.." 2>/dev/null && pwd -P) || return 1
  done
}

evg_claim() {
  local root=$1 state=${2:-}
  [ -n "$root" ] || { echo "evidence-guard: usage: evg_claim <run-root> [<state-root>]" >&2; return 3; }
  case "$root" in /*) ;; *) _evg_err "the run root must be absolute: $root"; return 2;; esac
  [ -e "$root" ] && { _evg_err "the run root already exists: $root (choose a NEW run identifier; never clean or reuse)"; return 2; }
  [ -d "$(dirname -- "$root")" ] || { _evg_err "the run root's parent does not exist: $(dirname -- "$root")"; return 2; }
  mkdir -- "$root" || { _evg_err "cannot create the run root: $root"; return 2; }
  if [ -n "$state" ]; then
    case "$state" in /*) ;; *) _evg_err "the state root must be absolute: $state"; return 2;; esac
    [ -e "$state" ] && { _evg_err "the state root already exists: $state"; return 2; }
    mkdir -- "$state" || { _evg_err "cannot create the state root: $state"; return 2; }
    chmod 700 -- "$state" 2>/dev/null || true   # effective on ext4 (the run's state root); a Windows filesystem ignores modes
  fi
  EVG_RUN_ROOT=$(realpath -- "$root"); EVG_STATE_ROOT=${state:+$(realpath -- "$state")}; EVG_RUN_ID=$(basename -- "$EVG_RUN_ROOT")
  ( set -o noclobber; printf 'run_id\t%s\nrun_root\t%s\nstate_root\t%s\nclaimed_utc\t%s\nguard_sha256\t%s\n' "$EVG_RUN_ID" "$EVG_RUN_ROOT" "$EVG_STATE_ROOT" "$(date -u +%FT%TZ)" "$(sha256sum -- "${BASH_SOURCE[0]}" | cut -c1-64)" > "$EVG_RUN_ROOT/.evidence-root" ) || { _evg_err "cannot write the claim record"; return 2; }
  echo "evidence-guard: claimed run root $EVG_RUN_ROOT${EVG_STATE_ROOT:+ and state root $EVG_STATE_ROOT} (run id $EVG_RUN_ID)"
}

evg_attach() {
  local root=$1 state=${2:-}
  [ -n "$root" ] || { echo "evidence-guard: usage: evg_attach <run-root> [<state-root>]" >&2; return 3; }
  [ -d "$root" ] && [ -f "$root/.evidence-root" ] || { _evg_err "not a claimed run root (no .evidence-root): $root"; return 2; }
  # M6-F2a: a SEALED root (its final manifest sha256.txt written) is historical evidence: it is never attached again, so no
  # guarded script can add a file to it (the claim record alone cannot tell an old root from the active one)
  [ -e "$root/sha256.txt" ] && { _evg_err "the run root is sealed (sha256.txt present): $root — historical evidence is read-only"; return 2; }
  EVG_RUN_ROOT=$(realpath -- "$root"); EVG_RUN_ID=$(basename -- "$EVG_RUN_ROOT")
  grep -q "^run_root	$EVG_RUN_ROOT\$" "$EVG_RUN_ROOT/.evidence-root" || { _evg_err "the claim record names another root than $EVG_RUN_ROOT"; return 2; }
  if [ -n "$state" ]; then
    [ -d "$state" ] || { _evg_err "the state root does not exist: $state"; return 2; }
    EVG_STATE_ROOT=$(realpath -- "$state")
    grep -q "^state_root	$EVG_STATE_ROOT\$" "$EVG_RUN_ROOT/.evidence-root" || { _evg_err "the claim record names another state root than $EVG_STATE_ROOT"; return 2; }
  else
    EVG_STATE_ROOT=""
  fi
}

evg_check() {
  local p=$1 abs
  [ -n "$EVG_RUN_ROOT" ] || { echo "evidence-guard: not attached (evg_claim / evg_attach first)" >&2; return 3; }
  abs=$(_evg_canon "$p") || return 2
  if _evg_under "$abs" "$EVG_RUN_ROOT" || { [ -n "$EVG_STATE_ROOT" ] && _evg_under "$abs" "$EVG_STATE_ROOT"; }; then
    printf '%s\n' "$abs"
  else
    _evg_err "destination outside the active roots: $p -> $abs (run root $EVG_RUN_ROOT${EVG_STATE_ROOT:+, state root $EVG_STATE_ROOT})"; return 2
  fi
}

evg_out() {
  local abs
  abs=$(evg_check "$1") || return 2
  [ -e "$abs" ] && { _evg_err "finalized capture already exists (no-clobber): $abs"; return 2; }
  [ -d "$(dirname -- "$abs")" ] || { _evg_err "the capture's directory does not exist: $(dirname -- "$abs")"; return 2; }
  ( set -o noclobber; : > "$abs" ) 2>/dev/null || { _evg_err "cannot create the capture exclusively: $abs"; return 2; }
  printf '%s\n' "$abs"
}

evg_log() {
  local abs
  abs=$(evg_check "$1") || return 2
  [ -d "$(dirname -- "$abs")" ] || { _evg_err "the log's directory does not exist: $(dirname -- "$abs")"; return 2; }
  printf '%s\n' "$abs"
}

evg_dir() {
  local abs
  abs=$(evg_check "$1") || return 2
  mkdir -p -- "$abs" || { _evg_err "cannot create the directory: $abs"; return 2; }
  printf '%s\n' "$abs"
}

evg_win() {
  local abs
  abs=$(evg_check "$1") || return 2
  wslpath -w -- "$abs" 2>/dev/null || { _evg_err "no Windows form for $abs"; return 2; }
}

evg_attempt() {
  local phase=$1 n=1 d
  [ -n "$EVG_RUN_ROOT" ] || { echo "evidence-guard: not attached" >&2; return 3; }
  case "$phase" in ''|*/*|*' '*|.*) _evg_err "bad phase name: '$phase'"; return 2;; esac
  while :; do
    d=$EVG_RUN_ROOT/$phase-attempt$n
    if [ ! -e "$d" ] && mkdir -- "$d" 2>/dev/null; then printf '%s\n' "$d"; return 0; fi
    n=$((n + 1)); [ "$n" -gt 999 ] && { _evg_err "too many attempts for $phase"; return 2; }
  done
}

evg_label() {
  local label=$1 n
  [ -n "$EVG_RUN_ROOT" ] || { echo "evidence-guard: not attached" >&2; return 3; }
  case "$label" in ''|*/*|*' '*|*'*'*|.*) _evg_err "bad label: '$label'"; return 2;; esac
  n=$(find "$EVG_RUN_ROOT" -maxdepth 1 -name "$label-*" | wc -l)
  [ "$n" = 0 ] || { _evg_err "label '$label' already has $n capture file(s) under $EVG_RUN_ROOT (choose a new label)"; return 2; }
  return 0
}
