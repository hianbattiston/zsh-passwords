# apple-passwords.plugin.zsh — passwords and 2FA codes from Apple Passwords (iCloud Keychain).
#
# Commands: pw, otp, pwlogin, pwrun, pw-setup, pw-status, pw-pair, pw-lock
# Backends: apwcli (preferred) or bendews/apw — both bridge to Apple's helper through a
# headless browser running the iCloud Passwords extension. See README.md.
#
# Secrets never touch: argv (ps), disk, history, or here-strings (zsh writes those to temp
# files). They travel through pipes and builtins only.

zmodload zsh/datetime 2>/dev/null

typeset -g _APWZ_CONF=${XDG_CONFIG_HOME:-$HOME/.config}/apple-passwords/config.zsh
typeset -g _APWZ_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/apple-passwords
typeset -g _APWZ_TTY=${_APWZ_TTY:-/dev/tty}
typeset -g _APWZ_APW_SOCK=$HOME/.apw/apw.sock
typeset -g _APWZ_ROOT=${${(%):-%x}:A:h}
typeset -g _APWZ_LIBEXEC=$_APWZ_ROOT/libexec
# bin/ holds the helpers git, docker and ssh call themselves (git-credential-…, etc.).
(( ${path[(Ie)$_APWZ_ROOT/bin]} )) || path+=($_APWZ_ROOT/bin)

# Settings the user set explicitly (env / .zshrc) — pw-setup never overrides these.
typeset -ga _APWZ_PRESET=(${(k)parameters[(I)APPLE_PW_*]})
# Config file uses `: ${VAR:=value}`, so anything already set in the environment wins.
[[ -r $_APWZ_CONF ]] && source $_APWZ_CONF
: ${APPLE_PW_BACKEND:=auto} ${APPLE_PW_CLEAR_AFTER:=20} ${APPLE_PW_AUTOLOCK:=900}
: ${APPLE_PW_CACHE:=1} ${APPLE_PW_BIND_KEYS:=1}

# ---------------------------------------------------------------------------- helpers

_apwz_err() { print -ru2 -- "apple-passwords: $*" }
_apwz_msg() { print -ru2 -- "$*" }
_apwz_has_tty() { { : <$_APWZ_TTY } 2>/dev/null }

_apwz_mkcache() { [[ -d $_APWZ_CACHE_DIR ]] || (umask 077; mkdir -p $_APWZ_CACHE_DIR) }

# Pick the backend into $REPLY (honours APPLE_PW_BACKEND=auto|apwcli|apw).
_apwz_backend() {
  REPLY=
  case $APPLE_PW_BACKEND in
    apwcli|apw) (( $+commands[$APPLE_PW_BACKEND] )) && REPLY=$APPLE_PW_BACKEND ;;
    *) if (( $+commands[apwcli] )); then REPLY=apwcli
       elif (( $+commands[apw] )); then REPLY=apw; fi ;;
  esac
  if [[ -z $REPLY ]]; then
    _apwz_err "no backend found (APPLE_PW_BACKEND=$APPLE_PW_BACKEND). Install one:
    brew install michel-tricot/tap/apwcli      # recommended
    brew install bendews/homebrew-tap/apw"
    return 1
  fi
  (( $+commands[jq] )) || { _apwz_err "jq is required: brew install jq"; return 1 }
}

# Is the apw daemon socket accepting connections?
_apwz_apw_up() {
  if zmodload zsh/net/socket 2>/dev/null; then
    local REPLY
    zsocket $_APWZ_APW_SOCK 2>/dev/null || return 1
    exec {REPLY}>&-
  else
    [[ -S $_APWZ_APW_SOCK ]]
  fi
}

# Pair with Apple Passwords. Prompts always go to the terminal, never stdout, so this is
# safe inside $(pw …).
_apwz_pair() {
  local be=$1
  if ! _apwz_has_tty; then
    if [[ $be == apwcli ]]; then   # no terminal: apwcli collects the PIN in a small window
      apwcli daemon pair </dev/null >&2
      return
    fi
    _apwz_err "pairing needs a terminal — run: apw auth"
    return 1
  fi
  _apwz_msg "🔐 Pairing with Apple Passwords — enter the 6-digit PIN macOS shows."
  case $be in
    apwcli) apwcli daemon pair <$_APWZ_TTY >&2 ;;
    apw)
      if ! _apwz_apw_up; then
        _apwz_err "the apw daemon isn't running — start it: brew services start apw"
        return 1
      fi
      apw auth <$_APWZ_TTY >&2 ;;
  esac
}

# Make sure the backend is paired before we capture its output (apwcli's own PIN prompt
# writes to stdout and would be swallowed by $(…)). apw fails fast instead, so skip it.
_apwz_ready() {
  [[ $1 == apwcli ]] || return 0
  apwcli daemon status --json </dev/null 2>/dev/null | jq -e '.paired == true' >/dev/null 2>&1 \
    && return 0
  _apwz_pair apwcli
}

# apwcli's own Python (it carries apwlib), for the names-only account listing.
_apwz_apwcli_python() {
  local bin=${commands[apwcli]:A:h} py
  for py in $bin/python3 $bin/python; do [[ -x $py ]] && { REPLY=$py; return 0 }; done
  return 1
}

