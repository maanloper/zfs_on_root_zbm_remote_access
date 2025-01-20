#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
    echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

get_arc_max(){
    ## Display current zfs_arc_max
    zfs_arc_max=$(cat /sys/module/zfs/parameters/zfs_arc_max)
    if [[ ${zfs_arc_max} -ne 0 ]]; then
        echo "Current zfs_arc_max: ${zfs_arc_max} bytes"
    else
		cat <<-EOF
			Current value of zfs_arc_max is set to '0' which means a certain % of ram depending on OS
			Check the OpenZFS documention to see what this percentage is for your OS
			Run 'zorra zfs set-arc-max [<int> (bytes) | <int>%]' to set the value
		EOF
    fi
}

calculate_arc_max(){
    ## calculate the value of zfs_arc_max from percentage
    local value="$1"
    local percentage="${value%\%}"
    if (( percentage < 0 || percentage > 100 )); then
        echo "Error: percentage for set-arc-max must be between 0% and 100%"
        exit 1
    fi

    ## Calculate zfs_arc_max based on total installed ram and percentage
    local total_ram=$(free -b | awk '/^Mem:/ {print $2}')
    local zfs_arc_max=$(( (${total_ram} * ${percentage}) / 100 ))
    echo "$zfs_arc_max"
}

set_arc_max(){
    ## Get zfs_arc_max from input
    local zfs_arc_max="$1"

    ## Append zfs_arc_max to zfsbootmenu:commandline
    local zfsbootmenu_commandline=$(zfs get -H -o value org.zfsbootmenu:commandline "${ROOT_POOL_NAME}")
    zfsbootmenu_commandline+=" zfs.zfs_arc_max=${zfs_arc_max}"
    zfs set org.zfsbootmenu:commandline="${zfsbootmenu_commandline}" "${ROOT_POOL_NAME}"
}

## Parse arguments
case $# in
    0)
		# Default arc size
        set_arc_max "85%"
        ;;
    1)
        if [[ "$1" == --show ]]; then
            get_arc_max
        elif [[ "$1" =~ ^[0-9]+%?$ ]]; then
            set_arc_max "$1"
        else
            echo "Error: unrecognized argument '$1' for 'zorra zfs set-arc-max'"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs set-arc-max'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac