#!/bin/bash
# =============================================================================
# ec2_userdata.sh
# EC2 User-Data Bootstrap — Ollama + Qwen3-32B on g5.xlarge
#
# Purpose:
#   - Installs Ollama and pulls Qwen3-32B model (~20 GB)
#   - Exposes Ollama API on 0.0.0.0:11434
#   - Schedules self-termination at 55 minutes
#   - Sends email via SNS (no postfix/SMTP required) as LAST step
#   - EBS delete-on-termination is set to false at launch time
#
# Email delivery: Uses AWS SNS → SES or email subscription.
# No local mail server required. SNS topic ARN is set in the launcher
# and passed in via instance tag "SnsTopicArn" read at boot time.
# =============================================================================

set -euo pipefail
exec > /var/log/ollama-bootstrap.log 2>&1

BOOT_TIME=$(date +%s)
echo "[$(date)] Starting Ollama bootstrap..."

# ---------------------------------------------------------------------------
# 1. System packages — no postfix, no mail tools
# ---------------------------------------------------------------------------
apt-get update -y
apt-get install -y curl wget jq awscli at

# ---------------------------------------------------------------------------
# 1b. Webhook callback setup
#     Status updates POST to Caddy (hermes) → local nc listener in launcher.
#     WEBHOOK_SECRET is injected by launch_qwen_spot.sh at encode time.
# ---------------------------------------------------------------------------
WEBHOOK_URL="__WEBHOOK_URL__"
WEBHOOK_SECRET="__WEBHOOK_SECRET__"

# Fetch instance metadata early so every callback carries full info.
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4)
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_TYPE=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-type)
OLLAMA_URL="http://${PUBLIC_IP}:11434"

# post_status <status> — fire a webhook callback; never fail the bootstrap.
post_status() {
    local status="$1"
    curl -sf -m 10 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "X-Webhook-Token: ${WEBHOOK_SECRET}" \
        -d "{\"status\":\"${status}\",\"instance_id\":\"${INSTANCE_ID}\",\"public_ip\":\"${PUBLIC_IP}\",\"instance_type\":\"${INSTANCE_TYPE}\",\"region\":\"${REGION}\",\"ollama_url\":\"${OLLAMA_URL}\",\"webui_url\":\"${WEBUI_URL:-}\"}" \
        && echo "[$(date)] webhook: $status sent" \
        || echo "[$(date)] webhook: $status POST failed (non-fatal)"
}

# Persist webhook config for the self-terminate hook (runs later, fresh shell).
cat > /etc/ollama-webhook.env << EOF
WEBHOOK_URL="${WEBHOOK_URL}"
WEBHOOK_SECRET="${WEBHOOK_SECRET}"
EOF
chmod 600 /etc/ollama-webhook.env

post_status booting

# ---------------------------------------------------------------------------
# 2. Enable Session Manager (SSM Agent)
#    Deep Learning AMI may already have it; this ensures it's running.
#    Requires the instance profile to have AmazonSSMManagedInstanceCore policy.
# ---------------------------------------------------------------------------
echo "[$(date)] Ensuring SSM Agent is running..."
if ! systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    snap install amazon-ssm-agent --classic 2>/dev/null || \
    apt-get install -y amazon-ssm-agent 2>/dev/null || \
    true
fi
systemctl enable amazon-ssm-agent 2>/dev/null || true
systemctl start amazon-ssm-agent 2>/dev/null || true
echo "[$(date)] SSM Agent status: $(systemctl is-active amazon-ssm-agent 2>/dev/null || echo 'unknown')"

# ---------------------------------------------------------------------------
# 3. Verify NVIDIA driver
# ---------------------------------------------------------------------------
if nvidia-smi &>/dev/null; then
    echo "[$(date)] GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
else
    echo "[$(date)] WARNING: nvidia-smi not found — model will run on CPU (very slow)"
fi

# ---------------------------------------------------------------------------
# 4. Install Ollama
# ---------------------------------------------------------------------------
echo "[$(date)] Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# ---------------------------------------------------------------------------
# 5. Configure Ollama to listen on all interfaces
# ---------------------------------------------------------------------------
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF

systemctl daemon-reload
systemctl enable ollama
systemctl start ollama

echo "[$(date)] Waiting for Ollama service..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "[$(date)] Ollama is up."
        break
    fi
    sleep 5
