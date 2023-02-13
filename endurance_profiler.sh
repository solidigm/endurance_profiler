#!/bin/bash
# Copyright 2021 Solidigm.
# SPDX-License-Identifier: BSD-3-Clause

# Default values for user configurable variables 
_nvme_namespace=""
_db=none
_nc_graphite_destination=localhost
_nc_graphite_port=2003
_console_logging=true

# Script variables, do not modify
_version="v1.1.54"
_service="$0"
# remove any leading directory components and .sh
_filename=$(basename "${_service}" .sh)

_datalogfile=/var/log/${_filename}/${_filename}.data.log
_consolelogfile=/var/log/${_filename}/${_filename}.console.log
_pidfile=/tmp/${_filename}.pid
_WAFfile=/var/log/${_filename}/${_filename}.WAF.var
_nvme_namespacefile=/var/log/${_filename}/${_filename}.nvmenamespace.var
_VUsmart_F4_beforefile=/var/log/${_filename}/${_filename}.F4_before.var
_VUsmart_F5_beforefile=/var/log/${_filename}/${_filename}.F5_before.var
_timed_workload_startedfile=/var/log/${_filename}/${_filename}.timed_workload_started.var
_dbfile=/var/log/${_filename}/${_filename}.db.var
_nc_graphite_destinationfile=/var/log/${_filename}/${_filename}.nc_graphite_destination.var
_nc_graphite_portfile=/var/log/${_filename}/${_filename}.nc_graphite_port.var
_console_loggingfile=/var/log/${_filename}/${_filename}.console_logging.var
_db_not_supported="not logged"

_TB_in_bytes=1000000000000
_host_written_unit=$(( 32 * 1024 * 1024 ))
_bandwidth_blocksize=512
_minutes_in_day=1440
_minutes_in_year=525600

