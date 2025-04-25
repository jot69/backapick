#!/usr/bin/env bash
# vim: tabstop=4 expandtab shiftwidth=4 softtabstop=4

#### Variables ####

backupDirectoryMount="/backup" # This should be a separate mount!
currentLink="current"
lastFullBackupMarker="last_full_backup_date.txt"
lastIncrementalBackupMarker="last_incremental_backup_date.txt"
backupExcludeFile="backup_exclude.txt"
backupProcessUmask="0002"
backupExcludeTag=".backup_exclude"

fullBackupDayNumber=1
minBackupPathLength=11 # We do not want to delete files from filesystem root
minBackupMaxAge=7 # It does not make sense to set this less than 7

fullBackupSuffix="full_backup.tar.bz2"
fullBackupLogSuffix="full_backup.log"

incrementalBackupSuffix="incremental_backup.tar.bz2"
incrementalBackupLogSuffix="incremental_backup.log"

# Internal variables, do not modify.
currentDirectory="$( cd $( dirname "$0" ); pwd; cd - >/dev/null )"
currentFileName="$( basename "$0" )"
backupExcludeFilePath="${currentDirectory}/${backupExcludeFile}"
keepBackupDays="$1"
whatToBackupPath=$( realpath "$2" )
directoryName="$3"

backupDirectoryPath="${backupDirectoryMount}/tar${whatToBackupPath}"

#### Functions ####

show() {
    _message="$1"
    if [ ! -z "${_message}" ]; then
        echo -e "${_message}"
    fi
}

quit() {
    _exitCode="$1"
    _message="$2"

    if [ -z "${_exitCode}" ]; then
        _exitCode=0
    fi
    show "${_message}"
    exit ${_exitCode}
}

usage() {
    _message="$1"
    show "${_message}"
    show "\nDescription:"
    show "  This script backs up data in given directory and cleans up old backup files.\n"
    show "Usage:\n  ${currentFileName} <max_days_to_keep_backups> <what_to_backup_directory>"
    show "  Options:"
    show "    max_days_to_keep_backups\t- Number of days, can't be less than '${minBackupMaxAge}'"
    show "    what_to_backup_directory\t- Full path to directory containing data folders"
    shoe "    what_dir_to_backup_exactly\t- Exact directory name inside what_to_backup_directory folder\n"
    quit 1
}

cleanupOldBackups() {
    _directoryToClean="$1"
    _maxAge="$2"
    # Full backups mast be kept a week more. Without it incremental backups make no sense.
    _maxFullAge=$((${_maxAge} + 6 ))
    _maxIncrementalAge=$((${_maxAge} + 6 ))

    if [ ! -d "${_directoryToClean}" ]; then
        show "Backup directory does not exist yet, skipping cleanup."
        return 0
    fi
    
    if [ "${#_directoryToClean}" -lt "${minBackupPathLength}" ]; then
        show "ERROR: Skipping cleanup process. Hardcoded directory path '${_directoryToClean}' is too short!"
    elif [ -z "${_maxAge##*[!0-9]*}" ] || [ "${_maxAge}" -lt "${minBackupMaxAge}" ]; then
        show "ERROR: Skipping cleanup process. Given max age '${_maxAge}' is less than '${minBackupMaxAge}' days!"
    else
        show "Removing more than '${_maxIncrementalAge}' days old incremental backup files from '${_directoryToClean}'."
        find "${_directoryToClean}" -type f -name "*${incrementalBackupSuffix}" -mtime +${_maxIncrementalAge} -exec sh -c 'echo "$0"; rm -f "$0"' {} \;
        find "${_directoryToClean}" -type f -name "*${incrementalBackupLogSuffix}*" -mtime +${_maxIncrementalAge} -exec sh -c 'echo "$0"; rm -f "$0"' {} \;
        find "${_directoryToClean}" -type f -name "${lastIncrementalBackupMarker}" -mtime +${_maxIncrementalAge} -exec sh -c 'echo "$0"; rm -f "$0"' {} \;

        show "Removing more than '${_maxFullAge}' days old full backup files from '${_directoryToClean}'."
        find "${_directoryToClean}" -type f -name "*${fullBackupSuffix}" -mtime +${_maxFullAge} -exec sh -c 'echo "$0"; rm -f "$0"' {} \;
        find "${_directoryToClean}" -type f -name "*${fullBackupLogSuffix}*" -mtime +${_maxFullAge} -exec sh -c 'echo "$0"; rm -f "$0"' {} \;
        find "${_directoryToClean}" -type f -name "${lastFullBackupMarker}" -mtime +${_maxFullAge} -exec sh -c 'echo "$0"; rm -f "$0"' {} \;

        # Remove empty directories and broken symlinks
        find "${_directoryToClean}" -type d -empty -delete
        find "${_directoryToClean}" -type l -exec sh -c '[ -h "$0" -a ! -e "$0" ] && rm -f "$0"' {} \;
    fi

    return 0
}

