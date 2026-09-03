#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/kengkoy-installer"
BACKUP_DIR="/opt/kengkoy-installer.backup-$(date +%Y%m%d-%H%M%S)"
SSH_DIR="/root/.ssh"
SSH_KEY="${SSH_DIR}/kengkoy_installer"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

die() {
    echo "[ERROR] $1"
    exit 1
}

trap 'echo "[ERROR] Installer failed on line $LINENO."' ERR

[[ "${EUID}" -eq 0 ]] || die "Run this installer as root."

log "KENGKOY VPS INSTALLER - SETUP"

echo "This installs the Kengkoy web panel on THIS VPS."
echo
echo "The panel can then connect through SSH to another VPS"
echo "and execute bin456789/reinstall there."
echo
read -rp "Continue? [y/N]: " ANSWER
[[ "${ANSWER,,}" == "y" ]] || exit 0

# ------------------------------------------------------------
# Detect OS
# ------------------------------------------------------------

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
else
    die "Cannot detect operating system."
fi

echo "Detected OS: ${PRETTY_NAME:-unknown}"

# ------------------------------------------------------------
# Install host dependencies
# ------------------------------------------------------------

log "INSTALLING HOST DEPENDENCIES"

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        openssl \
        openssh-client \
        gnupg
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y \
        ca-certificates \
        curl \
        openssl \
        openssh-clients
elif command -v yum >/dev/null 2>&1; then
    yum install -y \
        ca-certificates \
        curl \
        openssl \
        openssh-clients
else
    echo "WARNING: Unsupported package manager."
    echo "Make sure curl, openssl and ssh-keygen are installed."
fi

command -v ssh-keygen >/dev/null 2>&1 || \
    die "ssh-keygen is required."

command -v curl >/dev/null 2>&1 || \
    die "curl is required."

# ------------------------------------------------------------
# Install Docker
# ------------------------------------------------------------

log "CHECKING DOCKER"

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is not installed."
    echo "Installing Docker..."

    curl -fsSL https://get.docker.com | sh

    systemctl enable docker
    systemctl start docker
else
    echo "Docker already installed."
fi

systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker >/dev/null 2>&1 || true

command -v docker >/dev/null 2>&1 || \
    die "Docker installation failed."

# ------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------

if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose plugin is unavailable."
fi

echo
docker --version
docker compose version

# ------------------------------------------------------------
# Backup existing installation
# ------------------------------------------------------------

if [[ -d "${APP_DIR}" ]]; then
    log "EXISTING INSTALLATION DETECTED"

    echo "Existing directory:"
    echo "  ${APP_DIR}"
    echo
    echo "A backup will be created at:"
    echo "  ${BACKUP_DIR}"
    echo

    cp -a "${APP_DIR}" "${BACKUP_DIR}"

    echo "Backup created."
fi

# ------------------------------------------------------------
# Create directories
# ------------------------------------------------------------

log "CREATING PROJECT"

mkdir -p \
    "${APP_DIR}/app/templates" \
    "${APP_DIR}/app/static" \
    "${APP_DIR}/scripts" \
    "${APP_DIR}/data" \
    "${SSH_DIR}"

chmod 700 "${SSH_DIR}"

# ------------------------------------------------------------
# Controller SSH key
# ------------------------------------------------------------

log "CREATING CONTROLLER SSH KEY"

if [[ ! -f "${SSH_KEY}" ]]; then
    ssh-keygen \
        -t ed25519 \
        -f "${SSH_KEY}" \
        -N "" \
        -C "kengkoy-installer"

    chmod 600 "${SSH_KEY}"
    chmod 644 "${SSH_KEY}.pub"

    echo "SSH key created."
else
    echo "Existing SSH key preserved."
fi

[[ -f "${SSH_KEY}" ]] || die "SSH private key missing."
[[ -f "${SSH_KEY}.pub" ]] || die "SSH public key missing."

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

log "CONFIGURATION"

ENV_FILE="${APP_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
    echo "Existing .env preserved."
else
    ADMIN_USER="admin"
    ADMIN_PASSWORD='@#Babe03222025'
    APP_SECRET="$(openssl rand -hex 32)"

    cat > "${ENV_FILE}" <<EOF
APP_SECRET=${APP_SECRET}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
REINSTALL_URL=https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
SSH_KEY_PATH=/keys/kengkoy_installer
ALLOWED_SSH_PORTS=22,2222
DATA_DIR=/data
EOF

    chmod 600 "${ENV_FILE}"

    echo "Configuration created."
    echo "Admin username: ${ADMIN_USER}"
fi

# ------------------------------------------------------------
# requirements.txt
# ------------------------------------------------------------

cat > "${APP_DIR}/requirements.txt" <<'EOF'
fastapi==0.116.1
uvicorn[standard]==0.35.0
jinja2==3.1.6
python-multipart==0.0.20
cryptography==45.0.6
itsdangerous==2.2.0
EOF

# ------------------------------------------------------------
# Dockerfile
# ------------------------------------------------------------

cat > "${APP_DIR}/Dockerfile" <<'EOF'
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    curl \
    ca-certificates \
    bash \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY scripts ./scripts

RUN chmod +x /app/scripts/healthcheck.sh

EXPOSE 8080

CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8080"]
EOF

# ------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------

cat > "${APP_DIR}/docker-compose.yml" <<'EOF'
services:
  installer:
    build: .
    container_name: kengkoy-installer
    restart: unless-stopped

    ports:
      - "8088:8080"

    environment:
      APP_SECRET: ${APP_SECRET}
      ADMIN_USER: ${ADMIN_USER}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      REINSTALL_URL: ${REINSTALL_URL}
      SSH_KEY_PATH: ${SSH_KEY_PATH:-/keys/kengkoy_installer}
      ALLOWED_SSH_PORTS: ${ALLOWED_SSH_PORTS:-22,2222}
      DATA_DIR: ${DATA_DIR:-/data}

    volumes:
      - ./data:/data
      - /root/.ssh/kengkoy_installer:/keys/kengkoy_installer:ro
      - /root/.ssh/kengkoy_installer.pub:/keys/kengkoy_installer.pub:ro

    healthcheck:
      test:
        [
          "CMD",
          "python",
          "-c",
          "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3)"
        ]
      interval: 30s
      timeout: 5s
      retries: 3
