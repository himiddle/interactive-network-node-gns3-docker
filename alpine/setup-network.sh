#!/bin/sh

# INTERACTIVE NETWORK NODE v1.0 - POSIX-compatible

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
ORANGE='\033[0;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
LOG_FILE="${SCRIPT_DIR}/network_config.log"
TEMP_FILE="/tmp/netcfg_$$.tmp"
RESOLV_CONF="/etc/resolv.conf"
HOSTNAME=$(hostname 2>/dev/null || echo "node")
SELECTED_INTERFACE=""
VERSION="1.0"
AUTHOR="himiddle"

trap 'rm -f $TEMP_FILE' EXIT

log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$LOG_FILE"; }

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        printf '%s %s' "${NAME:-Unknown}" "${VERSION:-}"
    else
        printf 'Unknown OS'
    fi
}

check_dependencies() {
    _missing=""
    for _cmd in ip hostname awk sed tr wc; do
        if ! command -v "$_cmd" >/dev/null 2>&1; then
            _missing="$_missing $_cmd"
        fi
    done
    if [ -n "$_missing" ]; then
        printf "${RED}Error: Missing:%s${NC}\n" "$_missing"
        exit 1
    fi
}

print_header() {
    clear 2>/dev/null || printf '\n\n\n'
    printf "${CYAN}═══ INTERACTIVE NETWORK NODE v%s ═══${NC}\n" "$VERSION"
    printf '\n'
    printf "${WHITE}OS Version:${NC} ${GREEN}%s${NC}\n" "$(detect_os)"
    printf "Created by ${MAGENTA}%s${NC}\n" "$AUTHOR"
    printf '\n'
}
print_prompt() { printf "${ORANGE}%s${NC}# " "$HOSTNAME"; }

get_interfaces() { ls /sys/class/net/ 2>/dev/null | grep -v "lo"; }
get_gw4() { ip route show default dev "$1" 2>/dev/null | awk '{print $3}' | head -1; }
get_gw6() { ip -6 route show default dev "$1" 2>/dev/null | awk '{print $3}' | head -1; }

get_existing_gateway_info() {
    ip route show default 2>/dev/null | grep -v "dev $1" | awk '{print "GW="$3" DEV="$5}'
}

get_static_routes() {
    ip route show dev "$1" 2>/dev/null | grep -v "default\|proto kernel\|linkdown" | awk '{print $1" via "$3}'
}

get_static_routes6() {
    ip -6 route show dev "$1" 2>/dev/null | grep -v "default\|proto kernel\|fe80\|linkdown" | awk '{print $1" via "$3}'
}

check_duplicate_ip() {
    _new_ip="$1"; _current_iface="$2"
    _ip_clean=$(echo "$_new_ip" | cut -d/ -f1)

    for _iface in $(get_interfaces); do
        [ "$_iface" = "$_current_iface" ] && continue
        _existing=$(ip -4 addr show dev "$_iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        [ -z "$_existing" ] && continue
        _existing_clean=$(echo "$_existing" | cut -d/ -f1)
        if [ "$_ip_clean" = "$_existing_clean" ]; then
            echo "$_iface"
            return 0
        fi
    done
    return 1
}

get_ip4_type() {
    _ip=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    [ -z "$_ip" ] && { echo "none"; return; }

    if [ -f "/var/run/dhcp-$1.marker" ]; then
        echo "dhcp"
        return
    fi

    if pgrep -f "dhclient.*$1" >/dev/null 2>&1; then
        echo "dhcp"
        return
    fi
    if pgrep -f "udhcpc.*$1" >/dev/null 2>&1; then
        echo "dhcp"
        return
    fi

    echo "static"
}

get_ip6_type() {
    _ip=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    [ -z "$_ip" ] && { echo "none"; return; }
    [ -f "/var/run/dhcp6-$1.marker" ] && { echo "dhcp"; return; }
    echo "static"
}

set_dhcp_marker() { mkdir -p /var/run 2>/dev/null; touch "/var/run/dhcp-${1}.marker" 2>/dev/null; }
clear_dhcp_marker() { rm -f "/var/run/dhcp-${1}.marker" 2>/dev/null; }
set_dhcp6_marker() { mkdir -p /var/run 2>/dev/null; touch "/var/run/dhcp6-${1}.marker" 2>/dev/null; }
clear_dhcp6_marker() { rm -f "/var/run/dhcp6-${1}.marker" 2>/dev/null; }

validate_ip4() {
    _ip="$1"
    case "$_ip" in *[!0-9.]*) return 1 ;; esac

    _dots=0; _tmp="$_ip"
    while [ "$_tmp" != "${_tmp#*.}" ]; do _dots=$((_dots+1)); _tmp="${_tmp#*.}"; done
    [ "$_dots" -ne 3 ] && return 1

    _oldIFS="$IFS"; IFS='.'; set -- $_ip; IFS="$_oldIFS"
    [ $# -ne 4 ] && return 1

    for _octet; do
        case "$_octet" in ''|*[!0-9]*) return 1 ;; esac
        [ "$_octet" -lt 0 ] 2>/dev/null && return 1
        [ "$_octet" -gt 255 ] 2>/dev/null && return 1
    done
    return 0
}

validate_ip6() { echo "$1" | grep -E '^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$' >/dev/null; }
validate_mask4() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 32 ]; }
validate_mask6() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 128 ]; }
validate_port() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

clear_iface_full() {
    pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
    clear_dhcp_marker "$1"; clear_dhcp6_marker "$1"; sleep 0.5
    ip addr flush dev "$1" 2>/dev/null; ip -6 addr flush dev "$1" 2>/dev/null
    ip route del default dev "$1" 2>/dev/null; ip -6 route del default dev "$1" 2>/dev/null

    _routes4=$(get_static_routes "$1")
    if [ -n "$_routes4" ]; then
        echo "$_routes4" | while read -r _r; do
            ip route del $(echo "$_r" | awk '{print $1}') via $(echo "$_r" | awk '{print $3}') dev "$1" 2>/dev/null
        done
    fi

    _routes6=$(get_static_routes6 "$1")
    if [ -n "$_routes6" ]; then
        echo "$_routes6" | while read -r _r; do
            ip -6 route del $(echo "$_r" | awk '{print $1}') via $(echo "$_r" | awk '{print $3}') dev "$1" 2>/dev/null
        done
    fi

    ip link set "$1" down 2>/dev/null; sleep 1; ip link set "$1" up 2>/dev/null
}

clear_ip4_full() {
    pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
    clear_dhcp_marker "$1"
    ip addr flush dev "$1" 2>/dev/null
    ip route del default dev "$1" 2>/dev/null

    _routes4=$(get_static_routes "$1")
    if [ -n "$_routes4" ]; then
        echo "$_routes4" | while read -r _r; do
            ip route del $(echo "$_r" | awk '{print $1}') via $(echo "$_r" | awk '{print $3}') dev "$1" 2>/dev/null
        done
    fi
}

