#!/bin/bash 

#############################################################
################ Posting ####################################
#############################################################

declare POSTING_SUPPLIERS_SUBDIR="posting_suppliers.d"    ### Subdir under each posting deamon directory which contains symlinks to the decoding deamon(s) subdirs where spots for this daemon are copied
declare -r WAV_FILE_POLL_SECONDS=5            ### How often to poll for the 2 minute .wav record file to be filled

function get_posting_dir_path(){
    local receiver_name=$1
    local receiver_rx_band=$2
    local receiver_posting_path="${WSPRDAEMON_TMP_DIR}/posting.d/${receiver_name}/${receiver_rx_band}"

    echo ${receiver_posting_path}
}



### This daemon creates links from the posting dirs of all the $4 receivers to a local subdir, then waits for YYMMDD_HHMM_wspr_spots.txt files to appear in all of those dirs, then merges them
### and 
function posting_daemon() 
{
    local posting_receiver_name=${1}
    local posting_receiver_band=${2}
    local posting_receiver_modes=${3}
    local real_receiver_list=($4)
    local real_receiver_count=${#real_receiver_list[@]}

    wd_logger 1 "Starting with args ${posting_receiver_name} ${posting_receiver_band} ${posting_receiver_modes} '${real_receiver_list[*]}'"

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    source ${WSPRDAEMON_CONFIG_FILE}

    local posting_call_sign="$(get_receiver_call_from_name ${posting_receiver_name})"
    local posting_grid="$(get_receiver_grid_from_name ${posting_receiver_name})"
    
    ### Where to put the spots from the one or more real receivers for the upload daemon to find
    local  wsprnet_upload_dir=${UPLOADS_WSPRNET_SPOTS_DIR}/${posting_call_sign//\//=}_${posting_grid}/${posting_receiver_name}/${posting_receiver_band}  ## many ${posting_call_sign}s contain '/' which can't be part of a Linux filename, so convert them to '='
    mkdir -p ${wsprnet_upload_dir}

    ### Create a /tmp/.. dir where this instance of the daemon will process and merge spotfiles.  Then it will copy them to the uploads.d directory in a persistent file system
    local posting_receiver_dir_path=$PWD
    local no_nl_real_receiver_list=( "${real_receiver_list[*]//$'\n'/ /}")
    wd_logger 1 "Starting to post '${posting_receiver_name},${posting_receiver_band}' in '${posting_receiver_dir_path}' and copy spots from real_rx(s) '${no_nl_real_receiver_list[@]}' to '${wsprnet_upload_dir}"

    ### Link the real receivers to this dir
    local posting_source_dir_list=()
    local real_receiver_name
    mkdir -p ${POSTING_SUPPLIERS_SUBDIR}
    for real_receiver_name in ${real_receiver_list[@]}; do
        ### Create posting subdirs for each real recording/decoding receiver to copy spot files
        ### If a schedule change disables this receiver, we will want to signal to the real receivers that we are no longer listening to their spots
        ### To find those receivers, create a posting dir under each real reciever and make a sybolic link from our posting subdir to that real posting dir
        ### Since both dirs are under /tmp, create a hard link between that new dir and a dir under the real receiver where it will copy its spots
        local real_receiver_dir_path=$(get_recording_dir_path ${real_receiver_name} ${posting_receiver_band})
        local real_receiver_posting_dir_path=${real_receiver_dir_path}/${DECODING_CLIENTS_SUBDIR}/${posting_receiver_name}
        ### Since this posting daemon may be running before it's supplier decoding_daemon(s), create the dir path for that supplier
        mkdir -p ${real_receiver_posting_dir_path}

        ### Now create a symlink from under here to the directory where spots will apper
        local this_rx_local_link_name=${POSTING_SUPPLIERS_SUBDIR}/${real_receiver_name}
        if [[ -L ${this_rx_local_link_name} ]]; then
            wd_logger 1 "Link from ${this_rx_local_link_name} to ${real_receiver_posting_dir_path} already exists"
        else
            wd_logger 1 "Creating a symlink from ${this_rx_local_link_name} to ${real_receiver_posting_dir_path}"
            ln -s ${real_receiver_posting_dir_path} ${this_rx_local_link_name}
        fi
        posting_source_dir_list+=(${this_rx_local_link_name})
        wd_logger 1 "Created a symlink from ${this_rx_local_link_name} to ${real_receiver_posting_dir_path}"
    done

    local supplier_dirs_list=(${real_receiver_list[@]/#/${POSTING_SUPPLIERS_SUBDIR}/})
    wd_logger 1 "Searching in subdirs: '${supplier_dirs_list[*]}' for '*_spots.txt' files"
    while true; do
        local spot_file_list=()
        while spot_file_list=( $( find -L ${supplier_dirs_list[@]} -type f -name '*_spots.txt' -printf "%f\n") ) \
            && [[ ${#spot_file_list[@]} -lt ${#supplier_dirs_list[@]} ]] ; do
            ### Make sure there is a decode daemon running for each rx + band 
            local real_receiver
            for real_receiver  in ${real_receiver_list[@]} ; do
                (spawn_decoding_daemon ${real_receiver} ${posting_receiver_band} ${posting_receiver_modes})  ### the '()' suppresses the effects of the 'cd' executed by spawn_decoding_daemon()
                local ret_code=$?
                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: failed to 'spawn_decoding_daemon ${real_receiver} ${posting_receiver_band} ${posting_receiver_modes}' => ${ret_code}"
                fi
            done
            wd_logger 1 "Found ${#spot_file_list[@]} *_spots.txt' files. Waiting for at least ${#supplier_dirs_list[@]} files"
            wd_sleep 1
        done
        ### There are enough spot files that we *may* be able to merge and post.
        local filename_list=( ${spot_file_list[@]##*/} )
        local filetimes_list=(${filename_list[@]%_spots.txt})
        local unique_times_list=( $( echo "${filetimes_list[@]}" | tr ' ' '\n' | sort -n | uniq) )
        wd_logger 1 "filename_list='${filename_list[*]}', filetimes_list='${filetimes_list[*]}, unique_times_list='${unique_times_list[*]}'"

        local spot_file_time 
        for spot_file_time in ${unique_times_list[@]} ; do
            ### Examine the spot files for each WSPR cycle time and if all are there for a cycle merge into one file to be uploaded to wsprnet.org
            local spot_file_name=${spotfile_time}_spots.txt
            local spot_file_time_list=( $(find -L ${POSTING_SUPPLIERS_SUBDIR} -type f -name ${spot_file_name}) )

            if [[ ${#spot_file_time_list[@]} -lt ${#supplier_dirs_list[@]} ]]; then
                if [[ ${spot_file_time} -eq ${unique_times_list[-1]} ]]; then
                    wd_logger 1 "There are only ${#spot_file_time_list[@]} of the expected  ${#supplier_dirs_list[@]} spot files for the most recent time ${spot_file_time}, so wait for the rest of the files"
                else
                    wd_logger 1 "Found ${#spot_file_time_list[@]} of the expected  ${#supplier_dirs_list[@]} spot files for older WSPR cycle time ${spot_file_time}, so go ahead and post what we have"
                    post_files ${spot_file_time} ${spot_file_time_list[@]}
                fi
            else
                if [[ ${#spot_file_time_list[@]} -gt ${#supplier_dirs_list[@]} ]]; then
                    wd_logger 1 "ERROR: found ${#spot_file_time_list[@]} spot files when only ${#supplier_dirs_list[@]} files were expected, but process all of them anyways"
                fi
                 wd_logger 1 "Posting ${#spot_file_time_list[@]} WSPR cycle time ${spot_file_time} spot files: '${spot_file_time_list[*]}'"
                post_files ${posting_receiver_band} ${wsprnet_upload_dir} ${spot_file_time} ${spot_file_time_list[@]}
            fi
        done
    done
}

function post_files()
{
    local receiver_band=$1
    local wsprnet_upload_dir=$2         ### This is derived from the call and grid defined for the MERGEd receiver
    local spot_time=$3
    local spot_file_list=($@:3)         ### We expect that all the spots in the list are from the same WSPR cycle

    wd_logger 1 "Post spots from ${#spot_file_list[@]} files: '${spot_file_list[*]}'"

    cat ${spot_file_list[@]} > spots.ALL
    if [[ -s spots.ALL ]]; then
        ### There are spots to upload
        ### For each CALL, get the spot with the best SNR, add that spot to spots.BEST which will contain only one spot for each file.
        ### If confiugred for "proxy" uploads, at the same time mark the spot line in the source file for proxy upload
        > spots.BEST
        local calls_list=( $( awk '{print $6}' spots.ALL | sort -u ) )
        local call
        for call in ${calls_list[@]}; do
            local best_line=( $( awk -v call=${call} '$6 == call {printf "%s: %s\n", FILENAME, $0}' ${spot_file_list[@]} | sort -k 4,4n | head -n 1) )
            local best_file=${best_line[0]}
            local best_spot=${best_line[@]:1}
            local best_spot_list=( ${best_spot} )
            best_spot_list[-1]=1                            ### The last field of an extended spot line is the 'proxy upload' flag: 0= No proxy upoad (default), 1=WD's upload server should upload this spot to wsprnet.org
            local best_spot_marked="${best_spot_list[*]}"
 
            wd_logger 1 "For call ${call} found the best spot '${best_spot}' in '${best_file}'. Add it to spots.BEST and change the line in the source file ${best_file}"

            echo "${best_spot_marked}" >> spots.BEST      ### Add the best spot for this call to the file which will be uploaded to wsprnet.org
            if [[ ${SIGNAL_LEVEL_UPLOAD} == "proxy" ]]; then
                ### Mark the line in the source file for proxy `upload
                grep -v -F "${best_spot}" ${best_file} > best.TMP
                echo "${best_spot_marked}" >> best.TMP
                sort -k 5,5n best.TMP > ${best_file}
            fi
        done
        if [[ ${posting_receiver_name} =~ MERG.* ]] && [[ ${LOG_MERGED_SNRS-yes} == "yes"  ]]; then
            log_merged_snrs  spots.BEST ${spot_file_list[@]}
        fi

        if [[ ${SIGNAL_LEVEL_UPLOAD} != "proxy" ]]; then
            ### We are configured to upload the best set of spots directly to wsprnet.org
            local wsprnet_uploads_queue_directory
            mkdir -p ${wsprnet_uploads_queue_directory}
            local  wsprnet_uploads_queue_filename=${wsprnet_uploads_queue_directory}/${spot_time}_spots.txt
            mv spots.BEST ${wsprnet_uploads_queue_filename}
            wd_logger 1 "Queued 'spots.BEST' which contains the $( wc -l < spots.BEST ) spots from the ${#calls_list[@]} calls found in the source files by moving it to ${wsprnet_uploads_queue_filename}"
        fi
    fi

    if [[ ${SIGNAL_LEVEL_UPLOAD} != "no" ]]; then
        ### We are configured to upload to wsprdaemon.org and/or configured for proxy uploads, queue all the spot files for upload to wsprdaemon.org
        wd_logger 1 "Queuing noise and spot files '${spot_file_list[*]}"
        local spot_file_list=( ${spot_file_list[@]} )
        local spot_file
        for spot_file in ${spot_file_list[@]} ; do
            local receiver_name=${spot_file#*/}
                  receiver_name=${receiver_name%/*}

            local receiver_call_grid=$(get_call_grid_from_receiver_name ${receiver_name})    ### So that receiver_call_grid can be used as a directory name, any '/' in the receiver call has been replaced with '=' 
            local upload_wsprdaemon_spots_dir=${UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR}/${receiver_call_grid}/${receiver_name}/${receiver_band}  
            mkdir -p ${upload_wsprdaemon_spots_dir}
            mv ${spot_file} ${upload_wsprdaemon_spots_dir}
            wd_logger 1 "Copied ${spot_file} to ${upload_wsprdaemon_spots_dir} which contains spot(s):\n$( cat ${upload_wsprdaemon_spots_dir}/${spot_file##*/})"

            ### The spots.txt file may be empty, but there will always be a noise file to be uploaded
            local noise_file=${spot_file/spots.txt/noise.txt}
            if [[ ! -f ${noise_file} ]]; then
                wd_logger 1 "ERROR: can't find expected noise file ${noise_file}"
            else
                local upload_wsprdaemon_noise_dir=${UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR}/${receiver_call_grid}/${receiver_name}/${receiver_band}
                mkdir -p ${upload_wsprdaemon_noise_dir}
                mv ${noise_file} ${upload_wsprdaemon_noise_dir}
                wd_logger 1 "Moved the noise file ${noise_file} to ${upload_wsprdaemon_noise_dir}"
            fi
        done
        wd_logger 1 "Done queuing noise and spot files"
    fi
    return 0
}

################### wsprdaemon uploads ####################################
### add tx and rx lat, lon, azimuths, distance and path vertex using python script. 
### In the main program, call this function with a file path/name for the input file, the tx_locator, the rx_locator and the frequency
### The appended data gets stored into ${DERIVED_ADDED_FILE} which can be examined. Overwritten each acquisition cycle.
declare DERIVED_ADDED_FILE=derived_azi.csv
declare AZI_PYTHON_CMD=${WSPRDAEMON_ROOT_DIR}/derived_calc.py

function add_derived() {
    local spot_grid=$1
    local my_grid=$2
    local spot_freq=$3    

    if [[ ! -f ${AZI_PYTHON_CMD} ]]; then
        wd_logger 0 "Can't find '${AZI_PYTHON_CMD}'"
        exit 1
    fi
    python3 ${AZI_PYTHON_CMD} ${spot_grid} ${my_grid} ${spot_freq} 1>add_derived.txt 2> add_derived.log
}

### For a group of MERGEd receivers: For each call output the to the file 'merged.log' one SNR reported for it to wsprnet.org and a list of SNRs (if any) reported for it by each real reciever 
function log_merged_snrs() 
{
    local best_snrs_file=$1
    local all_spot_files_list=( ${@:1} )

    local source_file_count=${#all_spot_files_list[@]}
    local source_spots_count=$(cat ${all_spot_files_list[@]} | wc -l)
    if [[ ${source_spots_count} -eq 0 ]] ;then
        ## There are no spots recorded in this wspr cycle, so don't log
        wd_logger 1 "Found no spot lines in the ${source_file_count} spot files: ${all_spot_files_list[*]}"
        return 0
    fi
 
    local posted_spots_count=$(cat ${wsprd_spots_best_file_path} | wc -l)
    local posted_calls_list=( $(awk '{print $7}' ${wsprd_spots_best_file_path}) )   ### This list will have already been sorted by frequency
    local posted_spots_count=${#posted_calls_list[@]}                               ### WD posts to wsprnet.org only the spot with the best SNR from each call, so sthe # of spots == #calls

    wd_logger 1 "Log the source of the ${posted_spots_count} posted spots taken from the total ${source_spots_count} spots reported by all the receivers in a MERGEd pool"
    
    printf "${WD_TIME_FMT}: %10s %8s %10s" "FREQUENCY" "CALL" "POSTED_SNR" -1  >> merged.log

    local real_receiver_list=( ${all_spot_files_list[@]#*/} )
          real_receiver_list=( ${real_receiver_list%/*}     )
    local receiver
    for receiver in ${real_receiver_list[@]}; do
        printf "%12s" ${receiver}                            >> merged.log
    done
    printf "       TOTAL=%2s, POSTED=%2s\n" ${source_spots_count} ${posted_spots_count} >> merged.log

    local call
    for call in ${posted_calls_list[@]}; do
        local posted_freq=$(${GREP_CMD} " $call " ${best_snrs_file} | awk '{print $6}')
        local posted_snr=$( ${GREP_CMD} " $call " ${best_snrs_file} | awk '{print $4}')
        printf "${WD_TIME_FMT}: %10s %8s %10s" -1 $posted_freq $call $posted_snr            >>  merged.log
        local file
        for file in ${all_spot_files_list[@]}; do
            ### Only pick the strongest SNR from each file which went into the .BEST file
            local rx_snr=$(${GREP_CMD} -F " $call " $file | sort -k 4,4n | tail -n 1 | awk '{print $4}')
            if [[ -z "$rx_snr" ]]; then
                printf "%12s" "*"                           >>  merged.log
            elif [[ $rx_snr == $posted_snr ]]; then
                printf "%11s%1s" $rx_snr "p"                >>  merged.log
            else
                printf "%11s%1s" $rx_snr " "                >>  merged.log
            fi
        done
        printf "\n"                                        >>  merged.log
    done
    truncate_file merged.log ${MAX_MERGE_LOG_FILE_SIZE-1000000}        ## Keep each of these logs to less than 1 MByte
    return 0
}
 

declare -r POSTING_DAEMON_PID_FILE="posting_daemon.pid"
declare -r POSTING_DAEMON_LOG_FILE="posting_daemon.log"

###
function spawn_posting_daemon() {
    local receiver_name=$1
    local receiver_band=$2
    local receiver_modes=$3

    wd_logger 1 "Starting with args ${receiver_name} ${receiver_band} ${receiver_modes}"
    local daemon_status
    if daemon_status=$(get_posting_status $receiver_name $receiver_band) ; then
        wd_logger 1 "Daemon for '${receiver_name}','${receiver_band}' is already running"
        return 0
    fi
    local receiver_address=$(get_receiver_ip_from_name ${receiver_name})
    local real_receiver_list=""

    if [[ "${receiver_name}" =~ ^MERG ]]; then
        ### This is a 'merged == virtual' receiver.  The 'real rx' which are merged to create this rx are listed in the IP address field of the config line
        real_receiver_list="${receiver_address//,/ }"
        wd_logger 1 "Creating merged rx '${receiver_name}' which includes real rx(s) '${receiver_address}' => list '${real_receiver_list[@]}'"  
    else
        wd_logger 1 "Creating real rx '${receiver_name}','${receiver_band}'"  
        real_receiver_list=${receiver_name} 
    fi
    local receiver_posting_dir=$(get_posting_dir_path ${receiver_name} ${receiver_band})
    mkdir -p ${receiver_posting_dir}
    cd ${receiver_posting_dir}
    wd_logger 1 "Spawning posting job ${receiver_name},${receiver_band},${receiver_modes} '${real_receiver_list}' in $PWD"
    WD_LOGFILE=${POSTING_DAEMON_LOG_FILE} posting_daemon ${receiver_name} ${receiver_band} ${receiver_modes} "${real_receiver_list}" &
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'posting_daemon ${receiver_name} ${receiver_band} ${receiver_modes} ${real_receiver_list}' => ${ret_code}"
        return 1
    fi
    local posting_pid=$!
    echo ${posting_pid} > ${POSTING_DAEMON_PID_FILE}

    cd - > /dev/null
    wd_logger 1 "Finished"
    return 0
}

###
function kill_posting_daemon() {
    local receiver_name=$1
    local receiver_band=$2

    local receiver_address=$(get_receiver_ip_from_name ${receiver_name})
    if [[ -z "${receiver_address}" ]]; then
        wd_logger 1 " No address(s) found for ${receiver_name}"
        return 1
    fi
    local posting_dir=$(get_posting_dir_path ${receiver_name} ${receiver_band})
    if [[ ! -d "${posting_dir}" ]]; then
        wd_logger 1 "Caan't find expected posting daemon dir ${posting_dir}"
        return 2
    else
        local posting_daemon_pid_file=${posting_dir}/${POSTING_DAEMON_PID_FILE}
        if [[ ! -f ${posting_daemon_pid_file} ]]; then
            wd_logger 1 "Can't find expected posting daemon file ${posting_daemon_pid_file}"
            return 3
        else
            local posting_pid=$(cat ${posting_daemon_pid_file})
            if ps ${posting_pid} > /dev/null ; then
                kill ${posting_pid}
                wd_logger 1 "Killed active posting_daemon() pid ${posting_pid} and deleting '${posting_daemon_pid_file}'"
            else
                wd_logger 1 "Pid ${posting_pid} was dead.  Deleting '${posting_daemon_pid_file}' it came from"
            fi
            rm -f ${posting_daemon_pid_file}
        fi
    fi

    local real_receiver_list=()
    if [[ "${receiver_name}" =~ ^MERG ]]; then
        ### This is a 'merged == virtual' receiver.  The 'real rx' which are merged to create this rx are listed in the IP address field of the config line
        wd_logger 1 "Stopping merged rx '${receiver_name}' which includes real rx(s) '${receiver_address}'"  
        real_receiver_list=(${receiver_address//,/ })
    else
        wd_logger 1 "Stopping real rx '${receiver_name}','${receiver_band}'"  
        real_receiver_list=(${receiver_name})
    fi

    if [[ -z "${real_receiver_list[@]}" ]]; then
        wd_logger 1 "Can't find expected real receiver(s) for '${receiver_name}','${receiver_band}'"
        return 3
    fi
    ### Signal all of the real receivers which are contributing ALL_WSPR files to this posting daemon to stop sending ALL_WSPRs by deleting the 
    ### associated subdir in the real receiver's posting.d subdir
    ### That real_receiver_posting_dir is in the /tmp/ tree and is a symbolic link to the real ~/wsprdaemon/.../real_receiver_posting_dir
    ### Leave ~/wsprdaemon/.../real_receiver_posting_dir alone so it retains any spot data for later uploads
    local posting_suppliers_root_dir=${posting_dir}/${POSTING_SUPPLIERS_SUBDIR}
    local real_receiver_name
    for real_receiver_name in ${real_receiver_list[@]} ; do
        local real_receiver_posting_dir=$(get_recording_dir_path ${real_receiver_name} ${receiver_band})/${DECODING_CLIENTS_SUBDIR}/${receiver_name}
        wd_logger 1 "Signaling real receiver ${real_receiver_name} to stop posting to ${real_receiver_posting_dir}"
        if [[ ! -d ${real_receiver_posting_dir} ]]; then
            wd_logger 1 "ERROR: kill_posting_daemon(${receiver_name},${receiver_band}) WARNING: expect posting directory  ${real_receiver_posting_dir} does not exist"
        else 
            wd_logger 1  "Removing '${posting_suppliers_root_dir}/${real_receiver_name}' and '${real_receiver_posting_dir}'"
            rm -f ${posting_suppliers_root_dir}/${real_receiver_name}     ## Remote the posting daemon's link to the source of spots
            rm -rf ${real_receiver_posting_dir}                          ### Remove the directory under the recording deamon where it puts spot files for this decoding daemon to process
            local real_receiver_posting_root_dir=${real_receiver_posting_dir%/*}
            local real_receiver_posting_root_dir_count=$(ls -d ${real_receiver_posting_root_dir}/*/ 2> /dev/null | wc -w)
            if [[ ${real_receiver_posting_root_dir_count} -gt 0 ]]; then
                wd_logger 1 "Found that decoding_daemon for ${real_receiver_name},${receiver_band} has other posting clients, so didn't signal the recoding and decoding daemons to stop"
            else
                if kill_decoding_daemon ${real_receiver_name} ${receiver_band}; then
                    wd_logger 1 "Decoding daemon has no more posting clients, so 'kill_decoding_daemon ${real_receiver_name} ${receiver_band}' => $?"
                else
                    wd_logger 1 "ERROR: 'kill_decoding_daemon ${real_receiver_name} ${receiver_band} => $?"
                fi
            fi
       fi
    done
    ### decoding_daemon() will terminate themselves if this posting_daemon is the last to be a client for wspr_spots.txt files
    return 0
}

#

##
function get_posting_status() {
    local rx_name=$1
    local rx_band=$2

    local posting_dir=$(get_posting_dir_path ${rx_name} ${rx_band})
    local pid_file=${posting_dir}/${POSTING_DAEMON_PID_FILE}

    if [[ ! -f ${pid_file} ]]; then
       [[ $verbosity -ge 0 ]] && echo "No pid file"
       return 2
    fi

    local posting_pid=$(< ${pid_file})
    if ! ps ${posting_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid '${posting_pid}' from file, but it is not running"
        return 3
    fi
    echo "Pid = ${posting_pid}"
    return 0
}

