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

if [ -s /etc/ha-lizard/ha-lizard.pool.conf ]
then
	source /etc/ha-lizard/ha-lizard.pool.conf	#global configuration parameters for all hosts in pool - dynamic for pool
else
	cat /etc/ha-lizard/scripts/install.params > /etc/ha-lizard/ha-lizard.pool.conf
fi

source /etc/ha-lizard/ha-lizard.init		#override configuration settings for this host - static for this host
source /etc/ha-lizard/ha-lizard.func

for input_param in ${@}
do
	log "initializing passed in parameter [$input_param]"
	eval $input_param
done
LOG_TERMINAL=${log_terminal:-false}
log "LOG_TERMINAL = [$LOG_TERMINAL]"

if [ ! -e /$STATE_PATH/time_day ]
then
	update_day
else
	DAY_CACHE=$(cat /$STATE_PATH/time_day)
	DAY_NOW=$(date +%e)
	if [ ${DAY_CACHE} -ne ${DAY_NOW} ]
	then
		update_day
	fi
fi

if [ ! -e /$STATE_PATH/time_hour ]
then
	update_hour
else
	HOUR_CACHE=$(cat /$STATE_PATH/time_hour)
	HOUR_NOW=$(date +%k)
	if [ ${HOUR_CACHE} -ne ${HOUR_NOW} ]
	then
		update_hour
		if [ ${DISK_MONITOR} -eq 1 ]
		then
			DISK_HEALTH_RESULT=$(${CHECK_DISK})
			RETVAL=$?
			if [ $RETVAL -ne 0 ]
			then
				log "Disk errors detected [${DISK_HEALTH_RESULT}]"
				email "[$HOUR_NOW] Disk errors detected [${DISK_HEALTH_RESULT}]"
			else
				log "Disk status OK [${DISK_HEALTH_RESULT}]"
			fi
		else
			log "[DISK_MONITOR] is disabled"
		fi
	fi
fi

if [ -d $MAIL_SPOOL ]
then
		log "Mail Spool Directory Found $MAIL_SPOOL"
else
		mkdir $MAIL_SPOOL
		if [ $? = 0 ]
		then
			log "Successfully created mail spool directory $MAIL_SPOOL"
		else
			log "Failed to create mail spool - not suppressing duplicate notices"
		fi
fi

if [ ! -f $MAIL_SPOOL/count ]
then
	touch $MAIL_SPOOL/count
	echo 0 > $MAIL_SPOOL/count
fi

CURRENT_COUNT=`cat $MAIL_SPOOL/count`

if [ $CURRENT_COUNT -gt 10000 ]
then
	log "Resetting iteration counter"
	echo 1 > $MAIL_SPOOL/count
	CURRENT_COUNT=0
fi

NEW_COUNT=$(($CURRENT_COUNT + 1))
log "This iteration is count $NEW_COUNT"
echo $NEW_COUNT > $MAIL_SPOOL/count

if [ -e /etc/xensource/pool.conf ]
then
	log "Checking if this host is a Pool Master or Slave"
	STATE=`/bin/cat /etc/xensource/pool.conf`
	log "This host's pool status = $STATE"
else
	log "/etc/xensource/pool.conf missing. Cannot determine master/slave status."
	email "/etc/xensource/pool.conf missing. Cannot determine master/slave status."
	exit 1
fi


if [ $STATE = "master" ]
then
	log "Checking if ha-lizard is enabled for this pool"
	check_ha_enabled
	case $? in
		0)
			log "ha-lizard is enabled"
			check_xs_ha
			if [ $? -ne 0 ]
			then
				log "ERROR - Detected alternate HA configured for pool- disabling HA-Lizard"
				email "ERROR - Detected alternate HA configured for pool- disabling HA-Lizard"
				disable_ha_lizard
				if [ $? -eq 1 ]
				then
					log "Conflicting High Availability detected - failed to disable HA-Lizard"
					email "Conflicting High Availability detected - failed to disable HA-Lizard"
				fi
				exit 1
			fi
           	;;
		1)
			log "ha-lizard is disabled"
			log "Calling autoselect_slave with ha disabled"
			autoselect_slave
			log "Updating state information"
			write_pool_state
			update_global_conf_params
			exit $?
			;;
		2)
			log "ha-lizard-enabled state unknown - exiting"
			exit 2
			;;
		3)
			log "ha-lizard is enabled but host is in maintenance mode"
			log "Updating state information"
			write_pool_state
			update_global_conf_params
			exit $?
			;;
		*)
			log "check_ha_enabled returned error: $? - exiting"
			exit $?
			;;
	esac
