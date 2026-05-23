# GitHub Actions Runner Orchestrator

Dynamic runner auto-scaling for kernel build workflows. Provisions Docker-based runners on-demand, sharing toolchains and ccache for efficient builds.

## Overview

This orchestrator monitors your GitHub Actions queue and automatically provisions self-hosted runners when builds are queued. It's optimized for kernel builds with:

- **Shared toolchains** from `/mnt/Hawai/toolchains` (read-only)
- **Shared ccache** from `/mnt/ccache/.ccache` (read-write)
- **Shared source mirrors** from `/mnt/Android/source-mirrors` (read-write)
- **Dynamic scaling** from 1 to 4 runners based on queue depth
- **Automatic cleanup** of idle runners after 10 minutes

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  GitHub Actions Queue                    │
│              (Kernel Build Workflows)                    │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ Monitors via API
                     ▼
┌─────────────────────────────────────────────────────────┐
│            Runner Orchestrator (Python)                  │
│  • Polls queue every 30s                                │
│  • Calculates target runner count                       │
│  • Provisions/terminates Docker runners                 │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ Manages
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Docker Runner Containers                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│  │ Runner 1 │  │ Runner 2 │  │ Runner 3 │  ...        │
│  └──────────┘  └──────────┘  └──────────┘             │
│                                                          │
│  Shared Volumes:                                        │
│  • /mnt/Hawai/toolchains (ro)                          │
│  • /mnt/ccache/.ccache (rw)                            │
│  • /mnt/Android/source-mirrors (rw)                    │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

- Docker installed and running
- Python 3.8+ with `requests` library
- GitHub Personal Access Token with `repo` and `workflow` scopes
- Sufficient disk space for multiple concurrent builds

## Quick Start

### 1. Run Setup Script

```bash
cd .github/orchestrator
chmod +x setup.sh
./setup.sh
```

This will:
- Check prerequisites
- Build the Docker runner image
- Create configuration file
- Optionally install systemd service

### 2. Configure GitHub Token

Edit `orchestrator.env`:

```bash
nano orchestrator.env
```

Add your GitHub Personal Access Token:

```env
GITHUB_TOKEN=ghp_your_token_here
GITHUB_REPO=deepongi-labs/android14-6.1.162-common-2026-03
```

**Creating a GitHub Token:**
1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Select scopes: `repo` and `workflow`
4. Copy the token and paste it in `orchestrator.env`

### 3. Test the Orchestrator

```bash
./test-orchestrator.sh
```

You should see:
```
Starting runner orchestrator
Configuration: MIN=1, MAX=4, IDLE_TIMEOUT=600s
Status: 1 active runners, 0 queued workflows
```

Press `Ctrl+C` to stop.

### 4. Install as System Service

```bash
sudo systemctl start runner-orchestrator
sudo systemctl enable runner-orchestrator
```

View logs:
```bash
sudo journalctl -u runner-orchestrator -f
```

## Configuration

Edit `orchestrator.env` to customize behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `GITHUB_TOKEN` | (required) | GitHub Personal Access Token |
| `GITHUB_REPO` | (required) | Repository in format `owner/repo` |
| `MAX_RUNNERS` | 4 | Maximum concurrent runners |
| `MIN_RUNNERS` | 1 | Minimum runners to keep alive |
| `RUNNER_IDLE_TIMEOUT` | 600 | Seconds before idle runner is terminated |
| `POLL_INTERVAL` | 30 | Seconds between queue checks |
| `RUNNER_IMAGE` | `ghcr.io/actions/actions-runner:latest` | Docker image for runners |

## Integration with Kernel Build Workflow

### Update Workflow to Use Orchestrated Runners

Edit `.github/workflows/kernel-build.yml`:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, pixel8-orchestrated]
```

The orchestrator provisions runners with the `pixel8-orchestrated` label.

### Scaling Behavior

- **1 queued workflow** → 1 runner provisioned
- **2 queued workflows** → 2 runners provisioned
- **4+ queued workflows** → 4 runners provisioned (max)
- **0 queued workflows** → Scales down to 1 runner after idle timeout

Each kernel build workflow (with matrix builds) runs on a single runner, so the orchestrator provisions one runner per queued workflow.

## Monitoring

### Check Orchestrator Status

```bash
sudo systemctl status runner-orchestrator
```

### View Real-Time Logs

```bash
sudo journalctl -u runner-orchestrator -f
```

### Check Active Runners

```bash
docker ps --filter "name=orchestrated-runner"
```

### Check Runner Registration on GitHub

Go to: `https://github.com/YOUR_ORG/YOUR_REPO/settings/actions/runners`

