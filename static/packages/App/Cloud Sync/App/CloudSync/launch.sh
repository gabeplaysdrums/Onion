#!/bin/sh

start=$(date +%s)

NAME=
CONFIG_FILE=/mnt/SDCARD/rclone.conf
LOGS_REL_DIR=logs
LOG_FILE_PREFIX="cloud_sync"
LOG_FILE_SUFFIX=.log
MAX_LOG_FILES=10
ERROR_FLAG=/tmp/cloud_sync_error
PROFILE=/mnt/SDCARD/Saves/CurrentProfile
SYNC_ROMS_CONFIG_FLAG=/mnt/SDCARD/.tmp_update/config/.cloudSyncRoms
ROMS=/mnt/SDCARD/Roms
RCLONE_REMOTE=cloud
CLOUD_DIR=$RCLONE_REMOTE:Onion
SCRIPT_DIR=$(dirname "$0")
WORK_DIR=$SCRIPT_DIR

show_usage_and_exit() {
    echo "usage: $(basename $0) [-p profile_directory] [-r roms_directory] [-n device_name] [-w work_dir] [-c rclone_config]"
    exit 1
}

while getopts 'p:r:n:w:c:' opt; do
    case "$opt" in
        p)
            PROFILE="${OPTARG%/}"
            ;;
        r)
            ROMS="${OPTARG%/}"
            ;;
        n)
            NAME="$OPTARG"
            ;;
        w)
            WORK_DIR="${OPTARG%/}"
            ;;
        c)
            CONFIG_FILE="$OPTARG"
            ;;
        ?)
            show_usage_and_exit
            ;;
    esac
done
shift "$(($OPTIND -1))"

abs_path() {
    if [ -e "$1" ]; then
        echo $(cd "$(dirname "$1")" && pwd)/$(basename "$1")
    else
        echo $1
    fi
}

mkdir -p "$WORK_DIR"

LOGS_DIR=$(abs_path "$WORK_DIR/$LOGS_REL_DIR")
mkdir -p "$LOGS_DIR"
timestamp=$(date "+%Y%m%d-%H%M%S")
LOG_FILE="$LOGS_DIR/$LOG_FILE_PREFIX-$timestamp.log"
echo "LOG_FILE: $LOG_FILE"
echo $0 $* >$LOG_FILE

log() {
    echo $* >>$LOG_FILE
    echo $*
}

LOGS_PATTERN=${LOGS_DIR}/${LOG_FILE_PREFIX}*${LOG_FILE_SUFFIX}
declare -i log_count=$(ls -l $LOGS_PATTERN 2>/dev/null | wc -l)

while [ $log_count -ge $MAX_LOG_FILES ]; do
    oldest_log_file=$(ls -tr $LOGS_PATTERN | tr '\n' '\n' | head -1)
    log "Deleting old log file: $oldest_log_file"
    rm -f $oldest_log_file
    log_count=$(ls -l $LOGS_PATTERN 2>/dev/null | wc -l)
done

RCLONE=$(which rclone 2>/dev/null)
if [ $? -ne 0 ]; then
    RCLONE="$SCRIPT_DIR/rclone"
fi
log "RCLONE: $RCLONE"
CONFIG_FILE=$(abs_path "$CONFIG_FILE")
log "CONFIG_FILE: $CONFIG_FILE"
RCLONE_OPTIONS="--no-check-certificate --config=$CONFIG_FILE"

if [ -z "$NAME" ]; then
    NAME_FILE=/mnt/SDCARD/name.txt
    NAME=unnamed
    if [ -f "$NAME_FILE" ]; then
        NAME=$(cat "$NAME_FILE")
    fi
fi
log "NAME: $NAME"

TITLE="Syncing $NAME device"
log $TITLE

LIBPADSP="/mnt/SDCARD/miyoo/lib/libpadsp.so"

preload_info_panel() {
    local MESSAGE=$1
    local PANEL_TITLE=$2

    if [ -z "$PANEL_TITLE" ]; then
        PANEL_TITLE=$TITLE
    fi

    log $MESSAGE
    if [ -f "$LIBPADSP" ]; then
        LD_PRELOAD=$LIBPADSP /mnt/SDCARD/.tmp_update/bin/infoPanel -t "$PANEL_TITLE" -m "$MESSAGE" --auto &
    fi
}

rm $ERROR_FLAG >/dev/null 2>&1

exit_on_error() {
    local MESSAGE=$1
    preload_info_panel "$MESSAGE" "Error"
    touch $ERROR_FLAG >/dev/null 2>&1
    if [ -f "$LIBPADSP" ]; then
        sleep 5
    fi
    exit 0
}

now=$(date +%s)
elapsed_offset=$(expr $now - $start)

