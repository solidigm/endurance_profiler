# endurance_profiler.sh
Linux Bash script that reports the Write Amplification Factor (WAF) of a workload over a defined period and estimates the Drive Life in years of a new drive under this workload.
## Name
endurance_profiler.sh - Extracting Write Amplification Factor (WAF) on Intel PCIe/NVMe based SSDs.
## Synopsis
endurance_profiler.sh [options]
## Options
**start**

 Starts the *endurance_profiler* service. It will log all the required Vendor Unique Smart Attributes to calculate the Write Amplification Factor.

When *endurance_profiler.sh start* is called it will complete immediately and a background process will keep running until *endurance_profiler.sh stop* is called. 
The status of the service can be checked with the option *status*.   
Start will fail if no NVMe device is set with setDevice option.

**stop**

Stops the *endurance_profiler* service and stop logging the Vendor Unique Smart Attributes.

**restart**

Stops and restarts the *endurance_profiler* service.

**status**

Returns the status of the service.
The status can be *running* or *not running*.

**resetWorkloadTimer**

Resets the workload timer. 

**WAFinfo**

Prints the Write Amplification Factor (WAF) and other information for the NVMe SSD.

**setDevice nvmeXnX**

Sets the NVMe device to be monitored.  
This option has one mandatory parameter: the nvme device e.g. nvme1n1  
The option is required before the service can be started.
## Tested Operating Systems
- Ubuntu 18.04, 20.04  
- CentOS 7, CentOS 8
## Step by step guide 
Calling the script without a parameter will result in printing the supported options.
```
# ./endurance_profiler.sh
[start|stop|restart|status|resetWorkloadTimer|WAFinfo|setDevice]
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
It is suggested to run a workload for longer than 1 hour.

Check the Write Amplification Info:
```
# ./endurance_profiler.sh WAFinfo
Drive                            : Intel(R) SSD DC P5316   Series 15362GB
Serial number                    : PHAC121300TN15PHGN
Device                           : /dev/nvme3n1
smart.write_amplification_factor : 2.34
smart.media_wear_percentage      : 0.030%
smart.host_reads                 : 81%
smart.timed_work_load            : 653 minutes
Drive life                       : 4.007 years (2106451 minutes)
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
- supported values: graphite, logfile, console
- default: console  

The following SMART attributes are evaluated:
- media_wear_percentage
- host_reads
- timed_work_load
- write_amplicifation_factor
- host_bytes_written
- temperature
- percentage_used

The following bandwidth metrics are evaluated: 
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
