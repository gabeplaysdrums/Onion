#!/bin/sh

start=$(date +%s)

NAME=
CONFIG_FILE=/mnt/SDCARD/rclone.conf
LOGS_REL_DIR=logs
LOG_FILE_PREFIX=cloud_sync
LOG_FILE_SUFFIX=.log
LOG_FILE_TAIL_SUFFIX=.tail
LOG_FILE_LATEST=cloud_sync.log.latest
LOG_FILE_LATEST_TAIL=$LOG_FILE_LATEST.tail
MAX_LOG_FILES=5
ERROR_FLAG=/tmp/cloud_sync_error
PROFILE=/mnt/SDCARD/Saves/CurrentProfile
DRY_RUN_CONFIG_FLAG=/mnt/SDCARD/.tmp_update/config/.cloudSyncDryRun
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
timestamp=$(date -d @$start "+%Y%m%d-%H%M%S")
LOG_FILE="$LOGS_DIR/${LOG_FILE_PREFIX}-${timestamp}${LOG_FILE_SUFFIX}"
echo "LOG_FILE: $LOG_FILE"
echo $0 $* >$LOG_FILE

log() {
    echo $* >>$LOG_FILE
    echo $*
}

finish_log() {
    latest_log_file="$LOGS_DIR/$LOG_FILE_LATEST"
    #ln -fs "$LOG_FILE" "$latest_log_file" >$LOG_FILE 2>&1
    cp "$LOG_FILE" "$latest_log_file"

    tail_log_file="${LOG_FILE}${LOG_FILE_TAIL_SUFFIX}"
    tail -20 $LOG_FILE >$tail_log_file
    latest_log_file_tail="$LOGS_DIR/$LOG_FILE_LATEST_TAIL"
    #ln -fs "$tail_log_file" "$latest_log_file_tail" >$LOG_FILE 2>&1
    cp "$tail_log_file" "$latest_log_file_tail"
}

logs_pattern=${LOGS_DIR}/${LOG_FILE_PREFIX}*${LOG_FILE_SUFFIX}
log_count=$(ls -l $logs_pattern 2>/dev/null | wc -l)

while [ $log_count -ge $MAX_LOG_FILES ]; do
    oldest_log_file=$(ls -tr $logs_pattern | tr '\n' '\n' | head -1)
    log "Deleting old log file: $oldest_log_file"
    rm -f $oldest_log_file
    rm -f "${oldest_log_file}${LOG_FILE_TAIL_SUFFIX}"
    log_count=$(ls -l $logs_pattern 2>/dev/null | wc -l)
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
    if [ -e "$LIBPADSP" ]; then
        sleep 5
    fi
    finish_log
    exit 1
}

ntpd_offset=0

# Quick time sync fix
if which ntpd; then
    preload_info_panel "Syncing clock to network time"
    log "Time before NTP sync is $timestamp"
    export TZ=UTC-0

    NTPD_LOG=/tmp/ntpd.log
    ntpd -n -q -N -p time.nist.gov -p 162.159.200.1 >$NTPD_LOG 2>&1
    ntpd_error=$?
    cat $NTPD_LOG >>$LOG_FILE
    if [ $ntpd_error -ne 0 ]; then
        exit_on_error "NTPD failed"
    fi
    hwclock -w >>$LOG_FILE 2>&1 || exit_on_error "hwclock failed"
    while IFS= read -r line; do
        match=$(echo $line | grep -o -E "^ntpd: setting time to .* \(offset -?[0-9]+(\.[0-9]+)s\)")
        if [ $? -eq 0 ]; then
            log "found offset line in ntpd output"
            # extract offset part
            match=$(echo $match | grep -o -E "\(offset -?[0-9]+(\.[0-9]+)s\)")
            # extract seconds part
            match=$(echo $match | grep -o -E "[-]?[0-9]+" | head -1)
            # set ntpd offset
            ntpd_offset=$match
        fi
    done < $NTPD_LOG
    log "ntpd offset is $ntpd_offset seconds"

    if [ $ntpd_offset -ne 0 ]; then
        # adjust log file name
        old_log_file=$LOG_FILE
        start=$(expr $start + $ntpd_offset)
        timestamp=$(date -d @$start "+%Y%m%d-%H%M%S")
        LOG_FILE="$LOGS_DIR/${LOG_FILE_PREFIX}-${timestamp}${LOG_FILE_SUFFIX}"
        mv $old_log_file $LOG_FILE
    fi
fi

log "Current time is $timestamp"

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

        local dry_run_option=
        if [ -f $DRY_RUN_CONFIG_FLAG ] || [ "$CLOUD_SYNC_DRY_RUN" = "true" ]; then
            log "WARNING: Performing dry run"
            dry_run_option=--dry-run
        fi

        "$RCLONE" bisync --verbose --workdir $BISYNC_WORK_DIR $resync_option $dry_run_option $filter_option $RCLONE_OPTIONS $CLOUD_DIR $LOCAL_DIR >>$LOG_FILE 2>&1
        local rclone_error=$?

        if [ $rclone_error -ne 0 ]; then
            log "rclone bisync failed with exit code $rclone_error"
            if [ $rclone_error -eq 2 ] && [ -z "$resync_option" ]; then
                log "WARNING: bisync failed.  Trying again with --resync"
                "$RCLONE" bisync --verbose --workdir $BISYNC_WORK_DIR --resync $dry_run_option $filter_option $RCLONE_OPTIONS $CLOUD_DIR $LOCAL_DIR >>$LOG_FILE 2>&1 || exit_on_error "Bidirectional sync failed while syncing $WHAT"
            else
                exit_on_error "Bidirectional sync failed while syncing $WHAT"
            fi
        fi
    fi
}

sync_profile_dir "profile" "" "sync" "$SCRIPT_DIR/filter-list.txt"

# Smart sync of matching ROMs
if [ -f "$SYNC_ROMS_CONFIG_FLAG" ] || [ "$CLOUD_SYNC_ROMS" = "true" ]; then
    log "ROMS: $ROMS"
    preload_info_panel "Searching for matching ROMs"
    ROMS_FILTER_LIST=/tmp/roms-filter-list.txt
    echo "# roms matched to saves and states" >$ROMS_FILTER_LIST
    chmod u+x "$SCRIPT_DIR/find-roms.sh"
    "$SCRIPT_DIR/find-roms.sh" -p "$PROFILE" -r "$ROMS" |
        while IFS= read -r rom_subpath; do
            echo "+ $rom_subpath" >>$ROMS_FILTER_LIST
            preload_info_panel "Searching for matching ROMs\n$rom_subpath"
        done
    echo "# exclude everything else" >>$ROMS_FILTER_LIST
    echo "- **" >>$ROMS_FILTER_LIST
    log "-- filter list begin --"
    cat $ROMS_FILTER_LIST >>$LOG_FILE
    log "-- filter list end --"
    preload_info_panel "Uploading matching ROMs to the cloud"
    "$RCLONE" copy --update -P -L --filter-from="$ROMS_FILTER_LIST" $RCLONE_OPTIONS "$ROMS" "$CLOUD_DIR/Roms" >>$LOG_FILE 2>&1 || exit_on_error "Failed to upload ROMs"
    preload_info_panel "Downloading ROMs from the cloud"
    "$RCLONE" copy --update -P -L $RCLONE_OPTIONS "$CLOUD_DIR/Roms" "$ROMS" >>$LOG_FILE 2>&1 || exit_on_error "Failed to download ROMs"
fi

now=$(date +%s)
elapsed=$(expr $now - $start)
preload_info_panel "Success!\nSync took $elapsed seconds"
finish_log