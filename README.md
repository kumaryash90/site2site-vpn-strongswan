# AWS Site-to-Site VPN Lab — strongSwan Edition

A working substitute for [`aws-simple-site2site-vpn`](https://github.com/acantril/learn-cantrill-io-labs/tree/master/aws-simple-site2site-vpn) lab.

**This repo is based on and modifies Adrian Cantrill's original lab, used under its MIT license (see [`LICENSE`](./LICENSE)).**

This README covers all 5 stages so it's usable standalone, but only **Stage 2** actually differs from the original, everything else is identical to the original lab.

## Why

The original lab requires subscribing to the **pfSense AMI on AWS Marketplace**. Some AWS accounts can't complete Marketplace subscriptions — billing-entity restrictions, regional payment issues, or a preference to avoid a paid AMI.

The fix: We swap the Marketplace AMI for a plain Ubuntu instance and configure strongSwan directly, and the rest of the lab's architecture is completely unaffected.

## Architecture

Same as the original — two VPCs simulating a hybrid on-prem/cloud network, connected over a real AWS Site-to-Site VPN:

- **"AWS side"** (`10.16.0.0/16`) — private subnets, an Amazon Linux server (`awsServerA`), VPC endpoints for SSM/S3/etc.
- **"On-prem side"** (`192.168.8.0/21`) — public subnet (`192.168.12.0/24`) + private subnet (`192.168.10.0/24`), a Windows server box, and a dual-homed router instance bridging the two subnets

The only change: the router instance runs **Ubuntu 22.04 + strongSwan** instead of pfSense.

## Repo Contents

| File                                         | Purpose                                                                                           |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `infra.yaml`                                 | Modified CloudFormation template — pfSense AMI parameter replaced with an SSM-resolved Ubuntu AMI |
| `vpn-heartbeat.sh` / `vpn-heartbeat.service` | Keepalive ping service, replicating pfSense's built-in "automatic ping host" feature              |

---

## Stage 1 — Create the Site-to-Site VPN

Identical to the original lab, with one change (see step 5 below):

1. Deploy `infra.yaml` via CloudFormation
2. In the VPC console, create a **Customer Gateway** using the router instance's public IP (CFN output `onpremRouterIP`)
3. Create a **Virtual Private Gateway**, attach it to the AWS-side VPC
4. Create the **VPN Connection** linking them, with static routing to the on-prem CIDR
5. Download the tunnel configuration: pick vendor **"Strongswan"** instead of "pfSense." **Keep this file** — AWS auto-generates two tunnel endpoint IPs and two pre-shared keys (PSKs) as part of creating the VPN connection.

## Stage 2 — Configure the Router (this is the actual substitution)

Here, we configure strongSwan directly on the instance.

**1. Connect to the router instance:** EC2 console → **Instances** → select the router instance → **Connect** → **Session Manager** tab → **Connect**

**2. Install strongSwan and enable IP forwarding:**

```bash
sudo apt-get update && sudo apt-get install -y strongswan
sudo sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sudo sysctl -p
```

**3. Write `/etc/ipsec.conf`** — using the two tunnel endpoints/PSKs from the downloaded config file. We used **policy-based** IPsec (explicit `leftsubnet`/`rightsubnet`) rather than AWS's default VTI/route-based sample, since it maps directly onto pfSense's Phase 2 model and this lab only needs static routing:

Create file:
`/etc/ipsec.conf`

write these contents to the file and save (make sure to replace the placeholders):

```
config setup
	uniqueids=no

conn Tunnel1
	auto=start
	left=<router's private IP on the public subnet ENI>
	leftid=<router's public/EIP address>
	leftsubnet=192.168.10.0/24
	right=<AWS tunnel 1 endpoint, from the downloaded config>
	rightsubnet=10.16.0.0/16
	type=tunnel
	leftauth=psk
	rightauth=psk
	keyexchange=ikev1
	ike=aes128-sha1-modp1024
	ikelifetime=8h
	esp=aes128-sha1-modp1024
	lifetime=1h
	keyingtries=%forever
	dpddelay=10s
	dpdtimeout=30s
	dpdaction=restart

conn Tunnel2
	auto=start
	left=<router's private IP on the public subnet ENI>
	leftid=<router's public/EIP address>
	leftsubnet=192.168.10.0/24
	right=<AWS tunnel 2 endpoint, from the downloaded config>
	rightsubnet=10.16.0.0/16
	type=tunnel
	leftauth=psk
	rightauth=psk
	keyexchange=ikev1
	ike=aes128-sha1-modp1024
	ikelifetime=8h
	esp=aes128-sha1-modp1024
	lifetime=1h
	keyingtries=%forever
	dpddelay=10s
	dpdtimeout=30s
	dpdaction=restart
```

**4. Write `/etc/ipsec.secrets`** with both tunnels' pre-shared keys (look into the downloaded config file from Stage 1, step 5 - look for the `PSK` value under each tunnel):

Create file:
`/etc/ipsec.secrets`

write these contents to the file and save (make sure to replace the placeholders):

```
<router's public/EIP address> <AWS tunnel 1 endpoint> : PSK "<TUNNEL1_PSK>"
<router's public/EIP address> <AWS tunnel 2 endpoint> : PSK "<TUNNEL2_PSK>"
```

Fix file permissions — root-only, since it holds both tunnels' pre-shared keys in plaintext:

```bash
sudo chmod 600 /etc/ipsec.secrets
sudo chown root:root /etc/ipsec.secrets
```

**5. Start strongSwan and verify:**

```bash
sudo systemctl restart strongswan-starter
sudo ipsec status
```

Both tunnels should show `ESTABLISHED`.

**6. Set up the keepalive ping** (replicates pfSense's "automatically ping host" + "periodic keep-alive check").

Create file:
`/usr/local/bin/vpn-heartbeat.sh` (source: this repo's [`vpn-heartbeat.sh`](./vpn-heartbeat.sh)):

```bash
#!/bin/bash
while true; do
	ping -c 1 -W 2 <AWSSERVERA_PRIVATE_IP> > /dev/null 2>&1
	sleep 5
done
```

Create file:
`/etc/systemd/system/vpn-heartbeat.service` (source: this repo's [`vpn-heartbeat.service`](./vpn-heartbeat.service)):

```ini
[Unit]
Description=VPN tunnel keepalive ping to awsServerA
After=network.target strongswan-starter.service

[Service]
ExecStart=/usr/local/bin/vpn-heartbeat.sh
Restart=always

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo chmod +x /usr/local/bin/vpn-heartbeat.sh
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-heartbeat
```

## Stage 3 — Routing & Security Groups

Identical to the original lab — see [Stage 3 instructions](https://github.com/acantril/learn-cantrill-io-labs/blob/master/aws-simple-site2site-vpn/02_LABINSTRUCTIONS/STAGE3.md).

## Stage 4 — Test Connectivity

Identical to the original lab — see [Stage 4 instructions](https://github.com/acantril/learn-cantrill-io-labs/blob/master/aws-simple-site2site-vpn/02_LABINSTRUCTIONS/STAGE4.md).

## Stage 5 — Cleanup

Identical to the original lab — see [Stage 5 instructions](https://github.com/acantril/learn-cantrill-io-labs/blob/master/aws-simple-site2site-vpn/02_LABINSTRUCTIONS/STAGE5.md).

## References

- [strongSwan documentation](https://docs.strongswan.org/)
- [AWS: Customer Gateway devices](https://docs.aws.amazon.com/vpn/latest/s2svpn/your-cgw.html) — AWS's docs on third-party VPN devices connecting to a Site-to-Site VPN
