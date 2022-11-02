#!/bin/bash

if [[ -f /home/ec2-user/environment/bootstrap.log ]]; then
    exit 1
fi

set -x
exec >/home/ec2-user/environment/bootstrap.log; exec 2>&1

sudo yum -y -q install jq sssd realmd oddjob oddjob-mkhomedir adcli samba-common samba-common-tools krb5-workstation openldap-clients policycoreutils-python
sudo chown -R ec2-user:ec2-user /home/ec2-user/
#source cluster profile and move to the home dir
cd /home/ec2-user/environment
. cluster_env

#needed to join the domain
IPS=$(aws ds describe-directories --directory-id "${AD_ID}" --query 'DirectoryDescriptions[*].DnsIpAddrs' --output text)
ADName=$(aws ds describe-directories --directory-id "${AD_ID}" --query 'DirectoryDescriptions[*].Name' --output text)
export IP_AD1=$(echo "${IPS}" | awk '{print $1}')
export IP_AD2=$(echo "${IPS}" | awk '{print $2}')

export DC0=$(echo "${ADName}" | awk -F'.' '{print $1}')
export DC1=$(echo "${ADName}" | awk -F'.' '{print $2}')
export DC2=$(echo "${ADName}" | awk -F'.' '{print $3}')
export OU=${DC0^^}

ADMIN_PW=$(aws secretsmanager get-secret-value --secret-id "hpc-1click-${CLUSTER_NAME}-AD" --query SecretString --output text --region "${AWS_REGION_NAME}")
ROU_PW=$(aws secretsmanager get-secret-value --secret-id "hpc-1click-${CLUSTER_NAME}-ROU" --query SecretString --output text --region "${AWS_REGION_NAME}")
export SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "hpc-1click-${CLUSTER_NAME}-AD" --query ARN --output text --region "${AWS_REGION_NAME}")

sudo cp /etc/resolv.conf /etc/resolv.conf.OK
echo ";Generated by Cloud9-Bootstrap.sh" | sudo tee /etc/resolv.conf
echo ";search ${ADName}" | sudo tee -a /etc/resolv.conf
for IP in ${IPS}
do
	echo "${IP} ${ADName}" | sudo tee -a /etc/hosts
	echo "nameserver ${IP}" | sudo tee -a /etc/resolv.conf
done
echo "${ADMIN_PW}" | sudo realm join -U Admin ${ADName}

if [[ $CUSTOMAD == "false" ]];then
  echo "${ADMIN_PW}" | adcli create-user -x -U Admin --domain=${ADName} --display-name=ReadOnlyUser ReadOnlyUser
  echo "${ADMIN_PW}" | adcli create-user -x -U Admin --domain=${ADName} --display-name=user000 user000
  aws ds reset-user-password --directory-id "${AD_ID}" --user-name "ReadOnlyUser" --new-password "${ROU_PW}" --region "${AWS_REGION_NAME}"
  aws ds reset-user-password --directory-id "${AD_ID}" --user-name "user000" --new-password "${ROU_PW}" --region "${AWS_REGION_NAME}"
fi

sudo cp /etc/resolv.conf.OK /etc/resolv.conf

#install Lustre client
sudo amazon-linux-extras install -y lustre2.10 > /dev/null 2>&1
python3 -m pip install "aws-parallelcluster" --user --upgrade --quiet


curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash
chmod ug+x ~/.nvm/nvm.sh
source ~/.nvm/nvm.sh > /dev/null 2>&1
nvm install 17.9.1 > /dev/null 2>&1
node --version


if [[ $FSX_ID == "AUTO" ]];then
FSX=$(cat <<EOF
  - MountDir: /fsx
    Name: new
    StorageType: FsxLustre
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      DataCompressionType: LZ4
EOF
)
else
FSX=$(cat <<EOF
  - MountDir: /fsx
    Name: existing
    StorageType: FsxLustre
    FsxLustreSettings:
      FileSystemId: ${FSX_ID}
EOF
)
fi
export FSX

if [[ $PRIVATE_SUBNET_ID == "NONE" ]];then
  export SUBNET_ID="${PUBLIC_SUBNET_ID}"
  export USE_PUBLIC_IPS='true'
  echo "export SUBNET_ID=\"${PUBLIC_SUBNET_ID}\"" >> cluster_env
  echo "export USE_PUBLIC_IPS='true'" >> cluster_env

  export HN_SUBNET_ID="${PUBLIC_SUBNET_ID}"
else
  export SUBNET_ID="${PRIVATE_SUBNET_ID}"
  export USE_PUBLIC_IPS='false'
  echo "export SUBNET_ID=\"${PRIVATE_SUBNET_ID}\"" >> cluster_env
  echo "export USE_PUBLIC_IPS='false'" >> cluster_env
  
  export HN_SUBNET_ID="${PUBLIC_SUBNET_ID}"
fi

