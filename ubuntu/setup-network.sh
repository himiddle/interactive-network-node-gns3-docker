#!/bin/bash

# INTERACTIVE NETWORK NODE v1.0

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
        echo "${NAME:-Unknown} ${VERSION:-}"
    else
        echo "Unknown OS"
    fi
}

check_dependencies() {
    local missing=""
    for cmd in ip hostname awk sed tr wc; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if [ ! -z "$missing" ]; then
        echo -e "${RED}Error: Missing:$missing${NC}"
        exit 1
    fi
}

print_header() {
    clear 2>/dev/null || echo -e "\n\n\n"
    echo -e "${CYAN}═══ INTERACTIVE NETWORK NODE v${VERSION} ═══${NC}"
    echo ""
    echo -e "${WHITE}OS Version:${NC} ${GREEN}$(detect_os)${NC}"
    echo -e "Created by ${MAGENTA}${AUTHOR}${NC}"
    echo ""
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
    local new_ip="$1" current_iface="$2"
    local ip_clean=$(echo "$new_ip" | cut -d/ -f1)
    
    for iface in $(get_interfaces); do
        [ "$iface" = "$current_iface" ] && continue
        local existing=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        [ -z "$existing" ] && continue
        local existing_clean=$(echo "$existing" | cut -d/ -f1)
        if [ "$ip_clean" = "$existing_clean" ]; then
            echo "$iface"
            return 0
        fi
    done
    return 1
}

get_ip4_type() {
    local ip=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    [ -z "$ip" ] && { echo "none"; return; }
    
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
    local ip=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    [ -z "$ip" ] && { echo "none"; return; }
    [ -f "/var/run/dhcp6-$1.marker" ] && { echo "dhcp"; return; }
    echo "static"
}

set_dhcp_marker() { mkdir -p /var/run 2>/dev/null; touch "/var/run/dhcp-${1}.marker" 2>/dev/null; }
clear_dhcp_marker() { rm -f "/var/run/dhcp-${1}.marker" 2>/dev/null; }
set_dhcp6_marker() { mkdir -p /var/run 2>/dev/null; touch "/var/run/dhcp6-${1}.marker" 2>/dev/null; }
clear_dhcp6_marker() { rm -f "/var/run/dhcp6-${1}.marker" 2>/dev/null; }

validate_ip4() {
    local ip="$1"
    case "$ip" in *[!0-9.]*) return 1 ;; esac
    
    local dots=0 tmp="$ip"
    while [ "$tmp" != "${tmp#*.}" ]; do dots=$((dots+1)); tmp="${tmp#*.}"; done
    [ "$dots" -ne 3 ] && return 1
    
    local oldIFS="$IFS"; IFS='.'; set -- $ip; IFS="$oldIFS"
    [ $# -ne 4 ] && return 1
    
    for octet; do
        case "$octet" in ''|*[!0-9]*) return 1 ;; esac
        [ "$octet" -lt 0 ] 2>/dev/null && return 1
        [ "$octet" -gt 255 ] 2>/dev/null && return 1
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
    
    local routes4=$(get_static_routes "$1")
    if [ ! -z "$routes4" ]; then
        echo "$routes4" | while read r; do
            ip route del $(echo "$r" | awk '{print $1}') via $(echo "$r" | awk '{print $3}') dev "$1" 2>/dev/null
        done
    fi
    
    local routes6=$(get_static_routes6 "$1")
    if [ ! -z "$routes6" ]; then
        echo "$routes6" | while read r; do
            ip -6 route del $(echo "$r" | awk '{print $1}') via $(echo "$r" | awk '{print $3}') dev "$1" 2>/dev/null
        done
    fi
    
    ip link set "$1" down 2>/dev/null; sleep 1; ip link set "$1" up 2>/dev/null
}

clear_ip4_full() {
    pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
    clear_dhcp_marker "$1"
    ip addr flush dev "$1" 2>/dev/null
    ip route del default dev "$1" 2>/dev/null
    
    local routes4=$(get_static_routes "$1")
    if [ ! -z "$routes4" ]; then
        echo "$routes4" | while read r; do
            ip route del $(echo "$r" | awk '{print $1}') via $(echo "$r" | awk '{print $3}') dev "$1" 2>/dev/null
        done
    fi
}

clear_ip6_full() {
    clear_dhcp6_marker "$1"
    ip -6 addr flush dev "$1" 2>/dev/null
    ip -6 route del default dev "$1" 2>/dev/null
    
    local routes6=$(get_static_routes6 "$1")
    if [ ! -z "$routes6" ]; then
        echo "$routes6" | while read r; do
            ip -6 route del $(echo "$r" | awk '{print $1}') via $(echo "$r" | awk '{print $3}') dev "$1" 2>/dev/null
        done
    fi
}

clear_ips_only() {
    pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
    clear_dhcp_marker "$1"; clear_dhcp6_marker "$1"
    ip addr flush dev "$1" 2>/dev/null; ip -6 addr flush dev "$1" 2>/dev/null
}

clear_ips_only_menu() {
    echo -e "  ${GREEN}1${NC}) Clear IPv4 only"
    echo -e "  ${GREEN}2${NC}) Clear IPv6 only"
    echo -e "  ${GREEN}3${NC}) Clear both IPv4 and IPv6"
    echo -e "  ${GREEN}4${NC}) Cancel\n"
    read -p "$(print_prompt)" v
    [ "$v" = "q" ] && return
    case "$v" in
        1) pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
           clear_dhcp_marker "$1"; ip addr flush dev "$1" 2>/dev/null
           echo -e "${GREEN}IPv4 cleared${NC}" ;;
        2) clear_dhcp6_marker "$1"; ip -6 addr flush dev "$1" 2>/dev/null
           echo -e "${GREEN}IPv6 cleared${NC}" ;;
        3) pkill -f "dhclient.*$1" 2>/dev/null; pkill -f "udhcpc.*$1" 2>/dev/null
           clear_dhcp_marker "$1"; clear_dhcp6_marker "$1"
           ip addr flush dev "$1" 2>/dev/null; ip -6 addr flush dev "$1" 2>/dev/null
           echo -e "${GREEN}IPs cleared${NC}" ;;
    esac
    read -p "Press Enter to continue..."
}

