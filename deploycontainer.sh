#!/bin/bash

#********************************************************************************
# Copyright 2014 IBM
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#********************************************************************************

# load helper functions
source $(dirname "$0")/deploy_utilities.sh

dump_info () {
    log_and_echo "$LABEL" "Container Information: "
    log_and_echo "$LABEL" "Information about this organization and space:"
    log_and_echo "$INFO" " Summary:"
    local ICEINFO=$(ice info 2>/dev/null)
    log_and_echo "$INFO" " $ICEINFO"


    export CONTAINER_LIMIT=$(echo "$ICEINFO" | grep "Containers limit" | awk '{print $4}')
    # if container limit is disabled no need to check and warn
    if [ ! -z ${CONTAINER_LIMIT} ]; then
        if [ ${CONTAINER_LIMIT} -ge 0 ]; then
            export CONTAINER_COUNT=$(echo "$ICEINFO" | grep "Containers usage" | awk '{print $4}')
            local WARNING_LEVEL="$(echo "$CONTAINER_LIMIT - 2" | bc)"

            if [ ${CONTAINER_COUNT} -ge ${CONTAINER_LIMIT} ]; then
                log_and_echo "$ERROR" "You have ${CONTAINER_COUNT} containers running, and may reached the default limit on the number of containers "
            elif [ ${CONTAINER_COUNT} -ge ${WARNING_LEVEL} ]; then
                log_and_echo "$WARN" "There are ${CONTAINER_COUNT} containers running, which is approaching the limit of ${CONTAINER_LIMIT}"
            fi
        fi
    fi

    # check memory limit, warn user if we're at or approaching the limit
    export MEMORY_LIMIT=$(echo "$ICEINFO" | grep "Memory limit" | awk '{print $5}')
    # if memory limit is disabled no need to check and warn
    if [ ! -z ${MEMORY_LIMIT} ]; then
        if [ ${MEMORY_LIMIT} -ge 0 ]; then
            export MEMORY_USAGE=$(echo "$ICEINFO" | grep "Memory usage" | awk '{print $5}')
            local MEM_WARNING_LEVEL="$(echo "$MEMORY_LIMIT - 512" | bc)"

            if [ ${MEMORY_USAGE} -ge ${MEMORY_LIMIT} ]; then
                log_and_echo "$ERROR" "You are using ${MEMORY_USAGE} MB of memory, and may have reached the default limit for memory used "
            elif [ ${MEMORY_USAGE} -ge ${MEM_WARNING_LEVEL} ]; then
                log_and_echo "$WARN" "You are using ${MEMORY_USAGE} MB of memory, which is approaching the limit of ${MEMORY_LIMIT}"
            fi
        fi
    fi

#    export IP_LIMIT=$(echo "$ICEINFO" | grep "Floating IPs limit" | awk '{print $5}')
#    export IP_COUNT=$(echo "$ICEINFO" | grep "Floating IPs usage" | awk '{print $5}')
#
#    local AVAILABLE="$(echo "$IP_LIMIT - $IP_COUNT" | bc)"
#    if [ ${AVAILABLE} -le 0 ]; then
#        echo -e "${red}You have reached the default limit for the number of available public IP addresses${no_color}"
#    else
#        echo -e "${label_color}You have ${AVAILABLE} public IP addresses remaining${no_color}"
#    fi

    log_and_echo "Groups: "
    log_and_echo `ice group list 2> /dev/null`
    log_and_echo "Routes: "
    log_and_echo `cf routes`
    log_and_echo "Running Containers: "
    log_and_echo `ice ps 2> /dev/null`
    log_and_echo "Floating IP addresses"
    log_and_echo `ice ip list 2> /dev/null`
    log_and_echo "Images:"
    log_and_echo `ice images`
    return 0
}

