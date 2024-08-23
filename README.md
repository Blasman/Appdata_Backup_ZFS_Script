# Unraid Appdata Backup Custom ZFS Script

When ran as a `Pre-container-backup` script for the [Appdata.Backup](https://forums.unraid.net/topic/137710-plugin-appdatabackup/) plugin for Unraid, this script will create ZFS snapshots of your docker containers appdata datasets (using [sanoid](https://github.com/jimsalterjrs/sanoid)) while containers are stopped during backups.

In addition, when ran as a `Post-run` script, it will also give any of the following options:

1. Replicate your appdata datasets/snapshots to another pool/dataset (using [syncoid](https://github.com/jimsalterjrs/sanoid?tab=readme-ov-file#syncoid)).

2. Create tarfiles from the most recent snapshots of appdata datasets *instead of* having Appdata.Backup create tarfiles. This allows dockers to instantly start after creating a snapshot from the `Pre-container-backup` script option.

3. Rsync from the most recent snapshots of appdata datasets. This is an alternative to creating tarfiles. Rsync'd appdata folders are saved in Appdata.Backup's generated backup directory where the tarfiles are stored.

## Requirements / Limitations

- Appdata.Backup plugin version 2024.08.16b1 (currently BETA) or higher (for the `Pre-container-backup` script option).

- Unraid 6.12+ or higher (for ZFS features).

- sanoid plug-in for Unraid needs to be installed from Unraid's Community Applications.

- Only works for the first appdata source that is specified in Appdata.Backup config. I don't imagine changing this as it seems like a niche use case.

- Use the same appdata folder for your docker containers as is specified in Appdata.Backup config. Do not mix the interchangable appdata paths (ie `/mnt/user/appdata` and `/mnt/pool_main/appdata`).

## Installation

1. Edit the required/desired sections in the 'user config' at the top of the script. Carefully read all the comments as every option is explained there.

2. Make script(s) executable with `chmod +x script_name.sh`.

3. Add as a 'Custom script' in Appdata.Backup config page under the `Pre-container-backup` and `Post-run` script sections:
![Snapshot Logging](https://i.imgur.com/xlFufcg.png)

## Misc

You may also run the script from an Unraid terminal in addition to or instead of from Appdata.Backup's custom scripts. You will just need to specify the arguments `pre-container container_name` to snapshot a docker container or `post-run /backup/path` to perform the post-run options. Also, you don't *need* to have Appdata.Backup shut down your dockers in order for the scripts to work, but the recommended usage is to stop all dockers during backups.

I have only tested this script on my own Unraid 6.12.11 system, however, from doing some research, it is possible that Unraid 7+ beta users may have to apply [this fix](https://github.com/SpaceinvaderOne/Unraid_ZFS_Dataset_Snapshot_and_Replications/issues/41#issuecomment-2211973696) in order to use sanoid/syncoid.

## Log Examples

The script logs to the Appdata.Backup Status/Log Web GUI. See the screenshots for an ideal of how the script works.

![Snapshot Logging](https://i.imgur.com/XiQ44pk.png)

![Replication Logging](https://i.imgur.com/Ees9Rbz.png)

![Tar/Rsync Logging](https://i.imgur.com/Rs4YakX.png)