fi

update_global_conf_params


if [ $STATE = "master" ]
then

	MASTER_UUID=$($XE host-list hostname=$(hostname) --minimal)
	$XE host-param-set uuid=$MASTER_UUID other-config:XenCenter.CustomFields.$XC_FIELD_NAME="master"
	check_master_mgt_link_state
	RETVAL=$?
	if [ $RETVAL -eq 0 ]
	then
		log "Master management link OK - checking prior link state"
		if [ -e $STATE_PATH/master_mgt_down ]
		then
			log "Management link transitioned from DOWN -> UP"
			log "Master sleep for XAPI_COUNT [ $XAPI_COUNT ] [X] XAPI_DELAY [ $XAPI_DELAY ] + 10"
			MASTER_SLEEP=$(( $XAPI_COUNT * $XAPI_DELAY + 10 ))
			log "Delaying master execution [ $MASTER_SLEEP ] seconds"
			sleep $MASTER_SLEEP
			rm -f $STATE_PATH/master_mgt_down
			service_execute xapi restart
			exit 0
		fi
	else
		NOW=$(date +"%s")
		log "Master management link = DOWN"
		echo $NOW > $STATE_PATH/master_mgt_down
	fi

	MGT_LINK_STATE=$RETVAL
	while :
	do
		if [ $MGT_LINK_STATE -ne 0 ]
		then
			if [ ! $MGT_LINK_LOSS_TOLERANCE ]
			then
				log "MGT_LINK_LOSS_TOLERANCE not set - defauting to [ 5 ] seconds"
				MGT_LINK_LOSS_TOLERANCE=5
			fi

			TIME_NOW=$(date +"%s")
			TIME_FAILED=$(cat $STATE_PATH/master_mgt_down)
			TIME_ELAPSED=$(($TIME_NOW - $TIME_FAILED))
			log "TIMENOW = $TIME_NOW"
			log "TIMEFAILED = $TIME_FAILED"
			log "TIMEELAPSED = $TIME_ELAPSED"
			log "MGT link failure duration = [ $TIME_ELAPSED ] Tolerance = [ $MGT_LINK_LOSS_TOLERANCE seconds ]"
			if [ $TIME_ELAPSED -gt $MGT_LINK_LOSS_TOLERANCE ]
			then
				log "Management link outage tolerance [ ${MGT_LINK_LOSS_TOLERANCE} seconds ] reached - shutting down ALL VMs on Master [ $MASTER_UUID ]"
				check_replication_link_state
				RETVAL=$?
				if [ $RETVAL -eq 0 ]
				then
					stop_vms_on_host ${MASTER_UUID}
				elif [ $RETVAL -eq 1 ]
				then
					log "ABORTING VM SHUTDOWN: Replication network is connected!!"
				fi
				
			fi

			log "MGT link is down - waiting for link to be restored"
			sleep 5

			check_master_mgt_link_state
			MGT_LINK_STATE=$?
			if [ $MGT_LINK_STATE -eq 0 ]
			then
				log "MGT link has been restored"
				exit 0
			fi
		else
			break
		fi
	done

	log "This host detected as pool  Master"	
	
	NUM_HOSTS=$($XE host-list | grep "uuid ( RO)"| wc -l)
	if [ $? = 0 ]
	then
		log "Found $NUM_HOSTS hosts in pool"
	else
		log "Failed to find total number of hosts in pool"
	fi

	validate_vm_ha_state

	log "Calling function write_pool_state"
	write_pool_state &
	log "Calling function autoselect_slave"
	autoselect_slave &
	log "Calling function check_slave_status"
	check_slave_status
	
	case "$?" in 
		2)	
			log "Function check_slave_status Host Power = Off, calling vm_mon"
			vm_mon
			;;
		1)
			log "Function check_slave_status failed to fence failed host.. checking whether to attempt starting failed VMs"
			log "FENCE_HA_ONFAIL is set to: $FENCE_HA_ONFAIL"
			if [ $FENCE_HA_ONFAIL = "1" ]
			then
				log "FENCE_HA_ONFAIL is set to: $FENCE_HA_ONFAIL, calling vm_mon"
				vm_mon
			else
				log "FENCE_HA_ONFAIL is set to: $FENCE_HA_ONFAIL, not attempting to start VMs"	
			fi
			;;
		0)
			log "Function check_slave_status reported no failures: calling vm_mon"
			vm_mon
			$ECHO "0" > $STATE_PATH/rebooted
			;;
		*)
			log "Calling function vm_mon"
			vm_mon
			$ECHO "0" > $STATE_PATH/rebooted
			;;
	esac
