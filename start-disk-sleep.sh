#!/bin/bash

DISK1=`ls -l /dev/disk/by-id/ata-ST2000DM006-2DM164_W4Z4JD2S | sed -e 's#.*\(sd.\)#\1#'`
DISK2=`ls -l /dev/disk/by-id/ata-ST3000DM001-1ER166_W502Y599 | sed -e 's#.*\(sd.\)#\1#'`
nohup bash /root/truenas-k3s-init/spindown_timer.sh -q -t 600 -p 600 -i $DISK1 -i $DISK2 &
nohup bash /root/truenas-k3s-init/spindown_timer.sh -q -t 1800 -p 600 -m -i $DISK1 -i $DISK2 &