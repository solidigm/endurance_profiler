#!/bin/bash
# Copyright 2021 Solidigm.
# SPDX-License-Identifier: BSD-3-Clause

# User configurable variables
_db=console
_nc_graphite_destination=localhost
_nc_graphite_port=2003

# Script variables, do not modify
_version="v1.2-rc"
_service="$0"
# remove any leading directory components and .sh 
_filename=$(basename "${_service}" .sh)

_logfile=/var/log/${_filename}/${_filename}.log
_pidfile=/tmp/${_filename}.pid
_WAFfile=/var/log/${_filename}/${_filename}.WAF.var
_nvme_namespacefile=/var/log/${_filename}/${_filename}.nvmenamespace.var
_VUsmart_F4_beforefile=/var/log/${_filename}/${_filename}.F4_before.var
_VUsmart_F5_beforefile=/var/log/${_filename}/${_filename}.F5_before.var
_timed_work_load_startedfile=/var/log/${_filename}/${_filename}.timed_work_load_started.var
_db_not_supported="not logged"

_TB_in_bytes=1000000000000
_host_written_unit=32000000
_bandwith_blocksize=512
_minutes_in_day=1440

function check_command() {
	# Iterate over all function arguments and check if each argument is an installed command
	while [ $# -gt 0 ] ; do
		# check if a passed argument is an installed command
		if ! command -v "$1" &> /dev/null ; then
			log "[CHECKCOMMAND] Command $1 could not be found"
			# exit the script with error code 1 
			exit 1
		fi
		shift
	done
	return 0
}

function check_nvme_namespace() {
	# Fuction returns true if argument is an existing nvme device namespace
	# argument 1: a namespace
	local _nvme_namespace=$1
	local _ret

	if [[ ${_nvme_namespace} =~ ^nvme[0-9]+n[0-9]+$ ]] ; then
		_ret=$(nvme list 2>/dev/null  | grep "${_nvme_namespace}" 2>&1 >/dev/null)
		# assign the return value of grep to the varialbe ret
		_ret=$?
		if [[ ${_ret} -eq 0 ]] ; then
			# grep returned 0 as it found ${_nvme_namespace}
			log "[CHECKNVMENAMESPACE] nvme device ${_nvme_namespace} exists"
		elif [[ ${_ret} -eq 1 ]] ; then
			# grep returned 1 as it did not find ${_nvme_namespace}
			log "[CHECKNVMENAMESPACE] nvme device does not exist"
			return 1
		else
			log "[CHECKNVMENAMESPACE] grep returned error"
			return 1
		fi
	else
		log "[CHECKNVMENAMESPACE] Bad device name"
		return 1
	fi
	return 0
}

function send_to_db() {
	# Function will send to content of the argument to a database as configured in the global variable _db
	# Supported databases defined in _db
	#	graphite
	#	logfile
	# argument 1: data to be sent
	local _data=$1

	if [ "${_db}" = "graphite" ] ; then
		# send the data to the graphite port and destination
		echo "${_data}" | nc -N ${_nc_graphite_destination} ${_nc_graphite_port}
	elif [ "${_db}" = "logfile" ] ; then
		# send the data the log file
		echo "${_data}"
	elif [ "${_db_not_supported}" != "logged" ] ; then
		# variable _db does not contain a supported database
		# send once the the error to the log file
		_db_not_supported="logged"
		log "[SENDTODB] ${_db} as database is not supported"
	fi
	return 0
}

function get_smart_log() {
	# Function will return the smart log info for the nvme device at an offset
	# argument 1: nvme device
	# argument 2: offset 
	local _local_nvme_namespace=$1
	local _offset=$2
	local _rev_vusmart_hexadecimal

	# get Vendor Unique smart attributes in binary format, get 6 bytes from possition _offset and remove position.
	_vusmart_hexadecimal=$(nvme intel smart-log-add /dev/"${_local_nvme_namespace}" -b | xxd -l 6 -seek "${_offset}" | cut -c 11-19 | sed 's/ //g')
	# reverse the varialbe _vusmart_hexadecimal
	len=${#_vusmart_hexadecimal}
	for((i=len;i>=0;i=i-2)); do _rev_vusmart_hexadecimal="$_rev_vusmart_hexadecimal${_vusmart_hexadecimal:$i:2}"; done
	# convert _vusmart_hexadecimal to capital letter, convert to decimal and remove leading zeros
	_vusmart_decimal=$(echo "ibase=16;${_rev_vusmart_hexadecimal^^}" | bc )
	echo "${_vusmart_decimal}"
	return 0
}

function loop() {
	local _counter=0
	local _hostWrites=1
	local _nandWrites=0
	local _read_bandwidth=0
	local _write_bandwidth=0
	local _readblocks_old=0
	local _writeblocks_old=0
	local _readblocks_new=0
	local _writeblocks_new=0
	local _nvme_namespace=$1

	_tnvmcap=$(nvme id-ctrl /dev/"${_nvme_namespace}" 2>stderr | grep tnvmcap | awk '{print $3}')

	echo "${_service} ${_version}"
	echo "date, media_wear_percentage, host_reads, timed_work_load, NAND_bytes_written, host_bytes_written, WAF, temperature, percentage_used, drive_life_minutes, DWPD, dataWritten"

	eval "$(awk '{printf "_readblocks_old=\"%s\" _writeblocks_old=\"%s\"", $3 ,$7}' < /sys/block/"${_nvme_namespace}"/stat)"
	while true; do
		if ! ((_counter % 60)) ; then
			# this block will run every minute
			_VUsmart_E2=$(get_smart_log "${_nvme_namespace}" 0x41)
			_VUsmart_E3=$(get_smart_log "${_nvme_namespace}" 0x4d)
			_VUsmart_E4=$(get_smart_log "${_nvme_namespace}" 0x59)
			_VUsmart_F4=$(get_smart_log "${_nvme_namespace}" 0x89)
			_VUsmart_F5=$(get_smart_log "${_nvme_namespace}" 0x95)
			_media_wear_percentage=$(echo "scale=3;${_VUsmart_E2}/1024" | bc -l)
			send_to_db "smart.media_wear_percentage ${_media_wear_percentage} $(date +%s)"
			send_to_db "smart.host_reads ${_VUsmart_E3} $(date +%s)"
			send_to_db "smart.timed_work_load ${_VUsmart_E4} $(date +%s)"
			_VUsmart_F4_before=$(cat "${_VUsmart_F4_beforefile}")
			_VUsmart_F5_before=$(cat "${_VUsmart_F5_beforefile}")
			if [[ "${_VUsmart_F4_before}" -eq 0 ]]; then
				_VUsmart_F4_before=${_VUsmart_F4}
				echo "${_VUsmart_F4_before}" > "${_VUsmart_F4_beforefile}"
				_VUsmart_F5_before=${_VUsmart_F5}
				echo "${_VUsmart_F5_before}" > "${_VUsmart_F5_beforefile}"
			fi
			if [[ "${_VUsmart_F5}" -eq "${_VUsmart_F5_before}" ]] ; then
				_hostWrites=1
				_nandWrites=0
			else
				_hostWrites=${_VUsmart_F5}-${_VUsmart_F5_before}
				_nandWrites=${_VUsmart_F4}-${_VUsmart_F4_before}
			fi
			_WAF=$(echo "scale=2;(${_nandWrites})/(${_hostWrites})" | bc -l)
			send_to_db "smart.write_amplicifation_factor ${_WAF} $(date +%s)"
			echo "${_WAF}" > "${_WAFfile}"
			# log host write bytes
			send_to_db "smart.host_bytes_written $(echo "${_VUsmart_F5}*32" | bc -l) $(date +%s)"
			# log smart attributes
			_temperature=$(nvme smart-log /dev/"${_nvme_namespace}" 2>stderr | grep temperature | awk '{print $3}' | sed 's/[^0-9]*//g')
			send_to_db "smart.temperature ${_temperature} $(date +%s)"
			_percentage_used=$(nvme smart-log /dev/"${_nvme_namespace}" 2>stderr | grep percentage_used | awk '{print $3}' | sed 's/[^0-9]*//g')
			send_to_db "smart.percentage_used ${_percentage_used} $(date +%s)"
			_drive_life_minutes=$(echo "scale=0;${_VUsmart_E4}*100*1024/${_VUsmart_E2}" | bc -l)
			send_to_db "smart.drive_life ${_drive_life_minutes} $(date +%s)"
			_DWPD=$(echo "scale=2;((${_VUsmart_F5}-${_VUsmart_F5_before})*${_host_written_unit}*${_minutes_in_day}/${_VUsmart_E4})/${_tnvmcap}" | bc -l)
			send_to_db "smart.DWPD ${_DWPD} $(date +%s)"
			_dataWritten=$(echo "scale=0;(${_hostWrites})*${_host_written_unit}" | bc -l)
			send_to_db "smart.dataWritten ${_dataWritten} $(date +%s)"

			echo "$(date +%s), ${_VUsmart_E2}, ${_VUsmart_E3}, ${_VUsmart_E4}, ${_VUsmart_F4}, ${_VUsmart_F5}, ${_WAF}, ${_temperature}, ${_percentage_used}, ${_drive_life_minutes}, ${_DWPD}, ${_dataWritten}"
			_counter=0
		fi
		# this block will run every second
		eval "$(awk '{printf "_readblocks_new=\"%s\" _writeblocks_new=\"%s\"", $3 ,$7}' < /sys/block/"${_nvme_namespace}"/stat)"
		_read_bandwidth=$(echo "(${_readblocks_new}-${_readblocks_old})*${_bandwith_blocksize}/1000/1000" | bc)
		_write_bandwidth=$(echo "(${_writeblocks_new}-${_writeblocks_old})*${_bandwith_blocksize}/1000/1000" | bc)
		_readblocks_old=${_readblocks_new}
		_writeblocks_old=${_writeblocks_new}

		# add read and write bandwidth to TimeSeriesDataBase
		send_to_db "nvme.readBW ${_read_bandwidth} $(date +%s)"
		send_to_db "nvme.writeBW ${_write_bandwidth} $(date +%s)"

		_counter=$(( _counter + 1 ))
		sleep 1
	done
	return 0
}