# Quick time sync fix
if which ntpd; then
    preload_info_panel "Syncing clock to network time"
    export TZ=UTC-0
    ntpd -n -q -N -p time.nist.gov -p 162.159.200.1 >>$LOG_FILE 2>&1 || exit_on_error "NTPD failed"
    hwclock -w >>$LOG_FILE 2>&1 || exit_on_error "hwclock failed"
fi

start=$(date +%s)

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
log "Current time is $TIMESTAMP"

# rclone check
preload_info_panel "Checking cloud connection"
"$RCLONE" $RCLONE_OPTIONS -vv lsd ${RCLONE_REMOTE}: >>$LOG_FILE 2>&1 || exit_on_error "Could not verify cloud connection"

sync_profile_dir() {
    local WHAT=$1
    local REL_DIR=$2
    local OP=$3
    local FILTER_LIST=$4

    if [ -z "$OP" ]; then
        OP="sync"
    fi

    local filter_option=
    if [ ! -z "$FILTER_LIST" ]; then
        # Path to filter list cannot contain spaces
        cp "$FILTER_LIST" /tmp/filter-list.txt
        filter_option=--filters-file=/tmp/filter-list.txt
    fi

    local LOCAL_DIR=$(abs_path "$PROFILE/$REL_DIR")
    log "LOCAL_DIR: $LOCAL_DIR"
    local CLOUD_DIR="$CLOUD_DIR/$NAME/$REL_DIR"
    log "CLOUD_DIR: $CLOUD_DIR"
    log "OP: $OP"

    local BISYNC_WORK_DIR="$WORK_DIR/bisync/$NAME/$REL_DIR"
    log "BISYNC_WORK_DIR: $BISYNC_WORK_DIR"

    if [ "$OP" = "upload" ]; then
        preload_info_panel "Uploading $WHAT to the cloud"
        "$RCLONE" copy --update -P -L $filter_option $RCLONE_OPTIONS $LOCAL_DIR $CLOUD_DIR >>$LOG_FILE 2>&1 || exit_on_error "Upload failed while syncing $WHAT"
    fi

    if [ "$OP" = "download" ]; then
        preload_info_panel "Downloading $WHAT from the cloud"
        "$RCLONE" copy --update -P -L $filter_option $RCLONE_OPTIONS $CLOUD_DIR $LOCAL_DIR >>$LOG_FILE 2>&1 || exit_on_error "Download failed while syncing $WHAT"
    fi

    if [ "$OP" = "sync" ]; then
        preload_info_panel "Syncing $WHAT with the cloud"

        "$RCLONE" mkdir $RCLONE_OPTIONS $CLOUD_DIR >>$LOG_FILE 2>&1 || exit_on_error "Failed to create cloud directory while syncing $WHAT"

        local resync_option=--resync

        if [ -d "$BISYNC_WORK_DIR" ]; then
            resync_option=
        else
            mkdir -p "$BISYNC_WORK_DIR"
        fi

        "$RCLONE" bisync $resync_option $filter_option $RCLONE_OPTIONS $CLOUD_DIR $LOCAL_DIR >>$LOG_FILE 2>&1
        local rclone_error=$?

        if [ $rclone_error -ne 0 ]; then
            log "rclone bisync failed with exit code $rclone_error"
            if [ $rclone_error -eq 2 ] && [ -z "$resync_option" ]; then
                log "WARNING: bisync failed.  Trying again with --resync"
                "$RCLONE" bisync --resync $filter_option $RCLONE_OPTIONS $CLOUD_DIR $LOCAL_DIR >>$LOG_FILE 2>&1 || exit_on_error "Bidirectional sync failed while syncing $WHAT"
            else
                exit_on_error "Bidirectional sync failed while syncing $WHAT"
            fi
        fi
    fi
}

# sync_profile_dir "saves" "saves/"
# sync_profile_dir "states" "states/"
# sync_profile_dir "rom screens" "romScreens/"
sync_profile_dir "profile" "" "sync" "$SCRIPT_DIR/filter-list.txt"


# Smart sync of matching ROMs
if [ -f "$SYNC_ROMS_CONFIG_FLAG" ]; then
    preload_info_panel "Searching for matching ROMs"
    "$SCRIPT_DIR/find-roms.sh" -p "$PROFILE" -r "$ROMS" |
        while IFS= read -r rom_subpath; do
            preload_info_panel "Copying ROMs to the cloud\n$rom_subpath"
            "$RCLONE" copyto --update -P -L $RCLONE_OPTIONS "$ROMS/$rom_subpath" "$CLOUD_DIR/Roms/$rom_subpath" >>$LOG_FILE 2>&1 || exit_on_error "Failed to upload $rom_subpath"
        done
fi

now=$(date +%s)
elapsed=$(expr $elapsed_offset + $now - $start)
preload_info_panel "Success!\nSync took $elapsed seconds"