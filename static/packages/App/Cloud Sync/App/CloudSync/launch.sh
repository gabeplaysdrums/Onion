#!/bin/sh
echo $0 $*

NAME_FILE=/mnt/SDCARD/name.txt
NAME=unnamed
if [ -f "$NAME_FILE" ]; then
    NAME=$(cat "$NAME_FILE")
fi

echo NAME: $NAME

cd $(dirname "$0")

# Quick time sync fix
ntpd -N -p 162.159.200.1
hwclock -w

# rclone

sync_dirs() {
    local TITLE="Syncing $NAME device"
    local MESSAGE=$1
    local LOCAL_DIR=$2
    local CLOUD_DIR=$3
    echo "Title: $TITLE"
    echo "Message: $MESSAGE"
    echo "Local dir: $LOCAL_DIR"
    echo "Cloud dir: $CLOUD_DIR"

    LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so /mnt/SDCARD/.tmp_update/bin/infoPanel -t "$TITLE" -m "$MESSAGE" --auto &

    ./rclone copy -P -L --no-check-certificate --config=/mnt/SDCARD/rclone.conf $LOCAL_DIR $CLOUD_DIR
    ./rclone copy -P -L --no-check-certificate --config=/mnt/SDCARD/rclone.conf $CLOUD_DIR $LOCAL_DIR
}

sync_dirs "Syncing saves with the cloud" "/mnt/SDCARD/Saves/CurrentProfile/saves/" "cloud:Onion/$NAME/saves/"
sync_dirs "Syncing states with the cloud" "/mnt/SDCARD/Saves/CurrentProfile/states/" "cloud:Onion/$NAME/states/"
sync_dirs "Syncing rom screens with the cloud" "/mnt/SDCARD/Saves/CurrentProfile/romScreens/" "cloud:Onion/$NAME/romScreens/"
#sync_dirs "Syncing ROMs with the cloud" "/mnt/SDCARD/Roms/" "cloud:Onion/Roms/"