function log() {
	echo "$*"
	return 0
}

function retrieve_pid() {
	# echo the process id of the running background process
	# if not running echo 0 as 0 is an invalid pid
	local _pid

	if [ -s "${_pidfile}" ] ; then
		# file ${_pid} is not empty
		_pid=$(cat "${_pidfile}")
		if ps -p "${_pid}" > /dev/null 2>&1 ; then 
			# ${_pid} is running process
			echo "${_pid}"
		else
			# ${_pid} is not a process id or not a ruunning process
			echo 0
		fi
	else
		# file ${_pid} is empty
		echo 0
	fi
	return 0
}

function retrieve_nvme_namespace() {
	# echo the namespace reriteved from the file ${_nvme_namespacefile}
	# only returns the namespace when it exists in the system 
	# if an error found retrun an empty string
	if [ -s "${_nvme_namespacefile}" ] ; then
		# the file ${_nvme_namespacefile} exists
		_nvme_namespace=$(cat "${_nvme_namespacefile}")
		if [[ ${_nvme_namespace} =~ ^nvme[0-9]+n[0-9]+$ ]] ; then
			_ret=$(nvme list 2>/dev/null  | grep "${_nvme_namespace}" 2>&1 >/dev/null)
			# assign the return value of grep to the varialbe ret
			_ret=$?
			if [[ ${_ret} -eq 0 ]] ; then
			# grep returned 0 as it found ${_nvme_namespace}
				echo "${_nvme_namespace}"
			elif [[ ${_ret} -eq 1 ]] ; then
				# grep returned 1 as it did not find ${_nvme_namespace}
				echo ""
			else
				# grep return an error
				echo ""
			fi
		else
			echo ""
		fi
	else
		# the file ${_nvme_namespacefile} does not exists
		echo ""
	fi

	return 0
}

