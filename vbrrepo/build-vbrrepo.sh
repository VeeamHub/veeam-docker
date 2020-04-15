#!/bin/bash

# build-vbrrepo.sh
# Version 0.1
# Author: Tom Sightler
# Email: tom.sightler@veeam.com
        
# Reset
nc="\033[0m"
red="\033[0;31m"
green="\033[0;32m"
yellow="\033[0;33m"

echo -e "${green}Welcome to build-vbrrepo!${nc}\n"
echo -e "The goal of this script is to simplify the configuration of this host system"
echo -e "as a secure repository for storing backups for Veeam Backup & Replication.\n"
echo -e "This script is designed and tested on a base install of Ubuntu Server 20.04"
echo -e "and leverages standard Ubuntu features including ZFS, Docker and UFW to create"
echo -e "a very tighly secured repository configuration where Veeam processes are isolated"
echo -e "inside a Docker container and ZVOLs along with ZFS snapshots are used to provide"
echo -e "additional protection against accidental deletions and ransomware.\n"
echo -e "This script will install various packages, configure firewall rules,"
echo -e "and deploy a Docker container for isolating the Veeam services from the host.\n"
echo -e "${green}Information you will need to run this script:${nc}"
echo -e "  1) Name of ZFS Pool for ZVOL creation (this script assumes the ZFS Pool has already been created)"
echo -e "  2) IP address of VBR Server (conatiner SSH access will be restrited to this IP)"
echo -e "  3) IP address/subnet of management servers (host SSH access will be restricted to this IP/subnet)"
echo -e "  4) (Optional) If you want to use a pre-generated SSH public key for authentication to the"
echo -e "     container repo you should do one of the following:"
echo -e "     a) Copy the key to ${yellow}veeam-auth-key.pub${nc} in the same directory as this script"
echo -e "     -- or --"
echo -e "     b) Have the key in a place where you can easly copy and paste into the terminal when prompted."
echo -e "     This step is optional since the script can generate a new key, but in that case you will need"
echo -e "     to copy the generated private key file to the Veeam server and add it to the VBR servers as a"
echo -e "     Linux private key credential.\n"

echo -en "Please enter \"${yellow}yes${nc}\" to proceed: "
read -e proceed
if [[ $proceed != "yes" ]]; then
  echo -e "\n${red}Script execution aborted!${nc}\n"
  exit 2
fi

# Install required updates
echo -e "\n${green}Installing ZFS tools and Docker support...${nc}"
DEBIAN_FRONTEND=noninteractive apt-get -q -y install zfsutils-linux docker.io

# Setup ZVOL for repo storage
echo -e "\n${green}Setting up ZFS for repository storage...${nc}"
echo -e "The docker container will use a ZVOL configured on the ZFS pool for repository storage."
echo -e "The ZVOL will be formatted as XFS and mounted to the container, but not the host."
echo -e "Snapshots will be scheduled to protect the ZVOL and allow reverting the snapshot.\n"
while [ -z $zpool ]; do
  echo -en "Please enter the name of the ZPOOL where you want to ceate the ZVOL: "
  read -e zpoolname
  zpool=$(zpool list -H -p -o name $zpoolname)
  if [ -z $zpool ]; then
    echo -e "${red}ERROR:${nc} Failed to get zpool with name ${yellow}${zpoolname}${nc}, please try again!"
  fi
