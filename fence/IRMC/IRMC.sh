#!/bin/bash
##################################
# HA-Lizard version 2.3.3
##################################
#################################################################################################
#
# HA-Lizard - Open Source High Availability Framework for Xen Cloud Platform and XenServer
#
# Copyright Salvatore Costantino
# ha@pulsesupply.com
#
# This file is part of HA-Lizard.
#
#    HA-Lizard is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    HA-Lizard is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with HA-Lizard.  If not, see <http://www.gnu.org/licenses/>.
#
##################################################################################################

exec 2>/dev/null
source /etc/ha-lizard/ha-lizard.init
source /etc/ha-lizard/ha-lizard.func

log "fence_host: IRMC Searching for IP address for host: $1"
HOST_IP=`(cat $FENCE_FILE_LOC/$FENCE_METHOD/$FENCE_METHOD.hosts | grep $1 | awk -F ":" '{print $2}')`
if [ $? = "0" ] ; then
    log "fence_host: IRMC IP Address for host: $1 found: $HOST_IP"
    log "fence_host: IRMC Checking if fencing interface can be reached"
    ping -c 1 $HOST_IP > /dev/null
    if [ $? = "0" ] ; then
	log "fence_host: IRMC Host fence port on $HOST_IP response = OK"
	log "fence_host: IRMC Fence $HOST_IP -  TCL/SSH connection start"
	rm -f $FENCE_FILE_LOC/$FENCE_METHOD/irmc_fence.out
	case $2 in
	    start)
		MSG=`$FENCE_FILE_LOC/$FENCE_METHOD/irmc_start.tcl $HOST_IP admin $FENCE_PASSWD`
		;;
	    stop)
		MSG=`$FENCE_FILE_LOC/$FENCE_METHOD/irmc_stop.tcl $HOST_IP admin $FENCE_PASSWD`
		;;
	    reset)
		MSG=`$FENCE_FILE_LOC/$FENCE_METHOD/irmc_reset.tcl $HOST_IP admin $FENCE_PASSWD`
		;;
	esac
		
        log "fence_host: IRMC TCL Session exit message: $MSG"
        log "fence_host: IRMC Checking power state of $1, IRMC: $HOST_IP"
        
        POWER_STATE=`$FENCE_FILE_LOC/$FENCE_METHOD/irmc_powerstate.tcl $HOST_IP admin $FENCE_PASSWD`

	log "fence_host: IRMC Server Power = $POWER_STATE"

        if [[ "$POWER_STATE" == "Off" ]] ; then
     	    IRMC_SERVER_POWER=0
	    exit 0
	fi

        if [[ "$POWER_STATE" == "On" ]] ; then
     	    IRMC_SERVER_POWER=1
	    exit 1
	else
	    log "fence_host: IRMC error cheking power state msg=$POWER_STATE"
	    exit 1
	fi
	
    else

	log "fence_host: IRMC interface not responding to ping request.Server is down!"
	exit 0

    fi
else

    log "fence_host: IRMC interface IP address check failed."
    exit 1

fi
