#!/bin/bash

set -o pipefail

declare -A config_vars
declare -A man_config_vars

man_config_vars[INSTALL_DISK]="Path to the block device that holds or should hold partitions for the installation."
man_config_vars[ROOT_ENCRYPTED_NAME]="Name of the mapping for the unlocked encrypted root partition."
man_config_vars[GPT_AUTOMOUNT]="Whether the root partition should be mounted automatically by systemd (0=no, 1=yes)."
man_config_vars[ROOT_PARTITION]="Path to the partition that should hold the root file system."
man_config_vars[EFI_PARTITION]="Path to the partition that should hold the root file system."

SCRIPT_DIR="$(dirname "$0")"
STEPS=10
STEP=$1

# shellcheck source=./*
for i in "$SCRIPT_DIR/"__*; do
    source "$i"
done

set_config_var_efi_partition() {
    get_config_var INSTALL_DISK
    config_vars[EFI_PARTITION]="$(get_part "${config_vars[INSTALL_DISK]}" EFI)"
}

set_config_var_root_partition() {
    get_config_var INSTALL_DISK
    config_vars[ROOT_PARTITION]="$(get_part "${config_vars[INSTALL_DISK]}" root)"
}

# --- functions
get_config_var() {
    local setter val env
    test -n "${config_vars["$1"]}" && return
    # try to get value from the environment
    env=SYL_"${1^^}"
    config_vars["$1"]="${!env}"
    test -n "${config_vars["$1"]}" && return

    setter="set_config_var_${1,,}"
    if declare -F "$setter" >/dev/null; then
        $setter
        test -n "${config_vars["$1"]}" && return
    fi

    msg "Setting '$1' not defined. Normally, this is because a previous step was skipped.
This is the documentation for this setting:
 ${man_config_vars["$1"]}

Please provide a value for this setting below. Be aware that provided values will not be validated."
    read -rp "  $1> " val
    config_vars["$1"]="$val"
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

awk_calc() {
    awk "BEGIN { printf \"%.0f\", $1 }"
}

edit_file() {
    while true; do
        $EDITOR "$1" || exit 1
        ask_y_n "Would you like to continue? (Replying No will reopen the file. Press Ctrl-C to exit.)" && break
    done
}

pause() {
    local prompt
    prompt="$1"
    test -z "$prompt" && prompt="Press any key to continue."
    read -n1 -srp "$prompt"
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
    if ping -c 1 -w 5 8.8.8.8 >/dev/null 2>&1; then
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
    # custom yes/no values can be passed but should always be lowercase
    yes="$2"
    test -z "$yes" && yes=yes
    no="$3"
    test -z "$no" && no=no
    choice_len=1

    while [ -z "$return" ]; do
        msg_bold -n "  $1 "
        read -rp "[${yes^}/${no^}] " choice
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

ask_y_n_secure() {
    local choice return
    while [ -z "$return" ]; do
        msg "  To continue, enter your full response in capital letters (including !)."
        msg_bold -n "  $1 "
        read -rp "[YES!/NO!] " choice
        test "$choice" = "YES!" && return=0
        test "$choice" = "NO!" && return=1
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

prompt_for_extra_pkgs() {
    declare -a pkgs
    msg "
Please answer the following questions. The package that will be installed if you
answer 'Yes' is given in parentheses for each question."

    for cpu in amd intel; do
        if ask_y_n "Does your computer run on an ${cpu^} CPU ($cpu-ucode)?"; then
            pkgs+=("$cpu-ucode")
        fi
    done
    ask_y_n "Do you want to use a wireless connection on the system (iwd)?" && pkgs+=("iwd")
    ask_y_n "Do you want to encrypt the DNS queries made by the system (dnscrypt-proxy)?" && pkgs+=("dnscrypt-proxy")
    ask_y_n "Will you make use of zram on the system (recommended!) (zram-generator)?" && pkgs+=("zram-generator")
    ask_y_n "Do you want to build custom (e.g. AUR) packages on the system? (base-devel)" && pkgs+=("base-devel")

    echo -n "${pkgs[*]}"
}

get_missing_pkgs() {
    declare -a pkgs no_pkgs
    read -ra pkgs <<< "$1"

    for p in "${pkgs[@]}"; do
        pacman -Si "$p" >/dev/null 2>&1 || no_pkgs+=("$p")
    done
    echo -n "${no_pkgs[*]}" | xargs
}

bootstrap() {
    local kernel choice pkgs no_pkgs
    test_system_mounted || exit 1

    while true; do
        read -rp "  Please enter the name of your desired kernel package (default: linux): " kernel
        test -z "$kernel" && kernel=linux

        kernel="$(echo -n "$kernel" | xargs)"
        test -z "$(get_missing_pkgs "$kernel")" && break
        msg "Kernel package '$kernel' not found."
    done

    pkgs+="$(prompt_for_extra_pkgs)"

    msg "
If desired, you can specify additional packages you would like to install on the
system. Some common choices would be:
    - man-db
    - man-pages
    - less
    - sudo
    - vim
"
    while true; do
        read -rp "  Please enter additional packages separated by spaces here (default: none): " choice
        no_pkgs="$(get_missing_pkgs "$choice")"
        if [ -z "$no_pkgs" ]; then
            pkgs+=" $choice"
            break
        else
            msg "The following packages could not be found:"
            printf -- "- %s\n" $no_pkgs
        fi
    done

    # add btrfs-progs so we can put btrfs binary in the initramfs
    pkgs+=" btrfs-progs"

    msg "\nBootstrapping a base system with the following packages: base $kernel linux-firmware $pkgs..."

    pacstrap -K /mnt base linux-firmware "$kernel" $pkgs || exit 1
}

tab_display() {
    local count
    count=0
    for i in "$@"; do
        printf "%-20s" "$i" >&2
        (( (++count % 4) == 0)) && msg ""
    done
    (( count % 4 > 0 )) && msg ""
}

select_item() {
    local answer
    tab_display "$@"
    while true; do
        read -rp "  Please enter one of the above (honoring case): " answer
        for i in "$@"; do
            test "$i" = "$answer" && break 2
        done
        test -n "$answer" && msg "$answer is not a valid option."
    done
    echo -n "$answer"
}

mount_system() {
    local root efi
    get_config_var ROOT_ENCRYPTED_NAME
    root="/dev/mapper/${config_vars[ROOT_ENCRYPTED_NAME]}"
    get_config_var EFI_PARTITION
    efi="${config_vars[EFI_PARTITION]}"
    declare -A mounts
    mounts[@]=/mnt
    mounts[@home]=/mnt/home
    mounts[@snp]=/mnt/snp

    msg "Mounting top-level subvolumes..."
    for sv in @ @home @snp; do
        mount_subvol "$root" "$sv" "${mounts[$sv]}"
    done

    msg "Mounting EFI system partition..."
    mount --mkdir "$efi" /mnt/boot
}

test_on_live_system() {
    if [ "$(findmnt -no SOURCE)" = airootfs ]; then
        return 0
    else
        return 1
    fi
}

test_system_mounted() {
    local root root_query efi_query
    get_config_var ROOT_ENCRYPTED_NAME
    root="/dev/mapper/${config_vars[ROOT_ENCRYPTED_NAME]}"
    get_config_var EFI_PARTITION
    efi="${config_vars[EFI_PARTITION]}"
    root_query="SOURCE =~ \"$root\" && TARGET == \"/mnt\""
    efi_query="SOURCE == \"$efi\" && TARGET == \"/mnt/boot\""

    if [ -z "$(findmnt -Q "$root_query")" ]; then
        msg "
root partition $root is not mounted at /mnt. Mount it before continuing."
        return 1
    elif [ -z "$(findmnt -Q "$efi_query")" ]; then
        msg "
EFI system partition $efi not mounted at /mnt/boot. Mount it before continuing."
        return 1
    else
        return 0
    fi
}

prepare_for_reboot() {
    local swap
    test_system_mounted || exit 1
    msg "
First, we will need git on the live medium. It is probably already installed but
let's make sure."
    pacman -Sy --needed git

    msg "Cloning to new system..."
    git clone "https://github.com/Pu-Anlai/strapping-young-lad" /mnt/root/strapping-young-lad

    msg "
Unmounting the system from /mnt..."
    swapoff -a
    umount -R /mnt

    msg "
This concludes the installation process from the live medium. Next, you should
shut down the computer, remove the installation medium and turn the system back
on. After entering your encryption password, you should be taken to the tty
login screen where you can login as root.
Once logged in as root, run ./syl.sh 9 to continue the setup.

If you wish to set up Secure Boot later on, you can also enter Secure Boot setup
mode before booting into the system. However, you may also do this at a later
stage of the installation process."
    exit
}

step() {
    msg ""

    case "$1" in
        1)
            msg_bold "STEP ONE: Setting up the partition table"
            msg "Specify a disk with unpartitioned disk space. It will be formatted and the
following partitions will be created on it:
    - an EFI system partition of size 1G if one does not exist already
    - an unformatted root partition

General note: If you abort the installation process at any point, you may
restart at a specific step by passing its number as an argument to the script."
            # TODO: alternative partition layout
            ask_for_skip && setup_parts
            ;;
        2)
            msg_bold "STEP TWO: Encrypting and formatting the partitions"
            msg "Next, we will encrypt the root partition using LUKS2 encryption. You will be
asked for a password. If you intend to use this password as a decryption key on
the final system, you should choose a secure one.
During a later step, you will have the opportunity to enroll other keys as well.
You may then also delete the password you set during this step.

After encryption, the root partition will be unlocked so it can be used in the next steps."
            ask_for_skip && encrypt_parts
            ;;
        3)
            msg_bold "STEP THREE: Creating btrfs subvolumes"
            msg "Instead of a conventional partitioning scheme, we will use subvolumes on a
single btrfs partition to simulate a multi-partition structure. This has the
advantage of only encrypting a single partition while still enjoying the
benefits of a multi partition layout.
Additionally, you will be able to make use of btrfs's snapshot feature to backup
subvolumes.

First, we will create a btrfs filesystem on root.
Afterwards, the following subvolumes will be created:
    - @: the root file system, to be mounted at /
    - @home: the home \"partition\", to be mounted at /home
    - @snp: a subvolume to hold snapshots of other subvolumes, to be mounted at /snp

On @, we will create additional subvolumes. This is just so btrfs snapshots will
not include these paths:
    - /swap: subvolume to hold a swapfile
    - /var/var: this and the following subvolumes are for folders considered not relevant for backups
    - /var/cache
    - /var/log"
            ask_for_skip && setup_root
            ;;
        4)
            msg_bold "STEP FOUR: Mounting partitions and subvolumes"
            msg "Let's mount our partitions and subvolumes at the following mountpoints:
    - @ subvolume: /mnt
    - @home subvolume: /mnt/home
    - @snp subvolume: /mnt/snp (not necessary but helpful for the genfstab script)
    - EFI system partition: /mnt/boot