EOF

# ------------------------------------------------------------
# app/__init__.py
# ------------------------------------------------------------

cat > "${APP_DIR}/app/__init__.py" <<'EOF'
# Kengkoy Installer
EOF

# ------------------------------------------------------------
# main.py
# ------------------------------------------------------------

cat > "${APP_DIR}/app/main.py" <<'PYEOF'
import base64
import json
import os
import re
import shlex
import subprocess
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware


APP_SECRET = os.environ.get("APP_SECRET", "")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
REINSTALL_URL = os.environ.get(
    "REINSTALL_URL",
    "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh",
)

SSH_KEY_PATH = os.environ.get(
    "SSH_KEY_PATH",
    "/keys/kengkoy_installer",
)

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
JOBS_DIR = DATA_DIR / "jobs"

ALLOWED_SSH_PORTS = {
    int(x.strip())
    for x in os.environ.get("ALLOWED_SSH_PORTS", "22,2222").split(",")
    if x.strip().isdigit()
}

APP_DIR = Path("/app")
TEMPLATES_DIR = APP_DIR / "templates"
STATIC_DIR = APP_DIR / "static"

DATA_DIR.mkdir(parents=True, exist_ok=True)
JOBS_DIR.mkdir(parents=True, exist_ok=True)


app = FastAPI(title="Kengkoy Installer")

app.add_middleware(
    SessionMiddleware,
    secret_key=APP_SECRET,
    session_cookie="kengkoy_session",
    max_age=60 * 60 * 12,
    same_site="lax",
    https_only=False,
)

templates = Jinja2Templates(directory=str(TEMPLATES_DIR))


# ============================================================
# OS CATALOG
# ============================================================

OS_CATALOG = {
    "ubuntu-22.04": {
        "family": "ubuntu",
        "version": "22.04",
        "name": "Ubuntu 22.04 LTS",
        "icon": "U",
    },
    "ubuntu-24.04": {
        "family": "ubuntu",
        "version": "24.04",
        "name": "Ubuntu 24.04 LTS",
        "icon": "U",
    },
    "ubuntu-26.04": {
        "family": "ubuntu",
        "version": "26.04",
        "name": "Ubuntu 26.04 LTS",
        "icon": "U",
    },
    "debian-12": {
        "family": "debian",
        "version": "12",
        "name": "Debian 12",
        "icon": "D",
    },
    "debian-13": {
        "family": "debian",
        "version": "13",
        "name": "Debian 13",
        "icon": "D",
    },
    "almalinux-9": {
        "family": "almalinux",
        "version": "9",
        "name": "AlmaLinux 9",
        "icon": "A",
    },
    "almalinux-10": {
        "family": "almalinux",
        "version": "10",
        "name": "AlmaLinux 10",
        "icon": "A",
    },
    "rocky-9": {
        "family": "rocky",
        "version": "9",
        "name": "Rocky Linux 9",
        "icon": "R",
    },
    "rocky-10": {
        "family": "rocky",
        "version": "10",
        "name": "Rocky Linux 10",
        "icon": "R",
    },
    "fedora": {
        "family": "fedora",
        "version": "",
        "name": "Fedora",
        "icon": "F",
    },
    "alpine": {
        "family": "alpine",
        "version": "3.24",
        "name": "Alpine Linux 3.24",
        "icon": "A",
    },
    "arch": {
        "family": "arch",
        "version": "",
        "name": "Arch Linux",
        "icon": "A",
    },
    "kali": {
        "family": "kali",
        "version": "",
        "name": "Kali Linux",
        "icon": "K",
    },
    "windows-server-2019": {
        "family": "windows",
        "version": "",
        "name": "Windows Server 2019",
        "image": "Windows Server 2019 SERVERDATACENTER",
        "icon": "W",
    },
    "windows-server-2022": {
        "family": "windows",
        "version": "",
        "name": "Windows Server 2022",
        "image": "Windows Server 2022 SERVERDATACENTER",
        "icon": "W",
    },
    "windows-server-2025": {
        "family": "windows",
        "version": "",
        "name": "Windows Server 2025",
        "image": "Windows Server 2025 SERVERDATACENTER",
        "icon": "W",
    },
}


# ============================================================
# HELPERS
# ============================================================

def now():
    return datetime.now(timezone.utc).isoformat()


def authenticated(request: Request):
    return request.session.get("authenticated") is True


def valid_target(target: str) -> bool:
    if not target:
        return False

    if len(target) > 253:
        return False

    if not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9.\-:]*",
        target,
    ):
        return False

    lowered = target.lower()

    blocked = {
        "localhost",
        "localhost.localdomain",
        "0.0.0.0",
        "::",
        "::1",
    }

    return lowered not in blocked


def valid_username(username: str) -> bool:
    return bool(
        username
        and len(username) <= 32
        and re.fullmatch(r"[A-Za-z0-9._-]+", username)
    )


def job_file(job_id: str):
    return JOBS_DIR / f"{job_id}.json"


def load_job(job_id: str):
    path = job_file(job_id)

    if not path.exists():
        return None

    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def save_job(job):
    path = job_file(job["id"])

    tmp = path.with_suffix(".tmp")

    tmp.write_text(
        json.dumps(
            job,
            indent=2,
        )
    )

    tmp.replace(path)


def update_job(job_id, **changes):
    job = load_job(job_id)

    if not job:
        return None

    job.update(changes)
    job["updated_at"] = now()

    save_job(job)

    return job


