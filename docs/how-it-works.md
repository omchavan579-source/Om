# How the Drive ↔ GitHub sync works

Short version: **GitHub Actions runs `rclone bisync` on a schedule**, then
commits whatever changed into the repository. Nothing runs on your computer and
no server has to stay awake.

```
   Google Drive                    GitHub Actions runner                GitHub repo
 ┌──────────────┐    rclone    ┌───────────────────────────┐   git    ┌──────────────┐
 │  your folder │ ◄──────────► │  bisync (both directions) ├─────────►│  main branch │
 └──────────────┘  Drive API    └───────────────────────────┘  commit  └──────────────┘
        ▲                                      ▲
        │                                      │
   base64 credential                    previous sync state (cache)
```

---

## Why not just put the repo inside Google Drive?

Because that is the #1 way people lose work, and it is worth one paragraph to
explain why. Git expects the files in `.git/` to change in a very specific
order, thousands of tiny writes and renames within milliseconds. Drive's sync
client watches files from the outside and uploads them one by one, in whatever
order it notices. It can copy a half-written file, race two machines against
each other, or drop its own `desktop.ini` into `.git/refs/` and break
`git gc`/`git checkout` with errors like `fatal: bad object refs/desktop.ini`.
Git's own documentation says repositories on network/sync filesystems are
unsupported for exactly this reason.

This setup keeps the two worlds apart: Drive syncs over its **API**, locally the
repo is a normal folder on a normal disk, and every change lands as a **commit**
you can review, revert, and blame.

---

## What each step of the workflow does

| Step | Why it exists |
|---|---|
| Check out repo | Gives us the current files; `fetch-depth: 0` lets the later push rebase. |
| Check credentials exist | Fails fast with a friendly message instead of a confusing rclone error. |
| Install rclone | Always the latest release from rclone.org. |
| Restore sync state | `bisync` is not stateless — it remembers what both sides looked like last time. See below. |
| Write credentials | `scripts/configure-rclone.sh` turns the secret into `~/.config/rclone/rclone.conf`. |
| Run the sync | `scripts/drive-sync.sh --mode=two-way` (or `pull`/`push`). |
| Save sync state | Only on success. A half-finished run's state is worse than none. |
| Commit synced files | `git add -A` + commit + rebase + push, as `drive-sync[bot]`. |
| Summary | A small table in the run's Summary tab: mode, folder, result. |

## Why "resync" exists

`rclone bisync` keeps a record of the last known state of *both* sides. With
that record it can tell the difference between:

- a file you deleted in Drive, and
- a file that was never synced down in the first place.

Without the record, those two look identical, so bisync refuses to guess and
asks for `--resync`. That is why:

- **the first two-way run must be a resync.** The script detects a first run
  automatically and flips the flag for you.
- **editing `.drivesync-ignore` requires a resync**, because the set of files
  being compared changed.
- **`--resync` only copies, it never deletes.** It unions the two sides; a file
  present on one side gets copied to the other. That makes it safe, but also
  means a file you purposely deleted reappears if the other side still has it.

The state lives in a GitHub Actions **cache** under the key
`rclone-bisync-*`. Caches older than 7 days are evicted, newer runs always
restore the most recent state they can find, and if the state is missing the
script quietly falls back to a resync instead of failing.

There is a second, subtler piece of state: rclone stores an MD5 of the filters
file next to it and *refuses to run* if that MD5 changes, precisely so that
adding an exclusion can never be mistaken for "those files were deleted". To
make that work across ephemeral CI runners, the workflow copies
`.drivesync-ignore` into the cached workdir and points bisync there with
`--filters-file` — the MD5 therefore survives between runs. Edit the ignore
list and the next run hits the check, which the script catches and resolves
with a single automatic `--resync` (safe: a resync copies, it never deletes).

## How changes are detected

`--compare size,modtime,checksum` with `--slow-hash-sync-only`: sizes and
timestamps are used for the cheap scan, and real checksums decide anything that
looks different. This matters because a fresh `git checkout` on every run gives
files brand-new timestamps — if the sync only trusted timestamps, every run
would think every file changed. It only trusts checksums, so identical content
is recognised as identical, and no-news runs commit nothing.

## Conflicts

A conflict is a file that changed on **both** sides since the last run *and* is
not currently identical. By default nothing is overwritten — you keep both:

