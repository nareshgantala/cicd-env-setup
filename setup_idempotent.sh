#!/usr/bin/env bash
set -Eeuo pipefail

# ========= Config =========
JENKINS_NAME="jenkins"
SONAR_NAME="sonarqube"
NET_NAME="devops-network"

# Ports
JENKINS_HTTP=8080
JENKINS_AGENT=50000
SONAR_HTTP=9000

# Named volumes (data persists across re-creates)
JENKINS_VOL="jenkins_home"
SONAR_VOL_DATA="sonarqube_data"

# Behavior flags (env override): RECREATE=1 to force re-create, PULL=1 to docker pull images
RECREATE="${RECREATE:-0}"
PULL="${PULL:-0}"

# ========= Helpers =========
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

pull_images_if_requested(){
  if [[ "$PULL" == "1" ]]; then
    log "⬇️  Pulling latest images..."
    docker pull jenkins/jenkins:lts >/dev/null
    docker pull sonarqube:lts-community >/dev/null
  fi
}

start_or_recreate(){
  local name="$1"
  local run_cmd="$2"

  if exists_container "$name"; then
    if [[ "$RECREATE" == "1" ]]; then
      log "♻️  Recreating $name..."
      docker rm -f "$name" >/dev/null || true
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

wait_for_jenkins_password(){
  # Wait until Jenkins writes initialAdminPassword (fresh bootstrap) or confirm container is healthy/running.
  local tries=60
  local delay=2
  while (( tries-- > 0 )); do
    if docker exec "$JENKINS_NAME" bash -lc 'test -f /var/jenkins_home/secrets/initialAdminPassword' 2>/dev/null; then
      return 0
    fi
    # If Jenkins was already configured, the file may not exist anymore. Bail if the UI is responding.
    if docker exec "$JENKINS_NAME" bash -lc "curl -fsS localhost:${JENKINS_HTTP:-8080} >/dev/null 2>&1 || true"; then
      return 0
    fi
    sleep "$delay"
  done
  return 0
}

install_jenkins_tools_if_needed(){
  log "🧰 Ensuring tools inside Jenkins..."
  docker exec -u root "$JENKINS_NAME" bash -lc '
    set -e

    need_apt=0
    for pkg in curl ca-certificates unzip docker.io gnupg; do
      dpkg -s "$pkg" >/dev/null 2>&1 || need_apt=1
    done
    if [ "$need_apt" -eq 1 ]; then
      apt-get update
      apt-get install -y curl ca-certificates unzip docker.io gnupg
    fi

    # AWS CLI (idempotent)
    if ! command -v aws >/dev/null 2>&1; then
      curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
      unzip -q awscliv2.zip
      ./aws/install
      rm -rf aws awscliv2.zip
    fi

    # Trivy (distro-agnostic installer -> /usr/local/bin/trivy)
    if ! command -v trivy >/dev/null 2>&1; then
      curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
    fi

    echo "✔ Tools ready (docker, unzip, aws, trivy)."
  '
}

print_endpoints(){
  log ""
  log "✅ Setup complete!"
  echo ""
  echo "Jenkins URL:  http://localhost:${JENKINS_HTTP}"
  echo -n "Jenkins Password (initial, if present): "
  docker exec "$JENKINS_NAME" bash -lc 'cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo "(already configured / not present)"' || true
  echo ""
  echo "SonarQube URL: http://localhost:${SONAR_HTTP}"
  echo "SonarQube Login (default): admin / admin   (change on first login)"
  echo ""
  echo "Next steps:"
  echo "1) Open Jenkins and finish setup (or log in if already configured)."
  echo "2) Open SonarQube and change the default password."
  echo "3) (Optional) cd terraform && terraform init && terraform apply"
}

# ========= Main =========
log "🛠️  Setting up E-Commerce DevOps Environment..."

ensure_network
pull_images_if_requested

# Build run commands (redirect stdout to keep logs clean)
JENKINS_RUN_CMD=$(cat <<CMD
docker run -d --name "$JENKINS_NAME" --network "$NET_NAME" \
  -p ${JENKINS_HTTP}:8080 -p ${JENKINS_AGENT}:50000 \
  -v ${JENKINS_VOL}:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --user root jenkins/jenkins:lts >/dev/null
CMD
)

SONAR_RUN_CMD=$(cat <<CMD
docker run -d --name "$SONAR_NAME" --network "$NET_NAME" \
  -p ${SONAR_HTTP}:9000 \
  -v ${SONAR_VOL_DATA}:/opt/sonarqube/data \
  sonarqube:lts-community >/dev/null
CMD
)

start_or_recreate "$JENKINS_NAME" "$JENKINS_RUN_CMD"
start_or_recreate "$SONAR_NAME" "$SONAR_RUN_CMD"

# If Jenkins just launched, give it a moment and install tools
wait_for_jenkins_password
install_jenkins_tools_if_needed

print_endpoints
