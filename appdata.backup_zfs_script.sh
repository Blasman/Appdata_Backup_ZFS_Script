#!/bin/bash

################################################################################
#              UNRAID APPDATA.BACKUP ZFS COMPANION SCRIPT v1.000               #
#             https://github.com/Blasman/Appdata_Backup_ZFS_Script             #
################################################################################

################################################################################
#                            USER CONFIG (GENERAL)                             #
################################################################################
APPDATA_SOURCE_DATASET="pool_main/appdata"  # Source dataset of your appdata.
LOG_TO_STATUS_PAGE=true  # Set to 'true' to also display log messages on the Appdata.Backup "Status/Log" Web GUI page.
BETA_VERSION=true  # Set to 'true' if using the BETA version of Appdata.Backup plugin.
################################################################################
#                        USER CONFIG (SNAPSHOTS/SANOID)                        #
################################################################################
SANOID_CONFIG_DIR="/etc/sanoid"  # Directory of your default sanoid config files. They should already be located at "/etc/sanoid".
# Each docker containers dataset that is processed will have a sub-folder created for it (using the dataset basename) within SANOID_CONFIG_DIR containing it's own sanoid config files.
# Set sanoid retention policy below. "How many X of each timeframe will be kept before deleting old snapshots of said timeframe?" Snapshot pruning is done in 'POST-RUN' to minimize docker downtime.
SNAPSHOT_HOURS="0"
SNAPSHOT_DAYS="0"
SNAPSHOT_WEEKS="4"
SNAPSHOT_MONTHS="3"
SNAPSHOT_YEARS="0"
SANOID_CONFIG_UPDATE=true  # Set to 'true' to have the script *also* automatically update the config files with any changes made to the retention policy above.
ALLOW_SNAPSHOTS_OUTSIDE_OF_RETENTION_POLICY=false  # sanoid will not take new snapshots if ran before its next retention policy interval. Set to 'true' to allow additional '_extra' snapshots to be taken.
################################################################################
#                            USER CONFIG (POST-RUN)                            #
################################################################################
# Post-Run processes the docker containers that are set to 'skip = no' in Appdata.Backup config. For the tarfile option, the docker containers must also to be set to 'skip Backup = yes'.
# DELETE_EXTRA_SNAPSHOTS_OLDER_THAN_X_DAYS="7"  # Uncomment this line to delete any '_extra' snapshots (taken when ALLOW_SNAPSHOTS_OUTSIDE_OF_RETENTION_POLICY=true) that are older than this many days.
# Below you can define a list of any extra datasets (full paths) that you want to snapshot and/or replicate and/or rsync from the most recent snapshot. (sanoid config sub-directory will be created as the basename of each dataset)
EXTRA_DATASETS=(  # WARNING: extra datasets will be replicated to 'DATASET_TO_REPLICATE_TO/[basename of extra dataset]' (ie 'pool_main/some_share/stuff' to 'pool_two/backup_appdata/stuff')
  # "pool_main/appdata/plexato"
  # "pool_main/some_share/stuff"
)
SNAPSHOT_EXTRA_DATASETS=false  # Take snapshots of the EXTRA_DATASETS.
# For the REPLICATE option, uncomment the line below and define the name of the parent dataset that you want to replicate the source datasets to. THIS DATASET(S) WILL BE CREATED AUTOMATICALLY if it does not exist!
# DATASET_TO_REPLICATE_TO="pool_ssds/backup_appdata"
REPLICATE_CONTAINERS=false  # Replicate the datasets/snapshots of docker containers appdata.
REPLICATE_EXTRA_DATASETS=false  # Replicate the datasets/snapshots of EXTRA_DATASETS.
MOUNT_REPLICATED_DATASETS=false  # If all replicated datasets need to be mounted before replication *and* unmounted after replication.
SYNCOID_ARGS="-r --delete-target-snapshots --force-delete --no-sync-snap --quiet"  # OPTIONALLY (and carefully) customize the syncoid command line arguments. See: https://github.com/jimsalterjrs/sanoid/wiki/Syncoid#options
# For TAR and RSYNC options, uncomment the line below and specify the permanent dataset to clone recent snapshots to temporary datasets (ie 'pool_main/temp/_temp_plex'). THIS DATASET(S) WILL BE CREATED AUTOMATICALLY if it does not exist!
# DATASET_TO_TEMP_CLONE_TO="pool_main/temp"  # WARNING: any datasets that start with '_temp_' within this dataset will be DESTROYED when the script is ran!
# Tar datasets contents from most recent snapshots. Tarfiles are saved to the same generated backup folder that Appdata.Backup would save them to. 
TAR_CONTAINERS=false  # Tar containers from most recents snapshots. Tar compression and exclude settings are inherited from Appdata.Backup config.
TAR_EXTRA_DATASETS=false  # Tar EXTRA_DATASETS from most recent snapshots.
# Rsync datasets contents from most recent snapshots. Folders are created in the same generated timestamped backup folder that Appdata.Backup saves the tarfiles to. 
RSYNC_CONTAINERS=false  # rsync containers appdata from most recent snapshots. Exclude settings are inherited from Appdata.Backup config.
RSYNC_EXTRA_DATASETS=false  # rsync EXTRA_DATASETS from most recent snapshots.
################################################################################
#                              END OF USER CONFIG                              #
################################################################################

