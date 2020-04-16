#!/bin/bash

# build-vbrrepo.sh
# Version 0.1
# Author: Tom Sightler
# Email: tom.sightler@veeam.com

function valid_ip() {
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# Reset
nc="\033[0m"
red="\033[0;31m"
green="\033[0;32m"
yellow="\033[0;33m"

printf "\n${green}Welcome to build-vbrrepo!${nc}\n"
printf "The goal of this script is to simplify the configuration of this host system\n"
printf "as a secure repository for storing backups for Veeam Backup & Replication.\n"
printf "This script is designed and tested on a base install of Ubuntu Server 20.04\n"
printf "and leverages standard Ubuntu features including ZFS, Docker and UFW to create\n"
printf "a very tighly secured repository configuration where Veeam processes are isolated\n"
printf "inside a Docker container and backups are stored on ZVOLs protected using native\n"
printf "ZFS snapshots for additional protection against accidental deletions and ransomware.\n"
printf "This script will install various packages, configure firewall rules,\n"
printf "and deploy a Docker container for isolating the Veeam services from the host.\n\n"
printf "${green}Information you will need to run this script:${nc}\n"
printf "  1) Name of ZFS Pool for ZVOL creation (this script assumes the ZFS Pool has already been created)\n"
printf "  2) IP address of VBR Server (conatiner SSH access will be restrited to this IP)\n"
printf "  3) IP address/subnet of management servers (host SSH access will be restricted to this IP/subnet)\n"
printf "  4) (Optional) If you want to use a pre-generated SSH public key for authentication to the\n"
printf "     container repo you should do one of the following:\n"
printf "     a) Copy the key to ${yellow}veeam-auth-key.pub${nc} in the same directory as this script\n"
printf "     -- or --\n"
printf "     b) Have the key in a place where you can easly copy and paste into the terminal when prompted.\n"
printf "     This step is optional since the script can generate a new key, but in that case you will need\n"
printf "     to copy the generated private key file to the Veeam server and add it to the VBR servers as a\n"
printf "     Linux private key credential.\n\n"

printf "Please enter \"${yellow}yes${nc}\" to proceed: "
read -e proceed
if [[ $proceed != "yes" ]]; then
  printf "\n${red}Script execution aborted!${nc}\n\n"
  exit 2
fi

# Install required updates
printf "\n${green}Installing ZFS tools and Docker support...${nc}\n"
DEBIAN_FRONTEND=noninteractive apt-get -q -y install zfsutils-linux docker.io

# Setup ZVOL for repo storage
printf "\n${green}Setting up ZFS for repository storage...${nc}\n"
printf "The docker container will use a ZVOL configured on the ZFS pool for repository storage.\n"
printf "The ZVOL will be formatted as XFS and mounted to the container, but not the host.\n"
printf "Snapshots will be scheduled to protect the ZVOL and allow reverting the snapshot.\n\n"
while [ -z $zpool ]; do
  printf "Please enter the name of the ZPOOL where you want to ceate the ZVOL: "
  read -e zpoolname
  zpool=$(zpool list -H -p -o name $zpoolname)
  if [ -z $zpool ]; then
    printf "${red}ERROR:${nc} Failed to get zpool with name ${yellow}${zpoolname}${nc}, please try again!\n"
  fi
done
zpoolfreebytes=$(zpool list -H -p -o free $zpool)
let zpoolfree=$zpoolfreebytes/1024/1024/1024
let dssize=$zpoolfree*95/100
let zvolsize=$dssize*65/100
let zvolmaxsize=$dssize*90/100
printf "\nZPOOL ${yellow}${zpool}${nc} has ${yellow}${zpoolfree}GB${nc} free space.\n"
printf "A dataset named ${yellow}veeam${nc} with ${yellow}${dssize}GB${nc} reserved space in zpool ${yellow}${zpool}${nc} will be created.\n"
printf "A ZVOL with the name ${yellow}repo_vol${nc} will be created within this dataset.\n"
printf "This approach leaves some unreserved free space in the parent zpool that can be useful for recovery\n"
printf "in cases where an attacker tries to overwrite all backups and uses all available data/snapshot space.\n"
printf "in the ${yellow}veeam${nc} dataset\n\n"
printf "This script calculates recommended values for the ZVOL and snapshot space based on zpool free space.\n"
printf "It is ${yellow}HIGHLY RECOMMENDED${nc} to use these defaults (ZVOL of 65% of dataset free space).\n"
printf "However the script will allow the creation of a ZVOL that uses up to 90% of the dataset free space.\n"
printf "Please be aware that this may not be enough space to store the snapshots and, if the dataset runs\n"
printf "out of space, the repo volume will be taken offline and require manual intervention to return to service.\n\n"
printf "Recommended size of the ZVOL is ${yellow}${zvolsize}GB${nc}, maximum allowed size is ${yellow}${zvolmaxsize}GB${nc}.\n\n"
while [ -z $inputzvolsize ]; do
    read -e -i "${zvolsize}" -p "Enter the desired size of the repo ZVOL device in GBs: " inputzvolsize
    if [ $inputzvolsize -gt $zvolmaxsize ]; then
      printf "\n${red}***ERROR*** ${yellow}ZVOL size cannot be more than ${zvolmaxsize}GB (90% of dataset free space).${nc}\n\n"
      inputzvolsize=""
    fi
done
zvolsize=$inputzvolsize
printf "\nCreating dataset ${yellow}${zpool}/veeam${nc} with quota/reservation of ${yellow}${dssize}GB${nc} on ZPOOL ${yellow}${zpool}${nc}...\n"
zfs create ${zpool}/veeam
zfs set quota=${dssize}GB reservation=${dssize}GB ${zpool}/veeam
printf "Creating ZVOL ${yellow}repo_vol${nc} of size ${yellow}${zvolsize}GB${nc} on dataset ${yellow}${zpool}/veeam${nc}...\n"
zfs create -b 4096 -V ${zvolsize}GB ${zpool}/veeam/repo_vol
zfs set refreservation=none ${zpool}/veeam/repo_vol
zvoldev="/dev/zvol/${zpool}/veeam/repo_vol"
printf "ZVOL ${yellow}${zvolname}${nc} created, formatting with XFS filesytem...\n"
mkfs.xfs -b size=4096 -m crc=1,reflink=1 $zvoldev
printf "ZVOL creation and XFS formatting complete!\n"

# Generate new or reuse existing SSH keys for docker host
printf "\n${green}Configure SSH host keys for docker container...${nc}\n"
printf "SSH keys for authenticating to the container repo are stored in a persistent location on the host.\n"
keypath=/opt/veeam/keys
read -e -i "${keypath}" -p "Enter path to store SSH keys (will be created if it does not exist): " userkeypath
keypath="${userkeypath:-keypath}"

if [ ! -d ${keypath} ]; then
  mkdir -p ${keypath}
fi

if [ -f ${keypath}/ssh_host_rsa_key ]; then
  printf "Using existing host key ${keypath}/ssh_host_rsa_key\n"
else
  printf "Generating host key ${keypath}/ssh_host_rsa_key...\n"
  ssh-keygen -f ${keypath}/ssh_host_rsa_key -N '' -t rsa -C "veeam-docker-hostkey"
fi

if [ -f ${keypath}/ssh_host_ecdsa_key ]; then
  printf "Using existing host key ${keypath}/ssh_host_ecdsa_key\n"
else
  printf "Generating host key ${keypath}/ssh_host_ecdsa_key...\n"
  ssh-keygen -f ${keypath}/ssh_host_ecdsa_key -N '' -t ecdsa -C "veeam-docker-hostkey"
fi

if [ -f ${keypath}/ssh_host_ed25519_key ]; then
  printf "Using existing host key ${keypath}/ssh_host_ed25519_key\n"
else
  printf "Generating host key ${keypath}/ssh_host_ed25519_key...\n"
  ssh-keygen -f ${keypath}/ssh_host_ed25519_key -N '' -t ed25519 -C "veeam-docker-hostkey"
fi

chown root.root ${keypath}/ssh_host_*key*
chmod 600 ${keypath}/ssh_host_*key*
chmod 644 ${keypath}/ssh_host_*key*.pub
pubkeyfile="${keypath}/veeam-auth-key.pub"
printf "${green}SSH host keys are configured!${nc}\n\n"

# Generate new or reuse existing SSH key for Docker veeam user
printf "${green}Configure SSH auth key for container veeam user...${nc}\n"
printf "For security purposes, the SSH daemon running in the container will be configured\n"
printf "to accept only SSH public key authentication for the veeam user account.\n"
printf "This script provies 3 options for sourcing the key used for authentication:\n"
printf "  1) Generate a new private/public key.  You must copy the private key\n"
printf "     to the Veeam server and add it as a Linux private key credential\n"
printf "  2) Copy and use an existing public key file (by default it looks\n"
printf "     for veeam-auth-key.pub in the current directory)\n"
printf "  3) Use Copy/Paste to provide an existing public key\n\n"
printf "${green}Please select an option below:${nc}\n"
keyoptions=("Generate new private/public keys for authentication" "Look for existing veeam-auth-key.pub or enter path to public key" "Copy/Paste existing public key" "Quit")
select keyoption in "${keyoptions[@]}"
do
  case $REPLY in
    "1")
      printf "${green}Generating a new public/private key...${nc}\n"
      printf "Enter a passphrase or press enter if you do not wish to encrpt the private key\n"
      printf "${yellow}!!! Please note that if you choose to use a passphrase here you must !!!\n"
      printf "!!! enter this passphrase when importing the private key into Veeam. !!!${nc}\n"
      printf "Passphrase (or enter for unencrypted): "
      read -e passphrase
      ssh-keygen -f ./veeam-auth-key -N "${passphrease}" -t rsa -C "veeam-auth-key"
      printf "Moving public key file to ${yellow}${pubkeyfile}${nc}\n"
      mv "./veeam-auth-key.pub" "${pubkeyfile}"
      printf "${green}New SSH auth key generated, please copy ${yellow}veeam-auth-key${green} to your Veeam server\nand add it as a Linux private key credential (username = veeam).\nWhen adding this system as a managed server select this credential.${nc}\n"
      break
      ;;
    "2")
      if [ -f "${pubkeyfile}" ]; then
        printf "Found existing public key file ${yellow}${pubkeyfile}${nc}\n"
      elif [ -f "./veeam-auth-key.pub" ]; then
        printf "Found public key file ${yellow}veeam-auth-key.pub${nc} in current directory, moving to ${yellow}${pubkeyfile}${nc}\n"
        mv "./veeam-auth-key.pub" "${pubkeyfile}"
      else
        while [ ! -f "$pubkeyfile" ]; do
          printf "Existing public key file was not found, please enter path to public key: "
          read -e newpubkeyfile
          if [ -f $newpubkeyfile ]; then break; fi
          printf "${red}Public key file was not found, please try again...${nc}\n"
        done
        printf "Found public key file ${yellow}${newpubkeyfile}${nc}, copying to ${yellow}${pubkeyfile}${nc}\n"
        cp "${newpubkeyfile}" "${pubkeyfile}" 
      fi
      break
      ;;
    "3")
      printf "Please copy and paste the SSH public key below:\n"
      read -e pubkeypaste
      printf "Storing public key in file ${yellow}${pubkeyfile}${nc}\n"
      printf "${pubkeypaste}" > ${pubkeyfile}
      break
      ;;
    "4")
      printf "Script aborted!\n"
      exit 2
      ;;
    *) printf "Invalid option $REPLY\n";
  esac
