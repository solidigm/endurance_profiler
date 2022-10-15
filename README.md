# endurance_profiler.sh
Linux Bash script that reports the Write Amplification Factor (WAF) of a workload over a defined period and estimates the Drive Life of the media in years of a new drive under that workload.
Media is one component of many affecting drive lifespan.
## Name
endurance_profiler.sh - Extracting Write Amplification Factor (WAF) on Solidigm and Intel PCIe/NVMe NAND based SSDs.
## Synopsis
endurance_profiler.sh [options]
## Options
**start**

Starts the *endurance_profiler* service. It will log all the required Vendor Unique Smart Attributes to calculate the Write Amplification Factor and other endurance related information.

When *endurance_profiler.sh start* is called it will complete immediately and a background process will keep running until *endurance_profiler.sh stop* is called. 
The status of the service can be checked with the option *status*.
Start will fail if no device is set with setDevice option.

**stop**

Stops the *endurance_profiler* service and stops logging the Vendor Unique Smart Attributes.

**restart**

Stops and restarts the *endurance_profiler* service.

**status**

Returns the status of the service.
The status can be *running* or *not running*.

**resetWorkloadTimer**

Resets the workload timer. 

**WAFinfo**

Prints the Write Amplification Factor (WAF) and other information for the SSD.

**version**

Shows the version of the tool.

**clean**

Removes all the files that were created when running the tool. Including the log file. 

**setDevice nvmeXnX**

Sets the device to be monitored.
This option has one mandatory parameter: the nvme device e.g. nvme1n1   
The option is required before the service can be started.
## Tested Operating Systems
- Ubuntu 18.04, 20.04, 22.04  
- CentOS 7, CentOS 8
## Performance impact
The performance impact of the tool is minimal. 
## Log file size
The log file endurance_profiler.log is located in /var/log/endurance_profiler.
Every minute one line is added to the file. 
File grows about 125KB per day.
## WAF info output
- **Drive**: the drive's market name.
- **Serial number**: the drive's serial number. 
- **Firmware version**: the drive's firmware version.
- **Device**: the drive's device name.
- **Log file**: the endurance_profiler script log file.
- **write_amplification_factor**: the ratio of the amount of data actually written from the controller to the NAND to the amount of data sent from Operating System to the SSD since reset of the workload timer. The more data written since a reset of the workload timer the more accurate the Write Amplification Factor (WAF) result is.
- **media_wear_percentage** : wear seen by the SSD since reset of the workload timer as a percentage of the max rated NAND cycles.
- **host_reads** : the percentage of I/O operations that are read operations since reset of the workload timer.
- **timed_workload**: the elapsed time in minutes since reset of the workload timer.
- **Drive life** : the drive life expectancy of the drive's media in years. Do not use this information as an overall indicator of the drive life expectancy. Media is one component of many affecting drive lifespan
Drive life is timed_workload divided by media_wear_percentage. The more data written since a reset of the workload timer the more accurate the drive life.
- **Endurance** : Drive Writes Per Day (DWPD) represents the average amount of data written to the SSD per day since reset of the workload timer and measured in the drive's full capacity.
The more data written since a reset of the workload timer the more accurate the endurance expectancy.
- **Data written**: Terabytes written by the host to the drive since reset of the workload timer.

## Step by step guide 
Calling the script without a parameter will result in printing the supported options.
```
# ./endurance_profiler.sh
[start|stop|restart|status|resetWorkloadTimer|WAFinfo|setDevice|version|clean]
```
Check the status of the service:
```
# ./endurance_profiler.sh status
[STATUS] Service ./endurance_profiler.sh not running
```
Set the NVMe device to be monitored:
```
# ./endurance_profiler.sh setDevice nvme1n1
[CHECKNVMENAMESPACE] nvme device nvme1n1 exists
[SETDEVICE] Device set to nvme1n1
```
Start the service:
```
# ./endurance_profiler.sh start
[START] Starting ./endurance_profiler.sh
[START} /var/log/endurance_profiler/endurance_profiler.nvmenamespace.var exists and device=nvme1n1
[CHECKNVMENAMESPACE] nvme device nvme1n1 exists
[START] Logging on nvme1n1. Log filename /var/log/endurance_profiler/endurance_profiler.log
[START] ./endurance_profiler.sh has pid=7936
[STATUS] Service ./endurance_profiler.sh with pid=7936 running
```
Check the status of the service:
```
# ./endurance_profiler.sh status
[STATUS] Service ./endurance_profiler.sh with pid=7936 running
```
To get a good estimation for the information returned by the WAFinfo command it is suggested to run a workload for a significant amount of time.  
Media wear, host reads and timed workload are only updated after one hour.  
Write Amplification Factor, Drive life, Endurance and Data written are based on Media Wear since resetting the workload timer. It might require a workload to write multiple times the drive's capacity to get a high enough Media Wear percentage. 

