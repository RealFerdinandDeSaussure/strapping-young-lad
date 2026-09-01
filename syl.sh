#!/bin/bash

for f in "$@"; do
    case "${f:0:2}" in
        "-q")
            QUIET=yes
            test "$f" = "-qq" && QUIET=very
            shift
            ;;
        "-x")
            EXPLANATORY=yes
            shift
            ;;
        *)
            break
            ;;
    esac
done

SCRIPTDIR="$(dirname -- "$(readlink -f -- "$0")")"
STEP=$1

# shellcheck source-path=SCRIPTDIR
source "${SCRIPTDIR}/__vars"
source "${SCRIPTDIR}/__btrfs"
source "${SCRIPTDIR}/__partitioning"
source "${SCRIPTDIR}/__post_boot_setup"
source "${SCRIPTDIR}/__pre_boot_setup"
source "${SCRIPTDIR}/__post_base_install"

set -o pipefail

# --- functions
explain() {
    test "$QUIET" = "very" && return 1
    local explanation_file explanation var
    explanation_file="${SCRIPTDIR}/explain/$1"
    if [ ! -f "$explanation_file" ]; then
        msg_bold "Warning: Explanation file \"$explanation_file\" missing!"
        pause
    fi
    explanation="$(cat "$explanation_file")"
    shift

    var=1
    for val in "$@"; do
        explanation="${explanation//"%$var"/"$val"}"
        ((++var))
    done
    echo ""
    echo "${explanation//%[[:digit:]]/}" | pageshow
}

explain_and_confirm() {
    if [ "$QUIET" = "very" ]; then
        return 1
     else
        explain "$@"
        pause
    fi
}

get_safe_filename() {
    filename="$1"
    while [ -f "$filename" ]; do
        filename+="_"
    done
    echo -n "$filename"
}

