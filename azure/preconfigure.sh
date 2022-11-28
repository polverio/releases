#!/bin/sh 

tdnf upgrade --refresh -y 
mkdir -p /var/lib/polverio

cat <<EOF | sudo tee /var/lib/polverio/activate.sh
#!/bin/sh 

if [[ ! -f /.kubelift ]] ; then
  curl https://raw.githubusercontent.com/polverio/releases/main/azure/prereqs.sh | sudo tee /var/lib/polverio/prereqs.sh
  sudo sh /var/lib/polverio/prereqs.sh 
  sudo touch /.kubelift
fi
EOF

cat <<EOF | sudo tee /var/lib/cloud/scripts/per-instance/instance.sh
#!/bin/sh 
sudo sh /var/lib/polverio/activate.sh
EOF

chmod 0755 /var/lib/cloud/scripts/per-instance/instance.sh

# move scripts-per-instance into the init phase when networking is present
cat /etc/cloud/cloud.cfg | sed "s/-\ ssh$/-\ ssh\\n\ -\ scripts-per-instance/g" | sudo tee /etc/cloud/cloud.cfg

# generalize the image
# sudo waagent -deprovision+user --force