ab_log() { printf "[%(%d.%m.%Y %H:%M:%S)T] [$emoji] %s\n" -1 "$@"; }

pre_checks_and_process_args() {
    local beta=$([[ $BETA_VERSION == true ]] && echo ".beta" || echo "")
    if [[ $LOG_TO_STATUS_PAGE == true ]]; then exec > >(tee -a "/tmp/appdata.backup$beta/ab.log") 2>&1; fi
    emoji="📜" backup_type="$1"
    if [[ "$backup_type" != "post-run" && "$backup_type" != "pre-container" ]]; then
        ab_log "[❌] This script is expecting a 'post-run' or 'pre-container' argument to be passed to it."; exit 1; fi
    if [[ "$backup_type" == "post-run" ]]; then
        backup_path="/$(echo "$2" | sed 's|^/*||; s|/*$||')"
        if [[ ! -d "$backup_path" ]]; then ab_log "[❌] You must specify a valid backup directory after the 'post-run' argument."; exit 1; fi
    elif [[ "$backup_type" == "pre-container" ]]; then
        docker_name="$2"
        if [[ -z "$docker_name" ]]; then ab_log "[❌] You must specifiy the name of a docker container after 'pre-container'."; exit 1; fi
        if [ ! "$(docker ps -a --format '{{.Names}}' | grep -w "$docker_name")" ]; then
            ab_log "[❌] Could not find docker container '$docker_name'."; exit 1; fi
    fi
    if [[ ! -x "$(which zfs)" ]]; then
        ab_log "[❌] ZFS not found on this system ('which zfs'). This script is meant for Unraid 6.12 or above (which includes ZFS support). Please make sure you are using the correct Unraid version."; exit 1; fi
    appdata_backup_config="/boot/config/plugins/appdata.backup$beta/config.json"
    if [[ ! -f "$appdata_backup_config" ]]; then
        ab_log "[❌] Appdata.Backup config not found at '$appdata_backup_config'. Please make sure that the plugin is installed from the Unraid Community Apps."; exit 1; fi
    if ! zfs list -o name -H "$APPDATA_SOURCE_DATASET" &>/dev/null; then
        ab_log "[❌] Dataset '$APPDATA_SOURCE_DATASET' does not exist."; exit 1; fi
    appdata_source_path=$(jq -r '.allowedSources' "$appdata_backup_config" | sed 's|\r.*||')
}

