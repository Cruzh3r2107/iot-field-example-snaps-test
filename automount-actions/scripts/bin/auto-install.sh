#!/bin/sh

# mklog ensures that a log file exists
mklog() {
    _log_dir="${1:-"$LOG_DIR"}"

    [ -d "$_log_dir" ] || mkdir -p "$_log_dir"

    _log_file="${_log_dir}/$(date '+%Y-%m-%d_%H-%M-%S').log"
    : >| "$_log_file" && echo "$_log_file"
}

# log to SNAP_COMMON and TTY
# _log_file is created by auto-install.sh and will exist
# shellcheck disable=2154
log() {
    printf '%s %s\n' \
        "$(date -Iseconds)" "$*" | tee -a "${_log_file}" >&2
}

# rest_call submits either an acknowledge, install, or channel track request to
# the snapd socket. For more information on valid endpoints, see:
# https://snapcraft.io/docs/snapd-api
rest_call() {
    _action="$1"
    _file="$2"

    _snap_name="$(basename "${2%%_*}")"
    _socket="${SNAPD_SOCKET:-/run/snapd.socket}"

    case "$_action" in
        ack)
            curl \
                -sS \
                -X POST \
                --data-binary "@$_file" \
                --unix-socket "$_socket" \
                http://localhost/v2/assertions
        ;;
        install)
            curl \
                -sS \
                -X POST \
                --form snap="@$_file" \
                --unix-socket "$_socket" \
                http://localhost/v2/snaps
        ;;
        track)
            curl \
                -sS \
                -X POST \
                --unix-socket "$_socket" \
                --header "Content-Type: application/json" \
                --data '{"action":"switch","channel":"stable"}' \
                "http://localhost/v2/snaps/${_snap_name}"
        ;;
    esac
}

# validate_assertion_file checks that assertion contains required components
# A valid assertion file must contain account-key, snap-declaration, and snap-revision
validate_assertion_file() {
    _assert_file="$1"
    
    # Check if file exists and is readable
    [ -r "$_assert_file" ] || {
        log "ERROR: Cannot read assertion file: $_assert_file"
        return 1
    }
    
    # Check file is not empty
    [ -s "$_assert_file" ] || {
        log "ERROR: Assertion file is empty: $_assert_file"
        return 1
    }
    
    # Use permission-style integer flags to track which assertions are found
    # This allows us to determine exactly which ones are missing based on the sum
    _has_account_key=0
    _has_snap_declaration=0
    _has_snap_revision=0
    
    # Read the file and look for the required assertion types
    # Parse key-value pairs properly by splitting on ': '
    while IFS=': ' read -r _key _val; do
        [ "$_key" = "type" ] || continue
        case "$_val" in
            "account-key")     _has_account_key=1     ;;
            "snap-declaration") _has_snap_declaration=2 ;;
            "snap-revision")   _has_snap_revision=4   ;;
        esac
    done < "$_assert_file"
    
    # Calculate sum to determine which assertions are present
    _sum=$(( _has_account_key + _has_snap_declaration + _has_snap_revision ))
    
    # If sum is 7 (1+2+4), all assertions are present
    [ "$_sum" -eq 7 ] && {
        log "VALIDATION: Assertion file contains all required types: $_assert_file"
        return 0
    }
    
    # Build missing assertions message based on sum
    _missing=""
    [ $(( _sum & 1 )) -eq 0 ] && _missing="${_missing} account-key"
    [ $(( _sum & 2 )) -eq 0 ] && _missing="${_missing} snap-declaration" 
    [ $(( _sum & 4 )) -eq 0 ] && _missing="${_missing} snap-revision"
    
    log "WARN: Assertion file missing${_missing}: $_assert_file"
    
    return 1
}

# validate_snap_file performs basic validation on snap files
# Checks file accessibility, size, and SquashFS format when possible
validate_snap_file() {
    _snap_file="$1"
    
    # Check if file exists and is readable
    [ -r "$_snap_file" ] || {
        log "ERROR: Cannot read snap file: $_snap_file"
        return 1
    }
    
    # Check if file is not empty
    [ -s "$_snap_file" ] || {
        log "ERROR: Snap file is empty: $_snap_file"
        return 1
    }
    
    # Check file size is reasonable (> 1KB, < 2GB for safety)
    if command -v stat >/dev/null 2>&1; then
        _file_size=$(stat -c%s "$_snap_file" 2>/dev/null) || {
            log "WARN: Cannot determine size of snap file: $_snap_file"
            # Don't fail here, continue with other checks
        }
        
        if [ -n "$_file_size" ]; then
            [ "$_file_size" -gt 1024 ] || {
                log "ERROR: Snap file is too small (<1KB): $_snap_file"
                return 1
            }
            
            [ "$_file_size" -lt 2147483648 ] || {
                log "WARN: Snap file is unusually large (>2GB): $_snap_file"
            }
        fi
    fi
    
    # Check if it's a SquashFS file (snap files are SquashFS archives)
    # SquashFS magic number is 'hsqs' at offset 0
    # Use dd to read first 4 bytes, redirect stderr to avoid noise
    _magic=$(dd if="$_snap_file" bs=4 count=1 2>/dev/null)
    if [ -n "$_magic" ] && [ "$_magic" != "hsqs" ]; then
        log "WARN: Snap file does not appear to be SquashFS format: $_snap_file"
        # Don't fail here as snapd will do final validation
    fi
    
    log "VALIDATION: Basic snap file validation passed: $_snap_file"
    return 0
}

