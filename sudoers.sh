#!/bin/bash
# Run once with sudo: sudo ./sudoers.sh
# Allows passwordless sudo for three exact commands, nothing else.
set -euo pipefail

tmp=$(mktemp)
cat > "$tmp" <<'EOF'
# lid-awake: thermal guard + toggle, these three commands only
Cmnd_Alias LID_AWAKE = /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset sleepnow
%admin ALL=(ALL) NOPASSWD: LID_AWAKE
EOF

/usr/sbin/visudo -cf "$tmp"
/usr/sbin/chown root:wheel "$tmp"
/bin/chmod 440 "$tmp"
/bin/mv -f "$tmp" /etc/sudoers.d/lidawake

echo "installed /etc/sudoers.d/lidawake"