msg_bold() {
    declare -a args
    while [ $# -gt 1 ]; do
        args+=("$1")
        shift
    done
    echo -e "${args[@]}" "\033[1m$1\033[0m" >&2
}

step_msg() {
    echo -e "\033[1mSTEP $1: $2\033[0m (alias: $3)"
}

msg() {
    declare -a args
    while [ $# -gt 1 ]; do
        args+=("$1")
        shift
    done
    echo -e "${args[@]}" "\n$1" >&2
}

awk_calc() {
    awk "BEGIN { printf \"%.0f\", $1 }"
}

test_in_path() {
    local found
    declare -a paths
    IFS=: read -ra paths <<< "$PATH"
    for p in "${paths[@]}"; do
        if [ -f "${p}/${1}" ]; then
            found=1
            break
        fi
    done
    test "$found" = 1
}

edit_file() {
    while ! test_in_path "$EDITOR"; do
        msg '$EDITOR has not been set to a valid application name.'
        read -rp "  Please enter the name of your preferred editor application: " EDITOR
    done

    while true; do
        $EDITOR "$1" || exit 1
        ask_y_n "Would you like to continue? (Replying No will reopen the file. Press Ctrl-C to exit.)" && break
    done
}
 
print_cmd() {
    msg_bold -ne "  \033[32m->\033[37m " >&2
    printf "%s\n" "$1" >&2
}

# print and exec
prexec() {
    local status
    if [ -n "$QUIET" ]; then
        "$@"
        status=$?
    else
        print_cmd "$*"
        "$@"
        status=$?
        test -n "$EXPLANATORY" && pause
    fi
    return $status
}

print_write_to_file() {
    local file content
    verb=$1
    file=$2
    content=$3
    
    print_cmd "${verb} the following to ${file}:" >&2
    while IFS= read -r line; do
        echo "    |$line" >&2
    done <<<"$content"
    test -n "$EXPLANATORY" && pause
}

# print and write to file
prwrite() {
    local file content mode status

    if [ "$1" = "-a" ]; then
        mode="Appending"
        shift
    else
        mode="Writing"
    fi

    file=$1
    content=$2

    test -z "$QUIET" && print_write_to_file "$mode" "$file" "$content"
    if [ "$mode" = "Appending" ]; then
        echo -n "$content" >> "$file"
    else
        echo -n "$content" > "$file"
    fi
}

pause() {
    read -n1 -srp "  Press any key to continue."
    echo ""
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
    echo -n "Are we in UEFI mode? "
    fw_platform_size=$(cat /sys/firmware/efi/fw_platform_size)
    if [[ "$fw_platform_size" = "64" ]]; then
        msg_bold "Yes."
        return
    else
        msg_bold "No."
        return 1
    fi
}

test_internet() {
    echo -n "Are we connected to the internet? "
    if ping -c 1 -w 5 8.8.8.8 >/dev/null 2>&1; then
        msg_bold "Yes."
        return
    else
        msg_bold "No."
        return 1
    fi
}

test_mountpoint() {
    echo -n "Partition mounted at $1? "
    if findmnt "$1" >/dev/null 2>&1; then
        msg_bold "Yes."
        return
    else
        msg_bold "No."
        return 1
    fi
}

test_tpm() {
    echo -n "Do we have TPM2.0 support? "
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

prompt_for_extra_pkgs() {
    declare -a pkgs
    msg "Please answer the following questions. The package that will be installed if you
answer 'Yes' is given in parentheses behind each question."

    for cpu in amd intel; do
        if ask_y_n "Does your computer run on an ${cpu^} CPU ($cpu-ucode)?"; then
            pkgs+=("$cpu-ucode")
        fi
    done
    ask_y_n "Do you want to use a wireless connection on the system (iwd)?" && pkgs+=("iwd")
    ask_y_n "Do you want to encrypt the DNS queries made by the system (dnscrypt-proxy)?" && pkgs+=("dnscrypt-proxy")
    ask_y_n "Do you want to allow regular users to shut down the computer? (polkit)" && pkgs+=("polkit")
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

edit_mirrorlist() {
    msg "Editing pacman mirrorlist..."
    explain_and_confirm mirrorlist || pause
    edit_file /etc/pacman.d/mirrorlist
}

bootstrap() {
    local kernel choice
    declare -a pkgs no_pkgs
    test_system_mounted || exit 1

    edit_mirrorlist

    while true; do
        read -rp "  Please enter the name of your desired kernel package (default: linux): " kernel
        test -z "$kernel" && kernel=linux

        kernel="$(echo -n "$kernel" | xargs)"
        test -z "$(get_missing_pkgs "$kernel")" && break
        msg "Kernel package '$kernel' not found."
    done

    read -ra pkgs < <(prompt_for_extra_pkgs)

    explain common_packages
    while true; do
        read -rp "  Please enter additional packages separated by spaces here (default: none): " choice
        read -ra choice <<< "$choice"
        read -ra no_pkgs < <(get_missing_pkgs "${choice[*]}")
        if [ "${#no_pkgs[@]}" -eq 0 ]; then
            pkgs+=("${choice[@]}")
            break
        else
            msg "The following packages could not be found:"
            printf -- "- %s\n" "${no_pkgs[@]}"
        fi
    done

    # add btrfs-progs so we can put btrfs binary in the initramfs
    pkgs+=("btrfs-progs")

    msg "\nBootstrapping a base system with the following packages: base $kernel linux-firmware ${pkgs[*]}..."

    prexec pacstrap -K /mnt base linux-firmware "$kernel" "${pkgs[@]}" || exit 1
}

pageshow() {
    local rows
    declare -a output
    rows=$(($(tput lines) - 1))
    while IFS= read -r line; do
        output+=("$line")
    done < <(cat -)

    if [ ${#output[@]} -gt $rows ]; then
        output+=("  -> Press q to exit the pager and continue")
        printf "%s\n" "${output[@]}" | less
    else
        printf "%s\n" "${output[@]}" 
    fi
}

tab_display() {
    local count
    declare -a output
    count=0
    output=("")
    for i in "$@"; do
        output[-1]+="$(printf "%-20s" "$i")"
        (( (++count % 4) == 0)) && output+=("")
    done
    # (( count % 4 > 0 )) && output+=("")
    test -z "${output[-1]}" && output=("${output[@]:0:((${#output[@]} - 1))}")

    printf "%s\n" "${output[@]}" | pageshow
}

select_item() {
    local answer
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
    local root efi xbootldr
    get_config_var ROOT_ENCRYPTED_NAME
    root="/dev/mapper/${config_vars[ROOT_ENCRYPTED_NAME]}"
    get_config_var EFI_PARTITION
    efi="${config_vars[EFI_PARTITION]}"
    get_config_var XBOOTLDR_PARTITION
    xbootldr="${config_vars[XBOOTLDR_PARTITION]}"
    declare -A mounts
    mounts[@]=/mnt
    mounts[@home]=/mnt/home
    mounts[@snp]=/mnt/snp

    msg "Mounting top-level subvolumes..."
    for sv in @ @home @snp; do
        mount_subvol "$root" "$sv" "${mounts[$sv]}"
    done

    if [ -n "$xbootldr" ]; then
        msg "Mounting EFI system and XBOOTLDR partitions..."
        prexec mount --mkdir -o fmask=0077,dmask=0077 "$efi" /mnt/efi
        prexec mount --mkdir -o fmask=0077,dmask=0077 "$xbootldr" /mnt/boot
    else
        msg "Mounting EFI system partition..."
        prexec mount --mkdir -o fmask=0077,dmask=0077 "$efi" /mnt/boot
    fi
}

test_on_live_system() {
    if [ "$(findmnt -no SOURCE /)" = airootfs ]; then
        return 0
    else
        return 1
    fi
}

test_system_mounted() {
    local root arr err
    get_config_var ROOT_ENCRYPTED_NAME
    root="/dev/mapper/${config_vars[ROOT_ENCRYPTED_NAME]}"
    get_config_var EFI_PARTITION
    efi="${config_vars[EFI_PARTITION]}"
    get_config_var XBOOTLDR_PARTITION
    xbootldr="${config_vars[XBOOTLDR_PARTITION]}"
    declare -a mntpoints
    mntpoints+=("$(echo -ne "root\t${PART_TYPES[root]}\t${root}\t/mnt")")
    if [ -n "$xbootldr" ]; then
        mntpoints+=("$(echo -ne "EFI system\t${PART_TYPES[efi]}\t${efi}\t/mnt/efi")")
        mntpoints+=("$(echo -ne "XBOOTLDR\t${PART_TYPES[xbootldr]}\t${xbootldr}\t/mnt/boot")")
    else
        mntpoints+=("$(echo -ne "EFI system\t${PART_TYPES[efi]}\t${efi}\t/mnt/boot")")
    fi

    for i in "${mntpoints[@]}"; do
        IFS=$'\t' read -r -a arr <<< "$i"
        lsblk -nQ "PARTTYPE == \"${arr[1]}\" && MOUNTPOINT == \"${arr[3]}\"" >/dev/null && continue
        msg "${arr[0]} partition ${arr[2]} not mounted at ${arr[3]}. Mount it before continuing."
        err=1
    done

    test -n "$err" && return 1
    return 0
}

prepare_for_reboot() {
    test_system_mounted || exit 1
    msg "For this, we will need git on the live medium. It is probably already installed
but let's make sure."
    prexec pacman -Sy --needed git

    msg "Cloning to new system..."
    prexec git clone "$SCRIPTREPO" /mnt/root/strapping-young-lad

    msg "Unmounting the system from /mnt..."
    prexec swapoff -a
    prexec umount -R /mnt

    msg "This concludes the installation process from the live medium."
    explain boot_into_system "$0"
    exit 0
}

step() {
    echo ""

    case "$1" in
        1)
            step_msg "ONE" "Setting up the partition table" "start/partition"
            explain step_1 "$0"
            # TODO: alternative partition layout
            ask_for_skip && setup_parts
            ;;
        2)
            step_msg "TWO" "Encrypting and formatting the partitions" "encrypt/format"
            explain step_2
            ask_for_skip && encrypt_parts
            ;;
        3)
            step_msg "THREE" "Creating btrfs subvolumes" "btrfs/subvolume"
            explain step_3
            ask_for_skip && setup_root
            ;;
        4)
            step_msg "FOUR" "Mounting partitions and subvolumes" "mount"
            get_config_var XBOOTLDR_PARTITION
            if [ -n "${config_vars[XBOOTLDR_PARTITION]}" ]; then
                explain step_4 "EFI system partition: /mnt/efi
    - XBOOTLDR partition: /mnt/boot"
            else
                explain step_4 "EFI system partition: /mnt/boot"
            fi
                ask_for_skip && mount_system
            ;;
        5)
            step_msg "FIVE" "Bootstrapping the system" "bootstrap"
            explain step_5
            ask_for_skip && bootstrap
            ;;
        6)
            step_msg "SIX" "Setting up the system" "base"
            explain step_6
            ask_for_skip && prepare_system
            ;;
        7)
            step_msg "SEVEN" "Making the system bootable" "boot"
            explain step_7
            ask_for_skip && make_bootable
            ;;
        8)
            step_msg "EIGHT" "Copying the script to the new system" "scriptcopy"
            explain step_8
            ask_for_skip && prepare_for_reboot
            ;;
        9)
            step_msg "NINE" "Setting up a basic firewall" "firewall/postboot"
            explain step_9
            ask_for_skip && setup_firewall
            ;;
        10)
            step_msg "TEN" "Setting up Secure Boot" "secureboot"
            explain step_10
            ask_for_skip && setup_sboot
            ;;
        11)
            step_msg "ELEVEN" "Enrolling additional secrets" "secrets"
            explain step_11
            ask_for_skip && finalize_luks
            ;;
        12)
            step_msg "TWELVE" "Final settings" "final/end"
            explain step_12
            ask_for_skip && finish_setup
            ;;
    esac
    echo ""
}
# --- end functions

