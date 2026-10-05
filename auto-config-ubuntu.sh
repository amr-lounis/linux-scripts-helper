#!/bin/bash
# ==========================================================
#  Interactive System Setup Script (v2)
#  Tested for: Ubuntu / Debian (netplan, systemd)
# ==========================================================

# ---------- Colors ----------
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; NC=$'\e[0m'

info()  { echo "${BLUE}[i]${NC} $*"; }
ok()    { echo "${GREEN}[✔]${NC} $*"; }
warn()  { echo "${YELLOW}[!]${NC} $*"; }
err()   { echo "${RED}[✘]${NC} $*" >&2; }
pause() { read -r -p "Press Enter to continue..." _; }

confirm() {  # confirm "question" -> returns 0 if yes
    local ans
    read -r -p "$1 (y/n): " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

header() {
    clear
    echo "${BOLD}=========================================="
    echo "   $1"
    echo "==========================================${NC}"
}

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo)."
    exit 1
fi

# ---------- Validators ----------
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_hostname() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }
valid_ip() {
    local ip=$1 o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -ra o <<< "$ip"
    for n in "${o[@]}"; do (( n <= 255 )) || return 1; done
}
valid_cidr() {
    [[ "$1" =~ ^([0-9.]+)/([0-9]{1,2})$ ]] || return 1
    valid_ip "${BASH_REMATCH[1]}" && (( BASH_REMATCH[2] <= 32 ))
}

user_exists() { id "$1" &>/dev/null; }

# Prompt for a username that must (or must not) exist
ask_username() {  # ask_username <must_exist|must_not_exist>
    local mode=$1 u
    while true; do
        read -r -p "Enter Username (empty to cancel): " u
        [[ -z "$u" ]] && return 1
        if ! valid_username "$u"; then
            err "Invalid username (lowercase letters, digits, _ and - only)."; continue
        fi
        if [[ $mode == must_exist ]] && ! user_exists "$u"; then
            err "User '$u' does not exist."; continue
        fi
        if [[ $mode == must_not_exist ]] && user_exists "$u"; then
            err "User '$u' already exists."; continue
        fi
        USERNAME=$u; return 0
    done
}

# Prompt for a password twice
ask_password() {
    local p1 p2
    while true; do
        read -r -s -p "Enter Password: " p1; echo
        read -r -s -p "Confirm Password: " p2; echo
        if [[ -z "$p1" ]]; then err "Password cannot be empty."; continue; fi
        if [[ "$p1" != "$p2" ]]; then err "Passwords do not match."; continue; fi
        PASSWORD=$p1; return 0
    done
}

# ==========================================================
#  1. User Management
# ==========================================================
list_users() {
    header "System Users (UID >= 1000)"
    printf "%-20s %-8s %-25s %s\n" "USER" "UID" "HOME" "SUDO"
    while IFS=: read -r name _ uid _ _ home _; do
        if (( uid >= 1000 && uid < 65534 )); then
            local s="no"; id -nG "$name" | grep -qw sudo && s="yes"
            printf "%-20s %-8s %-25s %s\n" "$name" "$uid" "$home" "$s"
        fi
    done < /etc/passwd
    echo
}

create_user() {
    header "Create User"
    ask_username must_not_exist || return
    ask_password || return

    useradd -m -s /bin/bash "$USERNAME" || { err "useradd failed."; return; }
    echo "$USERNAME:$PASSWORD" | chpasswd
    ok "User '$USERNAME' created."

    if confirm "Give '$USERNAME' sudo privileges?"; then
        usermod -aG sudo "$USERNAME"
        if confirm "Allow sudo WITHOUT password? (less secure)"; then
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
            chmod 440 "/etc/sudoers.d/$USERNAME"
            visudo -cf "/etc/sudoers.d/$USERNAME" >/dev/null || {
                err "Invalid sudoers file, removing it."; rm -f "/etc/sudoers.d/$USERNAME"; }
        fi
        ok "Sudo privileges granted."
    fi
}

