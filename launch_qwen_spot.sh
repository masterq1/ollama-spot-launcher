#!/bin/bash
# =============================================================================
# launch_qwen_spot.sh
# Local Launcher — Qwen3-32B Ollama Spot Instance
#
# Purpose:
#   Submits an EC2 Spot Instance Request for a g5.xlarge, injects
#   ec2_userdata.sh as the boot script, retains EBS on termination,
#   and wires up SNS email + Session Manager access.
#
# One-time setup (run once, ever):
#   ./launch_qwen_spot.sh --setup
#
# Normal launch (spot, us-east-1 default):
#   ./launch_qwen_spot.sh
#   ./launch_qwen_spot.sh --spot
#   ./launch_qwen_spot.sh --region us-east-2
#
# On-demand launch:
#   ./launch_qwen_spot.sh --ondemand
#   ./launch_qwen_spot.sh --ondemand --region us-east-2
#
# Check spot availability (no launch) — ranks AZs by fulfillment likelihood:
#   ./launch_qwen_spot.sh --check-spot
#   ./launch_qwen_spot.sh --check-spot --region us-east-2
#
# Auto-pick the best-scoring AZ's subnet for the launch:
#   ./launch_qwen_spot.sh --auto-az
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# ARG PARSING
# ---------------------------------------------------------------------------
LAUNCH_MODE="spot"
REGION="us-east-1"
DO_SETUP=false
DO_CHECK_SPOT=false
AUTO_AZ=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ondemand)   LAUNCH_MODE="ondemand"; shift ;;
        --spot)       LAUNCH_MODE="spot"; shift ;;
        --setup)      DO_SETUP=true; shift ;;
        --check-spot) DO_CHECK_SPOT=true; shift ;;
        --auto-az)    AUTO_AZ=true; shift ;;
        --region)     REGION="$2"; shift 2 ;;
        --region=*)   REGION="${1#--region=}"; shift ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# CONFIG  (all tunables now live in launch.env — see launch.env.example)
#   Instance/spot   : INSTANCE_TYPE, SPOT_MAX_PRICE, SPOT_WAIT_MAX
#   EBS root volume : EBS_SIZE_GB, EBS_TYPE, EBS_IOPS, EBS_THROUGHPUT,
#                     EBS_DELETE_ON_TERMINATION
#   Webhook         : WEBHOOK_PORT, WEBHOOK_WAIT_MAX, WEBHOOK_SECRET_FILE
#   Account-specific: KEY_PAIR/SECURITY_GROUP_ID/SUBNET_ID per region,
#                     INSTANCE_PROFILE, NOTIFY_EMAIL, SNS_TOPIC_NAME, WEBHOOK_URL
#   AMI IDs (public, non-PII) live in this script, keyed by region — not env.
# ---------------------------------------------------------------------------
LAUNCH_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/launch.env"
if [[ ! -f "$LAUNCH_ENV" ]]; then
    echo "ERROR: $LAUNCH_ENV not found. Copy launch.env.example → launch.env and fill in values."
    exit 1
fi
# shellcheck source=launch.env
source "$LAUNCH_ENV"

# Human-readable EBS fate, derived from the env flag, for log/echo lines.
if [[ "${EBS_DELETE_ON_TERMINATION,,}" == "true" ]]; then
    EBS_FATE_DESC="deleted on termination"
else
    EBS_FATE_DESC="retained on termination"
fi

# Select region-specific account vars (PII) from launch.env.
case "$REGION" in
    us-east-1)
        KEY_PAIR="${KEY_PAIR_USE1}"
        SECURITY_GROUP_ID="${SECURITY_GROUP_ID_USE1}"
        SUBNET_ID="${SUBNET_ID_USE1}"          # us-east-1d (subnet-04bb1b2a)
        ;;
    us-east-2)
        KEY_PAIR="${KEY_PAIR_USE2}"
        SECURITY_GROUP_ID="${SECURITY_GROUP_ID_USE2}"
        SUBNET_ID="${SUBNET_ID_USE2}"
        ;;
    *)
        echo "ERROR: Region '$REGION' not configured. Add KEY_PAIR/SECURITY_GROUP_ID/SUBNET_ID _USE* vars to launch.env, and an AMI mapping below."
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# AMI IDs  (public images — NOT PII, kept in code rather than launch.env)
# g5.xlarge Qwen3-32B base AMI per region.
# ---------------------------------------------------------------------------
case "$REGION" in
    us-east-1) AMI_ID="ami-0601d6b9f96c195f3" ;;
    us-east-2) AMI_ID="ami-0f79de63fe71ea29d" ;;