Should any of the mountpoints not exist, they will be created."
            ask_for_skip && mount_system
            ;;
        5)
            msg_bold "STEP FIVE: Bootstrapping the system"
            msg "Now, we will bootstrap the system by copying a base ArchLinux install to the
prepared system. Normally, this base system will consist of three packages:
base, linux and linux-firmware.
We will also install a few extra packages that may be useful later. If you wish,
you can switch out 'linux' with a different kernel package. You may also specify
additional packages if desired."
            ask_for_skip && bootstrap
            ;;
        6)
            msg_bold "STEP SIX: Setting up the system"
            msg "Now, we will make some changes to the bootstrapped system that ensure basic
functionality.
During this process, the following options can be customized:
    - swap size and zram settings
    - the fstab file
    - system clock and time settings
    - locale
    - supported network interfaces
    - root password

This includes quite a few steps and you will be offered to skip any of them in
case you have already completed them manually. If you have not, skipping a step
may result in an incomplete system."
            ask_for_skip && prepare_system
            ;;
        7)
            msg_bold "STEP SEVEN: Making the system bootable"
            msg "Yes, what it says in the headline. We will first create a unified kernel image
(UKI) and then install the bootloader. This is the most critical step of the
installation process as errors made here can result in an unbootable system."
            ask_for_skip && make_bootable
            ;;
        8)
            msg_bold "STEP EIGHT: Copying the script to the new system"
            msg "At this point, the system should be bootable. Before we will boot into it, we
