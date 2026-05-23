#!/usr/bin/env python3
"""
GitHub Actions Runner Orchestrator for Kernel Builds

Monitors GitHub Actions queue and provisions Docker-based runners on-demand.
Optimized for kernel builds with shared toolchains and ccache.
"""

import os
import sys
import time
import json
import logging
import subprocess
import requests
from typing import List, Dict, Optional
from dataclasses import dataclass
from datetime import datetime, timedelta

# Configuration
GITHUB_TOKEN = os.environ.get('GITHUB_TOKEN')
GITHUB_REPO = os.environ.get('GITHUB_REPO', 'deepongi-labs/android14-6.1.162-common-2026-03')
RUNNER_REGISTRATION_TOKEN_URL = f'https://api.github.com/repos/{GITHUB_REPO}/actions/runners/registration-token'
WORKFLOW_RUNS_URL = f'https://api.github.com/repos/{GITHUB_REPO}/actions/runs'

# Runner configuration
MAX_RUNNERS = int(os.environ.get('MAX_RUNNERS', '4'))
MIN_RUNNERS = int(os.environ.get('MIN_RUNNERS', '1'))
RUNNER_IDLE_TIMEOUT = int(os.environ.get('RUNNER_IDLE_TIMEOUT', '600'))  # 10 minutes
POLL_INTERVAL = int(os.environ.get('POLL_INTERVAL', '30'))  # 30 seconds

# Docker configuration
RUNNER_IMAGE = os.environ.get('RUNNER_IMAGE', 'ghcr.io/actions/actions-runner:latest')
RUNNER_LABELS = ['self-hosted', 'linux', 'x64', 'pixel8-orchestrated']

# Shared volumes for toolchains and cache
SHARED_VOLUMES = [
    '/mnt/Hawai/toolchains:/mnt/Hawai/toolchains:ro',
    '/mnt/ccache/.ccache:/mnt/ccache/.ccache:rw',
    '/mnt/Android/source-mirrors:/mnt/Android/source-mirrors:rw',
]

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('runner-orchestrator')


@dataclass
class Runner:
    """Represents a managed runner instance"""
    container_id: str
    name: str
    labels: List[str]
    started_at: datetime
    last_active: datetime
    status: str  # 'starting', 'idle', 'busy', 'stopping'