```
report.pdf                  # untouched
notes.md.conflict1          # the repo's version (Path1)
notes.md.conflict2          # the Drive version (Path2)
```

(That numbering is rclone's modern default, `--conflict-loser num`. Both files
are copied to both sides, so nothing is lost either way.) Keep the one you
want, delete the other, and the next run tidies up.

Prefer it automated? Set the `DRIVE_CONFLICT_RESOLVE` repository variable to
`newer`, `older`, `larger`, `smaller`, `path1` or `path2`, and that copy wins
while the other is renamed `*.conflict1`. Note that if the two versions turn
out to be byte-identical, it isn't a conflict at all — bisync checks first.

**During a resync there are no conflicts to report** — there is no previous run
to compare against, so where a file differs on both sides one version simply
overwrites the other. That is what `DRIVE_RESYNC_MODE` controls; it defaults to
`newer` (the most recently edited copy wins) rather than rclone's own default of
`path1` (always the repo), so a resync can't blindly clobber a fresh Drive edit.

## Safety brakes

- **`--dry-run`** — the workflow input. Reports everything, changes nothing.
- **`--max-delete 10`** — bisync aborts if a run would delete more than 10% of
  the files. Protects you from a filter typo, a Drive hiccup, or a half-broken
  listing wiping the repo. If you hit it on purpose (say, a directory rename
  that moved most of your files), set the `DRIVE_FORCE` variable to `true` for
  one run — or just relabel the directory the same way on both sides.
- **"Everything changed" check** — if every previously-synced file on a side
  suddenly looks changed, bisync refuses to run at all rather than believing it.
- **One-way modes** (`pull`, `push`) — `rclone copy` never deletes anything on
  the destination. A repo that only ever grows can't destroy your Drive.
- **`.drivesync-ignore`** — the shared exclusion list: `.git`, dependencies,
  build output, and patterns like `*.pem`, `.env`, `credentials.json` so
  secrets can't accidentally travel in either direction.
- **Concurrency group** — a scheduled run and a manual run can never overlap.

## Known limits

| Limit | Detail |
|---|---|
| Google Docs, Sheets, Slides | They aren't real files. They have size `-1` and no checksum, so rclone itself documents them as "cannot be reliably synced"; they export as `.docx`/`.xlsx`/`.pptx`, and editing that export on GitHub would create a **second** file in Drive rather than editing your Doc. Hence `DRIVE_SKIP_GDOCS=true` by default — flip it to `false` if you want the exports regardless. |
| File size | Default `DRIVE_MAX_SIZE=45MiB`; GitHub hard-rejects files over 100 MiB. Big media belongs in Git LFS or stays in Drive. |
| Repo growth | Every sync is a commit. Git stores every version of every file, so a repo syncing large binaries will grow (and clone) fast. Text files are fine. |
| Symlinks, filenames with `:`/`\` | Git and Windows reject some names. They are skipped, with a warning in the log. |
| Renaming a folder | bisync sees a rename as "all those files deleted + new copies", which can trip the 10% brake. Rename on both sides, or set `DRIVE_FORCE=true` for one run. |
| Dry-run output | A dry run may print "would delete" for files it would actually have copied first. rclone's own docs call this a known artifact of `--dry-run`. |
| Files over `DRIVE_MAX_SIZE` | They are invisible to the sync on *both* sides — skipped, never transferred, never deleted. |
| Schedule timing | GitHub's cron is best-effort — expect a few minutes' drift, and it is disabled automatically after 60 days without repo activity. Also, scheduled runs on **private** repos consume Actions minutes; public repos are free. |
| Push rejected | If `main` is branch-protected, the bot can't push. Allow `github-actions[bot]` to bypass, or sync into a non-protected branch and merge via PR. |

## Doing it locally instead

The same scripts work on your own machine if you'd rather keep sync in your own
hands:

```bash
export RCLONE_CONF_B64="$(base64 -w0 ~/.config/rclone/rclone.conf)"
bash scripts/configure-rclone.sh

bash scripts/drive-sync.sh --mode=two-way --dry-run   # look first
bash scripts/drive-sync.sh --mode=two-way --resync    # first real run
bash scripts/drive-sync.sh --mode=two-way             # from then on (e.g. from cron)
```
