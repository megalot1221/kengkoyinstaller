#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# XNAMSO TELEGRAM MINI APP
# Ubuntu 26.04 One-Shot Installer
# ============================================================

APP_NAME="xnamso-miniapp"
APP_DIR="/opt/xnamso-miniapp"
APP_DOMAIN="${APP_DOMAIN:-app.xnamso.com}"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8000/api/v1}"
BOT_ENV="/opt/xnamso-bot/.env"
SERVICE_NAME="xnamso-miniapp"

echo
echo "============================================================"
echo "        XNAMSO TELEGRAM MINI APP INSTALLER"
echo "============================================================"
echo
echo "Domain : ${APP_DOMAIN}"
echo "App    : ${APP_DIR}"
echo "Backend: ${BACKEND_URL}"
echo

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: Run this installer as root."
    exit 1
fi

if [ ! -f "${BOT_ENV}" ]; then
    echo "ERROR: ${BOT_ENV} was not found."
    echo "The installer expects your existing Xnamso bot installation."
    exit 1
fi

BOT_TOKEN="$(grep -E '^BOT_TOKEN=' "${BOT_ENV}" | head -n1 | cut -d= -f2- || true)"
ADMIN_ID="$(grep -E '^ADMIN_ID=' "${BOT_ENV}" | head -n1 | cut -d= -f2- || true)"

if [ -z "${BOT_TOKEN}" ]; then
    echo "ERROR: BOT_TOKEN was not found in ${BOT_ENV}"
    exit 1
fi

echo "[1/12] Installing system packages..."

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx \
    certbot \
    python3 \
    python3-venv \
    python3-pip \
    sqlite3 \
    curl \
    openssl

echo "[2/12] Creating application..."

mkdir -p "${APP_DIR}/web"
mkdir -p "${APP_DIR}/data"

cat > "${APP_DIR}/requirements.txt" <<'REQ'
fastapi==0.116.1
uvicorn[standard]==0.35.0
httpx==0.28.1
python-dotenv==1.1.1
REQ

python3 -m venv "${APP_DIR}/venv"

"${APP_DIR}/venv/bin/pip" install --upgrade pip
"${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"

echo "[3/12] Creating environment..."

cat > "${APP_DIR}/.env" <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_ID=${ADMIN_ID}
APP_DOMAIN=${APP_DOMAIN}
BACKEND_URL=${BACKEND_URL}
DATABASE=${APP_DIR}/data/miniapp.db
EOF

chmod 600 "${APP_DIR}/.env"

echo "[4/12] Creating Mini App backend..."

cat > "${APP_DIR}/app.py" <<'PY'
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from pathlib import Path
from urllib.parse import parse_qsl

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

load_dotenv()

BOT_TOKEN = os.environ["BOT_TOKEN"]
BACKEND_URL = os.environ["BACKEND_URL"].rstrip("/")
DATABASE = os.environ["DATABASE"]

BASE_DIR = Path(__file__).resolve().parent
WEB_DIR = BASE_DIR / "web"

app = FastAPI(title="Xnamso Mini App")


# ============================================================
# DATABASE
# ============================================================

def db():
    conn = sqlite3.connect(DATABASE)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = db()

    conn.execute("""
        CREATE TABLE IF NOT EXISTS users (
            telegram_id INTEGER PRIMARY KEY,
            username TEXT,
            first_name TEXT,
            last_name TEXT,
            created_at INTEGER NOT NULL,
            last_seen INTEGER NOT NULL
        )
    """)

    conn.execute("""
        CREATE TABLE IF NOT EXISTS mailboxes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            telegram_id INTEGER NOT NULL,
            email TEXT NOT NULL,
            token TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE(telegram_id, email),
            FOREIGN KEY(telegram_id) REFERENCES users(telegram_id)
        )
    """)

    conn.commit()
    conn.close()


init_db()


# ============================================================
# TELEGRAM INIT DATA VALIDATION
# ============================================================