esac
# g5.12xlarge Qwen2.5-72B per-AZ AMIs (fill + wire in when built):
#   us-east-1a: ami-xxxxxxxxxxxxxxxxx   us-east-1b: ami-xxxxxxxxxxxxxxxxx
#   us-east-2a: ami-xxxxxxxxxxxxxxxxx   us-east-2b: ami-xxxxxxxxxxxxxxxxx

# ---------------------------------------------------------------------------
# SPOT AVAILABILITY CHECK  (--check-spot / --auto-az)
# Ranks AZs in $REGION for $INSTANCE_TYPE by Spot Placement Score (AWS's
# likelihood-of-fulfillment metric, 1=worst .. 10=best), annotated with the
# current spot price and whether the AZ even offers the type. Read-only, free.
# rank_spot_azs() emits one "name<TAB>score<TAB>price<TAB>offered" row per AZ,
# sorted score-desc then price-asc. check_spot() prints it and sets BEST_AZ to
# the top offered AZ.
# ---------------------------------------------------------------------------
BEST_AZ=""

rank_spot_azs() {
    local itype="$1"

    # AZ id <-> name map (per account/region) so we can join SPS (ids) to prices (names).
    local az_map offered sps prices
    az_map=$(aws ec2 describe-availability-zones --region "$REGION" \
        --query 'AvailabilityZones[].[ZoneId,ZoneName]' --output text 2>/dev/null || true)

    # AZs (zone names) that actually offer the instance type.
    offered=$(aws ec2 describe-instance-type-offerings --region "$REGION" \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=${itype}" \
        --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null || true)

    # Spot Placement Score per single AZ (returns AZ IDs).
    sps=$(aws ec2 get-spot-placement-scores --region "$REGION" \
        --instance-types "$itype" \
        --target-capacity 1 --target-capacity-unit-type units \
        --single-availability-zone \
        --region-names "$REGION" \
        --query 'SpotPlacementScores[].[AvailabilityZoneId,Score]' --output text 2>/dev/null || true)

    # Latest spot price per AZ name.
    prices=$(aws ec2 describe-spot-price-history --region "$REGION" \
        --instance-types "$itype" --product-descriptions "Linux/UNIX" \
        --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>/dev/null || true)

    printf '%s\n' "$sps" | awk -v azmap="$az_map" -v offered="$offered" -v prices="$prices" '
        BEGIN {
            n=split(azmap, a, /[ \t\n]+/);  for(i=1;i<=n;i+=2) id2name[a[i]]=a[i+1];
            n=split(offered, o, /[ \t\n]+/); for(i=1;i<=n;i++)   off[o[i]]=1;
            n=split(prices, p, /[ \t\n]+/);  for(i=1;i<=n;i+=2)  price[p[i]]=p[i+1];
        }
        $1!="" {
            name=id2name[$1]; if(name=="") name=$1;
            pr=(name in price)?price[name]:"-";
            ofr=(name in off)?"yes":"no";
            printf "%s\t%s\t%s\t%s\n", name, $2, pr, ofr;
        }
    ' | sort -t"$(printf '\t')" -k2,2nr -k3,3n
}

check_spot() {
    echo ""
    echo "Spot availability — ${INSTANCE_TYPE} in ${REGION}  (score 1-10, higher = more likely to fill)"
    printf "  %-16s %-6s %-12s %-8s\n" "AZ" "SCORE" "PRICE/hr" "OFFERED"
    printf "  %-16s %-6s %-12s %-8s\n" "----------------" "-----" "------------" "-------"
    local found=0
    while IFS=$'\t' read -r az score price ofr; do
        [[ -z "$az" ]] && continue
        printf "  %-16s %-6s %-12s %-8s\n" "$az" "$score" "$price" "$ofr"
        if [[ "$found" -eq 0 && "$ofr" == "yes" ]]; then BEST_AZ="$az"; found=1; fi
    done < <(rank_spot_azs "$INSTANCE_TYPE")
    echo ""
    if [[ -n "$BEST_AZ" ]]; then
        echo "  Best bet: ${BEST_AZ}  (your cap SPOT_MAX_PRICE=\$${SPOT_MAX_PRICE}/hr)"
    else
        echo "  No scored/offered AZ returned. Check AWS creds, region, or that ${INSTANCE_TYPE} is available here."
    fi
    echo ""
}

# --check-spot: print the ranking and exit without launching anything.
if [[ "$DO_CHECK_SPOT" == "true" ]]; then
    check_spot
    exit 0
fi

# --auto-az: rank AZs, then swap SUBNET_ID for a subnet in the best AZ that lives
# in the SAME VPC as the configured subnet (no per-AZ subnet config needed).
if [[ "$AUTO_AZ" == "true" ]]; then
    check_spot
    if [[ -n "$BEST_AZ" ]]; then
        VPC_ID=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$SUBNET_ID" \
            --query 'Subnets[0].VpcId' --output text 2>/dev/null || true)
        NEW_SUBNET=$(aws ec2 describe-subnets --region "$REGION" \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=availability-zone,Values=${BEST_AZ}" \
            --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)
        if [[ -n "$NEW_SUBNET" && "$NEW_SUBNET" != "None" ]]; then
            echo "[$(date)] --auto-az: launching in ${BEST_AZ} via subnet ${NEW_SUBNET} (was ${SUBNET_ID})"
            SUBNET_ID="$NEW_SUBNET"
        else
            echo "[$(date)] --auto-az: no subnet for ${BEST_AZ} in VPC ${VPC_ID}; keeping ${SUBNET_ID}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# WEBHOOK CALLBACK CONFIG
# Instance POSTs status (booting, ollama_ready, model_ready, terminating) to
# WEBHOOK_URL. Caddy (port 8080) reverse-proxies /webhook/ollama → the local
# nc listener on WEBHOOK_PORT. Launcher blocks until model_ready arrives.
# WEBHOOK_URL, WEBHOOK_PORT, WEBHOOK_WAIT_MAX, WEBHOOK_SECRET_FILE are loaded
# from launch.env.
# ---------------------------------------------------------------------------
# Load shared secret (env > file), or generate and persist one.
WEBHOOK_SECRET="${WEBHOOK_SECRET:-$(cat "$WEBHOOK_SECRET_FILE" 2>/dev/null || true)}"
if [[ -z "$WEBHOOK_SECRET" ]]; then
    WEBHOOK_SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
    umask 077
    echo "$WEBHOOK_SECRET" > "$WEBHOOK_SECRET_FILE"
    echo "[$(date)] Generated new webhook secret → $WEBHOOK_SECRET_FILE"
fi

# ---------------------------------------------------------------------------
# ONE-TIME SETUP MODE
# Run: ./launch_qwen_spot.sh --setup
# Creates IAM role, instance profile, SNS topic, email subscription.
# Also adds AmazonSSMManagedInstanceCore so Session Manager works.
# ---------------------------------------------------------------------------
if [[ "$DO_SETUP" == "true" ]]; then
    echo "=== Running one-time setup ==="

    # IAM role for self-termination + SSM access
    aws iam create-role \
        --role-name OllamaSpotRole \
        --assume-role-policy-document '{
          "Version":"2012-10-17",
          "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},
          "Action":"sts:AssumeRole"}]}' 2>/dev/null || echo "Role already exists"

    aws iam put-role-policy \
        --role-name OllamaSpotRole \
        --policy-name OllamaSpotPermissions \
        --policy-document '{
          "Version":"2012-10-17",
          "Statement":[
            {"Effect":"Allow","Action":"ec2:TerminateInstances","Resource":"*"},
            {"Effect":"Allow","Action":"ec2:DescribeTags","Resource":"*"},
            {"Effect":"Allow","Action":"sns:Publish","Resource":"*"}
          ]}' 2>/dev/null || echo "Policy already set"

    # Attach SSM managed policy for Session Manager
    aws iam attach-role-policy \
        --role-name OllamaSpotRole \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
        2>/dev/null || echo "SSM policy already attached"

    aws iam create-instance-profile \
        --instance-profile-name OllamaSpotProfile \
        2>/dev/null || echo "Instance profile already exists"

    aws iam add-role-to-instance-profile \
        --instance-profile-name OllamaSpotProfile \
        --role-name OllamaSpotRole \
        2>/dev/null || echo "Role already in profile"

    # SNS topic
    SNS_ARN=$(aws sns create-topic \
        --name "$SNS_TOPIC_NAME" \
        --region "$REGION" \
        --query 'TopicArn' \
        --output text)
    echo "SNS Topic ARN: $SNS_ARN"

    # Subscribe email to topic
    aws sns subscribe \
        --topic-arn "$SNS_ARN" \
        --protocol email \
        --notification-endpoint "$NOTIFY_EMAIL" \
        --region "$REGION"

    echo ""
    echo "=== Setup complete ==="
    echo "IMPORTANT: Check $NOTIFY_EMAIL and confirm the SNS subscription"
    echo "           before launching. Email won't work until confirmed."
    echo "SNS_ARN=$SNS_ARN"
    echo ""
    echo "Save this ARN — it will be auto-detected on future launches."
    exit 0
