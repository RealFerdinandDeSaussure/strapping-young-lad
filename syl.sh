#!/bin/bash

set -o pipefail

declare -A config_vars
declare -A man_config_vars

man_config_vars[INSTALL_DISK]="Path to the block device that holds or should hold partitions for the installation."
man_config_vars[EFI_PARTITION]="Path to the EFI system partition."
man_config_vars[ROOT_PARTITION]="Path to the partition where the root folder of the system will reside."
man_config_vars[ROOT_ENCRYPTED_NAME]="Name of the mapping for the unlocked encrypted root partition."

SCRIPT_DIR="$(dirname "$0")"
STEPS=6

# shellcheck source=./*
for i in "$SCRIPT_DIR/"__*; do
    source "$i"
done

# --- functions
get_config_var() {
    local val="${config_vars["$1"]}"
    if [ -z "$val" ]; then
        msg "Setting '$1' not defined. Normally, this is because a previous step was skipped.
This is the documentation for this setting:
 ${man_config_vars["$1"]}

Please provide a value for this setting below. Be aware that provided values will not be validated."
        read -rp "  $1> " val
        config_vars["$1"]="$val"
    fi
    echo -n "$val"
}

msg_bold() {
    local args
    while [ $# -gt 1 ]; do
        args="$args $1"
        shift
    done
    echo -e $args "\033[1m$1\033[0m" >&2
}

msg() {
    local args
    while [ $# -gt 1 ]; do
        args="$args $1"
        shift
    done
    echo -e $args "$1" >&2
}

pause() {
    read -n1 -srp "Press any key to continue."
    msg ""
}

test_root() {
    echo -n "Are we root? "
    if [[ $EUID -eq 0 ]]; then
        msg_bold "Yes."
        return
    else
        msg_bold "No."
        return 1
    fi
}

test_uefi() {
    local fw_platform_size
    msg -n "Are we in UEFI mode? "
    # debug: will commenting the following line out get rid of bash language server crashing?
    fw_platform_size=$(cat /sys/firmware/efi/fw_platform_size)
    if [[ "$fw_platform_size" = "64" ]]; then
        msg_bold "Yes."
        return
    else
        msg_bold "No."
        # msg "\`cat /sys/firmware/efi/fw_platform_size\` ergab: $fw_platform_size"
        return 1
    fi
}

test_internet() {
    msg -n "Are we connected to the internet? "
    if ping -c 1 -t 5 8.8.8.8 >/dev/null 2>&1; then
        msg_bold "Yes."
        return
    else
        msg_bold "No."
        return 1
    fi
}

test_mountpoint() {
    msg -n "Partition mounted at $1? "
    if findmnt "$1" >/dev/null 2>&1; then
        msg_bold "Yes."
        return
    else
        msg_bold "No."
        return 1
    fi
}

test_tpm() {
    msg -n "Do we have TPM2.0 support? "
    if systemd-analyze has-tpm2 >/dev/null 2>&1; then
        msg_bold "Yes."
        return
    else
        msg_bold "No."
        return 1
    fi
}

ask_y_n() {
    local choice choice_len yes no return
    yes=yes
    no=no
    choice_len=1

    while [ -z "$return" ]; do
        msg_bold -n "  $1 "
        read -rp "[Yes/No] " choice
        test -n "$choice" && choice_len=${#choice}
        test "$choice_len" -eq 0 && continue
        choice="$(echo "$choice" | xargs | tr "[:upper:]" "[:lower:]")"
        case $choice in
            "${yes:0:$choice_len}")
                return=0
                ;;
            "${no:0:$choice_len}")
                return=1
                ;;
        esac
    done
    return $return
}

ask_for_skip() {
    local choice choice_len yes abort skip return
    yes=yes
    abort=abort
    skip=skip
    choice_len=1

    while [ -z "$return" ]; do
          msg_bold -n "  Would you like to continue? "
          read -rp "[Yes/Abort/Skip] " choice
          test -n "$choice" && choice_len=${#choice}
          choice="$(echo "$choice" | xargs | tr "[:upper:]" "[:lower:]")"
          case $choice in
              "${yes:0:$choice_len}")
                  return=0
                  ;;
              "${abort:0:$choice_len}")
                  exit 0
                  ;;
              "${skip:0:$choice_len}")
                  return=1
                  ;;
          esac
    done
    return $return
}

get_largest_empty_blk() {
    local start end
    start=$(sgdisk -F "$1") || exit 1
    end=$(sgdisk -E "$1") || exit 1
    echo -n "$(("$end" - "$start"))"
}

get_largest_empty_blk_in_m() {
    echo -n "$(($(get_largest_empty_blk "$1") * 512 / 1000000))"
}