will clone this script's git repository to the new system's root folder so we
can continue with the setup process after booting into the new system."
            ask_for_skip && prepare_for_reboot
            ;;
        9)
            msg_bold "STEP NINE: Setting up a basic firewall"
            msg "Now that we are on the new system (if we are not, you should quit and reboot
into the system), we can make additional steps toward a more fully fleshed out
setup.

The first few steps deal with security. We will install ufw, a simple firewall,
and set up a very basic ruleset for it. Afterwards, we can get onto the much
more daunting (and optional) task of installing Secure Boot."
            ask_for_skip && setup_firewall
            ;;
        10)
            msg_bold "STEP TEN: Setting up Secure Boot"
            msg "Secure Boot provides a way to prevent unnoticed tampering with the bootchain.
Using Secure Boot requires signing different parts of the bootchain and
verifying their signature before execution.

Device firmware can also be factory-signed and make use of Secure Boot for
verification. The certificate used for signing in these cases will be the ones
provided by Microsoft. For this reason, we will also enroll Microsoft's keys.
This is non-optional as not doing so can run the risk of bricking your entire
system.

All the commands in this step are well documented and are considered safe. I use
this script myself to set up Secure Boot on my system and have never run into
any issues. Nevertheless, you yourself are responsible for reading through the
script and taking proper care when executing this step. I TAKE NO RESPONSIBILITY
FOR ANY DAMAGE YOUR SYSTEM MAY SUSTAIN.

Secure Boot is a useful security feature but if this is all a bit much for you,
feel free to skip this step."
            ask_for_skip && setup_sboot
            ;;
    esac
    msg ""
}
# --- end functions

if ! (return 0 2>/dev/null); then
    case "$STEP" in
        "")
            STEP=1
            msg_bold -e "\033[37m
-----------------------------------
Greetings! Let's install \033[34mArchLinux\033[37m!
-----------------------------------
"
            ;;
        [0-9]*)
            if ((STEP > STEPS || STEP == 0)); then
                msg "There is no step $STEP."
                exit 1
            elif ((STEP < 9)) && ! test_on_live_system; then
                msg_bold -e "WARNING: Step $STEP is intended to be run from Arch live media.\n"
            elif test_on_live_system; then
                msg_bold -e "WARNING: Step $STEP is intended to be run from the installed system.\n"
            fi
            ;;
        *)
            msg "Invalid argument: $STEP"
            exit 1
            ;;
    esac

    test_root || exit 1
    test_uefi || exit 1
    test_internet || exit 1

    msg "
(Replies to prompts do not need to be written out completely.)"

    for s in $(seq "$STEP" "$STEPS"); do
        step "$s"
    done
fi
