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

# _apwz_query BACKEND KIND SITE [USER] → $REPLY = JSON array of matches. 3 = none.
_apwz_query() {
  local be=$1 kind=$2 site=$3 user=$4 out rc attempt
  for attempt in 1 2; do
    case $be/$kind in
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
    _apwz_err "${msg:-$be failed (exit $rc)}"
    return rc
  fi
  REPLY=$(print -r -- $json | jq -c --arg u "$user" '[.results[]? | select($u == "" or .username == $u)]') \
    || { _apwz_err "unexpected output from $be"; return 100 }
  [[ $REPLY != '[]' ]] || return 3
}

# A site without a dot is shorthand: `github` → a cached `github.*` domain, else github.com.
_apwz_resolve_site() {
  REPLY=$1
  [[ $REPLY == *.* || $REPLY == *:* || $REPLY == localhost ]] && return
  local f=$_APWZ_CACHE_DIR/accounts
  local -a lines matches
  [[ -r $f ]] && lines=("${(@f)$(<$f)}")
  matches=(${(M)${lines%%$'\t'*}:#$1.*})
  REPLY=${matches[1]:-$1.com}
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
  print -r -- $stamp >| $f
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
  local kind=$1 site user=$3 be json rc
  _apwz_firstrun
  _apwz_backend || return 1; be=$REPLY
  _apwz_resolve_site $2; site=$REPLY
  _apwz_ready $be || return 9
  _apwz_query $be $kind $site "$user"; rc=$?
  if (( rc == 3 )); then
    _apwz_err "no ${${kind/pw/password}/otp/2FA code} saved for $site${user:+ ($user)}"
    return 3
  fi
  (( rc == 0 )) || return rc
  json=$REPLY
  _apwz_pick "$json" || return
  reply=("${(@f)$(print -r -- $json |
    jq -r --argjson i $REPLY '.[$i] | (.password // .code // ""), .username, .domain')}")
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
    pwrun) print -r -- "usage: pwrun [-e VAR=[user@]site]... [-t VAR=[user@]site]... [--] command [args...]

Run a command with secrets in its environment only (never in history, argv or files).
  -e  password       -t  current 2FA code
Example: pwrun -e PGPASSWORD=admin@db.example.com -- psql -h db.example.com -U admin" ;;
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
  local -a reply
  _apwz_get pw $1 "$2" || return
  local user=$reply[2]
  _apwz_deliver copy pw || return
  _apwz_has_tty || return 0
  local key
  read -u0 -sk1 "key?Paste it, then press any key for the 2FA code (q to skip)… " <$_APWZ_TTY
  print -u2
  [[ $key == [qQ] ]] && return 0
  if ! _apwz_get otp $1 "$user" 2>/dev/null; then
    _apwz_get otp $1 || return       # 2FA saved under another name: the site's only code / picker
  fi
  _apwz_fresh_otp $1 "$reply[2]" || return
  _apwz_deliver copy otp
}

pwrun() {
  emulate -L zsh -o extended_glob
  local -a kinds specs
  while (( $# )); do
    case $1 in
      -e|-t)
        (( $# >= 2 )) || { _apwz_err "$1 needs VAR=[user@]site"; return 2 }
        kinds+=(${${1/-e/pw}/-t/otp}); specs+=("$2"); shift 2 ;;
      -h|--help) _apwz_usage pwrun; return 0 ;;
      --) shift; break ;;
      -*) _apwz_err "unknown option: $1"; return 2 ;;
      *) break ;;
    esac
  done
  if (( ! $#kinds || ! $# )); then _apwz_usage pwrun >&2; return 2; fi

  local -a vars secrets reply
  local i spec var target site user
  for i in {1..$#kinds}; do
    spec=$specs[i]; var=${spec%%=*}; target=${spec#*=}
    if [[ $spec != *=* || $var != [A-Za-z_][A-Za-z0-9_]# || -z $target ]]; then
      _apwz_err "bad spec '$spec' (expected VAR=[user@]site)"; return 2
    fi
    if [[ $target == *@* ]]; then user=${target%@*}; site=${target##*@}   # last @: emails work
    else user=; site=$target; fi
    _apwz_get $kinds[i] $site "$user" || return
    vars+=($var); secrets+=("$reply[1]")
  done
  (
    for i in {1..$#vars}; do export "$vars[i]=$secrets[i]"; done
    unset secrets reply
    if (( $+commands[$1] )); then exec "$@"; else "$@"; fi
  )
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