done
printf "Using public key file ${yellow}${pubkeyfile}${nc}"

# Pull Docker container
printf "\n${green}Pulling Docker repo image from VeeamHub...${nc}\n"
docker pull veeamhub/vbrrepo:latest

# Start repo container
docker run -itd --restart unless-stopped --name vbrrepo --device ${zvoldev} --mount type=bind,source=${keypath},target=/keys --cap-add SYS_ADMIN --security-opt apparmor:unconfined --network=host -e REPO_VOL=${zvoldev} veeamhub/vbrrepo:latest
printf "Setup of Docker repo is complete.\n\n"

# Install Sanoid to take ZFS snapshots
printf "${green}Installing Sanoid to manage ZFS snapshots...${nc}\n"
wget https://github.com/VeeamHub/veeam-docker/raw/master/vbrrepo/sanoid_2.0.3_all.deb
apt install ./sanoid_2.0.3_all.deb
printf "[${zpool}/veeam/repo_vol]\n  use_template = vbrrepo\n  recursive = yes\n\n" > /etc/sanoid/sanoid.conf
printf "#############################\n# templates below this line #\n#############################\n" >> /etc/sanoid/sanoid.conf
printf "\n[template_vbrrepo]\n  frequently = 32\n  hourly = 48\n  daily = 5\n" >> /etc/sanoid/sanoid.conf
printf "  monthly = 0\n  yearly = 0\n  autosnap = yes\n  autoprune = yes\n" >> /etc/sanoid/sanoid.conf
sudo systemctl enable sanoid.timer
sudo systemctl start sanoid.timer
printf "Sanoid installed and configured.\n\n"

# Install revert vbrrepo script
printf "${green}Installing snapshot revert helper script...${nc}\n"
wget https://github.com/VeeamHub/veeam-docker/raw/master/vbrrepo/vbrrepo-revert.sh
mv ./vbrrepo-revert.sh /usr/local/bin/.
chmod 755 /usr/local/bin/vbrrepo-revert.sh
chown root.root /usr/local/bin/vbrrepo-revert.sh
printf "Snapshot revert helper script installed.\n"

# Setup local firewall rules for UFW
apt install ufw
while [ -z $vbrip ]; do
  read -e -
done

while [ -z $mgmtip ]; do
done
#ufw default deny incoming
#ufw default allow outgoing
#ufw allow ssh
#ufw allow 22222
#ufw allow 2500:3300/tcp