clear_ip6_full() {
    clear_dhcp6_marker "$1"
    ip -6 addr flush dev "$1" 2>/dev/null
    ip -6 route del default dev "$1" 2>/dev/null

    _routes6=$(get_static_routes6 "$1")
    if [ -n "$_routes6" ]; then
        echo "$_routes6" | while read -r _r; do
            ip -6 route del $(echo "$_r" | awk '{print $1}') via $(echo "$_r" | awk '{print $3}') dev "$1" 2>/dev/null
        done
    fi
}

clear_ips_only() {
    pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
    clear_dhcp_marker "$1"; clear_dhcp6_marker "$1"
    ip addr flush dev "$1" 2>/dev/null; ip -6 addr flush dev "$1" 2>/dev/null
}

clear_ips_only_menu() {
    printf "  ${GREEN}1${NC}) Clear IPv4 only\n"
    printf "  ${GREEN}2${NC}) Clear IPv6 only\n"
    printf "  ${GREEN}3${NC}) Clear both IPv4 and IPv6\n"
    printf "  ${GREEN}4${NC}) Cancel\n\n"
    read -r -p "$(print_prompt)" v
    [ "$v" = "q" ] && return
    case "$v" in
        1) pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
           clear_dhcp_marker "$1"; ip addr flush dev "$1" 2>/dev/null
           printf "${GREEN}IPv4 cleared${NC}\n" ;;
        2) clear_dhcp6_marker "$1"; ip -6 addr flush dev "$1" 2>/dev/null
           printf "${GREEN}IPv6 cleared${NC}\n" ;;
        3) pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
           clear_dhcp_marker "$1"; clear_dhcp6_marker "$1"
           ip addr flush dev "$1" 2>/dev/null; ip -6 addr flush dev "$1" 2>/dev/null
           printf "${GREEN}IPs cleared${NC}\n" ;;
    esac
    read -r -p "Press Enter to continue..."
}

show_dns() {
    printf "${WHITE}DNS:${NC}\n"
    if [ -f "$RESOLV_CONF" ]; then
        if grep -q "^nameserver" "$RESOLV_CONF" 2>/dev/null; then
            grep "^nameserver" "$RESOLV_CONF" 2>/dev/null | while read -r _l; do printf "  ${GREEN}%s${NC}\n" "$_l"; done
        else printf "  ${YELLOW}none${NC}\n"; fi
    else printf "  ${RED}Error: no resolv.conf${NC}\n"; fi
    echo
}

configure_dns() {
    show_dns
    printf "${WHITE}DNS:${NC}\n"
    printf "  ${GREEN}1${NC}) Add DNS\n  ${GREEN}2${NC}) Remove DNS\n  ${GREEN}3${NC}) Set primary DNS\n  ${GREEN}4${NC}) Clear all DNS\n  ${GREEN}5${NC}) Cancel\n\n"
    read -r -p "$(print_prompt)" c
    [ "$c" = "q" ] && return
    case "$c" in
        1) read -r -p "IP: " ip; validate_ip4 "$ip" || validate_ip6 "$ip" || { printf "${RED}Error: Invalid IP${NC}\n"; read -r -p "Press Enter to continue..."; return; }
           grep -q "^nameserver $ip" "$RESOLV_CONF" 2>/dev/null && printf "${YELLOW}Exists${NC}\n" || { echo "nameserver $ip" >> "$RESOLV_CONF"; printf "${GREEN}Added${NC}\n"; }; read -r -p "Press Enter to continue..." ;;
        2) read -r -p "IP: " ip; grep -q "^nameserver $ip" "$RESOLV_CONF" 2>/dev/null && { sed -i "/^nameserver $ip/d" "$RESOLV_CONF" 2>/dev/null; printf "${GREEN}Removed${NC}\n"; } || printf "${YELLOW}Not found${NC}\n"; read -r -p "Press Enter to continue..." ;;
        3) read -r -p "IP: " ip; validate_ip4 "$ip" || validate_ip6 "$ip" || { printf "${RED}Error: Invalid IP${NC}\n"; read -r -p "Press Enter to continue..."; return; }
           grep -v "^nameserver" "$RESOLV_CONF" 2>/dev/null > "${RESOLV_CONF}.tmp"; echo "nameserver $ip" >> "${RESOLV_CONF}.tmp"; mv "${RESOLV_CONF}.tmp" "$RESOLV_CONF" 2>/dev/null; printf "${GREEN}Set${NC}\n"; read -r -p "Press Enter to continue..." ;;
        4) [ -f "$RESOLV_CONF" ] && { cp "$RESOLV_CONF" "${RESOLV_CONF}.backup" 2>/dev/null; sed -i '/^nameserver/d' "$RESOLV_CONF" 2>/dev/null; printf "${GREEN}Cleared${NC}\n"; }; read -r -p "Press Enter to continue..." ;;
        5|"") return ;;
        *) printf "${RED}Error: Invalid option${NC}\n"; sleep 1 ;;
    esac
}

show_interfaces() {
    _ifaces=$(get_interfaces)
    [ -z "$_ifaces" ] && { printf "${RED}Error: No interfaces${NC}\n"; return 1; }
    printf "${WHITE}%-8s %-20s %-26s %-8s %s${NC}\n" "Iface" "IPv4" "IPv6" "Status" "Method"
    printf "${CYAN}────────────────────────────────────────────────────────────────────${NC}\n"
    for _i in $_ifaces; do
        _ip4=$(ip -4 addr show dev "$_i" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        _ip6=$(ip -6 addr show dev "$_i" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
        _t4=$(get_ip4_type "$_i"); _t6=$(get_ip6_type "$_i")
        _m="-"
        if [ "$_t4" = "dhcp" ] || [ "$_t6" = "dhcp" ]; then _m="D"
        elif [ "$_t4" = "static" ] || [ "$_t6" = "static" ]; then _m="S"
        else _m="N"; fi
        _s=$(ip link show "$_i" 2>/dev/null | awk '/state/ {print $9}'); [ -z "$_s" ] && _s="DOWN"
        printf "%-8s " "$_i"
        [ -z "$_ip4" ] && printf "${RED}%-20s${NC} " "none" || printf "${GREEN}%-20s${NC} " "$_ip4"
        [ -z "$_ip6" ] && printf "${RED}%-26s${NC} " "none" || printf "${GREEN}%-26s${NC} " "$_ip6"
        printf "%-8s " "$_s"
        case "$_m" in D) printf "${YELLOW}[D]${NC}\n" ;; S) printf "${YELLOW}[S]${NC}\n" ;; *) printf "${GRAY}[N]${NC}\n" ;; esac
    done
    echo
}

