# Obsidian Headless (`ob`)

Headless client for Obsidian Sync and Publish — syncs and publishes vaults from the CLI without the desktop app. Required for fully headless/cron automation setups.

**Requires:** Node.js 22+  
**Install:** `npm install -g obsidian-headless`  
**Docs:** https://github.com/obsidianmd/obsidian-headless

---

## Authentication

```bash
# Login (interactive — prompts for email/password)
ob login

# Check login status
ob login
```

---

## Sync Commands

### `ob sync-list-remote`
List all remote vaults available to your account (including shared vaults).

### `ob sync-list-local`
List locally configured vaults and their paths.

### `ob sync-setup`
Set up sync between a local vault and a remote vault.

```bash
cd ~/MyVault
ob sync-setup --vault "My Vault"
```

Options:
- `--vault <id-or-name>` — remote vault identifier (required)
- `--path <local-path>` — local directory (default: current)
- `--password <password>` — E2E encryption password (prompted if omitted)
- `--device-name <name>` — device name shown in sync version history

### `ob sync`
Run a one-time sync (downloads remote changes to local).

```bash
ob sync
```

### `ob sync --continuous`
Watch for changes and sync continuously in the background. Use for servers/cron environments.

```bash
# Run in background
ob sync --continuous &
```

### `ob sync-status`
Show sync status for a vault.

---

## Publish Commands

### `ob publish-list-sites`
List publish sites.

### `ob publish-create-site`
Create a new publish site.

```bash
ob publish-create-site --name "My Site" --vault "My Vault"
```

### `ob publish-setup`
Connect a local vault to a publish site.

```bash
cd ~/MyVault
ob publish-setup --site "My Site"
```

### `ob publish`
Publish vault changes to the connected site.

```bash
ob publish
```

### `ob publish-site-options`
View or update publish site options.

---

## Workflow for Headless Automation

```
┌─────────────────────────────────────────────────────┐
│  1. ob login                                        │
│     Authenticate with your Obsidian account         │
│                                                     │
│  2. ob sync-setup --vault "My Vault"               │
│     Link local vault to remote                      │
│                                                     │
│  3. ob sync --continuous &                          │
│     Keep local vault in sync with remote            │
│                                                     │
│  4. process-inbox.sh (cron)                        │
│     Automation script writes to local vault          │
│     directly — no Obsidian app needed              │
│                                                     │
│  5. ob sync                                         │
│     Push processed notes back to remote             │
└─────────────────────────────────────────────────────┘
```

The `process-inbox.sh` script uses direct file operations (cp, mv, cat, mkdir, write_file) — it never calls `obsidian` or `ob`. Running `ob sync --continuous` in the background keeps the local vault directory current with your remote, so any notes created by the automation are automatically synced.

---

## `ob` vs `obsidian` (Desktop CLI)

| Feature | `ob` (headless) | `obsidian` (desktop) |
|---|---|---|
| Vault sync | ✓ | — |
| Vault publish | ✓ | — |
| Note create/read/search | — | ✓ |
| Works without desktop app | ✓ | — |
| Works in cron/headless | ✓ | — |
| Requires running app | — | ✓ |
