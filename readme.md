# Ollama Spot Launcher

Launch an on-demand or **EC2 Spot** GPU instance that boots straight into
[Ollama](https://ollama.com) serving a local LLM (Qwen3-32B by default), then
blocks until the model is pulled and ready. Designed for cheap, ephemeral
inference: spin it up when you need it, let the spot instance go when you don't,
and keep the model cache on a retained EBS volume so the next launch is fast.

## Pieces

| File                  | Role                                                                 |
| --------------------- | -------------------------------------------------------------------- |
| `launch_qwen_spot.sh` | Local launcher. Submits the spot/on-demand request, tags resources, waits for a `model_ready` webhook. |
| `ec2_userdata.sh`     | Boot script injected as EC2 user-data. Installs Ollama, pulls the model, posts status callbacks. |
| `launch.env.example`  | Template for your private config. Copy to `launch.env` and fill in.  |

## Quick start

```bash
# 1. Fill in your account-specific config
cp launch.env.example launch.env
$EDITOR launch.env          # key pair, subnet, security group, AMI, email, webhookv

# 2. One-time AWS setup (IAM role, instance profile, SNS topic + email sub)
./launch_qwen_spot.sh --setup
# Confirm the SNS subscription email before launching.

# 3. Launch
./launch_qwen_spot.sh                 # spot, us-east-1 (default)
./launch_qwen_spot.sh --ondemand      # on-demand instead of spot
./launch_qwen_spot.sh --region us-east-2
```

When the model is ready the launcher prints the Ollama URL **and the Web UI
URL**, and writes `OLLAMA_API_BASE` to `~/.aider.env`.

```bash
export OLLAMA_API_BASE=http://<public-ip>:11434
aider --model ollama/tax-qwen
```

### Web UI

The instance also runs [Open WebUI](https://github.com/open-webui/open-webui)
(Docker) as a browser chat front-end for Ollama, so you can run queries in a
browser instead of the API/CLI:

```
http://<public-ip>:3000
```

The URL is included in the launcher's on-screen log and the SNS email. Open the
SG port `3000` for it to be reachable. Auth is disabled (`WEBUI_AUTH=False`) —
fine for an ephemeral single-user instance; do not expose it long-lived.

## Configuration (`launch.env`)

All tunables live in `launch.env` — nothing account-specific is hard-coded in
the scripts.

| Variable                    | Meaning                                                        |
| --------------------------- | -------------------------------------------------------------- |
| `INSTANCE_TYPE`             | EC2 instance type (default `g5.xlarge`).                       |
| `SPOT_MAX_PRICE`            | Max $/hr bid for spot.                                         |
| `SPOT_WAIT_MAX`             | Seconds to wait for spot fulfillment before cancelling.        |
| `EBS_SIZE_GB` / `EBS_TYPE` / `EBS_IOPS` / `EBS_THROUGHPUT` | Root volume spec.        |
| `EBS_DELETE_ON_TERMINATION` | `false` retains the model-cache volume after the instance dies; `true` deletes it. |
| `WEBHOOK_URL` / `WEBHOOK_PORT` / `WEBHOOK_WAIT_MAX` / `WEBHOOK_SECRET_FILE` | Status-callback channel the launcher waits on. |
| `INSTANCE_PROFILE` / `NOTIFY_EMAIL` / `SNS_TOPIC_NAME` | IAM profile + email notifications.    |
| `*_USE1` / `*_USE2`         | Per-region key pair, security group, subnet, AMI.             |

Commented `*_12XL_*` lines hold per-AZ AMIs for a larger `g5.12xlarge`
(Qwen2.5-72B) configuration — fill them in and uncomment to use.

## How it works

1. The launcher renders `ec2_userdata.sh` (injecting the webhook secret/URL and
   key pair), base64-encodes it, and submits a spot or on-demand request with a
   `BlockDeviceMapping` honoring `EBS_DELETE_ON_TERMINATION`.
2. It waits up to `SPOT_WAIT_MAX` for fulfillment, then tags the instance and
   EBS volume.
3. On boot the instance installs Ollama, pulls the model, starts Open WebUI on
   port `3000`, and POSTs status updates (`booting` → `ollama_ready` →
   `model_ready`) to `WEBHOOK_URL`, authenticated with a shared secret. The
   `model_ready` callback carries both the Ollama and Web UI URLs.
4. The launcher listens locally (via a Caddy reverse-proxy to `WEBHOOK_PORT`)
   and unblocks when `model_ready` arrives, up to `WEBHOOK_WAIT_MAX`, then prints
   the Ollama + Web UI URLs.

## Notes

- `launch.env`, `last_launch.txt`, and `*.pem` are git-ignored — keep your real
  config and keys out of version control.
- The instance is set to self-terminate ~55 min after fulfillment; adjust in the
  launcher if you need longer sessions.
- EBS is retained by default so re-launches skip the multi-GB model download.