show_dns() {
    echo -e "${WHITE}DNS:${NC}"
    if [ -f "$RESOLV_CONF" ]; then
        if grep -q "^nameserver" "$RESOLV_CONF" 2>/dev/null; then
            grep "^nameserver" "$RESOLV_CONF" 2>/dev/null | while read l; do echo -e "  ${GREEN}$l${NC}"; done
        else echo -e "  ${YELLOW}none${NC}"; fi
    else echo -e "  ${RED}Error: no resolv.conf${NC}"; fi
    echo
}

configure_dns() {
    show_dns
    echo -e "${WHITE}DNS:${NC}"
    echo -e "  ${GREEN}1${NC}) Add DNS\n  ${GREEN}2${NC}) Remove DNS\n  ${GREEN}3${NC}) Set primary DNS\n  ${GREEN}4${NC}) Clear all DNS\n  ${GREEN}5${NC}) Cancel\n"
    read -p "$(print_prompt)" c
    [ "$c" = "q" ] && return
    case "$c" in
        1) read -p "IP: " ip; validate_ip4 "$ip" || validate_ip6 "$ip" || { echo -e "${RED}Error: Invalid IP${NC}"; read -p "Press Enter to continue..."; return; }
           grep -q "^nameserver $ip" "$RESOLV_CONF" 2>/dev/null && echo -e "${YELLOW}Exists${NC}" || { echo "nameserver $ip" >> "$RESOLV_CONF"; echo -e "${GREEN}Added${NC}"; }; read -p "Press Enter to continue..." ;;
        2) read -p "IP: " ip; grep -q "^nameserver $ip" "$RESOLV_CONF" 2>/dev/null && { sed -i "/^nameserver $ip/d" "$RESOLV_CONF" 2>/dev/null; echo -e "${GREEN}Removed${NC}"; } || echo -e "${YELLOW}Not found${NC}"; read -p "Press Enter to continue..." ;;
        3) read -p "IP: " ip; validate_ip4 "$ip" || validate_ip6 "$ip" || { echo -e "${RED}Error: Invalid IP${NC}"; read -p "Press Enter to continue..."; return; }
           grep -v "^nameserver" "$RESOLV_CONF" 2>/dev/null > "${RESOLV_CONF}.tmp"; echo "nameserver $ip" >> "${RESOLV_CONF}.tmp"; mv "${RESOLV_CONF}.tmp" "$RESOLV_CONF" 2>/dev/null; echo -e "${GREEN}Set${NC}"; read -p "Press Enter to continue..." ;;
        4) [ -f "$RESOLV_CONF" ] && { cp "$RESOLV_CONF" "${RESOLV_CONF}.backup" 2>/dev/null; sed -i '/^nameserver/d' "$RESOLV_CONF" 2>/dev/null; echo -e "${GREEN}Cleared${NC}"; }; read -p "Press Enter to continue..." ;;
        5|"") return ;;
        *) echo -e "${RED}Error: Invalid option${NC}"; sleep 1 ;;
    esac
}

show_interfaces() {
    local ifaces=$(get_interfaces)
    [ -z "$ifaces" ] && { echo -e "${RED}Error: No interfaces${NC}"; return 1; }
    printf "${WHITE}%-8s %-20s %-26s %-8s %s${NC}\n" "Iface" "IPv4" "IPv6" "Status" "Method"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────${NC}"
    for i in $ifaces; do
        local ip4=$(ip -4 addr show dev "$i" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        local ip6=$(ip -6 addr show dev "$i" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
        local t4=$(get_ip4_type "$i"); local t6=$(get_ip6_type "$i")
        local m="-"
        if [ "$t4" = "dhcp" ] || [ "$t6" = "dhcp" ]; then m="D"
        elif [ "$t4" = "static" ] || [ "$t6" = "static" ]; then m="S"
        else m="N"; fi
        local s=$(ip link show "$i" 2>/dev/null | awk '/state/ {print $9}'); [ -z "$s" ] && s="DOWN"
        printf "%-8s " "$i"
        [ -z "$ip4" ] && printf "${RED}%-20s${NC} " "none" || printf "${GREEN}%-20s${NC} " "$ip4"
        [ -z "$ip6" ] && printf "${RED}%-26s${NC} " "none" || printf "${GREEN}%-26s${NC} " "$ip6"
        printf "%-8s " "$s"
        case "$m" in D) echo -e "${YELLOW}[D]${NC}" ;; S) echo -e "${YELLOW}[S]${NC}" ;; *) echo -e "${GRAY}[N]${NC}" ;; esac
    done
    echo
}

select_iface() {
    local ifaces=$(get_interfaces)
    [ -z "$ifaces" ] && { echo -e "${RED}Error: No interfaces${NC}"; return 1; }
    echo -e "${WHITE}Available:${NC}"
    local n=1
    for i in $ifaces; do printf "  ${GREEN}%d${NC}) %s\n" "$n" "$i"; n=$((n+1)); done
    echo
    while true; do
        read -p "$(print_prompt)" c
        [ "$c" = "q" ] && { echo "EXIT" > "$TEMP_FILE"; return 0; }
        case "$c" in ''|*[!0-9]*) echo -e "${RED}Error: 1-$((n-1)) or q${NC}"; continue ;; esac
        local count=1
        for i in $ifaces; do [ $count -eq $c ] && { echo "$i" > "$TEMP_FILE"; return 0; }; count=$((count+1)); done
        echo -e "${RED}Error: 1-$((n-1)) or q${NC}"
    done
}

get_selected() { [ -f "$TEMP_FILE" ] && cat "$TEMP_FILE"; }

