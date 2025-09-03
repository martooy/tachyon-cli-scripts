#!/usr/bin/env bash
# tachyon-info-dump.sh — Simple, reliable info/benchmark dump for Particle Tachyon (QCM6490)
# For requirements, run:  ./tachyon-info-dump.sh --requires [all|minimal]

set -o nounset
set -o pipefail

############################
# Config (env-overridable) #
############################
BENCH_SIZE_MB="${BENCH_SIZE_MB:-256}"
BENCH_RUNTIME="${BENCH_RUNTIME:-30}"
RESULTS_ROOT="${RESULTS_ROOT:-/root/tachyon_info_dumps}"
APT_INSTALL="${APT_INSTALL:-yes}"
SYSCON_DUMP_LINES="${SYSCON_DUMP_LINES:-200}"
WIFI_SCAN_TIMEOUT="${WIFI_SCAN_TIMEOUT:-25}"

################
# CLI / Help   #
################
show_help() {
  cat <<'EOF'
Usage: sudo TESTNOTES="notes" ./tachyon-info-dump.sh [OPTIONS]

Options:
  --disk,  -d             Include disk benchmarks (hdparm, fio). Default: off.
  --quick, -q             Skip logs and package/service inventories.
  --no-syscon             Skip SysCon snapshots.
  --noconsole             Plain text console (no ANSI).
  --outputallthethings    Stream EVERYTHING to STDOUT; write NO files.
  --nowritefilesystem     Write NO files; STDOUT only. (Implies --noconsole.)
  --name "TEXT"           Set TESTNOTES from CLI (overrides env).
  --requires [all|minimal]  Print apt-get install line, then exit.
  --help,  -h             This help.

Env you can override:
  TESTNOTES, BENCH_SIZE_MB, BENCH_RUNTIME, RESULTS_ROOT, APT_INSTALL,
  SYSCON_DUMP_LINES, WIFI_SCAN_TIMEOUT
EOF
}

print_requires() {
  case "${1:-all}" in
    all)     echo 'sudo apt-get update && sudo apt-get install -y util-linux iproute2 systemd usbutils pciutils lshw dmidecode ethtool iw network-manager inxi neofetch nftables iptables sysbench hdparm fio' ;;
    minimal) echo 'sudo apt-get update && sudo apt-get install -y util-linux iproute2 usbutils pciutils lshw dmidecode ethtool iw network-manager' ;;
    *)       echo 'sudo apt-get update && sudo apt-get install -y util-linux iproute2 systemd usbutils pciutils lshw dmidecode ethtool iw network-manager inxi neofetch nftables iptables sysbench hdparm fio' ;;
  esac
}

##############
# CLI parsing
##############
DISK_TESTS=0
QUICK_MODE=0
DO_SYSCON=1
NO_CONSOLE=0
OUTPUT_ALL=0
NOWRITE_FS=0
CLI_TESTNOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk|-d)             DISK_TESTS=1; shift ;;
    --quick|-q)            QUICK_MODE=1; shift ;;
    --no-syscon)           DO_SYSCON=0; shift ;;
    --noconsole)           NO_CONSOLE=1; shift ;;
    --outputallthethings)  OUTPUT_ALL=1; NO_CONSOLE=1; NOWRITE_FS=1; shift ;;
    --nowritefilesystem)   NOWRITE_FS=1; NO_CONSOLE=1; shift ;;
    --name)                CLI_TESTNOTES="${2-}"; shift 2 ;;
    --name=*)              CLI_TESTNOTES="${1#*=}"; shift ;;
    --requires)            print_requires "${2:-all}"; exit 0 ;;
    --requires=*)          print_requires "${1#*=}"; exit 0 ;;
    --help|-h)             show_help; exit 0 ;;
    --)                    shift; break ;;
    -*)                    echo "Unknown option: $1" >&2; echo "Try --help" >&2; exit 1 ;;
    *) break ;;
  esac
done

#############
# Root req. #
#############
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

