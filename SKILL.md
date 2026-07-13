---
name: relabel-audio-tags
description: Use when bulk-correcting or normalizing audio metadata in a directory — a fragmented or duplicated artist listing, garbage "numeric" artists (01, 02, 03…), mojibake / wrong-encoding tags (Ã¼ instead of ü), an artist split by an umlaut or spelling variant, inconsistent artist/album/disc/track across a mixed-format music library (mp3, mpc, m4a, wma, flac, ogg, opus), or embedding album / cover art into files verbatim (without recompressing the image), including when a media server (Navidrome, Subsonic, Plex, Jellyfin) keeps showing stale tags after edits.
---

# Relabel Audio Tags

## Overview
Bulk-fix music metadata reliably across mixed formats. Core insight: **`ffmpeg` is the only tag writer that is both format-universal AND encoding-correct — use it, and verify every write with an independent reader (`ffprobe`), because taggers lie about success.**

**Requires `ffmpeg` + `ffprobe`** (`brew install ffmpeg` / `dnf install ffmpeg` on Fedora, needs RPM Fusion / `apt install ffmpeg`). The scripts check and exit with a clear message if missing.

## Workflow
1. **Survey first — never write blind.** Count formats and inspect current tags:
   - `find "$DIR" -type f | sed -n 's/.*\.\([A-Za-z0-9]*\)$/\1/p' | tr A-Z a-z | sort | uniq -c`
   - `ffprobe -v quiet -show_entries format_tags -of json FILE`
2. **Back up all tags first** (reversibility): dump `path + ffprobe JSON` per file to a TSV.
3. **Write with ffmpeg** (see Tool Choice). Temp file + atomic `mv`.
4. **Verify with ffprobe** — trust the reader, not the writer's exit code.
5. **If a media server caches** (Navidrome/Subsonic/Plex/Jellyfin): force a FULL rescan (see Stale Library).

## Scripts in this skill dir
Both live next to this file. Invoke them by absolute path; `chmod +x` them once if they came over without the bit set.

| Script | Does |
|---|---|
| `bulk-retag.sh [--dry-run] DIR KEY=VALUE ...` | Backup + ffmpeg write + atomic replace, for "set these fields on every file". `--dry-run` lists what it would touch and writes nothing — **lead with it on someone else's library.** |
| `embed-art.sh DIR IMAGE` | Embed cover art verbatim (see Album art). |

`bulk-retag.sh` writes its tag backup to `${TMPDIR:-/tmp}/relabel-audio-tags/<dir>.<timestamp>.tags.tsv` — one file per run, never overwriting an earlier one. Set `RETAG_BACKUP_DIR=/somewhere/durable` to keep backups somewhere that survives a reboot; **do this if the retag is large or hard to reconstruct**, because /tmp is not forever.

## Tool Choice (the crux)
| Tool | Formats | Verdict |
|---|---|---|
| **ffmpeg** | all | **Use this.** Correct UTF encoding, lossless (`-c copy`), keeps cover art (`-map 0`). |
| kid3-cli | mp3/mpc/m4a/wma/ogg/flac | Encodes right, but **silently no-ops on a scattered subset** over network/SMB mounts (exit 0, writes nothing). Don't trust for bulk. |
| id3v2 | mp3 only | **Corrupts non-ASCII → mojibake** (`Ã¼`): writes UTF-8 bytes into a Latin-1 ID3v2.3 frame. Avoid for accented text. |

Canonical ffmpeg write (per file):
```bash
ext=$(printf %s "${f##*.}" | tr A-Z a-z)
out=(-map 0 -c copy); [ "$ext" = mp3 ] && out+=(-id3v2_version 3)
tmp="${f%.*}.__retag__.$ext"
ffmpeg -y -loglevel error -i "$f" "${out[@]}" \
  -metadata    artist="ARTIST" -metadata    album_artist="ARTIST" \
  -metadata:s:a artist="ARTIST" -metadata:s:a album_artist="ARTIST" "$tmp" && mv -f "$tmp" "$f"
```
- `-id3v2_version 3` (UTF-16) **only for mp3** — it's an mp3-muxer option and errors on other muxers. Use `4` for UTF-8.
- `-map 0 -c copy` copies audio + embedded art, no re-encode.
- **Write every tag TWICE — `-metadata` AND `-metadata:s:a`.** See below; without this, Ogg silently keeps its old tags.

## Ogg / Opus is the trap (verified, bites hard)
`.ogg` and `.opus` keep tags at the **stream** level, not the container level. Two consequences, and **both fail silently**:

1. **Writing.** `-metadata artist=X` alone **exits 0 and leaves the OLD artist in place** on ogg/opus. A junk `01`/`02` artist survives the "fix" while ffmpeg reports success. Always also pass `-metadata:s:a artist=X`. Harmless on mp3/flac/m4a, so just always do both.
2. **Reading.** `ffprobe -show_entries format_tags` reads **EMPTY on ogg/opus even when the tags are perfectly fine** — so a naive verify says "no tags!" and a naive backup captures *nothing*, leaving you with a restore point that doesn't exist. Always read `format_tags` **and** `stream_tags`.

```bash
# read a tag no matter which level it lives at (braces matter: unbraced "$1:stream_tags" is
# mangled by zsh's :s history modifier)
read_tag() { ffprobe -v quiet -show_entries "format_tags=${1}:stream_tags=${1}" \
  -of default=nw=1:nk=1 "$2" 2>/dev/null | grep -v '^$' | head -1; }
```