update_inventory(){
    local TYPE=$1
    local NAME=$2
    local ACTION=$3
    if [ $# -ne 3 ]; then
        log_and_echo "$ERROR" "updating inventory expects a three inputs: 1. type 2. name 3. action. Where type is either group or container, and the name is the name of the container being added to the inventory."
        return 1
    fi
    local ID="undefined"
    # find the container or group id
    if [ "$TYPE" == "ibm_containers" ]; then
        ID=$(ice inspect ${NAME} 2> /dev/null | grep "\"Id\":" | awk '{print $2}')
        local RESULT=$?
        if [ $RESULT -ne 0 ]; then
            log_and_echo "$ERROR" "Could not find container called $NAME"
            ice ps 2> /dev/null
            return 1
        fi

    elif [ "${TYPE}" == "ibm_containers_group" ]; then
        ID=$(ice group inspect ${NAME} 2> /dev/null | grep "\"Id\":" | awk '{print $2}')
        if [ $RESULT -ne 0 ]; then
            log_and_echo "$ERROR" "Could not find group called $NAME"
            ice group list 2> /dev/null
            return 1
        fi
    else
        log_and_echo "$ERROR" "Could not update inventory with unknown type: ${TYPE}"
        return 1
    fi

    local JOB_TYPE=""
    # trim off junk
    local temp="${ID%\",}"
    ID="${temp#\"}"
    log_and_echo "The ID of the $TYPE is: $ID"

    # find other inventory information
    log_and_echo "$LABEL" "Updating inventory with $TYPE of $NAME "
    local IDS_INV_URL="${IDS_URL%/}"
    local IDS_REQUEST=$TASK_ID
    local IDS_DEPLOYER=${JOB_NAME##*/}
    if [ ! -z "$COPYARTIFACT_BUILD_NUMBER" ] ; then
        IDS_VERSION_TYPE="JENKINS_BUILD_ID"
        IDS_VERSION=$COPYARTIFACT_BUILD_NUMBER
    elif [ ! -z "$CS_BUILD_SELECTOR" ] ; then
        IDS_VERSION_TYPE="JENKINS_BUILD_ID"
        IDS_VERSION=$CS_BUILD_SELECTOR
    else
            IDS_VERSION_TYPE="SCM_REV_ID"
        if [ ! -z "$GIT_COMMIT" ] ; then
            IDS_VERSION=$GIT_COMMIT
        elif [ ! -z "$RTCBuildResultUUID" ] ; then
            IDS_VERSION=$RTCBuildResultUUID
        fi
    fi

    if [ -z "$IDS_RESOURCE" ]; then
        local IDS_RESOURCE="https://hub.jazz.net/pipeline"
    fi

    if [ -z "$IDS_VERSION" ]; then
        local IDS_RESOURCE="1"
    fi

    IDS_RESOURCE=$CF_SPACE_ID
    if [ -z "$IDS_RESOURCE" ]; then
        log_and_echo "$ERROR" "Could not find CF SPACE in environment, using production space id"
    else
        # call IBM DevOps Service Inventory CLI to update the entry for this deployment
        log_and_echo "bash ids-inv -a ${ACTION} -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ${TYPE} -u $IDS_INV_URL -v $IDS_VERSION"
        bash ids-inv -a ${ACTION} -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ${TYPE} -u $IDS_INV_URL -v $IDS_VERSION
    fi
}

insert_inventory(){
    update_inventory $1 $2 "insert"
}
delete_inventory(){
    update_inventory $1 $2 "delete"
}

# function to wait for a container to start
# takes a container name as the only parameter
wait_for (){
    local WAITING_FOR=$1
    if [ -z ${WAITING_FOR} ]; then
        log_and_echo "$ERROR" "Expected container name to be passed into wait_for"
        return 1
    fi
    local COUNTER=0
    local STATE="unknown"
    while [[ ( $COUNTER -lt 180 ) && ("${STATE}" != "Running") && ("${STATE}" != "Crashed") ]]; do
        let COUNTER=COUNTER+1
        STATE=$(ice inspect $WAITING_FOR 2> /dev/null | grep "Status" | awk '{print $2}' | sed 's/"//g')
        if [ -z "${STATE}" ]; then
            STATE="being placed"
        fi
        log_and_echo "${WAITING_FOR} is ${STATE}"
        sleep 3
    done
    if [ "$STATE" == "Crashed" ]; then
        log_and_echo "$ERROR" "Container instance crashed. Removing the crashed container ${WAITING_FOR} "
        ice rm ${WAITING_FOR} 2> /dev/null
        return 1
    fi
    if [ "$STATE" != "Running" ]; then
        log_and_echo "$ERROR" "Failed to start instance "
        return 1
    fi
    return 0
}

# function to wait for a container to start
# takes a container name as the only parameter
wait_for_stopped (){
    local WAITING_FOR=$1
    if [ -z ${WAITING_FOR} ]; then
        log_and_echo "$ERROR" "Expected container name to be passed into wait_for"
        return 1
    fi
    local COUNTER=0
    local FOUND=0
    while [[ ( $COUNTER -lt 60 ) && ("${STATE}" != "Shutdown")  ]]; do
        let COUNTER=COUNTER+1
        STATE=$(ice inspect $WAITING_FOR 2> /dev/null | grep "Status" | awk '{print $2}' | sed 's/"//g')
        if [ -z "${STATE}" ]; then
            STATE="being deleted"
        fi
        sleep 2
    done
    if [ "$STATE" != "Shutdown" ]; then
        log_and_echo "$ERROR" "Failed to stop instance $WAITING_FOR "
        return 1
    else
        log_and_echo "Successfully stopped $WAITING_FOR"
    fi
    return 0
}

deploy_container() {
    local MY_CONTAINER_NAME=$1
    log_and_echo "deploying container ${MY_CONTAINER_NAME}"

    if [ -z MY_CONTAINER_NAME ];then
        log_and_echo "$ERROR" "No container name was provided"
        return 1
    fi

    # check to see if that container name is already in use
    ice inspect ${MY_CONTAINER_NAME} > /dev/null
    local FOUND=$?
    if [ ${FOUND} -eq 0 ]; then
        log_and_echo "$ERROR" "${MY_CONTAINER_NAME} already exists.  Please remove these containers or change the Name of the container or group being deployed"
    fi

    local BIND_PARMS=""
    # validate the bind_to parameter if one was passed
    if [ ! -z "${BIND_TO}" ]; then
        log_and_echo "Binding to ${BIND_TO}"
        local APP=$(cf env ${BIND_TO})
        local APP_FOUND=$?
        if [ $APP_FOUND -ne 0 ]; then
            log_and_echo "$ERROR" "${BIND_TO} application not found in space.  Please confirm that you wish to bind the container to the application, and that the application exists"
        fi
        local VCAP_SERVICES=$(echo "${APP}" | grep "VCAP_SERVICES")
        local SERVICES_BOUND=$?
        if [ $SERVICES_BOUND -ne 0 ]; then
            log_and_echo "$WARN" "No services appear bound to ${BIND_TO}.  Please confirm that you have bound the intended services to the application."
        fi
        BIND_PARMS="--bind ${BIND_TO}"
    fi
    # run the container and check the results
    log_and_echo "run the container: ice run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME} "
    ice run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME} 2> /dev/null
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Failed to deploy ${MY_CONTAINER_NAME} using ${IMAGE_NAME}"
        dump_info
        return 1
    fi

    # wait for container to start
    wait_for ${MY_CONTAINER_NAME}
    RESULT=$?
    if [ $RESULT -eq 0 ]; then
        insert_inventory "ibm_containers" ${MY_CONTAINER_NAME}
    fi
    return ${RESULT}
}

deploy_simple () {
    local MY_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_container ${MY_CONTAINER_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Error encountered with simple build strategy for ${CONTAINER_NAME}_${BUILD_NUMBER}"
        exit $RESULT
    fi
}

deploy_red_black () {
    log_and_echo "$LABEL" "Example red_black container deploy "
    # deploy new version of the application
    local MY_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    local FLOATING_IP=""
    local IP_JUST_FOUND=""
    deploy_container ${MY_CONTAINER_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        exit $RESULT
    fi

    log_and_echo "Cleaning up previous deployments.  Will keep ${CONCURRENT_VERSIONS} versions active."
    local COUNTER=0
    if [ -z "$REMOVE_FROM" ]; then
        COUNTER=${BUILD_NUMBER}
    else
        COUNTER=$REMOVE_FROM
    fi
    local FOUND=0
    until [  $COUNTER -lt 1 ]; do
        ice inspect ${CONTAINER_NAME}_${COUNTER} > inspect.log 2> /dev/null
        RESULT=$?
        if [ $RESULT -eq 0 ]; then
            log_and_echo "Found container ${CONTAINER_NAME}_${COUNTER}"
            # does it have a public IP address
            let FOUND+=1

            if [ -z "${FLOATING_IP}" ]; then
                FLOATING_IP=$(cat inspect.log | grep "PublicIpAddress" | awk '{print $2}')
                temp="${FLOATING_IP%\"}"
                FLOATING_IP="${temp#\"}"
                if [ -n "${FLOATING_IP}" ]; then
                   log_and_echo "Discovered previous IP ${FLOATING_IP}"
                   IP_JUST_FOUND=$FLOATING_IP
                fi
            else
                log_and_echo "Did not search for previous IP because we have already discovered $FLOATING_IP"
            fi
            if [ "${COUNTER}" -ne "${BUILD_NUMBER}" ]; then
                # this is a previous deployment
                if [ -z "${FLOATING_IP}" ]; then
                    log_and_echo "${CONTAINER_NAME}_${COUNTER} did not have a floating IP so will need to discover one from previous deployment or allocate one"
                elif [ -n "${IP_JUST_FOUND}" ]; then
                    log_and_echo "${CONTAINER_NAME}_${COUNTER} had a floating ip ${FLOATING_IP}"
                    ice ip unbind ${FLOATING_IP} ${CONTAINER_NAME}_${COUNTER} 2> /dev/null
                    sleep 2
                    ice ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
                fi
                if [ $FOUND -le $CONCURRENT_VERSIONS ]; then
                    log_and_echo "keeping previous deployment: ${CONTAINER_NAME}_${COUNTER}"
                else
                    log_and_echo "removing previous deployment: ${CONTAINER_NAME}_${COUNTER}"
                    ice stop ${CONTAINER_NAME}_${COUNTER}
                    wait_for_stopped ${CONTAINER_NAME}_${COUNTER}
                    ice rm ${CONTAINER_NAME}_${COUNTER} 2> /dev/null
                    delete_inventory "ibm_containers" ${CONTAINER_NAME}_${COUNTER}
                fi
            fi
            IP_JUST_FOUND=""
        fi
        let COUNTER-=1
    done
    # check to see that I obtained a floating IP address
    #ice inspect ${CONTAINER_NAME}_${BUILD_NUMBER} > inspect.log
    #FLOATING_IP=$(cat inspect.log | grep "PublicIpAddress" | awk '{print $2}')
    if [ "${FLOATING_IP}" = '""' ] || [ -z "${FLOATING_IP}" ]; then
        log_and_echo "Requesting IP"
        FLOATING_IP=$(ice ip request 2> /dev/null | awk '{print $4}' | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            log_and_echo "$WARN" "Failed to request new IP address, will attempt to reuse existing IP"
            FLOATING_IP=$(ice ip list 2> /dev/null | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}[[:space:]]*$' | head -n 1)
            #FLOATING_IP=$(ice ip list 2> /dev/null | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n 1)
            #strip off whitespace
            FLOATING_IP=${FLOATING_IP// /}
            if [ -z "${FLOATING_IP}" ];then
                log_and_echo "$ERROR" "Could not request a new, or reuse an existing IP address "
                dump_info
                exit 1
            else
                log_and_echo "Assigning existing IP address $FLOATING_IP"
            fi
        else
            # strip off junk
            temp="${FLOATING_IP%\"}"
            FLOATING_IP="${temp#\"}"
            log_and_echo "Assigning new IP address $FLOATING_IP"
        fi
        ice ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            log_and_echo "$ERROR" "Failed to bind ${FLOATING_IP} to ${CONTAINER_NAME}_${BUILD_NUMBER} "
            log_and_echo "Unsetting TEST_URL"
            export TEST_URL=""
            dump_info
            exit 1
        fi
    else
        ice ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
    fi
    log_and_echo "Exporting TEST_URL:${TEST_URL}"
    export TEST_URL="${URL_PROTOCOL}${FLOATING_IP}:$(echo $PORT | sed 's/,/ /g' |  awk '{print $1;}')"

    log_and_echo "${green}Public IP address of ${CONTAINER_NAME}_${BUILD_NUMBER} is ${FLOATING_IP} and the TEST_URL is ${TEST_URL} ${no_color}"
}

clean() {
    log_and_echo "Cleaning up previous deployments.  Will keep ${CONCURRENT_VERSIONS} versions active."
    local COUNTER=0
    if [ -z "$REMOVE_FROM" ]; then
        COUNTER=${BUILD_NUMBER}
    else
        COUNTER=$REMOVE_FROM
    fi
    local FOUND=0
    until [  $COUNTER -lt 1 ]; do
        log_and_echo "Looking for and inspecting ${CONTAINER_NAME}_${COUNTER}"
        ice inspect ${CONTAINER_NAME}_${COUNTER} > inspect.log
        local RESULT=$?
        if [ $RESULT -eq 0 ]; then
            log_and_echo "Found previous container ${CONTAINER_NAME}_${COUNTER}"
            let FOUND+=1
            if [ $FOUND -le $CONCURRENT_VERSIONS ]; then
                # this is the previous version so keep it around
                log_and_echo "keeping deployment: ${CONTAINER_NAME}_${COUNTER}"
            elif [[ ( -n "${ROUTE_DOMAIN}" ) && ( -n "${ROUTE_HOSTNAME}" ) ]]; then
                # remove this container
                log_and_echo "removing route $ROUTE_HOSTNAME $ROUTE_DOMAIN from ${CONTAINER_NAME}_${COUNTER}"
                ice route unmap --hostname $ROUTE_HOSTNAME --domain $ROUTE_DOMAIN ${CONTAINER_NAME}_${COUNTER}
                sleep 2
                log_and_echo "removing ${CONTAINER_NAME}_${COUNTER}"
                ice rm ${CONTAINER_NAME}_${COUNTER}
                delete_inventory "ibm_containers" ${CONTAINER_NAME}_${COUNTER}
            else
                log_and_echo "removing ${CONTAINER_NAME}_${COUNTER}"
                ice rm ${CONTAINER_NAME}_${COUNTER}
                delete_inventory "ibm_containers" ${CONTAINER_NAME}_${COUNTER}
            fi
        fi
        let COUNTER-=1
    done
    log_and_echo "Cleaned up previous deployments"
    return 0
}

##################
# Initialization #
##################
# Check to see what deployment type:
#   simple: simply deploy a container and set the inventory
#   red_black: deploy new container, assign floating IP address, keep original container
if [ -z "$URL_PROTOCOL" ]; then
 export URL_PROTOCOL="http://"
fi

# set the port numbers with --publish
if [ -z "$PORT" ]; then
    export PUBLISH_PORT="--publish 80"
else
    export PUBLISH_PORT=$(get_port_numbers "${PORT}")
fi

# set the memory size
if [ -z "$CONTAINER_SIZE" ];then
    export MEMORY=""
else
    RET_MEMORY=$(get_memory_size $CONTAINER_SIZE)
    if [ $RET_MEMORY == -1 ]; then
        exit 1;
    else
        export MEMORY="--memory $RET_MEMORY"
    fi
fi

# set current version
if [ -z "$CONCURRENT_VERSIONS" ];then
    export CONCURRENT_VERSIONS=1
fi

log_and_echo "$LABEL" "Deploying using ${DEPLOY_TYPE} strategy, for ${CONTAINER_NAME}, deploy number ${BUILD_NUMBER}"
if [ "${DEPLOY_TYPE}" == "red_black" ]; then
    deploy_red_black
elif [ "${DEPLOY_TYPE}" == "clean" ]; then
    clean
else
    log_and_echo "$WARN" "Currently only supporting red_black deployment strategy"
    log_and_echo "$WARN" "If you would like another strategy please fork https://github.com/Osthanes/deployscripts.git and submit a pull request"
    log_and_echo "$WARN" "Defaulting to red_black deploy"
    deploy_red_black
fi
dump_info
exit 0
