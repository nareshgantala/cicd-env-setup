#!/usr/bin/env bash
set -Eeuo pipefail

# ========= Config =========
JENKINS_NAME="jenkins"
SONAR_NAME="sonarqube"
POSTGRES_NAME="sonarqube-db"
NET_NAME="devops-network"

# Ports
JENKINS_HTTP=8080
JENKINS_AGENT=50000
SONAR_HTTP=9000
POSTGRES_PORT=5432

# Named volumes (data persists across re-creates)
JENKINS_VOL="jenkins_home"
JENKINS_CACHE_VOL="jenkins_cache"
SONAR_VOL_DATA="sonarqube_data"
SONAR_VOL_EXTENSIONS="sonarqube_extensions"
SONAR_VOL_LOGS="sonarqube_logs"
POSTGRES_VOL="postgresql_data"

# Database credentials
POSTGRES_USER="sonar"
POSTGRES_PASSWORD="sonar"
POSTGRES_DB="sonarqube"

# Resource limits (adjust based on instance type)
# For t3.xlarge (16GB): Jenkins 6GB, SonarQube 4GB, PostgreSQL 1GB
# For t3.large (8GB): Jenkins 4GB, SonarQube 2GB, PostgreSQL 512MB
JENKINS_MEMORY="${JENKINS_MEMORY:-6g}"
JENKINS_MEMORY_SWAP="${JENKINS_MEMORY_SWAP:-6g}"
JENKINS_CPUS="${JENKINS_CPUS:-2}"
JENKINS_JAVA_OPTS="${JENKINS_JAVA_OPTS:--Xms1g -Xmx4g -XX:MaxMetaspaceSize=512m}"

SONAR_MEMORY="${SONAR_MEMORY:-4g}"
SONAR_MEMORY_SWAP="${SONAR_MEMORY_SWAP:-4g}"
SONAR_CPUS="${SONAR_CPUS:-2}"
SONAR_ES_JAVA_OPTS="${SONAR_ES_JAVA_OPTS:--Xms1g -Xmx2g}"
SONAR_JAVA_OPTS="${SONAR_JAVA_OPTS:--Xms512m -Xmx1g -XX:MaxMetaspaceSize=512m}"

POSTGRES_MEMORY="${POSTGRES_MEMORY:-1g}"
POSTGRES_MEMORY_SWAP="${POSTGRES_MEMORY_SWAP:-1g}"
POSTGRES_CPUS="${POSTGRES_CPUS:-1}"

# Behavior flags (env override): RECREATE=1 to force re-create, PULL=1 to docker pull images
RECREATE="${RECREATE:-0}"
PULL="${PULL:-0}"

# ========= Helpers =========
log(){ printf "\n%s\n" "$*"; }
exists_container(){ docker ps -a --format '{{.Names}}' | grep -qx "$1"; }
is_running(){ docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx 'true'; }

detect_instance_resources(){
  # Auto-detect available memory and adjust limits
  local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local total_mem_gb=$((total_mem_kb / 1024 / 1024))
  
  log "📊 Detected ${total_mem_gb}GB total memory"
  
  # Adjust resource limits based on available memory
  if [ "$total_mem_gb" -ge 30 ]; then
    log "🚀 High memory instance detected - using max resources"
    JENKINS_MEMORY="8g"
    JENKINS_MEMORY_SWAP="8g"
    JENKINS_JAVA_OPTS="-Xms2g -Xmx6g -XX:MaxMetaspaceSize=512m"
    SONAR_MEMORY="6g"
    SONAR_MEMORY_SWAP="6g"
    SONAR_ES_JAVA_OPTS="-Xms2g -Xmx4g"
    SONAR_JAVA_OPTS="-Xms1g -Xmx2g -XX:MaxMetaspaceSize=512m"
    POSTGRES_MEMORY="2g"
    POSTGRES_MEMORY_SWAP="2g"
  elif [ "$total_mem_gb" -ge 15 ]; then
    log "⚡ Medium memory instance detected - using recommended resources"
    JENKINS_MEMORY="6g"
    JENKINS_MEMORY_SWAP="6g"
    JENKINS_JAVA_OPTS="-Xms1g -Xmx4g -XX:MaxMetaspaceSize=512m"
    SONAR_MEMORY="4g"
    SONAR_MEMORY_SWAP="4g"
    SONAR_ES_JAVA_OPTS="-Xms1g -Xmx2g"
    SONAR_JAVA_OPTS="-Xms512m -Xmx1g -XX:MaxMetaspaceSize=512m"
    POSTGRES_MEMORY="1g"
    POSTGRES_MEMORY_SWAP="1g"
  else
    log "⚠️  Low memory instance detected - using minimal resources"
    JENKINS_MEMORY="3g"
    JENKINS_MEMORY_SWAP="3g"
    JENKINS_JAVA_OPTS="-Xms512m -Xmx2g -XX:MaxMetaspaceSize=256m"
    SONAR_MEMORY="2g"
    SONAR_MEMORY_SWAP="2g"
    SONAR_ES_JAVA_OPTS="-Xms512m -Xmx1g"
    SONAR_JAVA_OPTS="-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m"
    POSTGRES_MEMORY="512m"
    POSTGRES_MEMORY_SWAP="512m"
  fi
}

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
    docker pull postgres:15-alpine >/dev/null
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

