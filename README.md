# GitLab Manager TUI (`gitlab-manager.sh`)

A single-file, secure Bash TUI for managing GitLab **Groups** and **Projects** with sane defaults and strong security.
Targets **Debian/Ubuntu/Kali** hosts, uses the system **keyring** for token storage, enforces **HTTPS**, and clones repositories into `~/.glab-repos` by default.

> Maintainer: *this repository*
> Version: **v1.2.3**
> Supported GitLab: GitLab.com and self-managed (HTTPS)

---

## Table of Contents

* [Features](#features)
* [Security Model](#security-model)
* [Quick Start](#quick-start)
* [Prerequisites](#prerequisites)
* [Installation](#installation)
* [Configuration & State](#configuration--state)
* [Usage Guide](#usage-guide)

  * [Main Menu](#main-menu)
  * [Groups](#groups)
  * [Projects](#projects)
  * [Settings](#settings)
* [Clone Directory Layout](#clone-directory-layout)
* [CI Template Injected on Create](#ci-template-injected-on-create)
* [Required Token Scopes](#required-token-scopes)
* [Troubleshooting](#troubleshooting)
* [FAQ](#faq)
* [Uninstall / Cleanup](#uninstall--cleanup)
* [Roadmap](#roadmap)
* [License](#license)

---

## Features

* **Secure token storage** via `secret-tool` (libsecret; system keyring). No env vars, no plaintext files.
* **HTTPS-only** API calls with TLS 1.2+, retries, and robust error handling.
* **Interactive TUI** with clear menus, confirmations for destructive actions, and colorized output.
* **Default clone root**: `~/.glab-repos` (mode `0700`).

  * **All clones** go there.
  * **Newly created projects** are **auto-cloned** there after initialization.
* **Automatic dependency handling** on Debian/Ubuntu/Kali: prompts to `apt install` missing tools.
* **Caching with TTL** (default 5 minutes) for snappy list operations; manual cache clear.
* **POSIX-friendly** Bash with `set -Eeuo pipefail`, consistent error traps, input validation.
* **No hardcoded paths** (beyond the clone root); all other state is local to the working directory.

---

## Security Model

* **Token storage**: your GitLab PAT/Group/Project token is saved in the system keyring (libsecret) under:

  * `service=gitlab-manager`, `account=access-token`, `instance=<your GitLab base URL>`.
* **Transport security**: all API requests enforce `--proto =https` and TLS v1.2+.
* **Least privilege**: you choose the token type and scopes (see [Required Token Scopes](#required-token-scopes)).
* **No leakage**: the token is never written to disk, never exported to the environment, and never echoed.

---

## Quick Start

```bash
# 1) Make the script executable
chmod +x gitlab-manager.sh

# 2) Run it (will prompt to install missing packages on Debian/Ubuntu/Kali)
./gitlab-manager.sh

# 3) On first run you'll be asked for:
#    - GitLab instance URL (default: https://gitlab.com)
#    - Personal/Group/Project Access Token (stored in system keyring)
```

Once running, navigate the menus to create/list/rename/delete **Groups** and **Projects**, or **clone** projects into `~/.glab-repos`.

---

## Prerequisites

* **OS**: Debian, Ubuntu, or Kali Linux
* **Bash**: 4.x or newer
* **Packages** (the script can install these for you):

  * `curl`, `jq`, `git`, `libsecret-tools` (provides `secret-tool`)
* **Network**: HTTPS access to your GitLab instance
* **Access Token**: PAT or Group/Project token with sufficient scopes (see below)

> The TUI will detect missing packages and prompt to `apt install` them using `sudo` (or ask you to run as root).

---

## Installation

**Simple (recommended)**

1. Add `gitlab-manager.sh` to a directory in your repo or scripts folder.
2. `chmod +x gitlab-manager.sh`
3. Run: `./gitlab-manager.sh`

**Optional: Add to PATH**

```bash
sudo install -m 0755 gitlab-manager.sh /usr/local/bin/gitlab-manager
gitlab-manager
```

---

## Configuration & State

| Item           | Location                         | Purpose                                    |
| -------------- | -------------------------------- | ------------------------------------------ |
| Instance URL   | `./.gitlab_manager_config.json`  | Stores `instance_url` for this working dir |
| Cache (TTL 5m) | `./.gitlab_manager_cache/*.json` | Caches list responses for speed            |
| Token (secure) | System keyring via `secret-tool` | Stored with service `gitlab-manager`       |
| Clone root     | `~/.glab-repos` (mode `0700`)    | All clones live here                       |

> Configuration and cache are **per working directory**. The clone root is **global** (`$HOME/.glab-repos`).

---

## Usage Guide

### Main Menu

```
Main Menu:
1) Groups
2) Projects
3) Settings
4) Quit
```

### Groups

* **New Group** — Prompt for group name/path and optional parent group ID; creates the group.
* **Rename Group** — Choose a group from your accessible list and update its `name`.
* **List Groups** — Displays: `ID`, `full_path`, `name`.
* **Delete Group** — Choose a group and confirm. **Destructive**; requires confirmation.

APIs used: `GET/POST/PUT/DELETE /api/v4/groups`

### Projects

* **Clone Project** — Pick a project and clone into `~/.glab-repos/<namespace>/<project>`.
  Uses SSH URL when available; falls back to HTTPS.
* **Create Project** — Creates a repo (optionally under a group), initializes README, **injects CI template** (see below), then **auto-clones** into the clone root.
* **Rename Project** — Choose a project and update its `name`.
* **List Projects** — Displays: `ID`, `path_with_namespace`, `last_activity_at`.
* **Delete Project** — Choose a project and confirm. **Destructive**; requires confirmation.

APIs used:
`GET/POST/PUT/DELETE /api/v4/projects`,
`GET/POST/PUT /api/v4/projects/:id/repository/files/:path`

> The tool re-fetches a newly created project once to obtain stable clone URLs and handles brief propagation delays gracefully.

### Settings

* **Update GitLab token** — Replace the token in the keyring for the active instance.
* **Set GitLab instance URL** — Change from the default `https://gitlab.com` to your self-managed URL (must be HTTPS).
* **Clear cached data** — Clears `./.gitlab_manager_cache/*.json` for a fresh view.

---

## Clone Directory Layout

All repositories are cloned into `~/.glab-repos` (mode `0700`):

```
~/.glab-repos/
└── <group-or-user>/
    └── <subgroup>/...
        └── <project>/.git
```

* If a repository already exists at that path: the tool runs `git fetch --all --prune` and a fast-forward `git pull`.
* If you prefer SSH, add your SSH key to GitLab; the script will automatically prefer the SSH clone URL when available.

---

## CI Template Injected on Create

When creating a project, the tool commits:

* `README.md` with a basic scaffold
* `.gitlab-ci.yml` with:

```yaml
variables:
  PUSH_TO_GITHUB: "true"
  GITHUB_REPO_PRIVATE: "false"
include:
  - project: '${SHARED-CONF}'
    file: 'github-deploy.yml'
```

**What to know:**

* Ensure the include target (`${SHARED-CONF}` / `github-deploy.yml`) exists and is accessible from your new project.
* Adjust variables (e.g., `PUSH_TO_GITHUB`) to suit your workflow after creation.
* The default branch is detected from the API (falls back to `main`).

---

## Required Token Scopes

Choose the **least privilege** that fits your workflow:

* **Personal Access Token (PAT)** (broadest):

  * Recommended scopes: `api` (required for Groups/Projects CRUD and repository file API).
* **Group Access Token** (scoped to a group):

  * Scopes: `api` (and ensure the group has permission to create/delete projects as desired).
* **Project Access Token** (scoped to a single project):

  * Scopes: `api` and `write_repository` (sufficient for repository file writes).
  * *Note*: cannot create new projects by definition.

> If in doubt, use a PAT with `api` while you evaluate this tool, then tighten to group/project tokens.

---

## Troubleshooting

### “No clone URL available for new project”

* The tool re-fetches the project after creation (with short retries).
* If clone URLs still aren’t present, it constructs a valid HTTPS URL from `instance_url + path_with_namespace + .git`.
* Ensure your token has `api` scope and you have project visibility to read clone URLs.

### “Clone root not writable”

* Ensure `~/.glab-repos` exists and is writable by your user:

  ```bash
  mkdir -p -m 700 ~/.glab-repos
  ```

### “Keyring locked” or `secret-tool` errors

* Install `libsecret-tools` (the TUI will offer to install).
* Ensure a Secret Service (e.g., GNOME Keyring) is available/started in your session.

### “Unexpected error (line …)”

* The tool uses `set -Eeuo pipefail` and a strict error trap.
* Re-run with clean network, confirm token scopes/validity, and clear cache from **Settings**.

### SSH cloning fails

* Add your SSH public key to GitLab (`~/.ssh/id_ed25519.pub` or `id_rsa.pub`).
* The tool falls back to HTTPS where SSH URLs are unavailable.

---

## FAQ

**Q: Where is the token stored?**
A: In your system keyring via `secret-tool`, labelled “GitLab PAT (<instance URL>)”.

**Q: Can I change the clone directory?**
A: Currently fixed to `~/.glab-repos` by design for consistency. (A future option may make this configurable.)

**Q: Does it work on macOS/Arch/etc.?**
A: This tool is built and tested for **Debian/Ubuntu/Kali**. Other distros aren’t officially supported here.

**Q: What if I work across multiple GitLab instances?**
A: The token is stored *per instance URL* in the keyring. Use **Settings → Set GitLab instance URL** and then **Update GitLab token**.

---

## Uninstall / Cleanup

```bash
# Remove script (wherever you installed it)
rm -f ./gitlab-manager.sh

# Remove local config & cache (from each working directory that used it)
rm -rf .gitlab_manager_config.json .gitlab_manager_cache/

# Remove token from keyring (per instance URL)
# Example for gitlab.com:
secret-tool clear service gitlab-manager account access-token instance https://gitlab.com

# (Optional) Remove cloned repos (global)
rm -rf ~/.glab-repos/
```

---

## Roadmap

* Optional setting to customize the **clone root** directory.
* Toggle for **SSH vs HTTPS** clone preference.
* Optional “bulk actions” (e.g., bulk clone / audit).
* Export/import of configuration.

---

## License

Choose an appropriate license for this repository (e.g., MIT, Apache-2.0, or your organization’s internal license). Add the license file to the repo root and reference it here.

---

### Appendix: Menu Reference (for quick scanning)

```
Main Menu:
1) Groups
2) Projects
3) Settings
4) Quit
```

```
Groups:
1) New Group
2) Rename Group
3) List Groups
4) Delete Group
5) Back
6) Quit
```

```
Projects:
1) Clone Project
2) Create Project
3) Rename Project
4) List Projects
5) Delete Project
6) Back
7) Quit
```

> **Destructive operations** (delete group/project) require explicit confirmation.
> **Cache** can be cleared from Settings to force fresh API results.
