#!/bin/sh

set -eu

minimum_kib=83886080
available_kib=$(/bin/df -Pk /System/Volumes/Data | /usr/bin/awk 'NR == 2 { print $4 }')

case "$available_kib" in
    ''|*[!0-9]*)
        echo "Unable to determine free space on /System/Volumes/Data." >&2
        exit 1
        ;;
esac

if [ "$available_kib" -lt "$minimum_kib" ]; then
    echo "Xcode build requires at least 80 GiB free on /System/Volumes/Data." >&2
    exit 1
fi

umask 077
lock_file=/private/tmp/junchat-element-x-ios-xcodebuild.lock
exec 9>>"$lock_file"
if ! /usr/bin/lockf -s -t 0 9; then
    echo "Another Junchat Xcode build holds $lock_file." >&2
    exit 1
fi
/bin/chmod 600 "$lock_file"

handshake_root=
ready_file=
go_file=
child_pid=
launching=0
pending_signal=
pending_exit_status=

cleanup_handshake() {
    if [ -z "$handshake_root" ]; then
        return 0
    fi
    case "$handshake_root" in
        /private/tmp/junchat-xcodebuild-handshake.*) ;;
        *) echo "Refusing to clean an unexpected Xcode handshake path." >&2; return 1 ;;
    esac
    /bin/rm -f "$ready_file" "$go_file"
    /bin/rmdir "$handshake_root" 2>/dev/null || true
    handshake_root=
}

process_group_is_active() {
    [ -n "$child_pid" ] && /bin/kill -0 "-$child_pid" 2>/dev/null
}

wait_for_process_group_exit() {
    attempts=0
    while process_group_is_active; do
        attempts=$((attempts + 1))
        if [ "$attempts" -eq 100 ]; then
            /bin/kill -KILL "-$child_pid" 2>/dev/null || true
        fi
        /bin/sleep 0.1
    done
}

terminate_process_group() {
    signal_name=$1
    if process_group_is_active; then
        /bin/kill "-$signal_name" "-$child_pid" 2>/dev/null || true
    elif [ -n "$child_pid" ]; then
        # A signal can arrive before the launcher finishes setpgid().
        /bin/kill "-$signal_name" "$child_pid" 2>/dev/null || true
    fi
    set +e
    wait "$child_pid" 2>/dev/null
    set -e
    wait_for_process_group_exit
    child_pid=
}

terminate_child_and_exit() {
    signal_name=$1
    exit_status=$2
    trap '' HUP INT TERM
    if [ -n "$child_pid" ]; then
        terminate_process_group "$signal_name"
    fi
    cleanup_handshake || true
    trap - EXIT
    exit "$exit_status"
}

handle_signal() {
    signal_name=$1
    exit_status=$2
    if [ "$launching" -eq 1 ] && [ -z "$child_pid" ]; then
        pending_signal=$signal_name
        pending_exit_status=$exit_status
        return 0
    fi
    terminate_child_and_exit "$signal_name" "$exit_status"
}

trap 'cleanup_handshake || true' EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

if /usr/bin/pgrep -x xcodebuild >/dev/null 2>&1 || /usr/bin/pgrep -x XCBBuildService >/dev/null 2>&1; then
    echo "Another Xcode build process is active; refusing a concurrent build." >&2
    exit 1
fi

readonly_root=${JUNCHAT_XCODEBUILD_READ_ONLY_ROOT:-}
readonly_git_dir=${JUNCHAT_XCODEBUILD_READ_ONLY_GIT_DIR:-}
readonly_git_common_dir=${JUNCHAT_XCODEBUILD_READ_ONLY_GIT_COMMON_DIR:-}
readonly_count=0
[ -n "$readonly_root" ] && readonly_count=$((readonly_count + 1))
[ -n "$readonly_git_dir" ] && readonly_count=$((readonly_count + 1))
[ -n "$readonly_git_common_dir" ] && readonly_count=$((readonly_count + 1))

if [ "$readonly_count" -ne 0 ] && [ "$readonly_count" -ne 3 ]; then
    echo "The three JUNCHAT_XCODEBUILD_READ_ONLY_* paths must be provided together." >&2
    exit 1