function status() {
	local _pid
	
	_pid=$(retrieve_pid)

	if [[ "${_pid}" -gt 0 ]] ; then
		# background process running
		log "[STATUS] Service ${_service} with pid=${_pid} running"
		return 0
	else
		# background process not running
		log "[STATUS] Service ${_service} not running"
		return 1
	fi
}

function start() {
	local _pid
	local _nvme_namespace
	
	if status >/dev/null 2>&1 ; then
		# background process running
		_pid=$(retrieve_pid)
		log "[START] ${_service} with pid ${_pid} is already running"
	else
		# background process not running
		if [ -s "${_nvme_namespacefile}" ] ; then
			_nvme_namespace=$(retrieve_nvme_namespace)
			if [ "${_nvme_namespace}" == "" ] ; then
				log "[START] Invalid nvme namespace parameter."
				return 1
			else
				log "[START] Logging namespace ${_nvme_namespace}. Log filename ${_logfile}"
				log "[START} ${_nvme_namespacefile} exists and namespace=${_nvme_namespace}"
				if [ -s "${_VUsmart_F4_beforefile}" ] ; then
					_VUsmart_F4_before=$(cat "${_VUsmart_F4_beforefile}")
				else
					_VUsmart_F4_before=0
					echo ${_VUsmart_F4_before} > "${_VUsmart_F4_beforefile}"
				fi

				if [ -s "${_VUsmart_F5_beforefile}" ] ; then
					_VUsmart_F5_before=$(cat "${_VUsmart_F5_beforefile}")
				else
					_VUsmart_F5_before=0
					echo ${_VUsmart_F5_before} > "${_VUsmart_F5_beforefile}"
				fi

				(loop "${_nvme_namespace}" >> "${_logfile}" 2>>"${_logfile}") &
				# write process id to file
				echo $! > "${_pidfile}"

				# check if backgournd process is running
				if ! status ; then 
					log "[START] ${_service} failed to start"
					rm "${_pidfile}"
					return 1
				fi
			fi
		else
			log "[START] ${_nvme_namespacefile} is empty"
			log "[START] Not started, need to set device first"
			log "[START] e.g. $_service setDevice nvme0n1"
			return 1
		fi
	fi
	return 0
}

