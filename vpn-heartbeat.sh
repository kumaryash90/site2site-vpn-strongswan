#!/bin/bash
while true; do
	ping -c 1 -W 2 <AWSSERVERA_PRIVATE_IP> > /dev/null 2>&1
	sleep 5
done