select_iface() {
    _ifaces=$(get_interfaces)
    [ -z "$_ifaces" ] && { printf "${RED}Error: No interfaces${NC}\n"; return 1; }
    printf "${WHITE}Available:${NC}\n"
    _n=1
    for _i in $_ifaces; do printf "  ${GREEN}%d${NC}) %s\n" "$_n" "$_i"; _n=$((_n+1)); done
    echo
    while true; do
        read -r -p "$(print_prompt)" c
        [ "$c" = "q" ] && { echo "EXIT" > "$TEMP_FILE"; return 0; }
        case "$c" in ''|*[!0-9]*) printf "${RED}Error: 1-%d or q${NC}\n" $((_n-1)); continue ;; esac
        _count=1
        for _i in $_ifaces; do [ $_count -eq $c ] && { echo "$_i" > "$TEMP_FILE"; return 0; }; _count=$((_count+1)); done
        printf "${RED}Error: 1-%d or q${NC}\n" $((_n-1))
    done
}

get_selected() { [ -f "$TEMP_FILE" ] && cat "$TEMP_FILE"; }

show_iface_config() {
    _iface="$1"
    [ -z "$_iface" ] && { printf "${RED}Error: No interface${NC}\n"; return 1; }
    [ ! -d "/sys/class/net/$_iface" ] && { printf "${RED}Error: %s not found${NC}\n" "$_iface"; return 1; }

    _ip4=$(ip -4 addr show dev "$_iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    _ip6=$(ip -6 addr show dev "$_iface" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    _t4=$(get_ip4_type "$_iface"); _t6=$(get_ip6_type "$_iface")
    _mac=$(ip link show "$_iface" 2>/dev/null | awk '/link\/ether/ {print $2}')

    [ -z "$_ip4" ] && _ip4="none"; [ -z "$_ip6" ] && _ip6="none"; [ -z "$_mac" ] && _mac="unknown"

    _m4="N"; [ "$_t4" = "dhcp" ] && _m4="D"; [ "$_t4" = "static" ] && _m4="S"
    _m6="N"; [ "$_t6" = "dhcp" ] && _m6="D"; [ "$_t6" = "static" ] && _m6="S"
    _c4="$GRAY"; [ "$_m4" = "D" ] && _c4="$YELLOW"; [ "$_m4" = "S" ] && _c4="$YELLOW"
    _c6="$GRAY"; [ "$_m6" = "D" ] && _c6="$YELLOW"; [ "$_m6" = "S" ] && _c6="$YELLOW"

    _def_gw4=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    _def_gw4_dev=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    _def_gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
    _def_gw6_dev=$(ip -6 route show default 2>/dev/null | awk '{print $5}' | head -1)

    printf "${CYAN}═══ ${GREEN}%s${CYAN} ═══${NC}\n" "$_iface"
    printf "  ${WHITE}MAC:${NC} ${WHITE}%s${NC}\n" "$_mac"

    printf "  ${WHITE}IPv4:${NC} "; [ "$_ip4" = "none" ] && printf "${RED}%-24s${NC}" "$_ip4" || printf "${GREEN}%-24s${NC}" "$_ip4"
    printf "${_c4}[${_m4}]${NC}\n"

    printf "  ${WHITE}IPv6:${NC} "; [ "$_ip6" = "none" ] && printf "${RED}%-24s${NC}" "$_ip6" || printf "${GREEN}%-24s${NC}" "$_ip6"
    printf "${_c6}[${_m6}]${NC}\n"

    if [ -n "$_def_gw4" ]; then
        printf "  ${WHITE}Default GWv4:${NC} ${MAGENTA}%s dev %s${NC}\n" "$_def_gw4" "$_def_gw4_dev"
    else
        printf "  ${WHITE}Default GWv4:${NC} ${RED}none${NC}\n"
    fi

    if [ -n "$_def_gw6" ]; then
        printf "  ${WHITE}Default GWv6:${NC} ${MAGENTA}%s dev %s${NC}\n" "$_def_gw6" "$_def_gw6_dev"
    else
        printf "  ${WHITE}Default GWv6:${NC} ${RED}none${NC}\n"
    fi

    _routes4=$(get_static_routes "$_iface")
    if [ -n "$_routes4" ]; then
        echo "$_routes4" | while read -r _r; do printf "  ${WHITE}Route:${NC} ${GREEN}%s${NC}\n" "$_r"; done
    fi

    _routes6=$(get_static_routes6 "$_iface")
    if [ -n "$_routes6" ]; then
        echo "$_routes6" | while read -r _r; do printf "  ${WHITE}Route6:${NC} ${GREEN}%s${NC}\n" "$_r"; done
    fi
    echo
}

# DELETE ROUTE
del_route() {
    _iface="$1"
    printf "${WHITE}Delete route from ${GREEN}%s${NC}\n" "$_iface"
    printf "  ${GREEN}1${NC}) Delete default gateway\n  ${GREEN}2${NC}) Delete static route\n  ${GREEN}3${NC}) Cancel\n\n"
    read -r -p "$(print_prompt)" type
    [ "$type" = "q" ] && return
    case "$type" in
        3|"") return ;;
        1) printf "  ${GREEN}1${NC}) Default GWv4\n  ${GREEN}2${NC}) Default GWv6\n  ${GREEN}3${NC}) Cancel\n\n"
           read -r -p "$(print_prompt)" ver; [ "$ver" = "q" ] && return
           case "$ver" in 1) ip route del default 2>/dev/null; printf "${GREEN}Removed${NC}\n" ;; 2) ip -6 route del default 2>/dev/null; printf "${GREEN}Removed${NC}\n" ;; esac
           read -r -p "Press Enter to continue..." ;;
        2) printf "  ${GREEN}1${NC}) IPv4\n  ${GREEN}2${NC}) IPv6\n  ${GREEN}3${NC}) Cancel\n\n"
           read -r -p "$(print_prompt)" ver; [ "$ver" = "q" ] && return
           case "$ver" in
               1) _r4=$(get_static_routes "$_iface")
                  [ -z "$_r4" ] && { printf "${YELLOW}None${NC}\n"; read -r -p "Press Enter to continue..."; return; }
                  echo "$_r4" | cat -n; read -r -p "Number: " n; [ "$n" = "q" ] && return
                  case "$n" in ''|*[!0-9]*) ;; *) _rt=$(echo "$_r4" | sed -n "${n}p")
                      [ -n "$_rt" ] && { ip route del $(echo "$_rt" | awk '{print $1}') via $(echo "$_rt" | awk '{print $3}') dev "$_iface" 2>/dev/null; printf "${GREEN}Removed: %s${NC}\n" "$_rt"; } ;; esac
                  read -r -p "Press Enter to continue..." ;;
               2) _r6=$(get_static_routes6 "$_iface")
                  [ -z "$_r6" ] && { printf "${YELLOW}None${NC}\n"; read -r -p "Press Enter to continue..."; return; }
                  echo "$_r6" | cat -n; read -r -p "Number: " n; [ "$n" = "q" ] && return
                  case "$n" in ''|*[!0-9]*) ;; *) _rt=$(echo "$_r6" | sed -n "${n}p")
                      [ -n "$_rt" ] && { ip -6 route del $(echo "$_rt" | awk '{print $1}') via $(echo "$_rt" | awk '{print $3}') dev "$_iface" 2>/dev/null; printf "${GREEN}Removed: %s${NC}\n" "$_rt"; } ;; esac
                  read -r -p "Press Enter to continue..." ;;
           esac ;;
    esac
}

