# zsh-apple-passwords

Passwords and 2FA (TOTP) codes from **Apple Passwords / iCloud Keychain**, straight from zsh,
without leaking them into history, scrollback, `ps`, or clipboard managers.

```console
$ pw github.com
✓ password for me@example.com (github.com) copied — clears in 20s
$ otp github.com
✓ 2FA code 123456 for me@example.com (github.com) copied (valid ~17s) — clears in 20s
$ pwlogin github.com          # password, then (press a key) the 2FA code
$ pwrun -e PGPASSWORD=admin@db.example.com -- psql -h db.example.com -U admin
```

## How it works

Apple offers no public API or CLI for Passwords. Its only bridge is the
`PasswordManagerBrowserExtensionHelper` that the iCloud Passwords browser extension uses, and since
macOS 15.4 it can only be launched by an approved browser. So this plugin drives one of two
community backends, which run a **headless Chrome/Brave with Apple's real extension** and pair
with it using the 6‑digit PIN macOS shows (once per daemon lifetime):

| Backend | Install | Notes |
|---|---|---|
| [apwcli](https://github.com/michel-tricot/apwcli) (preferred) | `brew install michel-tricot/tap/apwcli` | MIT; auto-starts; works on macOS 27 |
| [bendews/apw](https://github.com/bendews/apw) | `brew install bendews/homebrew-tap/apw` then `brew services start apw` | GPL; needs `apw auth` after each restart |

Both need Chrome, Brave, Edge or Chromium installed, plus `jq`. The plugin picks whichever is
installed (`APPLE_PW_BACKEND=auto`), apwcli first.

Lookups are **per site**: Apple's protocol cannot list your whole vault. Completion learns sites
from your past lookups.

## Install

Clone it somewhere **not** synced by iCloud (files evicted from `~/Documents` would stall shell
startup):

```sh
git clone https://github.com/hianbattiston/zsh-passwords.git ~/zsh-passwords
```

- **oh-my-zsh:** `ln -s ~/zsh-passwords $ZSH_CUSTOM/plugins/apple-passwords`, then add
  `apple-passwords` to `plugins=(…)`.
- **zinit:** `zinit light hianbattiston/zsh-passwords`
- **antidote:** add `hianbattiston/zsh-passwords` to your plugins file.
- **plain:** `fpath+=(~/zsh-passwords)` before `compinit`, then
  `source ~/zsh-passwords/apple-passwords.plugin.zsh`.

The first lookup runs a short setup wizard (`pw-setup` reruns it).

## Commands

| Command | |
|---|---|
| `pw [-c\|-p] <site> [user]` | Password. In a terminal it's copied; piped or `$(pw site)` prints it. `-c`/`-p` force copy/print. Several accounts → picker (fzf if installed, else a numbered menu). |
| `otp [-c\|-p] <site> [user]` | Current 2FA code. If it expires in under 4 s, waits for the next one. |
| `pwlogin <site> [user]` | Copies the password, then after a key press the 2FA code (`q` skips). |
| `pwrun [-e VAR=[user@]site]… [-t VAR=[user@]site]… -- cmd …` | Runs `cmd` with passwords (`-e`) / 2FA codes (`-t`) in its environment only. Usernames may contain `@` (split on the last one). Presets: `--pg`, `--mysql`, `--twine`. |
| `pw-setup` | Configure auto-lock, clipboard clearing, backend, keybindings. |
| `pw-status` / `pw-pair` / `pw-lock` | Health check / pair now / stop the bridge and drop pairing. |

- **One prompt per lookup:** macOS asks you to authorise every password it hands out. Like a
  browser, `pw` first lists the site's account names (no password read, no prompt), lets you
  pick one, then reads only that password. Pass the username (`pw site user`) to skip the list.
- **Narrowing:** Apple matches by base domain (`aws.amazon.com` would also return every
  amazon.com shopping login), so results are narrowed to the host you typed and its subdomains.
- **Aliases and shorthand:** `aws`, `gcp` and `azure` are built-in aliases (`aws` →
  `aws.amazon.com`). Add your own with `typeset -A APPLE_PW_ALIASES=(work sso.example.com)`.
  Any other dot-less name, such as `pw github`, resolves to a cached `github.*` site, otherwise
  to `github.com`.
- **Keys:** <kbd>Ctrl-X</kbd> <kbd>p</kbd> / <kbd>Ctrl-X</kbd> <kbd>o</kbd> start a
  ` pw ` / ` otp ` line with tab completion. Whatever you were typing comes back afterwards. Keys
  are bound only if they're unbound.

## Developer integrations

Each integration uses the tool's own credential hook, so **the tool tells the plugin which
host or account it needs**. Nothing guesses from screen output.

| Tool | Command | How it works |
|---|---|---|
| **AWS CLI** (MFA) | `awsmfa staging` | Reads the profile's `mfa_serial` (+ `role_arn`/`source_profile`), gets the 2FA code from `aws.amazon.com` (one Touch ID), calls STS and exports `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` into the shell. `awsmfa -c` clears them. |
| **SSH** | `pwssh user@host`, `pwssh scp …`, `pwssh rsync …` | Runs ssh with `SSH_ASKPASS` → `bin/apple-pw-askpass`. ssh passes its prompt (`user@host's password:`, `(user@host) Verification code:`), so the right password or server 2FA code is looked up by host. Host-key questions and key passphrases still ask you. |
| **git** (HTTPS) | `pw-git enable gitlab.example.com` | Registers `git-credential-apple-passwords` for that host only. git sends `host=…`, the helper answers with username/password. For GitHub, save a personal access token as the password. |
| **Docker** | `pw-docker enable ghcr.io`, `pw-docker enable docker` | Adds a per-registry `credHelpers` entry using `docker-credential-apple-passwords`. Docker Hub logins are looked up under `docker.com`. Your other Docker settings are left untouched. |
| **npm / pnpm / yarn** | `npmotp publish`, `npmotp pnpm publish` | Adds `--otp=<code>` from your npmjs.com 2FA entry. |
| **Postgres / MySQL / PyPI** | `pwrun --pg admin@db.host -- psql`, `pwrun --mysql …`, `pwrun --twine pypi -- twine upload dist/*` | Fills `PGHOST/PGUSER/PGPASSWORD`, `MYSQL_HOST/MYSQL_PWD`, `TWINE_USERNAME/TWINE_PASSWORD` for that one command. |
| **gh, gcloud, az, Vercel, Heroku** | — | They log in through the browser, which uses Apple Passwords directly. |

Tool aliases: `aws`, `npm`/`pnpm`/`yarn` (npmjs.com), `docker`/`dockerhub` (docker.com),
`pypi`/`twine`, `github`, `gitlab`, `bitbucket`, `gcp` (google.com), `azure`
(microsoftonline.com), `heroku`, `vercel`, `cloudflare`, `digitalocean`. So `otp npm` just works.

**Where to save entries:** SSH servers and private registries/git hosts are looked up by
hostname, so save them in Passwords with that hostname as the website, and add the 2FA code
to the same entry. For `awsmfa`, the 2FA entry is matched by your MFA device name; set
`aws configure set apple_pw_user <username> --profile X` if yours differs.

**Notes:**
- 2FA codes passed as `--token-code`/`--otp` are briefly visible in `ps`; they're single-use
  and expire within 30 s.
- AWS session credentials live in that shell's environment until they expire or you run
  `awsmfa -c`.

## Configuration

`pw-setup` writes `~/.config/apple-passwords/config.zsh`. Variables you set yourself (e.g. in
`.zshrc`, before the plugin loads) always win.

| Variable | Default | |
|---|---|---|
| `APPLE_PW_AUTOLOCK` | `900` | Seconds without lookups before the bridge is stopped; `0` = never |
| `APPLE_PW_CLEAR_AFTER` | `20` | Seconds before a copied secret is cleared; `0` = never |
| `APPLE_PW_BACKEND` | `auto` | `auto`, `apwcli`, or `apw` |
| `APPLE_PW_BIND_KEYS` | `1` | <kbd>Ctrl-X</kbd> <kbd>p</kbd> / <kbd>o</kbd> |
| `APPLE_PW_CACHE` | `1` | Remember site + username (never secrets) for completion and shorthand |
| `APPLE_PW_ALIASES` | unset | Associative array of your own aliases, e.g. `(work sso.example.com)` |
| `APPLE_PW_NO_SETUP` | unset | `1` skips the first-run wizard |

## Security model

What the plugin guarantees:

- **No secrets on disk:** the cache (`~/.cache/apple-passwords/accounts`, mode 600) holds only
  site and username.
- **No secrets in argv or `ps`:** secrets move only through pipes and zsh builtins. Here-strings
  are avoided because zsh writes them to temp files.
- **No secrets in scrollback** unless you pass `-p`, and none in history.
- **Clipboard:** copies carry the `org.nspasteboard.ConcealedType` marker, so clipboard managers
  that honour it (Raycast, Maccy, …) skip them. Copies are cleared after `APPLE_PW_CLEAR_AFTER`
  seconds, but only if you haven't copied something else in the meantime.

What you should know about the backends:

- **Same-user processes:** while a backend is paired, any process running as your user can ask it
  for any password through its socket. That's the same trust level as an unlocked password
  manager.
- **Open DevTools port:** both backends currently control their headless browser through an
  unauthenticated Chrome DevTools port on `127.0.0.1`. While the bridge runs, other local
  accounts and sandboxed apps could connect to that port and read passwords.
- **Mitigation:** auto-lock (default 15 min idle) stops the bridge, which closes the port and
  drops the pairing. `pw-lock` does it immediately, which is worth doing before running untrusted
  code. The cost is re-entering the macOS PIN after idle periods.
- **Headless browser:** the backend keeps a headless browser running in the background (own
  profile) while the bridge is up.

## Tests

`zsh tests/run.zsh` runs offline against fake backends and a fake clipboard; it never touches
real passwords.