def append_log(job_id, message):
    job = load_job(job_id)

    if not job:
        return

    timestamp = datetime.now().strftime("%H:%M:%S")

    line = f"[{timestamp}] {message}"

    job.setdefault("logs", []).append(line)

    # Prevent unlimited log growth.
    job["logs"] = job["logs"][-2000:]

    job["updated_at"] = now()

    save_job(job)


def ssh_base(target, port):
    return [
        "ssh",
        "-i",
        SSH_KEY_PATH,
        "-p",
        str(port),
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=2",
        f"root@{target}",
    ]


def run_ssh(target, port, command, timeout=60):
    cmd = ssh_base(target, port) + [
        "bash",
        "-lc",
        command,
    ]

    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def verify_ssh(target, port):
    result = run_ssh(
        target,
        port,
        "printf KENGKOY_SSH_OK",
        timeout=20,
    )

    return (
        result.returncode == 0
        and result.stdout.strip() == "KENGKOY_SSH_OK"
    ), result


def prepare_remote(target, port):
    public_key = Path("/keys/kengkoy_installer.pub").read_text().strip()

    encoded_key = base64.b64encode(
        public_key.encode()
    ).decode()

    command = (
        "mkdir -p /root/.ssh && "
        "chmod 700 /root/.ssh && "
        f"echo {shlex.quote(encoded_key)} | base64 -d "
        "> /root/.kengkoy_reinstall_key && "
        "chmod 600 /root/.kengkoy_reinstall_key && "
        f"curl -fL --retry 3 "
        f"{shlex.quote(REINSTALL_URL)} "
        "-o /root/reinstall.sh && "
        "chmod 700 /root/reinstall.sh"
    )

    result = run_ssh(
        target,
        port,
        command,
        timeout=90,
    )

    return result


def build_command(os_id, username, password):
    os_info = OS_CATALOG[os_id]

    if os_info["family"] == "windows":
        return (
            "bash /root/reinstall.sh windows "
            f"--image-name {shlex.quote(os_info['image'])} "
            "--lang en-us "
            "--rdp-port 3389 "
            f"--username {shlex.quote(username)} "
            f"--password {shlex.quote(password)} "
            "--ssh-key /root/.kengkoy_reinstall_key"
        )

    parts = [
        "bash",
        "/root/reinstall.sh",
        os_info["family"],
    ]

    if os_info["version"]:
        parts.append(os_info["version"])

    parts.extend(
        [
            "--username",
            username,
            "--ssh-key",
            "/root/.kengkoy_reinstall_key",
        ]
    )

    if password:
        parts.extend(
            [
                "--password",
                password,
            ]
        )

    return " ".join(shlex.quote(x) for x in parts)


def redacted_command(os_id, username):
    os_info = OS_CATALOG[os_id]

    if os_info["family"] == "windows":
        return (
            "bash /root/reinstall.sh windows "
            f"--image-name {shlex.quote(os_info['image'])} "
            "--lang en-us "
            "--rdp-port 3389 "
            f"--username {shlex.quote(username)} "
            "--password ******** "
            "--ssh-key /root/.kengkoy_reinstall_key"
        )

    command = (
        f"bash /root/reinstall.sh "
        f"{os_info['family']}"
    )

    if os_info["version"]:
        command += f" {os_info['version']}"

    command += (
        f" --username {shlex.quote(username)}"
        " --ssh-key /root/.kengkoy_reinstall_key"
    )

    command += " --password ********"

    return command


# ============================================================
# JOB EXECUTION
# ============================================================

def run_job(
    job_id,
    target,
    port,
    os_id,
    username,
    password,
):
    try:
        update_job(
            job_id,
            status="connecting",
            progress=10,
        )

        append_log(
            job_id,
            f"Connecting to root@{target}:{port}",
        )

        ok, result = verify_ssh(
            target,
            port,
        )

        if not ok:
            append_log(
                job_id,
                "SSH connection failed.",
            )

            if result.stderr:
                append_log(
                    job_id,
                    result.stderr.strip(),
                )

            update_job(
                job_id,
                status="failed",
                progress=0,
                error="Unable to connect through SSH.",
            )
            return

        append_log(
            job_id,
            "SSH connection successful.",
        )

        update_job(
            job_id,
            status="preparing",
            progress=25,
        )

        append_log(
            job_id,
            "Downloading latest reinstall.sh to target VPS...",
        )

        result = prepare_remote(
            target,
            port,
        )

        if result.returncode != 0:
            append_log(
                job_id,
                "Failed to prepare target VPS.",
            )

            if result.stdout:
                append_log(
                    job_id,
                    result.stdout.strip(),
                )

            if result.stderr:
                append_log(
                    job_id,
                    result.stderr.strip(),
                )

            update_job(
                job_id,
                status="failed",
                progress=0,
                error="Remote preparation failed.",
            )
            return

        append_log(
            job_id,
            "Target VPS prepared successfully.",
        )

        command = build_command(
            os_id,
            username,
            password,
        )

        append_log(
            job_id,
            "Starting OS installation...",
        )

        append_log(
            job_id,
            "Command: " + redacted_command(
                os_id,
                username,
            ),
        )

        update_job(
            job_id,
            status="installing",
            progress=40,
        )

        ssh_command = ssh_base(
            target,
            port,
        ) + [
            "bash",
            "-lc",
            command,
        ]

        process = subprocess.Popen(
            ssh_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        for line in process.stdout:
            line = line.rstrip()

            if line:
                append_log(
                    job_id,
                    line,
                )

        return_code = process.wait()

        if return_code == 0:
            append_log(
                job_id,
                "Remote reinstall command completed.",
            )

            append_log(
                job_id,
                "The target VPS should now reboot into the selected OS.",
            )

            append_log(
                job_id,
                "The controller does not treat this as confirmation that the new OS has booted.",
            )

            update_job(
                job_id,
                status="reinstall_scheduled",
                progress=100,
            )

        else:
            append_log(
                job_id,
                f"SSH/reinstall process exited with code {return_code}.",
            )

            update_job(
                job_id,
                status="failed",
                progress=0,
                error=f"Remote process exited with code {return_code}.",
            )

    except subprocess.TimeoutExpired:
        append_log(
            job_id,
            "Operation timed out.",
        )

        update_job(
            job_id,
            status="failed",
            progress=0,
            error="Operation timed out.",
        )

    except Exception as exc:
        append_log(
            job_id,
            f"Unexpected error: {exc}",
        )

        update_job(
            job_id,
            status="failed",
            progress=0,
            error=str(exc),
        )


# ============================================================
# ROUTES
# ============================================================

@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "kengkoy-installer",
    }


