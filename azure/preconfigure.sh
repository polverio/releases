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

cat <<EOF | sudo tee /var/lib/cloud/scripts/vendor/instance.sh
#!/bin/sh 
sudo sh /var/lib/polverio/activate.sh
EOF

chmod 0755 /var/lib/cloud/scripts/vendor/instance.sh

# move scripts-vendor into the init phase when networking is present
cat /var/cloud/cloud.cfg | sed "s/-\ ssh$/-\ ssh\\n\ -\ scripts-vendor/g" | sudo tee /var/cloud/cloud.cfg

# generalize the image
# sudo waagent -deprovision+user --force