class RunnerOrchestrator:
    """Manages GitHub Actions runners lifecycle"""

    def __init__(self):
        self.runners: Dict[str, Runner] = {}
        self.session = requests.Session()
        self.session.headers.update({
            'Authorization': f'token {GITHUB_TOKEN}',
            'Accept': 'application/vnd.github.v3+json'
        })

    def get_registration_token(self) -> Optional[str]:
        """Get a registration token for new runners"""
        try:
            response = self.session.post(RUNNER_REGISTRATION_TOKEN_URL)
            response.raise_for_status()
            return response.json()['token']
        except Exception as e:
            logger.error(f"Failed to get registration token: {e}")
            return None

    def get_queued_workflows(self) -> int:
        """Get count of queued workflow runs"""
        try:
            params = {
                'status': 'queued',
                'per_page': 100
            }
            response = self.session.get(WORKFLOW_RUNS_URL, params=params)
            response.raise_for_status()
            data = response.json()

            # Filter for kernel build workflows
            kernel_builds = [
                run for run in data['workflow_runs']
                if 'kernel' in run['name'].lower()
            ]

            logger.info(f"Found {len(kernel_builds)} queued kernel build workflows")
            return len(kernel_builds)
        except Exception as e:
            logger.error(f"Failed to get queued workflows: {e}")
            return 0

    def get_active_runners(self) -> int:
        """Get count of currently active runners"""
        return len([r for r in self.runners.values() if r.status in ['idle', 'busy']])

    def create_runner(self, runner_name: str) -> Optional[str]:
        """Create a new Docker-based runner"""
        token = self.get_registration_token()
        if not token:
            logger.error("Cannot create runner without registration token")
            return None

        try:
            # Build docker run command
            cmd = [
                'docker', 'run', '-d',
                '--name', runner_name,
                '--restart', 'unless-stopped',
                '-e', f'RUNNER_NAME={runner_name}',
                '-e', f'RUNNER_TOKEN={token}',
                '-e', f'RUNNER_REPOSITORY_URL=https://github.com/{GITHUB_REPO}',
                '-e', f'RUNNER_LABELS={",".join(RUNNER_LABELS)}',
                '-e', 'RUNNER_WORKDIR=/work',
            ]

            # Add shared volumes
            for volume in SHARED_VOLUMES:
                cmd.extend(['-v', volume])

            # Add the runner image
            cmd.append(RUNNER_IMAGE)

            # Execute docker run
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            container_id = result.stdout.strip()

            # Register the runner
            runner = Runner(
                container_id=container_id,
                name=runner_name,
                labels=RUNNER_LABELS,
                started_at=datetime.now(),
                last_active=datetime.now(),
                status='starting'
            )
            self.runners[container_id] = runner

            logger.info(f"Created runner {runner_name} (container: {container_id[:12]})")
            return container_id

        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to create runner: {e.stderr}")
            return None

    def stop_runner(self, container_id: str):
        """Stop and remove a runner"""
        if container_id not in self.runners:
            logger.warning(f"Runner {container_id[:12]} not found in registry")
            return

        runner = self.runners[container_id]
        runner.status = 'stopping'

        try:
            # Stop the container gracefully
            subprocess.run(['docker', 'stop', '-t', '30', container_id], check=True)
            subprocess.run(['docker', 'rm', container_id], check=True)

            del self.runners[container_id]
            logger.info(f"Stopped runner {runner.name} (container: {container_id[:12]})")

        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to stop runner {container_id[:12]}: {e}")

    def check_runner_status(self, container_id: str) -> str:
        """Check if a runner container is still running"""
        try:
            result = subprocess.run(
                ['docker', 'inspect', '-f', '{{.State.Status}}', container_id],
                capture_output=True,
                text=True,
                check=True
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError:
            return 'stopped'

    def update_runner_statuses(self):
        """Update status of all managed runners"""
        for container_id, runner in list(self.runners.items()):
            container_status = self.check_runner_status(container_id)

            if container_status != 'running':
                logger.warning(f"Runner {runner.name} is {container_status}, removing from registry")
                del self.runners[container_id]
                continue

            # Check if runner is idle for too long
            if runner.status == 'idle':
                idle_time = (datetime.now() - runner.last_active).total_seconds()
                if idle_time > RUNNER_IDLE_TIMEOUT:
                    logger.info(f"Runner {runner.name} idle for {idle_time:.0f}s, stopping")
                    self.stop_runner(container_id)

    def scale_runners(self, target_count: int):
        """Scale runners to target count"""
        current_count = self.get_active_runners()

        if target_count > current_count:
            # Scale up
            to_create = min(target_count - current_count, MAX_RUNNERS - current_count)
            logger.info(f"Scaling up: creating {to_create} new runners")

            for i in range(to_create):
                runner_name = f"orchestrated-runner-{int(time.time())}-{i}"
                self.create_runner(runner_name)
                time.sleep(2)  # Stagger creation

        elif target_count < current_count and current_count > MIN_RUNNERS:
            # Scale down idle runners
            idle_runners = [
                (cid, r) for cid, r in self.runners.items()
                if r.status == 'idle'
            ]

            to_remove = min(current_count - target_count, len(idle_runners))
            logger.info(f"Scaling down: removing {to_remove} idle runners")

            for i in range(to_remove):
                container_id, _ = idle_runners[i]
                self.stop_runner(container_id)

    def run(self):
        """Main orchestration loop"""
        logger.info("Starting runner orchestrator")
        logger.info(f"Configuration: MIN={MIN_RUNNERS}, MAX={MAX_RUNNERS}, IDLE_TIMEOUT={RUNNER_IDLE_TIMEOUT}s")

        # Ensure minimum runners are running
        self.scale_runners(MIN_RUNNERS)

        try:
            while True:
                # Update runner statuses
                self.update_runner_statuses()

                # Check queue depth
                queued_count = self.get_queued_workflows()
                active_count = self.get_active_runners()

                logger.info(f"Status: {active_count} active runners, {queued_count} queued workflows")

                # Calculate target runner count
                # Each kernel build workflow needs 1 runner (matrix builds run on same runner)
                target_count = max(MIN_RUNNERS, min(queued_count, MAX_RUNNERS))

                # Scale runners
                if target_count != active_count:
                    self.scale_runners(target_count)

                # Sleep before next poll
                time.sleep(POLL_INTERVAL)

        except KeyboardInterrupt:
            logger.info("Shutting down orchestrator")
            # Clean up all runners
            for container_id in list(self.runners.keys()):
                self.stop_runner(container_id)


def main():
    """Entry point"""
    if not GITHUB_TOKEN:
        logger.error("GITHUB_TOKEN environment variable is required")
        sys.exit(1)

    orchestrator = RunnerOrchestrator()
    orchestrator.run()


if __name__ == '__main__':
    main()