done

post_status ollama_ready

# ---------------------------------------------------------------------------
# 6. Create Modelfile — tuned for document extraction / tax analysis
# ---------------------------------------------------------------------------
cat > /tmp/TaxQwenModelfile << 'EOF'
FROM qwen3:32b
PARAMETER num_ctx 24576
PARAMETER temperature 0.1
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.1
SYSTEM "You are a precise document analysis assistant. Extract structured data accurately from tax documents. Never fabricate numbers, figures, or citations. If a value is not present in the source document, return null."
EOF

# ---------------------------------------------------------------------------
# 7. Pull Qwen3-32B
# ---------------------------------------------------------------------------
echo "[$(date)] Pulling Qwen3-32B model..."
ollama pull qwen3:32b

echo "[$(date)] Creating tax-optimized model alias..."
ollama create tax-qwen -f /tmp/TaxQwenModelfile

echo "[$(date)] Model ready."

# ---------------------------------------------------------------------------
# 7b. Open WebUI — browser chat front-end for Ollama (queries via the browser)
#     Runs in Docker, proxies to Ollama on the host (:11434), no login wall.
#     Served on :${WEBUI_PORT}; the security group must allow that port.
# ---------------------------------------------------------------------------
WEBUI_PORT=3000
WEBUI_URL="http://${PUBLIC_IP}:${WEBUI_PORT}"
echo "[$(date)] Starting Open WebUI on :${WEBUI_PORT}..."
if ! command -v docker >/dev/null 2>&1; then
    echo "[$(date)] Docker not present — installing..."
    curl -fsSL https://get.docker.com | sh || echo "[$(date)] Docker install failed"
fi
if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker 2>/dev/null || true
    docker rm -f open-webui 2>/dev/null || true
    if docker run -d --restart unless-stopped \
        --name open-webui \
        -p "${WEBUI_PORT}:8080" \
        --add-host=host.docker.internal:host-gateway \
        -e OLLAMA_BASE_URL="http://host.docker.internal:11434" \
        -e WEBUI_AUTH=False \
        -v open-webui:/app/backend/data \
        ghcr.io/open-webui/open-webui:main; then
        echo "[$(date)] Open WebUI up at ${WEBUI_URL}"
    else
        echo "[$(date)] Open WebUI failed to start — continuing without it"
        WEBUI_URL=""
    fi
else
    echo "[$(date)] Docker unavailable — Open WebUI skipped"
    WEBUI_URL=""
fi

# Unblock the launcher: model is live and serving (payload carries webui_url).
post_status model_ready

# ---------------------------------------------------------------------------
# 8. Compute termination time (metadata already fetched in step 1b)
# ---------------------------------------------------------------------------
# Calculate termination time (55 min from boot)
TERMINATE_EPOCH=$((BOOT_TIME + 55 * 60))
TERMINATE_TIME=$(date -d "@${TERMINATE_EPOCH}" '+%Y-%m-%d %H:%M:%S %Z')
ELAPSED=$(( ($(date +%s) - BOOT_TIME) / 60 ))
REMAINING=$((55 - ELAPSED))

# Session Manager connect command
SSM_CMD="aws ssm start-session --target ${INSTANCE_ID} --region ${REGION}"

echo "[$(date)] $INSTANCE_TYPE | $INSTANCE_ID | $REGION | $PUBLIC_IP"

# ---------------------------------------------------------------------------
# 9. Write status file
# ---------------------------------------------------------------------------
cat > /home/ubuntu/ollama-status.txt << EOF
============================================================
  Qwen3-32B Instance Status
============================================================
  Instance ID    : ${INSTANCE_ID}
  Instance Type  : ${INSTANCE_TYPE}
  Region         : ${REGION}
  Public IP      : ${PUBLIC_IP}
  Boot Time      : $(date -d "@${BOOT_TIME}" '+%Y-%m-%d %H:%M:%S %Z')
  Terminates At  : ${TERMINATE_TIME}
  Minutes Left   : ~${REMAINING} min

  OLLAMA URL     : ${OLLAMA_URL}
  WEB UI         : ${WEBUI_URL:-not available (Docker/WebUI failed)}

  SSH:
    ssh -i ~/.ssh/__KEY_PAIR__.pem ubuntu@${PUBLIC_IP}

  Session Manager:
    ${SSM_CMD}

  aider:
    export OLLAMA_API_BASE=${OLLAMA_URL}
    aider --model ollama/tax-qwen

  Home Ollama:
    OLLAMA_HOST=${OLLAMA_URL} ollama run tax-qwen

  API test:
    curl ${OLLAMA_URL}/api/tags

  Models loaded:
