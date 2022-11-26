#!/bin/sh 

tdnf upgrade --refresh -y 
mkdir -p /var/lib/polverio

cat <<EOF | sudo tee /var/lib/polverio/activate.sh
#!/bin/sh 

if [[ ! -f /.kubelift ]] ; then
  curl https://raw.githubusercontent.com/polverio/releases/main/azure/prereqs.sh | sudo tee /var/lib/polverio/prereqs.sh
  sudo sh /var/lib/polverio/prereqs.sh 
  sudo touch /.kubelift
  sudo chmod 777 /.kubelift
  sudo crontab -r
fi
EOF

cat <<EOF | sudo tee /var/lib/cloud/scripts/per-instance/instance.sh
#!/bin/sh 
sudo sh /var/lib/polverio/activate.sh
EOF

chmod 0755 /var/lib/cloud/scripts/per-instance/instance.sh

# generalize the image
# sudo waagent -deprovision+user --force