# ADD STATIC ROUTE
add_static_route() {
    _iface="$1"

    printf "\n${WHITE}Current routes on ${GREEN}%s${NC}:\n" "$_iface"
    printf "${CYAN}────────────────────────────────────────${NC}\n"

    _def_gw4=$(ip route show default 2>/dev/null | awk '{print "IPv4: via "$3" dev "$5}' | head -1)
    _def_gw6=$(ip -6 route show default 2>/dev/null | awk '{print "IPv6: via "$3" dev "$5}' | head -1)
    printf "${WHITE}Default GW:${NC}\n"
    [ -n "$_def_gw4" ] && printf "  ${MAGENTA}%s${NC}\n" "$_def_gw4" || printf "  ${RED}IPv4: none${NC}\n"
    [ -n "$_def_gw6" ] && printf "  ${MAGENTA}%s${NC}\n" "$_def_gw6" || printf "  ${RED}IPv6: none${NC}\n"

    printf "\n${WHITE}Static routes on %s:${NC}\n" "$_iface"
    _routes4=$(get_static_routes "$_iface")
    _routes6=$(get_static_routes6 "$_iface")
    [ -n "$_routes4" ] && echo "$_routes4" | while read -r _r; do printf "  ${GREEN}%s${NC}\n" "$_r"; done || printf "  ${RED}IPv4: none${NC}\n"
    [ -n "$_routes6" ] && echo "$_routes6" | while read -r _r; do printf "  ${GREEN}%s${NC}\n" "$_r"; done || printf "  ${RED}IPv6: none${NC}\n"

    _iface_net=$(ip -4 route show dev "$_iface" 2>/dev/null | grep "proto kernel" | awk '{print $1}' | head -1)
    [ -n "$_iface_net" ] && printf "\n${WHITE}Interface subnet:${NC} ${GREEN}%s${NC} ${YELLOW}(directly connected)${NC}\n" "$_iface_net"

    printf "${CYAN}────────────────────────────────────────${NC}\n\n"

    printf "${WHITE}Add static route for ${GREEN}%s${NC}\n" "$_iface"
    printf "  ${GREEN}1${NC}) IPv4\n  ${GREEN}2${NC}) IPv6\n  ${GREEN}3${NC}) Cancel\n\n"
    read -r -p "$(print_prompt)" ver
    [ "$ver" = "q" ] && return
    case "$ver" in
        3|"") return ;;
        1) while true; do
            read -r -p "Subnet (e.g. 192.168.100.0/24): " s; [ -z "$s" ] && return; [ "$s" = "q" ] && return
            echo "$s" | grep -q '/' || { printf "${RED}Error: Need /mask${NC}\n"; continue; }
            _net=$(echo "$s"|cut -d/ -f1); _mask=$(echo "$s"|cut -d/ -f2)
            [ -z "$_mask" ] || [ "$_mask" = "$_net" ] && { printf "${RED}Error: Invalid mask${NC}\n"; continue; }
            validate_ip4 "$_net" || { printf "${RED}Error: Invalid network${NC}\n"; continue; }
            validate_mask4 "$_mask" || { printf "${RED}Error: Mask /1-/32${NC}\n"; continue; }
            [ "$s" = "$_iface_net" ] && { printf "${YELLOW}Own subnet${NC}\n"; read -r -p "Press Enter to continue..."; return; }
            read -r -p "Gateway: " gw; [ -z "$gw" ] && return; [ "$gw" = "q" ] && return
            validate_ip4 "$gw" || { printf "${RED}Error: Invalid gateway${NC}\n"; continue; }
            ip route show "$s" 2>/dev/null | grep -q "via $gw" && { printf "${YELLOW}Exists${NC}\n"; read -r -p "Press Enter to continue..."; return; }
            ip route add "$s" via "$gw" dev "$_iface" 2>&1 && printf "${GREEN}Added: %s via %s${NC}\n" "$s" "$gw" || printf "${RED}Error: Failed${NC}\n"
            read -r -p "Press Enter to continue..."; return
        done ;;
        2) while true; do
            read -r -p "Subnet (e.g. 2001:db8:100::/48): " s; [ -z "$s" ] && return; [ "$s" = "q" ] && return
            echo "$s" | grep -q '/' || { printf "${RED}Error: Need /mask${NC}\n"; continue; }
            _net=$(echo "$s"|cut -d/ -f1); _mask=$(echo "$s"|cut -d/ -f2)
            [ -z "$_mask" ] || [ "$_mask" = "$_net" ] && { printf "${RED}Error: Invalid mask${NC}\n"; continue; }
            validate_ip6 "$_net" || { printf "${RED}Error: Invalid IPv6${NC}\n"; continue; }
            validate_mask6 "$_mask" || { printf "${RED}Error: Mask /1-/128${NC}\n"; continue; }
            read -r -p "Gateway: " gw; [ -z "$gw" ] && return; [ "$gw" = "q" ] && return
            validate_ip6 "$gw" || { printf "${RED}Error: Invalid gateway${NC}\n"; continue; }
            ip -6 route show "$s" 2>/dev/null | grep -q "via $gw" && { printf "${YELLOW}Exists${NC}\n"; read -r -p "Press Enter to continue..."; return; }
            ip -6 route add "$s" via "$gw" dev "$_iface" 2>&1 && printf "${GREEN}Added: %s via %s${NC}\n" "$s" "$gw" || printf "${RED}Error: Failed${NC}\n"
            read -r -p "Press Enter to continue..."; return
        done ;;
    esac
}