fi

if [[ $STATE == slave* ]]
then

	if [ -e $STATE_PATH/fenced_slave ]
	then
		log "This host has self fenced - scheduling  host health check..."
		THIS_HOST_HAS_SELF_FENCED=true
	else
		THIS_HOST_HAS_SELF_FENCED=false
	fi

	master_ip $STATE

	log "Validating master is still a master"
	VALIDATE_MASTER_EXEC="${TIMEOUT} 1 ${HOST_IS_SLAVE} ${MASTER_IP}"
	log "[ $VALIDATE_MASTER_EXEC ]"
	VALIDATE_MASTER=$(${VALIDATE_MASTER_EXEC})
	RETVAL=$?
	if [ $RETVAL -eq 0 ]
	then
		if [ "${VALIDATE_MASTER}" = "HOST_IS_SLAVE" ]
		then
			log "MAJOR ERROR - pool master [ $MASTER_IP ] reports it is a slave"
			MY_HOST_UUID=$(cat $STATE_PATH/local_host_uuid)
			NEW_MASTER_UUID=$(head -n 1 $STATE_PATH/host_uuid_ip_list | awk -F ':' {'print $1'})
			if [ "${NEW_MASTER_UUID[@]}" = "${MY_HOST_UUID}" ]
			then
				log "Calling promote slave for UUID [ $NEW_MASTER_UUID ]"
				promote_slave
			fi
		fi
	fi	

	if [ -e $STATE_PATH/autopromote_uuid ]
	then
		THIS_SLAVE_UUID=`$CAT $STATE_PATH/local_host_uuid`
		AUTOPROMOTE_UUID=`$CAT $STATE_PATH/autopromote_uuid`
		if [ "$THIS_SLAVE_UUID" = "$AUTOPROMOTE_UUID" ]
		then
			log "This slave - $HOST: $THIS_SLAVE_UUID selected as allowed to become master: setting ALLOW_PROMOTE_MASTER=1"
			ALLOW_PROMOTE_SLAVE=1
		else
			log "This slave- $HOST: $THIS_SLAVE_UUID not permitted to become master"
		fi
		
	else
		log "Missing file - $STATE_PATH/autopromote_uuid - cannot validate autopromote_status"
		email "Missing file - $STATE_PATH/autopromote_uuid - cannot validate autopromote_status"
		THIS_SLAVE_UUID=
	fi
	

	if check_xapi $MASTER_IP
	then

		if [ "$THIS_HOST_HAS_SELF_FENCED" = "true" ]
		then
			log "Checking host health to clear suspended HA mode"
			THIS_SLAVE_HEALTH_STATUS=$($XE host-param-get uuid=$THIS_SLAVE_UUID param-name=other-config param-key=XenCenter.CustomFields.$XC_FIELD_NAME)
			if [ "$THIS_SLAVE_HEALTH_STATUS" != "healthy" ]
			then
				log "This host health status = [ $THIS_SLAVE_HEALTH_STATUS ] and host is in suspended HA mode. Exiting.."
				exit 0
			else
				log "This host health status = [ $THIS_SLAVE_HEALTH_STATUS ] - removing HA Suspension"
				rm -f $STATE_PATH/fenced_slave
			fi
		fi

		validate_this_host_vm_states

		log "Pool Master is OK - calling function check_ha_enabled - updating local status"
		check_ha_enabled
		if [ $? = "0" ]
		then
			$ECHO true > $STATE_PATH/ha_lizard_enabled
		else
			$ECHO false > $STATE_PATH/ha_lizard_enabled
		fi

		log "Checking state file for status if ha-lizard is enabled"
		if [ -e "$STATE_PATH/ha_lizard_enabled" ]
		then
			log "Statefile $STATE_PATH/ha_lizard_enabled found: checking if ha-lizard is enabled"
			ha_lizard_STAT=$($CAT $STATE_PATH/ha_lizard_enabled)
			if [ "$ha_lizard_STAT" = "true" ]
			then
				log "ha-lizard is enabled - continuing"
				check_xs_ha
				if [ $? -ne 0 ]
				then
					log "ERROR - Detected alternate HA configured for pool"
					exit 1
				fi	
			else
				log "ha-lizard is disabled - exiting"
				log "Updating state information"
				write_pool_state
				exit 0
			fi
		fi
		
		log "Calling Function write_pool_state - updating local state files"
		write_pool_state &
		
		if [ $SLAVE_VM_STAT -eq "1" ]
		then
			log "Calling Function vm_mon - check if any VMs need to be started"
			vm_mon
		fi
	else
		if [ "$THIS_HOST_HAS_SELF_FENCED" = "true" ]
		then
			log "Host has self fenced and cannot reach master - exiting"
		fi

		log "Pool Master NOT OK - Checking if ha-lizard is enabled in latest state file"
		log "Checking if ha-lizard is enabled"
		if [ -e "$STATE_PATH/ha_lizard_enabled" ]
		then
			log "Statefile $STATE_PATH/ha_lizard_enabled found: checking if ha-lizard is enabled"
			ha_lizard_STAT=$($CAT $STATE_PATH/ha_lizard_enabled)
			if [ "$ha_lizard_STAT" = "true" ]
			then
				log "ha-lizard is enabled - continuing"
			else
				log "ha-lizard is disabled - exiting"
				exit 0
			fi
		fi

		log "Pool Master Monitor = Failed"
		email "Server $HOSTNAME: Failed to contact pool master - manual intervention may be required"
		log "Retry Count set to $XAPI_COUNT. Retrying $XAPI_COUNT times in $XAPI_DELAY second intervals.."
		COUNT=0 #reset loop counter

		while [ $COUNT -lt $XAPI_COUNT ]
		do
			log "Attempt $COUNT: Checking Pool Master Status"
			COUNT=$((COUNT+1))
			sleep $XAPI_DELAY
			
			if check_xapi $MASTER_IP
			then
				log "Pool Master Communication Restored"
				break
			else
				if [ $COUNT = $XAPI_COUNT ]
				then
					if [ -e $STATE_PATH/pool_num_hosts ]
					then
						NUM_HOSTS=`$CAT $STATE_PATH/pool_num_hosts`
						log "Retrieving number of hosts in pool. Setting NUM_HOSTS = $NUM_HOSTS"
					else
						log "ERROR Retrieving number of hosts in pool. Setting NUM_HOSTS = UNKNOWN"
					fi
					
					log "Failed to reach Pool Master - Checking if this host promotes to Master.."
					
					if [[ $PROMOTE_SLAVE = "1" ]] && [[ $ALLOW_PROMOTE_SLAVE = "1" ]]	
					then
						MASTER_UUID=`$CAT $STATE_PATH/master_uuid`
						log "State file MASTER UUID = $MASTER_UUID"

						if [ $FENCE_ENABLED = "1" ]
						then
							fence_host $MASTER_UUID stop
							RETVAL=$?
							log "Function fence_host returned status $RETVAL"	
							case $RETVAL in
								0)
									log "Master: $MASTER_UUID successfully fenced, attempting to start any failed VMs"
									log "Promote Slave enabled for this host. Calling promote_slave - attempt to become pool master"
									promote_slave
									RETVAL=$?
									if [ $RETVAL -eq 0 ]
									then
										log "New Master ha_enabled check"
										POOL_UUID=`xe pool-list --minimal`
										DB_HA_STATE=$(xe pool-param-get uuid=$POOL_UUID param-name=other-config param-key=XenCenter.CustomFields.$XC_FIELD_NAME)
										if [ "$DB_HA_STATE" = "false" ]
										then
											log "This host just became master - re-enabling HA"
											xe pool-param-set uuid=$POOL_UUID other-config:XenCenter.CustomFields.$XC_FIELD_NAME=true
											RETVAL=$?
											if [ $RETVAL -eq 0 ]
											then
												log "HA returned to enabled state"
											else
												log "Error returning HA to enabled state"
											fi
										fi
									else
										log "Failed to promote slave - Pool master must be manually recovered!"
										email "Failed to promote slave - Pool master must be manually recovered!"
										exit 1
									fi
									;;
								1)
									log "Failed to fence Master: $MASTER_UUID. Checking whether FENCE_HA_ONFAIL is enabled"
									if [ "$NUM_HOSTS" -gt 1 ]
									then
										log "Marking this host as fenced, Rebooting this host now!"
										log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!! SELF FENCING - REBOOT HERE !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
										> $STATE_PATH/fenced_slave
										sync && $ECHO b > /proc/sysrq-trigger
									else
										log "Pool number of hosts detected as: $NUM_HOSTS - no further action"
									fi

									;;
								2)
									log "---------------------------- A L E R T -----------------------------"
									log "2 host noSAN pool validation has failed. This pool is a 2 node pool with hyperconverged"
									log "storage and the storage network between hosts is still conncted. All fencing actions"
									log "will be blocked while the storage network remains connected."
									log "---------------------------- A L E R T -----------------------------"
									exit 101
									;;
							esac
						fi


						log "Retrieving list of VMs on failed master from local state file host.$MASTER_UUID.vmlist.uuid_array"
						FAILED_VMLIST=(`$CAT $STATE_PATH/host.$MASTER_UUID.vmlist.uuid_array`)

						for c in ${FAILED_VMLIST[@]}
						do
							log "Resetting Power State for VM: $c"
							$XE vm-reset-powerstate uuid=$c --force
							
							if [ $? = 0 ]
							then
								log "Power State for uuid: $c set to: halted"
							else
								log "Error resetting power state for VM UUID: $c"
							fi
						done
						
						RESET_IFS=$IFS
						IFS=","
						for v in `$XE pbd-list host-uuid=$MASTER_UUID --minimal`
						do
							log "Resetting VDI: $v on host: $MASTER_UUID"
							STORE=`$XE pbd-param-get uuid=$v param-name=sr-uuid`
							$RESET_VDI $MASTER_UUID $STORE
							if [ $? = "0" ]
							then
								log "Resetting VDI: $v Success!"
							else
								log "Resetting VDI: $v ERROR!"
							fi
						done
						IFS=$RESET_IFS

						if [ $SLAVE_HA = 1 ]
						then
							log "Slave HA is ON, Master is unreachable  - Checking for VMs or appliances to start in this pool"
							sleep 5
							vm_mon
						else
							log "Slave HA is OFF, Master is unreachable  - Not Attempting Restore - Manual Intervention Needed"	
						fi
					else
						log "PROMOTE_SLAVE = [$PROMOTE_SLAVE] and ALLOW_PROMOTE_SLAVE = [$ALLOW_PROMOTE_SLAVE] - Not Promoting this host - Manual Intervention Needed"
					fi
				fi
			fi
		done
	fi
fi
