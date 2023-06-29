#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# Script to install a RaspberryMatic OVA VM in Proxmox programatically.
# https://raw.githubusercontent.com/jens-maus/RaspberryMatic/master/scripts/install-proxmox.sh
#
# Inspired by https://github.com/whiskerz007/proxmox_hassos_install
#
# Copyright (c) 2022-2023 Jens Maus <mail@jens-maus.de>
# Apache 2.0 License applies
#
# Usage:
# wget -qO - https://raspberrymatic.de/install-proxmox.sh | bash -
#

# Setup script environment
set -o errexit  #Exit immediately if a pipeline returns a non-zero status
set -o errtrace #Trap ERR from shell functions, command substitutions, and commands from subshell
set -o nounset  #Treat unset variables as an error
set -o pipefail #Pipe will exit with last non-zero status if applicable
shopt -s expand_aliases
alias die='EXIT=$? LINE=${LINENO} error_exit'
trap die ERR
trap cleanup EXIT

# Set default variables
VERSION="1.10"
LOGFILE="/tmp/install-proxmox.log"
LINE=

function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m${EXIT}@${LINE}:"
  msg "${FLAG} ${REASON}"
  [ -n "${VMID-}" ] && cleanup_vmid
  msg "${FLAG} \e[39mSee ${LOGFILE} for error details"
  exit "${EXIT}"
}
function warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "${FLAG} ${REASON}"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "${FLAG} ${REASON}"
}
function msg() {
  local TEXT="$1"
  echo -e "${TEXT}"
}
function cleanup_vmid() {
  if qm status "${VMID}" >>${LOGFILE} 2>&1; then
    if [ "$(qm status "${VMID}" | awk '{print $2}')" == "running" ]; then
      qm stop "${VMID}" >>${LOGFILE} 2>&1
    fi
    qm destroy "${VMID}" >>${LOGFILE} 2>&1
  fi
}
function cleanup() {
  popd >/dev/null
  rm -rf "${TEMP_DIR}"
}

msg "RaspberryMatic Proxmox installation script v${VERSION}"
msg "Copyright (c) 2022-2023 Jens Maus <mail@jens-maus.de>"
msg ""

# create temp dir
TEMP_DIR=$(mktemp -d)
pushd "${TEMP_DIR}" >/dev/null

# remove existing log
rm -f "${LOGFILE}"

# check if this is a valid PVE environment host or not
if [[ ! -d /etc/pve ]]; then
  die "This script must be executed on a Proxmox VE host system."
fi

# Select RaspberryMatic ova version
info "Getting available RaspberryMatic releases..."
RELEASES=$(cat<<EOF | python3
import requests
import os
url = "https://api.github.com/repos/jens-maus/RaspberryMatic/releases"
r = requests.get(url).json()
if "message" in r:
    exit()
num = 0
for release in r:
    if release["prerelease"] or release["tag_name"] == "snapshots":
      continue
    for asset in release["assets"]:
        if asset["name"].endswith(".ova") == True:
            image_url = asset["browser_download_url"]
            name = asset["name"]
            version = os.path.splitext(name)[0][name.find('-')+1:]
            if num < 5:
                print(version + ' release ' + image_url)
                num = num + 1
            break
EOF
)
if [[ -z "${RELEASES}" ]]; then
  die "GitHub has returned an error. A rate limit may have been applied to your connection."
fi

SNAPSHOTS=$(cat<<EOF | python3
import requests
import os
url = "https://api.github.com/repos/jens-maus/RaspberryMatic/releases/tags/snapshots"
r = requests.get(url).json()
if "message" in r:
    exit()
print()
for asset in r["assets"]:
    if asset["name"].endswith(".ova") == True:
        image_url = asset["browser_download_url"]
        name = asset["name"]
        version = os.path.splitext(name)[0][name.find('-')+1:]
        print(version + ' snapshot ' + image_url)
        break
EOF
)

if [[ -z "${SNAPSHOTS}" ]]; then
  die "GitHub has returned an error. A rate limit may have been applied to your connection."
fi