fullBackup() {
    _what="$1"
    _where="$2"
    _whereParent=$( dirname "${_where}" )
    _whatName=$( basename "${_what}" )
    _currentLinkPointer="${_whereParent}/${currentLink}"
    _backupMarker="$( date +'%Y-%m-%d %H:%M:%S' )"
    _backupPrefix="$( date +'%Y%m%d_%H%M%S' )"
    _backupName="${_backupPrefix}_${_whatName}_${fullBackupSuffix}"
    _backupLogName="${_backupPrefix}_${_whatName}_${fullBackupLogSuffix}"
    _backupMarkerPath="${_currentLinkPointer}/${lastFullBackupMarker}"

    # create backup directory
    if [ ! -d "${_where}" ]; then
        show "Creating directory '${_where}'"
        mkdir -p "${_where}"
    fi

    rm -f "${_currentLinkPointer}"
    ln -s "${_where}" "${_currentLinkPointer}"

    echo "${_backupMarker}" > "${_backupMarkerPath}.tmp"

    createBackup "${_what}" "${_where}" "${_backupName}" "${_backupLogName}"
    _resultCode=$?

    if [[ ${_resultCode} = 0 ]]; then
        mv "${_backupMarkerPath}.tmp" "${_backupMarkerPath}"
    else
        rm "${_backupMarkerPath}.tmp"
    fi
}

incrementalBackup() {
    _what="$1"
    _where="$2"
    _whereParent=$( dirname "${_where}" )
    _whatName=$( basename "${_what}" )
    _currentLinkPointer="${_whereParent}/${currentLink}"
    _lastFullBackupDate=$( cat "${_currentLinkPointer}/${lastFullBackupMarker}" 2>/dev/null)
    _lastIncrementalBackupDate=$( cat "${_currentLinkPointer}/${lastIncrementalBackupMarker}" 2>/dev/null )
    _backupMarker="$( date +'%Y-%m-%d %H:%M:%S' )"
    _backupPrefix="$( date +'%Y%m%d_%H%M%S' )"
    _backupName="${_backupPrefix}_${_whatName}_${incrementalBackupSuffix}"
    _backupLogName="${_backupPrefix}_${_whatName}_${incrementalBackupLogSuffix}"
    _backupMarkerPath="${_currentLinkPointer}/${lastIncrementalBackupMarker}"

    _lastBackupDate="${_lastIncrementalBackupDate}"
    if [ -z "${_lastBackupDate}" ]; then
        _lastBackupDate="${_lastFullBackupDate}"
    fi

    echo "${_backupMarker}" > "${_backupMarkerPath}.tmp"

    createBackup "${_what}" "${_where}" "${_backupName}" "${_backupLogName}" "${_lastBackupDate}"
    _resultCode=$?

    if [[ ${_resultCode} = 0 ]]; then 
        mv "${_backupMarkerPath}.tmp" "${_backupMarkerPath}"
    else
        rm "${_backupMarkerPath}.tmp"
    fi
}

