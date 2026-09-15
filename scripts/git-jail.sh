#!/usr/bin/env bash
# shellcheck shell=bash
# Sourced by fetch-repo.sh and tree-digest.sh: the one way git is ever run on
# prover-controlled data.
#
#   git_jail <dir> fetch|read <command...>
#
# Runs <command> inside a bubblewrap jail whose only content besides the system
# binaries is <dir>, mounted at /repo:
#   fetch  <dir> is writable and the jail shares the host's network -- used once,
#          to bring the requested commit in.
#   read   <dir> is read-only and there is no network at all -- used to inspect a
#          finished checkout (tree listing, blob contents).
# Both: own user/pid/ipc/uts namespaces, no nested user namespaces, empty
# environment, no HOME configuration, no /etc/gitconfig, and git's own settings
# come from the environment (GIT_CONFIG_*), so they apply to every git process
# the command starts:
#   - https is the only transport, also across redirects (protocol.allow=never
#     plus an explicit allow for https): closes ext:: (command execution),
#     file://, ssh://, git://;
#   - no credentials, no prompts, no hooks, no submodule recursion;
#   - objects are fsck'ed on receipt.
# Everything a hostile server or repository can throw at git -- transport
# tricks, malformed packfiles, delta bombs, odd tree entries -- is parsed in
# here, where a git bug yields a throwaway namespace and a directory the rest of
# the pipeline treats as untrusted anyway. The same holds for reading back the
# objects later: pack and delta decoding are separate code paths from fsck, so
# they get the same wall.
#
# Read-only mounts are for name resolution and TLS (fetch) and for git to look
# up the user it runs as; nothing else from /etc is visible.
git_jail() {
    local dir="$1" access="$2"
    shift 2
    local mount_flag
    local -a net=()
    case "$access" in
        fetch)
            mount_flag=--bind
            net=(--share-net)
            ;;
        read) mount_flag=--ro-bind ;;
        *)
            echo "git_jail: access must be fetch or read, got '$access'" >&2
            return 1
            ;;
    esac
    bwrap \
        --unshare-all \
        --unshare-user \
        "${net[@]}" \
        --disable-userns \
        --die-with-parent \
        --ro-bind /usr /usr \
        --ro-bind /lib /lib \
        --ro-bind /lib64 /lib64 \
        --ro-bind /bin /bin \
        --ro-bind-try /etc/alternatives /etc/alternatives \
        --ro-bind /etc/ssl /etc/ssl \
        --ro-bind /etc/resolv.conf /etc/resolv.conf \
        --ro-bind-try /etc/hosts /etc/hosts \
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
        --ro-bind-try /etc/passwd /etc/passwd \
        "$mount_flag" "$dir" /repo \
        --tmpfs /tmp \
        --proc /proc \
        --dev /dev \
        --chdir /repo \
        env -i \
        PATH="/usr/bin:/bin" \
        HOME="/tmp" \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 \
        GIT_ASKPASS=/bin/false \
        GIT_CONFIG_COUNT=10 \
        GIT_CONFIG_KEY_0=protocol.allow GIT_CONFIG_VALUE_0=never \
        GIT_CONFIG_KEY_1=protocol.https.allow GIT_CONFIG_VALUE_1=always \
        GIT_CONFIG_KEY_2=credential.helper GIT_CONFIG_VALUE_2= \
        GIT_CONFIG_KEY_3=core.hooksPath GIT_CONFIG_VALUE_3=/dev/null \
        GIT_CONFIG_KEY_4=core.askPass GIT_CONFIG_VALUE_4=/bin/false \
        GIT_CONFIG_KEY_5=submodule.recurse GIT_CONFIG_VALUE_5=false \
        GIT_CONFIG_KEY_6=transfer.fsckObjects GIT_CONFIG_VALUE_6=true \
        GIT_CONFIG_KEY_7=fetch.fsckObjects GIT_CONFIG_VALUE_7=true \
        GIT_CONFIG_KEY_8=http.sslVerify GIT_CONFIG_VALUE_8=true \
        GIT_CONFIG_KEY_9=advice.detachedHead GIT_CONFIG_VALUE_9=false \
        "$@"
}
