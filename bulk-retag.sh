#!/usr/bin/env bash
# bulk-retag.sh — reliably set the same tag field(s) on every audio file under a directory.
#
# Uses ffmpeg: format-universal (mp3/flac/m4a/mpc/wma/ogg/opus/aac), correct UTF encoding,
# lossless stream-copy (-c copy), preserves embedded cover art (-map 0). Backs up existing
# tags FIRST, replaces each file atomically, then RE-READS every file with ffprobe to prove
# the tags actually landed — because taggers (ffmpeg included) can exit 0 and write nothing.
#
# Usage:  bulk-retag.sh [--dry-run] <dir> KEY=VALUE [KEY=VALUE ...]
#   KEYs are ffmpeg -metadata keys: artist, album_artist, album, disc, track, date, genre, title, ...
#   --dry-run  list the files that WOULD be retagged, write nothing.
#
# Example (fold a whole discography folder under one artist):
#   bulk-retag.sh "/path/to/Music/Some Artist" \
#       artist="Some Artist" album_artist="Some Artist"
#
# TWO THINGS THIS GETS RIGHT THAT THE OBVIOUS VERSION DOESN'T (both verified, both bite Ogg):
#
#   1. Ogg-family (.ogg/.opus) keeps its tags at the STREAM level, not the container level.
#      `-metadata artist=X` alone exits 0 and leaves the OLD artist in place. So every tag is
#      written at BOTH levels (-metadata AND -metadata:s:a). Harmless on mp3/flac/m4a.
#   2. For the same reason `ffprobe -show_entries format_tags` reads EMPTY on .ogg/.opus even
#      when tags are fine. Backup and verification here read format_tags AND stream_tags.
#
# Tag backups are written OUTSIDE this script's directory so the skill stays clean and
# portable. Default: ${TMPDIR:-/tmp}/relabel-audio-tags/. Override with:
#   RETAG_BACKUP_DIR=/somewhere/durable bulk-retag.sh ...
# Each run gets its own timestamped file — re-running never clobbers an earlier backup.
#
# NOTE: sets the SAME value on every file. For per-file values (track/disc derived from
# filename or folder), write a custom loop — see the skill's "Per-file values" section.
set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then DRY_RUN=1; shift; fi

DIR="${1:?usage: bulk-retag.sh [--dry-run] <dir> KEY=VALUE [KEY=VALUE ...]}"; shift
[ "$#" -ge 1 ] || { echo "error: give at least one KEY=VALUE" >&2; exit 1; }
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
for kv in "$@"; do
  case "$kv" in
    *=*) : ;;
    *) echo "error: argument '$kv' is not KEY=VALUE" >&2; exit 1 ;;
  esac
done
command -v ffmpeg  >/dev/null 2>&1 || { echo "error: ffmpeg not found (brew install ffmpeg / dnf install ffmpeg / apt install ffmpeg)" >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "error: ffprobe not found (brew install ffmpeg / dnf install ffmpeg / apt install ffmpeg)" >&2; exit 1; }

# Write each tag at BOTH container and stream level (see note 1 above).
META=()
for kv in "$@"; do META+=(-metadata "$kv" -metadata:s:a "$kv"); done

# Read a tag back regardless of which level it lives at (see note 2 above).
# The trailing `|| true` is load-bearing: a MISSING tag makes grep exit 1, and under
# `set -euo pipefail` that would kill the script on exactly the case we need to REPORT.
# NOTE: ${1} braces are deliberate — an unbraced "$1:stream_tags" is mangled by zsh's
# :s history modifier if this snippet is ever pasted into a zsh prompt.
read_tag() {
  ffprobe -v quiet -show_entries "format_tags=${1}:stream_tags=${1}" \
    -of default=nw=1:nk=1 "$2" 2>/dev/null | grep -v '^$' | head -1 || true
}

# Backups live outside the skill dir; one timestamped file per run (never overwrite a prior backup).
BK_DIR="${RETAG_BACKUP_DIR:-${TMPDIR:-/tmp}/relabel-audio-tags}"
mkdir -p "$BK_DIR"
BK="$BK_DIR/$(basename "$DIR").$(date +%Y%m%dT%H%M%S).tags.tsv"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN — nothing will be written. Would set: $*"
else
  : > "$BK"
  printf 'path\tformat_tags_json\tstream_tags_json\n' >> "$BK"
fi

ok=0; fail=0; bad=0; n=0
while IFS= read -r -d '' f; do
  n=$((n+1))
  if [ "$DRY_RUN" -eq 1 ]; then echo "  would retag: ${f#"$DIR"/}"; continue; fi

  # 1) backup current tags at BOTH levels (restore reference)
  printf '%s\t%s\t%s\n' "$f" \
    "$(ffprobe -v quiet -show_entries format_tags -of json "$f" 2>/dev/null | tr '\n\t' '  ')" \
    "$(ffprobe -v quiet -show_entries stream_tags -of json "$f" 2>/dev/null | tr '\n\t' '  ')" \
    >> "$BK"

  # 2) build output opts; -id3v2_version is an mp3-muxer option ONLY
  ext="$(printf %s "${f##*.}" | tr 'A-Z' 'a-z')"
  out=(-map 0 -c copy)
  [ "$ext" = "mp3" ] && out+=(-id3v2_version 3)

  # 3) write to temp, then atomic replace
  tmp="${f%.*}.__retag__.$ext"
  if ! { ffmpeg -y -loglevel error -i "$f" "${out[@]}" "${META[@]}" "$tmp" 2>/dev/null && mv -f "$tmp" "$f"; }; then
    fail=$((fail+1)); echo "  FAIL (ffmpeg): ${f#"$DIR"/}" >&2; rm -f "$tmp"
    continue
  fi

  # 4) VERIFY with an independent reader — never trust the writer's exit code
  mismatch=""
  for kv in "$@"; do
    key="${kv%%=*}"; want="${kv#*=}"
    got="$(read_tag "$key" "$f")"
    [ "$got" = "$want" ] || mismatch="$mismatch $key(want='$want' got='$got')"
  done
  if [ -n "$mismatch" ]; then
    bad=$((bad+1)); echo "  MISMATCH: ${f#"$DIR"/} —$mismatch" >&2
    # Raw ADTS .aac has nowhere to PUT a tag; ffmpeg still exits 0. Say so instead of
    # leaving the user staring at an unexplained mismatch.
    [ "$ext" = "aac" ] && echo "      ^ raw ADTS .aac cannot store tags at all. Remux to .m4a: ffmpeg -i in.aac -c copy out.m4a" >&2
  else
    ok=$((ok+1)); echo "  ok: ${f#"$DIR"/}"
  fi
done < <(find "$DIR" -type f \( \
  -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' -o -iname '*.mpc' \
  -o -iname '*.wma' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.aac' \) -print0)

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: $n file(s) would be retagged. Re-run without --dry-run to apply."
  exit 0
fi
[ "$n" -eq 0 ] && echo "warning: no audio files found under $DIR" >&2
echo "retagged: $ok verified ok, $bad written-but-WRONG, $fail failed"
echo "tag backup: $BK"
if [ "$bad" -gt 0 ] || [ "$fail" -gt 0 ]; then
  echo "!! Not everything took. The MISMATCH lines above are files whose tags did NOT land." >&2
  echo "!! Original tags are in the backup TSV above. Do not assume the library is clean." >&2
  exit 1
fi