# PORT CHECK
check_port() {
    while true; do
        print_header; show_iface_config "$SELECTED_INTERFACE"
        printf "${WHITE}Port Check${NC}\n\n"
        printf "  ${GREEN}1${NC}) Single port\n  ${GREEN}2${NC}) Port range\n  ${GREEN}3${NC}) Common ports\n  ${GREEN}4${NC}) Back\n\n"
        read -r -p "$(print_prompt)" type
        [ "$type" = "q" ] && return
        _target=""; _ports=""

        case "$type" in
            4|"") return ;;
            1) read -r -p "Target: " _target; [ -z "$_target" ] && continue; [ "$_target" = "q" ] && continue
               read -r -p "Port: " port; [ "$port" = "q" ] && continue
               if ! validate_port "$port"; then
                   printf "${RED}Error: Invalid port (1-65535)${NC}\n"
                   read -r -p "Press Enter to continue..."
                   continue
               fi
               _ports="$port" ;;
            2) read -r -p "Target: " _target; [ -z "$_target" ] && continue; [ "$_target" = "q" ] && continue
               read -r -p "Start: " sp; read -r -p "End: " ep; [ "$sp" = "q" ] || [ "$ep" = "q" ] && continue
               if ! validate_port "$sp" || ! validate_port "$ep"; then
                   printf "${RED}Error: Invalid port range${NC}\n"
                   read -r -p "Press Enter to continue..."
                   continue
               fi
               if [ "$sp" -gt "$ep" ]; then
                   printf "${RED}Error: Start > End${NC}\n"
                   read -r -p "Press Enter to continue..."
                   continue
               fi
               _ports=$(seq $sp $ep 2>/dev/null) ;;
            3) read -r -p "Target: " _target; [ -z "$_target" ] && continue; [ "$_target" = "q" ] && continue
               _ports="22 80 443 8080 8443" ;;
            *) printf "${RED}Error: Invalid option${NC}\n"; sleep 1; continue ;;
        esac

        printf "\n${CYAN}Scanning %s...${NC}\n\n" "$_target"
        printf "${WHITE}%-8s %-12s %s${NC}\n" "Port" "State" "Service"
        printf "${CYAN}────────────────────────────${NC}\n"
        _open=0; _closed=0

        for _port in $_ports; do
            printf "  %-6s " "$_port"
            _result=1
            if command -v nc >/dev/null 2>&1; then
                timeout 3 nc -z "$_target" "$_port" 2>/dev/null && _result=0
            else
                timeout 3 sh -c "echo >/dev/tcp/$_target/$_port" 2>/dev/null && _result=0
            fi

            if [ $_result -eq 0 ]; then
                _svc="?"
                case "$_port" in 22) _svc="SSH" ;; 80) _svc="HTTP" ;; 443) _svc="HTTPS" ;; 8080) _svc="HTTP-Alt" ;; 8443) _svc="HTTPS-Alt" ;; esac
                printf "${GREEN}open${NC}      %s\n" "$_svc"
                _open=$((_open+1))
            else
                printf "${RED}closed${NC}\n"
                _closed=$((_closed+1))
            fi
        done
        printf "${CYAN}────────────────────────────${NC}\n"
        printf "${WHITE}Open:${NC} ${GREEN}%d${NC} ${WHITE}Closed:${NC} ${RED}%d${NC}\n\n" "$_open" "$_closed"
        read -r -p "Press Enter to continue..."
    done
}

# PACKAGES
detect_pkg() {
    if command -v apk >/dev/null 2>&1; then echo "apk"
    elif command -v apt-get >/dev/null 2>&1; then echo "apt"
    else echo "unknown"
    fi
}

install_packages() {
    _pkg=$(detect_pkg)
    [ "$_pkg" = "unknown" ] && { printf "${RED}Error: No package manager${NC}\n"; read -r -p "Press Enter to continue..."; return 1; }

    while true; do
        print_header; show_iface_config "$SELECTED_INTERFACE"
        printf "${WHITE}Package Manager: ${GREEN}%s${NC}\n\n" "$_pkg"
        printf "  ${GREEN}1${NC}) Update + install\n  ${GREEN}2${NC}) Install only\n  ${GREEN}3${NC}) Full upgrade\n  ${GREEN}4${NC}) Back\n\n"
        read -r -p "$(print_prompt)" c
        [ "$c" = "q" ] && return

        case "$c" in
            1) read -r -p "Package(s): " pkgs; [ -z "$pkgs" ] && continue; [ "$pkgs" = "q" ] && continue
               case "$_pkg" in
                   apk) apk update && apk add $pkgs && printf "${GREEN}[OK] Installed: %s${NC}\n" "$pkgs" || printf "${RED}[FAIL]${NC}\n" ;;
                   apt) apt-get update && apt-get install -y $pkgs && printf "${GREEN}[OK] Installed: %s${NC}\n" "$pkgs" || printf "${RED}[FAIL]${NC}\n" ;;
               esac
               read -r -p "Press Enter to continue..." ;;
            2) read -r -p "Package(s): " pkgs; [ -z "$pkgs" ] && continue; [ "$pkgs" = "q" ] && continue
               case "$_pkg" in
                   apk) apk add $pkgs && printf "${GREEN}[OK] Installed: %s${NC}\n" "$pkgs" || printf "${RED}[FAIL]${NC}\n" ;;
                   apt) apt-get install -y $pkgs && printf "${GREEN}[OK] Installed: %s${NC}\n" "$pkgs" || printf "${RED}[FAIL]${NC}\n" ;;
               esac
               read -r -p "Press Enter to continue..." ;;
            3) case "$_pkg" in
                   apk) apk update && apk upgrade && printf "${GREEN}[OK] Upgraded${NC}\n" || printf "${RED}[FAIL]${NC}\n" ;;
                   apt) apt-get update && apt-get upgrade -y && printf "${GREEN}[OK] Upgraded${NC}\n" || printf "${RED}[FAIL]${NC}\n" ;;
               esac
               read -r -p "Press Enter to continue..." ;;
            4|"") return ;;
            *) printf "${RED}Error: Invalid option${NC}\n"; sleep 1 ;;
        esac
    done
}

# IPv4
dhcp4_disco() {
    printf "${YELLOW}Flushing %s...${NC}\n" "$1"; ip addr flush dev "$1" 2>/dev/null
    printf "${YELLOW}Starting DHCPv4...${NC}\n"
    if command -v udhcpc >/dev/null 2>&1; then
        udhcpc -i "$1" -n -q 2>&1; sleep 2
    elif command -v dhclient >/dev/null 2>&1; then
        dhclient "$1" 2>&1; sleep 2
    else
        printf "${RED}Error: No DHCP client. Install: apk add dhclient${NC}\n"; return 1
    fi
    _ip=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    if [ -n "$_ip" ]; then
        printf "${GREEN}DHCPv4: %s${NC}\n" "$_ip"; set_dhcp_marker "$1"
        _gw=$(get_gw4 "$1"); [ -n "$_gw" ] && printf "${GREEN}GW: %s${NC}\n" "$_gw"
        grep -q "^nameserver" "$RESOLV_CONF" 2>/dev/null || { echo "nameserver 8.8.8.8" >> "$RESOLV_CONF"; echo "nameserver 8.8.4.4" >> "$RESOLV_CONF"; }
        return 0
    else printf "${RED}Error: DHCPv4 failed${NC}\n"; return 1; fi
}

