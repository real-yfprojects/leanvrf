#!/usr/bin/env bash
# Let bubblewrap -- and only bubblewrap -- create user namespaces on Ubuntu 24.04.
#
# Usage: allow-bwrap-userns.sh            (needs passwordless sudo, as on GitHub runners)
#
# Ubuntu confines unprivileged user namespaces with AppArmor
# (kernel.apparmor_restrict_unprivileged_userns=1): a process may only create one
# if its AppArmor profile grants `userns`. The profile Ubuntu ships for bwrap
# (bwrap-userns-restrict) grants that, but stacks the sandboxed children into a
# restricted profile under which bwrap cannot set up the nested namespace that
# `--disable-userns` relies on ("setting up uid map: Permission denied").
#
# Instead of turning the machine-wide restriction off, this replaces that profile
# with one that grants `userns` to /usr/bin/bwrap and leaves it otherwise
# unconfined -- the same pattern Ubuntu itself uses for browsers. Every other
# process on the runner stays under the restriction, so if anything ever escaped
# a jail it still could not reach the kernel surface that user namespaces open
# up. The code *inside* the jails is unaffected either way: bwrap's
# --disable-userns caps max_user_namespaces in the sandbox, a per-namespace kernel
# limit that does not involve AppArmor.
#
# Finishes with a behavioural check: the exact namespace flags the jails use must
# work for the (unprivileged) caller.
set -euo pipefail

profile_dir=/etc/apparmor.d
# Replace the shipped profile in place so the kernel-side profile of the same
# name (`bwrap`, attached to /usr/bin/bwrap) is swapped rather than duplicated;
# fall back to a new file when the image does not ship one.
if [ -f "$profile_dir/bwrap-userns-restrict" ]; then
    profile_file="$profile_dir/bwrap-userns-restrict"
else
    profile_file="$profile_dir/bwrap"
fi

if [ -e /sys/module/apparmor/parameters/enabled ] && [ "$(cat /sys/module/apparmor/parameters/enabled)" = "Y" ]; then
    sudo tee "$profile_file" >/dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

# Installed by leanvfy (scripts/allow-bwrap-userns.sh): bubblewrap may create
# user namespaces, including the nested one --disable-userns needs; nothing
# else about it is confined. All other processes remain subject to
# kernel.apparmor_restrict_unprivileged_userns.
profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
}
EOF
    sudo apparmor_parser -r "$profile_file"
    echo "AppArmor: /usr/bin/bwrap may create user namespaces; restriction kept at" \
         "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo '?') for everything else"
else
    echo "AppArmor not enabled; nothing to change"
fi

# The flags below are the ones fetch-repo.sh and sandboxed-comparator.sh use.
if ! bwrap --unshare-all --unshare-user --disable-userns --die-with-parent \
        --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind-try /lib64 /lib64 \
        -- /bin/true; then
    echo "Error: bwrap cannot create its user namespaces on this machine" >&2
    exit 1
fi
echo "bwrap namespace self-test passed"