show_iface_config() {
    local iface="$1"
    [ -z "$iface" ] && { echo -e "${RED}Error: No interface${NC}"; return 1; }
    [ ! -d "/sys/class/net/$iface" ] && { echo -e "${RED}Error: $iface not found${NC}"; return 1; }
    
    local ip4=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    local ip6=$(ip -6 addr show dev "$iface" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    local t4=$(get_ip4_type "$iface"); local t6=$(get_ip6_type "$iface")
    local mac=$(ip link show "$iface" 2>/dev/null | awk '/link\/ether/ {print $2}')
    
    [ -z "$ip4" ] && ip4="none"; [ -z "$ip6" ] && ip6="none"; [ -z "$mac" ] && mac="unknown"
    
    local m4="N"; [ "$t4" = "dhcp" ] && m4="D"; [ "$t4" = "static" ] && m4="S"
    local m6="N"; [ "$t6" = "dhcp" ] && m6="D"; [ "$t6" = "static" ] && m6="S"
    local c4="$GRAY"; [ "$m4" = "D" ] && c4="$YELLOW"; [ "$m4" = "S" ] && c4="$YELLOW"
    local c6="$GRAY"; [ "$m6" = "D" ] && c6="$YELLOW"; [ "$m6" = "S" ] && c6="$YELLOW"
    
    local def_gw4=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    local def_gw4_dev=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    local def_gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
    local def_gw6_dev=$(ip -6 route show default 2>/dev/null | awk '{print $5}' | head -1)
    
    echo -e "${CYAN}═══ ${GREEN}$iface${CYAN} ═══${NC}"
    printf "  ${WHITE}MAC:${NC} ${WHITE}%s${NC}\n" "$mac"
    
    printf "  ${WHITE}IPv4:${NC} "; [ "$ip4" = "none" ] && printf "${RED}%-24s${NC}" "$ip4" || printf "${GREEN}%-24s${NC}" "$ip4"
    printf "${c4}[${m4}]${NC}\n"
    
    printf "  ${WHITE}IPv6:${NC} "; [ "$ip6" = "none" ] && printf "${RED}%-24s${NC}" "$ip6" || printf "${GREEN}%-24s${NC}" "$ip6"
    printf "${c6}[${m6}]${NC}\n"
    
    if [ ! -z "$def_gw4" ]; then
        printf "  ${WHITE}Default GWv4:${NC} ${MAGENTA}%s dev %s${NC}\n" "$def_gw4" "$def_gw4_dev"
    else
        printf "  ${WHITE}Default GWv4:${NC} ${RED}none${NC}\n"
    fi
    
    if [ ! -z "$def_gw6" ]; then
        printf "  ${WHITE}Default GWv6:${NC} ${MAGENTA}%s dev %s${NC}\n" "$def_gw6" "$def_gw6_dev"
    else
        printf "  ${WHITE}Default GWv6:${NC} ${RED}none${NC}\n"
    fi
    
    local routes4=$(get_static_routes "$iface")
    if [ ! -z "$routes4" ]; then
        echo "$routes4" | while read r; do echo -e "  ${WHITE}Route:${NC} ${GREEN}$r${NC}"; done
    fi
    
    local routes6=$(get_static_routes6 "$iface")
    if [ ! -z "$routes6" ]; then
        echo "$routes6" | while read r; do echo -e "  ${WHITE}Route6:${NC} ${GREEN}$r${NC}"; done
    fi
    echo
}

# DELETE ROUTE
del_route() {
    local iface="$1"
    echo -e "${WHITE}Delete route from ${GREEN}$iface${NC}"
    echo -e "  ${GREEN}1${NC}) Delete default gateway\n  ${GREEN}2${NC}) Delete static route\n  ${GREEN}3${NC}) Cancel\n"
    read -p "$(print_prompt)" type
    [ "$type" = "q" ] && return
    case "$type" in
        3|"") return ;;
        1) echo -e "  ${GREEN}1${NC}) Default GWv4\n  ${GREEN}2${NC}) Default GWv6\n  ${GREEN}3${NC}) Cancel\n"
           read -p "$(print_prompt)" ver; [ "$ver" = "q" ] && return
           case "$ver" in 1) ip route del default 2>/dev/null; echo -e "${GREEN}Removed${NC}" ;; 2) ip -6 route del default 2>/dev/null; echo -e "${GREEN}Removed${NC}" ;; esac
           read -p "Press Enter to continue..." ;;
        2) echo -e "  ${GREEN}1${NC}) IPv4\n  ${GREEN}2${NC}) IPv6\n  ${GREEN}3${NC}) Cancel\n"
           read -p "$(print_prompt)" ver; [ "$ver" = "q" ] && return
           case "$ver" in
               1) local r4=$(get_static_routes "$iface")
                  [ -z "$r4" ] && { echo -e "${YELLOW}None${NC}"; read -p "Press Enter to continue..."; return; }
                  echo "$r4" | cat -n; read -p "Number: " n; [ "$n" = "q" ] && return
                  case "$n" in ''|*[!0-9]*) ;; *) local rt=$(echo "$r4" | sed -n "${n}p")
                      [ ! -z "$rt" ] && { ip route del $(echo "$rt" | awk '{print $1}') via $(echo "$rt" | awk '{print $3}') dev "$iface" 2>/dev/null; echo -e "${GREEN}Removed: $rt${NC}"; } ;; esac
                  read -p "Press Enter to continue..." ;;
               2) local r6=$(get_static_routes6 "$iface")
                  [ -z "$r6" ] && { echo -e "${YELLOW}None${NC}"; read -p "Press Enter to continue..."; return; }
                  echo "$r6" | cat -n; read -p "Number: " n; [ "$n" = "q" ] && return
                  case "$n" in ''|*[!0-9]*) ;; *) local rt=$(echo "$r6" | sed -n "${n}p")
                      [ ! -z "$rt" ] && { ip -6 route del $(echo "$rt" | awk '{print $1}') via $(echo "$rt" | awk '{print $3}') dev "$iface" 2>/dev/null; echo -e "${GREEN}Removed: $rt${NC}"; } ;; esac
                  read -p "Press Enter to continue..." ;;
           esac ;;
    esac
}