delete_user() {
    header "Delete User"
    ask_username must_exist || return

    if [[ "$USERNAME" == "root" || "$USERNAME" == "${SUDO_USER:-}" ]]; then
        err "Refusing to delete '$USERNAME' (root or the current sudo user)."; return
    fi

    warn "You are about to delete user '$USERNAME'."
    local typed
    read -r -p "Type the username again to confirm: " typed
    [[ "$typed" == "$USERNAME" ]] || { info "Cancelled."; return; }

    pkill -KILL -u "$USERNAME" 2>/dev/null
    if confirm "Also delete home directory and mail spool?"; then
        userdel -r "$USERNAME"
    else
        userdel "$USERNAME"
    fi
    rm -f "/etc/sudoers.d/$USERNAME"
    ok "User '$USERNAME' deleted."
}

change_password() {
    header "Change User Password"
    ask_username must_exist || return
    ask_password || return
    echo "$USERNAME:$PASSWORD" | chpasswd && ok "Password updated for '$USERNAME'."
    if confirm "Force the user to change password at next login?"; then
        chage -d 0 "$USERNAME" && ok "Password expiry set."
    fi
}

lock_unlock_user() {
    header "Lock / Unlock User"
    ask_username must_exist || return
    if passwd -S "$USERNAME" | awk '{print $2}' | grep -q '^L'; then
        info "User is currently LOCKED."
        confirm "Unlock it?" && usermod -U "$USERNAME" && ok "Unlocked."
    else
        info "User is currently ACTIVE."
        confirm "Lock it?" && usermod -L "$USERNAME" && ok "Locked."
    fi
}

toggle_sudo() {
    header "Add / Remove Sudo Privileges"
    ask_username must_exist || return
    if id -nG "$USERNAME" | grep -qw sudo; then
        info "'$USERNAME' is in the sudo group."
        if confirm "Remove sudo privileges?"; then
            gpasswd -d "$USERNAME" sudo >/dev/null
            rm -f "/etc/sudoers.d/$USERNAME"
            ok "Sudo removed."
        fi
    else
        info "'$USERNAME' is NOT in the sudo group."
        confirm "Grant sudo privileges?" && usermod -aG sudo "$USERNAME" && ok "Sudo granted."
    fi
}

add_ssh_key() {
    header "Add SSH Public Key"
    ask_username must_exist || return
    local key home
    read -r -p "Paste the public key: " key
    [[ "$key" =~ ^(ssh-|ecdsa-) ]] || { err "That doesn't look like a public key."; return; }
    home=$(getent passwd "$USERNAME" | cut -d: -f6)
    install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$home/.ssh"
    echo "$key" >> "$home/.ssh/authorized_keys"
    chown "$USERNAME:$USERNAME" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
    ok "Key added for '$USERNAME'."
}

user_menu() {
    while true; do
        header "User Management"
        echo " 1) List users"
        echo " 2) Create user"
        echo " 3) Delete user"
        echo " 4) Change password"
        echo " 5) Lock / Unlock user"
        echo " 6) Add / Remove sudo"
        echo " 7) Add SSH public key"
        echo " 0) Back"
        read -r -p "Choice: " c
        case $c in
            1) list_users ;;
            2) create_user ;;
            3) delete_user ;;
            4) change_password ;;
            5) lock_unlock_user ;;
            6) toggle_sudo ;;
            7) add_ssh_key ;;
            0) return ;;
            *) err "Invalid choice." ;;
        esac
        pause
    done
}

# ==========================================================
#  2. Hostname
# ==========================================================
set_hostname() {
    header "Hostname Configuration"
    info "Current hostname: $(hostname)"
    local new
    while true; do
        read -r -p "Enter new hostname (empty to cancel): " new
        [[ -z "$new" ]] && return
        valid_hostname "$new" && break
        err "Invalid hostname."
    done

    hostnamectl set-hostname "$new"
    if grep -q '^127.0.1.1' /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1 $new/" /etc/hosts
    else
        echo "127.0.1.1 $new" >> /etc/hosts
    fi
    if [[ -f /etc/cloud/cloud.cfg ]]; then
        sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
    fi
    ok "Hostname set to '$new'."
}

