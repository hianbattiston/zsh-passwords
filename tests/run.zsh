#!/usr/bin/env zsh
# Offline tests: fake backends (tests/stubs) and fake data (tests/data.json); never touches
# real Apple Passwords, the real clipboard, or your config/cache.
# Usage: zsh tests/run.zsh

emulate -L zsh
ROOT=${0:A:h:h}
STUBS=$ROOT/tests/stubs
chmod +x $STUBS/*
JQ=${commands[jq]}
integer pass=0 fail=0

PRELUDE='
eq() { [[ $1 == $2 ]] || { print -r -- "expected [$2], got [$1]"; exit 1 } }
paired() { touch $STUB_STATE/paired }
'

# t NAME CODE — run CODE in a clean `zsh -f` with the plugin sourced and no terminal.
t() {
  local name=$1 code=$2 out tmp
  tmp=$(mktemp -d)
  mkdir -p $tmp/state $tmp/home $tmp/bin
  ln -s $JQ $tmp/bin/jq   # only jq — never the real backends in /opt/homebrew/bin
  out=$(cd $tmp && env -i HOME=$tmp/home PATH=$STUBS:$tmp/bin:/usr/bin:/bin ROOT=$ROOT \
    APPLE_PW_NO_SETUP=1 \
    XDG_CACHE_HOME=$tmp/cache XDG_CONFIG_HOME=$tmp/config \
    STUB_STATE=$tmp/state STUB_DATA=$ROOT/tests/data.json \
    APPLE_PW_AUTOLOCK=0 APPLE_PW_CLEAR_AFTER=0 _APWZ_TTY=/nonexistent/tty \
    zsh -f -c "source $ROOT/apple-passwords.plugin.zsh; $PRELUDE
$code" 2>&1)
  if (( $? == 0 )); then
    (( pass++ )); print -r -- "ok    $name"
  else
    (( fail++ )); print -r -- "FAIL  $name"; print -r -- "${out//(#m)*/${(F)${(@f)MATCH/#/      }}}"
  fi
  rm -rf $tmp
}

t 'syntax: plugin' 'zsh -n $ROOT/apple-passwords.plugin.zsh'
t 'syntax: completion' 'zsh -n $ROOT/_apple-passwords'

t 'backend: auto prefers apwcli' '_apwz_backend; eq $REPLY apwcli'
t 'backend: APPLE_PW_BACKEND=apw' 'APPLE_PW_BACKEND=apw; _apwz_backend; eq $REPLY apw'
t 'backend: none installed → error' '
  path=(${path:#*stubs}); _apwz_backend 2>err; eq $? 1; grep -q "brew install" err'

t 'pw: piped → prints password' 'paired; eq "$(pw github.com)" gh-secret'
t 'pw: unpaired → pairs first, output stays clean' '
  eq "$(pw github.com)" gh-secret; grep -qx pair $STUB_STATE/log'
t 'pw: username narrows the match' 'paired; eq "$(pw google.com b@gmail.com)" g2'
t 'pw: several matches, no terminal → exit 2 listing accounts' '
  paired; pw google.com >/dev/null 2>err; eq $? 2; grep -q "a@gmail.com" err'
t 'pw: several matches, picker (select) chooses 2nd' '
  paired; print 2 > answers; _APWZ_TTY=$PWD/answers; eq "$(pw google.com 2>/dev/null)" g2'
t 'pw: nothing saved → exit 3' '
  paired; pw nothing.example 2>err; eq $? 3; grep -q "no password saved" err'
t 'pw: bad usage → exit 2' 'pw 2>/dev/null; eq $? 2; pw --bogus x 2>/dev/null; eq $? 2'
t 'query: ignores status lines before the JSON' '
  _apwz_query apwcli pw github.com ""; eq "$(print -r -- $REPLY | jq -r ".[0].password")" gh-secret'

t 'otp: prints current code' 'paired; eq "$(otp github.com)" 111222'
t 'apw: unpaired → exit 9 → auth → retry' '
  APPLE_PW_BACKEND=apw; _APWZ_TTY=/dev/null; _apwz_apw_up() { return 0 }
  eq "$(pw github.com 2>/dev/null)" gh-secret; grep -qx auth $STUB_STATE/log'
t 'apw: daemon down → hint, no auth attempt' '
  APPLE_PW_BACKEND=apw; _APWZ_TTY=/dev/null; _apwz_apw_up() { return 1 }
  pw github.com >/dev/null 2>err; eq $? 9; grep -q "brew services start apw" err
  [[ ! -e $STUB_STATE/log ]]'
t 'apw: otp filtered by username in jq' '
  APPLE_PW_BACKEND=apw; paired; eq "$(otp google.com b@gmail.com)" 654321'
t 'apw: no results (exit 3) → exit 3' '
  APPLE_PW_BACKEND=apw; paired; pw nothing.example 2>/dev/null; eq $? 3'

t 'copy: secret via stdin, no newline, nothing printed' '
  paired; out=$(pw -c github.com 2>/dev/null); eq "$out" ""
  eq "$(<$STUB_STATE/clipboard)" gh-secret; eq $(wc -c < $STUB_STATE/clipboard | tr -d " ") 9'
t 'copy: delayed clear scheduled without the secret in argv' '
  paired; APPLE_PW_CLEAR_AFTER=5; pw -c github.com 2>/dev/null; sleep 0.5
  grep -q "delay(5)" $STUB_STATE/clearjobs; ! grep -q gh-secret $STUB_STATE/clearjobs'
t 'copy: clear disabled with APPLE_PW_CLEAR_AFTER=0' '
  paired; pw -c github.com 2>/dev/null; sleep 0.3; [[ ! -e $STUB_STATE/clearjobs ]]'

t 'shorthand: github → github.com' 'paired; eq "$(pw github)" gh-secret'
t 'shorthand: cached domain wins over .com' '
  mkdir -p $XDG_CACHE_HOME/apple-passwords
  print "corp.example\tadmin" > $XDG_CACHE_HOME/apple-passwords/accounts
  _apwz_resolve_site corp; eq $REPLY corp.example'

t 'cache: site+user recorded once, mode 600, no secrets' '
  paired; pw github.com >/dev/null; pw github.com >/dev/null
  f=$XDG_CACHE_HOME/apple-passwords/accounts
  eq "$(<$f)" "github.com	me@example.com"; eq $(stat -f %Lp $f) 600; ! grep -q gh-secret $f'
t 'cache: APPLE_PW_CACHE=0 disables it' '
  paired; APPLE_PW_CACHE=0; pw github.com >/dev/null; [[ ! -e $XDG_CACHE_HOME/apple-passwords/accounts ]]'

t 'pwrun: secret only in the child env; email user split on last @' '
  paired; out=$(pwrun -e T=me@example.com@github.com -- zsh -fc "print -r -- \$T")
  eq "$out" gh-secret; [[ -z ${T-} ]]'
t 'pwrun: -e and -t together' '
  paired; eq "$(pwrun -e P=github.com -t C=github.com -- zsh -fc "print -r -- \$P:\$C")" gh-secret:111222'
t 'pwrun: failed lookup aborts before running anything' '
  paired; pwrun -e A=github.com -e B=nothing.example -- touch $STUB_STATE/ran 2>/dev/null
  eq $? 3; [[ ! -e $STUB_STATE/ran ]]'
t 'pwrun: bad spec rejected' 'pwrun -e 1BAD=github.com -- true 2>/dev/null; eq $? 2'

t 'auto-lock: stops the daemon after idle' '
  paired; APPLE_PW_AUTOLOCK=1; pw github.com >/dev/null; sleep 2.5; grep -qx stop $STUB_STATE/log'
t 'auto-lock: a newer lookup postpones it' '
  paired; APPLE_PW_AUTOLOCK=2; pw github.com >/dev/null; sleep 1.2; pw github.com >/dev/null
  sleep 1.2; [[ ! -e $STUB_STATE/log ]]; sleep 1.5; grep -qx stop $STUB_STATE/log'

t 'setup: writes 0600 config that defers to the environment' '
  printf "1\n3\n2\n2\n" > answers; _APWZ_TTY=$PWD/answers; pw-setup 2>/dev/null
  c=$XDG_CONFIG_HOME/apple-passwords/config.zsh
  eq $(stat -f %Lp $c) 600
  eq "$(env -u APPLE_PW_AUTOLOCK -u APPLE_PW_CLEAR_AFTER zsh -fc "source $c; print \$APPLE_PW_AUTOLOCK \$APPLE_PW_CLEAR_AFTER \$APPLE_PW_BACKEND \$APPLE_PW_BIND_KEYS")" "300 45 apwcli 0"
  eq "$(APPLE_PW_AUTOLOCK=7 zsh -fc "source $c; print \$APPLE_PW_AUTOLOCK")" 7'
t 'setup: "never" auto-lock needs confirmation (n → 15 min)' '
  printf "4\nn\n\n\n\n" > answers; _APWZ_TTY=$PWD/answers; pw-setup 2>/dev/null
  eq "$(env -u APPLE_PW_AUTOLOCK zsh -fc "source $XDG_CONFIG_HOME/apple-passwords/config.zsh; print \$APPLE_PW_AUTOLOCK")" 900'
t 'setup: "never" confirmed → 0' '
  printf "4\ny\n\n\n\n" > answers; _APWZ_TTY=$PWD/answers; pw-setup 2>/dev/null
  eq "$(env -u APPLE_PW_AUTOLOCK zsh -fc "source $XDG_CONFIG_HOME/apple-passwords/config.zsh; print \$APPLE_PW_AUTOLOCK")" 0'
t 'first run: no terminal → defaults, no config written' '
  unset APPLE_PW_NO_SETUP; paired; pw github.com >/dev/null; [[ ! -e $XDG_CONFIG_HOME/apple-passwords/config.zsh ]]'
t 'setup: env-pinned settings are not overridden in this shell' '
  printf "1\n\n\n\n" > answers; _APWZ_TTY=$PWD/answers; pw-setup 2>/dev/null; eq $APPLE_PW_AUTOLOCK 0'
t 'first run: terminal → wizard runs once before the lookup' '
  unset APPLE_PW_NO_SETUP; paired; printf "\n\n\n\n" > answers; _APWZ_TTY=$PWD/answers
  eq "$(pw github.com 2>/dev/null)" gh-secret; [[ -e $XDG_CONFIG_HOME/apple-passwords/config.zsh ]]'

print
print "$pass passed, $fail failed"
(( fail == 0 ))