# ADD STATIC ROUTE
add_static_route() {
    local iface="$1"
    
    echo -e "\n${WHITE}Current routes on ${GREEN}$iface${NC}:"
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    
    local def_gw4=$(ip route show default 2>/dev/null | awk '{print "IPv4: via "$3" dev "$5}' | head -1)
    local def_gw6=$(ip -6 route show default 2>/dev/null | awk '{print "IPv6: via "$3" dev "$5}' | head -1)
    echo -e "${WHITE}Default GW:${NC}"
    [ ! -z "$def_gw4" ] && echo -e "  ${MAGENTA}$def_gw4${NC}" || echo -e "  ${RED}IPv4: none${NC}"
    [ ! -z "$def_gw6" ] && echo -e "  ${MAGENTA}$def_gw6${NC}" || echo -e "  ${RED}IPv6: none${NC}"
    
    echo -e "\n${WHITE}Static routes on $iface:${NC}"
    local routes4=$(get_static_routes "$iface")
    local routes6=$(get_static_routes6 "$iface")
    [ ! -z "$routes4" ] && echo "$routes4" | while read r; do echo -e "  ${GREEN}$r${NC}"; done || echo -e "  ${RED}IPv4: none${NC}"
    [ ! -z "$routes6" ] && echo "$routes6" | while read r; do echo -e "  ${GREEN}$r${NC}"; done || echo -e "  ${RED}IPv6: none${NC}"
    
    local iface_net=$(ip -4 route show dev "$iface" 2>/dev/null | grep "proto kernel" | awk '{print $1}' | head -1)
    [ ! -z "$iface_net" ] && echo -e "\n${WHITE}Interface subnet:${NC} ${GREEN}$iface_net${NC} ${YELLOW}(directly connected)${NC}"
    
    echo -e "${CYAN}────────────────────────────────────────${NC}\n"
    
    echo -e "${WHITE}Add static route for ${GREEN}$iface${NC}"
    echo -e "  ${GREEN}1${NC}) IPv4\n  ${GREEN}2${NC}) IPv6\n  ${GREEN}3${NC}) Cancel\n"
    read -p "$(print_prompt)" ver
    [ "$ver" = "q" ] && return
    case "$ver" in
        3|"") return ;;
        1) while true; do
            read -p "Subnet (e.g. 192.168.100.0/24): " s; [ -z "$s" ] && return; [ "$s" = "q" ] && return
            echo "$s" | grep -q '/' || { echo -e "${RED}Error: Need /mask${NC}"; continue; }
            local net=$(echo "$s"|cut -d/ -f1) mask=$(echo "$s"|cut -d/ -f2)
            [ -z "$mask" ] || [ "$mask" = "$net" ] && { echo -e "${RED}Error: Invalid mask${NC}"; continue; }
            validate_ip4 "$net" || { echo -e "${RED}Error: Invalid network${NC}"; continue; }
            validate_mask4 "$mask" || { echo -e "${RED}Error: Mask /1-/32${NC}"; continue; }
            [ "$s" = "$iface_net" ] && { echo -e "${YELLOW}Own subnet${NC}"; read -p "Press Enter to continue..."; return; }
            read -p "Gateway: " gw; [ -z "$gw" ] && return; [ "$gw" = "q" ] && return
            validate_ip4 "$gw" || { echo -e "${RED}Error: Invalid gateway${NC}"; continue; }
            ip route show "$s" 2>/dev/null | grep -q "via $gw" && { echo -e "${YELLOW}Exists${NC}"; read -p "Press Enter to continue..."; return; }
            ip route add "$s" via "$gw" dev "$iface" 2>&1 && echo -e "${GREEN}Added: $s via $gw${NC}" || echo -e "${RED}Error: Failed${NC}"
            read -p "Press Enter to continue..."; return
        done ;;
        2) while true; do
            read -p "Subnet (e.g. 2001:db8:100::/48): " s; [ -z "$s" ] && return; [ "$s" = "q" ] && return
            echo "$s" | grep -q '/' || { echo -e "${RED}Error: Need /mask${NC}"; continue; }
            local net=$(echo "$s"|cut -d/ -f1) mask=$(echo "$s"|cut -d/ -f2)
            [ -z "$mask" ] || [ "$mask" = "$net" ] && { echo -e "${RED}Error: Invalid mask${NC}"; continue; }
            validate_ip6 "$net" || { echo -e "${RED}Error: Invalid IPv6${NC}"; continue; }
            validate_mask6 "$mask" || { echo -e "${RED}Error: Mask /1-/128${NC}"; continue; }
            read -p "Gateway: " gw; [ -z "$gw" ] && return; [ "$gw" = "q" ] && return
            validate_ip6 "$gw" || { echo -e "${RED}Error: Invalid gateway${NC}"; continue; }
            ip -6 route show "$s" 2>/dev/null | grep -q "via $gw" && { echo -e "${YELLOW}Exists${NC}"; read -p "Press Enter to continue..."; return; }
            ip -6 route add "$s" via "$gw" dev "$iface" 2>&1 && echo -e "${GREEN}Added: $s via $gw${NC}" || echo -e "${RED}Error: Failed${NC}"
            read -p "Press Enter to continue..."; return
        done ;;
    esac
}

# PORT CHECK
check_port() {
    while true; do
        print_header; show_iface_config "$SELECTED_INTERFACE"
        echo -e "${WHITE}Port Check${NC}\n"
        echo -e "  ${GREEN}1${NC}) Single port\n  ${GREEN}2${NC}) Port range\n  ${GREEN}3${NC}) Common ports\n  ${GREEN}4${NC}) Back\n"
        read -p "$(print_prompt)" type
        [ "$type" = "q" ] && return
        local target="" ports=""
        
        case "$type" in
            4|"") return ;;
            1) read -p "Target: " target; [ -z "$target" ] && continue; [ "$target" = "q" ] && continue
               read -p "Port: " port; [ "$port" = "q" ] && continue
               if ! validate_port "$port"; then
                   echo -e "${RED}Error: Invalid port (1-65535)${NC}"
                   read -p "Press Enter to continue..."
                   continue
               fi
               ports="$port" ;;
            2) read -p "Target: " target; [ -z "$target" ] && continue; [ "$target" = "q" ] && continue
               read -p "Start: " sp; read -p "End: " ep; [ "$sp" = "q" ] || [ "$ep" = "q" ] && continue
               if ! validate_port "$sp" || ! validate_port "$ep"; then
                   echo -e "${RED}Error: Invalid port range${NC}"
                   read -p "Press Enter to continue..."
                   continue
               fi
               if [ "$sp" -gt "$ep" ]; then
                   echo -e "${RED}Error: Start > End${NC}"
                   read -p "Press Enter to continue..."
                   continue
               fi
               ports=$(seq $sp $ep 2>/dev/null) ;;
            3) read -p "Target: " target; [ -z "$target" ] && continue; [ "$target" = "q" ] && continue
               ports="22 80 443 8080 8443" ;;
            *) echo -e "${RED}Error: Invalid option${NC}"; sleep 1; continue ;;
        esac
        
        echo -e "\n${CYAN}Scanning $target...${NC}\n"
        printf "${WHITE}%-8s %-12s %s${NC}\n" "Port" "State" "Service"
        echo -e "${CYAN}────────────────────────────${NC}"
        local open=0 closed=0
        
        for port in $ports; do
            printf "  %-6s " "$port"
            local result=1
            if command -v nc >/dev/null 2>&1; then
                timeout 3 nc -z "$target" "$port" 2>/dev/null && result=0
            else
                timeout 3 bash -c "echo >/dev/tcp/$target/$port" 2>/dev/null && result=0
            fi
            
            if [ $result -eq 0 ]; then
                local svc="?"
                case "$port" in 22) svc="SSH" ;; 80) svc="HTTP" ;; 443) svc="HTTPS" ;; 8080) svc="HTTP-Alt" ;; 8443) svc="HTTPS-Alt" ;; esac
                echo -e "${GREEN}open${NC}      $svc"
                open=$((open+1))
            else
                echo -e "${RED}closed${NC}"
                closed=$((closed+1))
            fi
        done
        echo -e "${CYAN}────────────────────────────${NC}"
        echo -e "${WHITE}Open:${NC} ${GREEN}$open${NC} ${WHITE}Closed:${NC} ${RED}$closed${NC}\n"
        read -p "Press Enter to continue..."
    done
}