pre_checks_snapshots() {
    if [[ ! -x /usr/local/sbin/sanoid ]]; then
        ab_log "[❌] sanoid not found or executable at '/usr/local/sbin/sanoid'. Please make sure that it is installed from the Unraid Community Apps."; exit 1; fi
    SANOID_CONFIG_DIR="/$(echo "$SANOID_CONFIG_DIR" | sed 's|^/*||; s|/*$||')"
    if [[ ! -d "$SANOID_CONFIG_DIR" ]]; then
        ab_log "[❌] sanoid default config file directory not found at '$SANOID_CONFIG_DIR'."; exit 1; fi
    if [[ ! -f "$SANOID_CONFIG_DIR/sanoid.defaults.conf" ]] || [[ ! -f "$SANOID_CONFIG_DIR/sanoid.conf" ]]; then
        ab_log "[❌] sanoid config files not found at '$SANOID_CONFIG_DIR'. You need 'sanoid.defaults.conf' and 'sanoid.conf' in this directory."; exit 1; fi
}

create_all_required_datasets_from_path() {
    if ! zfs list -o name -H "$1" &>/dev/null; then
        IFS='/' read -r -a components <<< "$1"
        local path="${components[0]}"
        for ((i=1; i<${#components[@]}; i++)); do
            path+="/${components[i]}"
            if ! zfs list -o name -H "$path" &>/dev/null; then
                ab_log "Creating dataset '$path'..."
                zfs create "$path"
                if ! zfs list -o name -H "$path" &>/dev/null; then ab_log "[❌] Failed to create dataset '$path'. Skipping "$2" jobs."; return 1; fi
                ab_log "[✔️] Successfully created dataset '$path'."
            fi
        done
    fi
}

pre_checks_replication() {
    if [[ ! -x /usr/local/sbin/syncoid ]]; then
        ab_log "[❌] syncoid not found or executable at '/usr/local/sbin/syncoid'. Please install syncoid (part of sanoid) plugin."; return 1; fi
    create_all_required_datasets_from_path "$DATASET_TO_REPLICATE_TO" replication
    if [ $? -ne 0 ]; then return 1; fi
}

destroy_any_temp_datasets() {
    for dataset in $(zfs list -H -o name | grep "^$DATASET_TO_TEMP_CLONE_TO/_temp_"); do
        ab_log "[⚠️] '$dataset' still exists. It should have been automatically destroyed. Destroying now!"
        zfs destroy "$dataset"
        if zfs list -o name -H "$dataset" &>/dev/null; then ab_log "[❌] Could not destroy '$dataset'."
        else ab_log "Destroyed '$dataset'."; fi
    done
}

pre_checks_additional_backups() {
    create_all_required_datasets_from_path "$DATASET_TO_TEMP_CLONE_TO" tar/rsync
    if [ $? -ne 0 ]; then return 1; fi
    mounted_path_of_dataset_to_temp_clone_to=$(zfs get -H -o value mountpoint "$DATASET_TO_TEMP_CLONE_TO")
    if [[ ! -d "$mounted_path_of_dataset_to_temp_clone_to" ]]; then ab_log "[❌] Could not find mountpoint for '$DATASET_TO_TEMP_CLONE_TO'."; exit 1; fi
    while IFS=$'\r\n' read -r line; do [[ -n "$line" ]] && exclude_arg+="--exclude=$line "; done < <(jq -r '.globalExclusions' "$appdata_backup_config")
    destroy_any_temp_datasets
}

mount_dataset() {
    local mount_status=$(zfs get -H -o value mounted "$1")
    if [[ "$mount_status" == "no" ]]; then
        zfs mount "$1" &>/dev/null
        if [[ $(zfs get -H -o value mounted "$1") == "yes" ]]; then ab_log "Mounted '$1'."
        else ab_log "[❌] Failed to mount '$1'."; return 1; fi
    elif [[ "$mount_status" == "yes" ]]; then ab_log "[⚠️] '$1' was already mounted."
    else ab_log "[❌] $mount_status."; return 1; fi
}

unmount_dataset() {
    local mount_status
    if [[ "$2" == "yes" ]]; then mount_status="yes"
    else mount_status=$(zfs get -H -o value mounted "$1"); fi
    if [[ "$mount_status" == "yes" ]]; then
        zfs unmount "$1" &>/dev/null
        if [[ $(zfs get -H -o value mounted "$1") == "no" ]]; then ab_log "Unmounted '$1'."
        else ab_log "[⚠️] Could not unmount '$1'."; fi
    elif [[ "$mount_status" == "no" ]]; then ab_log "[⚠️] '$1' was not mounted."; fi
}

delete_old_sanoid_snapshots_for_dataset() { /usr/local/sbin/sanoid --configdir="$SANOID_CONFIG_DIR/$dataset_basename" --prune-snapshots; }

delete_old_extra_snapshots_for_dataset() {
    zfs list -t snapshot -o name,creation -S creation -r "$dataset_path" | awk -v cutoff_date="$delete_old_extra_snapshots_cutoff_date" '
    /autosnap_.*_extra/ {
        split($0, fields, " ")
        creation_date = fields[length(fields)-4] " " fields[length(fields)-3] " " fields[length(fields)-2] " " fields[length(fields)-1] " " fields[length(fields)]
        snapshot_name = substr($0, 1, length($0) - length(creation_date) - 1)
        cmd = "date -d \"" creation_date "\" +%s"
        cmd | getline snapshot_date
        close(cmd)
        if (snapshot_date < cutoff_date) { print snapshot_name }
    }' | while read -r snapshot; do
        zfs destroy "$snapshot" &>/dev/null
        ab_log "Deleted old snapshot '$snapshot'."
    done
}

create_or_update_sanoid_configs() {
    sanoid_config_dataset_dir="$SANOID_CONFIG_DIR/$dataset_basename"
    if [[ ! -d "$sanoid_config_dataset_dir" ]]; then mkdir -p "$sanoid_config_dataset_dir"; fi
    if [[ ! -f "$sanoid_config_dataset_dir/sanoid.defaults.conf" ]]; then cp "$SANOID_CONFIG_DIR/sanoid.defaults.conf" "$sanoid_config_dataset_dir/sanoid.defaults.conf"; fi
    sanoid_config_file_for_dataset="$sanoid_config_dataset_dir/sanoid.conf"
    if [[ -f "$sanoid_config_file_for_dataset" ]]; then
        if [[ $SANOID_CONFIG_UPDATE == true ]]; then
            update_setting() {
                local key=$1 new_value=$2 current_value
                current_value=$(grep "^$key = " "$sanoid_config_file_for_dataset" | awk -F ' = ' '{print $2}')
                if [[ "$current_value" != "$new_value" ]]; then
                    sed -i "s/^$key = .*/$key = $new_value/" "$sanoid_config_file_for_dataset"
                    ab_log "[CONFIG CHANGE] Updated '$key' to '$new_value' in '$sanoid_config_file_for_dataset'."
                fi
            }
            update_setting "hourly" "$SNAPSHOT_HOURS"
            update_setting "daily" "$SNAPSHOT_DAYS"
            update_setting "weekly" "$SNAPSHOT_WEEKS"
            update_setting "monthly" "$SNAPSHOT_MONTHS"
            update_setting "yearly" "$SNAPSHOT_YEARS"
        fi
    else
        echo "[$dataset_path]" > "$sanoid_config_file_for_dataset"
        echo "use_template = production" >> "$sanoid_config_file_for_dataset"
        echo "recursive = yes" >> "$sanoid_config_file_for_dataset"
        echo "" >> "$sanoid_config_file_for_dataset"
        echo "[template_production]" >> "$sanoid_config_file_for_dataset"
        echo "hourly = $SNAPSHOT_HOURS" >> "$sanoid_config_file_for_dataset"
        echo "daily = $SNAPSHOT_DAYS" >> "$sanoid_config_file_for_dataset"
        echo "weekly = $SNAPSHOT_WEEKS" >> "$sanoid_config_file_for_dataset"
        echo "monthly = $SNAPSHOT_MONTHS" >> "$sanoid_config_file_for_dataset"
        echo "yearly = $SNAPSHOT_YEARS" >> "$sanoid_config_file_for_dataset"
        echo "autosnap = yes" >> "$sanoid_config_file_for_dataset"
        echo "autoprune = yes" >> "$sanoid_config_file_for_dataset"
        ab_log "Created new sanoid config at '$sanoid_config_dataset_dir'."
    fi
}

process_docker_container() {
    docker_name="$1"
    local matched_line=$(grep -oP "<Config Name=.*$appdata_source_path.*</Config>" "/boot/config/plugins/dockerMan/templates-user/my-$docker_name.xml" | tail -n 1)
    if [[ -n "$matched_line" ]]; then process_dataset "$APPDATA_SOURCE_DATASET/$(echo "$matched_line" | sed -e "s|.*$appdata_source_path||" -e 's|</Config>||' -e 's|^/||' -e 's|/.*||')"
    else ab_log "[⚠️] No appdata directory found for '$docker_name'. Skipping..."; fi
}

process_dataset() {
    dataset_path="$1" dataset_basename=${dataset_path##*/}
    if zfs list -o name -H "$dataset_path" &>/dev/null; then
        if [[ "$dataset_path" == *" "* ]]; then ab_log "[❌] sanoid doesn't like spaces in dataset names, skipping '$dataset_path'..."
        else for func_name in "${FUNCNAME[@]:1}"; do case "$func_name" in
        snapshot_*) create_or_update_sanoid_configs && snapshot_dataset; break ;;
        replicate_*) replicate_dataset; break ;;
        tar_*) create_tarfile_from_most_recent_snapshot; break ;;
        rsync_*) rsync_from_most_recent_snapshot; break ;;
        delete_old_sanoid_snapshots) delete_old_sanoid_snapshots_for_dataset; break ;; 
        delete_old_extra_snapshots) delete_old_extra_snapshots_for_dataset; break ;; esac; done; fi
    else ab_log "[❌] Dataset '$dataset_path' does not exist. Have you created the dataset from the folder?"; fi
}