function check_command() {
	# Function checks if the arguments are installed commands
	# Function iterates over all function arguments and returns 1 if a command is not an installed command
	# argument 1: a linux command
	local _command=$1

	while [ $# -gt 0 ] ; do
		# check if a passed argument is an installed command
		if ! command -v "${_command}" &> /dev/null ; then
			log "[CHECKCOMMAND] Command ${_command} could not be found"
			log "[CHECKCOMMAND] Command ${_command} is a required command. Try to install ${_command}."
			# exit the script with error code 1 
			exit 1
		fi
		shift
	done
	return 0
}

function check_nvme_namespace() {
	# Function checks if the first argument is an existing nvme device namespace
	# Function returns 0 if namespace exists
	# argument 1: a namespace
	local _nvme_namespace=$1
	local _ret=0

	if [[ ${_nvme_namespace} =~ ^nvme[0-9]+n[0-9]+$ ]] ; then
		_ret=$(nvme list 2>/dev/null | grep "${_nvme_namespace}" 2>&1 >/dev/null)
		# assign the return value of grep to the variable ret
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
	# Function will send the data in the first argument to a database as configured in the global variable _db
	# Supported databases defined in _db
	#	graphite
	#	logfile
	#	graphite+log
	#	none
	# argument 1: data to be sent
	local _data=$1

	if [ "${_db}" = "graphite" ] ; then
		# send the data to the graphite port and destination
		echo "${_data}" | nc -N "${_nc_graphite_destination}" "${_nc_graphite_port}"
	elif [ "${_db}" = "logfile" ] ; then
		# send the data the log file
		echo "${_data}"
	elif [ "${_db}" = "graphite+logfile" ] ; then
		# send the data to the graphite port and destination, and to the datalogfile
		echo "${_data}" | nc -N "${_nc_graphite_destination}" "${_nc_graphite_port}"
		echo "${_data}"
	elif [ "${_db}" = "none" ] ; then
		# don't do anything with the data
		:
	elif [ "${_db_not_supported}" != "logged" ] ; then
		# variable _db does not contain a supported database
		# send once the error to the log file
		_db_not_supported="logged"
		_db="none"
		log "[SENDTODB] ${_db} as database is not supported"
	fi
	return 0
}

function get_vusmart_log() {
	# Function will return the Intel/Solidigm Vendor Unique smart log info for the nvme device at an offset
	# argument 1: nvme device
	# argument 2: offset
	local _local_nvme_namespace=$1
	local _offset=$2
	local _rev_vusmart_hexadecimal=0
	local _len=0

	# get Vendor Unique smart attributes in binary format, get 6 bytes from position _offset
	_vusmart_hexadecimal=$(nvme get-log /dev/"${_local_nvme_namespace}" --log-id 0xca --log-len 512 --raw-binary | xxd -l 6 -seek "${_offset}" -ps)
	# reverse the variable _vusmart_hexadecimal
	_len=${#_vusmart_hexadecimal}
	for((i=_len;i>=0;i=i-2)); do _rev_vusmart_hexadecimal="$_rev_vusmart_hexadecimal${_vusmart_hexadecimal:$i:2}"; done
	# convert _vusmart_hexadecimal to capital letter, convert to decimal and remove leading zeros
	_vusmart_decimal=$(echo "ibase=16;${_rev_vusmart_hexadecimal^^}" | bc)
	echo "${_vusmart_decimal}"
	return 0
}

function loop() {
	# function checks every second the bandwidth for the specified namespace and every minute for Vendor Unique Smart Attributes
	# calculates teh WAF and sends all the data to the configured database
	# argument 1: nvme namespace
	local _nvme_namespace=$1
	local _counter=0
	local _hostWrites=1
	local _nandWrites=0
	local _read_bandwidth=0
	local _write_bandwidth=0
	local _readblocks_old=0
	local _writeblocks_old=0
	local _readblocks_new=0
	local _writeblocks_new=0
	local _host_reads=0
	local _media_wear_percentage=0
	local _timed_workload=0
	local _DWPD=0
	local _WAF=0
	local _host_bytes_written=0
	local _temperature=0
	local _percentage_used=0

	_tnvmcap=$(nvme id-ctrl /dev/"${_nvme_namespace}" 2>stderr | grep tnvmcap | awk '{print $3}')
	echo "${_service} ${_version}"
	echo "date, media_wear_percentage, host_reads, timed_workload, NAND_bytes_written, host_bytes_written, WAF, temperature, percentage_used, drive_life_minutes, DWPD, dataWritten"
	eval "$(awk '{printf "_readblocks_old=\"%s\" _writeblocks_old=\"%s\"", $3 ,$7}' < /sys/block/"${_nvme_namespace}"/stat)"
	while true; do
		if ! ((_counter % 60)) ; then
			# this block will run every minute
			_VUsmart_E2=$(get_vusmart_log "${_nvme_namespace}" 0x41)
			_VUsmart_E3=$(get_vusmart_log "${_nvme_namespace}" 0x4d)
			_VUsmart_E4=$(get_vusmart_log "${_nvme_namespace}" 0x59)
			_VUsmart_F4=$(get_vusmart_log "${_nvme_namespace}" 0x89)
			_VUsmart_F5=$(get_vusmart_log "${_nvme_namespace}" 0x95)
			_temperature=$(nvme smart-log /dev/"${_nvme_namespace}" 2>stderr | grep temperature | awk '{print $3}' | sed 's/[^0-9]*//g')
			_percentage_used=$(nvme smart-log /dev/"${_nvme_namespace}" 2>stderr | grep percentage_used | awk '{print $3}' | sed 's/[^0-9]*//g')
			_VUsmart_F4_before=$(cat "${_VUsmart_F4_beforefile}")
			_VUsmart_F5_before=$(cat "${_VUsmart_F5_beforefile}")
			if [[ "${_VUsmart_F5}" -eq "${_VUsmart_F5_before}" ]] ; then
				# No host data written since resetting the workload timer
				_hostWrites=0
				_nandWrites=0
				_WAF=0
			else
				# Calculate host bytes written and NAND bytes written since resetting the workload timer
				_hostWrites=${_VUsmart_F5}-${_VUsmart_F5_before}
				_nandWrites=${_VUsmart_F4}-${_VUsmart_F4_before}
				_WAF=$(echo "scale=2;(${_nandWrites})/(${_hostWrites})" | bc -l)
			fi
			_host_bytes_written=$(echo "scale=0;${_VUsmart_F5}*${_host_written_unit}" | bc -l)
			_dataWritten=$(echo "scale=0;(${_hostWrites})*${_host_written_unit}" | bc -l)

			if [[ ${_VUsmart_E4} -eq 65535 ]] ; then 
				# ${_timed_workload_started} is less than 60 minutes, no real data for Vendor Unique smart attribute E2, E3 and E4
				_media_wear_percentage=0
				_host_reads=0
				_timed_workload=0
				_drive_life_minutes=0
				_DWPD=0
			else
				_media_wear_percentage=$(echo "scale=3;${_VUsmart_E2}/1024" | bc -l)
				_host_reads=${_VUsmart_E3}
				_timed_workload=${_VUsmart_E4}
				if [[ ${_VUsmart_E2} -eq 0 ]] ; then
					_drive_life_minutes=0
				else
					_drive_life_minutes=$(echo "scale=0;${_VUsmart_E4}*100*1024/${_VUsmart_E2}" | bc -l)
				fi
				_DWPD=$(echo "scale=2;((${_VUsmart_F5}-${_VUsmart_F5_before})*${_host_written_unit}*${_minutes_in_day}/${_VUsmart_E4})/${_tnvmcap}" | bc -l)
			fi
			send_to_db "smart.media_wear_percentage ${_media_wear_percentage} $(date +%s)"
			send_to_db "smart.host_reads ${_host_reads} $(date +%s)"
			send_to_db "smart.timed_workload ${_timed_workload} $(date +%s)"
			send_to_db "smart.drive_life ${_drive_life_minutes} $(date +%s)"
			send_to_db "smart.host_bytes_written ${_host_bytes_written} $(date +%s)"
			send_to_db "smart.dataWritten ${_dataWritten} $(date +%s)"
			send_to_db "smart.DWPD ${_DWPD} $(date +%s)"
			send_to_db "smart.temperature ${_temperature} $(date +%s)"
			send_to_db "smart.percentage_used ${_percentage_used} $(date +%s)"
			send_to_db "smart.write_amplification_factor ${_WAF} $(date +%s)"
			echo "${_WAF}" > "${_WAFfile}"
			echo "$(date +%s), ${_VUsmart_E2}, ${_VUsmart_E3}, ${_VUsmart_E4}, ${_VUsmart_F4}, ${_VUsmart_F5}, ${_WAF}, ${_temperature}, ${_percentage_used}, ${_drive_life_minutes}, ${_DWPD}, ${_dataWritten}"
			_counter=0
		fi
		# this block will run every second
		if ! [ "${_db}" = "none" ] ; then
			eval "$(awk '{printf "_readblocks_new=\"%s\" _writeblocks_new=\"%s\"", $3 ,$7}' < /sys/block/"${_nvme_namespace}"/stat)"
			_read_bandwidth=$(echo "(${_readblocks_new}-${_readblocks_old})*${_bandwidth_blocksize}/1000/1000" | bc)
			_write_bandwidth=$(echo "(${_writeblocks_new}-${_writeblocks_old})*${_bandwidth_blocksize}/1000/1000" | bc)
			_readblocks_old=${_readblocks_new}
			_writeblocks_old=${_writeblocks_new}

			# add read and write bandwidth to TimeSeriesDataBase
			send_to_db "nvme.readBW ${_read_bandwidth} $(date +%s)"
			send_to_db "nvme.writeBW ${_write_bandwidth} $(date +%s)"
		fi
		_counter=$(( _counter + 1 ))
		sleep 1
	done
	return 0
}