Check the Write Amplification Info:
```
# ./endurance_profiler.sh WAFinfo
Drive                            : Intel(R) SSD DC P5520   Series 3840GB
Serial number                    : PHAX217400CZ3P8CGN
Firmware version                 : 9CV10200
Device                           : /dev/nvme1n1
smart.write_amplification_factor : 1.63
smart.media_wear_percentage      : 0.019%
smart.host_reads                 : 20%
smart.timed_workload             : 590 minutes
Drive life                       : 5.747 years (3020800 minutes)
Endurance                        : 1.87 DWPD
Data written                     : 4.161 TB (4161568000000 bytes)
```
Stop the service:
```
# ./endurance_profiler.sh stop
[STOP] Stopping ./endurance_profiler.sh with pid=7936
[STOP] kill 7936
```
Check the status:
```
# ./endurance_profiler.sh status
[STATUS] Service ./endurance_profiler.sh not running
```
Remove all used files:
```
# ./endurance_profiler.sh clean
[CLEAN] Removing used files.
removed '/var/log/endurance_profiler/endurance_profiler.F4_before.var'
removed '/var/log/endurance_profiler/endurance_profiler.F5_before.var'
removed '/var/log/endurance_profiler/endurance_profiler.log'
removed '/var/log/endurance_profiler/endurance_profiler.nvmenamespace.var'
removed '/var/log/endurance_profiler/endurance_profiler.timed_workload_started.var'
removed directory '/var/log/endurance_profiler'
```
## Configurable variables
The following variables in the **./endurance_profiler.sh** script are configurable.
``` 
_db=console
_nc_graphite_destination=localhost
_nc_graphite_port=2003
```
**_db**  
The variable indicates if and where the evaluated SMART attributes and bandwidth will be logged.
Logging is not required to get the Write Amplification Factor through the WAFinfo option.
- supported values: graphite, logfile
- default: logfile

The following SMART attributes are evaluated and logged every minute in the log file:
- media_wear_percentage
  - measures the wear seen by the SSD since reset of the workload timer as a percentage of the max rated cycles.
- host_reads
  - shows the percentage of I/O operations that are read operations since reset of the workload timer.
- timed_workload
  - the elapsed time in minutes since reset of the workload timer.
- NAND_bytes_written
  - bytes written to NAND over the lifetime of the SSD.
- host_bytes_written.
  - bytes written by the host to the SSD over the lifetime of the SSD.
- write_amplicifation_factor
  - defined as the ratio of the amount of data actually written from the controller to the NAND to the amount of data sent from Operating System to the SSD since reset of the workload timer.
- temperature
  - device SMART temperature in degree C.
- percentage_used
  - a value of 100 indicates that the estimated endurance of the device has been consumed, but may not indicate a device failure.
- drive_life
  - represents the drive life expectancy of the drive's media in minutes. Do not use this information as an overall indicator of the drive life expectancy. Media is one component of many affecting drive lifespan.
- DWPD
  - Drive Writes Per Day (DWPD) represents the average amount of data written to the SSD per day since reset of the workload timer and measured in the drive's full capacity.
- data_written
  - bytes written by the host to the drive since reset of the workload timer.

The following bandwidth metrics are evaluated every second: 
- readBW 
- writeBW

**_nc_graphite_destination**  
This variable will be used as destination address when _db=graphite.
The destination address can be localhost or a remote IP address.
- supported values: all IP addresses
- default: localhost 

**_nc_graphite_port**  
This variable will be used as destination port when _db=graphite.
The destination port can be any IP port.
- supported values: all IP ports
- default: 2003