snapshot_dataset() {
    ab_log "Creating 'autosnap' snapshot of '"$dataset_path"' using sanoid..."
    local sanoid_output=$(/usr/local/sbin/sanoid --configdir="$sanoid_config_dataset_dir" --take-snapshots -v)
    if [ $? -eq 0 ]; then
        local most_recent_autosnap_name=$(zfs list -t snapshot -o name -S creation -r "$dataset_path" | awk '/autosnap_/ {print; exit}')
        local most_recent_autosnap_age=$(( $(date +%s) - $(zfs get -Hp creation "$most_recent_autosnap_name" | awk '{print $3}') ))
        if [[ $(echo "$sanoid_output" | tail -n 1) == *"INFO: taking snapshots..."* ]] || [[ "$most_recent_autosnap_age" -gt 15 ]]; then
            if [[ $ALLOW_SNAPSHOTS_OUTSIDE_OF_RETENTION_POLICY == true ]]; then
                ab_log "[⚠️] Last 'autosnap' found is '$most_recent_autosnap_name' taken $most_recent_autosnap_age seconds ago. Taking snapshot with 'zfs snapshot' instead."
                zfs snapshot "$dataset_path@autosnap_$(date +"%Y-%m-%d_%H:%M:%S")_extra" &>/dev/null
                if [ $? -ne 0 ]; then ab_log "[❌] Failed to create snapshot for source: '$dataset_path'.";
                else ab_log "[✔️] '$(zfs list -t snapshot -o name -S creation -r "$dataset_path" | awk '/autosnap_/ {print; exit}')' created and verified."; fi
            else
                ab_log "[⚠️] SKIPPING SNAPSHOT! Last 'autosnap' found is '$most_recent_autosnap_name' taken $most_recent_autosnap_age seconds ago. Enable 'ALLOW_SNAPSHOTS_OUTSIDE_OF_RETENTION_POLICY' in script config to allow extra snapshots to be taken."
            fi
        else ab_log "[✔️] '$most_recent_autosnap_name' created and verified."; fi
    else ab_log "[❌] Automatic snapshot creation using sanoid failed for source '$dataset_path'."; fi
}

