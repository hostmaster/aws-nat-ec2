#!/bin/bash
# NAT instance bootstrap (user-data). Cloud-init only runs this once, on
# first boot, which would drop the iptables MASQUERADE rule on a later
# plain reboot. So the actual NAT setup lives in a systemd oneshot unit
# that reapplies it on every boot; this script just installs and enables
# that unit, then handles the one-time AWS-side setup below it.
set -euo pipefail

# Fetch a fresh token per call instead of threading one through the
# script — a 60s ttl is plenty for a single request. -f so a bad HTTP
# status (e.g. a stale/rejected token) fails the curl instead of
# returning the error body as if it were the token/metadata value.
# Invoked indirectly via retry()'s "$@", which shellcheck can't trace.
# shellcheck disable=SC2329
imds() {
  local token
  token=$(curl -sS -f -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  curl -sS -f -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$1"
}

retry() {
  local max_attempts=5 attempt=1 delay=2
  until "$@"; do
    if ((attempt >= max_attempts)); then
      echo "giving up after $attempt attempts: $*" >&2
      return 1
    fi
    echo "attempt $attempt failed: $*; retrying in $delay seconds" >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# Tracks whether any step below ultimately fails, so cloud-init's own
# exit status stays truthful even though later steps still run.
FAILED=0

# Stock AL2023 ships neither iptables nor nft. Retried: on nano-class
# instances, dnf's transaction has been observed losing the OOM-killer
# lottery against chronyd/sshd-keygen/cloud-init during early boot; a
# short retry lets that contention clear.
if ! retry dnf install -y iptables-nft; then
  FAILED=1
fi

install -d -m 0755 /usr/local/sbin

cat >/usr/local/sbin/nat-setup.sh <<'NAT_SETUP'
#!/bin/bash
set -euo pipefail

IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')

sysctl -w net.ipv4.ip_forward=1
sysctl -w "net.ipv4.conf.$IFACE.rp_filter=0"

cat >/etc/sysctl.d/99-nat-instance.conf <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv4.conf.$IFACE.rp_filter = 0
SYSCTL

iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
NAT_SETUP
chmod 0755 /usr/local/sbin/nat-setup.sh

cat >/etc/systemd/system/nat-setup.service <<'UNIT'
[Unit]
Description=NAT instance setup (IP forwarding + MASQUERADE)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nat-setup.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# Guarded like the steps below: if iptables failed to install above,
# nat-setup.sh fails and this returns non-zero. Left bare, that would
# trip set -e and take down everything after it, including the EIP and
# route-table steps that have nothing to do with iptables.
if ! systemctl enable --now nat-setup.service; then
  FAILED=1
fi

# Three independent, self-healing steps follow (source/dest check, EIP
# association, route repoint). None depends on another, so each uses
# `if ! retry ...` rather than a bare `retry ...` — one exhausting its
# attempts must not stop the others from being attempted too.
#
# INSTANCE_ID/REGION are the one thing all three steps genuinely do
# depend on, so unlike those three, retrying here is not optional: a
# bare `imds` call with no retry would let a single transient IMDS
# hiccup (same nano-class boot contention already seen with dnf) abort
# the whole script via `set -e` before any of the three steps run at
# all. If retries are exhausted here, there's truly nothing downstream
# that can succeed either, so letting the script exit non-zero (rather
# than limping on with an empty instance ID) is intentional.
INSTANCE_ID=$(retry imds instance-id)
REGION=$(retry imds placement/region)

# aws_launch_template has no argument for this, so it's disabled here
# instead of declaratively — required for the instance to forward
# traffic that isn't addressed to itself.
if ! retry aws ec2 modify-instance-attribute \
  --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --no-source-dest-check; then
  FAILED=1
fi

# EIP association is AWS-side state, unaffected by a plain reboot —
# unlike the iptables rule above, this only needs to run once.
if ! retry aws ec2 associate-address \
  --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --allocation-id "${eip_allocation_id}" \
  --allow-reassociation; then
  FAILED=1
fi

# Route table IDs arrive as one comma-separated string. ${route_table_ids}
# is substituted by templatefile() before bash ever parses this file, so
# the token left behind has no leading $ — IFS word-splitting only fires
# on the *result* of a bash expansion, never on a literal token, so
# `for RTB_ID in ${route_table_ids}` ran exactly once with the whole
# comma-joined string as a single, invalid --route-table-id value.
# Assigning it to a real bash variable first forces the split to happen
# where IFS actually applies.
route_table_ids_csv="${route_table_ids}"
IFS=',' read -ra route_table_id_list <<<"$route_table_ids_csv"
for RTB_ID in "$${route_table_id_list[@]}"; do
  # A route table with no pre-existing 0.0.0.0/0 route (first-ever launch
  # into it, e.g. a from-scratch deploy) rejects ReplaceRoute with
  # InvalidParameterValue ("Use CreateRoute instead"); try CreateRoute
  # once, cheaply, before falling back to the retried ReplaceRoute that
  # handles every later reboot/failover, where the route already exists.
  if aws ec2 create-route \
    --region "$REGION" \
    --route-table-id "$RTB_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --instance-id "$INSTANCE_ID" >/dev/null 2>&1; then
    continue
  fi
  if ! retry aws ec2 replace-route \
    --region "$REGION" \
    --route-table-id "$RTB_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --instance-id "$INSTANCE_ID"; then
    FAILED=1
  fi
done

exit "$FAILED"
