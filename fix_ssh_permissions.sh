#! /bin/bash -e

echo -n "Enter the SSH username (Default: 'ec2-user'): "
read ec2user

if [ -z "${ec2user}" ]
  then
  ec2user="ec2-user"
fi

while [ -z "${instance}" ]
  do
  echo -n "Enter the EC2 instance ID ie i-xxxxxxxxxxxxxxxxx: "
  read instance
done

if [[ ! "$instance" =~ ^i-.* ]]
  then
  echo "Invalid EC2 Instance ID specified!"
  echo "Instance ID must be in the form of i-xxxxxxxxxxxxxxxxx"
  exit 1
fi

echo -n "Enter the AWS region where the instance is located (Default: '$AWS_REGION'): "
read region

if [ -z "${region}" ]
  then
  region="$AWS_REGION"
fi

validRegion="0"
for aws_region in `aws ec2 describe-regions --query Regions[*].[RegionName] --output text`
  do
  if [ "${region}" == "${aws_region}" ]
    then
    validRegion="1"
  fi
done

if [ ${validRegion} == 0 ]
  then
  echo "The region '${region}' is not a valid AWS region."
  exit 1
fi

echo "WARNING! By executing this script, you will stop your instance!"
echo "If your instance has a public IP, but not an Elastic IP, you will lose it."
echo "If your instance has instance store volumes, and you have data on them, you will lose that data."
echo
echo "You must also have the following IAM permissions:"
echo " - ec2:DescribeInstanceStatus"
echo " - ec2:DescribeInstanceAttribute"
echo " - ec2:ModifyInstanceAttribute"
echo " - ec2:StopInstances"
echo " - ec2:StartInstances"
echo
echo "Press any key to when ready to begin..."
read response

cat <<EOF | tee userdata.txt
Content-Type: multipart/mixed; boundary="//"
MIME-Version: 1.0

--//
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="cloud-config.txt"

#cloud-config
cloud_final_modules:
- [scripts-user, always]

--//
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="userdata.txt"

#!/bin/bash
cat /etc/ssh/sshd_config
cat /var/log/secure | grep -i ssh | tail -50
ls -ld /etc/ssh /home /home/$ec2user /home/$ec2user/.ssh
ls -l /etc/ssh /home/$ec2user/.ssh
journalctl -n 100 --no-pager -r -u sshd
chmod 755 /etc/ssh
chmod 644 /etc/ssh/*
chmod 600 /etc/ssh/ssh_host_*_key /home/$ec2user/.ssh/authorized_keys
chmod 700 /home/ec2-user/.ssh
chown -R root:root /etc/ssh
chown -R $ec2user:$ec2user /home/$ec2user/.ssh
--//
EOF

echo
echo "Finished generating user data..."

echo "base64 encoding user data..."
base64 userdata.txt >userdata_encoded.txt

echo "Waiting for instance to enter the stopped state..."
aws ec2 stop-instances --instance-ids $instance --region $region && until [ "`aws ec2 describe-instance-status --instance-ids $instance --include-all-instances --query 'InstanceStatuses[*].InstanceState.Name' --region $region --output text 2>/dev/null`" == "stopped" ]; do echo -n "."; sleep 5; done
echo

echo "Backing up any existing user data to userdata_original.txt..."
aws ec2 describe-instance-attribute --instance-id $instance --attribute userData --query "UserData.Value" --region $region --output text >userdata_original.txt

echo "Inserting recover user data..."
aws ec2 modify-instance-attribute --instance-id $instance --attribute userData --value file://userdata_encoded.txt --region $region

echo "Starting instance $instance..."
aws ec2 start-instances --instance-ids $instance --region $region

echo "Waiting for instance to enter the running state..."
until [ "`aws ec2 describe-instance-status --instance-ids $instance --include-all-instances --query 'InstanceStatuses[*].InstanceState.Name' --region $region --output text 2>/dev/null`" == "running" ]; do echo -n "."; sleep 5; done
echo

echo
echo "Instance is now in the running state. Please check SSH access now."

while [ true ]
  do
  echo
  echo -n "Should I remove the user data changes now? y/n: "
  read INPUT

  if [[ "$INPUT" =~ ^([yY]|[nN])$ ]]
    then
    if [[ "$INPUT" =~ ^([yY])$ ]]
      then
      echo "Waiting for instance to enter the stopped state..."
      aws ec2 stop-instances --instance-ids $instance --region $region && until [ "`aws ec2 describe-instance-status --instance-ids $instance --include-all-instances --query 'InstanceStatuses[*].InstanceState.Name' --region $region --output text 2>/dev/null`" == "stopped" ]; do echo -n "."; sleep 5; done
      echo

      echo "Removing recovery user data..."; aws ec2 modify-instance-attribute --instance-id $instance --region $region --user-data Value=

      test -s userdata_original.txt && echo "inserting old user data..." && aws ec2 modify-instance-attribute --instance-id $instance --attribute userData --value file://userdata_original.txt --region $region

      echo "Starting instance $instance..."
      aws ec2 start-instances --instance-ids $instance --region $region

      echo "Waiting for instance to enter the running state..." && until [ "`aws ec2 describe-instance-status --instance-ids $instance --include-all-instances --query 'InstanceStatuses[*].InstanceState.Name' --region $region --output text 2>/dev/null`" == "running" ]; do echo -n "."; sleep 5; done
      echo

      echo
      echo "Instance is now in the running state once again."
      break
    fi
  fi
done

echo "Script execution complete."
