#!/bin/ksh -p
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright 2008 Sun Microsystems, Inc.  All rights reserved.
# Use is subject to license terms.
#

#
# Copyright (c) 2012, 2015 by Delphix. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/inuse/inuse.cfg

#
# DESCRIPTION:
# ZFS will not interfere with devices that are in use by ufsdump or
# ufsrestore.
#
# STRATEGY:
# 1. newfs a disk
# 2. mount the disk
# 3. create files and dirs on disk
# 4. umount the disk
# 5. ufsdump this disk to a backup disk
# 6. Try to create a ZFS pool with same disk (also as a spare device)
# 7. ufsrestore the disk from backup
# 8. try to create a zpool during the ufsrestore
#

verify_runnable "global"

function cleanup
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1

	poolexists $TESTPOOL2 && destroy_pool $TESTPOOL2

	log_note "Kill off ufsdump process if still running"
	$KILL -0 $PIDUFSDUMP > /dev/null 2>&1 && \
	    log_must $KILL -9 $PIDUFSDUMP  > /dev/null 2>&1
	#
	# Note: It would appear that ufsdump spawns a number of processes
	# which are not killed when the $PIDUFSDUMP is whacked.  So best bet
	# is to find the rest of the them and deal with them individually.
	#
	for all in `$PGREP ufsdump`
	do
		$KILL -9 $all > /dev/null 2>&1
	done

	log_note "Kill off ufsrestore process if still running"
	$KILL -0 $PIDUFSRESTORE > /dev/null 2>&1 && \
	    log_must $KILL -9 $PIDUFSRESTORE  > /dev/null 2>&1

	ismounted $UFSMP ufs && log_must $UMOUNT $UFSMP

	$RM -rf $UFSMP
	$RM -rf $TESTDIR

	#
	# Tidy up the disks we used.
	#
	log_must cleanup_devices $vdisks $sdisks
}

log_assert "Ensure ZFS does not interfere with devices that are in use by " \
    "ufsdump or ufsrestore"

log_onexit cleanup

typeset bigdir="${UFSMP}/bigdirectory"
typeset restored_files="${UFSMP}/restored_files"
typeset -i dirnum=0
typeset -i filenum=0
typeset cwd=""

for num in 0 1 2; do
	eval typeset slice=\${FS_SIDE$num}
	disk=${slice%s*}
	slice=${slice##*${SLICE_PREFIX}}
	log_must set_partition $slice "" $FS_SIZE $disk
done

log_note "Make a ufs filesystem on source $rawdisk1"
$ECHO "y" | $NEWFS -v $rawdisk1 > /dev/null 2>&1
(($? != 0)) && log_untested "Unable to create ufs filesystem on $rawdisk1"

log_must $MKDIR -p $UFSMP

log_note "mount source $disk1 on $UFSMP"
log_must $MOUNT $disk1 $UFSMP

log_note "Now create some directories and files to be ufsdump'ed"
while (($dirnum <= 2)); do
	log_must $MKDIR $bigdir${dirnum}
	while (( $filenum <= 2 )); do
		$FILE_WRITE -o create -f $bigdir${dirnum}/file${filenum} \
		    -b $BLOCK_SIZE -c $BLOCK_COUNT
		if [[ $? -ne 0 ]]; then
			if [[ $dirnum -lt 3 ]]; then
				log_fail "$FILE_WRITE only wrote" \
				    "<(( $dirnum * 3 + $filenum ))>" \
				    "files, this is not enough"
			fi
		fi
		((filenum = filenum + 1))
	done
	filenum=0
	((dirnum = dirnum + 1))
done

log_must $UMOUNT $UFSMP

log_note "Start ufsdump in the background"
log_note "$UFSDUMP 0bf 512 $rawdisk0 $disk1"
$UFSDUMP 0bf 512 $rawdisk0 $disk1 &
PIDUFSDUMP=$!

unset NOINUSE_CHECK
log_note "Attempt to zpool the source device in use by ufsdump"
log_mustnot $ZPOOL create $TESTPOOL1 "$disk1"
log_mustnot poolexists $TESTPOOL1

log_note "Attempt to take the source device in use by ufsdump as spare device"
log_mustnot $ZPOOL create $TESTPOOL1 "$FS_SIDE2" spare "$disk1"
log_mustnot poolexists $TESTPOOL1

wait $PIDUFSDUMP
typeset -i retval=$?
(($retval != 0)) && log_fail "$UFSDUMP failed with error code $ret_val"

log_must $MOUNT $disk1 $UFSMP

log_must $RM -rf $UFSMP/*
log_must $MKDIR $restored_files

cwd=$PWD
log_must cd $restored_files
log_note "Start ufsrestore in the background from the target device"
log_note "$UFSRESTORE rbf 512 $rawdisk0"
$UFSRESTORE rbf 512 $rawdisk0 &
PIDUFSRESTORE=$!
log_must cd $cwd

log_note "Attempt to zpool the restored device in use by ufsrestore"
log_mustnot $ZPOOL create -f $TESTPOOL2 "$disk1"
log_mustnot poolexists $TESTPOOL2

log_note "Attempt to take the restored device in use by ufsrestore as spare" \
    "device"
log_mustnot $ZPOOL create -f $TESTPOOL2 "$FS_SIDE2" spare "$disk1"
log_mustnot poolexists $TESTPOOL2

log_pass "Unable to zpool over a device in use by ufsdump or ufsrestore"
