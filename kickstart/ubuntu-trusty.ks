####################
# Ubuntu kickstart #
# branch: develop  #
####################

# Install, not upgrade
install

# Install from a friendly mirror and add updates
url --url http://it.archive.ubuntu.com/ubuntu/

# Language and keyboard setup
lang it_IT
# FixME: langsupport is deprecated
langsupport it_IT
keyboard it

# Configure Networking

# for STATIC IP: uncomment and configure
# network --device=eth0 --bootproto=static --ip=192.168.###.### --netmask=255.255.255.0 --gateway=192.168.###.### --nameserver=###.###.###.### --noipv6 --hostname=$$$

# for DHCP:
network --bootproto=dhcp --device=eth0

# Configure Firewall
# FixME: not work :-(
#firewall --enabled --ssh

# Set timezone
timezone --utc Europe/Rome

# Authentication
rootpw --disabled
authconfig --passalgo=sha512
user ubuntu --fullname "Ubuntu User" --iscrypted --password $6$aPcJwKYDIg6u6El$lBOJN36DmkdDWx3chBGV/V5.6OWx71kKQ8IbZ/WLGcHYbAyM36CxDQTjhjuGaim1Agsd2naRHY2PRX/AWl8go1

# Disable anything graphical
skipx
text

# Setup the disk
zerombr yes
bootloader --location=mbr
clearpart --all

part pv.01 --size 1 --grow
# --percent and --fsoptions not work :-(
volgroup mainvg pv.01
logvol swap --fstype swap --name=swap --vgname=mainvg --size 1024
logvol / --fstype ext4 --vgname=mainvg --size=6144 --grow --name=root
logvol /var --fstype ext4 --vgname=mainvg --size=1 --grow --name=var

preseed partman-lvm/confirm_nooverwrite boolean true
preseed partman-auto-lvm/no_boot boolean true

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

echo -n "Network fixes"
# For cloud images, 'eth0' _is_ the predictable device name, since
# we don't want to be tied to specific virtual (!) hardware
rm -f /etc/udev/rules.d/70*
ln -s /dev/null /etc/udev/rules.d/80-net-name-slot.rules
echo .

# Generic localhost names
echo "localhost.localdomain" > /etc/hostname
echo .
cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6

EOF
echo .

# Utility scripts
echo -n "Utility scripts"
wget -O /opt/domu-hostname.sh https://github.com/frederickding/xenserver-kickstart/raw/develop/opt/domu-hostname.sh
chmod +x /opt/domu-hostname.sh

# SSH
echo -n "Replacement SSH host keys"
rm -f /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server
echo .

echo -n "SSH keys for r0ot login"
mkdir -p -m0700 /root/.ssh
for u in lorenzococchi nico lorello; do curl -s https://github.com/$u.keys -w '\n' >> /root/.ssh/authorized_keys; done
chmod 0600 /root/.ssh/authorized_keys
echo .

# Generalization
echo -n "Cleaning APT"
apt-get -qq -y autoremove
apt-get clean
rm -f /var/cache/apt/archives/*.deb
rm -f /var/cache/apt/*cache.bin
rm -f /var/lib/apt/lists/*_Packages
echo .

%end