##########################
# Console styling toggles
##########################
if [[ -t 1 && "$NO_CONSOLE" -eq 0 ]]; then
  C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
  C_FG_TITLE=$'\e[38;5;39m'; C_FG_OK=$'\e[38;5;76m'; C_FG_WARN=$'\e[38;5;214m'
  C_FG_STEP=$'\e[38;5;45m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_FG_TITLE=""; C_FG_OK=""; C_FG_WARN=""; C_FG_STEP=""
fi
ICON_START="🚀"; ICON_DONE="✅"; ICON_BULLET="•"

hr() { echo "${C_DIM}------------------------------------------------------------${C_RESET}"; }
title() { echo "${C_FG_TITLE}${C_BOLD}${ICON_BULLET} ${1-}${C_RESET}"; }
stage_banner() { echo "${C_FG_STEP}${C_BOLD}${ICON_START} ${1-}${C_RESET}"; }
stage_done() { echo "${C_FG_OK}${C_BOLD}${ICON_DONE} ${1-} (done)${C_RESET}"; }
stage_note() { echo "${C_DIM}${1-}${C_RESET}"; }

#####################
# Paths & bookkeeping
#####################
START_TS="$(date -u +'%Y-%m-%dT%H-%M-%SZ')"
HOST="$(hostname -f 2>/dev/null || hostname)"
TESTNOTES_VAL="${CLI_TESTNOTES:-${TESTNOTES-}}"; [[ -n "${TESTNOTES_VAL:-}" ]] || TESTNOTES_VAL="(unset)"

NO_FILES=$(( OUTPUT_ALL == 1 || NOWRITE_FS == 1 ? 1 : 0 ))

OUTDIR=""; DIR_SYS=""; DIR_HW=""; DIR_STORAGE=""; DIR_NET=""; DIR_USBPCI=""; DIR_PKGSVC=""; DIR_LOGS=""; DIR_BENCH=""
ERRORS_FILE=""; RUN_LOG=""; SUMMARY_FILE=""

if [[ "$NO_FILES" -eq 0 ]]; then
  OUTDIR="$RESULTS_ROOT/${START_TS}_${HOST}"
  mkdir -p "$OUTDIR"
  DIR_SYS="$OUTDIR/1_system"; DIR_HW="$OUTDIR/2_hardware"; DIR_STORAGE="$OUTDIR/3_storage"
  DIR_NET="$OUTDIR/4_network"; DIR_USBPCI="$OUTDIR/5_usb_pci_modem"
  DIR_PKGSVC="$OUTDIR/6_packages_services"; DIR_LOGS="$OUTDIR/7_logs"; DIR_BENCH="$OUTDIR/8_benchmarks"
  mkdir -p "$DIR_SYS" "$DIR_HW" "$DIR_STORAGE" "$DIR_NET" "$DIR_USBPCI" "$DIR_PKGSVC" "$DIR_LOGS" "$DIR_BENCH"
  ERRORS_FILE="$OUTDIR/_errors.log"; RUN_LOG="$OUTDIR/_run.log"; SUMMARY_FILE="$OUTDIR/_summary.txt"
  : > "$ERRORS_FILE"; : > "$RUN_LOG"
fi

