#!/bin/bash

# Simple script to create regular snapshot-based backups for Citrix Xenserver
# Cocchi Lorenzo <lorenzo.cocchi@softecspa.it>
# Original idea from  Mark Round, scripts@markround.com
#  http://www.markround.com/snapback
#
# version 1.4:
#  add daily sheduling and retention selective scheduling

# Usage:
#
# [root@xenserver ~]# xe vm-list name-label=vm_name params=uuid --minimal
# 95b7ae99-e66b-aac4-8851-a0ceaaef4292
#
# [root@xenserver ~]# xe vm-param-set \
#    uuid=95b7ae99-e66b-aac4-8851-a0ceaaef4292 \
#    other-config:XenCenter.CustomFields.schedule="daily,weekly,monthly"
#
# [root@xenserver ~]# xe vm-param-set \
#    uuid=95b7ae99-e66b-aac4-8851-a0ceaaef4292 \
#    other-config:XenCenter.CustomFields.retain="daily=2,weekly=1,monthly=1"
#
# [root@xenserver ~]# ./snapback.sh

#
# Variables
#

# Temporary snapshots will be use this as a suffix
SNAPSHOT_SUFFIX=snapback
# Temporary backup templates will use this as a suffix
TEMP_SUFFIX=newbackup
# Temporary file
TEMP=/tmp/snapback.$$
# UUID of the destination SR for backups
DEST_SR=3be6f5c2-8828-8ed4-2c9b-db78a96b3a99

#
# Don't modify below this line
#

log()
{
    logger -p daemon.debug -s -t $(date "+%F %T") $(basename $0)[$$]: -- "$@"
}

backup_schedule()
{
    local SCHEDULE=$1

    if [[ "$SCHEDULE" =~ 'monthly' ]] && [[ $(date '+%d') =~ ^01$ ]]; then
        echo "monthly"
        exit
    fi

    if [[ "$SCHEDULE" =~ 'daily' ]] && [[ $(date '+%w') =~ ^[1-6]$ ]]; then
        echo "daily"
        exit
    fi

    if [[ "$SCHEDULE" =~ 'weekly' ]] && [[ $(date '+%w') =~ ^0$ ]]; then
        echo "weekly"
        exit
    fi
}

retain_number()
{
    local RETAIN=$1
    local SCHEDULE=$2

    if [[ $RETAIN =~ ${SCHEDULE}=([0-9]{1,}) ]]; then
        echo ${BASH_REMATCH[1]}
    fi
}

# Quick hack to grab the required paramater from the output of the xe command
xe_param()
{
    local PARAM=$1

    while read DATA; do
        LINE=$(echo $DATA | egrep "$PARAM")
        if [ $? -eq 0 ]; then
            echo "$LINE" | awk 'BEGIN{ FS=": " } { print $2 }'
        fi
    done
}

# Deletes a snapshot's VDIs before uninstalling it. This is needed as
# snapshot-uninstall seems to sometimes leave "stray" VDIs in SRs
delete_snapshot()
{
    local SNAPSHOT_UUID=$1

    for VDI_UUID in $(xe vbd-list vm-uuid=$SNAPSHOT_UUID empty=false | \
        xe_param "vdi-uuid")
    do
        log "deleting snapshot VDI: $VDI_UUID"
        xe vdi-destroy uuid=$VDI_UUID
    done

    # Now we can remove the snapshot itself
    log "removing snapshot with UUID: $DELETE_SNAPSHOT_UUID"
    xe snapshot-uninstall uuid=$DELETE_SNAPSHOT_UUID force=true
}

# See above - templates also seem to leave stray VDIs around...
delete_template()
{
    local TEMPLATE_UUID=$1

    for VDI_UUID in $(xe vbd-list vm-uuid=$TEMPLATE_UUID empty=false | \
        xe_param "vdi-uuid")
    do
        log "deleting template VDI: $VDI_UUID"
        xe vdi-destroy uuid=$VDI_UUID
    done

    # Now we can remove the template itself
    log "removing template with UUID: $DELETE_TEMPLATE_UUID"
    xe template-uninstall template-uuid=$DELETE_TEMPLATE_UUID force=true
}

LOCKFILE=/tmp/snapback.lock

if [ -f $LOCKFILE ]; then
    log "lockfile $LOCKFILE exists, exiting!"
    exit 1
fi

touch $LOCKFILE

# Date format must be %Y%m%d so we can sort them
BACKUP_DATE=$(date +"%Y%m%d")

log "snapshot backup started"

# Get all running VMs
# todo: Need to check this works across a pool
RUNNING_VMS=$(xe vm-list power-state=running is-control-domain=false | \
    xe_param uuid)