bootstrap() {
    local kernel choice pkgs no_pkgs
    if ! findmnt /mnt >/dev/null; then
        msg "Nothing mounted at /mnt. Can't continue."
        exit 1
    fi

    while true; do
        read -rp "Please enter the name of your desired kernel package (default: linux): " kernel
        test -z "$kernel" && kernel=linux

        kernel="$(echo -n "$kernel" | xargs)"
        if [ "$kernel" = "linux" ]; then
            break
        elif pacman -Syi "$kernel" >/dev/null 2>&1; then
             break
        else
            msg "Kernel package '$kernel' not found."
        fi
    done

    msg ""
    while true; do
        read -rp "Please enter additional packages separated by spaces here (default: none): " choice
        read -ra pkgs <<< "$choice"

        no_pkgs=()
        for p in "${pkgs[@]}"; do
            pacman -Si "$p" >/dev/null 2>&1 || no_pkgs+=("$p")
        done

        if [ "${#no_pkgs[@]}" -eq 0 ]; then
            break
        else
            msg -e "The following packages could not be found:"
            for n in "${no_pkgs[@]}"; do
                echo "- $n"
            done
        fi
    done

    msg "\nBootstrapping a base system with the following packages: base $kernel linux-firmware ${pkgs[*]}..."

    pacstrap -K /mnt base linux-firmware "$kernel" "${pkgs[*]}" || exit 1
}

tab_display() {
    local count
    count=0
    for i in "$@"; do
        printf "%-20s" "$i" >&2
        (( (++count % 6) == 0)) && msg ""
    done
    (( count % 6 > 0 )) && msg ""
}

select_item() {
    local answer
    tab_display "$@"
    while true; do
        read -rp "  Please enter one of the above (honoring case): " answer
        for i in "$@"; do
            test "$i" = "$answer" && break 2
        done
        msg "$answer is not a valid option."
    done
    echo -n "$answer"
}

mount_system() {
    local root efi
    root="/dev/mapper/$(get_config_var ROOT_ENCRYPTED_NAME)"
    efi="$(get_config_var EFI_PARTITION)"
    declare -A mounts
    mounts[@]=/mnt
    mounts[@home]=/mnt/home
    mounts[@snp]=/mnt/snp

    msg "Mounting top-level subvolumes..."
    for sv in @ @home @snp; do
        mount_subvol "$root" "$sv" "${mounts[$sv]}"
    done

    msg "Mounting EFI boot partition..."
    mount --mkdir "$efi" /mnt/boot
}

step() {
    msg ""

    case "$1" in
        1)
            msg_bold "STEP ONE: Setting up the partition table"
            msg "Specify a disk with unpartitioned disk space. It will be formatted and the
following partitions will be created on it:
	- an EFI system partition of size 1G if one does not exist already
	- a root partition formatted with btrfs"
            ask_for_skip && setup_parts
            ;;
        2)
            msg_bold "STEP TWO: Encrypting and formatting the partitions"
            msg "Next, we will encrypt the root partition using LUKS2 encryption. You will be
asked for a password. If you intend to use this password as a decryption key on
the final system, you should choose a secure one.
During a later step, you will have the opportunity to enroll a FIDO2 key as
well. As part of that step, you will also have the chance to delete the password
you have chosen during the current step from the LUKS key slots.

After encryption, the root partition will be unlocked so it can be used in the next steps."
            ask_for_skip && encrypt_parts
            ;;
        3)
            msg_bold "STEP THREE: Creating btrfs subvolumes"
            msg "Instead of a conventional partitioning scheme, we will be using btrfs subvolumes
on a single btrfs partition to simulate a multi-partition structure. This has
the advantage of being able to encrypt a single partition and store all data on
it. Additionally, we can make use of btrfs's snapshot feature to backup
subvolumes.
First we will format root with a btrfs filesystem.
Afterwards, the following subvolumes will be created:
	- @: the root file system, to be mounted at /
	- @home: the home \"partition\", to be mounted at /home
	- @snp: a subvolume to hold snapshots of other subvolumes, to be mounted at /snp

On @, we will create additional subvolumes to exclude these from future snapshots of @:
	- /swap: subvolume to hold a swapfile
	- /var/var: this and the following subvolumes are for folders considered not relevant for backups
	- /var/cache
	- /var/log"
            ask_for_skip && setup_root
            ;;
        4)
            msg_bold "STEP FOUR: Mounting partitions and subvolumes"
            msg "During this relatively short step, we will mount our partitions at the following
mountpoints:
	- @ subvolume: /mnt
	- @home subvolume: /mnt/home
	- @snp subvolume: /mnt/snp (not necessary but helpful for the genfstab script)
	- EFI system partition: /mnt/boot

Should any of the mountpoints not exist, they will be created."
            ask_for_skip && mount_system
            ;;
        5)
            msg_bold "STEP FIVE: Bootstrapping the system"
            msg "Now, we will bootstrap the system by coping a base ArchLinux install to the
prepared system. Normally, this base system will consist of three packages:
base, linux and linux-firmware.
If you wish, you can switch out 'linux' with a different kernel package. You may
also choose additional packages to be installed."
            ask_for_skip && bootstrap
            ;;
        6)
            msg_bold "STEP SIX: Setting up the system"
            msg "Now, we will setup the system so that it becomes bootable.
During this process, the following options can be customized:
	- the fstab file
	- system clock and time settings
	- locale
	- supported network interfaces"
            ask_for_skip && system_prepare
            ;;
    esac
    msg ""
}
# --- end functions

if ! (return 0 2>/dev/null); then
    if [ -z "$1" ]; then
        start=1
        msg -e "
-----------------------------------
Greetings! Let's install \033[34mArchLinux\033[0m!
-----------------------------------
"
    else
        start="$1"
    fi

    test_root || exit 1
    test_uefi || exit 1
    test_internet || exit 1
    test_tpm || exit 1

    for s in $(seq "$start" "$STEPS"); do
        step "$s"
    done
fi