###############
# Time helpers
###############
ts_ms() { date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"; }
now_ms() { date +%s%3N; }

#####################################
# Exec wrapper (headers, timing)
#####################################
run_and_log() {
  local outfile="${1-}"; shift
  local cmd_str="$*"
  local header
  header=$(
    printf '%s\n' \
      "===== TACHYON INFO DUMP =====" \
      "Timestamp (UTC): $START_TS" \
      "Host: $HOST" \
      "TESTNOTES: $TESTNOTES_VAL" \
      "Command: $cmd_str" \
      "========================================"
  )
  if [[ "$NO_FILES" -eq 0 && -n "${outfile:-}" ]]; then echo "$header" >"$outfile"; fi
  if [[ "$OUTPUT_ALL" -eq 1 || "$NO_FILES" -eq 1 ]]; then echo "$header"; fi

  local start_iso; start_iso="$(ts_ms)"
  local start_ms; start_ms="$(now_ms)"

  if [[ "$NO_FILES" -eq 0 ]]; then
    echo "[$start_iso] START cmd=\"$cmd_str\" outfile=\"$outfile\"" >>"$RUN_LOG"
    bash -lc "$cmd_str" >>"$outfile" 2>&1
    local ec=$?
    local end_ms; end_ms="$(now_ms)"; local dur_ms=$(( end_ms - start_ms ))
    echo "[$(ts_ms)] END   cmd=\"$cmd_str\" status=$ec duration_ms=$dur_ms" >>"$RUN_LOG"
    if [[ $ec -ne 0 ]]; then
      {
        echo "[$(ts_ms)] ERROR: exit $ec"
        echo "Command: $cmd_str"
        echo "See output file: $outfile"
        echo "----"
      } >>"$ERRORS_FILE"
    fi
    return "$ec"
  else
    bash -lc "$cmd_str"
    local ec=$?
    local end_ms; end_ms="$(now_ms)"; local dur_ms=$(( end_ms - start_ms ))
    echo "[$(ts_ms)] END   cmd=\"$cmd_str\" status=$ec duration_ms=$dur_ms"
    return "$ec"
  fi
}

############################################
# Stage helpers
############################################
stage_begin() {
  local name="${1-}"
  stage_banner "$name"
  echo "[$(ts_ms)] STAGE BEGIN name=\"$name\""
  stage_note "$(date -u +"%Y-%m-%d %H:%M:%SZ") • Working..."
}
stage_end() {
  local name="${1-}"
  stage_done "$name"
  echo "[$(ts_ms)] STAGE END   name=\"$name\""
  hr
}
stage_skip() {
  local why="${1- skipped}"
  echo "⚠️  $why"
  echo "[$(ts_ms)] STAGE SKIP reason=\"$why\""
  hr
}

################################
# Utility: scale micro-units
################################
scale_micro_to_unit() {
  local v="${1-}"
  case "$v" in
    ''|*[!0-9]*) echo "n/a" ;;
    *) echo $((v/1000000)).$(printf '%06d' $((v%1000000))) ;;
  esac
}

##############################
# Section: System identifiers
##############################
collect_system_core() {
  stage_begin "System & Identifiers"
  run_and_log "${DIR_SYS:+$DIR_SYS/os-release.txt}" "cat /etc/os-release"
  run_and_log "${DIR_SYS:+$DIR_SYS/uname.txt}" "uname -a"
  run_and_log "${DIR_SYS:+$DIR_SYS/machine-id.txt}" "cat /etc/machine-id"
  run_and_log "${DIR_SYS:+$DIR_SYS/boot-cmdline.txt}" "cat /proc/cmdline"
  run_and_log "${DIR_SYS:+$DIR_SYS/identifiers_simple.txt}" "ip -o link show"
  stage_end "System & Identifiers"
}

#################################
# Section: Power / Battery / USB-C
#################################
collect_battery_power() {
  stage_begin "Power / Battery / USB-C"
  run_and_log "${DIR_SYS:+$DIR_SYS/battery_power_status.txt}" <<'BASH'
bat="/sys/class/power_supply/battery"
usb="/sys/class/power_supply/usb"
read_sys(){ [ -r "$1" ] && cat "$1" || echo "n/a"; }
to_units(){ v="$1"; case "$v" in (""|*[!0-9]*) echo "n/a";; (*) echo $((v/1000000)).$(printf "%06d" $((v%1000000)));; esac; }
cap=$(read_sys "$bat/capacity")
stat=$(read_sys "$bat/status")
curr_uA=$(read_sys "$bat/current_now")
volt_uV=$(read_sys "$bat/voltage_now")
usb_online=$(read_sys "$usb/online")
curr_A=$(to_units "$curr_uA")
volt_V=$(to_units "$volt_uV")
echo "Battery capacity: $cap %"
echo "Status: $stat"
echo "Current: $curr_uA uA ($curr_A A)"
echo "Voltage: $volt_uV uV ($volt_V V)"
echo "USB online: $usb_online"
BASH
  stage_end "Power / Battery / USB-C"
}