RELEASES+=${SNAPSHOTS}
MSG_MAX_LENGTH=0
RELEASES_MENU=()
i=0
while read -r line; do
  VERSION=$(echo "${line}" | cut -d' ' -f1)
  ITEM=$(echo "${line}" | cut -d' ' -f2)
  OFFSET=20
  if [[ $((${#ITEM} + OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + OFFSET))
  fi
  RELEASES_MENU+=("${VERSION}" " ${ITEM}")
  ((i=i+1))
done < <(echo "${RELEASES}")

RELEASE=$(whiptail --title "Select RaspberryMatic Version" \
                   --menu \
                     "Select RaspberryMatic version to install:\n\n" \
                     16 $((MSG_MAX_LENGTH + 23)) 6 \
                     "${RELEASES_MENU[@]}" 3>&1 1>&2 2>&3) || exit

# extract URL from RELEASES
prefix=${RELEASES%%"$RELEASE"*}
URL=$(echo ${RELEASES:${#prefix}} | cut -d' ' -f3)
info "Using $RELEASE for VM installation"

# Select storage location
info "Selecting storage location"
MSG_MAX_LENGTH=0
while read -r line; do
  TAG=$(echo "${line}" | awk '{print $1}')
  TYPE=$(echo "${line}" | awk '{printf "%-10s", $2}')
  FREE=$(echo "${line}" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: ${TYPE} Free: ${FREE} "
  OFFSET=2
  if [[ $((${#ITEM} + OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + OFFSET))
  fi
  STORAGE_MENU+=( "${TAG}" "${ITEM}" "OFF" )
done < <(pvesm status -content images | awk 'NR>1')
if [ $((${#STORAGE_MENU[@]}/3)) -eq 0 ]; then
  warn "'Disk image' needs to be selected for at least one storage location."
  die "Unable to detect valid storage location."
elif [ $((${#STORAGE_MENU[@]}/3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --title "Storage Pools" --radiolist \
    "Which storage pool you would like to use for the container?\n\n" \
    16 $((MSG_MAX_LENGTH + 23)) 6 \
    "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit
  done
fi
info "Using '${STORAGE}' for storage location."

# Search+Select HomeMatic USB devices
MSG_MAX_LENGTH=0
USB_MENU=()
USB_DEVICE=
while read -r line; do
  ID=$(echo "${line}" | cut -d' ' -f6)
  if [[ "${ID}" == "1b1f:c020" ]] ||     # HmIP-RFUSB
     [[ "${ID}" == "10c4:8c07" ]] ||     # HB-RF-USB-2
     [[ "${ID}" == "0403:6f70" ]] ||     # HB-RF-USB
     [[ "${ID}" == "1b1f:c00f" ]]; then  # HM-CFG-USB-2
    ITEM=$(echo "${line}" | cut -d' ' -f7-)
    OFFSET=2
    if [[ $((${#ITEM} + OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
      MSG_MAX_LENGTH=$((${#ITEM} + OFFSET))
    fi
    USB_MENU+=( "${ID}" "${ITEM}" "OFF" )
  fi
done < <(lsusb)
if [[ -n "${USB_MENU[*]}" ]]; then
  info "Selecting HomeMatic-RF USB devices"
  USB_DEVICE=$(whiptail --title "HomeMatic-RF USB devices" --radiolist \
  "Which HomeMatic-RF USB device should be bind to RaspberryMatic VM?\n\n" \
  16 $((MSG_MAX_LENGTH + 23)) 6 \
  "${USB_MENU[@]}" 3>&1 1>&2 2>&3) || exit

  if [[ -n "${USB_DEVICE}" ]]; then
    info "Using '${USB_DEVICE}' as HomeMatic-RF device on usb0."
  else
    info "Using no USB device as HomeMatic-RF device."
  fi
else
  info "No HomeMatic-RF USB device found."
fi

# Get the next guest VM/LXC ID
VMID=$(pvesh get /cluster/nextid)
info "Container ID is ${VMID}."

# Download RaspberryMatic ova archive
info "Downloading disk image..."
wget -q --show-progress "${URL}"
echo -en "\e[1A\e[0K" #Overwrite output from wget
FILE=$(basename "${URL}")

# Extract RaspberryMatic disk image
info "Extracting disk image..."
tar xf "${FILE}"

# Identify target format
IMPORT_OPT=
STORAGE_TYPE=$(pvesm status -storage "${STORAGE}" | awk 'NR>1 {print $2}')
if [[ "${STORAGE_TYPE}" == "dir" ]] ||
   [[ "${STORAGE_TYPE}" == "nfs" ]]; then
  IMPORT_OPT="-format qcow2"
fi

# Create VM using the "importovf"
info "Importing OVA..."
qm importovf "${VMID}" \
  RaspberryMatic.ovf \
  "${STORAGE}" \
  ${IMPORT_OPT} >>${LOGFILE} 2>&1

# get the assigned disk id after the import
DISK_ID=$(qm config "${VMID}" 2>>${LOGFILE} | grep -e "\(sata\|scsi\).:" | cut -d' ' -f2 | cut -d',' -f1)

# Change settings of VM
info "Modifying VM setting..."
qm set "${VMID}" \
  --acpi 1 \
  --vcpus 2 \
  --numa 1 \
  --agent 1,fstrim_cloned_disks=1,type=virtio \
  --hotplug network,disk,usb,cpu,memory \
  --description "RaspberryMatic CCU" \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --onboot 1 \
  --tablet 0 \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --delete sata0 \
  --scsi0 "${DISK_ID},discard=on,iothread=1" >>${LOGFILE} 2>&1

# Set boot order 
qm set "${VMID}" \
  --boot order=scsi0 >>${LOGFILE} 2>&1

# Resize scsi0 disk
info "Resizing disk..."
qm resize "${VMID}" scsi0 64G >>${LOGFILE} 2>&1

# Identify+Set known USB-based RF module devices
if [[ -n "${USB_DEVICE}" ]]; then
  info "Setting ${USB_DEVICE} as usb0..."
  qm set "${VMID}" --usb0 host="${USB_DEVICE}",usb3=1 >>${LOGFILE} 2>&1
fi

info "Completed Successfully. New VM is: \e[1m${VMID} (RaspberryMatic)\e[0m."
