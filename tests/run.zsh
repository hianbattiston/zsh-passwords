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
t 'picker flow: lists names first, then reads only the chosen password' '
  paired; print 2 > answers; _APWZ_TTY=$PWD/answers; eq "$(pw google.com 2>/dev/null)" g2
  eq "$(<$STUB_STATE/calls)" "list google.com
pw get google.com b@gmail.com -o json"'
t 'picker flow (apw): pw list, then one pw get' '
  APPLE_PW_BACKEND=apw; paired; print 1 > answers; _APWZ_TTY=$PWD/answers
  eq "$(pw google.com 2>/dev/null)" g1
  eq "$(<$STUB_STATE/calls)" "list google.com
pw get google.com a@gmail.com"'
t 'username given: no listing, single read' '
  paired; pw google.com a@gmail.com >/dev/null; eq "$(<$STUB_STATE/calls)" "pw get google.com a@gmail.com -o json"'
t 'narrowing: aws.amazon.com hides plain amazon.com logins' '
  paired; _apwz_query apwcli list aws.amazon.com ""
  eq "$(print -r -- $REPLY | jq -r "[.[].username] | join(\",\")")" "root@example.com,iam-user"'
t 'alias: aws → aws.amazon.com' '_apwz_resolve_site aws; eq $REPLY aws.amazon.com'
t 'alias: user aliases win' '
  typeset -A APPLE_PW_ALIASES=(work corp.example aws my.aws.example); _apwz_resolve_site work; eq $REPLY corp.example
  _apwz_resolve_site aws; eq $REPLY my.aws.example'
t 'guessed .com miss suggests full domain / alias' '
  paired; pw zzz >/dev/null 2>err; eq $? 3; grep -q "guessed as zzz.com" err'
t 'pwlogin: password + 2FA fetched back-to-back, before the key press' '
  paired; print x > answers; _APWZ_TTY=$PWD/answers; pwlogin github.com 2>/dev/null
  # (a 4th otp call may legitimately follow if the code rolled over during the test)
  eq "$(head -3 $STUB_STATE/calls)" "list github.com
pw get github.com me@example.com -o json
otp get github.com me@example.com -o json"
  eq "$(<$STUB_STATE/clipboard)" 111222'
t 'pwlogin: q skips the 2FA copy' '
  paired; print q > answers; _APWZ_TTY=$PWD/answers; pwlogin github.com 2>/dev/null
  eq "$(<$STUB_STATE/clipboard)" gh-secret'
t 'pwlogin: site without 2FA just copies the password' '
  paired; print x > answers; _APWZ_TTY=$PWD/answers; pwlogin corp.example 2>/dev/null; eq $? 0
  eq "$(<$STUB_STATE/clipboard)" c0rp'
t 'Touch ID not approved in time → clear message' '
  paired; touch $STUB_STATE/timeout; pw github.com me@example.com >/dev/null 2>err; eq $? 100
  grep -q "approve the Touch ID prompt" err'
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

# ---------------------------------------------------------------- developer integrations
t 'aliases: npm → npmjs.com, docker → docker.com' '
  _apwz_resolve_site npm; eq $REPLY npmjs.com; _apwz_resolve_site docker; eq $REPLY docker.com'

t 'askpass: "user@host'"'"'s password:"' '
  paired; eq "$($ROOT/bin/apple-pw-askpass "deploy@srv.example.com'"'"'s password: ")" ssh-pw'
t 'askpass: "(user@host) Password:"' '
  paired; eq "$($ROOT/bin/apple-pw-askpass "(deploy@srv.example.com) Password: ")" ssh-pw'
t 'askpass: "(user@host) Verification code:" → 2FA' '
  paired; eq "$($ROOT/bin/apple-pw-askpass "(deploy@srv.example.com) Verification code: ")" 135790'
t 'askpass: host-key question goes to the human' '
  paired; print yes > answers; export _APWZ_TTY=$PWD/answers
  eq "$($ROOT/bin/apple-pw-askpass "Are you sure you want to continue connecting (yes/no/[fingerprint])? ")" yes
  [[ ! -e $STUB_STATE/calls ]]'
t 'askpass: no terminal and nothing found → fails' '
  paired; $ROOT/bin/apple-pw-askpass "Enter passphrase for key x: " >/dev/null 2>&1; (( $? != 0 ))'