function log() {
	# function will print the provided argument on the terminal and log it to the console log file if console logging is enabled
	# arguments: multiple strings

	echo "$*"
	if [[ "${_console_logging}" == "true" ]] ; then
		echo "$(date "+%F-%H:%M:%S") $*" >> "${_consolelogfile}"
	fi
	return 0
}

function retrieve_pid() {
	# echo the process id of the running background process
	# if not running echo 0 as 0 is an invalid pid
	local _pid=0

	if [ -s "${_pidfile}" ] ; then
		# file ${_pid} is not empty
		_pid=$(cat "${_pidfile}")
		if ps -p "${_pid}" > /dev/null 2>&1 ; then 
			# ${_pid} is running process
			echo "${_pid}"
		else
			# ${_pid} is not a process id or not a running process
			echo 0
		fi
	else
		# file ${_pid} is empty
		echo 0
	fi
	return 0
}

function retrieve_nvme_namespace() {
	# echo the namespace retrieved from the file ${_nvme_namespacefile}
	# only returns the namespace when it exists in the system 
	# if an error found return an empty string

	if [ -s "${_nvme_namespacefile}" ] ; then
		# the file ${_nvme_namespacefile} exists
		_nvme_namespace=$(cat "${_nvme_namespacefile}")
		if [[ ${_nvme_namespace} =~ ^nvme[0-9]+n[0-9]+$ ]] ; then
			_ret=$(nvme list 2>/dev/null | grep "${_nvme_namespace}" 2>&1 >/dev/null)
			# assign the return value of grep to the variable ret
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
	# log if the background process is running and return 0, or return 1 if not
	local _pid=0

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
	# Start the background process
	local _pid=0
	local _nvme_namespace=""

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
				log "[START] Logging namespace ${_nvme_namespace}"
				log "[START] Data log filename ${_datalogfile}"
				log "[START] Console log filename ${_consolelogfile}"
				log "[START] ${_nvme_namespacefile} exists and namespace=${_nvme_namespace}"
				log "[START] Sending endurance data to database=${_db}"

				if ! [ -s "${_timed_workload_startedfile}" ] ; then
					# ${_timed_workload_startedfile} is an empty file
					# reset all global variables
					resetWorkloadTimer
				fi

				(loop "${_nvme_namespace}" >> "${_datalogfile}" 2>>"${_datalogfile}") &
				# write process id to file
				echo $! > "${_pidfile}"

				# check if background process is running
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
	# Stop the background process
	local _pid=0

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
	# Restart the background process
	stop
	start
	return 0
}

