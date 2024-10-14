#!/bin/bash
# Uncomment the awk statement if you want to use mac as
# dhcp-identifier in Ubuntu
#awk '/^[[:space:]-]*dhcp4/{ split($0,arr,/dhcp4.*/)
#                           gsub(/-/," ", arr[1])
#                           rep=arr[1]
#                           print $0}
#                      rep{ printf "%s%s\n", rep, "dhcp-identifier: mac"
#                      rep=""
#                      next} 1' /etc/netplan/50-cloud-init.yaml | sudo tee /etc/netplan/50-cloud-init.yaml

# This ensures machine-id is generated during first boot and a unique
# dhcp IP is assigned to the VM
echo -n | sudo tee /etc/machine-id
#Lock password for the ssh user (peerpod) to disallow logins
#sudo passwd -l peerpod

# install required packages
if [ "$CLOUD_PROVIDER" == "vsphere" ]
then
# Add vsphere specific commands to execute on remote
    case $PODVM_DISTRO in
    rhel)
        (! dnf list --installed | grep open-vm-tools > /dev/null 2>&1) && \
        (! dnf -y install open-vm-tools) && \
             echo "$PODVM_DISTRO: Error installing package required for cloud provider: $CLOUD_PROVIDER" 1>&2 && exit 1
        ;;
    ubuntu)
        (! dpkg -l | grep open-vm-tools > /dev/null 2>&1) && apt-get update && \
        (! apt-get -y install open-vm-tools > /dev/null 2>&1) && \
             echo "$PODVM_DISTRO: Error installing package required for cloud provider: $CLOUD_PROVIDER" 1>&2  && exit 1
        ;;
    *)
        ;;
    esac
fi

if [[ "$CLOUD_PROVIDER" == "azure" || "$CLOUD_PROVIDER" == "generic" ]] && [[ "$PODVM_DISTRO" == "ubuntu" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://download.01.org/intel-sgx/sgx_repo/ubuntu/intel-sgx-deb.key | sudo apt-key add -
    echo "deb [arch=amd64] https://download.01.org/intel-sgx/sgx_repo/ubuntu $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/intel-sgx.list

    sudo apt-get update
    sudo apt-get install -y --no-install-recommends libtss2-tctildr0 libtdx-attest
fi

# Setup oneshot systemd service for AWS and Azure to enable NAT rules
if [ "$CLOUD_PROVIDER" == "azure" ] || [ "$CLOUD_PROVIDER" == "aws" ] || [ "$CLOUD_PROVIDER" == "generic" ]
then
    if [ ! -x "$(command -v iptables)" ]; then
        case $PODVM_DISTRO in
        rhel | fedora)
            dnf -q install iptables -y
            ;;
        ubuntu)
            apt-get -qq update && apt-get -qq install iptables -y
            ;;
        *)
            echo "\"iptables\" is missing and cannot be installed, setup-nat-for-imds.sh is likely to fail 1>&2"
            ;;
        esac
    fi

    # Enable oneshot serivce
    systemctl enable setup-nat-for-imds
fi

if [ -e /etc/certificates/tls.crt ] && [ -e /etc/certificates/tls.key ] && [ -e /etc/certificates/ca.crt ]; then
    # Update systemd service file to add additional options
    cat <<END >> /etc/default/agent-protocol-forwarder
TLS_OPTIONS=-cert-file /etc/certificates/tls.crt -cert-key /etc/certificates/tls.key -ca-cert-file /etc/certificates/ca.crt
END
elif [ -e /etc/certificates/tls.crt ] && [ -e /etc/certificates/tls.key ] && [ ! -e /etc/certificates/ca.crt ]; then
    # Update systemd service file to add additional options
    cat <<END >> /etc/default/agent-protocol-forwarder
TLS_OPTIONS=-cert-file /etc/certificates/tls.crt -cert-key /etc/certificates/tls.key
END
fi

# If DISABLE_CLOUD_CONFIG is not set or not set to true, then add cloud-init.target as a dependency for process-user-data.service
# so that required files via cloud-config are available before kata-agent starts
if [ -z "$DISABLE_CLOUD_CONFIG" ] || [ "$DISABLE_CLOUD_CONFIG" != "true" ]
then
# Add cloud-init.target as a dependency for process-user-data.service so that
# required files via cloud-config are available before kata-agent starts
    mkdir -p /etc/systemd/system/process-user-data.service.d
    cat <<END >> /etc/systemd/system/process-user-data.service.d/10-override.conf
[Unit]
After=cloud-config.service

[Service]
ExecStartPre=
END
fi

if [ -n "${FORWARDER_PORT}" ]; then
    cat <<END >> /etc/default/agent-protocol-forwarder 
OPTIONS=-listen 0.0.0.0:${FORWARDER_PORT}
END
fi

# Disable unnecessary systemd services

case $PODVM_DISTRO in
    rhel)
        systemctl disable kdump.service
        systemctl disable tuned.service
        systemctl disable firewalld.service
        ;;
    ubuntu)
        systemctl disable apt-daily.service
        systemctl disable apt-daily.timer
        systemctl disable apt-daily-upgrade.timer
        systemctl disable apt-daily-upgrade.service
        systemctl disable snapd.service
        systemctl disable snapd.seeded.service
        systemctl disable snap.lxd.activate.service
        ;;
esac

if  [[ "$PODVM_DISTRO" == "fedora" ]]; then
       #curl -L https://gist.githubusercontent.com/snir911/ca037add284558a7ec8d55acd192f4bb/raw/990a16145841cf999188e77b99a47c342bf0dd88/podvmh100.sh.b | bash || exit 1
       NVIDIA_USERSPACE_VERSION=${NVIDIA_USERSPACE_VERSION:-1.16.1-1}
       NVIDIA_USERSPACE_PKGS=(nvidia-container-toolkit libnvidia-container1 libnvidia-container-tools)

       # Create the prestart hook directory
       mkdir -p /usr/share/oci/hooks/prestart

       # Add hook script ############################## i hacked this due to a bug suspected
       cat <<'END' >  /usr/share/oci/hooks/prestart/nvidia-container-toolkit.sh
#!/bin/bash -x

# Log the o/p of the hook to a file
/usr/bin/nvidia-container-toolkit -debug "$@" > /var/log/nvidia-hook.log 2>&1
END

       # Make the script executable
       chmod +x /usr/share/oci/hooks/prestart/nvidia-container-toolkit.sh


       cat << EOF >  /usr/lib/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
       dracut --force


      # install driver
      wget https://us.download.nvidia.com/tesla/550.90.12/NVIDIA-Linux-x86_64-550.90.12.run
      sudo sh ./NVIDIA-Linux-x86_64-550.90.12.run -m=kernel-open -s #--kernel-source-path=/usr/src/kernels/6.11.3-100.fc39.x86_64/


      # install userspace stuff
      dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/fedora39/x86_64/cuda-fedora39.repo
      #dnf module install -y nvidia-driver:open-dkms

      # install userspace stuff
      dnf install -y "${NVIDIA_USERSPACE_PKGS[@]/%/-${NVIDIA_USERSPACE_VERSION}}"

      #misc
      cat << EOF > /etc/rc.d/rc.local
#!/bin/bash
nvidia-persistenced
nvidia-smi conf-compute -srs 1
EOF
      sudo chmod +x /etc/rc.d/rc.local

fi

exit 0