function stop() {
	local _pid
	
	_pid=$(retrieve_pid)

	if [[ "${_pid}" -gt 0 ]] ; then
		# background process running
		log "[STOP] Stopping ${_service} with pid=${_pid}"
		kill "${_pid}"
		log "[STOP] kill signal sent to pid=${_pid}"
		rm "${_pidfile}"
		return 0
	else
		# ${_pid} is 0, no background process running
		log "[STOP] Service ${_service} not running"
		return 1
	fi
}

function restart() {
	stop
	start
	return 0
}

function resetWorkloadTimer() {
	local _nvme_device
	local _nvme_namespace
	
	if status >/dev/null 2>&1 ; then
		# background process running
		_nvme_namespace=$(retrieve_nvme_namespace)
		if [ "${_nvme_namespace}" == "" ] ; then
			log "[RESETWORKLOADTIMER] Invalid nvme namespace parameter. Workload Timer not reset."
			return 1
		fi
		_nvme_device=${_nvme_namespace/%n[0-9]*/} 
		nvme set-feature -f 0xd5 -v 1 /dev/"${_nvme_device}" > /dev/null 2>&1
		log "[RESETWORKLOADTIMER] Workload Timer Reset on ${_nvme_device} at $(date)"

		echo 0 > "${_VUsmart_F4_beforefile}"
		echo 0 > "${_VUsmart_F5_beforefile}"
		echo 0 > "${_WAFfile}"
		date > "${_timed_work_load_startedfile}"
		return 0
	else	
		# background process not running
		log "[RESETWORKLOADTIMER] ${_service} is not running. Workload Timer not reset."
		return 1
	fi
}