# Can this backend list a site's accounts without reading their passwords?
_apwz_can_list() {
  [[ $1 == apw ]] && return 0
  [[ -r $_APWZ_LIBEXEC/apwz-accounts.py ]] && _apwz_apwcli_python
}

# _apwz_query BACKEND KIND SITE [USER] → $REPLY = JSON array of matches. 3 = none.
# KIND: pw | otp | list (account names only — no passwords read, so no macOS prompts).
_apwz_query() {
  local be=$1 kind=$2 site=$3 user=$4 out rc attempt py
  [[ $be/$kind == apwcli/list ]] && { _apwz_apwcli_python || return 1; py=$REPLY }
  for attempt in 1 2; do
    case $be/$kind in
      apwcli/list) out=$($py -I $_APWZ_LIBEXEC/apwz-accounts.py $site </dev/null 2>&1) ;;
      apw/list)    out=$(apw pw list $site </dev/null 2>&1) ;;
      apwcli/*) out=$(apwcli $kind get $site ${user:+"$user"} -o json </dev/null 2>&1) ;;
      apw/pw)   out=$(apw pw get $site ${user:+"$user"} </dev/null 2>&1) ;;
      apw/otp)  out=$(apw otp get $site </dev/null 2>&1) ;;
    esac
    rc=$?
    (( rc == 9 && attempt == 1 )) || break
    _apwz_pair $be || return 9
  done
  # The JSON object is the last line starting with "{" (status lines may precede it).
  local -a lines; lines=(${(M)${(f)out}:#\{*})
  local json=${lines[-1]:-'{}'}
  if (( rc == 3 )); then return 3; fi
  if (( rc != 0 )); then
    local msg; msg=$(print -r -- $json | jq -r '.error // empty' 2>/dev/null)
    if [[ $msg == *timed\ out* ]]; then
      _apwz_err "macOS didn't get an answer in time — approve the Touch ID prompt for Passwords, then retry"
    else
      _apwz_err "${msg:-$be failed (exit $rc)}"
    fi
    return rc
  fi
  # Apple matches by registrable domain (aws.amazon.com → every amazon.com login), so keep
  # only entries on the host asked for or its subdomains — unless that leaves nothing.
  local host=${${${site#*://}%%/*}%%:*}
  REPLY=$(print -r -- $json | jq -c --arg u "$user" --arg h "${host:l}" '
    def under: ascii_downcase | . == $h or endswith("." + $h);
    [.results[]? | select($u == "" or .username == $u)] as $all
    | [$all[] | select([(.sites // [])[], .domain] | map(select(type == "string")) | any(under))]
    | if length > 0 then . else $all end') \
    || { _apwz_err "unexpected output from $be"; return 100 }
  [[ $REPLY != '[]' ]] || return 3
}

# Built-in aliases for services whose logins don't live at <name>.com. Add your own with
#   typeset -A APPLE_PW_ALIASES=(work sso.example.com)   (in .zshrc or the config file)
typeset -gA _APWZ_DEFAULT_ALIASES=(
  aws aws.amazon.com          gcp google.com             azure microsoftonline.com
  npm npmjs.com               pnpm npmjs.com             yarn npmjs.com
  docker docker.com           dockerhub docker.com       pypi pypi.org        twine pypi.org
  github github.com           gitlab gitlab.com          bitbucket bitbucket.org
  heroku heroku.com           vercel vercel.com          cloudflare cloudflare.com
  digitalocean digitalocean.com
)

# Resolve aliases and shorthand: `github` → a cached `github.*` domain, else github.com.
# Sets _apwz_guessed=1 when the .com fallback was used (for a better "not found" message).
_apwz_resolve_site() {
  REPLY=$1 _apwz_guessed=0
  local alias=
  [[ ${(t)APPLE_PW_ALIASES} == association* ]] && alias=${APPLE_PW_ALIASES[$1]}
  : ${alias:=${_APWZ_DEFAULT_ALIASES[$1]}}
  [[ -n $alias ]] && { REPLY=$alias; return }
  [[ $REPLY == *.* || $REPLY == *:* || $REPLY == localhost ]] && return
  local f=$_APWZ_CACHE_DIR/accounts
  local -a lines matches
  [[ -r $f ]] && lines=("${(@f)$(<$f)}")
  matches=(${(M)${lines%%$'\t'*}:#$1.*})
  if (( $#matches )); then REPLY=$matches[1]; else REPLY=$1.com _apwz_guessed=1; fi
}

# _apwz_pick JSON_ARRAY → $REPLY = chosen 0-based index.
_apwz_pick() {
  local json=$1 n
  n=$(print -r -- $json | jq length)
  if (( n == 1 )); then REPLY=0; return; fi
  local -a labels
  labels=("${(@f)$(print -r -- $json | jq -r '.[] | "\(.username) (\(.domain))"')}")
  if ! _apwz_has_tty; then
    _apwz_err "several accounts match: ${(j:, :)labels} — pass a username"
    return 2
  fi
  local i sel
  if (( $+commands[fzf] )) && [[ $_APWZ_TTY == /dev/tty ]]; then
    sel=$(for i in {1..$#labels}; do print -r -- "$i"$'\t'"$labels[i]"; done |
          fzf --height=~40% --reverse --prompt='account> ' --delimiter=$'\t' --with-nth=2..) || return 130
    REPLY=$(( ${sel%%$'\t'*} - 1 ))
  else
    local PS3="account> " choice
    { select choice in "${labels[@]}"; do [[ -n $choice ]] && break; done } <$_APWZ_TTY
    [[ -n $choice ]] || return 130
    REPLY=$(( REPLY - 1 ))
  fi
}

# Copy stdin to the clipboard, marked concealed (clipboard managers such as Raycast skip it),
# and schedule a clear if nothing else is copied meanwhile. The secret goes to osascript via
# stdin; the delayed clear is a fresh osascript process that only knows the changeCount.
_apwz_copy() {
  local cc
  cc=$(osascript -l JavaScript -e 'ObjC.import("AppKit");
var d = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
var s = $.NSString.alloc.initWithDataEncoding(d, $.NSUTF8StringEncoding);
var pb = $.NSPasteboard.generalPasteboard;
pb.clearContents;
pb.setStringForType(s, "public.utf8-plain-text");
pb.setStringForType($(""), "org.nspasteboard.ConcealedType");
pb.changeCount' 2>/dev/null) || return 1
  [[ $cc == <-> ]] || return 1
  if (( APPLE_PW_CLEAR_AFTER > 0 )); then
    osascript -l JavaScript -e "ObjC.import('AppKit'); delay($APPLE_PW_CLEAR_AFTER);
var pb = \$.NSPasteboard.generalPasteboard; if (pb.changeCount == $cc) pb.clearContents; ''" \
      </dev/null >/dev/null 2>&1 &!
  fi
}

# Remember site + username (never secrets) for completion and shorthand.
_apwz_cache_add() {
  [[ $APPLE_PW_CACHE == 1 && -n $1 ]] || return 0
  _apwz_mkcache
  local f=$_APWZ_CACHE_DIR/accounts line="$1"$'\t'"$2"
  local -a lines
  [[ -r $f ]] && lines=("${(@f)$(<$f)}")
  (( ${lines[(Ie)$line]} )) && return 0
  (umask 077; print -r -- $line >>| $f)
}

# Stop/unpair the backend daemon.
_apwz_lock() {
  case $1 in
    apwcli) apwcli daemon stop >/dev/null 2>&1; return 0 ;;
    apw)
      if brew services list 2>/dev/null | grep -q '^apw .*started'; then
        brew services restart apw >/dev/null 2>&1
      else
        _apwz_err "apw isn't managed by brew services — stop the 'apw start' process yourself"
        return 1
      fi ;;
  esac
}

# Auto-lock: after APPLE_PW_AUTOLOCK seconds with no newer lookup, stop the daemon (closes
# its DevTools port and drops the pairing). Runs as a fresh `zsh -f`, holding no secrets.
_apwz_touch() {
  (( APPLE_PW_AUTOLOCK > 0 )) || return 0
  _apwz_mkcache
  local f=$_APWZ_CACHE_DIR/last-use stamp=$EPOCHREALTIME
  (umask 077; print -r -- $stamp >| $f)
  zsh -fc '
    sleep $1
    [[ -r $2 && $(<$2) == $3 ]] || exit 0
    case $4 in
      apwcli) apwcli daemon stop ;;
      apw) brew services list 2>/dev/null | grep -q "^apw .*started" && brew services restart apw ;;
    esac' apwz-autolock $APPLE_PW_AUTOLOCK $f $stamp $1 </dev/null >/dev/null 2>&1 &!
}

# _apwz_get KIND SITE [USER] → reply=(secret username domain)
_apwz_get() {
  local kind=$1 site user=$3 be json rc idx=0 _apwz_guessed=0
  _apwz_firstrun
  _apwz_backend || return 1; be=$REPLY
  _apwz_resolve_site $2; site=$REPLY
  _apwz_ready $be || return 9

  if [[ $kind == pw && -z $user ]] && _apwz_can_list $be; then
    # Like a browser: list account names (no password read, so no macOS prompt), pick one,
    # then read only that password. macOS asks to authorise every password it hands out,
    # so fetching all of a site's passwords would prompt once per account.
    _apwz_query $be list $site ""; rc=$?
    if (( rc == 0 )); then
      local names=$REPLY pick_user pick_domain
      _apwz_pick "$names" || return
      pick_user=$(print -r -- $names | jq -r --argjson i $REPLY '.[$i].username')
      pick_domain=$(print -r -- $names | jq -r --argjson i $REPLY '.[$i].domain')
      _apwz_query $be pw $site "$pick_user"; rc=$?
      if (( rc == 0 )); then
        json=$REPLY
        idx=$(print -r -- $json | jq --arg d "$pick_domain" '(map(.domain) | index($d)) // 0')
      fi
    fi
  else
    _apwz_query $be $kind $site "$user"; rc=$?
    if (( rc == 0 )); then
      json=$REPLY
      _apwz_pick "$json" || return
      idx=$REPLY
    fi
  fi

  if (( rc == 3 )); then
    _apwz_err "no ${${kind/pw/password}/otp/2FA code} saved for $site${user:+ ($user)}"
    (( _apwz_guessed )) && _apwz_msg "  ('$2' was guessed as $site — use the full domain,
   or add an alias: typeset -A APPLE_PW_ALIASES=($2 real.domain.com))"
    return 3
  fi
  (( rc == 0 )) || return rc
  reply=("${(@f)$(print -r -- $json |
    jq -r --argjson i $idx '.[$i] | (.password // .code // ""), .username, .domain')}")
  _apwz_cache_add $site "$reply[2]"
  _apwz_touch $be
}

# For OTPs: if the code is about to roll over, wait for the next one and fetch again.
_apwz_fresh_otp() {
  local site=$1 user=$2 left=$(( 30 - EPOCHSECONDS % 30 ))
  (( left < 4 )) || return 0
  _apwz_msg "code expires in ${left}s — waiting for the next one…"
  sleep $(( left + 1 ))
  _apwz_get otp $site "$user"
}

# Hand over reply[1]: print it, or copy it with a confirmation on stderr.
_apwz_deliver() {
  local mode=$1 kind=$2 secret=$reply[1] who="$reply[2]${reply[3]:+ ($reply[3])}"
  if [[ $mode == print ]]; then
    print -r -- $secret
    return
  fi
  print -rn -- $secret | _apwz_copy || { _apwz_err "could not copy to the clipboard"; return 1 }
  local clear=
  (( APPLE_PW_CLEAR_AFTER > 0 )) && clear=" — clears in ${APPLE_PW_CLEAR_AFTER}s"
  if [[ $kind == otp ]]; then
    _apwz_msg "✓ 2FA code $secret for $who copied (valid ~$(( 30 - EPOCHSECONDS % 30 ))s)$clear"
  else
    _apwz_msg "✓ password for $who copied$clear"
  fi
}

_apwz_usage() {
  case $1 in
    pw|otp) print -r -- "usage: $1 [-c|--copy] [-p|--print] <site> [username]

Fetch the ${${1/pw/password}/otp/current 2FA code} for <site> from Apple Passwords.
In a terminal it is copied to the clipboard (concealed, auto-cleared); when piped or
captured (\$($1 site)) it is printed. -c / -p force either behaviour.
<site> without a dot is shorthand: 'github' → github.com (or a matching cached site)." ;;
    pwlogin) print -r -- "usage: pwlogin <site> [username]

Copy the password, then — after a key press — the 2FA code for the same account." ;;
    awsmfa) print -r -- "usage: awsmfa [profile] [-d seconds] | awsmfa -c

Get temporary AWS credentials with the MFA code from Apple Passwords (one Touch ID) and
export them into this shell. Uses the profile's mfa_serial (and role_arn/source_profile
to assume a role). Optional profile keys: apple_pw_site (default aws.amazon.com) and
apple_pw_user (which 2FA entry to use). -c clears the session." ;;
    pwssh) print -r -- "usage: pwssh [ssh|scp|sftp|rsync|git] args...

Run ssh (or scp/sftp/rsync/git) with password and 2FA ('Verification code') prompts
answered from Apple Passwords, using the host and user from ssh's prompt. Save the
server's login under its hostname. Other prompts (host keys, passphrases) still ask you." ;;
    npmotp) print -r -- "usage: npmotp [npm|pnpm|yarn] args...

Run with --otp=<your npmjs.com 2FA code>. Example: npmotp publish" ;;
    pw-git) print -r -- "usage: pw-git enable|disable <host> | pw-git list

Let git fetch HTTPS credentials for <host> from Apple Passwords (per host only).
For GitHub, save a personal access token as the password — GitHub rejects passwords." ;;
    pw-docker) print -r -- "usage: pw-docker enable|disable <registry> | pw-docker list

Let docker fetch registry credentials from Apple Passwords (per registry).
'docker' means Docker Hub (saved under docker.com)." ;;
    pwrun) print -r -- "usage: pwrun [-e VAR=[user@]site]... [-t VAR=[user@]site]... [--] command [args...]

Run a command with secrets in its environment only (never in history, argv or files).
  -e  password       -t  current 2FA code
  --pg [user@]host     PGHOST, PGUSER, PGPASSWORD   (psql, pg_dump, …)
  --mysql [user@]host  MYSQL_HOST, MYSQL_PWD
  --twine [user@]site  TWINE_USERNAME, TWINE_PASSWORD   (e.g. --twine pypi)
Example: pwrun --pg admin@db.example.com -- psql" ;;
  esac
}

# ----------------------------------------------------------------------------- commands

_apwz_cmd() {
  local kind=$1; shift
  local mode=
  while (( $# )); do
    case $1 in
      -c|--copy)  mode=copy; shift ;;
      -p|--print) mode=print; shift ;;
      -h|--help)  _apwz_usage $kind; return 0 ;;
      --) shift; break ;;
      -*) _apwz_err "unknown option: $1"; _apwz_usage $kind >&2; return 2 ;;
      *) break ;;
    esac
  done
  (( $# == 1 || $# == 2 )) || { _apwz_usage $kind >&2; return 2 }
  if [[ -z $mode ]]; then
    if [[ -t 1 ]]; then mode=copy; else mode=print; fi
  fi
  local -a reply
  _apwz_get $kind $1 "$2" || return
  if [[ $kind == otp ]]; then
    _apwz_fresh_otp $1 "${2:-$reply[2]}" || return
  fi
  _apwz_deliver $mode $kind
}

pw()  { emulate -L zsh -o extended_glob; _apwz_cmd pw "$@" }
otp() { emulate -L zsh -o extended_glob; _apwz_cmd otp "$@" }

pwlogin() {
  emulate -L zsh -o extended_glob
  if [[ $1 == (-h|--help) ]] || (( $# < 1 || $# > 2 )); then
    _apwz_usage pwlogin; [[ $1 == (-h|--help) ]]; return
  fi
  local -a reply pw_reply otp_reply
  _apwz_get pw $1 "$2" || return
  pw_reply=("${reply[@]}")

  # Fetch the 2FA code right away, while the Touch ID approval for the password is still
  # fresh (macOS reuses an approval for a short while), and keep it in memory.
  local period=0
  if _apwz_get otp $1 "$pw_reply[2]" 2>/dev/null || _apwz_get otp $1; then
    _apwz_fresh_otp $1 "$reply[2]" && { otp_reply=("${reply[@]}"); period=$(( EPOCHSECONDS / 30 )) }
  fi

  reply=("${pw_reply[@]}")
  _apwz_deliver copy pw || return
  (( $#otp_reply )) || return 0
  _apwz_has_tty || return 0
  local key
  read -u0 -sk1 "key?Paste it, then press any key for the 2FA code (q to skip)… " <$_APWZ_TTY
  print -u2
  [[ $key == [qQ] ]] && return 0
  if (( EPOCHSECONDS / 30 == period )); then
    reply=("${otp_reply[@]}")
  else                                   # the code rolled over while you were pasting
    _apwz_get otp $1 "$otp_reply[2]" || return
    _apwz_fresh_otp $1 "$reply[2]" || return
  fi
  _apwz_deliver copy otp
}

pwrun() {
  emulate -L zsh -o extended_glob
  # Parallel arrays, one entry per secret: kind, [user@]site, and the env vars to fill.
  local -a kinds targets secret_vars user_vars host_vars
  _apwz_pwrun_add() { kinds+=($1); targets+=("$2"); secret_vars+=($3); user_vars+=("$4"); host_vars+=("$5") }
  local var tgt
  while (( $# )); do
    case $1 in
      -e|-t)
        (( $# >= 2 )) || { _apwz_err "$1 needs VAR=[user@]site"; return 2 }
        var=${2%%=*} tgt=${2#*=}
        if [[ $2 != *=* || $var != [A-Za-z_][A-Za-z0-9_]# || -z $tgt ]]; then
          _apwz_err "bad spec '$2' (expected VAR=[user@]site)"; return 2
        fi
        _apwz_pwrun_add ${${1/-e/pw}/-t/otp} $tgt $var "" ""; shift 2 ;;
      --pg|--mysql|--twine)
        (( $# >= 2 )) || { _apwz_err "$1 needs [user@]host"; return 2 }
        case $1 in
          --pg)    _apwz_pwrun_add pw "$2" PGPASSWORD PGUSER PGHOST ;;
          --mysql) _apwz_pwrun_add pw "$2" MYSQL_PWD "" MYSQL_HOST ;;
          --twine) _apwz_pwrun_add pw "$2" TWINE_PASSWORD TWINE_USERNAME "" ;;
        esac
        shift 2 ;;
      -h|--help) _apwz_usage pwrun; return 0 ;;
      --) shift; break ;;
      -*) _apwz_err "unknown option: $1"; return 2 ;;
      *) break ;;
    esac
  done
  if (( ! $#kinds || ! $# )); then _apwz_usage pwrun >&2; return 2; fi

  # Look everything up first (back-to-back, so one Touch ID approval usually covers all),
  # and run nothing if any lookup fails.
  local -a exports reply
  local i site user
  for i in {1..$#kinds}; do
    tgt=$targets[i]
    if [[ $tgt == *@* ]]; then user=${tgt%@*} site=${tgt##*@}   # last @: emails work
    else user= site=$tgt; fi
    _apwz_get $kinds[i] $site "$user" || return
    exports+=("$secret_vars[i]=$reply[1]")
    [[ -n $user_vars[i] ]] && exports+=("$user_vars[i]=$reply[2]")
    [[ -n $host_vars[i] ]] && exports+=("$host_vars[i]=$site")
  done
  (
    local e
    for e in "${exports[@]}"; do export "$e"; done
    unset exports reply
    if (( $+commands[$1] )); then exec "$@"; else "$@"; fi
  )
}

# ------------------------------------------------------------- developer integrations

# awsmfa [profile] — temporary AWS credentials using the MFA code from Apple Passwords.
awsmfa() {
  emulate -L zsh -o extended_glob
  local profile=${AWS_PROFILE:-default} duration=
  while (( $# )); do
    case $1 in
      -d|--duration) duration=$2; shift 2 ;;
      -c|--clear)
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_MFA_PROFILE AWS_MFA_EXPIRATION
        _apwz_msg "✓ cleared the AWS MFA session from this shell"; return 0 ;;
      -h|--help) _apwz_usage awsmfa; return 0 ;;
      -*) _apwz_err "unknown option: $1"; return 2 ;;
      *) profile=$1; shift ;;
    esac
  done
  (( $+commands[aws] )) || { _apwz_err "the AWS CLI is not installed: brew install awscli"; return 1 }

  # Long-term keys must make the STS call, so ignore any session already exported here.
  local -a aws_base=(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN aws)
  _apwz_awscfg() { $aws_base configure get $1 --profile $profile 2>/dev/null }
  local serial role src site user
  serial=$(_apwz_awscfg mfa_serial); role=$(_apwz_awscfg role_arn)
  src=$(_apwz_awscfg source_profile)
  site=$(_apwz_awscfg apple_pw_site); user=$(_apwz_awscfg apple_pw_user)
  if [[ -z $serial ]]; then
    _apwz_err "profile '$profile' has no mfa_serial. Set it once (IAM → Security credentials → MFA):
    aws configure set mfa_serial arn:aws:iam::<account-id>:mfa/<device-name> --profile $profile"
    return 2
  fi

  # The 2FA entry: apple_pw_user if configured, else the MFA device name, else pick.
  local -a reply
  if [[ -n $user ]]; then
    _apwz_get otp ${site:-aws} $user || return
  elif ! _apwz_get otp ${site:-aws} ${serial##*/} 2>/dev/null; then
    _apwz_get otp ${site:-aws} || return
  fi
  _apwz_fresh_otp ${site:-aws} "$reply[2]" || return
  local code=$reply[1] out
  if [[ -n $role ]]; then
    out=$($aws_base sts assume-role --profile ${src:-$profile} --role-arn $role \
      --role-session-name "apple-pw-${USER:-cli}" --serial-number $serial --token-code $code \
      ${duration:+--duration-seconds} $duration --output json 2>&1)
  else
    out=$($aws_base sts get-session-token --profile $profile --serial-number $serial \
      --token-code $code ${duration:+--duration-seconds} $duration --output json 2>&1)
  fi
  if (( $? )); then _apwz_err "AWS refused: ${out//$'\n'/ }"; return 1; fi
  local -a creds
  creds=("${(@f)$(print -r -- $out | jq -r '.Credentials | .AccessKeyId, .SecretAccessKey, .SessionToken, .Expiration')}")
  [[ $creds[1] == A* && -n $creds[3] ]] || { _apwz_err "unexpected answer from AWS STS"; return 1 }
  export AWS_ACCESS_KEY_ID=$creds[1] AWS_SECRET_ACCESS_KEY=$creds[2] AWS_SESSION_TOKEN=$creds[3]
  export AWS_MFA_PROFILE=$profile AWS_MFA_EXPIRATION=$creds[4]
  _apwz_msg "✓ AWS MFA session for '$profile'${role:+ as ${role##*/}} — expires $creds[4] (awsmfa -c to clear)"
}

