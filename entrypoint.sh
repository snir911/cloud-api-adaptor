#!/bin/bash

CLOUD_PROVIDER=${1:-$CLOUD_PROVIDER}

test_vars() {
        for i in $@; do
                [ -z ${!i} ] && echo "\$$i is NOT set" && EXT=1
        done
        [[ -n $EXT ]] && exit 1
}

aws() {
test_vars AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
set -x
cloud-api-adaptor aws \
	-aws-access-key-id ${AWS_ACCESS_KEY_ID} \
	-aws-secret-key ${AWS_SECRET_ACCESS_KEY} \
	-aws-region ${AWS_REGION} \
	-pods-dir /run/peerpod/pods \
	-socket /run/peerpod/hypervisor.sock
}

libvirt() {
test_vars LIBVIRT_URI
set -x
cloud-api-adaptor-libvirt libvirt \
	-uri ${LIBVIRT_URI} \
	-data-dir /opt/data-dir \
	-pods-dir /run/peerpod/pods \
	-network-name ${LIBVIRT_NET:-default} \
	-pool-name ${LIBVIRT_POOL:-default} \
	-socket /run/peerpod/hypervisor.sock
}

help_msg() {
	cat <<EOF
Usage:
	CLOUD_PROVIDER=aws|libvirt $0
or
	$0 aws|libvirt
in addition all cloud provider specific env variables must be set and valid
(CLOUD_PROVIDER is currently set to "$CLOUD_PROVIDER")
EOF
}

if [[ "$CLOUD_PROVIDER" == "aws" ]]; then
	aws
elif [[ "$CLOUD_PROVIDER" == "libvirt" ]]; then
	libvirt
else
	help_msg
fi