function resetWorkloadTimer() {
	# Reset the workload timer by sending a Vendor Unique Set command to the device.
	local _nvme_device=""
	local _nvme_namespace=""
	local _VUsmart_F4_before=0
	local _VUsmart_F5_before=0

	# background process running
	_nvme_namespace=$(retrieve_nvme_namespace)
	if [ "${_nvme_namespace}" == "" ] ; then
		log "[RESETWORKLOADTIMER] Invalid nvme namespace parameter. Workload Timer not reset."
		return 1
	fi
	_nvme_device=${_nvme_namespace/%n[0-9]*/}
	nvme set-feature -f 0xd5 -v 1 /dev/"${_nvme_device}" > /dev/null 2>&1
	log "[RESETWORKLOADTIMER] Workload Timer Reset on ${_nvme_device} at $(date)"
	_VUsmart_F4_before=$(get_vusmart_log "${_nvme_namespace}" 0x89)
	_VUsmart_F5_before=$(get_vusmart_log "${_nvme_namespace}" 0x95)
	echo "${_VUsmart_F4_before}" > "${_VUsmart_F4_beforefile}"
	echo "${_VUsmart_F5_before}" > "${_VUsmart_F5_beforefile}"
	echo 0 > "${_WAFfile}"
	date > "${_timed_workload_startedfile}"
	return 0
}