snapshot_extra_datasets() { emoji="📸"; for dataset in "${EXTRA_DATASETS[@]}"; do process_dataset "$dataset"; done }
replicate_containers() { jq -r '.containerSettings | to_entries | .[] | select(.value.skip == "no") | .key' "$appdata_backup_config" | while read -r docker_name; do process_docker_container "$docker_name"; done }
replicate_extra_datasets() { for dataset_path in "${EXTRA_DATASETS[@]}"; do process_dataset "$dataset_path"; done }
tar_containers_from_snapshots() { jq -r '.containerSettings | to_entries | .[] | select(.value.skip == "no" and .value.skipBackup == "yes") | .key' "$appdata_backup_config" | while read -r docker_name; do process_docker_container "$docker_name"; done }
tar_extra_datasets_from_snapshots() { for dataset_path in "${EXTRA_DATASETS[@]}"; do process_dataset "$dataset_path"; done }
rsync_containers_from_snapshots() { jq -r '.containerSettings | to_entries | .[] | select(.value.skip == "no") | .key' "$appdata_backup_config" | while read -r docker_name; do process_docker_container "$docker_name"; done }
rsync_extra_datasets_from_snapshots() { for dataset_path in "${EXTRA_DATASETS[@]}"; do process_dataset "$dataset_path"; done }

