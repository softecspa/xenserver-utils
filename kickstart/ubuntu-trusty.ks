############################################
# Ubuntu 14.04 LTS kickstart for XenServer #
# branch: develop                          #
############################################

# Install, not upgrade
install

# Install from a friendly mirror and add updates
url --url http://it.archive.ubuntu.com/ubuntu/

# Language and keyboard setup
lang it_IT
langsupport it_IT
keyboard it

# Configure networking

# for STATIC IP: uncomment and configure
# network --device=eth0 --bootproto=static --ip=192.168.###.### --netmask=255.255.255.0 --gateway=192.168.###.### --nameserver=###.###.###.### --noipv6 --hostname=$$$

# for DHCP:
network --bootproto=dhcp --device=eth0

firewall --enabled --ssh

# Set timezone
timezone --utc Europe/Rome

# Authentication
rootpw --disabled
user softec --fullname "Softec User" --iscrypted --password $6$xfddzJfIv3$lGspe/Mgc5NlvdvL9BPgGM6bwVgMlik961EcHDjtY4A9vyiODFpPQThcsPN9zq3MS7aD/2QB3fHTU83tKj.M1/
user ubuntu --fullname "Ubuntu User" --iscrypted --password $6$aPcJwKYDIg6u6El$lBOJN36DmkdDWx3chBGV/V5.6OWx71kKQ8IbZ/WLGcHYbAyM36CxDQTjhjuGaim1Agsd2naRHY2PRX/AWl8go1
auth --useshadow

# Disable anything graphical
skipx
text

# Setup the disk

#zerombr yes
#clearpart --all
#part /boot --fstype=ext3 --size=256 --asprimary
#part swap --size 1024
#part / --fstype=ext4 --grow --size=6144 --asprimary
#bootloader --location=mbr

d-i partman-auto/choose_recipe select swap-root
d-i partman-auto/disk string /dev/xvda
d-i partman-auto/method string lvm
d-i partman-auto-lvm/guided_size string 90%

d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-auto-lvm/no_boot boolean true

d-i partman-auto-lvm/new_vg_name string vg_mainvg

d-i partman-auto/expert_recipe string               \
    swap-root ::                                    \
    1024 1024 1024 linux-swap method{ swap }        \
    format{ } $lvmok{ } lv_name{ lv_swap }          \
    .                                               \
    1 10240 10000000000 ext4 method{ lvm }          \
    $lvmok{ } mountpoint{ / } lv_name{ lv_root }    \
    format{ } use_filesystem{ } filesystem{ ext4 }  \
    .
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-lvm/confirm boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select Finish
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm boolean true

# Shutdown when the kickstart is done
halt

# Minimal package set
%packages

ubuntu-minimal
openssh-server
screen
curl
wget
xenstore-utils
linux-image-virtual
puppet-common
git-core

%post

#!/bin/sh
echo -n "Minimizing kernel"
apt-get install -f -y linux-virtual
apt-get remove -y linux-firmware
dpkg -l | grep extra | grep linux | awk '{print $2}' | xargs apt-get remove -y
echo .

echo -n "/etc/fstab fixes"
# update fstab for the root partition
perl -pi -e 's/(errors=remount-ro)/noatime,nodiratime,$1,barrier=0/' /etc/fstab
echo .

echo -n "Network fixes"
# For cloud images, 'eth0' _is_ the predictable device name, since
# we don't want to be tied to specific virtual (!) hardware
rm -f /etc/udev/rules.d/70*
ln -s /dev/null /etc/udev/rules.d/80-net-name-slot.rules
echo .

# generic localhost names
echo "localhost.localdomain" > /etc/hostname
echo .
cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6

EOF
echo .

# utility scripts
echo -n "Utility scripts"
wget -O /opt/domu-hostname.sh https://github.com/frederickding/xenserver-kickstart/raw/develop/opt/domu-hostname.sh
chmod +x /opt/domu-hostname.sh
echo .
wget -O /opt/generate-sshd-keys.sh https://github.com/frederickding/xenserver-kickstart/raw/develop/opt/generate-sshd-keys.sh
chmod +x /opt/generate-sshd-keys.sh
echo .

# generalization
echo -n "Generalizing"
apt-get -qq -y autoremove
apt-get clean
rm -f /etc/ssh/ssh_host_*
rm -f /var/cache/apt/archives/*.deb
rm -f /var/cache/apt/*cache.bin
rm -f /var/lib/apt/lists/*_Packages
echo .

%end
