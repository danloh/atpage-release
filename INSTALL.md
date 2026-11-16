# Install atpage

atpage is a desktop client for Bluesky and the AT Protocol. Install it with one command, or download a file from [Releases](https://github.com/danloh/atpage-release/releases).

## One-line install

**macOS and Linux** (Terminal):

```sh
curl -fsSL https://raw.githubusercontent.com/danloh/atpage-release/main/install.sh | sh
```

**Windows** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/danloh/atpage-release/main/install.ps1 | iex
```

The script picks the right build for your system and CPU (x64 or ARM64). Before installing, it checks the download against the SHA-256 checksum GitHub publishes for it.

| System | What gets installed | Where |
|---|---|---|
| Debian, Ubuntu, Mint, … | `.deb` package (via `apt`, asks for your password) | `/usr/bin/atpage-client` |
| Fedora, openSUSE, RHEL, … | `.rpm` package (via `dnf`/`zypper`/`yum`) | `/usr/bin/atpage-client` |
| Other Linux (or `--format appimage`) | AppImage, per user, no password needed (videos don't play, see [Troubleshooting](#video-in-the-appimage)) | `~/.local/share/atpage/` |
| macOS 11+ (Apple silicon or Intel) | `atpage.app` | `/Applications` (or `~/Applications`) |
| Windows 10/11 (x64 or ARM64) | per-user installer, no admin needed | `%LOCALAPPDATA%\atpage` |

## Common tasks

| Task | macOS / Linux | Windows (PowerShell) |
|---|---|---|
| Install | `curl -fsSL …/install.sh \| sh` | `irm …/install.ps1 \| iex` |
| Update | `… \| sh -s -- --update` | `& ([scriptblock]::Create((irm …/install.ps1))) -Update` |
| Install a specific version | `… \| sh -s -- --version 0.1.0` | `… -Version 0.1.0` |
| Check for updates | `… \| sh -s -- --check` | `… -Check` |
| List versions | `… \| sh -s -- --list` | `… -List` |
| Repair (sign-in, shortcuts, broken install) | `… \| sh -s -- --repair` | `… -Repair` |
| Troubleshoot (no changes made) | `… \| sh -s -- --troubleshoot` | `… -Troubleshoot` |
| Uninstall | `… \| sh -s -- --uninstall` | `… -Uninstall` |
| Uninstall and delete local data | `… \| sh -s -- --uninstall --purge` | `… -Uninstall -Purge` |

`…` stands for `https://raw.githubusercontent.com/danloh/atpage-release/main`. The full Windows form with options is:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/danloh/atpage-release/main/install.ps1))) -Update
```

You can also download the script and run it directly:

```sh
curl -fsSLO https://raw.githubusercontent.com/danloh/atpage-release/main/install.sh
sh install.sh --help
```

```powershell
irm https://raw.githubusercontent.com/danloh/atpage-release/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -Help
```

## All options

| macOS / Linux | Windows | Meaning |
|---|---|---|
| `--install` | `-Install` | Install (default). If another version is already installed, it is updated. |
| `--update` | `-Update` | Update to the latest version (or to `--version`). |
| `--uninstall` | `-Uninstall` | Remove the app. Your local data is kept unless you add `--purge`. |
| `--repair` | `-Repair` | Reinstall the installed version and register the `app.atpage://` sign-in link handler, desktop entry and icon again. |
| `--troubleshoot` | `-Troubleshoot` | Check the installation, system libraries/WebView2, network and sign-in handler. |
| `--check` | `-Check` | Show the installed and the latest version. |
| `--list` | `-List` | List published versions. |
| `--version X.Y.Z` | `-Version X.Y.Z` | Target version (also `--target-version`). Default: latest. |
| `--format F` | `-Format F` | Linux: `deb`, `rpm`, `appimage`. macOS: `app`, `dmg`. Windows: `exe` (per user), `msi` (per machine, x64, needs admin). |
| `--install-dir DIR` | – | macOS app folder, or Linux AppImage folder. If you use it, pass it again when you update or uninstall. |
| `--purge` | `-Purge` | With uninstall: also delete settings, sign-in sessions and caches. |
| `--yes` | `-Yes` | Don't ask before acting. A running atpage is closed automatically. |
| `--force` | `-Force` | Reinstall the same version, or allow a downgrade. |
| `--dry-run` | `-DryRun` | Show what would happen without changing anything. |

The GitHub API is used to read checksums and version lists. If you hit its rate limit, set `GITHUB_TOKEN` to any GitHub token.

## Troubleshooting

Run the troubleshooter first. It changes nothing on your system:

```sh
curl -fsSL https://raw.githubusercontent.com/danloh/atpage-release/main/install.sh | sh -s -- --troubleshoot
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/danloh/atpage-release/main/install.ps1))) -Troubleshoot
```

- **Signing in through the browser doesn't return to atpage.** Run `--repair`. This usually happens when an AppImage was moved or deleted and the `app.atpage://` link still points to the old file.
- **macOS says the app is damaged or can't be opened.** These builds are not code-signed yet. Run `--repair`, which clears the quarantine flag, or right-click the app and choose *Open*.
- **Linux: the AppImage doesn't start.** Install FUSE 2: `sudo apt install libfuse2` (Ubuntu 24.04+: `libfuse2t64`). Alternatively, install the `.deb` or `.rpm` with `--format deb` or `--format rpm`.
- **Linux: blank or white window** (common with NVIDIA drivers). Start atpage with `WEBKIT_DISABLE_DMABUF_RENDERER=1 atpage-client`.
- **Linux: videos don't play** (deb/rpm). Install the GStreamer plugins: `gstreamer1.0-plugins-good`, `gstreamer1.0-plugins-bad` and `gstreamer1.0-libav` on Debian/Ubuntu (Fedora: `gstreamer1-plugins-good`, `gstreamer1-plugins-bad-free`, `gstreamer1-plugin-libav`).
- **Linux: videos don't play in the AppImage.** <a id="video-in-the-appimage"></a>The AppImage does not include an H.264 video decoder (for licensing reasons), so most videos cannot play in it. Install the `.deb` or `.rpm` package instead (`--format deb` / `--format rpm`), which uses your system's codecs (see the previous item). Everything else works the same in the AppImage.
- **Windows: blank window.** Make sure the WebView2 runtime is installed (`-Troubleshoot` shows its version), or set `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu`.
- **Start fresh.** Run `--uninstall --purge`, then install again. Your posts and account live on your PDS and are not affected.

Still stuck? [Open an issue](https://github.com/danloh/atpage-release/issues) and include the troubleshooter output.
