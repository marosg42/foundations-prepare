#!/bin/bash

# whether do deploy single node or three node high availability MaaS. 
HA=false  # single infra node

# whether to use proxy
PROXY=false
PROXY_HTTP="http://100.107.0.4:1080"
PROXY_HTTPS="http://100.107.0.4:1080"

# location of log file
LOG=./output.txt
# directory where qcows2 files for VMs will be located
VMs=~/VMs

# There is no big need to change these variables unless you want different IPs
INFRA1=192.168.210.4
INFRA2=192.168.210.5
INFRA3=192.168.210.6
CIDR=192.168.210.0/24
CIDR_bits=24
GW=192.168.210.1

# logging commands and their output
# $1 is a command to execute
logit() {
 echo "***************************************************************************" >> $LOG 2>&1
 date >> $LOG 2>&1
 echo $1 >> $LOG 2>&1
 eval ${1} >> $LOG 2>&1
 uptime >> $LOG 2>&1
 echo "" >> $LOG 2>&1
}

info() {
  echo -n $1
}

ok() {
  GREEN='\033[0;32m'
  NC='\033[0m' # No Color
  printf "${GREEN}OK${NC}\n"
}

echo
echo "******************************************************************************"
echo
echo -n "Going to deploy "
if [ "$HA" = true ] ; then
  echo "3 infra nodes"
else
  echo "1 infra node"
fi
echo
if [ "$PROXY" = true ] ; then
  echo "Going to use proxy"
  echo "  HTTP_PROXY=${PROXY_HTTP}"
  echo "  HTTPS_PROXY=${PROXY_HTTPS}"
else
  echo "No proxy will be configured"
fi
echo
echo "******************************************************************************"
echo

cd
logit "echo \"*** Start ***\"" 
info "Checking user..."
set -e
if [ ${USER} != 'ubuntu' ]; then
  echo "Script must run under user ubuntu"
  logit "echo This is just a dumb script which assumes it runs under user ubuntu"
  return 1
fi
ok

info "Creating ${VMs}..."
mkdir -p ${VMs}
ok

if [ "$PROXY" = true ] ; then
  info "Setting proxy in /etc/environment..."
  cat <<EOF | sudo tee -a /etc/environment >> $LOG 2>&1
http_proxy="${PROXY_HTTP}"
https_proxy="${PROXY_HTTPS}"
no_proxy=127.0.0.1
EOF
  ok
  info "Restarting snapd..."
  sudo systemctl restart snapd
  ok
fi

# install needed packages
logit "echo \"*** packages ***\""
info "Installing necessary packages..."
sudo apt install bridge-utils libvirt-bin qemu-utils virtinst qemu-kvm bind9 bind9utils -y >> $LOG 2>&1
sleep 30
ok

logit "echo \"*** Bind ***\""
info "Configuring bind9..."
cat <<EOF | sudo tee /etc/bind/named.conf.options >> $LOG 2>&1
options {
       directory "/var/cache/bind";
       forwarders {
             127.0.0.53;
       };
       dnssec-validation no;
       auth-nxdomain no;    # conform to RFC1035
       listen-on {${GW};};
       listen-on-v6 { any; };
};
EOF

ok
info "Restarting bind9..."
sudo systemctl restart bind9
ok

# it happened ONCE nested KVM was not allowed, so these three lines are just in case
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=1
echo "options kvm_intel nested=1" | sudo tee -a /etc/modprobe.d/kvm.conf >> $LOG 2>&1
logit "cat /sys/module/kvm_intel/parameters/nested"

# create maasbr0 and setup iptable for NAT and forward
logit "echo \"*** networking ***\""
info "Defining and configuring maasbr0 bridge..."
sudo brctl addbr maasbr0
sudo ip a add ${GW}/${CIDR_bits} dev maasbr0
sudo ip l set maasbr0 up
ok

info "Setting iptables..."
sudo iptables -t nat -A POSTROUTING -s ${CIDR} ! -d ${CIDR} -m comment --comment "network maasbr0" -j MASQUERADE
sudo iptables -t filter -A INPUT -i maasbr0 -p tcp -m tcp --dport 53 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -A INPUT -i maasbr0 -p udp -m udp --dport 53 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -A FORWARD -o maasbr0 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -A FORWARD -i maasbr0 -m comment --comment "network maasbr0" -j ACCEPT
ok

info "Generating ssh keypair..."
# generate keypair
printf 'y\n'|ssh-keygen -t rsa -f ~/.ssh/id_rsa -t rsa -N '' >> $LOG 2>&1
ok

# install multipass, prepare script for creating infra nodes in multipass
logit "echo \"*** multipass ***\""
info "Installing multipass snap..."
sudo snap install multipass --classic --beta >> $LOG 2>&1
sleep 30
ok
if [ "$PROXY" = true ] ; then
  info "Setting proxy for multipass..."
  sudo snap set multipass proxy.http=${PROXY_HTTP} >> $LOG 2>&1
  sudo snap set multipass proxy.https=${PROXY_HTTPS} >> $LOG 2>&1
  ok
  info "Restarting multipass..."
  sudo snap restart multipass >> $LOG 2>&1
  sleep 15
  ok