function info() {
	# show WAF and endurance related information
	local _nvme_namespace=""
	local _WAF=0
	local _market_name=""
	local _serial_number=""
	local _tnvmcap=0
	local _VUsmart_E2=0
	local _VUsmart_E3=0
	local _VUsmart_E4=0
	local _media_wear_percentage=0
	local _firmware=""
	local _VUsmart_F5_before=0
	local _VUsmart_F5=0
	local _hostWrites=0
	local _dataWritten=0
	local _dataWrittenTB=0

	if status >/dev/null 2>&1 ; then
		# background process running
		_nvme_namespace=$(retrieve_nvme_namespace)
		if [ "${_nvme_namespace}" == "" ] ; then
			log "[INFO] Invalid nvme namespace parameter."
			return 1
		fi
		_WAF=$(cat "${_WAFfile}")
		_market_name="$(nvme get-log /dev/"${_nvme_namespace}" -i 0xdd -l 0x512 -b 2>&1 | tr -d '\0')"
		_serial_number=$(nvme id-ctrl /dev/"${_nvme_namespace}" 2>stderr | grep sn | awk '{print $3}')
		_firmware=$(nvme id-ctrl /dev/"${_nvme_namespace}" 2>stderr | grep "fr " | awk '{print $3}')
		_tnvmcap=$(nvme id-ctrl /dev/"${_nvme_namespace}" 2>stderr | grep tnvmcap | awk '{print $3}')
		_VUsmart_E2=$(get_vusmart_log "${_nvme_namespace}" 0x41)
		_VUsmart_E3=$(get_vusmart_log "${_nvme_namespace}" 0x4d)
		_VUsmart_E4=$(get_vusmart_log "${_nvme_namespace}" 0x59)
		_timed_workload_started=$(cat "${_timed_workload_startedfile}")
		_datalogfile_size=$(find "${_datalogfile}" -printf "%s" )
		_consolelogfile_size=$(find "${_consolelogfile}" -printf "%s" )
		_VUsmart_F5_before=$(cat "${_VUsmart_F5_beforefile}")
		_VUsmart_F5=$(get_vusmart_log "${_nvme_namespace}" 0x95)
		_hostWrites="${_VUsmart_F5}-${_VUsmart_F5_before}"
		_dataWritten=$(echo "scale=0;(${_hostWrites})*${_host_written_unit}" | bc -l)
		_dataWrittenTB=$(echo "scale=3;${_dataWritten}/${_TB_in_bytes}" | bc -l)
		log "Drive                               : ${_market_name} $((_tnvmcap/1000/1000/1000))GB"
		log "Serial number                       : ${_serial_number}"
		log "Firmware version                    : ${_firmware}"
		log "Device                              : /dev/${_nvme_namespace}"
		log "Data log file                       : ${_datalogfile} (size: $((_datalogfile_size/1000)) KB)"
		log "Console log file                    : ${_consolelogfile} (size: $((_consolelogfile_size/1000)) KB)"
		if [[ ${_VUsmart_E4} -eq 65535 ]] ; then 
			log "smart.media_wear_percentage         : Not Available yet"
			log "smart.host_reads                    : Not Available yet"
			log "smart.timed_workload                : less than 60 minutes (started on ${_timed_workload_started})"
		else
			if [[ ${_WAF} = "0" ]] ; then
				_WAF="no data is written by the host since timed_workload is started"
			fi
			if [[ ${_VUsmart_E2} -eq 0 ]] ; then
				log "smart.media_wear_percentage         : <0.001%"
				log "smart.host_reads                    : ${_VUsmart_E3}%"
				log "smart.timed_workload                : ${_VUsmart_E4} minutes (started on ${_timed_workload_started})"
				log "Workload Write Amplification Factor : ${_WAF/#./0.}"
				log "Workload drive life                 : smart.media_wear_percentage to small to calculate Drive life"
			else
				_media_wear_percentage=$(echo "scale=3;${_VUsmart_E2}/1024" | bc -l)
				_drive_life_minutes=$(echo "scale=0;${_VUsmart_E4}*100*1024/${_VUsmart_E2}" | bc -l)
				_drive_life_years=$(echo "scale=3;${_drive_life_minutes}/${_minutes_in_year}" | bc -l)
				_DWPD=$(echo "scale=2;((${_VUsmart_F5}-${_VUsmart_F5_before})*${_host_written_unit}*${_minutes_in_day}/${_VUsmart_E4})/${_tnvmcap}" | bc -l)
				log "smart.media_wear_percentage         : ${_media_wear_percentage/#./0.}%"
				log "smart.host_reads                    : ${_VUsmart_E3}%"
				log "smart.timed_workload                : ${_VUsmart_E4} minutes (started at ${_timed_workload_started})"
				log "Workload Write Amplification Factor : ${_WAF/#./0.}"
				log "Workload drive life                 : ${_drive_life_years/#./0.} years (${_drive_life_minutes} minutes)"
				log "Workload write rate                 : ${_DWPD/#./0.} DWPD"
			fi
		fi
		log "Workload data written               : ${_dataWrittenTB/#./0.} TB (${_dataWritten} bytes)"
		return 0
	else
		# background process not running
		log "[INFO] ${_service} is not running."
		return 1
	fi
}

