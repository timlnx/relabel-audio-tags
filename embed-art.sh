#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Tim Case
#
# embed-art.sh — embed a cover image into every audio file under a directory, VERBATIM.
#
# The image's exact bytes are stream-copied in (-c copy): a PNG stays a PNG, a JPEG stays a
# JPEG. The art is NEVER re-encoded or recompressed. Refuses anything that isn't an image
# (blocks .exe and other garbage). Files whose format can't hold the art are skipped + reported,
# never silently degraded.
#
# Usage:  embed-art.sh <dir> <image-file>
# Example: embed-art.sh "/path/to/Music/Some Album" ./front-cover.png
set -euo pipefail

DIR="${1:?usage: embed-art.sh <dir> <image-file>}"
IMG="${2:?usage: embed-art.sh <dir> <image-file>}"
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
[ -f "$IMG" ] || { echo "error: no such image file: $IMG" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "error: ffmpeg not found (brew install ffmpeg / dnf install ffmpeg / apt install ffmpeg)" >&2; exit 1; }

# --- guardrail: must be a real image, else refuse (blocks .exe/pdf/zip/etc.) ---
MIME="$(file --mime-type -b "$IMG")"
case "$MIME" in
  image/*) : ;;
  *) echo "REFUSING: '$IMG' is '$MIME', not an image. Provide a real cover image (png/jpeg/webp/…)." >&2; exit 2 ;;
esac
# stat is BSD (-f%z) on macOS, GNU (-c%s) on Linux — try both.
SZ="$(stat -f%z "$IMG" 2>/dev/null || stat -c%s "$IMG")"
echo "cover: $IMG  ($MIME, $SZ bytes) — embedding VERBATIM (stream-copied, no recompression)"

# --- network-share (NAS / SMB / NFS) handling ---
# SMB can report "Permission denied" on a rename that ACTUALLY SUCCEEDED. Don't trust the
# exit code of a mutate: settle, then check whether it really happened. RETAG_SETTLE=<secs>
# adds a pause after each write (default 0; use 1-3 on a NAS).
SETTLE="${RETAG_SETTLE:-0}"
settle() {
  [ "${1:-0}" = "0" ] && return 0
  sleep "$1" 2>/dev/null \
    || python3 -c "import time,sys;time.sleep(float(sys.argv[1]))" "$1" 2>/dev/null \
    || perl -e "select(undef,undef,undef,$1)" 2>/dev/null || true
}
replace_atomic() {
  local tmp="$1" dst="$2" t
  for t in 0 1 2 4; do
    settle "$t"
    mv -f "$tmp" "$dst" 2>/dev/null && return 0
    [ -e "$tmp" ] || return 0   # tmp gone => the rename landed despite the error
  done
  return 1
}

ok=0; skip=0
while IFS= read -r -d '' f; do
  ext="$(printf %s "${f##*.}" | tr 'A-Z' 'a-z')"
  case "$ext" in
    # MP4/M4A cover atoms hold ONLY jpeg/png — do NOT silently convert; skip + warn on mismatch
    m4a|m4b|mp4)
      if [ "$MIME" != "image/jpeg" ] && [ "$MIME" != "image/png" ]; then
        echo "  SKIP (mp4 cover needs jpeg/png; yours is $MIME — not recompressing): ${f#"$DIR"/}" >&2
        skip=$((skip+1)); continue
      fi ;;
    # Ogg/Opus store cover art as a base64 METADATA_BLOCK_PICTURE vorbis comment, which
    # ffmpeg's ogg muxer will NOT write. Verified: it exits 0 and embeds nothing. Say so
    # up front rather than letting it fail into the generic message below.
    ogg|opus|oga)
      echo "  SKIP (ffmpeg cannot write cover art into Ogg/Opus — needs a Vorbis-comment tool, e.g. kid3-cli): ${f#"$DIR"/}" >&2
      skip=$((skip+1)); continue ;;
  esac
  out=(-map 0:a -map 1:v -c copy -disposition:v:0 attached_pic
       -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)")
  [ "$ext" = "mp3" ] && out+=(-id3v2_version 3)
  tmp="${f%.*}.__art__.$ext"
  if ffmpeg -y -loglevel error -i "$f" -i "$IMG" "${out[@]}" "$tmp" 2>/dev/null && [ -s "$tmp" ] \
     && replace_atomic "$tmp" "$f"; then
    settle "$SETTLE"
    ok=$((ok+1)); echo "  ok: ${f#"$DIR"/}"
  else
    echo "  SKIP (ffmpeg could not embed the art here — file left UNTOUCHED, not degraded): ${f#"$DIR"/}" >&2
    echo "      ^ usually an unreadable/corrupt image, or a container ffmpeg won't put pictures in (.mpc/.wma need kid3-cli)." >&2
    skip=$((skip+1)); rm -f "$tmp"
  fi
done < <(find "$DIR" -type f \( \
  -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' -o -iname '*.m4b' \
  -o -iname '*.mp4' -o -iname '*.ogg' -o -iname '*.opus' \) -print0)

echo
echo "art embedded: $ok ok, $skip skipped"
cat <<EOF
VERIFY the art went in byte-for-byte (extract it back out and compare):
  ffmpeg -v quiet -y -i <file> -map 0:v -c copy /tmp/extracted.<ext> && cmp "$IMG" /tmp/extracted.<ext> && echo VERBATIM
  # cmp is silent+exit-0 on an exact byte match. Portable; unlike md5(1), it exists on Linux too.
EOF