wait_for_service(){
  local service_name="$1"
  local port="$2"
  local max_wait="${3:-300}"  # 5 minutes default
  
  log "⏳ Waiting for $service_name to be ready (max ${max_wait}s)..."
  local elapsed=0
  local interval=5
  
  while [ $elapsed -lt $max_wait ]; do
    if curl -sf http://localhost:${port} >/dev/null 2>&1; then
      log "✅ $service_name is ready!"
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
    if [ $((elapsed % 30)) -eq 0 ]; then
      log "   Still waiting... (${elapsed}s elapsed)"
    fi
  done
  
  log "⚠️  $service_name did not respond within ${max_wait}s"
  return 1
}

wait_for_postgres(){
  local max_wait="${1:-60}"
  
  log "⏳ Waiting for PostgreSQL to be ready (max ${max_wait}s)..."
  local elapsed=0
  local interval=2
  
  while [ $elapsed -lt $max_wait ]; do
    if docker exec "$POSTGRES_NAME" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
      log "✅ PostgreSQL is ready!"
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  log "⚠️  PostgreSQL did not respond within ${max_wait}s"
  return 1
}

wait_for_jenkins_password(){
  # Wait until Jenkins writes initialAdminPassword or is ready
  local tries=60
  local delay=2
  
  log "⏳ Waiting for Jenkins initialization..."
  
  while (( tries-- > 0 )); do
    if docker exec "$JENKINS_NAME" bash -lc 'test -f /var/jenkins_home/secrets/initialAdminPassword' 2>/dev/null; then
      log "✅ Jenkins initialization complete!"
      return 0
    fi
    # If Jenkins was already configured, the file may not exist
    if docker exec "$JENKINS_NAME" bash -lc "curl -fsS localhost:${JENKINS_HTTP:-8080} >/dev/null 2>&1 || true"; then
      log "✅ Jenkins is ready (already configured)!"
      return 0
    fi
    sleep "$delay"
  done
  
  log "⚠️  Could not verify Jenkins initialization"
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
      echo "📦 Installing required packages..."
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates unzip docker.io gnupg
    fi

    # AWS CLI (idempotent)
    if ! command -v aws >/dev/null 2>&1; then
      echo "☁️  Installing AWS CLI..."
      curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
      unzip -q awscliv2.zip
      ./aws/install
      rm -rf aws awscliv2.zip
    fi

    # Trivy (distro-agnostic installer)
    if ! command -v trivy >/dev/null 2>&1; then
      echo "🔒 Installing Trivy..."
      curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
    fi

    echo "✔ Tools ready: docker, aws-cli ($(aws --version | cut -d/ -f2 | cut -d" " -f1)), trivy ($(trivy --version | head -n1 | awk "{print \$2}"))"
  '
}