destroy_cloned_snapshot_dataset() { 
    if zfs list -o name -H "$cloned_appdata_dataset" &>/dev/null; then
        zfs destroy "$cloned_appdata_dataset"
        if zfs list -o name -H "$cloned_appdata_dataset" &>/dev/null; then ab_log "[❌] Could not destroy '"$cloned_appdata_dataset"'."; fi
    fi
}

clean_up_post_run() {
    destroy_any_temp_datasets
    if [[ $REPLICATE_CONTAINERS == true || $REPLICATE_EXTRA_DATASETS == true ]] && [[ $MOUNT_REPLICATED_DATASETS == true ]]; then
        if [[ -n $replicated_appdata_dataset ]] && [[ $(zfs get -H -o value mounted "$replicated_appdata_dataset") == "yes" ]]; then unmount_dataset "$replicated_appdata_dataset" yes; fi
        if [[ -n $DATASET_TO_REPLICATE_TO ]] && [[ $(zfs get -H -o value mounted "$DATASET_TO_REPLICATE_TO") == "yes" ]]; then unmount_dataset "$DATASET_TO_REPLICATE_TO" yes; fi
    fi
}

clone_recent_snapshot() {
    most_recent_autosnap_name=$(zfs list -t snapshot -o name -S creation -r "$dataset_path" | awk '/autosnap_/ {print; exit}')
    if [[ -z $most_recent_autosnap_name ]]; then ab_log "[❌] Could not find most recent 'autosnap' snapshot for '$dataset_path' Aborting backup for this dataset."; return 1; fi
    cloned_basename=$(printf '%s\n' "${FUNCNAME[@]:1}" | grep -q 'process_docker_container' && echo "$docker_name" || echo "$dataset_basename")
    cloned_appdata_dataset="$DATASET_TO_TEMP_CLONE_TO/_temp_$cloned_basename"
    zfs clone "$most_recent_autosnap_name" "$cloned_appdata_dataset"
    if ! zfs list -o name -H "$cloned_appdata_dataset" &>/dev/null; then ab_log "[❌] Could not clone '$most_recent_autosnap_name' to '$cloned_appdata_dataset'. Aborting backup for this dataset."; return 1; fi
    zfs set readonly=on "$cloned_appdata_dataset"
    cloned_appdata_path="$mounted_path_of_dataset_to_temp_clone_to/_temp_$cloned_basename"
}