def validate_init_data(init_data: str):
    if not init_data:
        raise HTTPException(status_code=401, detail="Telegram authentication required")

    pairs = dict(parse_qsl(init_data, keep_blank_values=True))

    received_hash = pairs.pop("hash", None)

    if not received_hash:
        raise HTTPException(status_code=401, detail="Missing Telegram hash")

    auth_date = pairs.get("auth_date")

    if not auth_date:
        raise HTTPException(status_code=401, detail="Missing auth date")

    try:
        auth_timestamp = int(auth_date)
    except ValueError:
        raise HTTPException(status_code=401, detail="Invalid auth date")

    # Do not accept stale Telegram sessions.
    if abs(int(time.time()) - auth_timestamp) > 86400:
        raise HTTPException(status_code=401, detail="Telegram session expired")

    data_check_string = "\n".join(
        f"{key}={pairs[key]}"
        for key in sorted(pairs)
    )

    secret_key = hmac.new(
        b"WebAppData",
        BOT_TOKEN.encode(),
        hashlib.sha256
    ).digest()

    calculated_hash = hmac.new(
        secret_key,
        data_check_string.encode(),
        hashlib.sha256
    ).hexdigest()

    if not hmac.compare_digest(calculated_hash, received_hash):
        raise HTTPException(status_code=401, detail="Invalid Telegram authentication")

    user_raw = pairs.get("user")

    if not user_raw:
        raise HTTPException(status_code=401, detail="Telegram user missing")

    try:
        user = json.loads(user_raw)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid Telegram user")

    if "id" not in user:
        raise HTTPException(status_code=401, detail="Invalid Telegram user")

    return user


async def current_user(request: Request):
    init_data = request.headers.get("X-Telegram-Init-Data", "")
    user = validate_init_data(init_data)

    telegram_id = int(user["id"])

    conn = db()

    conn.execute("""
        INSERT INTO users
        (telegram_id, username, first_name, last_name, created_at, last_seen)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(telegram_id) DO UPDATE SET
            username=excluded.username,
            first_name=excluded.first_name,
            last_name=excluded.last_name,
            last_seen=excluded.last_seen
    """, (
        telegram_id,
        user.get("username"),
        user.get("first_name"),
        user.get("last_name"),
        int(time.time()),
        int(time.time()),
    ))

    conn.commit()
    conn.close()

    return user


# ============================================================
# BACKEND API
# ============================================================

async def backend_get(path: str):
    async with httpx.AsyncClient(timeout=15) as client:
        response = await client.get(BACKEND_URL + path)

    if response.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail=f"Backend returned HTTP {response.status_code}"
        )

    return response.json()


async def backend_post(path: str, payload: dict):
    async with httpx.AsyncClient(timeout=15) as client:
        response = await client.post(
            BACKEND_URL + path,
            json=payload
        )

    if response.status_code >= 400:
        try:
            detail = response.json()
        except Exception:
            detail = response.text

        raise HTTPException(
            status_code=502,
            detail=detail
        )

    return response.json()


# ============================================================
# API MODELS
# ============================================================

class GenerateRequest(BaseModel):
    username: str | None = None
    domain: str | None = None


# ============================================================
# FRONTEND
# ============================================================

@app.get("/")
async def index():
    return FileResponse(WEB_DIR / "index.html")


@app.get("/app.js")
async def javascript():
    return FileResponse(WEB_DIR / "app.js", media_type="application/javascript")


@app.get("/style.css")
async def css():
    return FileResponse(WEB_DIR / "style.css", media_type="text/css")


# ============================================================
# USER
# ============================================================

@app.get("/api/me")
async def me(request: Request):
    user = await current_user(request)

    return {
        "id": user["id"],
        "username": user.get("username"),
        "first_name": user.get("first_name"),
        "last_name": user.get("last_name"),
    }


# ============================================================
# DOMAINS
# ============================================================

@app.get("/api/domains")
async def domains(request: Request):
    await current_user(request)

    return await backend_get("/domains")


# ============================================================
# MAILBOXES
# ============================================================

@app.get("/api/mailboxes")
async def mailboxes(request: Request):
    user = await current_user(request)
    telegram_id = int(user["id"])

    conn = db()

    rows = conn.execute("""
        SELECT email, token, created_at
        FROM mailboxes
        WHERE telegram_id = ?
        ORDER BY id DESC
    """, (telegram_id,)).fetchall()

    conn.close()

    result = []

    for row in rows:
        try:
            mailbox = await backend_get(f"/{row['token']}/emails")
            emails = mailbox.get("emails", mailbox if isinstance(mailbox, list) else [])
        except Exception:
            emails = []

        result.append({
            "email": row["email"],
            "token": row["token"],
            "created_at": row["created_at"],
            "emails": emails,
            "email_count": len(emails),
        })

    return {"mailboxes": result}


# ============================================================
# GENERATE
# ============================================================