#############################
# Section: SysCon (minimal placeholder)
#############################
collect_syscon() {
  if [[ "$DO_SYSCON" -ne 1 ]]; then stage_skip "SysCon snapshot skipped (--no-syscon)"; return; fi
  stage_begin "SysCon Snapshot"
  run_and_log "${DIR_SYS:+$DIR_SYS/syscon_config.txt}" "echo 'SysCon snapshot placeholder — customize for your board if needed'"
  stage_end "SysCon Snapshot"
}

#############################
# Section: Hardware overview
#############################
collect_hardware() {
  stage_begin "Hardware Inventory"
  run_and_log "${DIR_HW:+$DIR_HW/lscpu.txt}" "lscpu"
  run_and_log "${DIR_HW:+$DIR_HW/cpuinfo.txt}" "cat /proc/cpuinfo"
  run_and_log "${DIR_HW:+$DIR_HW/meminfo.txt}" "cat /proc/meminfo"
  run_and_log "${DIR_HW:+$DIR_HW/lshw-short.txt}" "lshw -short 2>/dev/null || true"
  run_and_log "${DIR_HW:+$DIR_HW/lshw-full.txt}" "lshw 2>/dev/null || true"
  stage_end "Hardware Inventory"
}

#############################
# Section: Storage overview
#############################
collect_storage() {
  stage_begin "Storage Layout & IDs"
  run_and_log "${DIR_STORAGE:+$DIR_STORAGE/lsblk.txt}" "lsblk -O"
  run_and_log "${DIR_STORAGE:+$DIR_STORAGE/blkid.txt}" "blkid"
  run_and_log "${DIR_STORAGE:+$DIR_STORAGE/fdisk.txt}" "fdisk -l || true"
  run_and_log "${DIR_STORAGE:+$DIR_STORAGE/df.txt}" "df -hT"
  run_and_log "${DIR_STORAGE:+$DIR_STORAGE/mounts.txt}" "mount"
  stage_end "Storage Layout & IDs"
}

############################################
# Section: Cellular (Tachyon RIL controller)
############################################
collect_cellular_tachyon() {
  stage_begin "Cellular (Tachyon RIL)"
  run_and_log "${DIR_USBPCI:+$DIR_USBPCI/rild_status.txt}" "systemctl status particle-tachyon-rild 2>/dev/null || true"
  run_and_log "${DIR_USBPCI:+$DIR_USBPCI/modem_state.txt}" "particle-tachyon-ril-ctl state 2>/dev/null || echo 'particle-tachyon-ril-ctl not available'"
  run_and_log "${DIR_USBPCI:+$DIR_USBPCI/modem_status.txt}" "particle-tachyon-ril-ctl status 2>/dev/null || true"
  run_and_log "${DIR_USBPCI:+$DIR_USBPCI/modem_vitals.txt}" "particle-tachyon-ril-ctl vitals 2>/dev/null || true"
  stage_end "Cellular (Tachyon RIL)"
}

#################################
# Section: USB / PCI inventories
#################################
collect_usb_pci() {
  stage_begin "USB / PCI Inventories"
  run_and_log "${DIR_USBPCI:+$DIR_USBPCI/lsusb.txt}" "lsusb 2>/dev/null || true"
  run_and_log "${DIR_USBPCI:+$DIR_USBPCI/usb-devices.txt}" "usb-devices 2>/dev/null || true"
  run_and_log "${DIR_USBPCI:+$DIR_USBPCI/lspci.txt}" "lspci -nnvv 2>/dev/null || true"
  stage_end "USB / PCI Inventories"
}

