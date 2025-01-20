#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
	echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source safe_generate_initramfs
source "$script_dir/../lib/safe-generate-initramfs.sh"

auto_unlock_pool(){
	## Get input
	auto_unlock_pool_name="$1"

	## Import pool if needed
	if ! zpool list -H | grep -q "${auto_unlock_pool_name}"; then
		zpool import -f "${auto_unlock_pool_name}"
	fi

	## Try to load key with existing keyfile, otherwise prompt for passphrae
	if [[ $(zfs get -H -o value keystatus "${auto_unlock_pool_name}") != "available" ]]; then
		if ! zfs load-key -L "file://${KEYFILE}" "${auto_unlock_pool_name}" &>/dev/null; then
			zfs load-key -L prompt "${auto_unlock_pool_name}"
		fi
	fi

	## Change key to keyfile one and set required options
	zfs change-key -l -o keylocation="file://${KEYFILE}" -o keyformat=passphrase "${auto_unlock_pool_name}"
	echo "Changed keylocation (and thus key) of '${auto_unlock_pool_name}' to 'file://${KEYFILE}'"

	# Add pool to zfs-list cache TODO: also needed in zorra_install???
	mkdir -p /etc/zfs/zfs-list.cache/
	touch "/etc/zfs/zfs-list.cache/${auto_unlock_pool_name}"

	## Verify cache update (resets a pool property to force update of cache files)
	while [ ! -s "/etc/zfs/zfs-list.cache/${auto_unlock_pool_name}" ]; do
		zfs set keylocation="file://${KEYFILE}" "${auto_unlock_pool_name}"
		sleep 1
	done

	## Generate initramfs with check if keystore is mounted
	echo "Updating initramfs to auto-unlock pool on boot..."
	safe_generate_initramfs

	echo "Successfully setup auto-unlock for pool: ${auto_unlock_pool_name}"
}

## Parse arguments
case $# in
    1)
        if zpool list -H | grep -Fxq "$1"; then
            auto_unlock_pool "$1"
        else
            echo "Error: cannot auto-unlock pool '$1' as it does not exist"
            echo "Make sure to import the pool first using 'sudo zpool import [-f] <pool>'"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs auto-unlock'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac