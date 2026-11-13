# atpage-release

for issue, release and discussion

## Install or update app in one-line command

**One-line commands**

- On Linux/macOS

```sh
curl -fsSL https://raw.githubusercontent.com/danloh/atpage-release/main/install.sh | sh
```

- On Windows

```powershell
irm https://raw.githubusercontent.com/danloh/atpage-release/main/install.ps1 | iex
```

**Related scripts and doc**

- [install.sh](install.sh) is for macOS and Linux.
- [install.ps1](install.ps1) is for Windows. A plain `sh` script can't run on Windows, so it's PowerShell; if someone runs `install.sh` from Git Bash, it prints the PowerShell command instead.
- [INSTALL.md](INSTALL.md) is the guide, with all commands and fixes for common problems.

**Options:** `--install` (default), `--update`, `--uninstall [--purge]`, `--repair`, `--troubleshoot`, `--check`, `--list`, `--version X.Y.Z` (or `--target-version`), `--format`, `--yes`, `--force`, `--dry-run`. On Windows they're spelled `-Update`, `-Version 0.1.0`, and so on; `--update`-style also works.

**How it picks a build:**
- **Linux:** a deb or rpm through apt/dnf/zypper when the system supports it, otherwise a per-user AppImage. An installed format is kept on update.
- **macOS:** the right `.app` for Apple silicon or Intel, including when the shell runs under Rosetta.
- **Windows:** the per-user setup.exe for x64 or ARM64; the MSI is optional.

Every download is checked against the SHA-256 checksum GitHub publishes for it. `--repair` also removes a stale `app.atpage://` sign-in handler, which happens when an AppImage is moved or deleted.
