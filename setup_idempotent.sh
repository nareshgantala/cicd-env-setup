#!/usr/bin/env bash
set -Eeuo pipefail

JENKINS_NAME=jenkins
SONAR_NAME=sonarqube
NET_NAME=devops-network
RECREATE="${RECREATE:-0}"   # set RECREATE=1 to force container re-create

log(){ printf "\n%s\n" "$*"; }

exists_container(){ docker ps -a --format '{{.Names}}' | grep -qx "$1"; }
is_running(){ docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx 'true'; }
ensure_network(){
  if ! docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    docker network create "$NET_NAME" >/dev/null
    log "🔗 Created network: $NET_NAME"
  else
    log "🔗 Network already exists: $NET_NAME"
  fi
}

start_or_recreate(){
  local name="$1"
  local run_cmd="$2"

  if exists_container "$name"; then
    if [[ "$RECREATE" == "1" ]]; then
      log "♻️  Recreating $name..."
      docker rm -f "$name" >/dev/null
      eval "$run_cmd"
    else
      if is_running "$name"; then
        log "✅ $name already running."
      else
        log "▶️  Starting existing $name..."
        docker start "$name" >/dev/null
      fi
    fi
  else
    log "🚀 Creating $name..."
    eval "$run_cmd"
  fi
}

install_jenkins_tools_if_needed(){
  # Only run installers if missing inside the container
  log "🧰 Ensuring tools inside Jenkins..."
  docker exec -u root "$JENKINS_NAME" bash -lc '
    set -e
    need_update=0

    command -v docker >/dev/null 2>&1 || need_update=1
    command -v unzip  >/dev/null 2>&1 || need_update=1
    command -v aws    >/dev/null 2>&1 || need_update=1
    command -v trivy  >/dev/null 2>&1 || need_update=1

    if [ "$need_update" -eq 0 ]; then
      echo "Tools already installed (docker, unzip, aws, trivy)."
      exit 0
    fi

    apt-get update
    command -v docker >/dev/null 2>&1 || apt-get install -y docker.io
    command -v unzip  >/dev/null 2>&1 || apt-get install -y unzip

    if ! command -v aws >/dev/null 2>&1; then
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
      unzip -q awscliv2.zip
      ./aws/install
      rm -rf aws awscliv2.zip
    fi

    if ! command -v trivy >/dev/null 2>&1; then
      apt-get install -y gnupg
      wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg
      echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb bullseye main" > /etc/apt/sources.list.d/trivy.list
      apt-get update
      apt-get install -y trivy
    fi
  '
}

log "🛠️  Setting up E-Commerce DevOps Environment..."

ensure_network

# Optional: pull images to ensure you have latest tags before (re)create
# Comment out if you want to avoid pulling each time.
docker pull jenkins/jenkins:lts >/dev/null
docker pull sonarqube:lts-community >/dev/null

# Jenkins
JENKINS_RUN_CMD=$(cat <<'CMD'
docker run -d --name jenkins --network devops-network \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --user root jenkins/jenkins:lts >/dev/null
CMD
)
start_or_recreate "$JENKINS_NAME" "$JENKINS_RUN_CMD"

# SonarQube
SONAR_RUN_CMD=$(cat <<'CMD'
docker run -d --name sonarqube --network devops-network \
  -p 9000:9000 \
  -v sonarqube_data:/opt/sonarqube/data \
  sonarqube:lts-community >/dev/null
CMD
)
start_or_recreate "$SONAR_NAME" "$SONAR_RUN_CMD"

# Wait briefly if Jenkins just launched
if ! is_running "$JENKINS_NAME"; then
  log "⏳ Waiting for Jenkins to start..."
  sleep 15
fi

# Ensure tools inside Jenkins (idempotent)
install_jenkins_tools_if_needed

log ""
log "✅ Setup complete!"
log ""
echo "Jenkins URL: http://localhost:8080"
echo -n "Jenkins Password: "
docker exec "$JENKINS_NAME" cat /var/jenkins_home/secrets/initialAdminPassword || true
echo ""
echo "SonarQube URL: http://localhost:9000"
echo "SonarQube Login: admin / admin"
echo ""
echo "Next steps:"
echo "1. Open Jenkins and complete the setup wizard"
echo "2. Open SonarQube and change the default password"
echo "3. Run: cd terraform && terraform init && terraform apply"
