#!/bin/bash

while [ -z $zpool ]; do
  echo -en "Please enter the name of the ZPOOL where the veeam/repo_vol exist: "
  read -e zpoolname
  zpool=$(zpool list -H -p -o name $zpoolname)
  if [ -z $zpool ]; then
    echo -e "${red}ERROR:${nc} Failed to get zpool with name ${yellow}${zpoolname}${nc}, please try again!"
  fi
done

REPO_VOL=${zpool}/veeam/repo_vol
REPO_DOCKER=vbrrepo

SNAPS=($(zfs list -H -t snapshot -o name $REPO_VOL | sort -r | tail -n 50))

## Show the menu. This will list all files and the string "quit"
select SNAP in "${SNAPS[@]}" "Quit"
do
    case ${SNAP} in
    ${REPO_VOL}*)
        break;
        ;;
    "Quit")
        ## Exit
        exit;;
    *)
        file=""
        echo "Please choose a number from 1 to $((${#SNAPS[@]}+1))";;
    esac
done

echo -n "Stopping ${REPO_DOCKER}..."
docker stop ${REPO_DOCKER}
echo "OK!"

echo -n "Reverting ${REPO_DOCKER} to snapshot ${SNAP}..."
zfs clone -p ${SNAP} ${REPO_VOL}_clone
zfs promote ${REPO_VOL}_clone
zfs rename ${REPO_VOL} ${REPO_VOL}_save
zfs rename ${REPO_VOL}_clone ${REPO_VOL}
echo "OK!" 

echo -n "Starting ${REPO_DOCKER}..."
docker start ${REPO_DOCKER}
echo "OK!"