fi

# ---------------------------------------------------------------------------
# VALIDATE
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERDATA_SCRIPT="${SCRIPT_DIR}/ec2_userdata.sh"

if [[ ! -f "$USERDATA_SCRIPT" ]]; then
    echo "ERROR: ec2_userdata.sh not found at $USERDATA_SCRIPT"
    exit 1
fi

# ---------------------------------------------------------------------------
# LOOK UP SNS TOPIC ARN
# ---------------------------------------------------------------------------
SNS_TOPIC_ARN=$(aws sns list-topics \
    --region "$REGION" \
    --query "Topics[?ends_with(TopicArn, ':${SNS_TOPIC_NAME}')].TopicArn | [0]" \
    --output text 2>/dev/null || echo "")

if [[ -z "$SNS_TOPIC_ARN" || "$SNS_TOPIC_ARN" == "None" ]]; then
    echo "WARNING: SNS topic '$SNS_TOPIC_NAME' not found."
    echo "         Run './launch_qwen_spot.sh --setup' first for email notifications."
    echo "         Continuing without email — connect info will be in the bootstrap log."
    SNS_TOPIC_ARN=""
fi

# ---------------------------------------------------------------------------
# WEBHOOK PREFLIGHT
# Verifies the full callback path (NPM → localhost:WEBHOOK_PORT) before
# spending money on an instance. Starts nc listener in background, POSTs
# through the public URL, confirms 200 back and token received correctly.
# ---------------------------------------------------------------------------
echo "[$(date)] Webhook preflight: testing ${WEBHOOK_URL} → localhost:${WEBHOOK_PORT}..."
_PREFLIGHT_TMP=$(mktemp)
_HTTP_200=$'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{"ok":true}'