# PACKAGES
detect_pkg() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v apk >/dev/null 2>&1; then echo "apk"
    else echo "unknown"
    fi
}

install_packages() {
    local pkg=$(detect_pkg)
    [ "$pkg" = "unknown" ] && { echo -e "${RED}Error: No package manager${NC}"; read -p "Press Enter to continue..."; return 1; }
    
    while true; do
        print_header; show_iface_config "$SELECTED_INTERFACE"
        echo -e "${WHITE}Package Manager: ${GREEN}$pkg${NC}\n"
        echo -e "  ${GREEN}1${NC}) Update + install\n  ${GREEN}2${NC}) Install only\n  ${GREEN}3${NC}) Full upgrade\n  ${GREEN}4${NC}) Back\n"
        read -p "$(print_prompt)" c
        [ "$c" = "q" ] && return
        
        case "$c" in
            1) read -p "Package(s): " pkgs; [ -z "$pkgs" ] && continue; [ "$pkgs" = "q" ] && continue
               case "$pkg" in
                   apt) apt-get update && apt-get install -y $pkgs && echo -e "${GREEN}[OK] Installed: $pkgs${NC}" || echo -e "${RED}[FAIL]${NC}" ;;
                   apk) apk update && apk add $pkgs && echo -e "${GREEN}[OK] Installed: $pkgs${NC}" || echo -e "${RED}[FAIL]${NC}" ;;
               esac
               read -p "Press Enter to continue..." ;;
            2) read -p "Package(s): " pkgs; [ -z "$pkgs" ] && continue; [ "$pkgs" = "q" ] && continue
               case "$pkg" in
                   apt) apt-get install -y $pkgs && echo -e "${GREEN}[OK] Installed: $pkgs${NC}" || echo -e "${RED}[FAIL]${NC}" ;;
                   apk) apk add $pkgs && echo -e "${GREEN}[OK] Installed: $pkgs${NC}" || echo -e "${RED}[FAIL]${NC}" ;;
               esac
               read -p "Press Enter to continue..." ;;
            3) case "$pkg" in
                   apt) apt-get update && apt-get upgrade -y && echo -e "${GREEN}[OK] Upgraded${NC}" || echo -e "${RED}[FAIL]${NC}" ;;
                   apk) apk update && apk upgrade && echo -e "${GREEN}[OK] Upgraded${NC}" || echo -e "${RED}[FAIL]${NC}" ;;
               esac
               read -p "Press Enter to continue..." ;;
            4|"") return ;;
            *) echo -e "${RED}Error: Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# IPv4
dhcp4_disco() {
    echo -e "${YELLOW}Flushing $1...${NC}"; ip addr flush dev "$1" 2>/dev/null
    echo -e "${YELLOW}Starting DHCPv4...${NC}"
    if command -v dhclient >/dev/null 2>&1; then dhclient "$1" 2>&1; sleep 2
    elif command -v udhcpc >/dev/null 2>&1; then udhcpc -i "$1" -n -q 2>&1; sleep 2
    else echo -e "${RED}Error: No DHCP client${NC}"; return 1; fi
    local ip=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    if [ ! -z "$ip" ]; then
        echo -e "${GREEN}DHCPv4: $ip${NC}"; set_dhcp_marker "$1"
        local gw=$(get_gw4 "$1"); [ ! -z "$gw" ] && echo -e "${GREEN}GW: $gw${NC}"
        grep -q "^nameserver" "$RESOLV_CONF" 2>/dev/null || { echo "nameserver 8.8.8.8" >> "$RESOLV_CONF"; echo "nameserver 8.8.4.4" >> "$RESOLV_CONF"; }
        return 0
    else echo -e "${RED}Error: DHCPv4 failed${NC}"; return 1; fi
}