replicate_dataset() {
    replicated_appdata_dataset=$DATASET_TO_REPLICATE_TO/$dataset_basename
    if ! zfs list -o name -H "$replicated_appdata_dataset" &>/dev/null; then
        zfs create "$replicated_appdata_dataset"
        if ! zfs list -o name -H "$replicated_appdata_dataset" &>/dev/null; then ab_log "[❌] Failed to check or create dataset '$replicated_appdata_dataset'."; return 1; fi
    fi
    if [[ $MOUNT_REPLICATED_DATASETS == true ]]; then
        mount_dataset "$replicated_appdata_dataset"
        if [ $? -ne 0 ]; then return 1; fi
    fi
    ab_log "Starting snapshot replication for '$dataset_path' using syncoid..."
    /usr/local/sbin/syncoid $SYNCOID_ARGS "$dataset_path" "$replicated_appdata_dataset" >/dev/null
    if [ $? -eq 0 ]; then ab_log "[✔️] '$dataset_path' >> '$replicated_appdata_dataset'. Successful replication."
    else ab_log "[❌] Snapshot replication failed from source '$dataset_path' to '$replicated_appdata_dataset'."; fi
    if [[ $MOUNT_REPLICATED_DATASETS == true ]]; then unmount_dataset "$replicated_appdata_dataset"; fi
}

create_tarfile_from_most_recent_snapshot() {
    clone_recent_snapshot
    if [ $? -ne 0 ]; then return 1; fi
    trap destroy_cloned_snapshot_dataset RETURN
    local compression compression_arg ext filename complete_path tar_error_output
    compression=$(jq -r '.compression' "$appdata_backup_config")
    if [[ $compression == "yes" ]] then compression_arg="-z"; ext=".gz";
    elif [[ $compression == "yesMulticore" ]] then compression_arg="-I zstd -T$(jq -r '.compressionCpuLimit' "$appdata_backup_config")"; ext=".zst"; fi
    filename="$cloned_basename.tar$ext"; complete_path="$backup_path/$filename"
    ab_log "Creating '$filename' from '$most_recent_autosnap_name'..."
    tar_error_output=$(tar ${exclude_arg:+$exclude_arg} -cf "$complete_path" ${compression_arg:+"$compression_arg"} --transform "s|^${cloned_appdata_path#/}|$appdata_source_path/$dataset_basename|" "$cloned_appdata_path" 2>&1 >/dev/null)
    if [ $? -ne 0 ]; then ab_log "[❌] Tar command failed with error: $tar_error_output"; return 1
    elif [[ ! -f "$complete_path" ]]; then ab_log "[❌] File '$complete_path' was not created by tar."; return 1; fi
    ab_log "[✔️] '$filename' successfully created."; chmod 640 "$complete_path"; chown nobody:users "$complete_path"
}

rsync_from_most_recent_snapshot() {
    clone_recent_snapshot
    if [ $? -ne 0 ]; then return 1; fi
    trap destroy_cloned_snapshot_dataset RETURN
    ab_log "Rsyncing '$cloned_basename' from '$most_recent_autosnap_name'..."
    while true; do rsync -ah ${exclude_arg:+$exclude_arg} "$cloned_appdata_path/" "$backup_path/$dataset_basename/" &>/dev/null; break; done
    if [ $? -ne 0 ]; then ab_log "[❌] rsync failed for '$cloned_basename'." ; return 1; fi
    ab_log "[✔️] '$cloned_basename' successfully rsynced."
}