# nc in background: writes raw HTTP request to temp file.
( printf '%s' "$_HTTP_200" | nc -l -p "$WEBHOOK_PORT" -q 1 > "$_PREFLIGHT_TMP" 2>/dev/null ) &
_NC_PID=$!
sleep 1  # give nc time to bind

_HTTP_CODE=$(curl -sf -m 10 -o /dev/null -w '%{http_code}' -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -H "X-Webhook-Token: ${WEBHOOK_SECRET}" \
    -d '{"status":"preflight","instance_id":"local-test"}' 2>/dev/null || echo "000")

wait "$_NC_PID" 2>/dev/null || true

_RECV_TOKEN=$(grep -i '^X-Webhook-Token:' "$_PREFLIGHT_TMP" 2>/dev/null | tr -d '\r' | awk '{print $2}')
rm -f "$_PREFLIGHT_TMP"

if [[ "$_HTTP_CODE" != "200" ]]; then
    echo "ERROR: Webhook preflight failed — got HTTP ${_HTTP_CODE} from ${WEBHOOK_URL}"
    echo "  Check: NPM proxy for $(echo "$WEBHOOK_URL" | cut -d'/' -f3) → localhost:${WEBHOOK_PORT}"
    exit 1
fi
if [[ "$_RECV_TOKEN" != "$WEBHOOK_SECRET" ]]; then
    echo "ERROR: Webhook preflight — token mismatch (received: '${_RECV_TOKEN}')"
    exit 1
fi
echo "[$(date)] Webhook preflight OK."
echo ""

# ---------------------------------------------------------------------------
# ENCODE USERDATA
# ---------------------------------------------------------------------------
echo "[$(date)] Encoding user-data script..."
# Inject secrets/personal values into placeholders before encoding.
USERDATA_RENDERED=$(sed \
    -e "s|__WEBHOOK_SECRET__|${WEBHOOK_SECRET}|g" \
    -e "s|__WEBHOOK_URL__|${WEBHOOK_URL}|g" \
    -e "s|__KEY_PAIR__|${KEY_PAIR}|g" \
    "$USERDATA_SCRIPT")
USERDATA_B64=$(printf '%s' "$USERDATA_RENDERED" | base64 -w 0)

# ---------------------------------------------------------------------------
# BUILD LAUNCH SPEC
# ---------------------------------------------------------------------------
LAUNCH_SPEC=$(cat << EOF
{
  "ImageId": "${AMI_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "KeyName": "${KEY_PAIR}",
  "NetworkInterfaces": [
    {
      "DeviceIndex": 0,
      "SubnetId": "${SUBNET_ID}",
      "Groups": ["${SECURITY_GROUP_ID}"],
      "AssociatePublicIpAddress": true
    }
  ],
  "UserData": "${USERDATA_B64}",
  "IamInstanceProfile": {
    "Name": "${INSTANCE_PROFILE}"
  },
  "BlockDeviceMappings": [
    {
      "DeviceName": "/dev/sda1",
      "Ebs": {
        "VolumeSize": ${EBS_SIZE_GB},
        "VolumeType": "${EBS_TYPE}",
        "Iops": ${EBS_IOPS},
        "Throughput": ${EBS_THROUGHPUT},
        "DeleteOnTermination": ${EBS_DELETE_ON_TERMINATION}
      }
    }
  ]
}
EOF
)

# ---------------------------------------------------------------------------
# LAUNCH INSTANCE (spot or on-demand)
# ---------------------------------------------------------------------------
REQUEST_ID=""
INSTANCE_ID=""
FULFILL_TIME=""