config_ip4() {
    local ip=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    local current_type=$(get_ip4_type "$1")
    
    if [ "$current_type" = "dhcp" ]; then
        echo -e "${YELLOW}Interface is configured via DHCP${NC}"
        [ ! -z "$ip" ] && echo -e "${YELLOW}Current IP: $ip${NC}"
        echo -e "  ${GREEN}1${NC}) Clear DHCP and set static"
        echo -e "  ${GREEN}2${NC}) Renew DHCP"
        echo -e "  ${GREEN}3${NC}) Cancel\n"
        read -p "$(print_prompt)" cc
        [ "$cc" = "q" ] && return 1
        case "$cc" in
            1) 
                pkill -f "dhclient.*$1" 2>/dev/null
                pkill -f "udhcpc.*$1" 2>/dev/null
                clear_dhcp_marker "$1"
                ip addr flush dev "$1" 2>/dev/null
                ip link set "$1" up 2>/dev/null
                echo -e "${GREEN}DHCP cleared, now set static IP${NC}"
                ip=""
                ;;
            2) dhcp4_disco "$1"; read -p "Press Enter to continue..."; return 0 ;;
            3|"") return 1 ;;
            *) echo -e "${RED}Error: Invalid option${NC}"; read -p "Press Enter to continue..."; return 1 ;;
        esac
    fi
    
    [ ! -z "$ip" ] && [ "$current_type" != "dhcp" ] && echo -e "${YELLOW}Current: $ip${NC}"
    [ "$current_type" != "dhcp" ] && {
        echo -e "  ${GREEN}1${NC}) Static\n  ${GREEN}2${NC}) DHCP\n  ${GREEN}3${NC}) Cancel\n"
        read -p "$(print_prompt)" c
        [ "$c" = "q" ] && return 1
        case "$c" in
            3|"") return 1 ;;
            2) dhcp4_disco "$1"; read -p "Press Enter to continue..."; return 0 ;;
        esac
    }
    
    while true; do
        read -p "IPv4/mask: " uip; [ -z "$uip" ] && return 1; [ "$uip" = "q" ] && return 1
        echo "$uip" | grep -q '/' || { echo -e "${RED}Error: Need /mask${NC}"; continue; }
        local ic=$(echo "$uip"|cut -d/ -f1) mc=$(echo "$uip"|cut -d/ -f2)
        [ -z "$mc" ] || [ "$mc" = "$ic" ] && { echo -e "${RED}Error: Invalid mask${NC}"; continue; }
        validate_ip4 "$ic" || { echo -e "${RED}Error: Invalid IPv4${NC}"; continue; }
        validate_mask4 "$mc" || { echo -e "${RED}Error: Mask /1-/32${NC}"; continue; }
        local dup=$(check_duplicate_ip "$uip" "$1")
        [ ! -z "$dup" ] && { echo -e "${RED}Error: IP $ic already used on $dup${NC}"; read -p "Press Enter to continue..."; continue; }
        
        [ ! -z "$ip" ] && ip addr del "$ip" dev "$1" 2>/dev/null
        pkill -f "dhclient.*$1" 2>/dev/null
        pkill -f "udhcpc.*$1" 2>/dev/null
        clear_dhcp_marker "$1"
        
        ip addr add "$uip" dev "$1" 2>&1 && echo -e "${GREEN}Set: $uip${NC}" || echo -e "${RED}Error: Failed${NC}"
        read -p "Press Enter to continue..."; return 0
    done
}

config_gw4() {
    local cgw=$(get_gw4 "$1") cip=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    [ -z "$cip" ] && { echo -e "${RED}Error: Set IPv4 first${NC}"; read -p "Press Enter to continue..."; return 1; }
    [ "$(get_ip4_type "$1")" = "dhcp" ] && { echo -e "${RED}Error: DHCP has automatic gateway${NC}"; read -p "Press Enter to continue..."; return 1; }
    local existing_gw=$(get_existing_gateway_info "$1")
    [ ! -z "$existing_gw" ] && echo -e "${RED}Gateway already on: $existing_gw${NC}\n${YELLOW}New will REPLACE!${NC}"
    local ipo=$(echo "$cip"|cut -d/ -f1)
    echo -e "${WHITE}GW for $1${NC} IP: $cip GW: ${cgw:-none}\n"
    while true; do
        read -p "Gateway (Enter=cancel, del=remove, q=quit): " ugw
        [ -z "$ugw" ] && return 1
        [ "$ugw" = "q" ] && return 1
        [ "$ugw" = "del" ] && { [ ! -z "$cgw" ] && ip route del default 2>/dev/null && echo -e "${GREEN}Removed${NC}" || echo -e "${YELLOW}No GW${NC}"; read -p "Press Enter to continue..."; return 0; }
        validate_ip4 "$ugw" || { echo -e "${RED}Error: Invalid IPv4${NC}"; continue; }
        [ "$ugw" = "$ipo" ] && { echo -e "${RED}Error: GW cannot equal IP${NC}"; continue; }
        ip route del default 2>/dev/null
        ip route add default via "$ugw" dev "$1" 2>&1 && echo -e "${GREEN}GW: $ugw${NC}" || echo -e "${RED}Error: Failed${NC}"
        read -p "Press Enter to continue..."; return 0
    done
}

# IPv6
dhcp6_disco() {
    echo -e "${YELLOW}Flushing v6...${NC}"; ip -6 addr flush dev "$1" 2>/dev/null
    echo -e "${YELLOW}Starting DHCPv6...${NC}"
    if command -v dhclient >/dev/null 2>&1; then dhclient -6 "$1" 2>&1; sleep 3
    else echo -e "${RED}Error: No DHCPv6 client${NC}"; return 1; fi
    local ip=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    if [ ! -z "$ip" ]; then echo -e "${GREEN}DHCPv6: $ip${NC}"; set_dhcp6_marker "$1"; return 0
    else echo -e "${RED}Error: DHCPv6 failed${NC}"; return 1; fi
}

config_ip6() {
    local ip=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    [ "$(get_ip6_type "$1")" = "dhcp" ] && { echo -e "${RED}Error: Clear DHCPv6 first${NC}"; read -p "Press Enter to continue..."; return 1; }
    [ ! -z "$ip" ] && echo -e "${YELLOW}Current: $ip${NC}"
    echo -e "  ${GREEN}1${NC}) Static\n  ${GREEN}2${NC}) DHCPv6\n  ${GREEN}3${NC}) Cancel\n"
    read -p "$(print_prompt)" c
    [ "$c" = "q" ] && return 1
    case "$c" in
        3|"") return 1 ;;
        2) dhcp6_disco "$1"; read -p "Press Enter to continue..."; return 0 ;;
        1|*) while true; do
            read -p "IPv6/mask: " uip; [ -z "$uip" ] && return 1; [ "$uip" = "q" ] && return 1
            echo "$uip" | grep -q '/' || { echo -e "${RED}Error: Need /mask${NC}"; continue; }
            local ic=$(echo "$uip"|cut -d/ -f1) mc=$(echo "$uip"|cut -d/ -f2)
            [ -z "$mc" ] || [ "$mc" = "$ic" ] && { echo -e "${RED}Error: Invalid mask${NC}"; continue; }
            validate_ip6 "$ic" || { echo -e "${RED}Error: Invalid IPv6${NC}"; continue; }
            validate_mask6 "$mc" || { echo -e "${RED}Error: Mask /1-/128${NC}"; continue; }
            [ ! -z "$ip" ] && ip -6 addr del "$ip" dev "$1" 2>/dev/null
            clear_dhcp6_marker "$1"
            ip -6 addr add "$uip" dev "$1" 2>&1 && echo -e "${GREEN}Set: $uip${NC}" || echo -e "${RED}Error: Failed${NC}"
            read -p "Press Enter to continue..."; return 0
        done ;;
    esac
}