########################
# Section: Network core
########################
collect_network_core() {
  stage_begin "Network (Core Config)"
  run_and_log "${DIR_NET:+$DIR_NET/ip_a.txt}" "ip a"
  run_and_log "${DIR_NET:+$DIR_NET/route.txt}" "ip route"
  run_and_log "${DIR_NET:+$DIR_NET/resolvers.txt}" "resolvectl status 2>/dev/null || cat /etc/resolv.conf 2>/dev/null || true"
  run_and_log "${DIR_NET:+$DIR_NET/ss.txt}" "ss -tunap 2>/dev/null || true"
  stage_end "Network (Core Config)"
}

##########################################
# Section: Wi-Fi / Wired (nounset-safe)
##########################################
collect_network_wifi_and_usb_eth() {
  stage_begin "Wi-Fi / Wired (Dump Only)"

  # Basic capability dumps
  run_and_log "${DIR_NET:+$DIR_NET/iw_dev.txt}"  "iw dev 2>/dev/null || echo 'iw not available'"
  run_and_log "${DIR_NET:+$DIR_NET/iw_list.txt}" "iw list 2>/dev/null || true"

  # Per-interface link/info (nounset-safe)
  run_and_log "${DIR_NET:+$DIR_NET/iw_links.txt}" <<'BASH'
if command -v iw >/dev/null 2>&1; then
  iw dev 2>/dev/null | awk '/Interface/ {print $2}' | \
  while IFS= read -r ifc || [ -n "${ifc-}" ]; do
    [ -n "${ifc-}" ] || continue
    echo "--- ${ifc-} ---"
    iw dev "${ifc-}" info  2>/dev/null || true
    iw dev "${ifc-}" link  2>/dev/null || true
    echo
  done
else
  echo "iw not available"
fi
BASH

  # Best-effort scan per interface (nounset-safe)
  run_and_log "${DIR_NET:+$DIR_NET/iw_scan.txt}" <<'BASH'
if command -v iw >/dev/null 2>&1; then
  iw dev 2>/dev/null | awk '/Interface/ {print $2}' | \
  while IFS= read -r ifc || [ -n "${ifc-}" ]; do
    [ -n "${ifc-}" ] || continue
    echo ">>> scan on ${ifc-}"
    if ip link show "${ifc-}" | grep -q 'state UP'; then
      iw dev "${ifc-}" scan 2>/dev/null | sed 's/^\t/  /' || echo "(scan failed)"
    else
      echo "(down; skipping)"
    fi
  done
else
  echo "iw not available"
fi
BASH

  # USB/wired NIC dump (no risky parsing)
  run_and_log "${DIR_NET:+$DIR_NET/usb_eth_dump.txt}" <<'BASH'
for n in /sys/class/net/*; do
  [ -d "$n" ] || continue
  nic="$(basename "$n")"
  echo "=== $nic ==="
  if command -v ethtool >/dev/null 2>&1; then ethtool -P "$nic" 2>/dev/null || true; fi
  if command -v nmcli   >/dev/null 2>&1; then nmcli -f GENERAL,IP4,IP6 dev show "$nic" 2>/dev/null || true; fi
  echo
done
BASH

  stage_end "Wi-Fi / Wired (Dump Only)"
}

#############################
# Section: Packages/Services
#############################
collect_packages_services() {
  if [[ $QUICK_MODE -ne 0 ]]; then stage_skip "Packages/Services (--quick)"; return; fi
  stage_begin "Packages & Services"
  run_and_log "${DIR_PKGSVC:+$DIR_PKGSVC/dpkg_list.txt}" "dpkg -l"
  run_and_log "${DIR_PKGSVC:+$DIR_PKGSVC/enabled_services.txt}" "systemctl list-unit-files --type=service | grep enabled 2>/dev/null || true"
  run_and_log "${DIR_PKGSVC:+$DIR_PKGSVC/running_services.txt}" "systemctl --no-pager --type=service --state=running 2>/dev/null || true"
  stage_end "Packages & Services"
}

################
# Section: Logs
################
collect_logs() {
  if [[ $QUICK_MODE -ne 0 ]]; then stage_skip "Logs (--quick)"; return; fi
  stage_begin "Logs"
  run_and_log "${DIR_LOGS:+$DIR_LOGS/dmesg.txt}" "dmesg -T 2>/dev/null || dmesg || true"
  run_and_log "${DIR_LOGS:+$DIR_LOGS/journal_boot.txt}" "journalctl -b --no-pager 2>/dev/null || true"
  stage_end "Logs"
}

###################
# Section: Benchmarks
###################
collect_benchmarks() {
  stage_begin "Benchmarks"
  run_and_log "${DIR_BENCH:+$DIR_BENCH/sysbench_cpu.txt}" "sysbench cpu --threads=\$(nproc) --cpu-max-prime=20000 run 2>/dev/null || true"
  run_and_log "${DIR_BENCH:+$DIR_BENCH/sysbench_mem.txt}" "sysbench memory --threads=\$(nproc) --time=$BENCH_RUNTIME run 2>/dev/null || true"
  if [[ "$DISK_TESTS" -eq 1 ]]; then
    run_and_log "${DIR_BENCH:+$DIR_BENCH/hdparm.txt}" "hdparm -Tt /dev/mmcblk0 2>/dev/null || true"
    run_and_log "${DIR_BENCH:+$DIR_BENCH/fio.txt}" "
for mp in \$(lsblk -rno MOUNTPOINT,TYPE | sed -n 's/^[^ ]\\+ \\+part \\+\\(\\/[^ ]\\+\\).*$/\\1/p'); do
  [ -w \"\$mp\" ] || continue
  testfile=\"\$mp/.fio_testfile\"
  echo \"=== mountpoint: \$mp ===\"
  fio --name=randrw --filename=\"\$testfile\" --rw=randrw --bs=64k --iodepth=16 \
      --size=${BENCH_SIZE_MB}M --numjobs=2 --time_based --runtime=$BENCH_RUNTIME \
      --group_reporting --direct=1 --ioengine=libaio 2>&1
  rm -f \"\$testfile\" || true
done"
  fi
  stage_end "Benchmarks"
}

#########################
# Orchestrate all stages
#########################
TOTAL_START_MS="$(now_ms)"

title "Tachyon Info Dump — $(date -u +"%Y-%m-%d %H:%M:%SZ") (UTC)"; hr

collect_system_core
collect_battery_power
collect_syscon
collect_hardware
collect_storage
collect_cellular_tachyon
collect_usb_pci
collect_network_core
collect_network_wifi_and_usb_eth
collect_packages_services
collect_logs
collect_benchmarks

TOTAL_END_MS="$(now_ms)"; TOTAL_DUR_MS=$(( TOTAL_END_MS - TOTAL_START_MS ))

if [[ "$NO_FILES" -eq 0 ]]; then
  {
    echo
    echo "✅ Tachyon info dump complete."
    echo "Results directory: $OUTDIR"
    echo "Disk benchmarks: $([[ "$DISK_TESTS" -eq 1 ]] && echo ENABLED || echo DISABLED)"
    echo "Quick mode:      $([[ "$QUICK_MODE" -eq 1 ]] && echo ENABLED || echo DISABLED)"
    echo "SysCon snapshot: $([[ "$DO_SYSCON" -eq 1 ]] && echo ENABLED || echo DISABLED)"
    echo "Total runtime:   ${TOTAL_DUR_MS} ms"
    [[ -n "${ERRORS_FILE:-}" && -s "$ERRORS_FILE" ]] && echo "Errors logged:   $ERRORS_FILE" || echo "No errors recorded."
    [[ -n "${RUN_LOG:-}"     && -s "$RUN_LOG"     ]] && echo "Exec timings:    $RUN_LOG"
  } | tee "$SUMMARY_FILE"
else
  echo "[$(ts_ms)] TOTAL duration_ms=$TOTAL_DUR_MS disk_tests=$DISK_TESTS quick_mode=$QUICK_MODE syscon=$DO_SYSCON"
  echo
  echo "✅ Tachyon info dump complete (NO FILES MODE)."
fi