# ==========================================================
#  3. Network
# ==========================================================
configure_network() {
    header "Network Configuration"
    command -v netplan >/dev/null || { err "netplan is not installed."; return; }

    local interfaces
    mapfile -t interfaces < <(ls /sys/class/net | grep -v '^lo$')
    (( ${#interfaces[@]} )) || { err "No network interfaces found."; return; }

    info "Current addresses:"
    ip -br addr show | grep -v '^lo'
    echo

    local IFACE
    PS3="Select interface number: "
    select IFACE in "${interfaces[@]}" "Cancel"; do
        [[ "$IFACE" == "Cancel" ]] && return
        [[ -n "$IFACE" ]] && break
        err "Invalid selection."
    done

    echo "1) DHCP"
    echo "2) Static IP"
    local type; read -r -p "Choice [1/2]: " type

    local NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    local content

    if [[ "$type" == "1" ]]; then
        content="network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: true"
    elif [[ "$type" == "2" ]]; then
        local ip gw dns
        while true; do read -r -p "IP/Mask (e.g. 192.168.100.45/24): " ip
            valid_cidr "$ip" && break; err "Invalid IP/Mask."; done
        while true; do read -r -p "Gateway: " gw
            valid_ip "$gw" && break; err "Invalid gateway."; done
        while true; do read -r -p "DNS (comma separated, e.g. 8.8.8.8,1.1.1.1): " dns
            dns=${dns// /}
            local okdns=1
            IFS=, read -ra arr <<< "$dns"
            for d in "${arr[@]}"; do valid_ip "$d" || okdns=0; done
            (( okdns )) && [[ -n "$dns" ]] && break; err "Invalid DNS list."; done
        dns=${dns//,/, }

        content="network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: false
      addresses: [$ip]
      routes:
        - to: default
          via: $gw
      nameservers:
        addresses: [$dns]"
    else
        err "Invalid choice."; return
    fi

    # Backup old configs instead of deleting them
    local bk="/etc/netplan/backup-$(date +%Y%m%d-%H%M%S)"
    if ls /etc/netplan/*.yaml &>/dev/null; then
        mkdir -p "$bk" && mv /etc/netplan/*.yaml "$bk/"
        info "Old netplan files backed up to $bk"
    fi

    echo "$content" > "$NETPLAN_FILE"
    chmod 600 "$NETPLAN_FILE"

    if ! netplan generate; then
        err "Invalid configuration. Restoring backup."
        rm -f "$NETPLAN_FILE"; mv "$bk"/*.yaml /etc/netplan/ 2>/dev/null
        return
    fi

    warn "Applying with 'netplan try' - confirm within 120s or it auto-reverts."
    if netplan try; then
        ok "Network configuration applied."
    else
        err "Network change was reverted."
    fi
}

# ==========================================================
#  4. Extras
# ==========================================================
system_info() {
    header "System Information"
    echo "Hostname : $(hostname)"
    echo "OS       : $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "Kernel   : $(uname -r)"
    echo "Uptime   : $(uptime -p)"
    echo "CPU      : $(nproc) cores"
    echo "Memory   : $(free -h | awk '/Mem:/ {print $3 " / " $2}')"
    echo "Disk (/) : $(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
    echo "Timezone : $(timedatectl show -p Timezone --value 2>/dev/null)"
    echo; ip -br addr show
}

reboot_system() {
    confirm "Reboot now?" && reboot
}

extras_menu() {
    while true; do
        header "Extra Tools"
        echo " 1) System information"
        echo " 2) Reboot"
        echo " 0) Back"
        read -r -p "Choice: " c
        case $c in
            1) system_info ;;
            2) reboot_system ;;
            0) return ;;
            *) err "Invalid choice." ;;
        esac
        pause
    done
}

# ==========================================================
#  Main Menu
# ==========================================================
while true; do
    header "Interactive System Setup"
    echo " 1) User management"
    echo " 2) Hostname"
    echo " 3) Network"
    echo " 4) Extra tools"
    echo " 0) Exit"
    read -r -p "Choice: " choice
    case $choice in
        1) user_menu ;;
        2) set_hostname; pause ;;
        3) configure_network; pause ;;
        4) extras_menu ;;
        0) ok "Setup finished. Goodbye!"; exit 0 ;;
        *) err "Invalid choice."; sleep 1 ;;
    esac
done