@app.get(
    "/",
    response_class=HTMLResponse,
)
def index(request: Request):
    if not authenticated(request):
        return RedirectResponse(
            "/login",
            status_code=303,
        )

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "os_catalog": OS_CATALOG,
            "allowed_ports": sorted(ALLOWED_SSH_PORTS),
        },
    )


@app.get(
    "/login",
    response_class=HTMLResponse,
)
def login_page(request: Request):
    if authenticated(request):
        return RedirectResponse(
            "/",
            status_code=303,
        )

    return templates.TemplateResponse(
        "login.html",
        {
            "request": request,
            "error": None,
        },
    )


@app.post(
    "/login",
    response_class=HTMLResponse,
)
def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    if (
        username == ADMIN_USER
        and password == ADMIN_PASSWORD
    ):
        request.session["authenticated"] = True

        return RedirectResponse(
            "/",
            status_code=303,
        )

    return templates.TemplateResponse(
        "login.html",
        {
            "request": request,
            "error": "Invalid username or password.",
        },
        status_code=401,
    )


@app.post("/logout")
def logout(request: Request):
    request.session.clear()

    return RedirectResponse(
        "/login",
        status_code=303,
    )


@app.post("/install")
def install(
    request: Request,
    target: str = Form(...),
    port: int = Form(...),
    os_id: str = Form(...),
    username: str = Form(...),
    password: str = Form(""),
    confirm: str = Form(...),
):
    if not authenticated(request):
        return RedirectResponse(
            "/login",
            status_code=303,
        )

    target = target.strip()
    username = username.strip()

    if not valid_target(target):
        return JSONResponse(
            {
                "error": "Invalid target hostname or IP address."
            },
            status_code=400,
        )

    if port not in ALLOWED_SSH_PORTS:
        return JSONResponse(
            {
                "error": "SSH port is not allowed."
            },
            status_code=400,
        )

    if os_id not in OS_CATALOG:
        return JSONResponse(
            {
                "error": "Invalid operating system."
            },
            status_code=400,
        )

    if not valid_username(username):
        return JSONResponse(
            {
                "error": "Invalid username."
            },
            status_code=400,
        )

    if confirm != "WIPE":
        return JSONResponse(
            {
                "error": "You must type WIPE."
            },
            status_code=400,
        )

    os_info = OS_CATALOG[os_id]

    if os_info["family"] == "windows" and not password:
        return JSONResponse(
            {
                "error": "Windows installations require a password."
            },
            status_code=400,
        )

    job_id = uuid.uuid4().hex

    job = {
        "id": job_id,
        "target": target,
        "port": port,
        "os_id": os_id,
        "os_name": os_info["name"],
        "username": username,
        "status": "queued",
        "progress": 0,
        "created_at": now(),
        "updated_at": now(),
        "logs": [],
    }

    save_job(job)

    append_log(
        job_id,
        f"Queued installation of {os_info['name']}.",
    )

    thread = threading.Thread(
        target=run_job,
        args=(
            job_id,
            target,
            port,
            os_id,
            username,
            password,
        ),
        daemon=True,
    )

    thread.start()

    return RedirectResponse(
        f"/jobs/{job_id}",
        status_code=303,
    )


@app.get(
    "/jobs/{job_id}",
    response_class=HTMLResponse,
)
def job_page(
    request: Request,
    job_id: str,
):
    if not authenticated(request):
        return RedirectResponse(
            "/login",
            status_code=303,
        )

    job = load_job(job_id)

    if not job:
        return HTMLResponse(
            "Job not found.",
            status_code=404,
        )

    return templates.TemplateResponse(
        "job.html",
        {
            "request": request,
            "job": job,
        },
    )


@app.get("/api/jobs/{job_id}")
def job_api(
    request: Request,
    job_id: str,
):
    if not authenticated(request):
        return JSONResponse(
            {
                "error": "Unauthorized"
            },
            status_code=401,
        )

    job = load_job(job_id)

    if not job:
        return JSONResponse(
            {
                "error": "Job not found"
            },
            status_code=404,
        )

    return job


@app.get("/api/jobs")
def jobs_api(request: Request):
    if not authenticated(request):
        return JSONResponse(
            {
                "error": "Unauthorized"
            },
            status_code=401,
        )

    jobs = []

    for path in sorted(
        JOBS_DIR.glob("*.json"),
        key=lambda x: x.stat().st_mtime,
        reverse=True,
    )[:50]:
        try:
            jobs.append(
                json.loads(
                    path.read_text()
                )
            )
        except Exception:
            pass

    return jobs
PYEOF

# ------------------------------------------------------------
# login.html
# ------------------------------------------------------------

cat > "${APP_DIR}/app/templates/login.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kengkoy Installer</title>
<link rel="stylesheet" href="/static/style.css">
</head>

<body class="login-body">