$(ollama list 2>/dev/null || echo '    Could not list models')

  Bootstrap log  : /var/log/ollama-bootstrap.log
============================================================
EOF
chown ubuntu:ubuntu /home/ubuntu/ollama-status.txt
cat /home/ubuntu/ollama-status.txt

# ---------------------------------------------------------------------------
# 10. Schedule self-termination at 55 minutes from boot
# ---------------------------------------------------------------------------
echo "[$(date)] Scheduling self-termination at ${TERMINATE_TIME}..."
systemctl enable --now atd

cat > /usr/local/bin/self-terminate.sh << 'TERMINATE_EOF'
#!/bin/bash
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)
PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4)

# Fire terminating webhook before shutdown (best-effort).
if [[ -f /etc/ollama-webhook.env ]]; then
    . /etc/ollama-webhook.env
    curl -sf -m 10 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "X-Webhook-Token: ${WEBHOOK_SECRET}" \
        -d "{\"status\":\"terminating\",\"instance_id\":\"${INSTANCE_ID}\",\"public_ip\":\"${PUBLIC_IP}\",\"region\":\"${REGION}\",\"ollama_url\":\"http://${PUBLIC_IP}:11434\"}" || true
fi

echo "[$(date)] Terminating $INSTANCE_ID in $REGION"
aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"
TERMINATE_EOF

chmod +x /usr/local/bin/self-terminate.sh

# Schedule at exact 55-minute mark from boot
AT_TIME=$(date -d "@${TERMINATE_EPOCH}" '+%H:%M %Y-%m-%d')
echo "/usr/local/bin/self-terminate.sh" | at "${AT_TIME}"

echo "[$(date)] Self-termination scheduled for ${TERMINATE_TIME}"

# ---------------------------------------------------------------------------
# 11. Send notification via SNS (no local mail server required)
#     SNS topic is tagged on the instance at launch time.
#     Subscribe your email to the topic once via:
#       aws sns subscribe --topic-arn <ARN> --protocol email \
#         --notification-endpoint <EMAIL> --region us-east-1
# ---------------------------------------------------------------------------
echo "[$(date)] Sending SNS notification..."

SNS_TOPIC_ARN=$(aws ec2 describe-tags \
    --region "$REGION" \
    --filters "Name=resource-id,Values=${INSTANCE_ID}" \
              "Name=key,Values=SnsTopicArn" \
    --query 'Tags[0].Value' \
    --output text 2>/dev/null || echo "")

if [[ -n "$SNS_TOPIC_ARN" && "$SNS_TOPIC_ARN" != "None" && "$SNS_TOPIC_ARN" != "null" ]]; then
    MESSAGE="Qwen3-32B is ready on ${INSTANCE_TYPE}.

Instance ID   : ${INSTANCE_ID}
Region        : ${REGION}
Public IP     : ${PUBLIC_IP}
Terminates At : ${TERMINATE_TIME}
EBS Volume    : RETAINED after termination

OLLAMA URL    : ${OLLAMA_URL}
WEB UI        : ${WEBUI_URL:-not available (Docker/WebUI failed)}

SSH:
  ssh -i ~/.ssh/__KEY_PAIR__.pem ubuntu@${PUBLIC_IP}

Session Manager:
  ${SSM_CMD}

aider:
  export OLLAMA_API_BASE=${OLLAMA_URL}
  aider --model ollama/tax-qwen

API test:
  curl ${OLLAMA_URL}/api/tags"

    aws sns publish \
        --region "$REGION" \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "Qwen3-32B Ready — Terminates ${TERMINATE_TIME}" \
        --message "$MESSAGE" && \
        echo "[$(date)] SNS notification sent." || \
        echo "[$(date)] SNS publish failed — check topic ARN and permissions."
else
    echo "[$(date)] No SnsTopicArn tag found — skipping email notification."
    echo "[$(date)] Connect info is in /home/ubuntu/ollama-status.txt"
fi

echo "[$(date)] Bootstrap complete. Ollama live at ${OLLAMA_URL}"
