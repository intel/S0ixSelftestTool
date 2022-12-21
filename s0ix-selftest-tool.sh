#!/bin/bash

# SPDX-License-Identifier: GPL-2.0-only
# This is a CPU Package C-state and S0ix failure selftest and debug script, it's
# designed for Linux OS running on Intel® Architecture-based client platforms.
# Aims to get the potential Package C-state or S0ix blocker clue in an easy way.
# Helps Linux users save the basic isolation effort to focus on the advanced debug
# or report a bug with the initial debug log attached.

# Copyright (c) 2021 Intel Corporation.
# Author: wendy.wang@intel.com
# Contributor: david.e.box@intel.com

PATH=$PATH:$HOME
DATE=$(date '+%Y%m%d-%H-%M')
DIR="$(pwd -P)"
TURBO_COLUMNS="CPU%c1,CPU%c6,CPU%c7,GFX%rc6,Pkg%pc2,Pkg%pc3,Pkg%pc6,Pkg%pc7,Pkg%pc8,Pkg%pc9,Pk%pc10,SYS%LPI"
DEEP="S0i2.0"
SHALLOW="c10"
PMC_CORE_SYSFS_PATH="/sys/kernel/debug/pmc_core"
PCIEPORT_D0=""
PCIEPORT_D3HOT=""
PCIEPORT_L0=""
ASPM_ENABLE=""
KERNEL_VER="$(uname -a)"
#Define which debug stage should go
DEBUG=""
touch "$PWD"/"$DATE"-s0ix-output.log

#Function to archive S0ix debug output
log_output() {
  echo -e "${*}" | tee -a "$PWD"/"$DATE"-s0ix-output.log
}

#Define script must be run as root account
if [[ $EUID -ne 0 ]]; then
  log_output "\nThis script must be run as root.\n" >&2
  exit 0
fi

usage() {
  cat <<EOF
  Usage: ./${0##*/} [-s|h][-r on][-r off]
  -r: Check PC10 residency during runtime with screen on or screen off
  -s: Check S0ix residency during S2idle
  -h: Display help
EOF
}

runtime=0
s2idle=0

#Promote the usage info when there is no option placed
if [[ $# -lt 1 ]]; then
  usage && exit 1
fi

while getopts r:sh opt; do
  case $opt in
  r)
    runtime=$OPTARG
    ;;
  s)
    s2idle=1
    ;;
  h)
    usage && exit 1
    ;;
  *)
    echo "Invalid option argument." && usage && exit 1
    ;;
  esac
done

#Function to check whether slp_s0 is supported on the test platform
slp_s0_support() {
  local lp=""

  acpidump 1>/dev/null 2>&1 || {
    log_output "The acpidump tool is needed to check whether low idle S0 \
    \ncapability is enabled on the test platform, please install acpica-tools \
    \nor check if the acpidump command execution failed.\n"
    exit 0
  }
  acpidump -b 2>&1
  iasl -d ./facp.dat 1>/dev/null 2>&1
  sleep 2
  lp=$(grep "Low Power S0 Idle" facp.dsl 2>&1 | awk '{print $(NF)}')

  if [[ "$lp" -eq 1 ]]; then
    log_output "\nLow Power S0 Idle is:$lp"
    log_output "Your system supports low power S0 idle capability."
    return 0
  else
    log_output "\nLow Power S0 Idle is:$lp"
    log_output "Your system does not support low power S0 idle capability. \
    \nIsolation suggestion: \
    \nPlease check BIOS low power S0 idle capability setting.\n"
    return 1
  fi
}

#Judge whether intel_pmc_core sysfs debug files available
pmc_core_check() {
  if [[ "$(ls -A $PMC_CORE_SYSFS_PATH)" ]]; then
    log_output "\nThe pmc_core debug sysfs files are OK on your system."
    return 0
  else
    log_output "\nThe pmc_core debug sysfs file is empty on your system."
    log_output "Isolation suggestions: \
    \nPlease check whether intel_pmc_core driver is loaded.\n"
    return 1
  fi
}

pci_d3_status_check() {
  local duration=10
  local d3_log=""
  local pcieport_ds=""
  local pci_tree=""
  pci_tree=$(lspci -tvv)
  #Prepare for the PCI Device D3 states check
  echo -n "file pci-driver.c +p" >/sys/kernel/debug/dynamic_debug/control
  echo N >/sys/module/printk/parameters/console_suspend
  echo 1 >/sys/power/pm_debug_messages
  dmesg -C

  echo 0 >/sys/class/rtc/rtc0/wakealarm
  echo +$duration >/sys/class/rtc/rtc0/wakealarm

  "$DIR"/turbostat --quiet -o tc.out echo freeze 2>&1 >/sys/power/state
  sleep 2
  d3_log=$(dmesg | grep "PCI PM" 2>&1)

  if [[ -n "$d3_log" ]]; then
    log_output "\nChecking PCI Devices D3 States:\n$d3_log\n"
    log_output "\nChecking PCI Devices tree diagram:\n$pci_tree\n"
  fi
  #Filter out the pcieport devices D states
  pcieport_ds=$(echo "$d3_log" | grep -o "pcieport.*")
  if [[ -n "$pcieport_ds" ]]; then
    PCIEPORT_D0=$(echo "$pcieport_ds" | grep D0 |
      awk -F " " '{print $2}' | sed 's/:$//')
    PCIEPORT_D3HOT=$(echo "$pcieport_ds" | grep D3hot |
      awk -F " " '{print $2}' | sed 's/:$//')
    #Check the ASPM enable status for the D0 state pcieroot port
    if [[ -n "$PCIEPORT_D0" ]]; then
      for PCIEPORT in $PCIEPORT_D0; do
        ASPM_ENABLE=$(lspci -vvv -s"$PCIEPORT" | grep "LnkCtl:" | grep Enabled)
        log_output "The pcieport $PCIEPORT ASPM enable status:\n$ASPM_ENABLE\n"

        log_output "Pcieport is not in D3cold：\
          \n\033[31m$PCIEPORT\033[0m\n"
      done
    fi
    [[ -n "$PCIEPORT_D3HOT" ]] && log_output "Pcieport is not in D3cold: \
    \n\033[31m$PCIEPORT_D3HOT\033[0m\n"
    return 1
  fi
  return 0
}

#Function to automatically triage the potential deeper S0ix substate blockers
#through Intel_PMC_Core files: lpm_latch_mode and substate_requirements
#$1 is the archivable PC10 or shallower S0ix substate
#$2 is the deeper desired but not achieved S0ix substate
substate_triage() {
  local col=""
  local duration=15
  local sub=""
  local sta=""
  local req=""

  log_output "\n---Begin S0ix Substate Debug by substate_requirements---:\n"
  #Before testing, need to clean the lpm_latch_mode setting
  echo clear >"$PMC_CORE_SYSFS_PATH"/lpm_latch_mode 2>&1
  log_output "Clear lpm_latch_mode is Done\n"
  #Put $1 achieved PC10 or S0ix substate into lpm_latch_mode file
  echo "$1" >"$PMC_CORE_SYSFS_PATH"/lpm_latch_mode 2>&1
  log_output "Set $1 to lpm_latch_mode is Done\n"

  log_output "Need to run once S2idle, please wait for 15 seconds...\n"
  echo 0 >/sys/class/rtc/rtc0/wakealarm
  echo +$duration >/sys/class/rtc/rtc0/wakealarm

  "$DIR"/turbostat --quiet --show "$TURBO_COLUMNS" -o tc.out \
    echo freeze 2>&1 >/sys/power/state
  sleep 2
  #Filter out the desired deeper S0ix substate column:col
  eval "$(cat "$PMC_CORE_SYSFS_PATH"/substate_requirements | awk -F "|" '{
  for(i=1;i<NF;i++)
                  {
                  $i = gensub(/^[ \t]*|[ \t]*$/,"","g",$i)
                  if($i == "'"$2"'")
                    printf("col=%d\n",i)
                  }
                  exit 0
  }')" 2>&1

  log_output "\nsubstate_requirements file shows:\n"
  req="$(cat "$PMC_CORE_SYSFS_PATH"/substate_requirements | awk -F "|" \
    '!/Int_Timer/ && !/LSX_Wake/ && !/VNN_REQ_STS/{print $1,$"'"${col}"'",$(NF-1)}')" 2>&1
  log_output "$req"

  #Filter out the IPs which are required but not show YES
  sub="$(cat "$PMC_CORE_SYSFS_PATH"/substate_requirements | awk -F "|" \
    '!/Int_Timer/ && !/LSX_Wake/ && !/VNN_REQ_STS/{print $1,$"'"${col}"'",$(NF-1)}' |
    grep Required | awk '!/Yes/{print $0}')" 2>&1
  if [[ -z "$sub" ]]; then
    sta=$(cat "$PMC_CORE_SYSFS_PATH"/substate_status_registers)
    log_output "\nDid not detect the potential blockers from substate_requirements, \
    \nneed to check substate_status_registers file for the advanced debug.\n"
    log_output "substate_status_registers:"
    log_output "$sta"
    return 0
  else
    log_output "\nBelow are the deeper S0ix substate required IPs did not show YES:\n"
    log_output "\033[31m $sub \033[0m \n"
    return 1
  fi
}