<div class="login-card">

    <div class="brand">
        <div class="brand-logo">K</div>
        <div>
            <div class="brand-name">Kengkoy Installer</div>
            <div class="brand-sub">VPS OS deployment panel</div>
        </div>
    </div>

    <div class="login-title">
        Sign in
    </div>

    <div class="login-description">
        Sign in to manage remote VPS installations.
    </div>

    {% if error %}
    <div class="alert danger">
        {{ error }}
    </div>
    {% endif %}

    <form method="post" action="/login">

        <label>Username</label>
        <input
            type="text"
            name="username"
            autocomplete="username"
            required
        >

        <label>Password</label>
        <input
            type="password"
            name="password"
            autocomplete="current-password"
            required
        >

        <button class="primary-button" type="submit">
            Sign in
        </button>

    </form>

    <div class="login-footer">
        Kengkoy Installer
    </div>

</div>

</body>
</html>
HTMLEOF

# ------------------------------------------------------------
# index.html
# ------------------------------------------------------------

cat > "${APP_DIR}/app/templates/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">

<title>Kengkoy Installer</title>

<link rel="stylesheet" href="/static/style.css">
</head>

<body>

<header class="topbar">

    <div class="brand">
        <div class="brand-logo">K</div>

        <div>
            <div class="brand-name">
                Kengkoy Installer
            </div>

            <div class="brand-sub">
                VPS deployment panel
            </div>
        </div>
    </div>

    <form method="post" action="/logout">
        <button class="logout-button">
            Logout
        </button>
    </form>

</header>


<main class="container">

    <div class="page-heading">

        <div>
            <h1>Reinstall VPS</h1>

            <p>
                Deploy a fresh operating system using
                bin456789/reinstall.
            </p>
        </div>

    </div>


    <form
        method="post"
        action="/install"
        id="installForm"
    >

        <section class="card">

            <div class="card-header">

                <div>
                    <h2>Target VPS</h2>

                    <p>
                        Enter the VPS that will be reinstalled.
                    </p>
                </div>

                <div class="step">
                    01
                </div>

            </div>


            <div class="grid-2">

                <div class="field">

                    <label>
                        IP address / hostname
                    </label>

                    <input
                        type="text"
                        name="target"
                        placeholder="203.0.113.10"
                        required
                    >

                </div>


                <div class="field">

                    <label>
                        SSH port
                    </label>

                    <select name="port">

                        {% for p in allowed_ports %}

                        <option value="{{ p }}">
                            {{ p }}
                        </option>

                        {% endfor %}

                    </select>

                </div>

            </div>

        </section>


        <section class="card">

            <div class="card-header">

                <div>
                    <h2>Operating System</h2>

                    <p>
                        Choose the operating system to install.
                    </p>
                </div>

                <div class="step">
                    02
                </div>

            </div>


            <div class="os-grid">

                {% for id, os in os_catalog.items() %}

                <label class="os-option">

                    <input
                        type="radio"
                        name="os_id"
                        value="{{ id }}"
                        data-family="{{ os.family }}"
                        data-name="{{ os.name }}"
                        {% if loop.first %}checked{% endif %}
                    >

                    <div class="os-card">

                        <div class="os-icon">
                            {{ os.icon }}
                        </div>

                        <div>
                            <strong>
                                {{ os.name }}
                            </strong>

                            <span>
                                {% if os.family == "windows" %}
                                    Windows
                                {% else %}
                                    Linux
                                {% endif %}
                            </span>
                        </div>

                    </div>

                </label>

                {% endfor %}

            </div>

        </section>


        <section class="card">

            <div class="card-header">

                <div>
                    <h2>New OS credentials</h2>

                    <p>
                        These credentials will be configured
                        on the new operating system.
                    </p>
                </div>

                <div class="step">
                    03
                </div>

            </div>


            <div class="grid-2">

                <div class="field">

                    <label>
                        Username
                    </label>

                    <input
                        type="text"
                        name="username"
                        id="username"
                        value="root"
                        required
                    >

                    <small>
                        Linux normally uses root.
                        Windows normally uses administrator.
                    </small>

                </div>


                <div class="field">

                    <label>
                        Password
                    </label>

                    <div class="password-row">

                        <input
                            type="password"
                            name="password"
                            id="password"
                            autocomplete="new-password"
                        >

                        <button
                            type="button"
                            class="secondary-button"
                            id="generatePassword"
                        >
                            Generate
                        </button>

                    </div>

                    <small>
                        Required for Windows.
                    </small>

                </div>

            </div>

        </section>


        <section class="danger-card">

            <div class="danger-icon">
                !
            </div>

            <div>

                <h2>
                    Destructive operation
                </h2>

                <p>
                    Reinstalling a VPS can permanently erase
                    the existing operating system, files,
                    applications and data on the target disk.
                </p>

                <p>
                    Make sure you have a backup before continuing.
                </p>

            </div>

        </section>


        <section class="card confirmation">

            <div class="card-header">

                <div>
                    <h2>Confirm installation</h2>

                    <p>
                        Type WIPE to enable the installation.
                    </p>
                </div>

                <div class="step">
                    04
                </div>

            </div>


            <input
                class="wipe-input"
                type="text"
                name="confirm"
                id="confirm"
                placeholder="Type WIPE"
                autocomplete="off"
                required
            >

            <button
                class="danger-button"
                id="installButton"
                type="submit"
                disabled
            >
                Reinstall VPS
            </button>

        </section>

    </form>

</main>


<script>

const confirmInput =
    document.getElementById("confirm");

const installButton =
    document.getElementById("installButton");

const password =
    document.getElementById("password");

const username =
    document.getElementById("username");

const generatePassword =
    document.getElementById("generatePassword");

function updateButton() {

    installButton.disabled =
        confirmInput.value !== "WIPE";

}

confirmInput.addEventListener(
    "input",
    updateButton
);


generatePassword.addEventListener(
    "click",
    function () {

        const chars =
            "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%";

        let result = "";

        for (
            let i = 0;
            i < 20;
            i++
        ) {
            result += chars[
                Math.floor(
                    Math.random() * chars.length
                )
            ];
        }

        password.type = "text";
        password.value = result;

    }
);


