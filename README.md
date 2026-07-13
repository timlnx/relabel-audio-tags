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

## Examples

You don't run the scripts yourself and you don't invoke the skill by name — **you just describe
the mess in plain English and Claude picks the skill up on its own.** The examples below are
things you'd literally type.

Two habits make everything below go better:

- **Give an absolute path.** Claude can find your library, but "the Beatles folder" costs a round
  of guessing and risks it touching the wrong directory. `/Volumes/Media/Music/Beatles` doesn't.
- **Ask for a dry run first on anything big.** `bulk-retag.sh --dry-run` writes nothing and lists
  exactly what it would touch. On someone's real library, that's cheap insurance.

### The classic: an album that exploded into fake artists

```
The rips in /Volumes/Media/Music/Kollaps have track numbers as the artist, so my
music server thinks there are 9 different artists named 01, 02, 03. They're all
Einstürzende Neubauten, album "Kollaps". Fix the tags, dry run first.
```

This is the case the skill was built for. Claude will survey the formats, back up the existing
tags, set `artist` and `album_artist` to one canonical value, and re-read every file to prove it
landed.

### Names in a file — one title per track

```
Relabel the files in /Volumes/Media/Music/Bootleg/1981-Berlin/, the song names
are in songs.txt (one per line, in track order). Set the title and track number
on each file, and leave everything else alone.
```

Worth calling out because this is *not* what `bulk-retag.sh` does — that script sets the **same**
value on every file. Per-file values (titles, track numbers, disc numbers) need a loop, and Claude
will write one using the skill's guidance. **Have it show you the filename-to-title pairing before
it writes anything** — an off-by-one against a text file mislabels the whole album, and the
filenames are rarely in the order you assume.

### Look it up online

```
/Volumes/Media/Music/unknown-album-3 has no useful tags at all — just track01.mp3
through track11.mp3. Figure out what this album actually is (durations and any
embedded junk might help), find the best match online, show me your evidence and
your confidence, then tag it once I confirm.
```

Claude can search the web (MusicBrainz, Discogs) and reason from track count and durations, but a
confident-sounding wrong match will happily overwrite good metadata. **Ask for the evidence and
approve the match before the write.** "Show me your confidence" is doing real work in that prompt.

### Merge an artist that split in two

```
My library lists "Einstürzende Neubauten" and "Einsturzende Neubauten" as two
separate artists, and I think there's a "Einstuerzende Neubauten" too. Find every
variant under /Volumes/Media/Music and normalize them all to the umlaut spelling.
```

One character makes two artists as far as a media server is concerned. Note this one asks Claude
to **find** the variants first — you don't have to know all of them up front.

### Mojibake from a bad tagger

```
Something re-tagged half my library with the id3v2 tool and now everything with an
accent is garbage — "Ã¼" where "ü" should be, "Ã©" for "é". Scan
/Volumes/Media/Music/Bjork and repair the encoding without touching anything else.
```

### Cover art, exactly as-is

```
Put ~/Downloads/kollaps-front.png on every track in /Volumes/Media/Music/Kollaps.
Do not recompress it — I want the exact PNG bytes in the files.
```

The skill embeds art by stream copy and can prove it: it extracts the art back out and byte-compares
it to your source. Ask it to. (It will also *refuse* to convert rather than quietly degrade — a WebP
into `.m4a` can't work, so it skips and tells you.)

### Disc and track numbers from the folder layout

```
/Volumes/Media/Music/Some Box Set has CD1/ through CD4/ subfolders and the track
number is the first two digits of each filename. Set disc and track accordingly,
and set album to "Some Box Set" on all of them.
```

### The server won't admit you fixed anything

```
I retagged everything under /Volumes/Media/Music/Kollaps but Navidrome still shows
the old artists. My Navidrome runs in a docker container called "navidrome".
```

Editing a file in place changes the *file's* mtime but not the *folder's*, so incremental scanners
skip it entirely. The skill knows to force a full, timestamp-ignoring rescan and then verify
against the server's own database — which is the ground truth for what you actually see in the UI.

### Just tell me what's wrong first

```
Survey the tags under /Volumes/Media/Music/Kollaps and tell me what's broken.
Don't change anything yet.
```

A perfectly good way to start. The skill's first rule is *never write blind* — a survey pass costs
nothing and often changes what you'd have asked for.

## Requires

`ffmpeg` and `ffprobe` — nothing else. The scripts check for both and exit with a clear
message if they're absent.

```bash
# macOS
brew install ffmpeg

# Fedora / RHEL — ffmpeg proper lives in RPM Fusion, not the default repos
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install -y ffmpeg

# Debian / Ubuntu
sudo apt install ffmpeg
```

On Fedora, `dnf install ffmpeg` without RPM Fusion gets you `ffmpeg-free`, which is built
without some patent-encumbered codecs. For this skill that's mostly fine — retagging is a
stream copy, not a re-encode — but `ffmpeg-free` can be missing decoders for formats you own,
and you'd rather find that out now than halfway through a library.

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