t 'git helper: get → username/password for the host' '
  paired; out=$(printf "protocol=https\nhost=srv.example.com\n\n" | $ROOT/bin/git-credential-apple-passwords get)
  eq "$out" "username=deploy
password=ssh-pw"'
t 'git helper: unknown host → no output, git falls back' '
  paired; out=$(printf "protocol=https\nhost=nothing.example\n\n" | $ROOT/bin/git-credential-apple-passwords get 2>/dev/null)
  eq $? 0; eq "$out" ""'
t 'git helper: store/erase ignored' '
  printf "protocol=https\nhost=x\nusername=u\npassword=p\n\n" | $ROOT/bin/git-credential-apple-passwords store; eq $? 0
  [[ ! -e $STUB_STATE/calls ]]'
t 'pw-git: enable/list/disable per host' '
  pw-git enable srv.example.com 2>/dev/null
  eq "$(git config --global --get-all credential.https://srv.example.com.helper)" "
apple-passwords"
  eq "$(pw-git list)" "https://srv.example.com"
  pw-git disable srv.example.com 2>/dev/null; eq "$(pw-git list)" ""'

t 'docker helper: get → JSON for the registry' '
  paired; out=$(print -n srv.example.com | $ROOT/bin/docker-credential-apple-passwords get)
  eq "$(print -r -- $out | jq -r ".Username + \":\" + .Secret + \":\" + .ServerURL")" "deploy:ssh-pw:srv.example.com"'