function setDevice() {
	# Write the nvme device configuration from global variable to file
	# argument 1: nvme device
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
			resetWorkloadTimer
		else
			echo "" > "${_nvme_namespacefile}"
			log "[SETDEVICE] Could not set device. nvme_namespace ${_nvme_namespace} does not exist."
			return 1
		fi
		return 0
	fi
}

function getDevice() {
	# Read the nvme device configuration from file and save in global variable
	local _nvme_namespace=""

	if [[ -s ${_nvme_namespacefile} ]] ; then
		# _nvme_namespacefile is not empty, read value from file
		_nvme_namespace=$(cat "${_nvme_namespacefile}")
		log "[GETDEVICE] Device is set to ${_nvme_namespace}"
	else
		log "[GETDEVICE] Device is not set"
	fi
	return 0
}

function setVariable() {
	# Write a global variable to a file
	# argument 1: a variable
	# argument 2: a file name to save the variable
	# argument 3: the value for the variable
	local _variable=$1
	local _variablefile=$2
	local _value=$3
	local _db_options="[none | graphite | logfile | graphite+logfile]"
	local _console_logging_options="[true | false]"

	case "${_variable}" in 
		_db)
			if [[ ${_value} != "none" &&  ${_value} != "graphite" && ${_value} != "logfile" &&  ${_value} != "graphite+logfile" ]] ; then
				log "[SETVARIABLE] ${_value} for db is not supported."
				echo "Usage: $(basename "${_service}") set db ${_db_options}"
				return 1
			fi
			_db=${_value}
			if status >/dev/null 2>&1 ; then
				# background process running
				restart
			fi
			;;
		_nc_graphite_destination)
			_nc_graphite_destination=${_value}
			;;
		_nc_graphite_port)
			_nc_graphite_port=${_value}
			;;
		_console_logging)
			if [[ "${_value}" != "true" && "${_value}" != "false" ]] ; then
				log "[SETVARIABLE] ${_value} for console_logging is not supported."
				echo "Usage: $(basename "${_service}") set console_logging ${_console_logging_options}"
				return 1
			fi
			if [[ "${_value}" == "false" ]] ; then
				echo "${_value}" > "${_variablefile}"
				log "[SETVARIABLE] Variable ${_variable} set to false"
				return 0
			fi
			_console_logging=${_value}
			;;
		*)
			log "[SETVARIABLE] ${_variable} = ${_value} is not supported"
			return 1
			;;
	esac
	echo "${_value}" > "${_variablefile}"
	log "[SETVARIABLE] Variable ${_variable} set to ${_value}"
	return 0
}

function getVariable() {
	# log a variable's value
	# argument 1: a variable
	local _variable=$1
	local _value=""

	case "${_variable}" in
		_db)
			_value=${_db}
			;;
		_nc_graphite_destination)
			_value=${_nc_graphite_destination}
			;;
		_nc_graphite_port)
			_value=${_nc_graphite_port}
			;;
		_console_logging)
			_value=${_console_logging}
			;;
		*)
			log "[GETVARIABLE] ${_variable} is not supported"
			return 1
			;;
	esac
	log "[GETVARIABLE] Variable ${_variable} set to ${_value}"
	return 0
}

function retrieve_variables() {
	# Read the global variables from file

	if [[ -s ${_dbfile} ]] ; then
		# _dbfile is not empty, read value from file
		_db=$(cat "${_dbfile}")
	else
		echo "${_db}" > "${_dbfile}"
	fi
	if [[ -s "${_nc_graphite_destinationfile}" ]] ; then
		# _nc_graphite_destinationfile is not empty, read value from file
		_nc_graphite_destination=$(cat "${_nc_graphite_destinationfile}")
	else
		echo "${_nc_graphite_destination}" > "${_nc_graphite_destinationfile}"
	fi
	if [[ -s "${_nc_graphite_portfile}" ]] ; then
		# _nc_graphite_portfile is not empty, read value from file
		_nc_graphite_port=$(cat "${_nc_graphite_portfile}")
	else
		echo "${_nc_graphite_port}" > "${_nc_graphite_portfile}"
	fi
	if [[ -s "${_console_loggingfile}" ]] ; then
		# _console_loggingfile is not empty, read value from file
		_console_logging=$(cat "${_console_loggingfile}")
	else
		echo "${_console_logging}" > "${_console_loggingfile}"
	fi
	return 0
}