config_gw6() {
    local cgw=$(get_gw6 "$1") cip=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    [ -z "$cip" ] && { echo -e "${RED}Error: Set IPv6 first${NC}"; read -p "Press Enter to continue..."; return 1; }
    [ "$(get_ip6_type "$1")" = "dhcp" ] && { echo -e "${RED}Error: DHCPv6 has automatic gateway${NC}"; read -p "Press Enter to continue..."; return 1; }
    local ipo=$(echo "$cip"|cut -d/ -f1)
    echo -e "${WHITE}GWv6 for $1${NC} IP: $cip GW: ${cgw:-none}\n"
    while true; do
        read -p "Gateway (Enter=cancel, del=remove, q=quit): " ugw
        [ -z "$ugw" ] && return 1
        [ "$ugw" = "q" ] && return 1
        [ "$ugw" = "del" ] && { [ ! -z "$cgw" ] && ip -6 route del default 2>/dev/null && echo -e "${GREEN}Removed${NC}" || echo -e "${YELLOW}No GW${NC}"; read -p "Press Enter to continue..."; return 0; }
        validate_ip6 "$ugw" || { echo -e "${RED}Error: Invalid IPv6${NC}"; continue; }
        [ "$ugw" = "$ipo" ] && { echo -e "${RED}Error: GW cannot equal IP${NC}"; continue; }
        ip -6 route del default 2>/dev/null
        ip -6 route add default via "$ugw" dev "$1" 2>&1 && echo -e "${GREEN}GWv6: $ugw${NC}" || echo -e "${RED}Error: Failed${NC}"
        read -p "Press Enter to continue..."; return 0
    done
}

# PING, QUICK PING, TRACEROUTE
quick_ping_v4() {
    local iface="$1"
    echo -e "\n${YELLOW}Quick ping IPv4 (5 packets each):${NC}\n"
    printf "  Internet (8.8.8.8)... "; ping -c5 -W2 -I "$iface" 8.8.8.8 >/dev/null 2>&1 && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[FAIL]${NC}"
    local gw4=$(get_gw4 "$iface")
    [ ! -z "$gw4" ] && { printf "  Gateway ($gw4)... "; ping -c5 -W2 -I "$iface" "$gw4" >/dev/null 2>&1 && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[FAIL]${NC}"; } || echo -e "  Gateway: ${YELLOW}skipped${NC}"
    printf "  Loopback (127.0.0.1)... "; ping -c5 -W1 127.0.0.1 >/dev/null 2>&1 && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[FAIL]${NC}"
}

quick_ping_v6() {
    local iface="$1"
    echo -e "\n${YELLOW}Quick ping IPv6 (5 packets each):${NC}\n"
    printf "  Internet (2001:4860:4860::8888)... "; ping -c5 -W2 -I "$iface" 2001:4860:4860::8888 >/dev/null 2>&1 && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[FAIL]${NC}"
    local gw6=$(get_gw6 "$iface")
    [ ! -z "$gw6" ] && { printf "  Gateway ($gw6)... "; ping -c5 -W2 -I "$iface" "$gw6" >/dev/null 2>&1 && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[FAIL]${NC}"; } || echo -e "  Gateway: ${YELLOW}skipped${NC}"
    printf "  Loopback (::1)... "; ping -c5 -W1 ::1 >/dev/null 2>&1 && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[FAIL]${NC}"
}

run_traceroute() {
    echo -e "${WHITE}Traceroute${NC}\n  ${GREEN}1${NC}) 8.8.8.8\n  ${GREEN}2${NC}) 1.1.1.1\n  ${GREEN}3${NC}) Custom\n  ${GREEN}4${NC}) Back\n"
    read -p "$(print_prompt)" c; local target=""
    [ "$c" = "q" ] && return
    case "$c" in 1) target="8.8.8.8" ;; 2) target="1.1.1.1" ;; 3) read -p "Target: " target; [ -z "$target" ] && return ;; 4|"") return ;; *) return ;; esac
    echo -e "\n${CYAN}Traceroute to $target...${NC}\n"
    if command -v traceroute >/dev/null 2>&1; then traceroute -I "$target" 2>&1
    elif command -v tracepath >/dev/null 2>&1; then tracepath "$target" 2>&1
    else for ttl in $(seq 1 15); do printf "  %2d  " $ttl; ping -c1 -W1 -t$ttl "$target" 2>&1 | awk '/from/ {print $4}' | tr -d ':' | head -1 || echo "*"; done; fi
    echo; read -p "Press Enter to continue..."
}

interactive_ping() {
    local iface="$1"
    [ ! -d "/sys/class/net/$iface" ] && { echo -e "${RED}Error: $iface not found${NC}"; read -p "Press Enter to continue..."; return 1; }
    while true; do
        print_header; show_iface_config "$iface"
        echo -e "${WHITE}Ping via ${GREEN}$iface${NC}\n"
        echo -e "  ${GREEN}1${NC}) Custom\n  ${GREEN}2${NC}) Quick ping (IPv4)\n  ${GREEN}3${NC}) Quick ping (IPv6)\n  ${GREEN}4${NC}) Traceroute\n  ${GREEN}5${NC}) Back\n"
        read -p "$(print_prompt)" c; local target=""
        [ "$c" = "q" ] && return 0
        case "$c" in
            1) read -p "Target: " target; [ -z "$target" ] && continue
               echo -e "\n${CYAN}Pinging $target (5)...${NC}\n"; ping -c5 -W2 -I "$iface" "$target" 2>&1
               [ $? -eq 0 ] && echo -e "\n${GREEN}[OK]${NC}" || echo -e "\n${RED}[FAIL]${NC}"; read -p "Press Enter to continue..." ;;
            2) quick_ping_v4 "$iface"; echo; read -p "Press Enter to continue..." ;;
            3) quick_ping_v6 "$iface"; echo; read -p "Press Enter to continue..." ;;
            4) run_traceroute "$iface" ;;
            5|"") return 0 ;;
            *) echo -e "${RED}Error: Invalid${NC}"; sleep 1 ;;
        esac
    done
}

