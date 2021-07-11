#!/bin/bash

source ./common/common_functions.sh

export RECLONE=${RECLONE:-true}
export WORKSPACE=${WORKSPACE:-/tmp/k8s_$$}
export LOGDIR=$WORKSPACE/logs
export ARTIFACTS=$WORKSPACE/artifacts
export TIMEOUT=${TIMEOUT:-300}
export POLL_INTERVAL=${POLL_INTERVAL:-10}

export PROJECT_URL=${PROJECT_URL}
export PROJECT_PR=${PROJECT_PR}
export PROJECT_NAME=${PROJECT_NAME}

clone_project(){
    local status=0

    if [[ -e ""$WORKSPACE"/"$PROJECT_NAME"" ]];then
        rm -rf "$WORKSPACE"/"$PROJECT_NAME"
    fi

    git clone "${PROJECT_URL}" "$WORKSPACE"/"$PROJECT_NAME"

    pushd $WORKSPACE/"$PROJECT_NAME"

    # Check if part of Pull Request and
    git fetch --tags --progress ${PROJECT_URL} +refs/pull/${PROJECT_PR}/*:refs/remotes/origin/pull-requests/${PROJECT_PR}/*
    let status=$status+$?

    git checkout pull-requests/${PROJECT_PR}/head
    let status=$status+$?

    git log -p -1 > $ARTIFACTS/${PROJECT_NAME}-git.txt

    popd

    return $status
}

validate_copyrights(){
    local status=0
    local exclude_list=" "

    pushd "$WORKSPACE"/"$PROJECT_NAME"

    for file in $(git diff --name-status master HEAD | grep -E 'A' | awk '{print $2}' | grep -v ${exclude_list});do
        echo "validiting $file to match \"$(date +%Y) NVIDIA CORPORATION & AFFILIATES\"....."

        if ! grep -q "$(date +%Y) NVIDIA CORPORATION & AFFILIATES" "${WORKSPACE}/${PROJECT_NAME}/${file}";then
            let status=$status+1
            echo "    -Failed!"
        else
            echo "    -Passed!"
        fi

        echo ""
    done

    popd

    return $status
}

print_copyrights(){

    echo ""
    echo "Please use the following copy rights notice in the beggining of the failed files:"
    echo "----------------------------------------------------"
    echo "
  $(date +%Y) NVIDIA CORPORATION & AFFILIATES

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
"
    echo "----------------------------------------------------"
}

main(){
    local status=0

    create_workspace

    if ! clone_project;then
        echo "Failed to fetch and checkout project ${PROJECT_NAME} PR ${PROJECT_PR}!"
        return 1
    fi

    if ! validate_copyrights;then
        echo "Failed to validate the projects copyrights!"
        print_copyrights
        return 1
    fi
}

global_status=0

if main;then
    echo "Copyright validation suceeded!"
else
    echo "Copyright validation failed!"
    global_status=1
fi

echo "All code in $WORKSPACE"
echo "All logs $LOGDIR"
echo "All confs $ARTIFACTS"

exit $global_status