#Function to check whether Intel graphics DMC FW load status on the test platform
dmc_check() {
  local dmc_load=""
  local dmc_log=""

  dmc_load=$(grep "fw loaded" /sys/kernel/debug/dri/0/i915_dmc_info | head -n 1 |
    awk '{print $3}')
  dmc_log=$(dmesg | grep -i DMC 2>&1)

  if [[ -n "$dmc_load" ]] && [[ $dmc_load == yes ]]; then
    log_output "\nYour system Intel graphics DMC FW loaded status is:$dmc_load\n"
  else
    log_output "\nDid not get i915 dmc info from sysfs.\n"
    if [[ -n "$dmc_log" ]]; then
      log_output "$dmc_log\n"
      return 0
    else
      log_output "\n\033[31mYour system loaded Intel i915 DMC FW is not the latest \
version, \nor you did not install the DMC FW correctly: \n$dmc_log,
    \nplease refer to \
https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/i915 \
    \nto get the latest display DMC FW. \
    \nor re-install the Firmware package or manually check DMC FW file from /lib/firmware/i915.
    \nIf you are running with CentOS, try the command: \
#dracut -i /lib/firmware/i915 /lib/firmware/i915 --force and reboot.\n\033[0m"
      return 1
    fi
  fi
}

#Function to check runtime PC10 state when screen on
pc10_idle_on() {
  local runtime_pkg8=""
  local runtime_pkg10=""
  local turbostat_runtime=""
  local dmc_dir="/sys/kernel/debug/dri/0/i915_dmc_info"
  local pc10_para="CPU%c1,CPU%c6,CPU%c7,GFX%rc6,Pkg%pc2,Pkg%pc3,Pkg%pc6,Pkg%pc7,Pkg%pc8,Pkg%pc9,Pk%pc10"
  local dc5_before=""
  local dc5_after=""
  local dc6_before=""
  local dc6_after=""

  dc5_before=$(grep -i "DC3 -> DC5" $dmc_dir | awk '{print $NF}' 2>&1)
  dc6_before=$(grep -i "DC5 -> DC6" $dmc_dir | awk '{print $NF}' 2>&1)
  log_output "\nThe system will keep idle for 40 seconds then check runtime PC10 state:\n"
  sleep 40
  dc5_after=$(grep -i "DC3 -> DC5" $dmc_dir | awk '{print $NF}' 2>&1)
  dc6_after=$(grep -i "DC5 -> DC6" $dmc_dir | awk '{print $NF}' 2>&1)
  dmc_info=$(cat /sys/kernel/debug/dri/0/i915_dmc_info)
  dc5_count_delta=$(echo "$dc5_after-$dc5_before" | bc)
  dc6_count_delta=$(echo "$dc6_after-$dc6_before" | bc)
  turbostat_runtime=$("$DIR"/turbostat --quiet --show "$pc10_para" sleep 30 2>&1)
  runtime_pkg8=$(echo "$turbostat_runtime" | sed -n '/Pkg\%pc8/{n;p}' |
    awk '{print $9}')
  runtime_pkg10=$(echo "$turbostat_runtime" | sed -n '/Pk\%pc10/{n;p}' |
    awk '{print $11}')
  log_output "\nThe CPU runtime PC10 residency when screen ON: $runtime_pkg10%"
  log_output "The CPU runtime PC8 residency when screen ON: $runtime_pkg8%\n"
  log_output "\nTurbostat log: \n$turbostat_runtime\n"

  #Judge whether turbostat tool supports the test platform
  if [ -z "$runtime_pkg10" ]; then
    log_output "\nYour system installed turbostat tool does not support this \
test platform. \
    \nplease try to get the latest version turbostat tool.\n"
    exit 0
  fi

  if [[ -n "$runtime_pkg10" ]] && [[ "$(echo "scale=2; $runtime_pkg10 > 90.00" |
    bc)" -eq 1 ]]; then
    log_output "\n\033[32mYour system achieved high runtime PC10 residency during screen ON: \
$runtime_pkg10%\033[0m\n"
    return 0

  elif
    [[ -n "$runtime_pkg10" ]] &&
      [[ "$(echo "scale=2; $runtime_pkg10 > 50.00" | bc)" -eq 1 ]] &&
      [[ "$(echo "scale=2; $runtime_pkg10 < 90.00" | bc)" -eq 1 ]]
  then
    log_output "\nYour system achieved runtime PC10 during screen ON, \
    \nbut the residency is not high enough: $runtime_pkg10%\n"
    return 0

  elif
    [[ -n "$runtime_pkg10" ]] &&
      [[ "$(echo "scale=2; $runtime_pkg10 > 0.00" | bc)" -eq 1 ]] &&
      [[ "$(echo "scale=2; $runtime_pkg10 < 50.00" | bc)" -eq 1 ]]
  then
    log_output "\n\033[31mYour system achieved the runtime PC10 during screen ON, \
    \nbut the residency is too low and need to do the further debugging: \
$runtime_pkg10%\033[0m
    \n\nPotential Isolation Check: \
    \nDisplay DC5 count delta is $dc5_count_delta in 40 seconds idle, \
    \nwhich stands for display behavior. \
    \nDisplay DC6 count delta is $dc6_count_delta in 40 seconds idle, \
    \nwhich includes other peripheral besides display.\
    \n/sys/kernel/debug/dri/0/i915_dmc_info shows:\n"
    log_output "$dmc_info"
    return 0

  elif
    [[ -n "$runtime_pkg8" ]] &&
      [[ "$(echo "scale=2; $runtime_pkg8 > 1.00" | bc)" -eq 1 ]]
  then
    log_output "\n\033[32mYour system did not achieve the runtime PC10 during screen ON, \
\nbut the runtime PC8 residency is available:$runtime_pkg8%\033[0m\n"
    return 0
  fi

  log_output "\n\033[31mYour system did not achieve the runtime PC10 state \
during screen ON\033[0m\n"
  return 1
}

#Function to check runtime PC10 residency when screen OFF
pc10_idle_off() {
  local pc10_para="CPU%c1,CPU%c6,CPU%c7,GFX%rc6,Pkg%pc2,Pkg%pc3,Pkg%pc6,Pkg%pc7,Pkg%pc8,Pkg%pc9,Pk%pc10"
  log_output "\nThis script will turn off display using xset command, \
  \nplease startx first, then run this script in xterminal.\n"
  #Turn off display using xset command in GUI
  xset +dpms 2>&1 || {
    log_output "\033[31mPlease run this runtime PC10 check after startx\033[0m\n"
    exit 0
  }
  log_output "\nWill turn off the display in 30 seconds timeout, then the \
  \nturbostat tool will read the PC10 counter after 40 seconds idle...\n"
  xset dpms 30

  local runtime_pkg8=""
  local runtime_pkg10=""
  local turbostat_runtime=""
  sleep 40
  turbostat_runtime=$("$DIR"/turbostat --quiet --show "$pc10_para" sleep 35 2>&1)
  runtime_pkg8=$(echo "$turbostat_runtime" | sed -n '/Pkg\%pc8/{n;p}' |
    awk '{print $9}')
  runtime_pkg10=$(echo "$turbostat_runtime" | sed -n '/Pk\%pc10/{n;p}' |
    awk '{print $11}')
  log_output "The CPU runtime PC10 state when screen OFF: $runtime_pkg10%"
  log_output "The CPU runtime PC8 residency when screen OFF: $runtime_pkg8%\n"
  log_output "\nTurbostat log: \n$turbostat_runtime\n"

  #Judge whether turbostat tool supports the test platform
  if [[ -z "$runtime_pkg10" ]]; then
    log_output "\nYour system installed turbostat tool does not support this
test platform. \
    \nplease try to get the latest version turbostat tool.\n"
    exit 0
  fi

  if [[ -n "$runtime_pkg10" ]] &&
    [[ "$(echo "scale=2; $runtime_pkg10 > 90.00" | bc)" -eq 1 ]]; then
    log_output "\n\033[32mYour system achieved the high runtime PC10 residency during \
screen OFF: $runtime_pkg10%\033[0m\n"
    xset dpms force on && xset -dpms
    return 0

  elif
    [[ -n "$runtime_pkg10" ]] &&
      [[ "$(echo "scale=2; $runtime_pkg10 > 50.00" | bc)" -eq 1 ]] &&
      [[ "$(echo "scale=2; $runtime_pkg10 < 90.00" | bc)" -eq 1 ]]
  then
    log_output "\nYour system achieved the runtime PC10 during screen OFF, \
    \nbut the residency is not high enough: $runtime_pkg10%\n"
    xset dpms force on && xset -dpms
    return 0

  elif
    [[ -n "$runtime_pkg10" ]] &&
      [[ "$(echo "scale=2; $runtime_pkg10 > 0.00" | bc)" -eq 1 ]] &&
      [[ "$(echo "scale=2; $runtime_pkg10 < 50.00" | bc)" -eq 1 ]]
  then
    log_output "\n\033[31mYour system achieved the runtime PC10 state during Screen OFF, \
    \nbut the residency is too low and need to do the further debugging: \
  $runtime_pkg10%\033[0m\n"
    xset dpms force on && xset -dpms
    return 0

  elif
    [[ -n "$runtime_pkg8" ]] &&
      [[ "$(echo "scale=2; $runtime_pkg8 > 1.00" | bc)" -eq 1 ]]
  then
    log_output "\n\033[32mYour system did not achieve the runtime PC10 during screen OFF, \
\nbut the runtime PC8 residency is available:$runtime_pkg8%\033[0m\n"
    xset dpms force on && xset -dpms
    return 0
  fi

  log_output "\n\033[31mYour system did not achieve the runtime PC10 state \
with screen OFF\033[0m\n"
  xset dpms force on && xset -dpms
  return 1
}

#Function to check which package c-state or S0ix state is available during S2idle
pkg_output() {
  local rc6=""
  local cc7=""
  local pkg2=""
  local pkg8=""
  local pkg9=""
  local pkg10=""
  local slp_s0=""
  local turbostat_after_s2idle=""
  local duration=15
  local sub_enable_flag=""
  local sub_bf_enable=""
  local sub_af_enable=""
  local sub_num=""
  local sub_bf=""
  local sub_bf_res=""
  local subarraybf=""
  local resarraybf=""
  local subarrayaf=""
  local resarrayaf=""
  local resdeltaarray=""
  local s0ix_substate=""
  local s0ix_substate_af=""
  local sub_af=""
  local sub_af_res=""
  local shallower=""
  local deeper=""

  s0ix_substate="$(cat $PMC_CORE_SYSFS_PATH/substate_residencies)" 2>&1
  sub_enable_flag="$(grep "Enabled" $PMC_CORE_SYSFS_PATH/substate_residencies)" 2>&1
  if [[ -n "$s0ix_substate" ]] && [[ -z "$sub_enable_flag" ]]; then
    sub_num="$(echo "$s0ix_substate" | wc -l)"
    for ((i = 2; i <= sub_num; i++)); do
      sub_bf="$(sed -n "$i, 1p" $PMC_CORE_SYSFS_PATH/substate_residencies |
        awk '{print $1}')"
      subarraybf[i]=$sub_bf
      sub_bf_res="$(sed -n "$i,1p" $PMC_CORE_SYSFS_PATH/substate_residencies |
        awk '{print $2}')"
      resarraybf[i]=$sub_bf_res
    done
    #Print out the subarray and resarray contents
    log_output "\nTest system supports S0ix.y substate"
    log_output "\nS0ix substate before S2idle:\n" "${subarraybf[*]}"
    log_output "\nS0ix substate residency before S2idle:\n" "${resarraybf[*]}"
  elif
    [[ -n "$s0ix_substate" ]] && [[ -n "$sub_enable_flag" ]]
  then
    sub_num="$(echo "$s0ix_substate" | grep -c "Enabled")"
    for ((i = 1; i <= sub_num; i++)); do
      sub_bf_enable="$(grep "Enabled" $PMC_CORE_SYSFS_PATH/substate_residencies)"
      sub_bf="$(echo "$sub_bf_enable" | sed -n "$i,1p" | awk '{print $2}')"
      subarraybf[i]=$sub_bf
      sub_bf_res="$(echo "$sub_bf_enable" | sed -n "$i,1p" | awk '{print $3}')"
      resarraybf[i]=$sub_bf_res
    done
    #Print out the subarray and resarray contents
    log_output "\nTest system supports S0ix.y substate"
    log_output "\nS0ix substate before S2idle:\n" "${subarraybf[*]}"
    log_output "\nS0ix substate residency before S2idle:\n" "${resarraybf[*]}"
  else
    log_output "Test system does not support S0ix.y substate"
  fi

  echo 0 >/sys/class/rtc/rtc0/wakealarm
  echo +$duration >/sys/class/rtc/rtc0/wakealarm

  if turbostat_after_s2idle=$("$DIR"/turbostat --quiet --show "$TURBO_COLUMNS" \
    echo freeze 2>&1 >/sys/power/state); then
    log_output "\nTurbostat output: \n$turbostat_after_s2idle"
    #Let system sleep 5 seconds in case some systems cannot finish S0ix substate
    #and pkg cstate judgement before entering next S2idle cycle.
    sleep 5
  else
    log_output "\n\033[31mThe system failed to place S2idle entry command by turbostat, \
    \nplease check if the suspend is failed or turbostat tool version is old \
    \ne.g. did you make turbostat tool executable or separately run S2idle command: \
    \nrtcwake -m freeze -s 15\033[0m\n"
    exit 0
  fi

  cc7=$(echo "$turbostat_after_s2idle" | sed -n '/CPU\%c7/{n;p}' |
    awk '{print $3}')
  log_output "\nCPU Core C7 residency after S2idle is: $cc7"

  rc6=$(echo "$turbostat_after_s2idle" | sed -n '/GFX\%rc6/{n;p}' |
    awk '{print $4}')
  log_output "GFX RC6 residency after S2idle is: $rc6"
  if [ -z "$rc6" ]; then
    pkg2=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc2/{n;p}' |
      awk '{print $4}')
    log_output "CPU Package C-state 2 residency after S2idle is: $pkg2"

    pkg3=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc3/{n;p}' |
      awk '{print $5}')
    log_output "CPU Package C-state 3 residency after S2idle is: $pkg3"

    pkg8=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc8/{n;p}' |
      awk '{print $8}')
    log_output "CPU Package C-state 8 residency after S2idle is: $pkg8"

    pkg9=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc9/{n;p}' |
      awk '{print $9}')
    log_output "CPU Package C-state 9 residency after S2idle is: $pkg9"

    pkg10=$(echo "$turbostat_after_s2idle" | sed -n '/Pk\%pc10/{n;p}' |
      awk '{print $10}')
    log_output "CPU Package C-state 10 residency after S2idle is: $pkg10"

    slp_s0=$(echo "$turbostat_after_s2idle" | sed -n '/SYS\%LPI/{n;p}' |
      awk '{print $11}')
    log_output "S0ix residency after S2idle is: $slp_s0"
  else
    pkg2=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc2/{n;p}' |
      awk '{print $5}')
    log_output "CPU Package C-state 2 residency after S2idle is: $pkg2"

    pkg3=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc3/{n;p}' |
      awk '{print $6}')
    log_output "CPU Package C-state 3 residency after S2idle is: $pkg3"

    pkg8=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc8/{n;p}' |
      awk '{print $9}')
    log_output "CPU Package C-state 8 residency after S2idle is: $pkg8"

    pkg9=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc9/{n;p}' |
      awk '{print $10}')
    log_output "CPU Package C-state 9 residency after S2idle is: $pkg9"

    pkg10=$(echo "$turbostat_after_s2idle" | sed -n '/Pk\%pc10/{n;p}' |
      awk '{print $11}')
    log_output "CPU Package C-state 10 residency after S2idle is: $pkg10"

    slp_s0=$(echo "$turbostat_after_s2idle" | sed -n '/SYS\%LPI/{n;p}' |
      awk '{print $12}')
    log_output "S0ix residency after S2idle is: $slp_s0"
  fi

  s0ix_substate_af="$(cat $PMC_CORE_SYSFS_PATH/substate_residencies)" 2>&1
  if [[ -z "$s0ix_substate_af" ]] &&
    [[ "$(echo "scale=2; $slp_s0 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\n\033[32mCongratulations! Your system achieved S2idle S0ix \
residency: $slp_s0\033[0m\n"
    exit 0

  elif [[ -n "$s0ix_substate" ]] &&
    [[ "$(echo "scale=2; $slp_s0 > 0.00" | bc)" -eq 1 ]] &&
    [[ -z "$sub_enable_flag" ]]; then
    OLD_IFS="$IFS"
    IFS=$'\n'
    sub_num="$(echo "$s0ix_substate_af" | wc -l)"
    for ((j = 2; j <= sub_num; j++)); do
      sub_af="$(sed -n "$j, 1p" "$PMC_CORE_SYSFS_PATH"/substate_residencies | awk '{print $1}')"
      subarrayaf[j]=$sub_af
      sub_af_res="$(sed -n "$j,1p" "$PMC_CORE_SYSFS_PATH"/substate_residencies | awk '{print $2}')"
      resarrayaf[j]=$sub_af_res
    done
    IFS="$OLD_IFS"
    #Print out the subarrayaf and resarrayaf
    log_output "\nS0ix substate after S2idle:\n" "${subarrayaf[*]}"
    log_output "\nS0ix substate residency after S2idle:\n" "${resarrayaf[*]}"
    #Judge the substate residency delta
    for ((k = 2; k <= sub_num; k++)); do
      OLD_IFS="$IFS"
      IFS=$'\n'
      resdeltaarray[$k]=$((resarrayaf[k] - resarraybf[k]))
      IFS="$OLD_IFS"
      log_output "\nS0ix substates residency delta value:" \
        "${subarrayaf[$k]}" "${resdeltaarray[$k]}"
    done
    #Scan resdeltaarray and judge which one has no-zero value
    m=${#resdeltaarray[@]}
    while [ $m -ge 2 ]; do
      if [[ "${resdeltaarray[m]}" -gt "0" ]]; then
        if [[ "$m" -eq "${#resdeltaarray[@]}" ]]; then
          log_output "\n\033[32mCongratulations! Your system achieved the deepest \
S0ix substate!\033[0m \
          \nHere is the S0ix substates status: \n$s0ix_substate_af\n"
          exit 0
        else
          OLD_IFS="$IFS"
          IFS=$'\n'
          shallower=${subarrayaf[m]}
          n=$((m + 1))
          deeper=${subarrayaf[n]}
          IFS="$OLD_IFS"
          log_output "\n\033[31mYour system only get shallower S0ix substate \
residency:\033[0m" "\033[31m${subarrayaf[m]}\033[0m" "\033[31m${resarrayaf[m]}\033[0m"
          log_output "\nNeed to debug why not deeper substate:" "$deeper"
          if substate_triage "$shallower" "$deeper"; then
            log_output "\n\033[31mPlease do the advanced debug based on above \
substate_status_registers info \nor report a bug with that attached.\033[0m\n"
            log_output "\n---Debug PCIe root port device and link PM state---"
            #Check PCI devices D states
            pci_d3_status_check
            #Check PCIe bridge link PM states
            debug_pcie_bridge_lpm
            judge_dstate_linkstate
          else
            log_output "\nPlease check the potential blockers\n"
          fi
          exit 0
        fi
      else
        let m--
      fi
    done
    exit 0
  elif [[ -n "$s0ix_substate" ]] &&
    [[ "$(echo "scale=2; $slp_s0 > 0.00" | bc)" -eq 1 ]] &&
    [[ -n "$sub_enable_flag" ]]; then
    OLD_IFS="$IFS"
    IFS=$'\n'
    sub_num="$(echo "$s0ix_substate_af" | grep -c "Enabled")"
    for ((j = 1; j <= sub_num; j++)); do
      sub_af_enable="$(grep "Enabled" $PMC_CORE_SYSFS_PATH/substate_residencies)"
      sub_af="$(echo "$sub_af_enable" | sed -n "$j,1p" | awk '{print $2}')" subarrayaf[j]=$sub_af
      sub_af_res="$(echo "$sub_af_enable" | sed -n "$j,1p" | awk '{print $3}')" resarrayaf[j]=$sub_af_res
    done
    IFS="$OLD_IFS"
    #Print out subarrayaf and resarrayaf
    log_output "\nS0ix substate after S2idle:\n" "${subarrayaf[*]}"
    log_output "\nS0ix substate residency after S2idle:\n" "${resarrayaf[*]}"
    #Judge the substate residency delta
    for ((k = 1; k <= sub_num; k++)); do
      OLD_IFS="$IFS"
      IFS=$'\n'
      resdeltaarray[$k]=$((resarrayaf[k] - resarraybf[k]))
      IFS="$OLD_IFS"
      log_output "\nS0ix substates residency delta value:" \
        "${subarrayaf[$k]}" "${resdeltaarray[$k]}"
    done
    #Scan resdeltaarray and judge which one has no-zero value
    m=${#resdeltaarray[@]}
    while [ $m -ge 1 ]; do
      if [[ "${resdeltaarray[m]}" -gt "0" ]]; then
        if [[ "$m" -eq "${#resdeltaarray[@]}" ]]; then
          log_output "\n\033[32mCongratulations! Your system achieved the \
deepest S0ix substate! \033[0m \
          \nHere is the S0ix substates status: \n$s0ix_substate_af\n"
          exit 0
        else
          OLD_IFS="$IFS"
          IFS=$'\n'
          shallower=${subarrayaf[m]}
          n=$((m + 1))
          deeper=${subarrayaf[n]}
          IFS="$OLD_IFS"
          log_output "\n\033[31mYour system only get shallower S0ix substate \
residency:\033[0m" "${subarrayaf[m]}" "${resarrayaf[m]}"
          log_output "\nNeed to debug why not deeper substate:" "$deeper"
          if [[ -z "$sub" ]]; then
            sta=$(cat $PMC_CORE_SYSFS_PATH/substate_status_registers)
            log_output "\nPlease check substate_status_registers file for the \
advanced debug:\n"
            log_output "substate_status_registers:"
            log_output "$sta\n"
          fi
          exit 0
        fi
      else
        let m--
      fi
    done
    exit 0
  #Judge only PC10 residency is available when S0ix substate is supported
  elif [[ -n "$s0ix_substate" ]] &&
    [[ "$(echo "scale=2; $pkg10 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\n\033[31mYour system supports S0ix substates, but did not \
achieve the shallowest s0i2.0\033[0m
    \nHere is the S0ix substates status: \n$s0ix_substate_af\n"
    #Debug scenario 5: No any S0ix substate residency, only PC10 residency
    DEBUG=5

  elif [[ "$(echo "scale=2; $pkg10 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nNeed to debug which IP blocked S0ix since PC10 is observed."
    #Debug scenario 4: No S0ix residency, but has PC10 residency
    DEBUG=4

  elif [[ "$(echo "scale=2; $pkg9 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nYour system achieved PC9 residency: $pkg9, \
but no PC10 residency:$pkg10,no S0ix residency: $slp_s0"
    #Debug scenario 4: No PC10 residency, but has PC9 residency
    DEBUG=4

  elif [[ "$(echo "scale=2; $pkg8 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nYour system achieved PC8 residency: $pkg8, \
but no PC10 residency:$pkg10,no S0ix residency: $slp_s0"
    #Debug scenario 3: No PC10 residency, but has PC8 residency
    DEBUG=3

  elif [[ "$(echo "scale=2; $pkg3 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nYour system achieved PC3 residency: $pkg3, \
but no PC8 residency during S2idle: $pkg8"
    #Debug scenario 2: No PC8 residency, but has PC3 residency
    DEBUG=2

  elif [[ "$(echo "scale=2; $pkg2 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nYour system achieved PC2 residency: $pkg2, \
but no PC8 residency during S2idle: $pkg8"
    #Debug scenario 2: No PC8 residency, but has PC2 residency
    DEBUG=2

  else
    #Debug scenario 0: No PC2 residency
    log_output "\nYour system did not achieve PC2 state or PC2 residency is low: \
    \n$pkg2"
    DEBUG=1
  fi

  return 0
}

debug_no_pc2() {
  local cc6=""
  local rc6=""
  local turbostat_after_s2idle=""
  local duration=15
  local pc2_para="CPU%c1,CPU%c6,CPU%c7,GFX%rc6,Pkg%pc2"

  #Run powertop --auto-tune to double check PC2 status
  if ! type powertop 1>/dev/null 2>&1; then
    log_output "\033[31mPlease install powertop tool.\033[0m\n"
  else
    powertop --auto-tune 2>&1
  fi

  echo 0 >/sys/class/rtc/rtc0/wakealarm
  echo +$duration >/sys/class/rtc/rtc0/wakealarm

  if turbostat_after_s2idle=$("$DIR"/turbostat --quiet --show "$pc2_para" \
    echo freeze 2>&1 >/sys/power/state); then
    log_output "Turbostat output: \n$turbostat_after_s2idle"
    sleep 5
  else
    log_output "\nThe system failed to place S2idle entry command, please re-try.\n"
    exit 0
  fi

  cc6=$(echo "$turbostat_after_s2idle" | sed -n '/CPU\%c6/{n;p}' |
    awk '{print $3}')
  rc6=$(echo "$turbostat_after_s2idle" | sed -n '/GFX\%rc6/{n;p}' |
    awk '{print $4}')
  log_output "\nCPU Core c6:$cc6"
  log_output "GFX rc6:$rc6"

  #Check whether CPU Core C6 residency is available
  if [[ "$(echo "scale=2; $cc6 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nYour CPU Core C6 residency is available: $cc6"
  else
    log_output "\nYour CPU Core C6 residency is not available, \
need to check which CPU idle driver is in use:"
    cat /sys/devices/system/cpu/cpuidle/current_driver
    log_output "\nCheck what's the CPU idle driver status:"
    grep . /sys/devices/system/cpu/cpu*/cpuidle/state*/* 2>&1
    return 1
  fi

  #Check whether Intel graphics rc6 residency is available
  if [[ "$(echo "scale=2; $rc6 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nYour system Intel graphics RC6 residency is available, \
    \nplease double confirm whether the latest Linux Kernel and the latest
BIOS are in use, \
    \nsome hidden kernel or FW issues are beyond this script ability to isolate"
  else
    log_output "\nYour system did not get the GFX RC6 residency, it's a GFX problem, \
    \nplease check any serious Intel i915 driver failure from dmesg log, if yes please
    \nreport a bug, or the system is installed a third party of graphics device."
    log_output "Check any Intel graphics i915 failure from dmesg log:"
    dmesg | grep -i i915 | grep -iE "error|fail|BUG|HANG|WARNING" 2>&1
    return 1
  fi
  return 0
}

debug_pcie_link_aspm() {
  link_aspm_disable=$(lspci -vvv | grep "ASPM Disabled" 2>&1)
  if [[ -n "$link_aspm_disable" ]]; then
    log_output "\n\033[31mDetected PCIe device link ASPM Disabled, please investigate!\033[0m\n"
    log_output "\033[31m$link_aspm_disable\033[0m\n"
    return 0
  fi
  return 1
}

#Function to check PCIe bridge Link Power Management state
debug_pcie_bridge_lpm() {
  PCI_SYSFS="/sys/devices/pci0000:00"
  PCI_BRIDGE_CLASS="0x060400"
  devices=$(ls ${PCI_SYSFS})
  bridge_devices=()
  local link_substate_cap=""
  local link_substate_ctl=""
  local pci_tree=""
  pci_tree=$(lspci -tvv)

  # Get list of pci bridge devices
  for dev in $devices; do
    if [ -d "${PCI_SYSFS}"/"${dev}" ] &&
      [ -f "${PCI_SYSFS}"/"${dev}"/config ]; then
      class=$(cat "${PCI_SYSFS}"/"${dev}"/class)
      if [[ "${class}" == "${PCI_BRIDGE_CLASS}" ]]; then
        bridge_devices+=("${dev}")
      fi
    fi
  done

  link_state() {
    local pciests1=$1
    local byte1="$((16#${pciests1} >> 8))"
    local ltsmstate="$((16#${pciests1} & 255))"
    local l1msg="Link is in L1"
    local policy=""

    # Some bit manipulation to get Link Status
    lnkstat=$(((byte1 >> 3) & 15))

    case "${lnkstat}" in
    0)
      case "${ltsmstate}" in
      [0-9] | 1[0-6])
        l1msg="Link is in Detect"
        ;;
      4[2-9])
        l1msg="Link is in L2, LTSMSTATE=0"
        ;;
      59 | 60 | 61)
        l1msg="Link is Disabled"
        ;;
      *)
        l1msg="Link is not in Low Power State, LTSMSTATE=${ltsmstate}"
        ;;
      esac
      echo "${l1msg}"
      ;;
    1)
      echo "Link is Retraining"
      ;;
    3)
      case "${ltsmstate}" in
      5[5-9] | 60)
        l1msg="Link is in L1"
        ;;
      61 | 62)
        l1msg="Link is in L1.1"
        ;;
      63 | 64)
        l1msg="Link is in L1.2"
        ;;
      *)
        l1msg="Link is other L1 state, LTSMSTATE=${ltsmstate}"
        ;;
      esac
      echo "${l1msg}"
      ;;
    4)
      echo "Link is in L2"
      ;;
    5)
      echo "Link is in L3"
      ;;
    [7-9] | 10)
      echo "Link is in L0"
      ;;
    *)
      echo "Unknown link state ${lnkstat}"
      ;;
    esac
  }

  #Let system sleep 20 seconds below, in case did not get correct PCIe bridge \
  #Link state at beginning
  sleep 20

  #log_output "\nThe PCIe bridge link power management state is:"
  echo "Available bridge device:" "${bridge_devices[@]}"
  for dev in "${bridge_devices[@]}"; do
    #Get lower 16 bits of PCIESTS1 register
    pciests1=$(xxd -ps -l2 -s 0x32a "${PCI_SYSFS}"/"${dev}"/config)
    if [[ "$(link_state "${pciests1}")" == "Link is in L1.1" ]] ||
      [[ "$(link_state "${pciests1}")" == "Link is in L1.2" ]] ||
      [[ "$(link_state "${pciests1}")" == "Link is in Detect" ]] ||
      [[ "$(link_state "${pciests1}")" == "Link is in Disabled" ]] ||
      [[ "$(link_state "${pciests1}")" == "Link is in L2" ]] ||
      [[ "$(link_state "${pciests1}")" == "Link is in L2, LTSMSTATE=0" ]] ||
      [[ "$(link_state "${pciests1}")" == "Link is in L3" ]]; then
      log_output "\n$dev $(link_state "${pciests1}")"
      log_output "\nThe link power management state of PCIe bridge: $dev is OK."
    else
      PCIEPORT_L0="$dev"
      log_output "\nThe PCIe bridge link power management state is:"
      log_output "\033[31m$dev $(link_state "${pciests1}")\033[0m"
      log_output "\nThe link power management state of PCIe bridge: \
\033[31m$dev\033[0m is not expected. \nwhich is expected to be L1.1 or L1.2, \
or user would run this script again.\n"
      link_substate_cap=$(lspci -vvv -s"$dev" | grep L1SubCap)
      link_substate_ctl=$(lspci -vvv -s"$dev" | grep L1SubCtl1)
      log_output "\nThe L1SubCap of the failed $dev is:"
      log_output "$link_substate_cap"
      log_output "\nThe L1SubCtl1 of the failed $dev is:"
      log_output "$link_substate_ctl\n"
      log_output "\nChecking PCI Devices tree diagram:\n$pci_tree\n"
      return 1
    fi
  done

  #Check PCIE_ASPM default setting
  policy=$(grep "\[.*\]" -o /sys/module/pcie_aspm/parameters/policy 2>&1)
  if [[ "$policy" == "[default]" ]] ||
    [[ "$policy" == "[powersupersave]" ]]; then
    log_output "\nYour system default pcie_aspm policy setting is OK.\n"
  else
    log_output "\nYour system default PCIe_aspm policy setting is not proper, \
    \nsuggest to set /sys/module/pcie_aspm/parameters/policy to default or \
powersupersave.\n"
    return 1
  fi
  return 0
}

debug_no_pc8() {
  local cc7=""
  local rc6=""
  local turbostat_after_s2idle=""
  local duration=15

  #Run powertop --auto-tune to make sure the devices runtime PM are enabled
  if ! type powertop 1>/dev/null 2>&1; then
    log_output "\033[31mPlease install powertop tool.\033[0m\n"
  else
    powertop --auto-tune 2>&1
  fi

  echo 0 >/sys/class/rtc/rtc0/wakealarm
  echo +$duration >/sys/class/rtc/rtc0/wakealarm

  if turbostat_after_s2idle=$("$DIR"/turbostat --quiet --show "$TURBO_COLUMNS" \
    echo freeze 2>&1 >/sys/power/state); then
    log_output "\nTurbostat output: \n\n$turbostat_after_s2idle"
    sleep 5
  else
    log_output "\nThe system failed to place S2idle entry command, please re-try.\n"
    exit 0
  fi

  cc7=$(echo "$turbostat_after_s2idle" | sed -n '/CPU\%c7/{n;p}' |
    awk '{print $3}')
  rc6=$(echo "$turbostat_after_s2idle" | sed -n '/GFX\%rc6/{n;p}' |
    awk '{print $4}')
  pkg8=$(echo "$turbostat_after_s2idle" | sed -n '/Pkg\%pc8/{n;p}' |
    awk '{print $9}')
  pkg10=$(echo "$turbostat_after_s2idle" | sed -n '/Pk\%pc10/{n;p}' |
    awk '{print $11}')
  slp_s0=$(echo "$turbostat_after_s2idle" | sed -n '/SYS\%LPI/{n;p}' |
    awk '{print $12}')

  #Check whether PC8,PC10 and S0ix is available after running powertop
  if [[ "$(echo "scale=2; $slp_s0 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nS0ix residency is achieved after powertop --auto-tune"
    return 0
  elif [[ "$(echo "scale=2; $pkg10 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nPC10 residency achieved after powertop --auto-tune, \
but still no S0ix residency"
    return 0
  elif [[ "$(echo "scale=2; $pkg8 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nPC8 residency achieved after powertop --auto-tune, \
but still no PC10 and S0ix"
    return 0
  fi
  #Check whether CPU Core C7 residency is available
  if [[ "$(echo "scale=2; $cc7 > 0.00" | bc)" -eq 1 ]]; then
    log_output "\nYour CPU Core C7 residency is available: $cc7"
  else
    log_output "\nYour CPU Core C7 residency is not available, need to check \
which CPU idle driver is in use:"
    cat /sys/devices/system/cpu/cpuidle/current_driver
    log_output "\n\nCheck what's the CPU idle driver status:"
    grep . /sys/devices/system/cpu/cpu*/cpuidle/state*/* 2>&1
    return 1
  fi

  #Check whether Intel graphics RC6 residency is available and high enough for pc8
  if [[ -z "$rc6" ]]; then
    log_output "\n\033[31mPlease check if Intel graphic i915 driver is not loaded \
    \nor Intel graphics controller has been disabled \
    \nor the 3rd party graphics device is installed.\033[0m\n"
  elif [[ "$(echo "scale=2; $rc6 > 50.00" | bc)" -eq 1 ]]; then
    log_output "\nYour system Intel graphics RC6 residency is available:$rc6"
  else
    log_output "\nYour system graphics RC6 residency is low, need to double check \
the status after disabling gfx controller from BIOS setup \
    \nor appending modprobe.blacklist=i915 kernel parameter to check any \
deeper Package C-state available,\nthen submit an i915 bug to Intel graphics team.\n"
    return 1
  fi

  #Check whether PCIe Link PM is in L1 or L2, as L0 may block PC3
  if [[ "$(echo "scale=2; $pkg8 < 1.00" | bc)" -eq 1 ]]; then
    log_output "\nChecking PCIe Device D state and Bridge Link state:\n"
    debug_pcie_bridge_lpm
    pci_d3_status_check
  fi
}

debug_no_dc9() {
  local kbl_l=142
  local kbl=158
  local cml=165
  local cml_l=166
  local dc5_before=""
  local dc5_after=""
  local dc6_before=""
  local dc6_after=""
  local rc6_model_list=""
  local model=""
  local i=""
  local turbostat_after_s2idle=""
  local duration=15
  local dmc_dir="/sys/kernel/debug/dri/0/i915_dmc_info"

  if [ ! -f "$dmc_dir" ]; then
    log_output "\nPlease check if the Intel graphics i915 driver is not loaded \
or the graphic controller has been disabled?"
    return 0
  fi

  dc5_before=$(grep -i "DC3 -> DC5" $dmc_dir | awk '{print $(NF)}' 2>&1)
  dc6_before=$(grep -i "DC5 -> DC6" $dmc_dir | awk '{print $(NF)}' 2>&1)
  log_output "\nGFX DC5 before S2idle: $dc5_before"
  log_output "GFX DC6 before S2idle: $dc6_before"

  echo 0 >/sys/class/rtc/rtc0/wakealarm
  echo +$duration >/sys/class/rtc/rtc0/wakealarm

  if turbostat_after_s2idle=$("$DIR"/turbostat --quiet --show "$TURBO_COLUMNS" \
    echo freeze 2>&1 >/sys/power/state); then
    log_output "\nTurbostat output: \n\n$turbostat_after_s2idle"
    sleep 5
  else
    log_output "\nThe system failed to place S2idle entry command, please re-try\n"
    exit 0
  fi

  dc5_after=$(grep -i "DC3 -> DC5" $dmc_dir | awk '{print $(NF)}' 2>&1)
  dc6_after=$(grep -i "DC5 -> DC6" $dmc_dir | awk '{print $(NF)}' 2>&1)
  log_output "\nGFX DC5 after S2idle: $dc5_after"
  log_output "GFX DC6 after S2idle: $dc6_after"

  #Check DC6 state for Intel® Coffee lake, Whiskey lake, Comet lake platforms
  rc6_model_list="$kbl $kbl_l $cml $cml_l"

  model=$(sed -n '/model/p' /proc/cpuinfo | head -1 | awk '{print $3}' 2>&1)

  if [[ "$rc6_model_list" =~ $model ]]; then
    #Check DC6 state for Intel® Coffee lake, Whiskey lake, Comet lake platforms
    if [[ "$dc6_after" -gt "$dc6_before" ]]; then
      log_output "\nYour system CPU Model ID is: $model, and the graphics DC6 \
value is OK for DC9 entry."
      return 0
    else
      log_output "\nYour system CPU Model ID is: $model, and the graphics DC6 \
value is not expected to enter DC9, \
      \nplease check the latest display DMC FW load status:"
      if dmc_check; then
        return 0
      fi
      return 1
    fi
  #Check DC5 state for Intel® Broxton, Gemini lake, Ice lake and afterwards platforms
  elif [[ "$dc5_after" -lt "$dc5_before" ]]; then
    log_output "\nYour system CPU Model ID is: $model, and the graphics DC5 \
value is OK for DC9 entry."
    return 0
  else
    log_output "\nYour system CPU Model ID is: $model, and the graphics DC5 \
value is not expected to enter DC9, \
    \nplease check the latest display DMC FW load status."
    if dmc_check; then
      return 0
    fi
    return 1
  fi
}

debug_ltr_value() {
  local pc10=""
  local slp_s0=""
  local ltr_ip_num=""
  local l=""
  local counter=0
  local turbostat_after_s2idle=""
  local duration=10
  local ltr_failed_ip=""

  echo 0 >/sys/class/rtc/rtc0/wakealarm
  echo +$duration >/sys/class/rtc/rtc0/wakealarm

  if turbostat_after_s2idle=$("$DIR"/turbostat --quiet --show "$TURBO_COLUMNS" \
    echo freeze 2>&1 >/sys/power/state); then
    log_output "\nTurbostat output: \n$turbostat_after_s2idle"
    sleep 5
  else
    log_output "\nThe system failed to place S2idle entry command, please re-try.\n"
    exit 0
  fi

  pc10=$(echo "$turbostat_after_s2idle" | sed -n '/Pk\%pc10/{n;p}' |
    awk '{print $11}')
  slp_s0=$(echo "$turbostat_after_s2idle" | sed -n '/SYS\%LPI/{n;p}' |
    awk '{print $12}')

  #Check whether IP LTR value ignore is helpful to the PC10 and S0ix state
  ltr_ip_num=$(wc -l $PMC_CORE_SYSFS_PATH/ltr_show 2>&1 | awk '{print$1}')
  l=$((ltr_ip_num - 1))
  log_output "\nIP LTR Number: $l \
  \nPlease be patient, system will do $l cycles S2idle below, check if ignoring \
  \nthe IP LTR value is helpful to the PC10 and S0ix residency one by one."

  until [ $counter -gt $l ]; do
    echo $counter >$PMC_CORE_SYSFS_PATH/ltr_ignore
    log_output "\nLTR ignore for IP "$counter

    echo 0 >/sys/class/rtc/rtc0/wakealarm
    echo +$duration >/sys/class/rtc/rtc0/wakealarm

    if turbostat_after_s2idle=$("$DIR"/turbostat --quiet --show "$TURBO_COLUMNS" \
      echo freeze 2>&1 >/sys/power/state); then
      pc10=$(echo "$turbostat_after_s2idle" | sed -n '/Pk\%pc10/{n;p}' |
        awk '{print $11}')
      slp_s0=$(echo "$turbostat_after_s2idle" | sed -n '/SYS\%LPI/{n;p}' |
        awk '{print $12}')
      log_output "PC10 residency is:$pc10"
      log_output "S0ix residency is:$slp_s0"
    else
      log_output "The system failed to place S2idle entry command, please re-try.\n"
      exit 0
    fi

    if [ "$(echo "scale=2; $slp_s0 > 0.00" | bc)" -eq 1 ]; then
      log_output "\nS0ix residency is available after IP number $counter LTR ignore\n"
      let ltr_failed_ip=$l+1 &&
        cat "$PMC_CORE_SYSFS_PATH"/ltr_show | sed -n ''"ltr_failed_ip"''
      exit 0
    elif [ "$(echo "scale=2; $pc10 > 0.00" | bc)" -eq 1 ]; then
      log_output "\nNo S0ix residency, only PC10 is available after IP number \
$counter LTR ignore:\n"
      let ltr_failed_ip=$l+1 &&
        cat "$PMC_CORE_SYSFS_PATH"/ltr_show | sed -n ''"ltr_failed_ip"''
      return 0
      break
    else
      log_output "\nIP Number $counter LTR ignore is not helpful to the PC10 \
and S0ix state."
    fi
    counter=$((counter + 1))
    sleep 2
  done
  return 1
}

ignore_ltr_all() {
  local ltr_ip_num
  local num
  local i=0

  ltr_ip_num=$(wc -l $PMC_CORE_SYSFS_PATH/ltr_show 2>&1 | awk '{print$1}')
  num=$((ltr_ip_num - 1))

  while [ $i -ne $num ]; do
    echo $i >$PMC_CORE_SYSFS_PATH/ltr_ignore 2>&1
    i=$((i + 1))
  done
}

debug_pch_ip_pg() {
  local south_port_before=""
  local south_port_after=""
  local i=1

  south_port_before=$(grep -i On $PMC_CORE_SYSFS_PATH/pch_ip_power_gating_status |
    sed -n '/\<SP[A-F]/p' | awk '{print $5}' 2>&1)
  if [ -n "$south_port_before" ]; then
    log_output "\nYour system south port controller did not meet S0ix requirement: \
\033[31m$south_port_before\033[0m"
    grep "$south_port_before" $PMC_CORE_SYSFS_PATH/pch_ip_power_gating_status
    return 0
  else

    #Grep south ports power gating state multi-cycles as it reports the runtime state
    while [ $i -le 10 ]; do
      sleep 3
      south_port_after=$(grep -i On $PMC_CORE_SYSFS_PATH/pch_ip_power_gating_status |
        sed -n '/\<SP[A-F]/p' | awk '{print $5}' 2>&1)
      if [[ "$south_port_after" == "$south_port_before" ]]; then
        let ++i
        continue
      else
        log_output "\nYour system south port controller did not meet S0ix requirement: \
\033[31m$south_port_after\033[0m"
        grep "$south_port_after" $PMC_CORE_SYSFS_PATH/pch_ip_power_gating_status
        return 0
      fi
    done
    log_output "\nYour system south port controller power gating state is OK \
after 30 seconds runtime check."
  fi
  return 1
}

debug_s0ix() {
  local mphy=""
  local main_pll=""
  local oc_pll=""
  local csme=""
  local i=1

  #Enable slp_s0 debug setting
  echo Y >$PMC_CORE_SYSFS_PATH/slp_s0_dbg_latch 2>&1

  if rtcwake -m freeze -s 15 1>/dev/null 2>&1; then
    log_output "\nChecking slp_s0_debug_status:"
  else
    log_output "\nSystem failed to place S2idle entry command, please re-try.\n"
    exit 0
  fi

  mphy=$(grep No $PMC_CORE_SYSFS_PATH/slp_s0_debug_status |
    grep "MPHY_CORE_GATED" | awk '{print $2}')
  main_pll=$(grep No $PMC_CORE_SYSFS_PATH/slp_s0_debug_status |
    grep "MAIN_PLL_OFF" | awk '{print $2}')
  oc_pll=$(grep No $PMC_CORE_SYSFS_PATH/slp_s0_debug_status |
    grep "OC_PLL_OFF" | awk '{print $2}')
  csme=$(grep No $PMC_CORE_SYSFS_PATH/slp_s0_debug_status |
    grep "CSME_GATED" | awk '{print $2}')

  if [[ -z "$mphy" ]]; then
    log_output "\nYour system ModPHY Lane Core domain power gating state is OK \
for S0ix entry."
  else
    log_output "\nYour system ModPHY lane Core domain has issue blocks S0ix."
    log_output "\nIsolation suggestions: \
    \nCheck ModPHY related high speed I/O controller list: \
    \ncovering from XHCI, XDCI, SATA, PCIe (all instances), Gbe and SCC (UFS)"
  fi

  if [[ -z "$main_pll" ]] && [[ -z "$oc_pll" ]]; then
    log_output "\nYour system Main PLL and Oscillator Crystal PLL state are OK \
for S0ix entry."
  else
    log_output "\nYour system Main PLL or Oscillator Crystal PLL has issue to \
power off during S2idle, which may block S0ix. \
    \nFailed PLL: $main_pll $oc_pll\n"
    return 1
  fi

  #Grep CSMe power gating state multi-cycles as it reports the runtime state
  while [ $i -le 10 ]; do
    sleep 3
    if [ -z "$csme" ]; then
      log_output "\nYour system CSMe power gating state is OK for S0ix entry.\n"
      return 0
    else
      let ++i
      continue
    fi
  done
  log_output "\nYour system CSMe did not power gated during S2idle after 30 \
seconds runtime check. \
  \nIsolation suggestion: \
  \nPlease check whether the latest CSME FW is updated or run this script again."
  return 1
}

debug_acpi_dsm() {
  local slp_s0=""
  local turbostat_after_s2idle=""
  local duration=15

  echo Y >/sys/module/acpi/parameters/sleep_no_lps0
  echo 0 >/sys/class/rtc/rtc0/wakealarm
  echo +$duration >/sys/class/rtc/rtc0/wakealarm

  if turbostat_after_s2idle=$("$DIR"/turbostat --quiet --show "$TURBO_COLUMNS" \
    echo freeze 2>&1 >/sys/power/state); then
    slp_s0=$(echo "$turbostat_after_s2idle" | sed -n '/SYS\%LPI/{n;p}' |
      awk '{print $12}')
  else
    log_output "\nThe system failed to place S2idle entry command, please re-try.\n"
    exit 0
  fi

  if [ "$(echo "$slp_s0 > 0" | bc)" -eq 1 ]; then
    log_output "\nS0ix residency is available after setting no ACPI DSM callback.\n"
    exit 0
  else
    log_output "\nSetting no ACPI DSM callback is not helpful to the S0ix residency."
    #Recover the ACPI DSM setting
    echo N >/sys/module/acpi/parameters/sleep_no_lps0
  fi
  return 0
}

judge_dstate_linkstate() {
  [[ -n "$PCIEPORT_D0" ]] && D0="$PCIEPORT_D0"
  [[ -n "$PCIEPORT_L0" ]] && L0="$PCIEPORT_L0"

  if [[ -n $D0 ]] && [[ -n $L0 ]] &&
    [[ "$D0" =~ $L0 ]] && [[ -n "$ASPM_ENABLE" ]]; then
    log_output "\n\033[31mThe pcieroot port $L0 ASPM setting is Enabled, its \
D state and Link PM are not expected,\nplease investigate or report a bug.\033[0m\n"
  elif [[ -n $D0 ]] && [[ -n $L0 ]] &&
    [[ "$D0" =~ $L0 ]] && [[ -z "$ASPM_ENABLE" ]]; then
    log_output "\n\033[31mThe pcieroot port $L0 ASPM setting is Disabled, and \
its D state and Link PM are not expected,\nplease enable $L0 ASPM setting to \
double check or report a bug.\033[0m\n"
    return 1
  fi
  return 0
}

##############################################################################
if [[ $runtime == on ]]; then
  log_output "\n---Check Runtime PC10 Residency during Screen ON---:"
  [[ -n "$KERNEL_VER" ]] && log_output "\nThe system OS Kernel version is:
$KERNEL_VER\n"
  if ! type powertop 1>/dev/null 2>&1; then
    log_output "\033[31mPlease install powertop tool.\033[0m\n"
  else
    powertop --auto-tune 2>&1
  fi

  if pc10_idle_on; then
    log_output "\n"
  elif dmc_check; then
    log_output "\nIntel graphics i915 DMC FW is loaded. Will re-check the deeper
Package C-state by ignoring PCI Devices LTR value:\n"

    #Ignore all the PCI devices LTR values
    ignore_ltr_all
    log_output "All the PCI devices LTR values ignore is done!"

    if pc10_idle_on; then
      log_output "\n\033[32mThe deeper CPU Package C-state is available after
PCI devices LTR ignore,please investigate the potential IP LTR issue.\033[0m\n"
      exit 0
    else
      log_output "\nPCI devices LTR value ignore does not help the PC10, will
check PCIe Link PM states:\n"
      if debug_pcie_link_aspm; then
        exit 0
      else
        debug_pcie_bridge_lpm "$@"
        exit 0
      fi
    fi
  fi
fi

##############################################################################
if [[ $runtime == off ]]; then
  log_output "\n---Check Runtime PC10 Residency during Screen OFF---:"
  [[ -n "$KERNEL_VER" ]] && log_output "\nThe system OS Kernel version is:
$KERNEL_VER\n"
  if ! type powertop 1>/dev/null 2>&1; then
    log_output "\033[31mPlease install powertop tool.\033[0m\n"
  else
    powertop --auto-tune 2>&1
  fi
  if pc10_idle_off; then
    log_output "\n"
  elif dmc_check; then
    log_output "\nIntel graphics i915 DMC FW is loaded. Will re-check the deeper
Package C-state by ignoring PCI Devices LTR value:\n"

    #Ignore all the PCI devices LTR values
    ignore_ltr_all
    log_output "All the PCI devices LTR values ignore is done!"

    if pc10_idle_off; then
      log_output "\n\033[32mThe deeper CPU Package C-state is available after
PCI devices LTR ignore, please investigate the potential IP LTR issue.\033[0m\n"
      exit 0
    else
      log_output "\nPCI devices LTR value ignore does not help the PC10, will
check PCIe Link PM states:\n"
      if debug_pcie_link_aspm; then
        exit 0
      else
        debug_pcie_bridge_lpm "$@"
        exit 0
      fi
    fi
  fi
fi

##############################################################################
if [[ $s2idle == 1 ]]; then
  log_output "\n---Check S2idle path S0ix Residency---:"
  [[ -n "$KERNEL_VER" ]] && log_output "\nThe system OS Kernel version is:
$KERNEL_VER"
  log_output "\n---Check whether your system supports S0ix or not---:"
  if slp_s0_support; then
    log_output "\n"
  else
    exit 0
  fi

  log_output "\n---Check whether intel_pmc_core sysfs files exit---:"
  if pmc_core_check; then
    log_output "\n"
  else
    log_output "\nThe intel_pmc_core sysfs missing will impact S0ix failure analyze.\n"
  fi

  log_output "\n---Judge PC10, S0ix residency available status---:"
  pkg_output

  case $DEBUG in
  1)
    log_output "\n---Debug no PC2 residency scenario---:"
    if debug_no_pc2; then
      log_output "\nYour system CPU Core C6 and Intel graphics RC6 is OK, \
      \nthen this script cannot handle the exception which IP blocked PC2 state. \
      \nIf your HW is unstable, suggest to re-run this script.\n"
    fi
    ;;
  2)
    log_output "\n---Debug no PC8 residency scenario---:"
    if debug_no_pc8; then
      log_output "\nYour system CPU Core C7, GFX RC6, PCIe Device D state and \
Link PM state are OK, \nbut still did not achieve PC8 after powertop --auto-tune\n"
    else
      judge_dstate_linkstate
    fi
    ;;
  3)
    log_output "\n---Debug no DC9 residency scenario---:"
    if debug_no_dc9; then
      log_output "\n"
    else
      log_output "\nYour system had potential graphics bug, did not get DC9, \
 which may block PC10.\n"
      exit 0
    fi
    #If DC9 is OK, will check PCI devices LTR value
    log_output "\n---Debug no PC10 residency scenario--Ignore IP LTR value---:"
    if debug_ltr_value; then
      log_output "\nThis script detects PC10 residency after IP LTR ignore. \
      \nPlease consider reporting a bug against the potential IP LTR issue \
if the test platform is stable. \nMeanwhile this script will continue to check
the potential S0ix blocker since PC10 is available.\n"

      # When PC10 residency is achieved after IP LTR ignore,
      # this script will continue to check the potential S0ix blocker
      if debug_pch_ip_pg; then
        log_output "\n---Debug S0ix failure scenario--Setting No ACPI DSM Callback---:"
        debug_acpi_dsm

        log_output "\n---Debug PCIeports D states and link PM states---"
        #Check PCI devices D states
        pci_d3_status_check
        #Check PCIe bridge link PM states
        debug_pcie_bridge_lpm "$@"
        judge_dstate_linkstate
      fi
      #Check ModPHY and CSMe subsystem power gating status
      if [[ -e "${PMC_CORE_SYSFS_PATH}/slp_s0_dbg_latch" ]]; then
        if debug_s0ix; then
          log_output "\nModPHY and CSMe subsystem power gating status are OK\n"
        fi
      fi
    #When checking no-PC10 residency scenario, if ignoring IP LTR value is not \
    #helpful, then need to check PCIeport D state and Link Power Management state
    else
      log_output "\n---Debug PCIeports D states and link PM states---"
      #Check PCI devices D states
      pci_d3_status_check
      #Check PCIe bridge link PM states
      debug_pcie_bridge_lpm "$@"
      judge_dstate_linkstate
    fi
    ;;
  4)
    log_output "\n---Debug S0ix failure scenario--PCH IP power gating check---:"
    if debug_pch_ip_pg; then
      log_output "\n---Debug S0ix failure scenario--Setting No ACPI DSM Callback---:"
      debug_acpi_dsm

      log_output "\n---Debug PCIeport D states and link PM states---"
      #Check PCI devices D states
      pci_d3_status_check
      #Check PCIe bridge link PM states
      debug_pcie_bridge_lpm "$@"
      judge_dstate_linkstate
    fi

    #Check ModPHY and CSMe subsystem power gating status
    if [[ -e "${PMC_CORE_SYSFS_PATH}/slp_s0_dbg_latch" ]]; then
      if debug_s0ix; then
        log_output "\nModPHY and CSMe subsystem power gating status are OK\n"
      fi
    fi
    ;;
  5)
    log_output "\n---Debug s0i2.0 substate failure scenario---:"
    if [[ -e "${PMC_CORE_SYSFS_PATH}/lpm_latch_mode" ]]; then
      substate_triage "$SHALLOW" "$DEEP"
    fi
    if debug_pch_ip_pg; then
      log_output "\n---Trying S0ix workaround: setting No ACPI DSM Callback---:"
      debug_acpi_dsm

      log_output "\n---Debug PCIeport D states and link PM states---"
      #Check PCI devices D states
      pci_d3_status_check
      #Check PCIe bridge link PM states
      debug_pcie_bridge_lpm "$@"
      judge_dstate_linkstate
    fi
    ;;
  esac
fi

exit 0