restart_iface() {
    [ ! -d "/sys/class/net/$1" ] && return 1
    echo -e "${YELLOW}Restarting $1...${NC}"
    local sip4=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / {print $2}' | head -1)
    local sip6=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | head -1)
    local sgw4=$(get_gw4 "$1"); local sgw6=$(get_gw6 "$1")
    ip link set "$1" down 2>/dev/null; sleep 1; ip link set "$1" up 2>/dev/null
    [ ! -z "$sip4" ] && { sleep 1; ip addr add "$sip4" dev "$1" 2>/dev/null; }
    [ ! -z "$sip6" ] && { sleep 1; ip -6 addr add "$sip6" dev "$1" 2>/dev/null; }
    [ ! -z "$sgw4" ] && { sleep 1; ip route add default via "$sgw4" dev "$1" 2>/dev/null; }
    [ ! -z "$sgw6" ] && { sleep 1; ip -6 route add default via "$sgw6" dev "$1" 2>/dev/null; }
    echo -e "${GREEN}Done${NC}"
}

restart_network() {
    echo -e "${YELLOW}Restarting network...${NC}\n"
    for i in $(get_interfaces); do printf "  %-10s " "$i"; ip link set "$i" down 2>/dev/null; sleep 0.5; ip link set "$i" up 2>/dev/null; echo -e "${GREEN}OK${NC}"; done
    echo -e "\n${GREEN}Done${NC}"
}

reset_network() {
    echo -e "${RED}WARNING: Full reset!${NC}\n"; read -p "Confirm? (yes/no): " c
    [ "$c" != "yes" ] && [ "$c" != "y" ] && return
    for i in $(get_interfaces); do ip addr flush dev "$i" 2>/dev/null; ip -6 addr flush dev "$i" 2>/dev/null; ip link set "$i" down 2>/dev/null; sleep 0.5; ip link set "$i" up 2>/dev/null; done
    ip link set lo down 2>/dev/null; ip link set lo up 2>/dev/null; ip addr add 127.0.0.1/8 dev lo 2>/dev/null; ip -6 addr add ::1/128 dev lo 2>/dev/null
    echo -e "${GREEN}Reset complete${NC}"; SELECTED_INTERFACE=""; read -p "Press Enter to continue..."
}

check_dependencies
touch "$LOG_FILE" 2>/dev/null

while true; do
    print_header
    if [ -z "$SELECTED_INTERFACE" ]; then
        show_interfaces || { read -p "Press Enter to continue..."; continue; }
        echo -e "${WHITE}Select interface ${YELLOW}(q=quit)${NC}:\n"
        select_iface; SELECTED_INTERFACE=$(get_selected)
        [ "$SELECTED_INTERFACE" = "EXIT" ] || [ -z "$SELECTED_INTERFACE" ] && { echo -e "${GREEN}Bye${NC}\n"; exit 0; }
        continue
    fi
    
    show_iface_config "$SELECTED_INTERFACE"
    
    echo -e "${WHITE}Menu:${NC}"
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "1)" "Config IP" "8)" "Restart net"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "2)" "Config GW" "9)" "Restart iface"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "3)" "Switch iface" "10)" "Reset net"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "4)" "Ping/Trace" "11)" "Add static route"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "5)" "Routing" "12)" "Delete route"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "6)" "Clear iface" "13)" "Port check"
    printf "  ${GREEN}%s${NC} %-20s ${GREEN}%s${NC} %-20s\n" "7)" "DNS setup" "14)" "Packages"
    printf "  ${GREEN}%s${NC} %-20s\n" "0)" "Exit"
    echo -e "${CYAN}────────────────────────────────────────${NC}\n"
    
    read -p "$(print_prompt)" ACTION
    [ "$ACTION" = "q" ] && { echo -e "${GREEN}Bye${NC}\n"; exit 0; }
    
    case "$ACTION" in
        1) echo -e "  ${GREEN}1${NC}) IPv4\n  ${GREEN}2${NC}) IPv6\n  ${GREEN}3${NC}) Cancel\n"
           read -p "$(print_prompt)" v; [ "$v" = "q" ] && continue
           case "$v" in 1) config_ip4 "$SELECTED_INTERFACE" ;; 2) config_ip6 "$SELECTED_INTERFACE" ;; esac ;;
        2) echo -e "  ${GREEN}1${NC}) GWv4\n  ${GREEN}2${NC}) GWv6\n  ${GREEN}3${NC}) Cancel\n"
           read -p "$(print_prompt)" v; [ "$v" = "q" ] && continue
           case "$v" in 1) config_gw4 "$SELECTED_INTERFACE" ;; 2) config_gw6 "$SELECTED_INTERFACE" ;; esac ;;
        3) SELECTED_INTERFACE="" ;;
        4) interactive_ping "$SELECTED_INTERFACE" ;;
        5) echo -e "${WHITE}Routes:${NC}"; ip route show 2>/dev/null; echo; ip -6 route show 2>/dev/null; echo; read -p "Press Enter to continue..." ;;
        6) echo -e "  ${GREEN}1${NC}) Clear IPs only"
           echo -e "  ${GREEN}2${NC}) Clear IPv4 + default GW + static routes"
           echo -e "  ${GREEN}3${NC}) Clear IPv6 + default GW + static routes"
           echo -e "  ${GREEN}4${NC}) Clear iface (full reset)"
           echo -e "  ${GREEN}5${NC}) Cancel\n"
           read -p "$(print_prompt)" v; [ "$v" = "q" ] && continue
           case "$v" in
               1) clear_ips_only_menu "$SELECTED_INTERFACE" ;;
               2) clear_ip4_full "$SELECTED_INTERFACE"; echo -e "${GREEN}IPv4 cleared (IP + GW + routes)${NC}"; read -p "Press Enter to continue..." ;;
               3) clear_ip6_full "$SELECTED_INTERFACE"; echo -e "${GREEN}IPv6 cleared (IP + GW + routes)${NC}"; read -p "Press Enter to continue..." ;;
               4) clear_iface_full "$SELECTED_INTERFACE"; echo -e "${GREEN}Interface fully cleared${NC}"; read -p "Press Enter to continue..." ;;
           esac ;;
        7) configure_dns ;;
        8) restart_network; read -p "Press Enter to continue..." ;;
        9) restart_iface "$SELECTED_INTERFACE"; read -p "Press Enter to continue..." ;;
        10) reset_network ;;
        11) add_static_route "$SELECTED_INTERFACE" ;;
        12) del_route "$SELECTED_INTERFACE" ;;
        13) check_port ;;
        14) install_packages ;;
        0|exit|quit) print_header; echo -e "${GREEN}Bye${NC}\n"; exit 0 ;;
        "") continue ;;
        *) echo -e "${RED}Error: Invalid option (0-14)${NC}"; sleep 1 ;;
    esac
done