# ack_assert acknowledges an assertion file after validation
ack_assert() {
    _assert="$1"

    # Validate assertion file contains required components
    if ! validate_assertion_file "$_assert"; then
        log "ERROR: ASSERTION VALIDATION: $_assert failed validation"
        return 1
    fi

    # Acknowledge the assertion
    _response="$(rest_call ack "$_assert")"

    if ! echo "$_response" | grep -Iq '"status":"OK"'; then
        log "ERROR: ACKNOWLEDGE RESULT: $_assert not acknowledged"
        return 1
    fi

    log "ACKNOWLEDGE RESULT: $_assert acknowledged"
}

# install_snap installs a snap file after validation
install_snap() {
    _snap="$1"

    # Validate snap file before attempting installation
    if ! validate_snap_file "$_snap"; then
        log "ERROR: SNAP VALIDATION: $_snap failed validation"
        return 1
    fi

    # Install the snap
    _response="$(rest_call install "$_snap")"

    if ! echo "$_response" | grep -Iq '"status":"Accepted"'; then
        log "ERROR: INSTALL RESULT: ${_snap##*/} not installed"
        return 1
    fi

    log "INSTALL RESULT: ${_snap##*/} installed"
}

# track_stable sets the upstream tracking channel for a snap
# track_stable can optionally fail and will require manual intervention
track_stable() {
    # Keep trying to set the channel to stable because it may take some
    #   time if a snap change is in progress. Quadratically back off each loop,
    #   and quit after 9 loops, for a sum total of ~17 minutes

    _snap_name="$1"

    _loop_count=0
    _sleep=2

    while
        _response="$(rest_call track "$_snap_name")"

        if echo "$_response" | grep -Iq '"status":"Accepted"'; then
            log "${_snap_name} is now following stable"
            return 0
        fi

        [ $_loop_count -lt 9 ]
    do
        sleep $_sleep

        : $(( _loop_count += 1 ))
        : $(( _sleep      *= 2 ))
    done

    log "WARN: failed to make $_snap_name follow stable"
    log "WARN: Manual intervention may be required for $_snap_name to refresh"
    return 1
}

# eject_device handles device ejection and cleaning
eject_device() {
    # Try to copy log file over
    cp -f "$_log_file" "$_mount_point" || true

    # Remove the temp directory
    rm -r "$(dirname "$_log_file")"

    sync
    umount "$_mount_point"
    rmdir "$_mount_point"
}

# process_mounts verifies that for each assertion on a disk there is a
# correspondingly named snap file in the same directory. It acknowledges the
# assertion, installs the snap, and attempts to set that snap to track

# Updated process_mounts() - log file now created in main()
process_mounts() {
    _watch_file="$1"

    while read -r _mount_point < "$_watch_file"; do

        # Make sure the mount actually exists
        [ -d "$_mount_point" ] || continue

        log "Mountpoint is ${_mount_point}."

        # Rest of the function continues as before...
        _asserts=$(find "$_mount_point" -name "*.assert" -type f)
        [ -n "$_asserts" ] || {
            log "WARN: No assertions found."
            eject_device
            continue
        }

        # Loop through each assert and, for those with a corresponding snap, install
        echo "$_asserts" | while read -r _assert; do
            [ -n "$_assert" ] || continue
            
            # Make sure a corresponding snap exists
            [ -e "${_assert%%.assert}.snap" ] || {
                log "WARN: ${_assert%%.assert}.snap not found for $_assert"
                continue
            }

            # We want to continue in cases where ack_assert and install_snap
            # succeed, but track_stable fails. track_stable is optional
            # shellcheck disable=2015
            ack_assert "$_assert" \
                && install_snap "${_assert%.assert}.snap" \
                && track_stable "$(basename "${_assert%_*}")" \
                || continue
        done

        eject_device
    done
}

# cleanup acts to make sure this daemon stays tidy
cleanup() {
    _exit_status=$?

    rm -f "$WATCH_FILE"

    # Exit with 0 if we're interrupted with INT or TERM
    case $_exit_status in 130|143) exit 0; esac
}

# main ensures our fifo exists before we proceed to operating on a disk
main() {
    # Globally set exit on error, no unset variables
    set -eu

    : "${LOG_DIR:="$(mktemp -d)"}"; readonly LOG_DIR
    
    _log_file="$(mklog)"
    readonly _log_file
    
    : "${WATCH_FILE:=/tmp/mounts.fifo}"; readonly WATCH_FILE
    [ -p "$WATCH_FILE" ] || mkfifo "$WATCH_FILE"

    trap exit    INT TERM
    trap cleanup EXIT

    process_mounts "$WATCH_FILE"
}

[ -n "$NOEXEC" ] || main