# pwssh [ssh|scp|sftp|rsync|git] args… — ssh passwords and server 2FA prompts answered
# from Apple Passwords, matched by host from ssh's own prompt (see bin/apple-pw-askpass).
pwssh() {
  emulate -L zsh -o extended_glob
  local cmd=ssh
  [[ $1 == (ssh|scp|sftp|rsync|git) ]] && { cmd=$1; shift }
  [[ $1 == (-h|--help) || $# == 0 ]] && { _apwz_usage pwssh; [[ $# != 0 ]]; return }
  SSH_ASKPASS=$_APWZ_ROOT/bin/apple-pw-askpass SSH_ASKPASS_REQUIRE=force \
    DISPLAY=${DISPLAY:-apple-pw} command $cmd "$@"
}

# npmotp [npm|pnpm|yarn] args… — run with --otp from your npmjs.com 2FA entry.
npmotp() {
  emulate -L zsh -o extended_glob
  local tool=npm
  [[ $1 == (npm|pnpm|yarn) ]] && { tool=$1; shift }
  [[ $1 == (-h|--help) || $# == 0 ]] && { _apwz_usage npmotp; [[ $# != 0 ]]; return }
  local -a reply
  _apwz_get otp npm || return
  _apwz_fresh_otp npm "$reply[2]" || return
  command $tool "$@" --otp=$reply[1]
}

# make targets that read a 2FA code from stdin (e.g. `read -p "MFA Code: " mfa`). Opt-in:
#   typeset -A APPLE_PW_MAKE_OTP=('login-aws-*' aws)
# Then `make login-aws-prod` gets the code from Apple Passwords; other targets are untouched.
_apwz_make() {
  emulate -L zsh -o extended_glob
  local arg pat site=
  if [[ ${(t)APPLE_PW_MAKE_OTP} == association* ]]; then
    for arg in "$@"; do
      for pat in ${(k)APPLE_PW_MAKE_OTP}; do
        [[ $arg == ${~pat} ]] && { site=$APPLE_PW_MAKE_OTP[$pat]; break 2 }
      done
    done
  fi
  [[ -n $site ]] || { command make "$@"; return }
  local -a reply
  _apwz_get otp $site || return
  _apwz_fresh_otp $site "$reply[2]" || return
  _apwz_msg "🔑 2FA code for $reply[2]${reply[3]:+ ($reply[3])} passed to make"
  print -r -- $reply[1] | command make "$@"
}
[[ ${(t)APPLE_PW_MAKE_OTP} == association* ]] && make() { _apwz_make "$@" }

# pw-git enable|disable|list [host] — answer git's HTTPS credential requests for a host.
pw-git() {
  emulate -L zsh
  local key="credential.https://$2.helper"
  case $1 in
    enable)
      [[ -n $2 ]] || { _apwz_usage pw-git >&2; return 2 }
      git config --global --unset-all $key 2>/dev/null
      git config --global --add $key ""                 # reset: Apple Passwords is the only source
      git config --global --add $key apple-passwords
      _apwz_msg "✓ git will ask Apple Passwords for https://$2 (pw-git disable $2 to undo)" ;;
    disable)
      [[ -n $2 ]] || { _apwz_usage pw-git >&2; return 2 }
      git config --global --unset-all $key && _apwz_msg "✓ removed for https://$2" ;;
    list|"")
      git config --global --get-regexp '^credential\..*\.helper$' 2>/dev/null |
        awk '$2 == "apple-passwords" { sub(/^credential\./, "", $1); sub(/\.helper$/, "", $1); print $1 }' ;;
    *) _apwz_usage pw-git >&2; return 2 ;;
  esac
}