config_ip4() {
    _ip=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    _current_type=$(get_ip4_type "$1")

    if [ "$_current_type" = "dhcp" ]; then
        printf "${YELLOW}Interface is configured via DHCP${NC}\n"
        [ -n "$_ip" ] && printf "${YELLOW}Current IP: %s${NC}\n" "$_ip"
        printf "  ${GREEN}1${NC}) Clear DHCP and set static\n"
        printf "  ${GREEN}2${NC}) Renew DHCP\n"
        printf "  ${GREEN}3${NC}) Cancel\n\n"
        read -r -p "$(print_prompt)" cc
        [ "$cc" = "q" ] && return 1
        case "$cc" in
            1)
                pkill -f "dhclient.*$1" 2>/dev/null
                pkill -f "udhcpc.*$1" 2>/dev/null
                clear_dhcp_marker "$1"
                ip addr flush dev "$1" 2>/dev/null
                ip link set "$1" up 2>/dev/null
                printf "${GREEN}DHCP cleared, now set static IP${NC}\n"
                _ip=""
                ;;
            2) dhcp4_disco "$1"; read -r -p "Press Enter to continue..."; return 0 ;;
            3|"") return 1 ;;
            *) printf "${RED}Error: Invalid option${NC}\n"; read -r -p "Press Enter to continue..."; return 1 ;;
        esac
    fi

    [ -n "$_ip" ] && [ "$_current_type" != "dhcp" ] && printf "${YELLOW}Current: %s${NC}\n" "$_ip"
    [ "$_current_type" != "dhcp" ] && {
        printf "  ${GREEN}1${NC}) Static\n  ${GREEN}2${NC}) DHCP\n  ${GREEN}3${NC}) Cancel\n\n"
        read -r -p "$(print_prompt)" c
        [ "$c" = "q" ] && return 1
        case "$c" in
            3|"") return 1 ;;
            2) dhcp4_disco "$1"; read -r -p "Press Enter to continue..."; return 0 ;;
        esac
    }

    while true; do
        read -r -p "IPv4/mask: " uip; [ -z "$uip" ] && return 1; [ "$uip" = "q" ] && return 1
        echo "$uip" | grep -q '/' || { printf "${RED}Error: Need /mask${NC}\n"; continue; }
        _ic=$(echo "$uip"|cut -d/ -f1); _mc=$(echo "$uip"|cut -d/ -f2)
        [ -z "$_mc" ] || [ "$_mc" = "$_ic" ] && { printf "${RED}Error: Invalid mask${NC}\n"; continue; }
        validate_ip4 "$_ic" || { printf "${RED}Error: Invalid IPv4${NC}\n"; continue; }
        validate_mask4 "$_mc" || { printf "${RED}Error: Mask /1-/32${NC}\n"; continue; }
        _dup=$(check_duplicate_ip "$uip" "$1")
        [ -n "$_dup" ] && { printf "${RED}Error: IP %s already used on %s${NC}\n" "$_ic" "$_dup"; read -r -p "Press Enter to continue..."; continue; }

        [ -n "$_ip" ] && ip addr del "$_ip" dev "$1" 2>/dev/null
        pkill -f "dhclient.*$1" 2>/dev/null
        pkill -f "udhcpc.*$1" 2>/dev/null
        clear_dhcp_marker "$1"

        ip addr add "$uip" dev "$1" 2>&1 && printf "${GREEN}Set: %s${NC}\n" "$uip" || printf "${RED}Error: Failed${NC}\n"
        read -r -p "Press Enter to continue..."; return 0
    done
}

config_gw4() {
    _cgw=$(get_gw4 "$1"); _cip=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    [ -z "$_cip" ] && { printf "${RED}Error: Set IPv4 first${NC}\n"; read -r -p "Press Enter to continue..."; return 1; }
    [ "$(get_ip4_type "$1")" = "dhcp" ] && { printf "${RED}Error: DHCP has automatic gateway${NC}\n"; read -r -p "Press Enter to continue..."; return 1; }
    _existing_gw=$(get_existing_gateway_info "$1")
    [ -n "$_existing_gw" ] && printf "${RED}Gateway already on: %s${NC}\n${YELLOW}New will REPLACE!${NC}\n" "$_existing_gw"
    _ipo=$(echo "$_cip"|cut -d/ -f1)
    printf "${WHITE}GW for %s${NC} IP: %s GW: %s\n\n" "$1" "$_cip" "${_cgw:-none}"
    while true; do
        read -r -p "Gateway (Enter=cancel, del=remove, q=quit): " ugw
        [ -z "$ugw" ] && return 1
        [ "$ugw" = "q" ] && return 1
        [ "$ugw" = "del" ] && { [ -n "$_cgw" ] && ip route del default 2>/dev/null && printf "${GREEN}Removed${NC}\n" || printf "${YELLOW}No GW${NC}\n"; read -r -p "Press Enter to continue..."; return 0; }
        validate_ip4 "$ugw" || { printf "${RED}Error: Invalid IPv4${NC}\n"; continue; }
        [ "$ugw" = "$_ipo" ] && { printf "${RED}Error: GW cannot equal IP${NC}\n"; continue; }
        ip route del default 2>/dev/null
        ip route add default via "$ugw" dev "$1" 2>&1 && printf "${GREEN}GW: %s${NC}\n" "$ugw" || printf "${RED}Error: Failed${NC}\n"
        read -r -p "Press Enter to continue..."; return 0
    done
}

# IPv6
dhcp6_disco() {
    printf "${YELLOW}Flushing v6...${NC}\n"; ip -6 addr flush dev "$1" 2>/dev/null
    printf "${YELLOW}Starting DHCPv6...${NC}\n"
    if command -v dhclient >/dev/null 2>&1; then dhclient -6 "$1" 2>&1; sleep 3
    else printf "${RED}Error: No DHCPv6 client${NC}\n"; return 1; fi
    _ip=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    if [ -n "$_ip" ]; then printf "${GREEN}DHCPv6: %s${NC}\n" "$_ip"; set_dhcp6_marker "$1"; return 0
    else printf "${RED}Error: DHCPv6 failed${NC}\n"; return 1; fi
}

config_ip6() {
    _ip=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    [ "$(get_ip6_type "$1")" = "dhcp" ] && { printf "${RED}Error: Clear DHCPv6 first${NC}\n"; read -r -p "Press Enter to continue..."; return 1; }
    [ -n "$_ip" ] && printf "${YELLOW}Current: %s${NC}\n" "$_ip"
    printf "  ${GREEN}1${NC}) Static\n  ${GREEN}2${NC}) DHCPv6\n  ${GREEN}3${NC}) Cancel\n\n"
    read -r -p "$(print_prompt)" c
    [ "$c" = "q" ] && return 1
    case "$c" in
        3|"") return 1 ;;
        2) dhcp6_disco "$1"; read -r -p "Press Enter to continue..."; return 0 ;;
        1|*) while true; do
            read -r -p "IPv6/mask: " uip; [ -z "$uip" ] && return 1; [ "$uip" = "q" ] && return 1
            echo "$uip" | grep -q '/' || { printf "${RED}Error: Need /mask${NC}\n"; continue; }
            _ic=$(echo "$uip"|cut -d/ -f1); _mc=$(echo "$uip"|cut -d/ -f2)
            [ -z "$_mc" ] || [ "$_mc" = "$_ic" ] && { printf "${RED}Error: Invalid mask${NC}\n"; continue; }
            validate_ip6 "$_ic" || { printf "${RED}Error: Invalid IPv6${NC}\n"; continue; }
            validate_mask6 "$_mc" || { printf "${RED}Error: Mask /1-/128${NC}\n"; continue; }
            [ -n "$_ip" ] && ip -6 addr del "$_ip" dev "$1" 2>/dev/null
            clear_dhcp6_marker "$1"
            ip -6 addr add "$uip" dev "$1" 2>&1 && printf "${GREEN}Set: %s${NC}\n" "$uip" || printf "${RED}Error: Failed${NC}\n"
            read -r -p "Press Enter to continue..."; return 0
        done ;;
    esac
}

