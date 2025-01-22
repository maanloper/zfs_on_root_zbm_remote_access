#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

select_clone(){
    ## Select dataset
	if [ -n "${allowed_clone_datasets}" ]; then
        prompt_list clone_dataset "${allowed_clone_datasets}" "Please select a clone to recursively undo the rollback of"
    else
		echo "There are no clones available for an undo-rollback"
		exit 1
	fi
}


recursive_promote_and_rename_clone() {
    ## Get input
    local clone_dataset="$1"

    # Show clones to destroy and datasets to restore for confirmation
    local clone_datasets=$(grep "^${clone_dataset}" <<< "${clone_datasets}")
    local clone_datasets_rename=$(echo "${clone_datasets}" | sed 's/_[0-9]*T[0-9]*[^/]*//')
    echo "The following clones will be promoted and renamed:"
    echo "$(change_from_to "${clone_datasets}" "${clone_datasets_rename}")"

    # Confirm to proceed
    read -p "Proceed? (y/n): " confirmation

    if [[ "$confirmation" == "y" ]]; then
        # Check if the dataset(s) are not in use by any processes (only checking parent is sufficient)
        check_mountpoint_in_use "${clone_dataset}"

        # Unmount clone datasets
        echo "Unmounting clones:"
        unmount_datasets "${clone_datasets}"

        # Recursively promote clone parent dataset
        echo "Promoting clones:"
        for dataset in $clone_datasets; do
            echo "Promoting $dataset"
            zfs promote "$dataset"
        done

        # Rename clone parent dataset to original name
		local original_dataset=$(echo "${clone_dataset}" | sed 's/_clone_[^/]*\(\/\|$\)/\1/')
        echo "Renaming ${clone_dataset} to ${original_dataset}"
        zfs rename "${clone_dataset}" "${original_dataset}"

        ## Mount all datasets
        echo "Mounting all datasets"
        zfs mount -a

        # Result
		echo
        echo "Promoting safe-rollback clone completed:"
        overview_mountpoints "${original_dataset}"
        exit 0
    else
        echo "Operation cancelled"
        exit 0
    fi

}

## Get clones and allowed clones datasets
clone_datasets=$(zfs list -H -t snapshot -o clones | tr ',' '\n' | grep -v "^-" | grep "_clone_") || true
allowed_clone_datasets=$(echo "${clone_datasets}" | grep -E '_clone_[^/]*$') || true

## Parse arguments
case $# in
    0)
		select_clone
		undo_recursive_rollback "${clone_dataset}"
        ;;
    1)
		if grep -Fxq "$1" <<< "${allowed_clone_datasets}"; then
			undo_recursive_rollback "$1"
		else
			echo "Error: cannot rollback to '$1' as it does not exist or is the root dataset"
			exit 1
		fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs safe-rollback'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac