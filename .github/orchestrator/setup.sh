#!/bin/bash
set -e

# GitHub Actions Runner Orchestrator Setup Script
# Installs and configures the runner orchestrator system

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=========================================="
echo "GitHub Actions Runner Orchestrator Setup"
echo "=========================================="
echo "Script directory: ${SCRIPT_DIR}"
echo "Project root: ${PROJECT_ROOT}"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi
echo "✅ Docker found: $(docker --version)"

if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 is not installed. Please install Python 3 first."
    exit 1
fi
echo "✅ Python 3 found: $(python3 --version)"

# Install Python dependencies
echo ""
echo "Installing Python dependencies..."
pip3 install --break-system-packages requests || {
    echo "⚠️  Failed to install Python dependencies. Continuing anyway..."
}

# Build Docker image
echo ""
echo "Building runner Docker image..."
cd "${SCRIPT_DIR}"
if docker build -t actions-runner-kernel:latest .; then
    echo "✅ Docker image built successfully"
    RUNNER_IMAGE="actions-runner-kernel:latest"
else
    echo "⚠️  Docker build failed (common in WSL2 due to networking issues)"
    echo ""
    echo "Fallback options:"
    echo "1. Use official GitHub Actions runner image (recommended)"
    echo "2. Try Docker build fixes:"
    echo "   - Restart Docker: sudo systemctl restart docker"
    echo "   - Restart WSL2: wsl --shutdown (in Windows PowerShell)"
    echo "   - Build with host network: docker build --network=host -t actions-runner-kernel:latest ."
    echo ""
    read -p "Use official runner image? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "✅ Will use official runner image: ghcr.io/actions/actions-runner:latest"
        RUNNER_IMAGE="ghcr.io/actions/actions-runner:latest"
    else
        echo "❌ Setup aborted. Please fix Docker build and retry."
        exit 1
    fi
fi

# Create configuration file
echo ""
if [ ! -f "${SCRIPT_DIR}/orchestrator.env" ]; then
    echo "Creating configuration file..."
    cp "${SCRIPT_DIR}/orchestrator.env.example" "${SCRIPT_DIR}/orchestrator.env"
    echo "⚠️  Please edit ${SCRIPT_DIR}/orchestrator.env and add your GitHub token"
    echo ""
    echo "To create a GitHub token:"
    echo "1. Go to https://github.com/settings/tokens"
    echo "2. Click 'Generate new token (classic)'"
    echo "3. Select scopes: 'repo' and 'workflow'"
    echo "4. Copy the token and paste it in orchestrator.env"
    echo ""
    read -p "Press Enter after you've configured orchestrator.env..."
else
    echo "✅ Configuration file already exists"
fi

# Verify configuration
if ! grep -q "ghp_" "${SCRIPT_DIR}/orchestrator.env" 2>/dev/null; then
    echo "⚠️  GitHub token not configured in orchestrator.env"
    echo "Please add your token before starting the orchestrator"
fi

# Install systemd service
echo ""
read -p "Install as systemd service? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Installing systemd service..."
    sudo cp "${SCRIPT_DIR}/runner-orchestrator.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    echo "✅ Systemd service installed"
    echo ""
    echo "To start the orchestrator:"
    echo "  sudo systemctl start runner-orchestrator"
    echo ""
    echo "To enable on boot:"
    echo "  sudo systemctl enable runner-orchestrator"
    echo ""
    echo "To view logs:"
    echo "  sudo journalctl -u runner-orchestrator -f"
fi

# Create test script
echo ""
echo "Creating test script..."
cat > "${SCRIPT_DIR}/test-orchestrator.sh" << 'EOF'
#!/bin/bash
# Test the orchestrator without systemd

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Load environment
set -a
source orchestrator.env
set +a

# Run orchestrator
python3 runner-orchestrator.py
EOF
chmod +x "${SCRIPT_DIR}/test-orchestrator.sh"
echo "✅ Test script created: ${SCRIPT_DIR}/test-orchestrator.sh"

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Ensure orchestrator.env has your GitHub token"
echo "2. Test the orchestrator: ./test-orchestrator.sh"
echo "3. If working, install as service: sudo systemctl start runner-orchestrator"
echo ""
echo "The orchestrator will:"
echo "  - Monitor your GitHub Actions queue"
echo "  - Provision runners on-demand (min: 1, max: 4)"
echo "  - Share toolchains from /mnt/Hawai/toolchains"
echo "  - Share ccache from /mnt/ccache/.ccache"
echo "  - Scale down idle runners after 10 minutes"
echo ""
