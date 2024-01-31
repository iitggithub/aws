#!/bin/bash -e

# Default values
default_ec2user="ec2-user"
default_aws_region="$AWS_REGION"

# Function to check if a region is valid
function is_valid_region() {
  local input_region="$1"
  local valid_regions=($(aws ec2 describe-regions --query "Regions[*].RegionName" --output text))
  
  for aws_region in "${valid_regions[@]}"; do
    if [ "$input_region" == "$aws_region" ]; then
      return 0  # Valid region
    fi
  done

  return 1  # Invalid region
}

# Function to wait for instance state
function wait_for_instance_state() {
  local instance_id="$1"
  local target_state="$2"

  until [ "$(aws ec2 describe-instance-status --instance-ids "$instance_id" --include-all-instances --query "InstanceStatuses[*].InstanceState.Name" --region "$region" --output text 2>/dev/null)" == "$target_state" ]; do
    echo -n "."
    sleep 5
  done
}

# Input prompts
read -p "Enter the SSH username (Default: '$default_ec2user'): " ec2user
ec2user="${ec2user:-$default_ec2user}"

read -p "Enter the EC2 instance ID (e.g., i-xxxxxxxxxxxxxxxxx): " instance
while [ -z "$instance" ]; do
  read -p "Enter the EC2 instance ID ie i-xxxxxxxxxxxxxxxxx: " instance
done

if [[ ! "$instance" =~ ^i-.* ]]; then
  echo "Invalid EC2 Instance ID specified!"
  echo "Instance ID must be in the form of i-xxxxxxxxxxxxxxxxx"
  exit 1
fi

read -p "Enter the AWS region where the instance is located (Default: '$default_aws_region'): " region
region="${region:-$default_aws_region}"

# Validate the AWS region
if ! is_valid_region "$region"; then
  echo "The region '$region' is not a valid AWS region."
  exit 1
fi

# Warning message
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
read -p "Press Enter when ready to begin..."

# Generate recovery user data
echo "Generating recovery user data..."
echo
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
test -f /var/log/secure && cat /var/log/secure | grep -i ssh | tail -100
test -f /var/log/auth.log && cat /var/log/auth.log | grep -i ssh | tail -100
cat /etc/ssh/sshd_config
ls -ld /etc/ssh /home /home/$ec2user /home/$ec2user/.ssh
ls -l /etc/ssh /home/$ec2user/.ssh
journalctl -n 100 --no-pager -r -u sshd
chmod -c 755 /etc/ssh
chmod -c 644 /etc/ssh/*
chmod -c 600 /etc/ssh/ssh_host_*_key /home/$ec2user/.ssh/authorized_keys
chmod -c 700 /home/ec2-user/.ssh
chown -c -R root:root /etc/ssh
chown -c -R $ec2user:$ec2user /home/$ec2user/.ssh
--//
EOF

echo
echo "Finished generating recovery user data..."

# Base64 encoding recovery user data
echo "Base64 encoding recovery user data..."
base64 userdata.txt >userdata_encoded.txt

# Wait for instance to enter the stopped state
echo "Waiting for instance to enter the stopped state..."
aws ec2 stop-instances --instance-ids "$instance" --region "$region"
wait_for_instance_state "$instance" "stopped"
echo

# Backup any existing user data to userdata_original.txt
echo "Backing up any existing user data to userdata_original.txt..."
aws ec2 describe-instance-attribute --instance-id "$instance" --attribute userData --query "UserData.Value" --region "$region" --output text >userdata_original.txt

# Insert recovery user data
echo "Inserting recovery user data..."
aws ec2 modify-instance-attribute --instance-id "$instance" --attribute userData --value file://userdata_encoded.txt --region "$region"

# Start the instance
echo "Starting instance $instance..."
aws ec2 start-instances --instance-ids "$instance" --region "$region"

# Wait for instance to enter the running state
echo "Waiting for instance to enter the running state..."
wait_for_instance_state "$instance" "running"
echo

echo
echo "Instance is now in the running state. Please check SSH access now."

while true; do
  echo
  read -p "Should I remove the user data changes now? (y/n): " INPUT

  if [[ "$INPUT" =~ ^[yY]$ ]]; then
    echo "Waiting for instance to enter the stopped state..."
    aws ec2 stop-instances --instance-ids "$instance" --region "$region"
    wait_for_instance_state "$instance" "stopped"
    echo

    echo "Removing recovery user data..."
    aws ec2 modify-instance-attribute --instance-id "$instance" --region "$region" --user-data Value=

    if [ -s "userdata_original.txt" ]; then
      echo "Inserting old user data..."
      aws ec2 modify-instance-attribute --instance-id "$instance" --attribute userData --value file://userdata_original.txt --region "$region"
    fi

    echo "Removing temporary files..."
    rm -f userdata_original.txt
    rm -f userdata.txt
    rm -f userdata_encoded.txt

    echo "Starting instance $instance..."
    aws ec2 start-instances --instance-ids "$instance" --region "$region"

    echo "Waiting for instance to enter the running state..."
    wait_for_instance_state "$instance" "running"
    echo

    echo
    echo "Instance is now in the running state once again."
    break
  fi
done

echo "Script execution complete."
