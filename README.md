# relabel-audio-tags

A Claude Code skill for bulk-fixing music metadata across a mixed-format library
(mp3, flac, m4a, mpc, wma, ogg, opus) — duplicate/fragmented artists, numeric junk
artists (`01`, `02`, …), mojibake (`Ã¼` for `ü`), umlaut-split artists, and embedding
cover art verbatim. Also covers making a media server (Navidrome/Subsonic/Plex/Jellyfin)
actually notice the change.

The whole thing rests on one hard-won conclusion: **ffmpeg is the only tag writer that's
both format-universal and encoding-correct, and you must verify every write with an
independent reader (ffprobe), because taggers lie about success.**

## Install

Claude Code discovers a skill by directory name, so the folder **must** be called
`relabel-audio-tags`. Install it for yourself (available in every project):

```bash
git clone https://github.com/timlnx/relabel-audio-tags.git ~/.claude/skills/relabel-audio-tags
chmod +x ~/.claude/skills/relabel-audio-tags/*.sh
```

…or scope it to a single project (checked in, shared with collaborators):

```bash
git clone https://github.com/timlnx/relabel-audio-tags.git .claude/skills/relabel-audio-tags
chmod +x .claude/skills/relabel-audio-tags/*.sh
```

Then **start a new Claude Code session** — skills are loaded at startup. Confirm it's there
with `/skills` (it should list `relabel-audio-tags`). You don't invoke it explicitly: Claude
reads the description in `SKILL.md` and picks it up on its own when you ask for something like
*"every artist in this folder is a track number, fix them"* or *"put this cover art on the album."*

To update later: `git -C ~/.claude/skills/relabel-audio-tags pull`.

No-git alternative: download the ZIP, unpack it, and make sure the resulting directory is named
`relabel-audio-tags` before moving it into `~/.claude/skills/`.

## Requires

`ffmpeg` and `ffprobe` — `brew install ffmpeg` or `apt install ffmpeg`. Nothing else.
The scripts check for both and exit with a clear message if they're absent.

## The scripts

```bash
# See what would change — writes nothing. Do this first.
./bulk-retag.sh --dry-run "/path/to/Music/Some Artist" artist="Some Artist"

# Apply it. Backs up every existing tag before touching anything.
./bulk-retag.sh "/path/to/Music/Some Artist" \
    artist="Some Artist" album_artist="Some Artist"

# Embed cover art, byte-for-byte, never recompressed.
./embed-art.sh "/path/to/Music/Some Album" ./front-cover.png
```

`bulk-retag.sh` sets the *same* value on every file it finds. For per-file values
(track/disc derived from filename or folder), see the "Per-file values" section of
`SKILL.md` — Claude will write the loop.

## Your tags are backed up

Before `bulk-retag.sh` writes anything, it dumps every file's existing tags to a TSV:

```
${TMPDIR:-/tmp}/relabel-audio-tags/<dir>.<timestamp>.tags.tsv
```

One file per run — re-running never clobbers an earlier backup. Since `/tmp` doesn't
survive forever, point it somewhere durable for a big or hard-to-reconstruct retag:

```bash
RETAG_BACKUP_DIR=~/tag-backups ./bulk-retag.sh "/path/to/Music/Some Artist" artist="…"
```

There's no automated restore — the TSV is `path<TAB>ffprobe-JSON` per line, which is
enough for Claude to reconstruct any file's original tags on request.

## Why not just run ffmpeg yourself

Because two failure modes here are **completely silent**, and both were verified the hard way:

- **`.ogg` / `.opus` keep tags at the stream level.** A plain `ffmpeg -metadata artist=X` exits 0
  and leaves the *old* artist in place. Your junk `01`/`02` artists survive the fix while every
  tool reports success. `bulk-retag.sh` writes at both levels, so they actually change.
- **`ffprobe -show_entries format_tags` reads empty on `.ogg`/`.opus`** even when the tags are
  perfect. So the obvious backup command captures *nothing* for those files — a restore point
  that isn't there. The backup here dumps stream tags too.

After every write, `bulk-retag.sh` re-reads each file with `ffprobe` and prints `MISMATCH`
(and exits non-zero) for any file whose tags didn't land. Trust that, not ffmpeg's exit code.

Known dead ends it will tell you about rather than silently botch: raw ADTS `.aac` can't store
tags at all (remux to `.m4a`), and ffmpeg can't embed cover art into `.ogg`/`.opus` (needs
kid3-cli).

## Safety notes

- Both scripts write to a temp file and `mv` it into place, so an interrupted run
  leaves the original intact rather than a half-written file.
- `embed-art.sh` refuses anything that isn't `image/*` (blocks a stray `.exe`/pdf/zip),
  and **skips rather than degrades**: a WebP into `.m4a` can't work, so it warns and
  leaves the file alone instead of silently recompressing your art.
- Neither script recompresses audio or images — everything is a stream copy (`-c copy`).