for VM in $RUNNING_VMS; do
    VM_NAME="$(xe vm-list uuid=$VM | xe_param name-label)"

    log "backup for $VM_NAME started"
    log "retrieving backup paramaters"

    SCHEDULE=$(xe vm-param-get uuid=$VM param-name=other-config \
        param-key=XenCenter.CustomFields.backup)
    RETAIN=$(xe vm-param-get uuid=$VM param-name=other-config \
        param-key=XenCenter.CustomFields.retain)
	# Not using this yet, as there are some bugs to be worked out...
    QUIESCE=$(xe vm-param-get uuid=$VM param-name=other-config \
        param-key=XenCenter.CustomFields.quiesce)

    if [[ "$SCHEDULE" == "" || "$RETAIN" == "" ]]; then
        log "no schedule or retention set, skipping this VM"
        continue
    fi

    BACKUP_SCHEDULE=$(backup_schedule $SCHEDULE)

    if [ -z "$BACKUP_SCHEDULE" ]; then
        log "no schedule set, skipping this VM"
        continue
    fi

    RETAIN_NUMBER=$(retain_number $RETAIN $BACKUP_SCHEDULE)

    if [ -z "$RETAIN_NUMBER" ]; then
        log "no retain set, skipping this VM"
        continue
    fi

    BACKUP_SUFFIX="backup-${BACKUP_SCHEDULE}"

    log "VM backup schedule: $BACKUP_SCHEDULE ($SCHEDULE)"
    log "VM retention: $RETAIN_NUMBER previous snapshots ($RETAIN)"

    log "checking snapshots for $VM_NAME"
    VM_SNAPSHOT_CHECK=$(xe snapshot-list \
        name-label=$VM_NAME-$SNAPSHOT_SUFFIX | xe_param uuid)
    if [ "$VM_SNAPSHOT_CHECK" != "" ]; then
        log "found old backup snapshot: $VM_SNAPSHOT_CHECK, Deleting..."
        delete_snapshot $VM_SNAPSHOT_CHECK
    fi

    log "creating snapshot backup"

    # Select appropriate snapshot command
    # See above - not using this yet, as have to work around failures
    if [ "$QUIESCE" == "true" ]; then
       log "using VSS plugin"
       SNAPSHOT_CMD="vm-snapshot-with-quiesce"
    else
       log "not using VSS plugin, disks will not be quiesced"
       SNAPSHOT_CMD="vm-snapshot"
    fi

    SNAPSHOT_UUID=$(xe $SNAPSHOT_CMD vm="$VM_NAME" \
        new-name-label="$VM_NAME-$SNAPSHOT_SUFFIX")
    log "created snapshot with UUID: $SNAPSHOT_UUID"

    log "copying snapshot to SR"
    # Check there isn't a stale template with TEMP_SUFFIX name hanging
    # around from a failed job
    TEMPLATE_TEMP="$(xe template-list name-label="$VM_NAME-$TEMP_SUFFIX" | \
        xe_param uuid)"

    if [ "$TEMPLATE_TEMP" != "" ]; then
        log "found a stale temporary template, removing UUID $TEMPLATE_TEMP"
        delete_template $TEMPLATE_TEMP
    fi
    TEMPLATE_UUID=$(xe snapshot-copy uuid=$SNAPSHOT_UUID sr-uuid=$DEST_SR \
        new-name-description="Snapshot created on $(date)" \
        new-name-label="$VM_NAME-$TEMP_SUFFIX")

    log "removing temporary snapshot backup"
    delete_snapshot $SNAPSHOT_UUID

    # List templates for all VMs, grep for $VM_NAME-$BACKUP_SUFFIX
    # Sort -n, head -n -$RETAIN
    # Loop through and remove each one

    log "removing old backups"
    xe template-list | grep "$VM_NAME-$BACKUP_SUFFIX" | \
        xe_param name-label | sort -n | head -n-$RETAIN_NUMBER > $TEMP

    while read OLD_TEMPLATE
    do
        OLD_TEMPLATE_UUID=$(xe template-list name-label="$OLD_TEMPLATE" | \
            xe_param uuid)
        log "removing : $OLD_TEMPLATE with UUID $OLD_TEMPLATE_UUID"
        delete_template $OLD_TEMPLATE_UUID
    done < $TEMP

    # Also check there is no template with the current timestamp.
    # Otherwise, you would not be able to backup more than once a day if
    # you needed...
    TODAYS_TEMPLATE="$(xe template-list \
        name-label="$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE" | xe_param uuid)"
    if [ "$TODAYS_TEMPLATE" != "" ]; then
        log "found a template already for today, removing UUID $TODAYS_TEMPLATE"
        delete_template $TODAYS_TEMPLATE
    fi

    log "renaming template"
    xe template-param-set name-label="$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE" \
        uuid=$TEMPLATE_UUID

    log "backup for $VM_NAME finished"
done

xe vdi-list sr-uuid=$DEST_SR > /var/run/sr-mount/$DEST_SR/mapping.txt
xe vbd-list > /var/run/sr-mount/$DEST_SR/vbd-mapping.txt

log "snapshot backup finished"

[ -e $TEMP ] && rm $TEMP
rm $LOCKFILE