# pw-docker enable|disable|list [registry] — answer docker's credential requests.
pw-docker() {
  emulate -L zsh -o extended_glob
  local cfg=${DOCKER_CONFIG:-$HOME/.docker}/config.json reg=$2 json mode=600
  [[ $reg == (docker|hub|dockerhub|docker.io|index.docker.io) ]] && reg=https://index.docker.io/v1/
  if [[ -r $cfg ]]; then json=$(<$cfg); mode=$(stat -f %Lp $cfg); else json='{}'; fi
  case $1 in
    enable|disable)
      [[ -n $reg ]] || { _apwz_usage pw-docker >&2; return 2 }
      local filter='.credHelpers[$r] = "apple-passwords"'
      [[ $1 == disable ]] && filter='del(.credHelpers[$r])'
      mkdir -p ${cfg:h}
      local tmp=$(mktemp ${cfg:h}/.config.json.XXXXXX)
      print -r -- $json | jq --arg r $reg $filter >| $tmp && chmod $mode $tmp && mv $tmp $cfg \
        || { rm -f $tmp; _apwz_err "could not update $cfg"; return 1 }
      _apwz_msg "✓ docker ${${1/enable/will use}/disable/no longer uses} Apple Passwords for $reg" ;;
    list|"")
      print -r -- $json | jq -r '.credHelpers // {} | to_entries[] | select(.value == "apple-passwords") | .key' ;;
    *) _apwz_usage pw-docker >&2; return 2 ;;
  esac
}