delete_old_sanoid_snapshots() {
    jq -r '.containerSettings | to_entries | .[] | select(.value.skip == "no") | .key' "$appdata_backup_config" | while read -r docker_name; do process_docker_container "$docker_name"; done
    if [[ $SNAPSHOT_EXTRA_DATASETS == true ]]; then for dataset_path in "${EXTRA_DATASETS[@]}"; do process_dataset "$dataset_path"; done; fi
}

delete_old_extra_snapshots() {
    delete_old_extra_snapshots_cutoff_date=$(date -d "$DELETE_EXTRA_SNAPSHOTS_OLDER_THAN_X_DAYS days ago" +%s)
    jq -r '.containerSettings | to_entries | .[] | select(.value.skip == "no") | .key' "$appdata_backup_config" | while read -r docker_name; do process_docker_container "$docker_name"; done
    if [[ $SNAPSHOT_EXTRA_DATASETS == true ]]; then for dataset_path in "${EXTRA_DATASETS[@]}"; do process_dataset "$dataset_path"; done; fi
}

delete_old_snapshots() {
    emoji="🗑️"
    delete_old_sanoid_snapshots
    if [[ $DELETE_EXTRA_SNAPSHOTS_OLDER_THAN_X_DAYS =~ ^[0-9]+$ ]]; then delete_old_extra_snapshots; fi
}

post_run_replication() {
    emoji="🔄"
    if [[ $MOUNT_REPLICATED_DATASETS == true ]]; then 
        mount_dataset "$DATASET_TO_REPLICATE_TO"
        if [ $? -ne 0 ]; then return 1; fi
    fi
    if [[ $REPLICATE_CONTAINERS == true ]]; then replicate_containers; fi
    if [[ $REPLICATE_EXTRA_DATASETS == true ]]; then replicate_extra_datasets; fi
    if [[ $MOUNT_REPLICATED_DATASETS == true ]]; then unmount_dataset "$DATASET_TO_REPLICATE_TO"; fi
}

post_run_tarfiles() {
    emoji="📦"
    if [[ $TAR_CONTAINERS == true ]]; then tar_containers_from_snapshots; fi
    if [[ $TAR_EXTRA_DATASETS == true ]]; then tar_extra_datasets_from_snapshots; fi
}

post_run_rsync() {
    emoji="📁"
    if [[ $RSYNC_CONTAINERS == true ]]; then rsync_containers_from_snapshots; fi
    if [[ $RSYNC_EXTRA_DATASETS == true ]]; then rsync_extra_datasets_from_snapshots; fi
}

post_run_main() {
    ab_log "[POST-RUN ZFS SCRIPT STARTED]"
    trap clean_up_post_run EXIT
    if [[ $SNAPSHOT_EXTRA_DATASETS == true ]] && pre_checks_snapshots; then snapshot_extra_datasets; fi
    delete_old_snapshots
    if [[ $REPLICATE_CONTAINERS == true || $REPLICATE_EXTRA_DATASETS == true ]] && pre_checks_replication; then post_run_replication; fi
    if [[ $TAR_CONTAINERS == true || $TAR_EXTRA_DATASETS == true || $RSYNC_CONTAINERS == true || $RSYNC_EXTRA_DATASETS == true ]] && pre_checks_additional_backups; then
        if [[ $TAR_CONTAINERS == true || $TAR_EXTRA_DATASETS == true ]]; then post_run_tarfiles; fi
        if [[ $RSYNC_CONTAINERS == true || $RSYNC_EXTRA_DATASETS == true ]]; then post_run_rsync; fi
    fi
    emoji="📜"
    ab_log "[POST-RUN ZFS SCRIPT COMPLETED]"
}

snapshot_container() {
    pre_checks_snapshots
    emoji="📸"
    process_docker_container "$docker_name"
}

################################################################################
#                               BEGIN PROCESSING                               #
################################################################################

pre_checks_and_process_args "$1" "$2"
if [[ $backup_type == "pre-container" ]]; then snapshot_container;
elif [[ $backup_type == "post-run" ]]; then post_run_main; fi
exit 0
