# Connecting Google Drive to this repository

The sync workflow needs credentials that let rclone read and write your Drive.
Pick **one** of the two methods below.

> **Read this first.** Either secret gives its holder access to your Google
> Drive. Only add it to a repository you trust — anyone who can edit repo
> settings can read it, and anyone who can read it can reach your Drive.

---

## Method A — your own rclone login (recommended)

Works with any Google account, including free `@gmail.com`. Files you upload
stay owned by you.

### 1. Install rclone on your own computer (one time)

| OS | Command |
|---|---|
| Windows | `winget install Rclone.Rclone` |
| macOS | `brew install rclone` |
| Linux | `curl https://rclone.org/install.sh \| sudo bash` |

### 2. Create the remote

Run `rclone config` and answer the prompts like this:

```
n                                   # new remote
name>               gdrive          # must match DRIVE_REMOTE (default: gdrive)
Storage>            drive           # Google Drive
client_id>          (leave blank — press Enter)
client_secret>      (leave blank — press Enter)
scope>              1               # 1 = full access. The sync needs write access.
root_folder_id>     (blank, or paste a Drive folder ID — see the tip below)
service_account_file> (blank)
Edit advanced config?> n
Use auto config?>   y               # opens your browser: sign in and click Allow
Configure this as a Shared Drive?> n   # unless you really use one
Keep this remote?>  y
q                                   # quit
```

> **Tip: restrict the sync to one folder.** Create a folder in Drive, e.g.
> `Om`, open it, and copy the ID out of the URL:
> `https://drive.google.com/drive/folders/`**`1AbC...XyZ`** — paste that at the
> `root_folder_id` prompt. rclone then cannot see anything outside that folder,
> which is the single best safety measure you can take.

Verify it works:

```bash
rclone lsd gdrive:      # should list your Drive (or your one folder)
```

### 3. Turn the config into a secret value

The config lives at:

| OS | Path |
|---|---|
| Linux | `~/.config/rclone/rclone.conf` |
| macOS | `~/Library/Application Support/rclone/rclone.conf` |
| Windows | `%APPDATA%\rclone\rclone.conf` |

Print it as **one long base64 line** and copy it:

```bash
# Linux
base64 -w0 ~/.config/rclone/rclone.conf

# macOS
base64 -i ~/Library/Application\ Support/rclone/rclone.conf | tr -d '\n'
```

```powershell
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:APPDATA\rclone\rclone.conf"))
```

### 4. Paste it into GitHub

1. Open the repo → **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Name: `RCLONE_CONF_B64` — Value: the base64 blob → **Add secret**

### 5. (Optional) point the sync at a subfolder

Repo → **Settings** → **Secrets and variables** → **Actions** → **Variables** →
**New repository variable**:

| Variable | Example | Meaning |
|---|---|---|
| `DRIVE_PATH` | `Om` | Only sync `gdrive:Om` instead of the whole remote root |

Then clear your terminal scrollback / clipboard if your shell saved it.

---

## Method B — Google service account

Better for **Google Workspace / Shared Drives**. It cannot be used with a
personal `@gmail.com` My Drive: service accounts have no storage quota of their
own and any upload fails with
`403: Service Accounts do not have storage quota`.

1. In the [Google Cloud Console](https://console.cloud.google.com/), create a
   project (or pick one).
2. **APIs & Services → Library** → enable **Google Drive API**.
3. **IAM & Admin → Service Accounts → Create service account**; name it
   something like `drive-sync`. No roles needed.
4. Open the new account → **Keys → Add key → Create new key → JSON**. A JSON
   file downloads.
5. In Google Drive, share the target folder (or Shared Drive) with the service
   account's `client_email` (looks like
   `drive-sync@your-project.iam.gserviceaccount.com`) as **Editor**
   (Content Manager for Shared Drives).
6. In GitHub, add a secret named `GDRIVE_SA_JSON` containing the **entire JSON
   file**. Add these **repository variables**:
   - `GDRIVE_FOLDER_ID` — the folder ID you shared (required for a normal
     folder)
   - `GDRIVE_TEAM_DRIVE` — the Shared Drive ID (only if you use one)

---

## Checking it worked

Actions tab → **Drive sync** → **Run workflow** → tick **dry_run** → Run.
Open the run; the "Run the sync" step should end with a list of files instead
of an auth error. If it fails, expand the failing step — the messages below
cover the common cases.

| Error you see | What it means |
|---|---|
| `Failed to create file system ... couldn't find section in config file` | `RCLONE_CONF_B64` holds a config with a remote named something other than `gdrive`. Rename it, or set the `DRIVE_REMOTE` variable. |
| `RCLONE_CONF_B64 is not valid base64` | Line breaks or shell wrapping got in. Re-run the base64 command and copy the whole single line. |
| `401 / invalid_grant` | The Google token was revoked or expired. Repeat Method A steps 2–4 to mint a fresh one. |
| `403: Service Accounts do not have storage quota` | You are on Method B with a personal Drive. Switch to Method A. |
| `directory not found` | `DRIVE_PATH` must be a folder that already exists in Drive. Create it (or leave the variable empty) — the sync never creates its own root. |
| `filters file has changed (must run --resync)` | You edited `.drivesync-ignore`. The workflow retries once automatically; tick the `resync` box if it still complains. |
| `too many deletes` / `--max-delete` exceeded | The 10% safety brake. Usually a folder rename. Set the `DRIVE_FORCE` variable to `true` for one run, then set it back. |
| `Failed to ... oauth2: cannot fetch token` | Clock/credential problem — re-do the base64 step. |