fi

info "Changing multipass driver..."
sudo snap set multipass driver=LIBVIRT >> $LOG 2>&1
sleep 10
ok

logit "brctl show"

brctl show|grep mpvirtbr0 >> $LOG 2>&1

if [ $? != 0 ] ; then
  logit "echo It sucks"
  info "mpvirtbr0 was not created, something is wrong"
  return 1
fi

# multipass cloudinit
logit "echo \"*** create cloudinit ***\""
info "Creating cloudinit..."
PUBKEY=$(cat ~/.ssh/id_rsa.pub)
cat <<EOF | tee cloudinit.yaml >> $LOG 2>&1
package_update: true
package_upgrade: true
packages:
 - bridge-utils
 - qemu-kvm
 - libvirt-bin
ssh_authorized_keys:
 - ${PUBKEY}
users:
 - name: ubuntu
   sudo: ALL=(ALL) NOPASSWD:ALL
   home: /home/ubuntu
   shell: /bin/bash
   groups: [adm, audio, cdrom, dialout, floppy, video, plugdev, dip, netdev, libvirtd]
   lock_passwd: True
   gecos: Ubuntu
   ssh_authorized_keys:
     - ${PUBKEY}
EOF
ok

logit  "cat cloudinit.yaml"

logit "echo \"*** create define_infra script ***\""

info "Creating define_infra script..."

cat <<EOF | tee define_infra.sh >> $LOG 2>&1
#!/bin/bash
# \$1 name
# \$2 IP

# trick to avoid multipass asking interactive question about statistics at random times
exec 0<&-

HOST=\$1
multipass launch 18.04 -c 4 -d 50G -m 8G --cloud-init cloudinit.yaml -n \${HOST}
sleep 5
multipass.virsh attach-interface \${HOST} bridge maasbr0 --config --live
interface=\$(multipass exec \${HOST} -- ip l|grep ens|grep DOWN|head -n 1|awk '{print \$2}'|sed "s/\://")
multipass exec \${HOST} -- bash -c "echo \"network: {config: disabled}\"| sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
multipass exec \${HOST} -- bash -c "echo \"network:
 version: 2
 renderer: networkd
 ethernets:
   \${interface}:
     dhcp4: False
 bridges:   
   broam:   
     interfaces: [\${interface}]   
     dhcp4: False   
     dhcp6: False   
     addresses: [\${2}/${CIDR_bits}]
     gateway4: ${GW}
     nameservers:
       addresses: [${GW}]
     parameters:   
       stp: false   
       forward-delay: 0
\"|sudo tee /etc/netplan/51-fce.yaml"  

multipass exec \${HOST} -- sudo netplan apply
sleep 10
ping -c 5 \$2
multipass.virsh reboot \${HOST}
sleep 30
ping -c 5 \$2
EOF
ok

logit "cat define_infra.sh"
chmod +x define_infra.sh

# call the script to create three infra nodes
logit "echo \"*** define infras ***\""
logit "echo \"*** define infra1 ***\""
info "Defining infra1, this will take couple of minutes..."
./define_infra.sh infra1 ${INFRA1} >> $LOG 2>&1
logit "echo return code $?"
ok
if [ "$HA" = true ] ; then
  logit "echo \"*** define infra2 ***\""
  info "Defining infra2, this will take couple of minutes..."
  ./define_infra.sh infra2 ${INFRA2} >> $LOG 2>&1
  logit "echo return code $?"
  ok
  logit "echo \"*** define infra3 ***\""
  info "Defining infra3, this will take couple of minutes..."
  ./define_infra.sh infra3 ${INFRA3} >> $LOG 2>&1
  logit "echo return code $?"
  ok
fi

# let things settle down, some time for ssh start etc
# becasue from time to time it is not up yet
sleep 15

logit "multipass list"

# setup ssh keys as needed
PUBKEY=$(cat .ssh/id_rsa.pub)

if [ "$HA" = true ] ; then
  INFRAS="${INFRA1} ${INFRA2} ${INFRA3}"
else
  INFRAS="${INFRA1}"
fi

if [ "$PROXY" = true ] ; then
  logit "echo Adding proxy to infras"
  info "Adding proxy to infras..."
  for i in ${INFRAS} ; do echo http_proxy=\"${PROXY_HTTP}\"|ssh -o StrictHostKeyChecking=no ${i} "cat - |sudo tee -a /etc/environment"; done >> $LOG 2>&1
  for i in ${INFRAS} ; do echo https_proxy=\"${PROXY_HTTPS}\"|ssh -o StrictHostKeyChecking=no ${i} "cat - |sudo tee -a /etc/environment"; done >> $LOG 2>&1
  ok
