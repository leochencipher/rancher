#!/bin/bash

DOCKER_MIN_VERSION="1.3.0"

check_debug()
{
    if [ -n "$CATTLE_SCRIPT_DEBUG" ] || echo "${@}" | grep -q -- --debug; then
        export CATTLE_SCRIPT_DEBUG=true
        export PS4='[${BASH_SOURCE##*/}:${LINENO}] '
        set -x
    fi
}
check_debug

load()
{
    if [ "$URL" = "etcd" ]; then
        return 0
    fi

    if [ "$URL" = "upgrade" ]; then
        eval $(docker inspect rancher-agent | jq -r '"export \"" + .[0].Config.Env[] + "\""')
    else
        CONTENT=$(curl -sL $URL)

        if [[ "$CONTENT" =~ .!/bin/sh.* ]]; then
            eval "$CONTENT"
        fi
    fi
}

check()
{
    if [[ "$URL" = "etcd" || "$URL" = "upgrade" ]]; then
        return 0
    fi
    curl -sL $URL >/dev/null 2>&1
}

verify_docker_client_server_version()
{
    docker version 2>&1 | grep Server\ version >/dev/null || {
        echo "Docker server API too old. Please upgrade Docker to version ${DOCKER_MIN_VERSION} or greater."
        exit 1
    }
}

if [ "$1" == "--" ]; then
    shift 1
    exec "$@"
fi

if [ "$1" = "" ]; then
    echo URL is required as a parameter 1>&2
    exit 1
fi

URL=$1

#check for the correct version of Docker.
verify_docker_client_server_version
IMAGE=$(docker inspect -f '{{.Image}}' $(hostname))

if [ -z "$IMAGE" ]; then
    IMAGE=rancher/agent:latest
else
    GATEWAY=$(docker run --rm --net=host $IMAGE -- ip route get 8.8.8.8 | grep via | awk '{print $7}')
    URL=$(echo $URL | sed -e 's/127.0.0.1/'$GATEWAY'/' -e 's/localhost/'$GATEWAY'/')
fi

CATTLE_AGENT_IMAGE=${CATTLE_AGENT_IMAGE:-$IMAGE}


i=0
while ! check; do
    if [ "$WAIT" = true ]; then
        echo Waiting for $URL
        sleep 1
    else
        echo "Invalid URL [$URL] or not authorized"
        if [ "$i" -lt 300 ]; then
            i=$((i+1))
            echo "Will retry in another second"
            sleep 1
            continue
        fi
        exit 1
    fi
done

load

if [[ "$URL" != "upgrade" && -z "$CATTLE_REGISTRATION_SECRET_KEY" ]]; then
    CATTLE_URL_ARG=$URL
fi

export CATTLE_AGENT_IP=${CATTLE_AGENT_IP:-$DETECTED_CATTLE_AGENT_IP}

while docker inspect rancher-agent >/dev/null 2>&1; do
    docker rm -f rancher-agent
    sleep 1
done


docker run \
    --net=host \
    --restart=always \
    --privileged \
    --name rancher-agent \
    --privileged \
    -e CATTLE_SCRIPT_DEBUG=${CATTLE_SCRIPT_DEBUG} \
    -e ETCD_URL=${ETCD_URL} \
    -e CATTLE_EXEC_AGENT=true \
    -e CATTLE_REGISTRATION_ACCESS_KEY="${CATTLE_REGISTRATION_ACCESS_KEY}" \
    -e CATTLE_REGISTRATION_SECRET_KEY="${CATTLE_REGISTRATION_SECRET_KEY}" \
    -e CATTLE_AGENT_IP="${CATTLE_AGENT_IP}" \
    -e CATTLE_URL="${CATTLE_URL}" \
    -e CATTLE_URL_ARG="${CATTLE_URL_ARG}" \
    -v /lib/modules:/host/lib/modules \
    -v /var/lib/docker:/host/var/lib/docker \
    -v /var/lib/cattle:/host/var/lib/cattle \
    -v /opt/bin:/host/opt/bin \
    -v /proc:/host/proc \
    -v /run:/host/run \
    -v /var/run:/host/var/run \
    -d \
    "${CATTLE_AGENT_IMAGE}" -- /agent-env.sh
