#!/bin/bash

NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION} # must be set explicitly to pin version
KERNEL_VERSION=${KERNEL_VERSION} # must be set explicitly to pin version
NVIDIA_DRIVER_BRANCH=${NVIDIA_DRIVER_VERSION%.*.*} # if version is set, derive the branch
NVIDIA_DRIVER_BRANCH=${NVIDIA_DRIVER_BRANCH:-535}
NVIDIA_USERSPACE_VERSION=${NVIDIA_USERSPACE_VERSION:-1.13.5-1}

NVIDIA_USERSPACE_PKGS=(nvidia-container-toolkit libnvidia-container1 libnvidia-container-tools)

echo "KERNEL_VERSION: ${KERNEL_VERSION}"
echo "NVIDIA_DRIVER_VERSION: ${NVIDIA_DRIVER_VERSION}"
echo "NVIDIA_DRIVER_BRANCH: ${NVIDIA_DRIVER_BRANCH}"
echo "NVIDIA_USERSPACE_VERSION: ${NVIDIA_USERSPACE_VERSION}"
echo "NVIDIA_USERSPACE_PKGS: ${NVIDIA_USERSPACE_PKGS[@]}"

# Create the prestart hook directory
mkdir -p /usr/share/oci/hooks/prestart

# Add hook script
cat <<'END' >  /usr/share/oci/hooks/prestart/nvidia-container-toolkit.sh
#!/bin/bash -x

# Log the o/p of the hook to a file
/usr/bin/nvidia-container-toolkit -debug "$@" > /var/log/nvidia-hook.log 2>&1
END

# Make the script executable
chmod +x /usr/share/oci/hooks/prestart/nvidia-container-toolkit.sh


# PODVM_DISTRO variable is set as part of the podvm image build process
# and available inside the packer VM
# Add NVIDIA packages
if  [[ "$PODVM_DISTRO" == "ubuntu" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get -q update -y
    apt-get -q install -y "${NVIDIA_USERSPACE_PKGS[@]/%/-${NVIDIA_USERSPACE_VERSION}}"
    apt-get -q install -y nvidia-driver-${NVIDIA_DRIVER_BRANCH}
fi
if  [[ "$PODVM_DISTRO" == "rhel" ]]; then
    dnf config-manager --add-repo http://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
    dnf install -q -y "${NVIDIA_USERSPACE_PKGS[@]/%/-${NVIDIA_USERSPACE_VERSION}}"

    # check the following nvidia page to find mathcing kernel-driver pair
    # https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/precompiled/
    if [[ -n ${NVIDIA_DRIVER_VERSION} ]] && [[ -n ${KERNEL_VERSION} ]]; then
        dnf -q -y module enable nvidia-driver:${NVIDIA_DRIVER_VERSION%.*.*}
        dnf install -q -y  kernel-${KERNEL_VERSION}* \
            kernel-core-${KERNEL_VERSION}* \
            kernel-modules-core-${KERNEL_VERSION}*

        dnf install -y -q cuda-drivers-${NVIDIA_DRIVER_VERSION} \
            nvidia-driver-${NVIDIA_DRIVER_VERSION} \
            nvidia-driver-NVML-${NVIDIA_DRIVER_VERSION} \
            nvidia-driver-NvFBCOpenGL-${NVIDIA_DRIVER_VERSION} \
            nvidia-driver-cuda-${NVIDIA_DRIVER_VERSION} \
            nvidia-driver-cuda-libs-${NVIDIA_DRIVER_VERSION} \
            nvidia-driver-devel-${NVIDIA_DRIVER_VERSION} \
            nvidia-driver-libs-${NVIDIA_DRIVER_VERSION} \
            nvidia-kmod-common-${NVIDIA_DRIVER_VERSION} \
            nvidia-libXNVCtrl-${NVIDIA_DRIVER_VERSION} \
            nvidia-libXNVCtrl-devel-${NVIDIA_DRIVER_VERSION} \
            nvidia-modprobe-${NVIDIA_DRIVER_VERSION} \
            nvidia-persistenced-${NVIDIA_DRIVER_VERSION} \
            nvidia-settings-${NVIDIA_DRIVER_VERSION} \
            nvidia-xconfig-${NVIDIA_DRIVER_VERSION}
    else
        # This will use the default stream
        dnf -q -y dnf install kernel-modules
        dnf -q -y update kernel kernel-core kernel-modules-core kernel-modules
        dnf -q -y module install nvidia-driver:${NVIDIA_DRIVER_BRANCH}
    fi
fi

# Configure the settings for nvidia-container-runtime
sed -i "s/#debug/debug/g"                                           /etc/nvidia-container-runtime/config.toml
sed -i "s|/var/log|/var/log/nvidia-kata-container|g"                /etc/nvidia-container-runtime/config.toml
sed -i "s/#no-cgroups = false/no-cgroups = true/g"                  /etc/nvidia-container-runtime/config.toml
sed -i "/\[nvidia-container-cli\]/a no-pivot = true"                /etc/nvidia-container-runtime/config.toml
sed -i "s/disable-require = false/disable-require = true/g"         /etc/nvidia-container-runtime/config.toml
sed -i "s/info/debug/g"                                             /etc/nvidia-container-runtime/config.toml