pw-pair()   { emulate -L zsh; _apwz_backend || return; _apwz_pair $REPLY }

pw-lock() {
  emulate -L zsh
  _apwz_backend || return
  _apwz_lock $REPLY && _apwz_msg "🔒 locked — the next lookup will ask for a new PIN"
}

pw-status() {
  emulate -L zsh
  _apwz_backend || return
  local be=$REPLY
  if [[ $be == apwcli ]]; then
    apwcli doctor
  else
    print -r -- "● backend      apw $(apw --version 2>/dev/null)"
    if _apwz_apw_up; then
      print -r -- "● daemon       running"
      apw pw list example.invalid </dev/null >/dev/null 2>&1
      if (( $? == 9 )); then print -r -- "● pairing      not paired — run pw-pair"
      else print -r -- "● pairing      paired"; fi
    else
      print -r -- "● daemon       stopped — brew services start apw"
    fi
  fi
  local lock=never clear=never
  (( APPLE_PW_AUTOLOCK > 0 )) && lock="after $(( APPLE_PW_AUTOLOCK / 60 )) min idle"
  (( APPLE_PW_CLEAR_AFTER > 0 )) && clear="after ${APPLE_PW_CLEAR_AFTER}s"
  print -r -- "  plugin: backend=$be ($APPLE_PW_BACKEND), auto-lock $lock, clipboard clear $clear"
  if [[ -e $_APWZ_CONF ]]; then print -r -- "  config: $_APWZ_CONF"
  else print -r -- "  config: none yet — run pw-setup"; fi
}

