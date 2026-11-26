# Roadmap: Linux, Windows and more password managers

Status: **proposed**, not started. Today the plugin targets **macOS + zsh + Apple Passwords**.
This document plans the next major version. It covers Linux and Windows support and password
managers beyond Apple Passwords (1Password, Bitwarden and others), while keeping everything
that already works on macOS.

## Goals

- Same everyday experience on **macOS, Linux and Windows**: `pw <site>`, `otp <site>`,
  `pwlogin`, `pwrun`, the developer integrations (AWS MFA, SSH, git, Docker, npm) and command
  hooks (`make` / package.json scripts).
- **Pluggable providers:** Apple Passwords becomes one provider among several. Each provider
  can be configured per machine, and optionally per site (e.g. work in 1Password, personal in
  Apple Passwords).
- **Keep the security guarantees:** no secrets on disk, in argv, in history, or in clipboard
  history (concealed clipboard + auto-clear); list-before-read (one authorisation per lookup);
  idle auto-lock where the provider has a session.
- **No regressions on macOS:** the current test suite keeps passing throughout.

## Non-goals (for this version)

- Writing our own vault, sync or crypto. We only drive each provider's official CLI or API.
- Browser autofill (the providers' own extensions already do that).
- Managing passkeys (no CLI exposes them for use from a terminal).

## Phase 0: research (do this first)

Pick which providers and platforms are worth supporting, using current data rather than
assumptions.

1. **Usage data.** Look up the most used password managers, separately for individuals,
   developers and companies, from current sources:
   - Security.org's annual password manager report
     ([2024 edition](https://security.org/digital-safety/password-manager-annual-report)).
   - Ramp's business spend data
     ([password managers category](https://ramp.com/vendors/categories/password-managers)).
     As of Aug 2026 it ranked 1Password first among businesses, with LastPass and Bitwarden
     next.
   - Vendor and community surveys (e.g. the
     [Bitwarden community survey](https://linuxiac.com/bitwarden-community-survey-reveals-top-privacy-tools-for-2026/)).
     These are self-selected audiences; note the bias.
   - Developer surveys (Stack Overflow, JetBrains) if they cover password or secret managers.
   - Platform defaults that people use without choosing: Apple Passwords, Google Password
     Manager, Microsoft (Edge/Authenticator), and the Linux keyrings (GNOME Keyring / KWallet).
2. **Capability check per candidate.** For each one, answer from the official docs (and by
   trying it):
   - Is there an official CLI or API? Which OSes does it run on?
   - Can it **list account names without revealing secrets**?
   - Can it read a password for site + username?
   - Can it read **TOTP codes**?
   - How does it authenticate (biometric unlock, session token, master password), and how
     long does a session last?
   - Machine-readable output (JSON)? Licensing and terms that matter for automation?
3. **Shell and OS usage among developers:** zsh / bash / fish on macOS and Linux;
   PowerShell 7, Windows PowerShell, Git Bash and WSL on Windows.
4. **Output:** fill in the provider matrix below (replacing the "to verify" cells). Rank
   providers by usage × feasibility, and decide the support tiers (see "Provider tiers").

### Provider matrix (preliminary — every "?" must be verified in Phase 0)

| Provider | CLI | macOS | Linux | Windows | Names-only listing | Password | TOTP | Notes |
|---|---|---|---|---|---|---|---|---|
| Apple Passwords | `apwcli` / `apw` (community) | ✅ | ❌ | ? | ✅ (ghost search) | ✅ | ✅ | Works today via the browser-extension helper; iCloud for Windows ships an iCloud Passwords extension. Check whether a Windows helper can be driven the same way. |
| 1Password | `op` (official) | ✅ | ✅ | ✅ | ✅ (`op item list`) | ✅ | ✅ (`op item get --otp`) | Desktop-app integration gives biometric unlock; most used among businesses. |
| Bitwarden | `bw` (official), `rbw` (community) | ✅ | ✅ | ✅ | ✅ (`bw list items`, metadata) | ✅ | ✅ (`bw get totp`; premium feature?) | `bw` uses a session key (`BW_SESSION`); `rbw` keeps an agent. |
| KeePassXC | `keepassxc-cli` (official) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (`show --totp`) | Local database; unlocks with password/key file. |
| Proton Pass | `pass-cli` (official, new) | ? | ? | ? | ? | ? | ? | CLI announced by Proton; TOTP support unknown. |
| Dashlane | `dcli` (official) | ? | ? | ? | ? | ✅ | ? | Device registration (`dcli sync`); TOTP unknown. |
| LastPass | `lpass` (open source) | ✅ | ✅ | ? (WSL/Cygwin) | ✅ | ✅ | ? | Still widely used in companies; check whether it's maintained. |
| Keeper | Keeper Commander (official) | ? | ? | ? | ? | ? | ? | Business-focused. |
| pass / gopass | `pass`, `gopass` | ✅ | ✅ | ~ (WSL) | ✅ | ✅ | ✅ (pass-otp / built in) | Popular with developers on Linux. |
| Linux Secret Service (GNOME Keyring, KWallet) | `secret-tool` | — | ✅ | — | ? | ✅ | ❌ | No TOTP; useful as a fallback for passwords. |
| Windows Credential Manager | `cmdkey`, PowerShell modules | — | — | ✅ | ? | ✅ (generic credentials) | ❌ | No TOTP; site matching is by target name. |
| Google Password Manager, Microsoft (Edge/Authenticator), NordPass, Enpass | none known | — | — | — | — | — | — | Probably not drivable from a terminal; confirm in Phase 0. |

Sources used for this first draft:
- [List of password managers](https://en.wikipedia.org/wiki/List_of_password_managers) and
  [Comparison of OTP applications](https://en.wikipedia.org/wiki/Comparison_of_OTP_applications).
- CLI usage examples for `op`/`bw`
  ([viscosity-otp providers wiki](https://github.com/jerotire/viscosity-otp/wiki/Providers)).
- [1Password CLI 2.0 announcement](https://blog.1password.com/1password-cli-2_0).
- [KeePassXC CLI (Gentoo wiki)](https://wiki.gentoo.org/wiki/KeePassXC/cli).
- Proton's CLI discussion ([Proton Pass feedback forum](https://protonmail.uservoice.com/forums/953584-proton-pass/suggestions/46853284-command-line-interface?page=3)).
- [Vaultcast for Raycast](https://www.raycast.com/SemL/vaultcast-password-search) (lists `dcli`/`pass-cli` as supported tools).

### Provider tiers (to decide after Phase 0)

- **Tier 1:** full feature set (picker, TOTP, every integration), tested in CI with fakes.
  Likely 1Password, Bitwarden, Apple Passwords, KeePassXC.
- **Tier 2:** passwords plus TOTP where available; fewer integrations.
- **Tier 3:** password-only fallbacks (Secret Service, Windows Credential Manager).

## Phase 1: provider abstraction (macOS only, no new features)

Refactor before adding anything, so each later step is small.

- Define a **provider interface** that every backend implements:

  | Operation | Purpose |
  |---|---|
  | `detect` | Is this provider installed and usable here? |
  | `status` / `unlock` (pair) / `lock` | Session handling (PIN pairing, biometric unlock, session tokens) |
  | `list <site>` | Account names and domains, **no secrets** (powers the picker) |
  | `get-password <site> <user>` | One password |
  | `get-otp <site> [user]` | Current TOTP code |

  Each operation returns the same JSON shape the plugin uses today:
  `{"results":[{username, domain, password|code}], "status":N}`, with the same status codes
  (0 ok, 2 bad input, 3 nothing found, 9 locked/not paired, 100 provider error).
- Move `apwcli` and `apw` behind this interface. Site matching and narrowing, the picker,
  clipboard, cache, auto-lock and hooks stay provider-agnostic.
- **Provider selection:** keep `APPLE_PW_BACKEND` for compatibility and add a general
  `PW_PROVIDER` (auto | apple | 1password | bitwarden | …). Add optional per-site routing
  (e.g. `*.mycompany.com → 1password`), stored in the config written by `pw-setup`.
- Rename the project and settings from "apple-passwords" to a neutral name (e.g.
  `pw`/`zsh-passwords`), with compatibility shims for the old names.

## Phase 2: core engine decision

Today everything is ~1,000 lines of zsh. Linux can reuse zsh, but Windows cannot. Options:

| Option | Pros | Cons |
|---|---|---|
| **A. Portable core binary** (Go or Rust) with thin shell front-ends (zsh, bash, fish, PowerShell) | One implementation of providers, matching, picker, clipboard and helpers; fast startup; single file to install; easy to test | Rewrite of the logic; build and release pipeline needed |
| B. Keep zsh, add a separate PowerShell module | Fastest for Linux | Two implementations to keep in sync forever |
| C. Python core | Easy to write; apwcli is already Python | Needs a Python runtime on Windows; slower startup for every `pw` |

**Recommendation:** option A, so the git/docker/askpass helpers and hooks work the same on
every OS. Front-ends keep the shell-specific parts: keybindings, completion, function wrappers
for `make`/`npm`. Confirm after Phase 0 and Phase 1.

## Phase 3: Linux

- **Shells:** zsh (current plugin, unchanged UX), plus bash and fish front-ends.
- **Clipboard:**
  - Wayland: `wl-copy`. X11: `xclip`/`xsel`.
  - Mark copies as secret with the `x-kde-passwordManagerHint: secret` MIME type, which KDE
    Klipper honours. Check GNOME and other clipboard managers, and whether `wl-copy` has a
    sensitive mode.
  - Auto-clear only if the clipboard is unchanged.
- **Touch ID equivalent:** whatever the provider offers (1Password/Bitwarden system auth,
  polkit, fingerprint via fprintd).
- **Apple Passwords:** not available on Linux. Document clearly; route to other providers.
- **Packaging:** Homebrew on Linux, plain git clone, and AUR/Nix later if there's demand.

## Phase 4: Windows

- **Shells:** PowerShell 7 module (`pw`, `otp`, `pwlogin`, `pwrun`, tab completion via
  `Register-ArgumentCompleter`, PSReadLine key handlers for the `Ctrl-X p/o` equivalents).
  Git Bash and WSL can use the bash/zsh front-end.
- **Clipboard:**
  - Set the clipboard with the formats that keep secrets out of Windows clipboard history and
    cloud sync: `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory = 0`,
    `CanUploadToCloudClipboard = 0`.
  - Auto-clear only if unchanged.
- **Providers:**
  - 1Password, Bitwarden and KeePassXC CLIs all ship for Windows.
  - Investigate Apple Passwords through iCloud for Windows (whether its browser-extension
    helper can be driven like the macOS one).
  - Windows Credential Manager as a password-only fallback.
- **Integrations:**
  - git: Git Credential Manager is the default on Windows. Our helper must coexist (per-host
    config, as today).
  - SSH: Windows OpenSSH supports `SSH_ASKPASS`; verify `SSH_ASKPASS_REQUIRE`.
  - AWS, npm and Docker: same logic through the core binary.
  - Hooks: wrap `make`, `npm`, `pnpm`, `yarn` and `bun` as PowerShell functions.
- **Packaging:** winget and Scoop.

## Phase 5: providers, one by one

For each provider (in the order chosen in Phase 0):
1. Implement the interface: names-only `list` first, then `get-password`, `get-otp`,
   `status`/`unlock`/`lock`.
2. Map its session model onto auto-lock (e.g. `op signout`, `bw lock`).
3. Add fake-CLI stubs and contract tests (the same suite every provider must pass).
4. Document setup, how site matching works for that provider, and known limits.

## Testing and CI

- **One contract test suite** for every provider, run against fake CLIs (like
  `tests/stubs/`), so no real vault is ever needed in CI.
- **CI matrix:** macOS, Ubuntu and Windows runners × supported shells (zsh, bash, fish,
  PowerShell 7).
- **Security tests:**
  - No secret appears in argv (inspect fake CLIs' arguments), temp files, history, or logs.
  - Clipboard markers are set.
  - Auto-clear never clobbers a newer copy.
- **Manual release checklist** per OS with real providers (one Touch ID / unlock per lookup,
  pairing flows, hooks).

## Open questions

- Per-site provider routing: config file format and precedence with environment variables.
- How to present the same account found in two providers (prefer one, or show both in the
  picker?).
- Project name once it's no longer Apple-specific.
- Should the core binary also serve the MCP/agent use case? If so, keep the default "no
  plaintext passwords to agents" stance from apwcli.

## Suggested order

1. Phase 0 research → provider matrix filled in, tiers decided.
2. Phase 1 refactor on macOS (no behaviour change; tests green).
3. 1Password provider on macOS (largest user base among businesses; exercises the interface
   with a second, very different backend).
4. Phase 2 core decision and implementation.
5. Linux (zsh/bash) with 1Password + Bitwarden.
6. Windows (PowerShell) with 1Password + Bitwarden.
7. Remaining providers by tier.