if ! (return 0 2>/dev/null); then
    case "$STEP" in
        "")
            clear
            STEP=1
            msg_bold -e "\033[37m
-----------------------------------
Greetings! Let's install \033[34mArchLinux\033[37m!
-----------------------------------
"
            ;;
        [0-9]*)
            ;;
        *)
            if [ ${step_aliases[$STEP]+_} ]; then
                STEP=${step_aliases[$STEP]}
            else
                msg "Invalid argument: $STEP"
                exit 1
            fi
            ;;
    esac


            if ((STEP > STEPS || STEP == 0)); then
                msg "There is no step $STEP."
                exit 1
            elif ((STEP < 9)) && ! test_on_live_system; then
                msg_bold -e "WARNING: Step $STEP is intended to be run from Arch live media.\n"
                echo "Run \"$0 9\" or \"$0 postboot\" instead.
That will start the portion of the script that is intended for the new system."
                pause
            elif ((STEP > 8)) && test_on_live_system; then
                msg_bold -e "WARNING: Step $STEP is intended to be run from the installed system.\n"
                pause
            fi

    test_root || exit 1
    test_uefi || exit 1
    test_internet || exit 1

    msg "Two notes on using this script:
 - replies to prompts may be entered partially ('y' instead of 'yes')
 - install commands executed by the script will be printed out prefixed by a
   green arrow (unless -q was passed)"

    for s in $(seq "$STEP" "$STEPS"); do
        step "$s"
        pause
        clear
    done
fi