@app.post("/api/generate")
async def generate(request: Request, body: GenerateRequest):
    user = await current_user(request)
    telegram_id = int(user["id"])

    domains = await backend_get("/domains")
    available = domains.get("domains", [])

    domain = body.domain

    if domain and domain not in available:
        raise HTTPException(status_code=400, detail="Invalid domain")

    payload = {}

    if body.username:
        username = body.username.strip()

        if not username:
            raise HTTPException(status_code=400, detail="Invalid username")

        payload["username"] = username

    if domain:
        payload["domain"] = domain

    mailbox = await backend_post("/addresses", payload)

    email = mailbox.get("email")
    token = mailbox.get("token")

    if not email or not token:
        raise HTTPException(
            status_code=502,
            detail="Backend did not return mailbox credentials"
        )

    conn = db()

    conn.execute("""
        INSERT OR REPLACE INTO mailboxes
        (telegram_id, email, token, created_at)
        VALUES (?, ?, ?, ?)
    """, (
        telegram_id,
        email,
        token,
        int(time.time())
    ))

    conn.commit()
    conn.close()

    return {
        "email": email,
        "token": token,
        "expires_at": mailbox.get("expires_at"),
        "created_at": mailbox.get("created_at"),
    }


# ============================================================
# INBOX
# ============================================================

@app.get("/api/inbox")
async def inbox(request: Request, token: str):
    user = await current_user(request)
    telegram_id = int(user["id"])

    conn = db()

    row = conn.execute("""
        SELECT email
        FROM mailboxes
        WHERE telegram_id = ? AND token = ?
    """, (telegram_id, token)).fetchone()

    conn.close()

    if not row:
        raise HTTPException(status_code=403, detail="Mailbox does not belong to you")

    return await backend_get(f"/{token}/emails")


# ============================================================
# MESSAGE
# ============================================================

@app.get("/api/message/{email_id}")
async def message(request: Request, email_id: str, token: str):
    user = await current_user(request)
    telegram_id = int(user["id"])

    conn = db()

    row = conn.execute("""
        SELECT email
        FROM mailboxes
        WHERE telegram_id = ? AND token = ?
    """, (telegram_id, token)).fetchone()

    conn.close()

    if not row:
        raise HTTPException(status_code=403, detail="Mailbox does not belong to you")

    return await backend_get(f"/{token}/emails/{email_id}")


# ============================================================
# HEALTH
# ============================================================

@app.get("/health")
async def health():
    try:
        backend = await backend_get("/health")

        return {
            "status": "ok",
            "backend": backend
        }
    except Exception as exc:
        return JSONResponse(
            status_code=503,
            content={
                "status": "degraded",
                "error": str(exc)
            }
        )
PY

echo "[5/12] Creating Mini App interface..."

cat > "${APP_DIR}/web/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta
        name="viewport"
        content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"
    >

    <title>Xnamso Temp Mail</title>

    <script src="https://telegram.org/js/telegram-web-app.js?63"></script>

    <link rel="stylesheet" href="/style.css">
</head>

<body>

<div class="app">

    <header class="topbar">
        <div>
            <div class="brand">Xnamso</div>
            <div class="subtitle">Temporary Mail</div>
        </div>

        <button id="refreshTop" class="icon-button">↻</button>
    </header>

    <main>

        <section id="userCard" class="card user-card">
            <div class="avatar" id="avatar">X</div>

            <div>
                <div id="userName">Loading...</div>
                <div id="userUsername" class="muted"></div>
            </div>
        </section>


        <section class="card">

            <div class="section-title">
                <span>Generate mailbox</span>
            </div>

            <label>Domain</label>

            <select id="domain">
                <option>Loading...</option>
            </select>

            <label>Username</label>

            <input
                id="username"
                type="text"
                autocomplete="off"
                placeholder="Leave empty for random"
            >

            <button id="generate" class="primary">
                ✉️ Generate Email
            </button>

        </section>


        <section class="card">

            <div class="section-title">
                <span>My mailboxes</span>

                <button id="refresh" class="small-button">
                    Refresh
                </button>
            </div>

            <div id="mailboxes">
                <div class="loading">Loading...</div>
            </div>

        </section>


        <section id="messageView" class="card hidden">

            <button id="back" class="small-button">
                ← Back
            </button>

            <div id="messageContent"></div>

        </section>

    </main>

    <footer>
        Xnamso Temp Mail
    </footer>

</div>

<script src="/app.js"></script>

</body>
</html>
HTML