createBackup() {
    _sourcePath="$1"
    _backupPath="$2"
    _backupFile="$3"
    _backupLog="$4"
    _filesAfterDate="$5"

    _backupFilePath="${_backupPath}/${_backupFile}"
    _backupLogPath="${_backupPath}/${_backupLog}"
    _backupListPath="${_backupLogPath}.files_list.txt"

    _excludeOptions=$( find "${_sourcePath}" -type f -name "${backupExcludeTag}" -printf "-not \\\( -path \"%h\" -prune \\\) " )
    _excludeOptions="${_excludeOptions} -not \( -name \"lost+found\" -type d -prune \)"

    if [ ! -z "${_filesAfterDate}" ]; then
        _referenceFilePath="${_backupLogPath}.files_newer_than_marker"
        touch -d "${_filesAfterDate}" "${_referenceFilePath}"

        command="find \"${_sourcePath}\" ${_excludeOptions} -type f,l -cnewer \"${_referenceFilePath}\" > \"${_backupListPath}\""
        eval ${command}

        rm "${_referenceFilePath}"
    else
        command="find \"${_sourcePath}\" ${_excludeOptions} -type f,l > \"${_backupListPath}\""
        eval ${command}
    fi

    command="nice -n 19 tar -cpv -I lbzip2 --absolute-names --ignore-failed-read --exclude-tag-all=\"${backupExcludeTag}\" -f \"${_backupFilePath}\" -X \"${backupExcludeFilePath}\" --files-from=\"${_backupListPath}\" > \"${_backupLogPath}\" 2>&1"
    eval ${command}
    _tarResult=$?
    rm "${_backupListPath}"

    if [[ ${_tarResult} != 0 ]]; then
        show "Failed to create backup archive \"${_backupFilePath}\""
        mv "${_backupFilePath}" "${_backupFilePath}.error" 2>/dev/null
        mv "${_backupLogPath}" "${_backupLogPath}.error" 2>/dev/null
        return 2
    fi

    _backupFileContents=$( tar --list -f "${_backupFilePath}")
    if [ -z "${_backupFileContents}" ]; then
        show "Empty backup created, removing \"${_backupFilePath}\""
        rm "${_backupFilePath}"
        rm "${_backupLogPath}"
        return 1
    fi

    lbzip2 "${_backupLogPath}"
    _backupSize=$( du -h "${_backupFilePath}" |awk '{print $1}' )
    show "Created '${_backupFilePath}', size '${_backupSize}'."

    return 0
}

backupDirectory() {
    _dirName="$1"
    _sourceDirectory="${whatToBackupPath}/${_dirName}"
    _backupDirectory="${backupDirectoryPath}/${_dirName}"
    _currentBackupDirectory="${_backupDirectory}/$( date +%Y%m%d )"

    show "Backing up files for directory '${_dirName}'."

    if [ "$( date +%u )" -eq "${fullBackupDayNumber}" ] && [ ! -d "${_currentBackupDirectory}" ]; then
        # Full backup day and full backup hasn't been run yet.
        fullBackup "${_sourceDirectory}" "${_currentBackupDirectory}"
    elif [ "$( find "${_backupDirectory}/${currentLink}/" -type f -name "*${fullBackupSuffix}" 2>/dev/null |wc -l)" -lt 1 ]; then
        # We have no current link or no full backup file in it. Create a new full backup.
        fullBackup "${_sourceDirectory}" "${_currentBackupDirectory}"
    else
        # We have a current link and existing full backup. Create incremental backup.
        incrementalBackup "${_sourceDirectory}" "${_backupDirectory}/${currentLink}"
    fi
    show "Backup of directory '${_dirName}' finished.\n"
}

#### Sanity checks ####

if [ -z "${keepBackupDays##*[!0-9]*}" ] || [ "${keepBackupDays}" -lt "${minBackupMaxAge}" ]; then
    usage "\nERROR: no or incorrect <max_days_to_keep_backups> given!"
fi
if [ -z "${whatToBackupPath}" ]; then
    usage "\nERROR: no <source_path> given!"
fi
if [ -z "$( mount|grep "$backupDirectoryMount" )" ]; then
    quit 1 "\nFATAL: Backup directory '${backupDirectoryMount}' not mounted!"
fi
if [ ! -d "${whatToBackupPath}" ]; then
    quit 1 "\nFATAL: Source directory '${whatToBackupPath}' does not exist!"
fi

psPattern="bash $0 $1 $2"
if [ ! -z "$3" ]; then
    psPattern="${psPattern} $3"
fi
isRunning=$( pgrep -c -f "$psPattern" )
if [ "${isRunning}" -gt "1" ]; then
    quit 0 "\nERROR: Backup is already running!"
fi

#### Main script ####

show "Data backup script running on '$( hostname )' for directory '${whatToBackupPath}'\n"

umask "${backupProcessUmask}"
mkdir -p "${backupDirectoryPath}"

if [ ! -z "${directoryName}" ]; then
    directoriesToBackup="${directoryName}"
    whatToCleanupPath=$( realpath "${backupDirectoryPath}/${directoryName}" )
else
    directoriesToBackup="$( ls -1 ${whatToBackupPath} )"
    whatToCleanupPath="${backupDirectoryPath}"
fi

cleanupOldBackups "${whatToCleanupPath}" "${keepBackupDays}"

for directory in $directoriesToBackup; do
    if [[ -d "${whatToBackupPath}/${directory}" ]] && [[ ! -L "${whatToBackupPath}/${directory}" ]] && [[ "${directory}" != "lost+found" ]] && [[ ! -f "${whatToBackupPath}/${directory}/${backupExcludeTag}" ]]; then
        backupDirectory "$directory"
    fi
done

show "\nBackup filesystem usage:"
df -h "${backupDirectoryMount}"