if [[ "$LAUNCH_MODE" == "spot" ]]; then
    echo "[$(date)] Submitting Spot Instance Request..."
    echo "  Instance type : $INSTANCE_TYPE"
    echo "  Max price     : \$$SPOT_MAX_PRICE/hr"
    echo "  Region        : $REGION"
    echo "  AMI           : $AMI_ID"
    echo "  Key pair      : $KEY_PAIR"
    echo "  Security group: $SECURITY_GROUP_ID"
    echo "  EBS size      : ${EBS_SIZE_GB} GB (${EBS_FATE_DESC})"
    echo ""

    SPOT_RESPONSE=$(aws ec2 request-spot-instances \
        --region "$REGION" \
        --spot-price "$SPOT_MAX_PRICE" \
        --instance-count 1 \
        --type "one-time" \
        --launch-specification "$LAUNCH_SPEC" \
        --output json)

    REQUEST_ID=$(echo "$SPOT_RESPONSE" | jq -r '.SpotInstanceRequests[0].SpotInstanceRequestId')

    if [[ -z "$REQUEST_ID" || "$REQUEST_ID" == "null" ]]; then
        echo "ERROR: Spot request failed. Full response:"
        echo "$SPOT_RESPONSE"
        exit 1
    fi

    echo "[$(date)] Spot request submitted. Request ID: $REQUEST_ID"
    echo ""
    echo "Waiting for spot request to be fulfilled..."

    WAIT_SECONDS=0
    MAX_WAIT="$SPOT_WAIT_MAX"   # from launch.env: how long to wait for fulfillment

    while [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; do
        sleep 10
        WAIT_SECONDS=$((WAIT_SECONDS + 10))

        STATUS_RESPONSE=$(aws ec2 describe-spot-instance-requests \
            --region "$REGION" \
            --spot-instance-request-ids "$REQUEST_ID" \
            --output json)

        STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.SpotInstanceRequests[0].Status.Code')
        INSTANCE_ID=$(echo "$STATUS_RESPONSE" | jq -r '.SpotInstanceRequests[0].InstanceId // empty')

        echo "  [${WAIT_SECONDS}s] Status: $STATUS | Instance ID: ${INSTANCE_ID:-pending}"

        if [[ "$STATUS" == "price-too-low" ]]; then
            echo "ERROR: Spot price cap of \$$SPOT_MAX_PRICE/hr is below current market price."
            exit 1
        fi

        if [[ $WAIT_SECONDS -ge $MAX_WAIT && -z "$INSTANCE_ID" ]]; then
            echo "ERROR: Not fulfilled within ${MAX_WAIT}s. Cancelling."
            aws ec2 cancel-spot-instance-requests \
                --region "$REGION" \
                --spot-instance-request-ids "$REQUEST_ID"
            exit 1
        fi
    done

    FULFILL_TIME=$(date)
    echo ""
    echo "[$(date)] Spot instance fulfilled. Instance ID: $INSTANCE_ID"

else
    echo "[$(date)] Launching On-Demand Instance..."
    echo "  Instance type : $INSTANCE_TYPE"
    echo "  Region        : $REGION"
    echo "  AMI           : $AMI_ID"
    echo "  Key pair      : $KEY_PAIR"
    echo "  Security group: $SECURITY_GROUP_ID"
    echo "  EBS size      : ${EBS_SIZE_GB} GB (${EBS_FATE_DESC})"
    echo ""

    OD_RESPONSE=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_PAIR" \
        --network-interfaces "DeviceIndex=0,SubnetId=${SUBNET_ID},Groups=${SECURITY_GROUP_ID},AssociatePublicIpAddress=true" \
        --user-data "$USERDATA_B64" \
        --iam-instance-profile "Name=${INSTANCE_PROFILE}" \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${EBS_SIZE_GB},\"VolumeType\":\"${EBS_TYPE}\",\"Iops\":${EBS_IOPS},\"Throughput\":${EBS_THROUGHPUT},\"DeleteOnTermination\":${EBS_DELETE_ON_TERMINATION}}}]" \
        --count 1 \
        --output json)

    INSTANCE_ID=$(echo "$OD_RESPONSE" | jq -r '.Instances[0].InstanceId')

    if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
        echo "ERROR: On-demand launch failed. Full response:"
        echo "$OD_RESPONSE"
        exit 1
    fi

    FULFILL_TIME=$(date)
    echo "[$(date)] On-demand instance launched. Instance ID: $INSTANCE_ID"
fi

FULFILL_EPOCH=$(date +%s)
TERMINATE_EPOCH=$((FULFILL_EPOCH + 55 * 60))
TERMINATE_TIME=$(date -d "@${TERMINATE_EPOCH}" '+%Y-%m-%d %H:%M:%S %Z')

# ---------------------------------------------------------------------------
# WAIT FOR RUNNING STATE
# ---------------------------------------------------------------------------
echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"

# ---------------------------------------------------------------------------
# TAG INSTANCE AND EBS VOLUME
# Include SNS topic ARN as a tag so the userdata script can find it
# ---------------------------------------------------------------------------
echo "Tagging instance..."
TAG_LIST="Key=Name,Value=qwen3-32b-ollama Key=Project,Value=WatchTell Key=ManagedBy,Value=launch_qwen_spot.sh"
if [[ -n "$SNS_TOPIC_ARN" ]]; then
    TAG_LIST="$TAG_LIST Key=SnsTopicArn,Value=${SNS_TOPIC_ARN}"
fi

aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags $TAG_LIST

VOLUME_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
    --output text)