function WAFinfo() {
	local _nvme_namespace
	local _WAF
	local _market_name
	local _serial_number
	local _tnvmcap
	local _VUsmart_E2
	local _VUsmart_E3
	local _VUsmart_E4
	local _media_wear_percentage
	local _firmware
	local _VUsmart_F5_before
	local _VUsmart_F5
	local _hostWrites=0
	local _dataWritten=0
	local _dataWrittenTB=0

	if status >/dev/null 2>&1 ; then
		# background process running
		_nvme_namespace=$(retrieve_nvme_namespace)
		if [ "${_nvme_namespace}" == "" ] ; then
			log "[WAFINFO] Invalid nvme namespace parameter."
			return 1
		fi
		_WAF=$(cat "${_WAFfile}")
		_market_name="$(nvme get-log /dev/"${_nvme_namespace}" -i 0xdd -l 0x512 -b 2>&1 | tr -d '\0')"
		_serial_number=$(nvme id-ctrl /dev/"${_nvme_namespace}" 2>stderr | grep sn | awk '{print $3}')
		_firmware=$(nvme id-ctrl /dev/"${_nvme_namespace}" 2>stderr | grep "fr " | awk '{print $3}')
		_tnvmcap=$(nvme id-ctrl /dev/"${_nvme_namespace}" 2>stderr | grep tnvmcap | awk '{print $3}')
		_VUsmart_E2=$(get_smart_log "${_nvme_namespace}" 0x41)
		_VUsmart_E3=$(get_smart_log "${_nvme_namespace}" 0x4d)
		_VUsmart_E4=$(get_smart_log "${_nvme_namespace}" 0x59)
		_timed_work_load_started=$(cat "${_timed_work_load_startedfile}") 

		echo "Drive                            : ${_market_name} $((_tnvmcap/1000/1000/1000))GB"
		echo "Serial number                    : ${_serial_number}"
		echo "Firmware version                 : ${_firmware}"
		echo "Device                           : /dev/${_nvme_namespace}"	
		if [[ ${_VUsmart_E4} -eq 65535 ]] ; then 
			echo "smart.media_wear_percentage      : Not Available yet"
			echo "smart.host_reads                 : Not Available yet"
			echo "smart.timed_work_load            : less than 60 minutes (started on ${_timed_work_load_started})"
		else
			if [[ ${_VUsmart_E2} -eq 0 ]] ; then
				echo "smart.write_amplification_factor : ${_WAF}"
				echo "smart.media_wear_percentage      : <0.001%"
				echo "smart.host_reads                 : ${_VUsmart_E3}%"
				echo "smart.timed_work_load            : ${_VUsmart_E4} minutes (started on ${_timed_work_load_started})"
				echo "Drive life                       : smart.media_wear_percentage to small to calculate Drive life"
			else
				_media_wear_percentage=$(echo "scale=3;${_VUsmart_E2}/1024" | bc -l)
				_drive_life_minutes=$(echo "scale=0;${_VUsmart_E4}*100*1024/${_VUsmart_E2}" | bc -l)
				_drive_life_years=$(echo "scale=3;${_drive_life_minutes}/525600" | bc -l)
				_VUsmart_F5_before=$(cat "${_VUsmart_F5_beforefile}")
				_VUsmart_F5=$(get_smart_log "${_nvme_namespace}" 0x95)
				_DWPD=$(echo "scale=2;((${_VUsmart_F5}-${_VUsmart_F5_before})*${_host_written_unit}*1440/${_VUsmart_E4})/${_tnvmcap}" | bc -l)
				_hostWrites="${_VUsmart_F5}-${_VUsmart_F5_before}"
				_dataWritten=$(echo "scale=0;(${_hostWrites})*${_host_written_unit}" | bc -l)
				_dataWrittenTB=$(echo "scale=3;${_dataWritten}/${_TB_in_bytes}" | bc -l)
				echo "smart.write_amplification_factor : ${_WAF}"
				echo "smart.media_wear_percentage      : ${_media_wear_percentage/#./0.}%"
				echo "smart.host_reads                 : ${_VUsmart_E3}%"
				echo "smart.timed_work_load            : ${_VUsmart_E4} minutes (started on ${_timed_work_load_started})"
				echo "Drive life                       : ${_drive_life_years/#./0.} years (${_drive_life_minutes} minutes)"
				echo "Endurance                        : ${_DWPD} DWPD"
				echo "Data written                     : ${_dataWrittenTB} TB (${_dataWritten} bytes)"
			fi
		fi
		return 0
	else
		# background process not running
		log "[WAFINFO] ${_service} is not running."
		return 1
	fi
}