fi

info "Setting ssh stuff..."
logit "echo allow connection from host to ubuntu on infras"
# allow connection from host to ubuntu on infras
for i in ${INFRAS}  ; do echo "${PUBKEY}" |ssh -o StrictHostKeyChecking=no ${i} "cat - >> /home/ubuntu/.ssh/authorized_keys"; done >> $LOG 2>&1
logit "echo allow connection from host to root on infras"
# allow connection from host to root on infras (TODO - needed?)
for i in ${INFRAS} ; do echo "${PUBKEY}" |ssh -o StrictHostKeyChecking=no ${i} "cat - |sudo tee -a /root/.ssh/authorized_keys"; done >> $LOG 2>&1
logit "echo get ubuntu public key from infras"
# get ubuntu public key from infras
for i in ${INFRAS} ; do ssh -o StrictHostKeyChecking=no ${i} "printf 'y\n'|ssh-keygen -t rsa -f /home/ubuntu/.ssh/id_rsa -t rsa -N '' >>/dev/null 2>&1  ; cat /home/ubuntu/.ssh/id_rsa.pub"; done > ubuntukeyinfra 
logit "echo allow ubuntu from infras to logon to host"
# allow ubuntu from infras to logon to host
cat ubuntukeyinfra >> ~/.ssh/authorized_keys
logit "echo establish first conection from infras to host so that it does not ask next time" 
# establish first conection from infras to host so that it does not ask next time
for i in ${INFRAS} ; do ssh ${i} "printf 'yes\n'|ssh -o StrictHostKeyChecking=no ubuntu@${GW} hostname"; done >> $LOG 2>&1
ok

# define VMs for FCE
logit "echo \"*** define VMs ***\""

cat <<EOF |tee define_VMs.sh >> $LOG 2>&1
#!/bin/bash
define() {
# \$1 name
# \$2 id
# \$3 memory
# \$4 - \$8 unique MAC

CPUOPTS="--cpu host"
GRAPHICS="--graphics vnc --video=cirrus"
CONTROLLER="--controller scsi,model=virtio-scsi,index=0"
DISKOPTS="format=qcow2,bus=scsi,cache=writeback"
export CPUOPTS GRAPHICS CONTROLLER DISKOPTS

qemu-img create -f qcow2 ${VMs}/\${1}\${2}d1.qcow2 60G
qemu-img create -f qcow2 ${VMs}/\${1}\${2}d2.qcow2 20G
qemu-img create -f qcow2 ${VMs}/\${1}\${2}d3.qcow2 20G

virt-install --noautoconsole --print-xml --boot network,hd,menu=on \
\$GRAPHICS \$CONTROLLER --name \${1}\${2} --ram \$3 --vcpus 2 \$CPUOPTS \
--disk path=${VMs}/\${1}\${2}d1.qcow2,size=60,\$DISKOPTS \
--disk path=${VMs}/\${1}\${2}d2.qcow2,size=20,\$DISKOPTS \
--disk path=${VMs}/\${1}\${2}d3.qcow2,size=20,\$DISKOPTS \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:1\${2},model=virtio \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:2\${2},model=virtio \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:3\${2},model=virtio \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:4\${2},model=virtio \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:5\${2},model=virtio \
> \${1}\${2}.xml

virsh define \${1}\${2}.xml
}

for i in \$(seq 1 9); do
  define fe \${i} 4096 \$(date +"%y %m %H %M %S")
done
EOF

logit "cat define_VMs.sh"
info "Creating VMs..."
chmod +x define_VMs.sh 

# sudo becasue some weird change in libvirt in 18.04
sudo ./define_VMs.sh >> $LOG 2>&1
logit "echo return code $?"
sleep 30
ok

logit "ls -l"

printf 'y\n'|ssh-keygen -t rsa -f id_rsa_persistent -t rsa -N '' >> $LOG 2>&1
cat id_rsa_persistent.pub >> ~/.ssh/authorized_keys
echo "IdentityFile ~/.ssh/id_rsa" > sshconfig; echo "IdentityFile ~/.ssh/id_rsa_persistent" >> sshconfig

ssh-keyscan -H ${INFRA1} >> ~/.ssh/known_hosts >> $LOG 2>&1
if [ "$HA" = true ] ; then
  ssh-keyscan -H ${INFRA1} >> ~/.ssh/known_hosts >> $LOG 2>&1
  ssh-keyscan -H ${INFRA1} >> ~/.ssh/known_hosts >> $LOG 2>&1
fi

echo "******************************************************************************"
multipass list
virsh list --all

echo
echo "*******************************************************************************************************"
echo "* When you clone cpe-deployments, copy ssh config and id_rsa_persistent* to that directory            *"
echo "* Also run git config user.name \"Chuck Norris\"; git config user.email chuck.norris@norris.chuck there *"
echo "*******************************************************************************************************"
echo