# ------------------------------------------------------------------------- setup wizard

# _apwz_choose QUESTION OPTION... → $REPLY = chosen number (default: the "(recommended)" one)
_apwz_choose() {
  local question=$1; shift
  local -a opts; opts=("$@")
  local def=${opts[(i)*\(recommended\)*]} i ans
  (( def <= $#opts )) || def=1
  print -ru2 -- $'\n'"$question"
  for i in {1..$#opts}; do print -ru2 -- "  $i) $opts[i]"; done
  while true; do
    read -r "ans?choice [$def]: " || ans=$def
    ans=${ans:-$def}
    [[ $ans == <-> ]] && (( ans >= 1 && ans <= $#opts )) && break
    print -ru2 -- "  please enter 1-$#opts"
  done
  REPLY=$ans
}

_apwz_setup_body() {
  local al ca be kb ans
  print -ru2 -- "apple-passwords setup — saved to $_APWZ_CONF (rerun pw-setup anytime)"

  _apwz_choose "Auto-lock: stop the password bridge after how long without lookups?
(While running and paired, its browser exposes a DevTools port on 127.0.0.1 that other
local processes and accounts could use. Locking closes it; the next lookup asks for a PIN.)" \
    "5 minutes" "15 minutes (recommended)" "60 minutes" "never"
  al=${${:-300 900 3600 0}[(w)REPLY]}
  if (( al == 0 )); then
    read -r "ans?Keep the bridge running until reboot or pw-lock? [y/N] " || ans=n
    [[ $ans == [yY]* ]] || { al=900; print -ru2 -- "  → keeping 15 minutes"; }
  fi

  _apwz_choose "Clear the clipboard after copying a secret:" \
    "10 seconds" "20 seconds (recommended)" "45 seconds" "never"
  ca=${${:-10 20 45 0}[(w)REPLY]}

  _apwz_choose "Backend:" "auto — apwcli, else apw (recommended)" "apwcli" "apw"
  be=${${:-auto apwcli apw}[(w)REPLY]}

  _apwz_choose "Keybindings Ctrl-X p (password) / Ctrl-X o (2FA code):" "on (recommended)" "off"
  kb=${${:-1 0}[(w)REPLY]}

  (umask 077; mkdir -p ${_APWZ_CONF:h}; print -r -- "\
# apple-passwords — written by pw-setup on $(strftime '%Y-%m-%d %H:%M' $EPOCHSECONDS).
# Variables already set in the environment take precedence over these.
: \${APPLE_PW_AUTOLOCK:=$al}      # seconds without lookups before the bridge stops; 0 = never
: \${APPLE_PW_CLEAR_AFTER:=$ca}   # seconds before the clipboard is cleared; 0 = never
: \${APPLE_PW_BACKEND:=$be}       # auto | apwcli | apw
: \${APPLE_PW_BIND_KEYS:=$kb}     # Ctrl-X p / Ctrl-X o keybindings
: \${APPLE_PW_CACHE:=1}          # remember site + username (never secrets) for completion" >| $_APWZ_CONF)

  # Apply to this shell too, except settings the user pinned in the environment.
  local name value
  for name value in APPLE_PW_AUTOLOCK $al APPLE_PW_CLEAR_AFTER $ca \
                    APPLE_PW_BACKEND $be APPLE_PW_BIND_KEYS $kb; do
    (( ${_APWZ_PRESET[(Ie)$name]} )) || typeset -g $name=$value
  done
  (( $#_APWZ_PRESET )) && print -ru2 -- "  note: ${(j:, :)_APWZ_PRESET} set in your environment still take precedence"
  [[ $APPLE_PW_BIND_KEYS == 1 ]] && [[ -o zle ]] && _apwz_bind
  print -ru2 -- $'\n'"✓ saved. Keybinding changes apply to new shells."
}

pw-setup() {
  emulate -L zsh -o extended_glob
  _apwz_has_tty || { _apwz_err "pw-setup needs a terminal"; return 1 }
  _apwz_setup_body <$_APWZ_TTY
}

# First lookup without a config file → run the wizard (terminal only; otherwise defaults).
_apwz_firstrun() {
  [[ -e $_APWZ_CONF || -n $_APWZ_SETUP_OFFERED || $APPLE_PW_NO_SETUP == 1 ]] && return 0
  typeset -g _APWZ_SETUP_OFFERED=1
  _apwz_has_tty || return 0
  _apwz_msg "First run of apple-passwords — a few quick questions."
  _apwz_setup_body <$_APWZ_TTY
}

# --------------------------------------------------------------------------- keybindings

# Ctrl-X p / Ctrl-X o: park the current line, start " pw " / " otp " (leading space keeps it
# out of history with hist_ignore_space) so the site gets tab completion; the parked line
# comes back after it runs.
_apwz_widget_pw()  { zle push-line; BUFFER=" pw "; CURSOR=$#BUFFER }
_apwz_widget_otp() { zle push-line; BUFFER=" otp "; CURSOR=$#BUFFER }

_apwz_bind() {
  local km key widget
  for km in emacs viins; do
    for key widget in '^Xp' apple-pw-password '^Xo' apple-pw-otp; do
      [[ $(bindkey -M $km $key 2>/dev/null) == *undefined-key ]] && bindkey -M $km $key $widget
    done
  done
}

if [[ -o interactive ]] && zmodload zsh/zle 2>/dev/null; then
  zle -N apple-pw-password _apwz_widget_pw
  zle -N apple-pw-otp _apwz_widget_otp
  [[ $APPLE_PW_BIND_KEYS == 1 ]] && _apwz_bind
fi
