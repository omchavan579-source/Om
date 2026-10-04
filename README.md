# Om

This repository is wired up to **two-way sync with a Google Drive folder**.
Edit a file in Drive and it lands here as a commit; push a commit here and it
lands in Drive. Sync runs on a schedule in GitHub Actions, so no computer has
to stay awake.

> **Two-way means deletions travel too.** Delete a file on one side and the
> next run deletes it on the other. One-way `pull` / `push` modes are available
> if you'd rather it couldn't. Always try a **dry run** first — it changes
> nothing.

---

## Set it up (about 10 minutes, once)

### Step 1 — Give the workflow access to your Drive

Follow **[docs/setup-drive-credentials.md](docs/setup-drive-credentials.md)**.
The short version: run `rclone config` on your own computer, base64 the
resulting config file, and add it to this repo as the secret
`RCLONE_CONF_B64`.

*Never paste that secret into a chat, an issue, or a commit — it is full access
to your Drive.*

### Step 2 — Optional: point it at one folder

Repo → **Settings → Secrets and variables → Actions → Variables** → new variable
`DRIVE_PATH` = e.g. `Om`. Everything outside `gdrive:Om` is then untouched.

### Step 3 — Allow the bot to push

Repo → **Settings → Actions → General → Workflow permissions** → select
**Read and write permissions** → Save. (The workflow requests write access, but
a stricter account policy can still override it.)

### Step 4 — Your first run

Go to the **Actions** tab → **Drive sync** → **Run workflow**:

1. **direction** = `two-way`, **dry_run** = ✅ → Run.
   Read the log. Nothing is written; it just tells you what it would do.
2. If that looked right, run it again with **resync** = ✅.
   This is the one-time baseline that pairs both sides up.
3. From then on, leave it alone — it runs every 6 hours.

### Step 5 — Relax

Every run shows up under **Actions → Drive sync**, with a table summarising
what it did. Files that changed arrive here as commits authored by
`drive-sync[bot]`.

---

## Driving it by hand

**Actions → Drive sync → Run workflow:**

| Input | What it does |
|---|---|
| `two-way` | Both directions, including deletions and renames. The default. |
| `pull` | Google Drive → repo **only**. Never deletes anything in the repo. |
| `push` | Repo → Google Drive **only**. Never deletes anything in Drive. |
| `resync` | Re-baseline two-way sync. Needed for the first run and after editing `.drivesync-ignore`. Copies, never deletes. |
| `dry_run` | Show what would happen, change nothing. |

Even easier, if you have rclone installed locally:

```bash
bash scripts/drive-sync.sh --help
bash scripts/drive-sync.sh --mode=two-way --dry-run
```

---

## What's in here

| Path | Purpose |
|---|---|
| [`.github/workflows/drive-sync.yml`](.github/workflows/drive-sync.yml) | The scheduled workflow: credentials → sync → commit. |
| [`scripts/drive-sync.sh`](scripts/drive-sync.sh) | The sync itself. Works in CI *or* on your laptop. |
| [`scripts/configure-rclone.sh`](scripts/configure-rclone.sh) | Turns the GitHub secret into an rclone config. |
| [`docs/setup-drive-credentials.md`](docs/setup-drive-credentials.md) | Credential setup, both methods, plus an error reference. |
| [`docs/how-it-works.md`](docs/how-it-works.md) | The design, the safety brakes, conflicts, and the limits. |
| [`.drivesync-ignore`](.drivesync-ignore) | What is never synced — `.git`, build junk, and secrets. |

## Tuning

Everything below is optional; defaults work out of the box. Set them as
repository **variables** (Settings → Secrets and variables → Actions →
Variables) or edit the `env:` block of the workflow.

| Variable | Default | Meaning |
|---|---|---|
| `DRIVE_REMOTE` | `gdrive` | Name of the rclone remote. |
| `DRIVE_PATH` | *(empty)* | Sub-folder in Drive, e.g. `Om`. |
| `DRIVE_MAX_SIZE` | `45MiB` | Skip files larger than this (GitHub hard-caps at 100 MiB). |
| `DRIVE_MAX_DELETE_PERCENT` | `10` | Abort a run that would delete more than this share of files. |
| `DRIVE_CONFLICT_RESOLVE` | `none` | `none` keeps both copies; or `newer`, `older`, `larger`, `smaller`. |
| `DRIVE_RESYNC_MODE` | `newer` | On a resync, which copy wins when both sides have the same file: `newer`, `older`, `larger`, `smaller`, `path1`, `path2`. |
| `DRIVE_FORCE` | `false` | `true` disables the mass-deletion brake for one run (e.g. after a big folder rename). |
| `DRIVE_SKIP_GDOCS` | `true` | `false` = also sync Google Docs/Sheets/Slides as `.docx`/`.xlsx`/`.pptx` exports. |

**Changing the schedule:** edit the `cron:` line in the workflow
(`"0 */6 * * *"` = every 6 hours, UTC). **Stopping it:** Actions → Drive sync →
`⋯` → Disable workflow.

## Common questions

**My Google Doc isn't in the repo.** Correct, and by default on purpose.
Google Docs, Sheets and Slides have no file bytes to copy — rclone can only
export them (`.docx`, `.xlsx`, `.pptx`), and editing that export on GitHub
can't be pushed back into the original Doc; it would land in Drive as a second,
unrelated file. rclone's own recommended Drive sync skips them. If you want the
exports anyway, set the `DRIVE_SKIP_GDOCS` variable to `false`.

**Where did my file go?** Deletions sync in two-way mode. `git log` here, or
Drive's own version history, will have it — and a `pull`/`push` run can restore
one side from the other. If a file changed on both sides at once, both copies
are kept as `name.conflict1` / `name.conflict2`.

**Why does it insist on a resync?** bisync lost its memory of the last state
(cache evicted, or `.drivesync-ignore` changed). Resync re-learns it, and only
copies files — never deletes them. The workflow normally catches this and
resyncs by itself in the same run; tick the box yourself if it says otherwise.

**It refused, saying too many files would be deleted.** That's the 10% brake
doing its job — usually a big folder rename, which looks like "delete
everything, then create everything". Rename the folder on both sides, or set
the `DRIVE_FORCE` variable to `true` for one run, then set it back.

**Can I just put the repo inside my Google Drive folder instead?** Please don't
— that corrupts Git repositories. See
[Why not just put the repo inside Google Drive?](docs/how-it-works.md#why-not-just-put-the-repo-inside-google-drive)

**Something failed.** [docs/setup-drive-credentials.md](docs/setup-drive-credentials.md)
ends with a table of the common errors and what they mean.
