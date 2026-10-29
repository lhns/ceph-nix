#!/bin/sh
# Runs inside the image under test. Prints what qemu-user must execute for a command: the ELF itself, or the
# interpreter followed by the script. Follows symlinks and nixpkgs' wrapper convention (bin/.NAME-wrapped).
# qemu-user emulates execve with the host's exec, so only the first process of a chain is CPU-restricted;
# resolving wrappers to the real program is what makes the test cover it.
p=$(readlink -f "$1")
d=${p%/*}
b=${p##*/}
[ -e "$d/.$b-wrapped" ] && p=$d/.$b-wrapped
if [ "$(head -c2 "$p")" = '#!' ]; then
	# shellcheck disable=SC2046
	set -- $(head -n1 "$p" | cut -c3-)
	interp=$1
	shift
	if [ "${interp##*/}" = env ]; then
		interp=$(command -v "$1")
		shift
	fi
	echo "$(readlink -f "$interp") $* $p"
else
	echo "$p"
fi