if [[ -n "$VOLUME_ID" && "$VOLUME_ID" != "None" && "$VOLUME_ID" != "null" ]]; then
    echo "Tagging EBS volume $VOLUME_ID..."
    aws ec2 create-tags \
        --region "$REGION" \
        --resources "$VOLUME_ID" \
        --tags \
            Key=Name,Value=qwen3-32b-model-cache \
            Key=Project,Value=WatchTell \
            Key=Note,Value="EBS-${EBS_FATE_DESC// /-}-Qwen3-32B"
fi

# ---------------------------------------------------------------------------
# GET PUBLIC IP
# ---------------------------------------------------------------------------
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

OLLAMA_URL="http://${PUBLIC_IP}:11434"
WEBUI_URL="http://${PUBLIC_IP}:3000"   # Open WebUI (browser chat) — port 3000 must be open in the SG
SSM_CMD="aws ssm start-session --target ${INSTANCE_ID} --region ${REGION}"

# ---------------------------------------------------------------------------
# SUMMARY OUTPUT — includes all info that will also appear in the email
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Qwen3-32B Instance Ready (${LAUNCH_MODE})"
echo "============================================================"
echo "  Instance ID    : $INSTANCE_ID"
echo "  Launch Mode    : $LAUNCH_MODE"
echo "  EBS Volume     : $VOLUME_ID"
echo "  Public IP      : $PUBLIC_IP"
if [[ -n "$REQUEST_ID" ]]; then
echo "  Spot Request   : $REQUEST_ID"
fi
echo "  Region         : $REGION"
echo "  Fulfilled At   : $FULFILL_TIME"
echo "  Est. Terminate : $TERMINATE_TIME (55 min from fulfillment)"
echo ""
echo "  OLLAMA URL:"
echo "  $OLLAMA_URL"
echo ""
echo "  WEB UI (browser chat):"
echo "  $WEBUI_URL"
echo ""
echo "  SSH:"
echo "  ssh -i ~/.ssh/RonKeyPair01.pem ubuntu@${PUBLIC_IP}"
echo ""
echo "  Session Manager (no SSH key needed):"
echo "  $SSM_CMD"
echo ""
echo "  aider:"
echo "  export OLLAMA_API_BASE=$OLLAMA_URL"
echo "  aider --model ollama/tax-qwen"
echo ""
echo "  Home Ollama:"
echo "  OLLAMA_HOST=$OLLAMA_URL ollama run tax-qwen"
echo ""
echo "  Monitor bootstrap (~8-12 min until model ready):"
echo "  ssh -i ~/.ssh/RonKeyPair01.pem ubuntu@${PUBLIC_IP} 'tail -f /var/log/ollama-bootstrap.log'"
echo ""
if [[ "${EBS_DELETE_ON_TERMINATION,,}" == "true" ]]; then
echo "  EBS deleted on termination — next launch re-downloads the model."
else
echo "  EBS retained after termination — next launch skips model download."
fi
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# SAVE INSTANCE INFO LOCALLY
# ---------------------------------------------------------------------------
{
    echo "Launch Time    : $(date)"
    echo "Launch Mode    : $LAUNCH_MODE"
    echo "Fulfilled At   : $FULFILL_TIME"
    echo "Est. Terminate : $TERMINATE_TIME"
    echo "Instance ID    : $INSTANCE_ID"
    echo "EBS Volume     : $VOLUME_ID"
    echo "Public IP      : $PUBLIC_IP"
    [[ -n "$REQUEST_ID" ]] && echo "Spot Request   : $REQUEST_ID"
    echo "Region         : $REGION"
    echo "Ollama URL     : $OLLAMA_URL"
    echo "Web UI         : $WEBUI_URL"
    echo "SSH            : ssh -i ~/.ssh/RonKeyPair01.pem ubuntu@${PUBLIC_IP}"
    echo "Session Mgr    : $SSM_CMD"
    echo "aider          : export OLLAMA_API_BASE=$OLLAMA_URL && aider --model ollama/tax-qwen"
} > "${SCRIPT_DIR}/last_launch.txt"