**Raw ADTS `.aac` cannot store tags at all** — there is nowhere to put them, and ffmpeg still exits 0. Remux to `.m4a` first: `ffmpeg -i in.aac -c copy out.m4a`.

## Common Mistakes (hard-won)
| Symptom | Cause | Fix |
|---|---|---|
| Artists named `01`, `02`, `03`… | ARTIST tag is a track number (bad rip); one album spawns N fake artists | Set artist/album_artist to the real artist |
| `Ã¼`, `Ã©` in tags | UTF-8 written into a Latin-1 ID3v2.3 frame (id3v2 tool) | Rewrite with ffmpeg `-id3v2_version 3` or `4` |
| One artist split in two (`Einstürzende` vs `Einsturzende`) | umlaut / spelling variant = two distinct artists to the server | Normalize artist+album_artist to one canonical string |
| Tagger reports OK, tag unchanged | **Dual tags**: ID3v1 + ID3v2 + APE coexist; tool updated one, reader reads another | ffmpeg rewrites a clean canonical tag; always ffprobe-verify |
| ffmpeg says ok, but **.ogg/.opus keep the old artist** | Ogg tags live at STREAM level; plain `-metadata` doesn't reach them | Also pass `-metadata:s:a` (see Ogg/Opus trap) |
| ffprobe shows **no tags at all** on .ogg/.opus | You read `format_tags`; Ogg keeps them in `stream_tags` | Read both (see Ogg/Opus trap) |
| Tags won't stick to a `.aac` no matter what | Raw ADTS has no metadata container | Remux to `.m4a`, then tag |
| Fixed the file, server still shows old | In-place edits change file mtime but **not folder mtime**; incremental scanners skip it | Full rescan ignoring timestamps (below) |
| "file not found" from a DB path | Unicode normalization: DB (NFC) vs macOS/SMB filesystem (NFD) | Locate via `find -ipath '*pattern*'`, don't rebuild paths from DB strings |
| Media-server host alerts "container stopped" | throwaway `docker run --rm` query containers exiting | Query via `docker exec <running-container>` instead of spawning new ones |

## Stale Library (Navidrome / Subsonic)
Force a mtime-independent re-read, then confirm against the server's OWN database (ground truth for what users see — it can disagree with the file when a stale tag or cache is involved):
```bash
docker exec <container> navidrome scan --full        # -f/--full ignores timestamps
# read the server's sqlite DB (media_file.artist/album) to verify coverage:
#   SELECT artist, count(*) FROM media_file WHERE path LIKE 'Some Dir/%' GROUP BY artist;
```

## Album art — embed VERBATIM (never recompress)
When the user says "use this album art `<image>`", embed the image's **exact bytes** — a PNG stays a PNG, a JPEG stays a JPEG. **Never re-encode/recompress cover art.** Helper: `embed-art.sh DIR IMAGE`.

Rules:
- **Validate first.** `file --mime-type -b IMG` must be `image/*`. Block non-images (`.exe`, pdf, zip…) — refuse loudly, don't guess. Embed directly unless it genuinely cannot work.
- **Stream-copy the image** (`-c copy`) — never let ffmpeg re-encode it (no implicit `-c:v mjpeg`):
  ```bash
  ffmpeg -y -i track.mp3 -i cover.png -map 0:a -map 1:v -c copy \
    -id3v2_version 3 -disposition:v:0 attached_pic \
    -metadata:s:v title="Album cover" out.mp3     # PNG embedded byte-for-byte
  ```
- **Verify verbatim**: extract it back out and byte-compare. `cmp` is silent and exits 0 on an exact match, and unlike `md5(1)` it exists on Linux too:
  ```bash
  ffmpeg -v quiet -y -i out.mp3 -map 0:v -c copy /tmp/extracted.png && cmp cover.png /tmp/extracted.png && echo VERBATIM
  ```
- **Only decline direct embed when it truly breaks — then say so, don't degrade.**
  - MP4/M4A cover atoms hold **only JPEG/PNG**, so a WebP/GIF into `.m4a` won't render → skip + warn (don't convert).
  - **ffmpeg cannot write cover art into `.ogg`/`.opus` at all** (verified — it exits 0 and embeds nothing). Ogg keeps art as a base64 `METADATA_BLOCK_PICTURE` comment, which the ogg muxer won't write. Needs kid3-cli or another Vorbis-comment tool.
  - `.mpc`/`.wma` need kid3 for pictures.

## Per-file values (disc/track from structure)
`bulk-retag.sh` sets the SAME value on every file. For per-file fields, loop and derive:
```bash
base=${f##*/}; tn=${base%%[^0-9]*}; [ -n "$tn" ] && tn=$((10#$tn)) || tn=0   # leading number -> track
# disc from folder name (…CD1 / …CD2), etc.  Add: -metadata disc=1 -metadata track="$tn"
```

## Verify
Read BOTH levels, or ogg/opus will look empty when they're fine:
```bash
ffprobe -v quiet \
  -show_entries "format_tags=artist,album,album_artist,disc,track:stream_tags=artist,album,album_artist,disc,track" \
  -of default=nw=1 FILE
```
`bulk-retag.sh` already does this after every write and reports `MISMATCH` (and exits non-zero) for any file whose tags did not actually land. **A clean exit from the script is your evidence — not ffmpeg's exit code.**
