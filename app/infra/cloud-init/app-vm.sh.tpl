#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y nginx python3-pip python3-venv git

# --- FastAPI ---
mkdir -p /opt/todo-app
cd /opt/todo-app

python3 -m venv venv
venv/bin/pip install --quiet fastapi==0.115.0 uvicorn==0.30.6 psycopg2-binary==2.9.9 pydantic==2.8.2

cat > /opt/todo-app/main.py << 'PYEOF'
${app_source}
PYEOF

cat > /etc/systemd/system/todo-api.service << 'EOF'
[Unit]
Description=Todo API
After=network.target

[Service]
User=www-data
WorkingDirectory=/opt/todo-app
ExecStart=/opt/todo-app/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5
Environment=DB_HOST=${db_host}
Environment=DB_USER=${db_user}
Environment=DB_PASSWORD=${db_password}
Environment=DB_NAME=${db_name}

[Install]
WantedBy=multi-user.target
EOF

# --- Frontend ---
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'HTMLEOF'
${front_source}
HTMLEOF

# --- nginx ---
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/todo << 'EOF'
server {
    listen 80;
    root /var/www/html;

    location /todos {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        try_files $uri /index.html;
    }
}
EOF
ln -s /etc/nginx/sites-available/todo /etc/nginx/sites-enabled/todo

systemctl daemon-reload
systemctl enable todo-api
systemctl start todo-api
systemctl restart nginx