config_gw6() {
    _cgw=$(get_gw6 "$1"); _cip=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    [ -z "$_cip" ] && { printf "${RED}Error: Set IPv6 first${NC}\n"; read -r -p "Press Enter to continue..."; return 1; }
    [ "$(get_ip6_type "$1")" = "dhcp" ] && { printf "${RED}Error: DHCPv6 has automatic gateway${NC}\n"; read -r -p "Press Enter to continue..."; return 1; }
    _ipo=$(echo "$_cip"|cut -d/ -f1)
    printf "${WHITE}GWv6 for %s${NC} IP: %s GW: %s\n\n" "$1" "$_cip" "${_cgw:-none}"
    while true; do
        read -r -p "Gateway (Enter=cancel, del=remove, q=quit): " ugw
        [ -z "$ugw" ] && return 1
        [ "$ugw" = "q" ] && return 1
        [ "$ugw" = "del" ] && { [ -n "$_cgw" ] && ip -6 route del default 2>/dev/null && printf "${GREEN}Removed${NC}\n" || printf "${YELLOW}No GW${NC}\n"; read -r -p "Press Enter to continue..."; return 0; }
        validate_ip6 "$ugw" || { printf "${RED}Error: Invalid IPv6${NC}\n"; continue; }
        [ "$ugw" = "$_ipo" ] && { printf "${RED}Error: GW cannot equal IP${NC}\n"; continue; }
        ip -6 route del default 2>/dev/null
        ip -6 route add default via "$ugw" dev "$1" 2>&1 && printf "${GREEN}GWv6: %s${NC}\n" "$ugw" || printf "${RED}Error: Failed${NC}\n"
        read -r -p "Press Enter to continue..."; return 0
    done
}

# PING, QUICK PING, TRACEROUTE
quick_ping_v4() {
    _iface="$1"
    printf "\n${YELLOW}Quick ping IPv4 (5 packets each):${NC}\n\n"
    printf "  Internet (8.8.8.8)... "; ping -c5 -W2 -I "$_iface" 8.8.8.8 >/dev/null 2>&1 && printf "${GREEN}[OK]${NC}\n" || printf "${RED}[FAIL]${NC}\n"
    _gw4=$(get_gw4 "$_iface")
    [ -n "$_gw4" ] && { printf "  Gateway (%s)... " "$_gw4"; ping -c5 -W2 -I "$_iface" "$_gw4" >/dev/null 2>&1 && printf "${GREEN}[OK]${NC}\n" || printf "${RED}[FAIL]${NC}\n"; } || printf "  Gateway: ${YELLOW}skipped${NC}\n"
    printf "  Loopback (127.0.0.1)... "; ping -c5 -W1 127.0.0.1 >/dev/null 2>&1 && printf "${GREEN}[OK]${NC}\n" || printf "${RED}[FAIL]${NC}\n"
}

quick_ping_v6() {
    _iface="$1"
    printf "\n${YELLOW}Quick ping IPv6 (5 packets each):${NC}\n\n"
    printf "  Internet (2001:4860:4860::8888)... "; ping -c5 -W2 -I "$_iface" 2001:4860:4860::8888 >/dev/null 2>&1 && printf "${GREEN}[OK]${NC}\n" || printf "${RED}[FAIL]${NC}\n"
    _gw6=$(get_gw6 "$_iface")
    [ -n "$_gw6" ] && { printf "  Gateway (%s)... " "$_gw6"; ping -c5 -W2 -I "$_iface" "$_gw6" >/dev/null 2>&1 && printf "${GREEN}[OK]${NC}\n" || printf "${RED}[FAIL]${NC}\n"; } || printf "  Gateway: ${YELLOW}skipped${NC}\n"
    printf "  Loopback (::1)... "; ping -c5 -W1 ::1 >/dev/null 2>&1 && printf "${GREEN}[OK]${NC}\n" || printf "${RED}[FAIL]${NC}\n"
}

run_traceroute() {
    printf "${WHITE}Traceroute${NC}\n  ${GREEN}1${NC}) 8.8.8.8\n  ${GREEN}2${NC}) 1.1.1.1\n  ${GREEN}3${NC}) Custom\n  ${GREEN}4${NC}) Back\n\n"
    read -r -p "$(print_prompt)" c; _target=""
    [ "$c" = "q" ] && return
    case "$c" in 1) _target="8.8.8.8" ;; 2) _target="1.1.1.1" ;; 3) read -r -p "Target: " _target; [ -z "$_target" ] && return ;; 4|"") return ;; *) return ;; esac
    printf "\n${CYAN}Traceroute to %s...${NC}\n\n" "$_target"
    if command -v traceroute >/dev/null 2>&1; then traceroute -I "$_target" 2>&1
    elif command -v tracepath >/dev/null 2>&1; then tracepath "$_target" 2>&1
    else for _ttl in $(seq 1 15); do printf "  %2d  " $_ttl; ping -c1 -W1 -t$_ttl "$_target" 2>&1 | awk '/from/ {print $4}' | tr -d ':' | head -1 || echo "*"; done; fi
    echo; read -r -p "Press Enter to continue..."
}

interactive_ping() {
    _iface="$1"
    [ ! -d "/sys/class/net/$_iface" ] && { printf "${RED}Error: %s not found${NC}\n" "$_iface"; read -r -p "Press Enter to continue..."; return 1; }
    while true; do
        print_header; show_iface_config "$_iface"
        printf "${WHITE}Ping via ${GREEN}%s${NC}\n\n" "$_iface"
        printf "  ${GREEN}1${NC}) Custom\n  ${GREEN}2${NC}) Quick ping (IPv4)\n  ${GREEN}3${NC}) Quick ping (IPv6)\n  ${GREEN}4${NC}) Traceroute\n  ${GREEN}5${NC}) Back\n\n"
        read -r -p "$(print_prompt)" c; _target=""
        [ "$c" = "q" ] && return 0
        case "$c" in
            1) read -r -p "Target: " _target; [ -z "$_target" ] && continue
               printf "\n${CYAN}Pinging %s (5)...${NC}\n\n" "$_target"; ping -c5 -W2 -I "$_iface" "$_target" 2>&1
               [ $? -eq 0 ] && printf "\n${GREEN}[OK]${NC}\n" || printf "\n${RED}[FAIL]${NC}\n"; read -r -p "Press Enter to continue..." ;;
            2) quick_ping_v4 "$_iface"; echo; read -r -p "Press Enter to continue..." ;;
            3) quick_ping_v6 "$_iface"; echo; read -r -p "Press Enter to continue..." ;;
            4) run_traceroute "$_iface" ;;
            5|"") return 0 ;;
            *) printf "${RED}Error: Invalid${NC}\n"; sleep 1 ;;
        esac
    done
}