document.querySelectorAll(
    'input[name="os_id"]'
).forEach(
    function (radio) {

        radio.addEventListener(
            "change",
            function () {

                if (
                    this.dataset.family ===
                    "windows"
                ) {

                    username.value =
                        "administrator";

                    password.required =
                        true;

                } else {

                    username.value =
                        "root";

                    password.required =
                        false;

                }

            }
        );

    }
);


document.getElementById(
    "installForm"
).addEventListener(
    "submit",
    function (event) {

        if (
            !confirm(
                "WARNING: This will permanently reinstall the target VPS and may destroy all data. Continue?"
            )
        ) {
            event.preventDefault();
        }

    }
);

</script>

</body>
</html>
HTMLEOF

# ------------------------------------------------------------
# job.html
# ------------------------------------------------------------

cat > "${APP_DIR}/app/templates/job.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>

<meta charset="UTF-8">
<meta
    name="viewport"
    content="width=device-width,initial-scale=1"
>

<title>Installation Job</title>

<link rel="stylesheet" href="/static/style.css">

</head>

<body>

<header class="topbar">

    <div class="brand">

        <div class="brand-logo">
            K
        </div>

        <div>

            <div class="brand-name">
                Kengkoy Installer
            </div>

            <div class="brand-sub">
                Installation job
            </div>

        </div>

    </div>


    <a class="back-button" href="/">
        ← Dashboard
    </a>

</header>


<main class="container">

    <div class="page-heading">

        <div>

            <h1>
                Installation job
            </h1>

            <p>
                Job ID:
                <code>{{ job.id }}</code>
            </p>

        </div>

    </div>


    <section class="card">

        <div class="job-header">

            <div>

                <div class="job-os">
                    {{ job.os_name }}
                </div>

                <div class="job-target">
                    root@{{ job.target }}:{{ job.port }}
                </div>

            </div>

            <div
                id="status"
                class="status queued"
            >
                {{ job.status }}
            </div>

        </div>


        <div class="progress-wrap">

            <div class="progress">

                <div
                    id="progressBar"
                    class="progress-bar"
                    style="width:{{ job.progress }}%"
                ></div>

            </div>

            <div class="progress-text">
                <span id="progressText">
                    {{ job.progress }}%
                </span>
            </div>

        </div>

    </section>


    <section class="card">

        <div class="card-header">

            <div>

                <h2>
                    Live console
                </h2>

                <p>
                    Output from the remote installation.
                </p>

            </div>

        </div>


        <pre
            class="terminal"
            id="terminal"
        >Loading...</pre>

    </section>


    <section class="info-card">

        <strong>
            Important
        </strong>

        <p>
            A status of
            <b>reinstall_scheduled</b>
            means the remote reinstall command completed.
            The target VPS must still reboot into the new OS.
        </p>

    </section>

</main>


<script>

const jobId =
    "{{ job.id }}";

const terminal =
    document.getElementById(
        "terminal"
    );

const status =
    document.getElementById(
        "status"
    );

const progressBar =
    document.getElementById(
        "progressBar"
    );

const progressText =
    document.getElementById(
        "progressText"
    );


function statusClass(value) {

    status.className =
        "status " + value;

    status.textContent =
        value.replaceAll(
            "_",
            " "
        );

}


async function refresh() {

    try {

        const response =
            await fetch(
                "/api/jobs/" +
                jobId +
                "?t=" +
                Date.now()
            );

        if (!response.ok) {
            return;
        }

        const job =
            await response.json();

        statusClass(
            job.status
        );

        progressBar.style.width =
            job.progress + "%";

        progressText.textContent =
            job.progress + "%";

        terminal.textContent =
            (job.logs || []).join(
                "\n"
            );

        terminal.scrollTop =
            terminal.scrollHeight;

        if (
            job.status !== "failed" &&
            job.status !== "reinstall_scheduled"
        ) {

            setTimeout(
                refresh,
                1500
            );

        }

    } catch (error) {

        setTimeout(
            refresh,
            3000
        );

    }

}


refresh();

</script>

</body>
</html>
HTMLEOF

# ------------------------------------------------------------
# style.css
# ------------------------------------------------------------

cat > "${APP_DIR}/app/static/style.css" <<'CSSEOF'
* {
    box-sizing: border-box;
}

:root {
    --bg: #f6f7fb;
    --surface: #ffffff;
    --surface-soft: #fafbfc;
    --border: #e5e7eb;
    --border-dark: #d1d5db;
    --text: #171923;
    --muted: #6b7280;
    --dim: #9ca3af;
    --accent: #111827;
    --danger: #dc2626;
    --danger-bg: #fef2f2;
    --success: #059669;
    --warning: #d97706;
    --shadow: 0 10px 35px rgba(15, 23, 42, .06);
}

html,
body {
    margin: 0;
    padding: 0;
}

body {
    background: var(--bg);
    color: var(--text);
    font-family:
        Inter,
        ui-sans-serif,
        system-ui,
        -apple-system,
        BlinkMacSystemFont,
        "Segoe UI",
        sans-serif;
}

button,
input,
select {
    font: inherit;
}

button {
    cursor: pointer;
}

.topbar {
    height: 72px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);

    display: flex;
    align-items: center;
    justify-content: space-between;

    padding: 0 32px;
}

.brand {
    display: flex;
    align-items: center;
    gap: 12px;
}

.brand-logo {
    width: 40px;
    height: 40px;

    display: flex;
    align-items: center;
    justify-content: center;

    background: #111827;
    color: white;

    border-radius: 11px;

    font-weight: 800;
    font-size: 19px;
}

.brand-name {
    font-weight: 750;
    font-size: 15px;
}

.brand-sub {
    margin-top: 2px;
    color: var(--muted);
    font-size: 12px;
}

