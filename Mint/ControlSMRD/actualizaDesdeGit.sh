

WORKDIR=$(mktemp -d /tmp/git.XXXXXX) && chmod 755 "$WORKDIR"

git clone https://github.com/victormuelacarriles/IAC-IESMHP.git "$WORKDIR/IAC-IESMHP" || exit 1