restart_iface() {
    [ ! -d "/sys/class/net/$1" ] && return 1
    printf "${YELLOW}Restarting %s...${NC}\n" "$1"
    _sip4=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    _sip6=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    _sgw4=$(get_gw4 "$1"); _sgw6=$(get_gw6 "$1")
    ip link set "$1" down 2>/dev/null; sleep 1; ip link set "$1" up 2>/dev/null
    [ -n "$_sip4" ] && { sleep 1; ip addr add "$_sip4" dev "$1" 2>/dev/null; }
    [ -n "$_sip6" ] && { sleep 1; ip -6 addr add "$_sip6" dev "$1" 2>/dev/null; }
    [ -n "$_sgw4" ] && { sleep 1; ip route add default via "$_sgw4" dev "$1" 2>/dev/null; }
    [ -n "$_sgw6" ] && { sleep 1; ip -6 route add default via "$_sgw6" dev "$1" 2>/dev/null; }
    printf "${GREEN}Done${NC}\n"
}

restart_network() {
    printf "${YELLOW}Restarting network...${NC}\n\n"
    for _i in $(get_interfaces); do printf "  %-10s " "$_i"; ip link set "$_i" down 2>/dev/null; sleep 0.5; ip link set "$_i" up 2>/dev/null; printf "${GREEN}OK${NC}\n"; done
    printf "\n${GREEN}Done${NC}\n"
}

reset_network() {
    printf "${RED}WARNING: Full reset!${NC}\n\n"; read -r -p "Confirm? (yes/no): " c
    [ "$c" != "yes" ] && [ "$c" != "y" ] && return
    for _i in $(get_interfaces); do ip addr flush dev "$_i" 2>/dev/null; ip -6 addr flush dev "$_i" 2>/dev/null; ip link set "$_i" down 2>/dev/null; sleep 0.5; ip link set "$_i" up 2>/dev/null; done
    ip link set lo down 2>/dev/null; ip link set lo up 2>/dev/null; ip addr add 127.0.0.1/8 dev lo 2>/dev/null; ip -6 addr add ::1/128 dev lo 2>/dev/null
    printf "${GREEN}Reset complete${NC}\n"; SELECTED_INTERFACE=""; read -r -p "Press Enter to continue..."
}

check_dependencies
touch "$LOG_FILE" 2>/dev/null

while true; do
    print_header
    if [ -z "$SELECTED_INTERFACE" ]; then
        show_interfaces || { read -r -p "Press Enter to continue..."; continue; }
        printf "${WHITE}Select interface ${YELLOW}(q=quit)${NC}:\n\n"
        select_iface; SELECTED_INTERFACE=$(get_selected)
        [ "$SELECTED_INTERFACE" = "EXIT" ] || [ -z "$SELECTED_INTERFACE" ] && { printf "${GREEN}Bye${NC}\n\n"; exit 0; }
        continue
    fi

    show_iface_config "$SELECTED_INTERFACE"

    printf "${WHITE}Menu:${NC}\n"
    printf "${CYAN}────────────────────────────────────────${NC}\n"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "1)" "Config IP" "8)" "Restart net"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "2)" "Config GW" "9)" "Restart iface"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "3)" "Switch iface" "10)" "Reset net"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "4)" "Ping/Trace" "11)" "Add static route"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "5)" "Routing" "12)" "Delete route"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "6)" "Clear iface" "13)" "Port check"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "7)" "DNS setup" "14)" "Packages"
    printf "  ${GREEN}%s${NC} %-20s\n" "0)" "Exit"
    printf "${CYAN}────────────────────────────────────────${NC}\n\n"

    read -r -p "$(print_prompt)" ACTION
    [ "$ACTION" = "q" ] && { printf "${GREEN}Bye${NC}\n\n"; exit 0; }

    case "$ACTION" in
        1) printf "  ${GREEN}1${NC}) IPv4\n  ${GREEN}2${NC}) IPv6\n  ${GREEN}3${NC}) Cancel\n\n"
           read -r -p "$(print_prompt)" v; [ "$v" = "q" ] && continue
           case "$v" in 1) config_ip4 "$SELECTED_INTERFACE" ;; 2) config_ip6 "$SELECTED_INTERFACE" ;; esac ;;
        2) printf "  ${GREEN}1${NC}) GWv4\n  ${GREEN}2${NC}) GWv6\n  ${GREEN}3${NC}) Cancel\n\n"
           read -r -p "$(print_prompt)" v; [ "$v" = "q" ] && continue
           case "$v" in 1) config_gw4 "$SELECTED_INTERFACE" ;; 2) config_gw6 "$SELECTED_INTERFACE" ;; esac ;;
        3) SELECTED_INTERFACE="" ;;
        4) interactive_ping "$SELECTED_INTERFACE" ;;
        5) printf "${WHITE}Routes:${NC}\n"; ip route show 2>/dev/null; echo; ip -6 route show 2>/dev/null; echo; read -r -p "Press Enter to continue..." ;;
        6) printf "  ${GREEN}1${NC}) Clear IPs only\n"
           printf "  ${GREEN}2${NC}) Clear IPv4 + default GW + static routes\n"
           printf "  ${GREEN}3${NC}) Clear IPv6 + default GW + static routes\n"
           printf "  ${GREEN}4${NC}) Clear iface (full reset)\n"
           printf "  ${GREEN}5${NC}) Cancel\n\n"
           read -r -p "$(print_prompt)" v; [ "$v" = "q" ] && continue
           case "$v" in
               1) clear_ips_only_menu "$SELECTED_INTERFACE" ;;
               2) clear_ip4_full "$SELECTED_INTERFACE"; printf "${GREEN}IPv4 cleared (IP + GW + routes)${NC}\n"; read -r -p "Press Enter to continue..." ;;
               3) clear_ip6_full "$SELECTED_INTERFACE"; printf "${GREEN}IPv6 cleared (IP + GW + routes)${NC}\n"; read -r -p "Press Enter to continue..." ;;
               4) clear_iface_full "$SELECTED_INTERFACE"; printf "${GREEN}Interface fully cleared${NC}\n"; read -r -p "Press Enter to continue..." ;;
           esac ;;
        7) configure_dns ;;
        8) restart_network; read -r -p "Press Enter to continue..." ;;
        9) restart_iface "$SELECTED_INTERFACE"; read -r -p "Press Enter to continue..." ;;
        10) reset_network ;;
        11) add_static_route "$SELECTED_INTERFACE" ;;
        12) del_route "$SELECTED_INTERFACE" ;;
        13) check_port ;;
        14) install_packages ;;
        0|exit|quit) print_header; printf "${GREEN}Bye${NC}\n\n"; exit 0 ;;
        "") continue ;;
        *) printf "${RED}Error: Invalid option (0-14)${NC}\n"; sleep 1 ;;
    esac
done