.container {
    width: min(980px, calc(100% - 32px));
    margin: 38px auto 80px;
}

.page-heading {
    margin-bottom: 24px;
}

.page-heading h1 {
    margin: 0 0 7px;
    font-size: 30px;
    letter-spacing: -.7px;
}

.page-heading p {
    margin: 0;
    color: var(--muted);
}

.card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 16px;
    box-shadow: var(--shadow);
    padding: 26px;
    margin-bottom: 18px;
}

.card-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 22px;
}

.card-header h2 {
    margin: 0 0 5px;
    font-size: 17px;
}

.card-header p {
    margin: 0;
    color: var(--muted);
    font-size: 13px;
}

.step {
    color: var(--dim);
    font-size: 12px;
    font-weight: 700;
}

.grid-2 {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 18px;
}

.field label {
    display: block;
    font-size: 13px;
    font-weight: 650;
    margin-bottom: 8px;
}

.field small {
    display: block;
    color: var(--muted);
    font-size: 11px;
    margin-top: 7px;
}

input,
select {
    width: 100%;
    height: 46px;

    background: white;

    border: 1px solid var(--border-dark);
    border-radius: 10px;

    padding: 0 13px;

    color: var(--text);

    outline: none;

    transition:
        border-color .15s,
        box-shadow .15s;
}

input:focus,
select:focus {
    border-color: #6b7280;
    box-shadow: 0 0 0 3px rgba(17, 24, 39, .06);
}

.os-grid {
    display: grid;
    grid-template-columns:
        repeat(3, minmax(0, 1fr));
    gap: 12px;
}

.os-option input {
    display: none;
}

.os-card {
    min-height: 78px;

    border: 1px solid var(--border);
    border-radius: 12px;

    padding: 14px;

    display: flex;
    align-items: center;
    gap: 12px;

    cursor: pointer;

    transition:
        border-color .15s,
        box-shadow .15s,
        transform .15s;
}

.os-card:hover {
    transform: translateY(-1px);
    box-shadow: 0 7px 20px rgba(15,23,42,.06);
}

.os-option input:checked + .os-card {
    border-color: #111827;
    box-shadow:
        0 0 0 2px #111827 inset;
}

.os-icon {
    width: 38px;
    height: 38px;

    flex: 0 0 38px;

    display: flex;
    align-items: center;
    justify-content: center;

    background: #f3f4f6;
    border-radius: 10px;

    font-weight: 800;
}

.os-card strong {
    display: block;
    font-size: 13px;
}

.os-card span {
    display: block;
    margin-top: 4px;
    font-size: 11px;
    color: var(--muted);
}

.password-row {
    display: flex;
    gap: 8px;
}

.password-row input {
    min-width: 0;
}

.primary-button,
.secondary-button,
.danger-button,
.logout-button,
.back-button {
    border: 0;
    border-radius: 10px;

    height: 44px;

    padding: 0 17px;

    font-weight: 650;

    text-decoration: none;

    display: inline-flex;
    align-items: center;
    justify-content: center;
}

.primary-button {
    width: 100%;
    margin-top: 20px;
    background: #111827;
    color: white;
}

.primary-button:hover {
    background: #000;
}

.secondary-button {
    background: #f3f4f6;
    color: #111827;
    white-space: nowrap;
}

.logout-button,
.back-button {
    background: #f3f4f6;
    color: #374151;
}

.logout-button:hover,
.back-button:hover,
.secondary-button:hover {
    background: #e5e7eb;
}

.danger-card {
    background: var(--danger-bg);
    border: 1px solid #fecaca;
    color: #7f1d1d;

    border-radius: 16px;

    padding: 22px;

    display: flex;
    gap: 15px;

    margin-bottom: 18px;
}

.danger-icon {
    width: 36px;
    height: 36px;

    flex: 0 0 36px;

    display: flex;
    align-items: center;
    justify-content: center;

    border-radius: 50%;

    background: #fee2e2;
    color: var(--danger);

    font-weight: 800;
}

.danger-card h2 {
    margin: 0 0 6px;
    font-size: 16px;
}

.danger-card p {
    margin: 5px 0;
    font-size: 13px;
    line-height: 1.55;
}

.confirmation {
    margin-bottom: 0;
}

.wipe-input {
    margin-bottom: 12px;
}

.danger-button {
    width: 100%;
    background: var(--danger);
    color: white;
}

.danger-button:hover:not(:disabled) {
    background: #b91c1c;
}

.danger-button:disabled {
    opacity: .45;
    cursor: not-allowed;
}

.alert {
    padding: 12px;
    border-radius: 10px;
    margin: 15px 0;
    font-size: 13px;
}

.alert.danger {
    background: #fef2f2;
    color: #991b1b;
    border: 1px solid #fecaca;
}

.login-body {
    min-height: 100vh;

    display: flex;
    align-items: center;
    justify-content: center;

    padding: 20px;
}

.login-card {
    width: min(410px, 100%);

    background: white;

    border: 1px solid var(--border);
    border-radius: 18px;

    padding: 32px;

    box-shadow: 0 20px 60px rgba(15,23,42,.09);
}

.login-card .brand {
    margin-bottom: 32px;
}

.login-title {
    font-size: 24px;
    font-weight: 750;
    margin-bottom: 7px;
}

.login-description {
    color: var(--muted);
    font-size: 13px;
    margin-bottom: 22px;
}

.login-card label {
    display: block;
    font-size: 13px;
    font-weight: 650;
    margin: 15px 0 8px;
}

.login-footer {
    text-align: center;
    color: var(--dim);
    font-size: 11px;
    margin-top: 25px;
}

.job-header {
    display: flex;
    justify-content: space-between;
    gap: 20px;
    align-items: center;
}

.job-os {
    font-size: 18px;
    font-weight: 750;
}

.job-target {
    color: var(--muted);
    margin-top: 5px;
    font-size: 13px;
}