done
zpoolfreebytes=$(zpool list -H -p -o free $zpool)
let zpoolfree=$zpoolfreebytes/1024/1024/1024
let dssize=$zpoolfree*95/100
let zvolsize=$dssize*65/100
let zvolmaxsize=$dssize*90/100
echo -e "\nZPOOL ${yellow}${zpool}${nc} has ${yellow}${zpoolfree}GB${nc} free space."
echo -e "A dataset named ${yellow}veeam${nc} with ${yellow}${dssize}GB${nc} reserved space in zpool ${yellow}${zpool}${nc} will be created."
echo -e "A ZVOL with the name ${yellow}repo_vol${nc} will be created within this dataset."
echo -e "This approach leaves some unreserved free space in the parent zpool that can be useful for recovery"
echo -e "in cases where an attacker tries to overwrite all backups and uses all available data/snapshot space."
echo -e "in the ${yellow}veeam${nc} dataset\n"
echo -e "This script calculates recommended values for the ZVOL and snapshot space based on zpool free space."
echo -e "It is ${yellow}HIGHLY RECOMMENDED${nc} to use these defaults (ZVOL of 65% of dataset free space)."
echo -e "However the script will allow the creation of a ZVOL that uses up to 90% of the dataset free space."
echo -e "Please be aware that this may not be enough space to store the snapshots and, if the dataset runs"
echo -e "out of space, the repo volume will be taken offline and require manual intervention to return to service.\n"
echo -e "Recommended size of the ZVOL is ${yellow}${zvolsize}GB${nc}, maximum allowed size is ${yellow}${zvolmaxsize}GB${nc}.\n"
while [ -z $inputzvolsize ]; do
    read -e -i "${zvolsize}" -p "Enter the desired size of the repo ZVOL device in GBs: " inputzvolsize
    if [ $inputzvolsize -gt $zvolmaxsize ]; then
      echo -e "\n${red}***ERROR*** ${yellow}ZVOL size cannot be more than ${zvolmaxsize}GB (90% of dataset free space).${nc}\n"
      inputzvolsize=""
    fi
done
zvolsize=$inputzvolsize
echo -e "\nCreating dataset ${yellow}${zpool}/veeam${nc} with quota/reservation of ${yellow}${dssize}GB${nc} on ZPOOL ${yellow}${zpool}${nc}..."
zfs create ${zpool}/veeam
zfs set quota=${dssize}GB reservation=${dssize}GB ${zpool}/veeam
echo -e "Creating ZVOL ${yellow}repo_vol${nc} of size ${yellow}${zvolsize}GB${nc} on dataset ${yellow}${zpool}/veeam${nc}..."
zfs create -b 4096 -V ${zvolsize}GB ${zpool}/veeam/repo_vol
zfs set refreservation=none ${zpool}/veeam/repo_vol
zvoldev="/dev/zvol/${zpool}/veeam/repo_vol"
echo -e "ZVOL ${yellow}${zvolname}${nc} created, formatting with XFS filesytem..."
mkfs.xfs -b size=4096 -m crc=1,reflink=1 $zvoldev
echo -e "ZVOL creation and XFS formatting complete!"

# Generate new or reuse existing SSH keys for docker host
echo -e "\n${green}Configure SSH host keys for docker container...${nc}"
echo -e "SSH keys for authenticating to the container repo are stored in a persistent location on the host."
keypath=/opt/veeam/keys
read -e -i "${keypath}" -p "Enter path to store SSH keys (will be created if it does not exist): " userkeypath
keypath="${userkeypath:-keypath}"

if [ ! -d ${keypath} ]; then
  mkdir -p ${keypath}
fi

if [ -f ${keypath}/ssh_host_rsa_key ]; then
  echo -e "Using existing host key ${keypath}/ssh_host_rsa_key"
else
  echo -e "Generating host key ${keypath}/ssh_host_rsa_key..."
  ssh-keygen -f ${keypath}/ssh_host_rsa_key -N '' -t rsa -C "veeam-docker-hostkey"
fi

if [ -f ${keypath}/ssh_host_ecdsa_key ]; then
  echo -e "Using existing host key ${keypath}/ssh_host_ecdsa_key"
else
  echo -e "Generating host key ${keypath}/ssh_host_ecdsa_key..."
  ssh-keygen -f ${keypath}/ssh_host_ecdsa_key -N '' -t ecdsa -C "veeam-docker-hostkey"
fi

if [ -f ${keypath}/ssh_host_ed25519_key ]; then
  echo -e "Using existing host key ${keypath}/ssh_host_ed25519_key"
else
  echo -e "Generating host key ${keypath}/ssh_host_ed25519_key..."
  ssh-keygen -f ${keypath}/ssh_host_ed25519_key -N '' -t ed25519 -C "veeam-docker-hostkey"
fi