t 'docker helper: Docker Hub URL → docker.com entry' '
  paired; out=$(print -n https://index.docker.io/v1/ | $ROOT/bin/docker-credential-apple-passwords get)
  eq "$(print -r -- $out | jq -r .Username)" dockeruser'
t 'docker helper: not found → protocol message, exit 1' '
  paired; out=$(print -n nothing.example | $ROOT/bin/docker-credential-apple-passwords get 2>/dev/null)
  eq $? 1; eq "$out" "credentials not found in native keychain"'
t 'pw-docker: enable keeps other settings and file mode; disable removes' '
  mkdir -p $HOME/.docker; print "{\"auths\":{\"x\":{}},\"credsStore\":\"desktop\"}" > $HOME/.docker/config.json
  chmod 600 $HOME/.docker/config.json
  pw-docker enable ghcr.io 2>/dev/null; pw-docker enable docker 2>/dev/null
  c=$HOME/.docker/config.json
  eq "$(jq -c "[.credsStore, (.auths|keys), .credHelpers]" $c)" "[\"desktop\",[\"x\"],{\"ghcr.io\":\"apple-passwords\",\"https://index.docker.io/v1/\":\"apple-passwords\"}]"
  eq $(stat -f %Lp $c) 600
  pw-docker disable ghcr.io 2>/dev/null; eq "$(pw-docker list)" "https://index.docker.io/v1/"'

t 'awsmfa: session token with the MFA device'"'"'s 2FA entry' '
  paired; print arn:aws:iam::123:mfa/hian > $STUB_STATE/aws-dev-mfa_serial
  awsmfa dev 2>/dev/null; eq $AWS_ACCESS_KEY_ID ASIATEST; eq $AWS_SESSION_TOKEN tok; eq $AWS_MFA_PROFILE dev
  grep -q "sts get-session-token --profile dev --serial-number arn:aws:iam::123:mfa/hian --token-code 777888" $STUB_STATE/aws-calls'
t 'awsmfa: assume-role via source_profile' '
  paired; print arn:aws:iam::123:mfa/hian > $STUB_STATE/aws-prod-mfa_serial
  print arn:aws:iam::456:role/Admin > $STUB_STATE/aws-prod-role_arn; print dev > $STUB_STATE/aws-prod-source_profile
  awsmfa prod 2>/dev/null; eq $AWS_SESSION_TOKEN tok
  grep -q "sts assume-role --profile dev --role-arn arn:aws:iam::456:role/Admin" $STUB_STATE/aws-calls'
t 'awsmfa: ignores a session already exported in the shell' '
  paired; print arn:aws:iam::123:mfa/hian > $STUB_STATE/aws-dev-mfa_serial
  export AWS_SESSION_TOKEN=old AWS_ACCESS_KEY_ID=ASIAOLD; awsmfa dev 2>/dev/null; eq $AWS_ACCESS_KEY_ID ASIATEST'
t 'awsmfa: no mfa_serial → explains how to set it' '
  paired; awsmfa nomfa 2>err; eq $? 2; grep -q "aws configure set mfa_serial" err'
t 'awsmfa -c clears the session' '
  export AWS_SESSION_TOKEN=x AWS_ACCESS_KEY_ID=y; awsmfa -c 2>/dev/null; [[ -z ${AWS_SESSION_TOKEN-} && -z ${AWS_ACCESS_KEY_ID-} ]]'

t 'npmotp: --otp from npmjs.com' 'paired; eq "$(npmotp publish --access public)" "npm publish --access public --otp=424242"'
t 'pwrun --pg sets PGHOST/PGUSER/PGPASSWORD' '
  paired; eq "$(pwrun --pg deploy@srv.example.com -- zsh -fc "print \$PGHOST \$PGUSER \$PGPASSWORD")" "srv.example.com deploy ssh-pw"'
t 'pwrun --twine sets TWINE_USERNAME/TWINE_PASSWORD' '
  paired; eq "$(pwrun --twine srv.example.com -- zsh -fc "print \$TWINE_USERNAME \$TWINE_PASSWORD")" "deploy ssh-pw"'

t 'make hook: mapped target gets the 2FA code on stdin' '
  paired; typeset -A APPLE_PW_MAKE_OTP=("publish-*" npm)
  eq "$(_apwz_make publish-prod 2>/dev/null)" "make publish-prod got 424242"'
t 'make hook: other targets run untouched (no lookup)' '
  paired; typeset -A APPLE_PW_MAKE_OTP=("publish-*" npm)
  eq "$(_apwz_make test </dev/null)" "make test got "; [[ ! -e $STUB_STATE/calls ]]'
t 'make hook: not configured → make() not defined' '(( ! $+functions[make] ))'
t 'pw-make add: saved (0600), live at once, survives a new shell' '
  paired; pw-make add "publish-*" npm 2>/dev/null
  (( $+functions[make] )); eq "$(make publish-x 2>/dev/null)" "make publish-x got 424242"
  f=$XDG_CONFIG_HOME/apple-passwords/make-hooks; eq $(stat -f %Lp $f) 600
  eq "$(zsh -fc "source $ROOT/apple-passwords.plugin.zsh; print \${(kv)APPLE_PW_MAKE_OTP}; whence -w make")" "publish-* npm
make: function"'
t 'pw-make remove: gone from file and shell' '
  pw-make add "a-*" aws 2>/dev/null; pw-make remove "a-*" 2>/dev/null
  (( ! $+functions[make] )); eq "$(pw-make list)" ""'
t 'pw-make: zsh-config hooks merge with saved ones and win' '
  pw-make add "x-*" npm 2>/dev/null
  eq "$(zsh -fc "typeset -A APPLE_PW_MAKE_OTP=(x-\\* aws y-\\* gcp); source $ROOT/apple-passwords.plugin.zsh; print \${APPLE_PW_MAKE_OTP[x-*]} \${APPLE_PW_MAKE_OTP[y-*]}")" "aws gcp"'
t 'pw-make: does not replace a user'"'"'s own make function' '
  make() { print mine }; pw-make add "z-*" npm 2>/dev/null; eq "$(make z-1)" mine'
t 'pw-make detect: groups targets that read a code, guesses aws' '
  printf "MFA ?= \$(shell read -r -p x pwd)\n\nlogin-aws-prod:\n\t@read -p \"MFA Code: \" mfa; \\\\\n\tpython login_aws.py -m \$\$mfa\n\nlogin-aws-dev:\n\t@read -p \"MFA Code: \" mfa; \\\\\n\tpython login_aws.py -m \$\$mfa\n\ntest:\n\tpytest\n" > Makefile
  out=$(pw-make detect 2>&1); print -r -- $out | grep -q "login-aws-dev, login-aws-prod"
  print -r -- $out | grep -q "pw-make add .login-aws-\*. aws"; ! print -r -- $out | grep -q test'
t 'pw-make detect: with a terminal, Enter accepts the suggestion' '
  printf "login-aws-prod:\n\t@read -p \"MFA Code: \" mfa\nlogin-aws-dev:\n\t@read -p \"MFA Code: \" mfa\n" > Makefile
  print "" > answers; _APWZ_TTY=$PWD/answers; pw-make detect >/dev/null 2>&1
  eq "$(pw-make list)" "login-aws-*              → aws"'

print
print "$pass passed, $fail failed"
(( fail == 0 ))