.status {
    border-radius: 999px;
    padding: 7px 11px;
    font-size: 11px;
    font-weight: 750;
    text-transform: uppercase;
    white-space: nowrap;
}

.status.queued {
    background: #f3f4f6;
    color: #4b5563;
}

.status.connecting,
.status.preparing,
.status.installing {
    background: #eff6ff;
    color: #1d4ed8;
}

.status.reinstall_scheduled {
    background: #ecfdf5;
    color: #047857;
}

.status.failed {
    background: #fef2f2;
    color: #b91c1c;
}

.progress-wrap {
    margin-top: 24px;
}

.progress {
    height: 10px;
    background: #f0f1f4;
    border-radius: 999px;
    overflow: hidden;
}

.progress-bar {
    height: 100%;
    background: #111827;
    border-radius: inherit;
    transition: width .4s ease;
}

.progress-text {
    color: var(--muted);
    font-size: 11px;
    text-align: right;
    margin-top: 7px;
}

.terminal {
    margin: 0;

    min-height: 400px;
    max-height: 650px;

    overflow: auto;

    background: #0b0d11;
    color: #d1d5db;

    border-radius: 12px;

    padding: 18px;

    font-family:
        ui-monospace,
        SFMono-Regular,
        Menlo,
        Monaco,
        Consolas,
        monospace;

    font-size: 12px;
    line-height: 1.6;
}

.info-card {
    padding: 18px;

    border: 1px solid var(--border);
    border-radius: 13px;

    background: var(--surface-soft);

    color: var(--muted);

    font-size: 13px;
}

.info-card strong {
    color: var(--text);
}

.info-card p {
    margin: 7px 0 0;
    line-height: 1.5;
}

code {
    background: #f3f4f6;
    border-radius: 5px;
    padding: 2px 5px;
    font-size: 11px;
}

@media (max-width: 760px) {

    .topbar {
        padding: 0 16px;
    }

    .container {
        width: min(100% - 20px, 980px);
        margin-top: 25px;
    }

    .grid-2 {
        grid-template-columns: 1fr;
    }

    .os-grid {
        grid-template-columns: 1fr 1fr;
    }

    .card {
        padding: 19px;
    }

    .job-header {
        align-items: flex-start;
        flex-direction: column;
    }

}

@media (max-width: 480px) {

    .os-grid {
        grid-template-columns: 1fr;
    }

    .page-heading h1 {
        font-size: 25px;
    }

}
CSSEOF

# ------------------------------------------------------------
# Health check
# ------------------------------------------------------------

cat > "${APP_DIR}/scripts/healthcheck.sh" <<'EOF'
#!/usr/bin/env bash

set -e

curl -fsS \
    http://127.0.0.1:8080/health \
    >/dev/null
EOF

chmod +x "${APP_DIR}/scripts/healthcheck.sh"

# ------------------------------------------------------------
# Permissions
# ------------------------------------------------------------

chmod 600 "${APP_DIR}/.env"
chmod 700 "${APP_DIR}"
chmod 755 "${APP_DIR}/app"
chmod 755 "${APP_DIR}/scripts"

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------

log "BUILDING KENGKOY INSTALLER"

cd "${APP_DIR}"

docker compose down --remove-orphans >/dev/null 2>&1 || true

docker compose build --no-cache

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------

log "STARTING KENGKOY INSTALLER"

docker compose up -d

sleep 5

# ------------------------------------------------------------
# Verify
# ------------------------------------------------------------

log "VERIFYING INSTALLATION"

docker compose ps

echo
echo "Checking application..."

if curl -fsS \
    http://127.0.0.1:8088/health \
    >/dev/null 2>&1; then

    echo "Application health check: OK"

else

    echo
    echo "Application health check failed."
    echo
    docker compose logs --tail=100
    exit 1

fi

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then

    echo
    echo "UFW detected."

    if ufw status 2>/dev/null | grep -q "Status: active"; then

        echo "Opening TCP port 8088..."

        ufw allow 8088/tcp >/dev/null || true

    fi

fi

# ------------------------------------------------------------
# Final information
# ------------------------------------------------------------

PUBLIC_IP=""

if command -v curl >/dev/null 2>&1; then
    PUBLIC_IP="$(
        curl -4 -fsS \
        --max-time 5 \
        https://api.ipify.org \
        2>/dev/null || true
    )"
fi

echo
echo
echo "############################################################"
echo "#                                                          #"
echo "#              KENGKOY INSTALLER READY                    #"
echo "#                                                          #"
echo "############################################################"
echo

if [[ -n "${PUBLIC_IP}" ]]; then
    echo "Panel:"
    echo "  http://${PUBLIC_IP}:8088"
else
    echo "Panel:"
    echo "  http://YOUR_SERVER_IP:8088"
fi

echo
echo "Project:"
echo "  ${APP_DIR}"

echo
echo "Controller private key:"
echo "  ${SSH_KEY}"

echo
echo "Controller public key:"
echo "  ${SSH_KEY}.pub"

echo
echo "============================================================"
echo "PUBLIC KEY FOR TARGET VPS"
echo "============================================================"
cat "${SSH_KEY}.pub"
echo
echo "============================================================"

echo
echo "Add the public key above to the TARGET VPS:"
echo
echo "  /root/.ssh/authorized_keys"
echo
echo "Then test:"
echo
echo "  ssh -i ${SSH_KEY} root@TARGET_IP"
echo

echo "Useful commands:"
echo
echo "  cd ${APP_DIR}"
echo "  docker compose ps"
echo "  docker compose logs -f"
echo "  docker compose restart"
echo "  docker compose down"
echo

echo "Backup, if an older installation existed:"
echo "  ${BACKUP_DIR}"
echo

echo "IMPORTANT:"
echo "The panel itself does NOT reinstall this controller VPS."
echo "Only the VPS entered in the web panel is targeted."
echo
echo "Done."