/usr/bin/envsubst < "stability-hpc/parallelcluster/config.${AWS_REGION_NAME}.sample.yaml" > config.${AWS_REGION_NAME}.yaml
/usr/bin/envsubst < "stability-hpc/modules/50.install.capacity.reservation.pool.sh" > 50.install.capacity.reservation.pool.sh

#in case we use custom ODCR group
sed -i -e "s/${CLUSTER_NAME}-ODCR-Group/$ODCRGROUP/g" 50.install.capacity.reservation.pool.sh

aws s3 cp --quiet 50.install.capacity.reservation.pool.sh "s3://${S3_BUCKET}/1click-hpc/modules/50.install.capacity.reservation.pool.sh" --region "${AWS_REGION_NAME}"

#Create the key pair (remove the existing one if it has the same name)
aws ec2 create-key-pair --key-name ${KEY_PAIR} --query KeyMaterial --output text > /home/ec2-user/.ssh/id_rsa
if [ $? -ne 0 ]; then
    aws ec2 delete-key-pair --key-name ${KEY_PAIR}
    aws ec2 create-key-pair --key-name ${KEY_PAIR} --query KeyMaterial --output text > /home/ec2-user/.ssh/id_rsa
fi
sudo chmod 400 /home/ec2-user/.ssh/id_rsa

#Create the cluster and wait
/home/ec2-user/.local/bin/pcluster create-cluster --cluster-name "hpc-1click-${CLUSTER_NAME}" --cluster-configuration config.${AWS_REGION_NAME}.yaml --rollback-on-failure false --wait >> bootstrap.log

HEADNODE_PRIVATE_IP=$(/home/ec2-user/.local/bin/pcluster describe-cluster --cluster-name "hpc-1click-${CLUSTER_NAME}" | jq -r '.headNode.privateIpAddress')
echo "export HEADNODE_PRIVATE_IP='${HEADNODE_PRIVATE_IP}'" >> cluster_env

# Modify the Message Of The Day
sudo rm -f /etc/update-motd.d/*
sudo aws s3 cp --quiet "s3://${S3_BUCKET}/1click-hpc/scripts/motd"  /etc/update-motd.d/10-HPC --region "${AWS_REGION_NAME}" || exit 1
sudo chmod +x /etc/update-motd.d/10-HPC
echo 'run-parts /etc/update-motd.d' >> /home/ec2-user/.bash_profile

#attach the ParallelCluster SG to the Cloud9 instance (for FSx or NFS)
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
SG_CLOUD9=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query Reservations[*].Instances[*].SecurityGroups[*].GroupId --output text)
SG_HEADNODE=$(aws cloudformation describe-stack-resources --stack-name "hpc-1click-${CLUSTER_NAME}" --logical-resource-id ComputeSecurityGroup --query "StackResources[*].PhysicalResourceId" --output text)
aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --groups $SG_CLOUD9 $SG_HEADNODE

#increase the maximum number of files that can be handled by file watcher,
sudo bash -c 'echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf' && sudo sysctl -p

if [[ $FSX_ID == "AUTO" ]];then
  FSX_ID=$(aws cloudformation describe-stack-resources --stack-name "hpc-1click-${CLUSTER_NAME}" --logical-resource-id FSX0 --query "StackResources[*].PhysicalResourceId" --output text)
fi

FSX_DNS_NAME=$(aws fsx describe-file-systems --file-system-ids $FSX_ID --query "FileSystems[*].DNSName" --output text)
FSX_MOUNT_NAME=$(aws fsx describe-file-systems --file-system-ids $FSX_ID  --query "FileSystems[*].LustreConfiguration.MountName" --output text)

#mount the same FSx created for the HPC Cluster
mkdir fsx
sudo mount -t lustre -o noatime,flock $FSX_DNS_NAME@tcp:/$FSX_MOUNT_NAME fsx
sudo bash -c "echo \"$FSX_DNS_NAME@tcp:/$FSX_MOUNT_NAME /home/ec2-user/environment/fsx lustre defaults,noatime,flock,_netdev 0 0\" >> /etc/fstab"
sudo chmod 755 fsx
sudo chown ec2-user:ec2-user fsx

aws s3 cp --quiet bootstrap.log "s3://${S3_BUCKET}/install.log" --region "${AWS_REGION_NAME}"
aws s3 cp --quiet config.${AWS_REGION_NAME}.yaml "s3://${S3_BUCKET}/config.${AWS_REGION_NAME}.yaml" --region "${AWS_REGION_NAME}"

# send SUCCESFUL to the wait handle
curl -X PUT -H 'Content-Type:' \
    --data-binary "{\"Status\" : \"SUCCESS\",\"Reason\" : \"Configuration Complete\",\"UniqueId\" : \"$HEADNODE_PRIVATE_IP\",\"Data\" : \"$HEADNODE_PRIVATE_IP\"}" \
    "${WAIT_HANDLE}"