function showVersion() {
	echo "Version: ${_version}"
	return 0
}

function clean() {
	# Delete all files created by this script

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

function global_usage() {
	local _options="[start | stop | restart | status | resetWorkloadTimer | info | set | get | version | clean]"

	echo "Usage: $(basename "$1") ${_options}"
	return 0
}

function set_usage() {
	local _options="[device | db | nc_graphite_destination | nc_graphite_port | console_logging]"

	echo "Usage: $(basename "$1") set ${_options}"
	return 0
}

function get_usage() {
	local _options="[device | db | nc_graphite_destination | nc_graphite_port | console_logging | all]"

	echo "Usage: $(basename "$1") get ${_options}"
	return 0
}

# Script need to run as root user
if [ "$(id -u)" -ne 0 ] ; then
	log "${_service} need to run as root user or as super user"
	exit 1
fi

# Prerequisite commands
check_command awk basename bc grep sed nc nvme

# create a log directory 
mkdir -p /var/log/"${_filename}"

# Create required files if they do not exist
touch "${_datalogfile}" >/dev/null 2>&1 || log "Error creating ${_datalogfile}"
touch "${_consolelogfile}" >/dev/null 2>&1 || log "Error creating ${_consolelogfile}"
touch "${_pidfile}" >/dev/null 2>&1 || log "Error creating ${_pidfile}"
touch "${_nvme_namespacefile}" >/dev/null 2>&1 || log "Error creating ${_nvme_namespacefile}"
touch "${_VUsmart_F4_beforefile}" >/dev/null 2>&1 || log "Error creating ${_VUsmart_F4_beforefile}"
touch "${_VUsmart_F5_beforefile}" >/dev/null 2>&1 || log "Error creating ${_VUsmart_F5_beforefile}"
touch "${_timed_workload_startedfile}" >/dev/null 2>&1 || log "Error creating ${_timed_workload_startedfile}"
touch "${_dbfile}" >/dev/null 2>&1 || log "Error creating ${_dbfile}"
touch "${_nc_graphite_destinationfile}" >/dev/null 2>&1 || log "Error creating ${_nc_graphite_destinationfile}"
touch "${_nc_graphite_portfile}" >/dev/null 2>&1 || log "Error creating ${_nc_graphite_portfile}"

retrieve_variables

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
		restart
		;;
	info|Info|INFO)
		info
		;;
	WAFinfo|wafinfo|WafInfo|wi|WI|WAFINFO)
		info
		;;
	setDevice|SetDevice|setdevice|sd|SD|SETDEVICE)
		setDevice "$2"
		;;
	set|Set|SET)
		case "$2" in
			device|Device|DEVICE)
				setDevice "$3"
				;;
			db|Db|DB)
				setVariable "_db" "${_dbfile}" "$3"
				;;
			nc_graphite_destination)
				setVariable "_nc_graphite_destination" "${_nc_graphite_destinationfile}" "$3"
				;;
			nc_graphite_port)
				setVariable "_nc_graphite_port" "${_nc_graphite_portfile}" "$3"
				;;
			console_logging)
				setVariable "_console_logging" "${_console_loggingfile}" "$3"
				;;
			*)
				set_usage "${_service}"
				exit 1
				;;
		esac
		;;
	get|Get|GET)
		case "$2" in
			device|Device|DEVICE)
				getDevice
				;;
			db|Db|DB)
				getVariable "_db"
				;;
			nc_graphite_destination)
				getVariable "_nc_graphite_destination"
				;;
			nc_graphite_port)
				getVariable "_nc_graphite_port"
				;;
			console_logging)
				getVariable "_console_logging"
				;;
			all|All|ALL)
				getDevice
				getVariable "_db"
				getVariable "_nc_graphite_destination"
				getVariable "_nc_graphite_port"
				getVariable "_console_logging"
				;;
			*)
				get_usage "${_service}"
				exit 1
				;;
		esac
		;;
	version|Version|VERSION)
		showVersion
		;;
	clean|Clean|CLEAN)
		clean
		;;
	*)
		global_usage "${_service}"
		exit 1
		;;
esac