cat > "${APP_DIR}/web/style.css" <<'CSS'
:root {
    --bg: var(--tg-theme-bg-color, #f4f4f5);
    --card: var(--tg-theme-secondary-bg-color, #ffffff);
    --text: var(--tg-theme-text-color, #111111);
    --hint: var(--tg-theme-hint-color, #777777);
    --button: var(--tg-theme-button-color, #2481cc);
    --button-text: var(--tg-theme-button-text-color, #ffffff);
    --border: rgba(127,127,127,.18);
}

* {
    box-sizing: border-box;
}

body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family:
        -apple-system,
        BlinkMacSystemFont,
        "Segoe UI",
        Roboto,
        Arial,
        sans-serif;
}

.app {
    max-width: 680px;
    margin: auto;
    padding-bottom: 40px;
}

.topbar {
    position: sticky;
    top: 0;
    z-index: 10;

    display: flex;
    justify-content: space-between;
    align-items: center;

    padding:
        calc(12px + var(--tg-safe-area-inset-top, 0px))
        16px
        12px;

    background: var(--bg);
    border-bottom: 1px solid var(--border);
}

.brand {
    font-size: 21px;
    font-weight: 800;
}

.subtitle {
    font-size: 12px;
    color: var(--hint);
}

main {
    padding: 12px;
}

.card {
    background: var(--card);
    border-radius: 16px;
    padding: 16px;
    margin-bottom: 12px;
    border: 1px solid var(--border);
}

.user-card {
    display: flex;
    align-items: center;
    gap: 12px;
}

.avatar {
    width: 44px;
    height: 44px;
    border-radius: 50%;

    display: flex;
    align-items: center;
    justify-content: center;

    background: var(--button);
    color: var(--button-text);
    font-weight: 800;
}

.section-title {
    display: flex;
    align-items: center;
    justify-content: space-between;

    font-size: 16px;
    font-weight: 700;

    margin-bottom: 14px;
}

label {
    display: block;
    color: var(--hint);
    font-size: 12px;
    margin: 12px 0 6px;
}

input,
select {
    width: 100%;
    padding: 13px 12px;

    border: 1px solid var(--border);
    border-radius: 11px;

    background: var(--bg);
    color: var(--text);

    font-size: 15px;
    outline: none;
}

button {
    border: 0;
    cursor: pointer;
    font: inherit;
}

.primary {
    width: 100%;
    margin-top: 14px;
    padding: 13px;

    border-radius: 11px;

    background: var(--button);
    color: var(--button-text);

    font-weight: 700;
}

.icon-button,
.small-button {
    padding: 8px 11px;
    border-radius: 9px;

    background: var(--bg);
    color: var(--text);
}

.mailbox {
    padding: 13px 0;
    border-bottom: 1px solid var(--border);
}

.mailbox:last-child {
    border-bottom: 0;
}

.email-address {
    font-weight: 700;
    word-break: break-all;
}

.mail-count {
    color: var(--hint);
    font-size: 12px;
    margin-top: 4px;
}

.mail-actions {
    display: flex;
    gap: 7px;
    margin-top: 9px;
}

.mail-actions button {
    padding: 8px 10px;
    border-radius: 9px;
    background: var(--bg);
    color: var(--text);
}

.message {
    margin-top: 14px;
}

.message-subject {
    font-size: 19px;
    font-weight: 800;
    margin-bottom: 12px;
}

.message-meta {
    color: var(--hint);
    font-size: 13px;
    line-height: 1.5;
}

.message-body {
    margin-top: 15px;
    overflow-wrap: anywhere;
}

.loading,
.muted,
.empty {
    color: var(--hint);
}

.hidden {
    display: none;
}

footer {
    text-align: center;
    color: var(--hint);
    font-size: 11px;
    padding: 10px;
}
CSS


cat > "${APP_DIR}/web/app.js" <<'JS'
const tg = window.Telegram.WebApp;

tg.ready();
tg.expand();

const initData = tg.initData;

const headers = {
    "X-Telegram-Init-Data": initData
};

const $ = id => document.getElementById(id);

function esc(value) {
    if (value === null || value === undefined) return "";

    return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");
}

async function api(url, options = {}) {
    const response = await fetch(url, {
        ...options,
        headers: {
            ...headers,
            ...(options.headers || {})
        }
    });

    const data = await response.json().catch(() => ({}));

    if (!response.ok) {
        throw new Error(data.detail || "Request failed");
    }

    return data;
}


async function loadUser() {
    const user = await api("/api/me");

    const name = [
        user.first_name,
        user.last_name
    ].filter(Boolean).join(" ") || "Telegram User";

    $("userName").textContent = name;

    $("userUsername").textContent =
        user.username ? "@" + user.username : "";

    $("avatar").textContent =
        (user.first_name || "X").charAt(0).toUpperCase();
}


async function loadDomains() {
    const data = await api("/api/domains");

    const select = $("domain");

    select.innerHTML = "";

    for (const domain of data.domains || []) {
        const option = document.createElement("option");

        option.value = domain;
        option.textContent = domain;

        select.appendChild(option);
    }

    if (!data.domains || !data.domains.length) {
        select.innerHTML =
            '<option value="">No active domains</option>';
    }
}


async function loadMailboxes() {
    $("mailboxes").innerHTML =
        '<div class="loading">Loading mailboxes...</div>';

    try {
        const data = await api("/api/mailboxes");

        const mailboxes = data.mailboxes || [];

        if (!mailboxes.length) {
            $("mailboxes").innerHTML =
                '<div class="empty">No mailboxes yet.</div>';

            return;
        }

        $("mailboxes").innerHTML = "";

        for (const mailbox of mailboxes) {
            const div = document.createElement("div");

            div.className = "mailbox";

            div.innerHTML = `
                <div class="email-address">
                    ${esc(mailbox.email)}
                </div>

                <div class="mail-count">
                    ${mailbox.email_count || 0} message(s)
                </div>

                <div class="mail-actions">
                    <button
                        data-copy="${esc(mailbox.email)}"
                    >
                        Copy
                    </button>

                    <button
                        data-inbox="${esc(mailbox.token)}"
                    >
                        Inbox
                    </button>
                </div>
            `;

            $("mailboxes").appendChild(div);
        }

        document
            .querySelectorAll("[data-copy]")
            .forEach(button => {
                button.onclick = async () => {
                    await navigator.clipboard.writeText(
                        button.dataset.copy
                    );

                    tg.HapticFeedback?.notificationOccurred("success");

                    button.textContent = "Copied";

                    setTimeout(() => {
                        button.textContent = "Copy";
                    }, 1200);
                };
            });

        document
            .querySelectorAll("[data-inbox]")
            .forEach(button => {
                button.onclick = () =>
                    showInbox(button.dataset.inbox);
            });

    } catch (error) {
        $("mailboxes").innerHTML =
            `<div class="empty">${esc(error.message)}</div>`;
    }
}


async function generate() {
    const username = $("username").value.trim();
    const domain = $("domain").value;

    $("generate").disabled = true;
    $("generate").textContent = "Generating...";

    try {
        const data = await api("/api/generate", {
            method: "POST",
            headers: {
                "Content-Type": "application/json"
            },
            body: JSON.stringify({
                username: username || null,
                domain: domain || null
            })
        });

        await navigator.clipboard.writeText(data.email).catch(() => {});

        tg.HapticFeedback?.notificationOccurred("success");

        $("username").value = "";

        alert("Email created:\n\n" + data.email);

        await loadMailboxes();

    } catch (error) {
        alert(error.message);
    }

    $("generate").disabled = false;
    $("generate").textContent = "✉️ Generate Email";
}


async function showInbox(token) {
    $("messageView").classList.remove("hidden");

    $("messageContent").innerHTML =
        '<div class="loading">Loading inbox...</div>';

    window.scrollTo({
        top: document.body.scrollHeight,
        behavior: "smooth"
    });

    try {
        const data = await api(
            "/api/inbox?token=" + encodeURIComponent(token)
        );

        const emails =
            data.emails ||
            (Array.isArray(data) ? data : []);

        if (!emails.length) {
            $("messageContent").innerHTML =
                '<div class="empty">Inbox is empty.</div>';

            return;
        }

        $("messageContent").innerHTML = "";

        for (const email of emails) {
            const div = document.createElement("div");

            div.className = "mailbox";

            div.innerHTML = `
                <div class="email-address">
                    ${esc(email.subject || "(No subject)")}
                </div>

                <div class="mail-count">
                    From: ${esc(
                        email.from_address ||
                        email.from ||
                        "Unknown"
                    )}
                </div>

                <div class="mail-actions">
                    <button>Open message</button>
                </div>
            `;

            div.querySelector("button").onclick = async () => {
                await showMessage(token, email.id);
            };

            $("messageContent").appendChild(div);
        }

    } catch (error) {
        $("messageContent").innerHTML =
            `<div class="empty">${esc(error.message)}</div>`;
    }
}


async function showMessage(token, emailId) {
    $("messageContent").innerHTML =
        '<div class="loading">Loading message...</div>';

    try {
        const email = await api(
            "/api/message/" +
            encodeURIComponent(emailId) +
            "?token=" +
            encodeURIComponent(token)
        );

        const sender =
            email.from_address ||
            email.from ||
            "Unknown";

        let body =
            email.html_body ||
            email.body ||
            email.text_body ||
            "";

        $("messageContent").innerHTML = `
            <div class="message">
                <div class="message-subject">
                    ${esc(email.subject || "(No subject)")}
                </div>

                <div class="message-meta">
                    <b>From:</b> ${esc(sender)}<br>
                    <b>To:</b> ${esc(
                        email.to_address ||
                        email.to ||
                        ""
                    )}
                </div>

                <div class="message-body">
                    ${body}
                </div>
            </div>
        `;

    } catch (error) {
        $("messageContent").innerHTML =
            `<div class="empty">${esc(error.message)}</div>`;
    }
}


$("generate").onclick = generate;

$("refresh").onclick = loadMailboxes;

$("refreshTop").onclick = async () => {
    await loadDomains();
    await loadMailboxes();
};

$("back").onclick = () => {
    $("messageView").classList.add("hidden");
};


(async function boot() {
    if (!initData) {
        $("mailboxes").innerHTML =
            '<div class="empty">Open this page from Telegram.</div>';

        return;
    }

    try {
        await loadUser();
        await loadDomains();
        await loadMailboxes();
    } catch (error) {
        $("mailboxes").innerHTML =
            `<div class="empty">${esc(error.message)}</div>`;
    }
})();
JS

echo "[6/12] Creating systemd service..."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xnamso Telegram Mini App
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn app:app --host 127.0.0.1 --port 8090
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "[7/12] Waiting for Mini App..."

for i in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1; then
        break
    fi

    sleep 1
done

if ! curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1; then
    echo "ERROR: Mini App service did not start."
    journalctl -u "${SERVICE_NAME}" --no-pager -n 100
    exit 1
fi

echo "[8/12] Configuring nginx..."

rm -f "/etc/nginx/sites-enabled/${APP_NAME}"

cat > "/etc/nginx/sites-available/${APP_NAME}" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${APP_DOMAIN};

    client_max_body_size 20M;

    location / {
        proxy_pass http://127.0.0.1:8090;

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
    }
}
EOF

ln -sf \
    "/etc/nginx/sites-available/${APP_NAME}" \
    "/etc/nginx/sites-enabled/${APP_NAME}"

nginx -t
systemctl reload nginx

echo "[9/12] Obtaining HTTPS certificate..."

if certbot certificates 2>/dev/null | grep -q "Domains:.*${APP_DOMAIN}"; then
    echo "Certificate already exists for ${APP_DOMAIN}."
else
    certbot --nginx \
        --non-interactive \
        --agree-tos \
        --redirect \
        --register-unsafely-without-email \
        -d "${APP_DOMAIN}"
fi

echo "[10/12] Configuring Telegram Mini App menu..."

TELEGRAM_API="https://api.telegram.org/bot${BOT_TOKEN}"

curl -fsS \
    -X POST \
    "${TELEGRAM_API}/setChatMenuButton" \
    -H "Content-Type: application/json" \
    --data-binary @- <<EOF
{
  "menu_button": {
    "type": "web_app",
    "text": "📧 Open Xnamso",
    "web_app": {
      "url": "https://${APP_DOMAIN}/"
    }
  }
}
EOF

echo

echo "[11/12] Checking services..."

systemctl is-active --quiet nginx
systemctl is-active --quiet "${SERVICE_NAME}"

curl -fsS "https://${APP_DOMAIN}/health" || true

echo
echo "[12/12] Installation complete."
echo
echo "============================================================"
echo "             XNAMSO MINI APP READY"
echo "============================================================"
echo
echo "Mini App:"
echo "  https://${APP_DOMAIN}/"
echo
echo "Telegram menu:"
echo "  📧 Open Xnamso"
echo
echo "Service:"
echo "  ${SERVICE_NAME}.service"
echo
echo "Backend:"
echo "  ${BACKEND_URL}"
echo
echo "Useful commands:"
echo "  systemctl status ${SERVICE_NAME} --no-pager"
echo "  journalctl -u ${SERVICE_NAME} -f"
echo "  nginx -t"
echo
echo "============================================================"