echo "[$(date)] Instance info saved to: ${SCRIPT_DIR}/last_launch.txt"
if [[ -n "$SNS_TOPIC_ARN" ]]; then
    echo "Email will arrive at $NOTIFY_EMAIL once the model is loaded (~8-12 min)."
else
    echo "No SNS topic configured — run './launch_qwen_spot.sh --setup' to enable email."
fi

# ---------------------------------------------------------------------------
# WAIT FOR model_ready WEBHOOK
# Listen on localhost:WEBHOOK_PORT (Caddy proxies /webhook/ollama here).
# Print each status callback; block until model_ready (or timeout), then
# export OLLAMA_API_BASE and persist it to ~/.aider.env.
# ---------------------------------------------------------------------------
echo ""
echo "[$(date)] Listening on localhost:${WEBHOOK_PORT} for status callbacks..."
echo "  Waiting for 'model_ready' (model pull ~8-12 min). Ctrl-C to stop waiting."
echo ""

HTTP_200=$'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{"ok":true}     '

WAIT_START=$(date +%s)
CALLBACK_OLLAMA_URL=""
while true; do
    # nc serves one request: response on stdin → client, client request → stdout.
    # timeout bounds each listen so a stalled boot still hits WEBHOOK_WAIT_MAX.
    REQ=$(timeout 120 bash -c "printf '%s' \"\$1\" | nc -l -p $WEBHOOK_PORT -q 1" _ "$HTTP_200" 2>/dev/null || true)

    if [[ -z "$REQ" ]]; then
        # No connection within nc's wait; check overall timeout and re-listen.
        if (( $(date +%s) - WAIT_START >= WEBHOOK_WAIT_MAX )); then
            echo "[$(date)] Timed out after ${WEBHOOK_WAIT_MAX}s waiting for model_ready."
            echo "  Check bootstrap log:"
            echo "  ssh -i ~/.ssh/RonKeyPair01.pem ubuntu@${PUBLIC_IP} 'tail -f /var/log/ollama-bootstrap.log'"
            break
        fi
        continue
    fi

    # Validate shared secret.
    RECV_TOKEN=$(echo "$REQ" | grep -i '^X-Webhook-Token:' | tr -d '\r' | awk '{print $2}')
    if [[ "$RECV_TOKEN" != "$WEBHOOK_SECRET" ]]; then
        echo "[$(date)] Rejected callback with bad/missing token."
        continue
    fi

    STATUS=$(echo "$REQ" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
    CB_URL=$(echo "$REQ" | grep -o '"ollama_url":"[^"]*"' | head -1 | cut -d'"' -f4)
    CB_WEBUI=$(echo "$REQ" | grep -o '"webui_url":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "[$(date)] Callback: status=${STATUS:-?} ollama_url=${CB_URL:-?} webui_url=${CB_WEBUI:-?}"

    if [[ "$STATUS" == "model_ready" ]]; then
        CALLBACK_OLLAMA_URL="$CB_URL"
        [[ -n "$CB_WEBUI" ]] && WEBUI_URL="$CB_WEBUI"
        break
    fi
done

if [[ -n "$CALLBACK_OLLAMA_URL" ]]; then
    export OLLAMA_API_BASE="$CALLBACK_OLLAMA_URL"
    AIDER_ENV="${HOME}/.aider.env"
    if [[ -f "$AIDER_ENV" ]]; then
        grep -v '^OLLAMA_API_BASE=' "$AIDER_ENV" > "${AIDER_ENV}.tmp" 2>/dev/null || true
        mv "${AIDER_ENV}.tmp" "$AIDER_ENV"
    fi
    echo "OLLAMA_API_BASE=${CALLBACK_OLLAMA_URL}" >> "$AIDER_ENV"

    echo ""
    echo "============================================================"
    echo "  MODEL READY"
    echo "============================================================"
    echo "  OLLAMA_API_BASE=${CALLBACK_OLLAMA_URL}"
    echo "  Written to: ${AIDER_ENV}"
    echo ""
    echo "  Web UI (browser chat): ${WEBUI_URL}"
    echo ""
    echo "  Run aider now:"
    echo "    aider --model ollama/tax-qwen"
    echo "============================================================"
fi