print_resource_info(){
  log ""
  log "📊 Container Resource Allocation:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Jenkins:"
  echo "  Memory: ${JENKINS_MEMORY} (swap: ${JENKINS_MEMORY_SWAP})"
  echo "  CPUs: ${JENKINS_CPUS}"
  echo "  JVM: ${JENKINS_JAVA_OPTS}"
  echo ""
  echo "SonarQube:"
  echo "  Memory: ${SONAR_MEMORY} (swap: ${SONAR_MEMORY_SWAP})"
  echo "  CPUs: ${SONAR_CPUS}"
  echo "  Elasticsearch JVM: ${SONAR_ES_JAVA_OPTS}"
  echo "  SonarQube JVM: ${SONAR_JAVA_OPTS}"
  echo ""
  echo "PostgreSQL:"
  echo "  Memory: ${POSTGRES_MEMORY} (swap: ${POSTGRES_MEMORY_SWAP})"
  echo "  CPUs: ${POSTGRES_CPUS}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

print_endpoints(){
  log ""
  log "✅ Setup complete!"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📍 ACCESS INFORMATION"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "🔹 Jenkins"
  echo "   URL: http://localhost:${JENKINS_HTTP}"
  if docker exec "$JENKINS_NAME" bash -lc 'test -f /var/jenkins_home/secrets/initialAdminPassword' 2>/dev/null; then
    echo -n "   Initial Password: "
    docker exec "$JENKINS_NAME" cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo "(not found)"
  else
    echo "   Status: Already configured (no initial password)"
  fi
  echo ""
  echo "🔹 SonarQube"
  echo "   URL: http://localhost:${SONAR_HTTP}"
  echo "   Default Login: admin / admin"
  echo "   ⚠️  Change password on first login!"
  echo ""
  echo "🔹 PostgreSQL (Internal)"
  echo "   Container: ${POSTGRES_NAME}"
  echo "   Database: ${POSTGRES_DB}"
  echo "   User: ${POSTGRES_USER}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📝 NEXT STEPS"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "1. Open Jenkins and complete setup wizard"
  echo "2. Open SonarQube and change default password"
  echo "3. Configure credentials in Jenkins"
  echo "4. (Optional) Deploy infrastructure: cd terraform && terraform apply"
  echo ""
  echo "💡 Useful Commands:"
  echo "   View logs:       docker logs jenkins -f"
  echo "                    docker logs sonarqube -f"
  echo "                    docker logs sonarqube-db -f"
  echo "   Restart:         docker restart jenkins sonarqube sonarqube-db"
  echo "   Stop:            docker stop jenkins sonarqube sonarqube-db"
  echo "   Check status:    docker ps"
  echo "   Check resources: docker stats jenkins sonarqube sonarqube-db"
  echo "   Database backup: docker exec sonarqube-db pg_dump -U sonar sonarqube > backup.sql"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ========= Main =========
log "🛠️  Setting up E-Commerce DevOps Environment..."
log "$(date)"

# Detect and set optimal resource limits
detect_instance_resources
print_resource_info

ensure_network
pull_images_if_requested

# Build run commands with optimized settings
POSTGRES_RUN_CMD=$(cat <<CMD
docker run -d \
  --name "$POSTGRES_NAME" \
  --network "$NET_NAME" \
  --restart unless-stopped \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  -v ${POSTGRES_VOL}:/var/lib/postgresql/data \
  --memory=${POSTGRES_MEMORY} \
  --memory-swap=${POSTGRES_MEMORY_SWAP} \
  --cpus=${POSTGRES_CPUS} \
  postgres:15-alpine >/dev/null
CMD
)

JENKINS_RUN_CMD=$(cat <<CMD
docker run -d \
  --name "$JENKINS_NAME" \
  --network "$NET_NAME" \
  --restart unless-stopped \
  -p ${JENKINS_HTTP}:8080 \
  -p ${JENKINS_AGENT}:50000 \
  -e JAVA_OPTS="$JENKINS_JAVA_OPTS" \
  -e JENKINS_OPTS="--sessionTimeout=1440" \
  -v ${JENKINS_VOL}:/var/jenkins_home \
  -v ${JENKINS_CACHE_VOL}:/root/.cache \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --user root \
  --memory=${JENKINS_MEMORY} \
  --memory-swap=${JENKINS_MEMORY_SWAP} \
  --cpus=${JENKINS_CPUS} \
  jenkins/jenkins:lts >/dev/null
CMD
)

SONAR_RUN_CMD=$(cat <<CMD
docker run -d \
  --name "$SONAR_NAME" \
  --network "$NET_NAME" \
  --restart unless-stopped \
  -p ${SONAR_HTTP}:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  -e "SONAR_JDBC_URL=jdbc:postgresql://${POSTGRES_NAME}:5432/${POSTGRES_DB}" \
  -e "SONAR_JDBC_USERNAME=${POSTGRES_USER}" \
  -e "SONAR_JDBC_PASSWORD=${POSTGRES_PASSWORD}" \
  -e "ES_JAVA_OPTS=$SONAR_ES_JAVA_OPTS" \
  -e "SONAR_JAVA_OPTS=$SONAR_JAVA_OPTS" \
  -e "SONAR_WEB_JAVAADDITIONALOPTS=-server" \
  -e "SONAR_CE_JAVAADDITIONALOPTS=-server" \
  -v ${SONAR_VOL_DATA}:/opt/sonarqube/data \
  -v ${SONAR_VOL_EXTENSIONS}:/opt/sonarqube/extensions \
  -v ${SONAR_VOL_LOGS}:/opt/sonarqube/logs \
  --memory=${SONAR_MEMORY} \
  --memory-swap=${SONAR_MEMORY_SWAP} \
  --cpus=${SONAR_CPUS} \
  sonarqube:lts-community >/dev/null
CMD
)

# Start containers in order: PostgreSQL -> Jenkins + SonarQube
log "🗄️  Starting PostgreSQL database..."
start_or_recreate "$POSTGRES_NAME" "$POSTGRES_RUN_CMD"
wait_for_postgres 60

log "🚀 Starting application containers..."
start_or_recreate "$JENKINS_NAME" "$JENKINS_RUN_CMD"
start_or_recreate "$SONAR_NAME" "$SONAR_RUN_CMD"

# Wait for services to be ready
wait_for_service "Jenkins" "$JENKINS_HTTP" 180
wait_for_jenkins_password
install_jenkins_tools_if_needed

wait_for_service "SonarQube" "$SONAR_HTTP" 300

print_endpoints

log ""
log "🎉 DevOps environment is ready!"
log "$(date)"