function setDevice() {
	local _nvme_namespace=$1
	
	if status >/dev/null 2>&1 ; then
		# background process running
		log "[SETDEVICE] Can't set device. ${_service} is running."
		return 1
	else
		# background process not running
		if check_nvme_namespace "${_nvme_namespace}" ; then 
			echo "${_nvme_namespace}" > "${_nvme_namespacefile}"
			log "[SETDEVICE] Device set to ${_nvme_namespace}"
		else
			echo "" > "${_nvme_namespacefile}"
			log "[SETDEVICE] Could not set device. nvme_namespace ${_nvme_namespace} does not exist."
			return 1
		fi
		return 0
	fi
}

function showVersion() {
	echo "Version: ${_version}"
	return 0
}

function clean() {
        if status >/dev/null 2>&1 ; then
                # background process running
                log "[CLEAN] Can't remove used files. ${_service} is running."
                return 1
        else
                # background process not running
                log "[CLEAN] Removing used files."
                rm -rfv /var/log/"${_filename}"
		return 0
        fi
}

function usage() {
	local _options="[start|stop|restart|status|resetWorkloadTimer|WAFinfo|setDevice|version|clean]"
	
	echo "Usage: $(basename "$1") ${_options}"
	return 0
}

if [ "$(id -u)" -ne 0 ] ; then
	log "${_service} need to run as root user or as super user"
	exit 1
fi

# Prerequisite commands
check_command awk basename bc grep sed nc nvme

# create a log directory 
mkdir -p /var/log/"${_filename}"

# Create required files if they do not exist
touch "${_logfile}" >/dev/null 2>&1 || log "Error creating ${_logfile}"
touch "${_pidfile}" >/dev/null 2>&1 || log "Error creating ${_pidfile}"
touch "${_nvme_namespacefile}" >/dev/null 2>&1 || log "Error creating ${_nvme_namespacefile}"
touch "${_VUsmart_F4_beforefile}" >/dev/null 2>&1 || log "Error creating ${_VUsmart_F4_beforefile}"
touch "${_VUsmart_F5_beforefile}" >/dev/null 2>&1 || log "Error creating ${_VUsmart_F5_beforefile}"
touch "${_timed_work_load_startedfile}" >/dev/null 2>&1 || log "Error creating ${_timed_work_load_startedfile}"

case "$1" in
	status|Status|STATUS)
		status
		;;
	start|Start|START)
		start
		;;
	stop|Stop|STOP)
		stop
		;;
	restart|Restart|RESTART)
		restart
		;;
	resetWorkloadTimer|ResetWorkloadTimer|resetworkloadtimer|rwt|RWT|RESETWORKLOADTIMER)
		resetWorkloadTimer
		;;
	WAFinfo|wafinfo|WafInfo|wi|WI|WAFINFO)
		WAFinfo
		;;
	setDevice|SetDevice|setdevice|sd|SD|SETDEVICE)
		setDevice "$2"
		;;
	version|Version|VERSION)
		showVersion
		;;
	clean|Clean|CLEAN)
		clean
		;;
	*)
		usage "$0"
		exit 1
		;;
esac