fi

profile='(version 1) (allow default) (deny network*)'
append_read_only_rule() {
    protected_path=$1
    variable_name=$2
    case "$protected_path" in
        /*) ;;
        *) echo "$variable_name must be absolute." >&2; exit 1 ;;
    esac
    case "$protected_path" in
        *'"'*|*'\'*) echo "$variable_name contains unsupported characters." >&2; exit 1 ;;
    esac
    if /usr/bin/printf '%s' "$protected_path" | LC_ALL=C /usr/bin/grep -q '[[:cntrl:]]'; then
        echo "$variable_name contains a control character." >&2
        exit 1
    fi
    if [ ! -d "$protected_path" ]; then
        echo "$variable_name must identify an existing directory." >&2
        exit 1
    fi
    profile="$profile (deny file-write* (subpath \"$protected_path\"))"
}

if [ "$readonly_count" -eq 3 ]; then
    append_read_only_rule "$readonly_root" JUNCHAT_XCODEBUILD_READ_ONLY_ROOT
    append_read_only_rule "$readonly_git_dir" JUNCHAT_XCODEBUILD_READ_ONLY_GIT_DIR
    append_read_only_rule "$readonly_git_common_dir" JUNCHAT_XCODEBUILD_READ_ONLY_GIT_COMMON_DIR
fi

handshake_root=$(/usr/bin/mktemp -d /private/tmp/junchat-xcodebuild-handshake.XXXXXX)
/bin/chmod 700 "$handshake_root"
ready_file=$handshake_root/ready
go_file=$handshake_root/go

launching=1
/usr/bin/perl -MPOSIX -MFcntl=F_SETFD,O_WRONLY,O_CREAT,O_EXCL -e '
    my ($parent_pid, $ready_path, $go_path, @command) = @ARGV;
    open my $lock_handle, ">&=9" or die "Unable to inherit the Xcode build lock: $!\n";
    my $lock_flags = fcntl($lock_handle, F_SETFD, 0);
    die "Unable to preserve the Xcode build lock: $!\n" unless defined $lock_flags;
    my $result = POSIX::setpgid(0, 0);
    die "Unable to create the Xcode process group: $!\n" unless defined $result;
    sysopen my $ready, $ready_path, O_WRONLY | O_CREAT | O_EXCL, 0600
        or die "Unable to create the Xcode process-group handshake: $!\n";
    print {$ready} "$$\n" or die "Unable to write the Xcode process-group handshake: $!\n";
    close $ready or die "Unable to close the Xcode process-group handshake: $!\n";
    until (-e $go_path) {
        exit 125 if getppid() != $parent_pid || !kill(0, $parent_pid);
        select undef, undef, undef, 0.05;
    }
    exec { $command[0] } @command;
    die "Unable to launch sandboxed xcodebuild: $!\n";
' "$$" "$ready_file" "$go_file" /usr/bin/sandbox-exec -p "$profile" /usr/bin/xcodebuild "$@" &
child_pid=$!
launching=0

attempts=0
while [ ! -f "$ready_file" ]; do
    attempts=$((attempts + 1))
    if ! /bin/kill -0 "$child_pid" 2>/dev/null || [ "$attempts" -ge 100 ]; then
        set +e
        wait "$child_pid"
        status=$?
        set -e
        child_pid=
        if [ "$status" -eq 0 ]; then
            status=1
        fi
        echo "Unable to establish the Xcode process group." >&2
        exit "$status"
    fi
    /bin/sleep 0.01
done

ready_pid=
IFS= read -r ready_pid < "$ready_file" || true
if [ "$ready_pid" != "$child_pid" ] || ! process_group_is_active; then
    terminate_process_group TERM
    echo "The Xcode process-group handshake is invalid." >&2
    exit 1
fi

if [ -n "$pending_signal" ]; then
    terminate_child_and_exit "$pending_signal" "$pending_exit_status"
fi

: > "$go_file"

set +e
wait "$child_pid"
status=$?
set -e
if process_group_is_active; then
    /bin/kill -TERM "-$child_pid" 2>/dev/null || true
    wait_for_process_group_exit
fi
child_pid=
exit "$status"