chown root.root ${keypath}/ssh_host_*key*
chmod 600 ${keypath}/ssh_host_*key*
chmod 644 ${keypath}/ssh_host_*key*.pub
pubkeyfile="${keypath}/veeam-auth-key.pub"
echo -e "${green}SSH host keys are configured!${nc}\n"

# Generate new or reuse existing SSH key for Docker veeam user
echo -e "${green}Configure SSH auth key for container veeam user...${nc}"
echo -e "For security purposes, the SSH daemon running in the container will be configured"
echo -e "to accept only SSH public key authentication for the veeam user account."
echo -e "This script provies 3 options for sourcing the key used for authentication:"
echo -e "  1) Generate a new private/public key.  You must copy the private key"
echo -e "     to the Veeam server and add it as a Linux private key credential"
echo -e "  2) Copy and use an existing public key file (by default it looks"
echo -e "     for veeam-auth-key.pub in the current directory)"
echo -e "  3) Use Copy/Paste to provide an existing public key"
echo -e "\n${green}Please select an option below:${nc}"
keyoptions=("Generate new private/public keys for authentication" "Look for existing veeam-auth-key.pub or enter path to public key" "Copy/Paste existing public key" "Quit")
select keyoption in "${keyoptions[@]}"
do
  case $REPLY in
    "1")
      echo -e "${green}Generating a new public/private key...${nc}"
      echo -e "Enter a passphrase or press enter if you do not wish to encrpt the private key"
      echo -e "${yellow}!!! Please note that if you choose to use a passphrase here you must !!!"
      echo -e "!!! enter this passphrase when importing the private key into Veeam. !!!${nc}"
      echo -n "Passphrase (or enter for unencrypted): "
      read -e passphrase
      ssh-keygen -f ./veeam-auth-key -N "${passphrease}" -t rsa -C "veeam-auth-key"
      echo -e "Moving public key file to ${yellow}${pubkeyfile}${nc}"
      mv "./veeam-auth-key.pub" "${pubkeyfile}"
      echo -e "${green}New SSH auth key generated, please copy ${yellow}veeam-auth-key${green} to your Veeam server\nand add it as a Linux private key credential (username = veeam).\nWhen adding this system as a managed server select this credential.${nc}"
      break
      ;;
    "2")
      if [ -f "${pubkeyfile}" ]; then
        echo -e "Found existing public key file ${yellow}${pubkeyfile}${nc}"
      elif [ -f "./veeam-auth-key.pub" ]; then
        echo -e "Found public key file ${yellow}veeam-auth-key.pub${nc} in current directory, moving to ${yellow}${pubkeyfile}${nc}"
        mv "./veeam-auth-key.pub" "${pubkeyfile}"
      else
        while [ ! -f "$pubkeyfile" ]; do
          echo -en "Existing public key file was not found, please enter path to public key: "
          read -e newpubkeyfile
          if [ -f $newpubkeyfile ]; then break; fi
          echo -e "${red}Public key file was not found, please try again...${nc}"
        done
        echo -e "Found public key file ${yellow}${newpubkeyfile}${nc}, copying to ${yellow}${pubkeyfile}${nc}"
        cp "${newpubkeyfile}" "${pubkeyfile}" 
      fi
      break
      ;;
    "3")
      echo -e "Please copy and paste the SSH public key below:"
      read -e pubkeypaste
      echo -e "Storing public key in file ${yellow}${pubkeyfile}${nc}"
      echo "${pubkeypaste}" > ${pubkeyfile}
      break
      ;;
    "4")
      echo "Script aborted!"
      exit 2
      ;;
    *) echo "Invalid option $REPLY";;
  esac
done
echo -e "Using public key file ${yellow}${pubkeyfile}${nc}"

# Pull Docker container
echo -e "\n${green}Pullling Docker repo image from VeeamHub...${nc}"
docker pull veeamhub/vbrrepo:latest

# Start repo container
docker run -itd --restart unless-stopped --name vbrrepo --device ${zvoldev} --mount type=bind,source=${keypath},target=/keys --cap-add SYS_ADMIN --security-opt apparmor:unconfined --network=host -e REPO_VOL=${zvoldev} veeamhub/vbrrepo:latest