You should see runners with names like `orchestrated-runner-1234567890-0`.

## Troubleshooting

### Orchestrator Won't Start

**Check Docker:**
```bash
docker ps
```

**Check Python dependencies:**
```bash
pip3 install requests
```

**Check GitHub token:**
```bash
# Test API access
curl -H "Authorization: token YOUR_TOKEN" \
  https://api.github.com/repos/YOUR_ORG/YOUR_REPO/actions/runs
```

### Runners Not Appearing

**Check orchestrator logs:**
```bash
sudo journalctl -u runner-orchestrator -f
```

**Verify registration token:**
The orchestrator fetches a registration token from GitHub. If this fails, check:
- GitHub token has `repo` and `workflow` scopes
- Repository name is correct in `orchestrator.env`

**Check Docker image:**
```bash
docker images | grep actions-runner
```

### Runners Not Picking Up Jobs

**Check runner labels:**
```bash
docker logs orchestrated-runner-XXXXX
```

Ensure the workflow uses matching labels:
```yaml
runs-on: [self-hosted, linux, x64, pixel8-orchestrated]
```

### High Resource Usage

**Reduce MAX_RUNNERS:**
```env
MAX_RUNNERS=2
```

**Increase RUNNER_IDLE_TIMEOUT:**
```env
RUNNER_IDLE_TIMEOUT=300  # 5 minutes
```

**Check ccache size:**
```bash
du -sh /mnt/ccache/.ccache
```

## Advanced Configuration

### Custom Docker Image

Build a custom runner image with additional tools:

```dockerfile
FROM ghcr.io/actions/actions-runner:latest

# Add custom tools
RUN apt-get update && apt-get install -y \
    your-custom-package

# Add custom scripts
COPY custom-script.sh /usr/local/bin/
```

Update `orchestrator.env`:
```env
RUNNER_IMAGE=your-custom-runner:latest
```

### Multiple Orchestrators

Run separate orchestrators for different workflows:

```bash
cp -r .github/orchestrator .github/orchestrator-priority
cd .github/orchestrator-priority
# Edit orchestrator.env with different settings
./setup.sh
```

### Resource Limits

Add resource limits to Docker containers by editing `runner-orchestrator.py`:

```python
cmd.extend(['--cpus', '4'])
cmd.extend(['--memory', '16g'])
```

## Maintenance

### Update Runner Image

```bash
cd .github/orchestrator
docker pull ghcr.io/actions/actions-runner:latest
docker build -t actions-runner-kernel:latest .
sudo systemctl restart runner-orchestrator
```

### Clean Up Old Containers

```bash
docker container prune -f
```

### Rotate GitHub Token

1. Generate new token on GitHub
2. Update `orchestrator.env`
3. Restart orchestrator: `sudo systemctl restart runner-orchestrator`

## Uninstall

```bash
# Stop orchestrator
sudo systemctl stop runner-orchestrator
sudo systemctl disable runner-orchestrator

# Remove service
sudo rm /etc/systemd/system/runner-orchestrator.service
sudo systemctl daemon-reload

# Remove Docker containers
docker ps -a --filter "name=orchestrated-runner" -q | xargs docker rm -f

# Remove Docker image
docker rmi actions-runner-kernel:latest
```

## Performance Tips

1. **Use ccache effectively**: The orchestrator shares ccache across all runners, significantly speeding up rebuilds.

2. **Optimize MIN_RUNNERS**: Keep at least 1 runner alive to avoid cold-start delays.

3. **Tune POLL_INTERVAL**: Lower values (15-20s) provide faster response but increase API calls.

4. **Monitor resource usage**: Use `htop` and `docker stats` to ensure your system can handle MAX_RUNNERS.

5. **Use source mirrors**: The shared source mirrors prevent redundant git clones.

## Security Considerations

- **GitHub Token**: Store securely, rotate regularly, use minimal required scopes
- **Docker Socket**: Orchestrator needs Docker access; run as dedicated user if possible
- **Shared Volumes**: Toolchains are mounted read-only; ccache is read-write
- **Network**: Runners have full network access; consider firewall rules

## Support

For issues or questions:
- Check logs: `sudo journalctl -u runner-orchestrator -f`
- Review GitHub Actions runs: `https://github.com/YOUR_ORG/YOUR_REPO/actions`
- Test manually: `./test-orchestrator.sh`

## License

This orchestrator is part of the GKI kernel builder project.
