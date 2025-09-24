#!/bin/sh

# wait_for_fifo makes sure our fifo exists for auto-install.sh
wait_for_fifo() {
    [ ! -p "$WATCH_FILE" ] || return 0

    echo "Waiting for FIFO: ${WATCH_FILE}"
    inotifywait --quiet --csv --event create "$(dirname "$WATCH_FILE")" | \
        while IFS=, read -r _dir _ _name; do
            [ "${_dir}/${_name}" != "$WATCH_FILE" ] || return 0
        done
}

# watch_devices waits for the kernel to generate UUIDs for connected disks
# There are other ways to check for devices. For instance, one could use the
# netlink interface.
watch_devices() {
    inotifywait --quiet --monitor --event "moved_to" /dev/disk/by-uuid | \
        while read -r _parent _action _uuid; do
            case "$_action" in
                MOVED_TO) try_mount "$_parent" "$_uuid" ;;
                *) : ;;
            esac
        done
}

# try_mount attempts to mount a given partition to a particular directory
try_mount() {
    _parent="${1%/}"
    _uuid="$2"

    _source="${_parent}/${_uuid}"
    _target="${MOUNT_DIR}/${_uuid}"

    : "${OPTIONS:=rw,sync}"
    : "${FSTYPE:=vfat}"

    echo "${SNAP_NAME}.auto-mount found: ${_source}"

    # inotifywait can trigger for the same UUID symlink creation multiple times,
    # so we check that the partition isn't already mounted
    ! grep -q "$_target" /proc/mounts || {
      echo "WARN: Device is already mounted at ${_target}"
      return 0
    }

    mkdir -p "$_target"
    if ! mount -o "$OPTIONS" -t "$FSTYPE" "$_source" "$_target"; then
        echo "WARN: Could not mount ${_source} to ${_target}"
        rmdir "$_target"
        return 0
    fi

    # Add the mountpoint to our fifo for auto-install.sh
    wait_for_fifo
    echo "$_target" >> "$WATCH_FILE"
}

# cleanup acts to ensure this daemon remains tidy
cleanup() {
    _exit_status=$?

    sync
    
    # Check if MOUNT_DIR exists and continue with our life
    [ ! -e "$MOUNT_DIR" ] || {
        for _mount_path in "$MOUNT_DIR/"*; do
            # Skip if glob didn't match anything
            [ -e "$_mount_path" ] || continue
            
            _uuid=$(basename "$_mount_path")
            
            # Attempt to unmount the device
            umount "$_mount_path" 2>/dev/null && 
		    echo "Unmounted: $_mount_path" || 
		    echo "WARN: Failed to unmount $_mount_path"
            
            # Remove the mount directory
            rmdir "$_mount_path" 2>/dev/null && 
		    echo "Removed directory: $_mount_path" || 
		    echo "WARN: Failed to remove directory $_mount_path"
        done
        
        # Remove the main mount directory
        rmdir "$MOUNT_DIR" 2>/dev/null || 
		echo "WARN: Could not remove mount directory $MOUNT_DIR (may not be empty)"
    }
    
    # Exit with 0 if we're interrupted with INT or TERM
    case $_exit_status in 130|143) exit 0; esac
}

# main ensures important variables are set and watches for disk events
main() {
    set -eu

    : "${WATCH_FILE:=/tmp/mounts.fifo}"; readonly WATCH_FILE
    : "${MOUNT_DIR:="$(mktemp -d)"}";    readonly MOUNT_DIR

    trap exit    INT TERM
    trap cleanup EXIT

    watch_devices
}

[ -n "$NOEXEC" ] || main
