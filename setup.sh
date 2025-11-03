#!/bin/bash
set -e

echo "🚀 Setting up E-Commerce DevOps Environment..."

# 1. Create network
docker network create devops-network 2>/dev/null || true

# 2. Start Jenkins
echo "Starting Jenkins..."
docker run -d --name jenkins --network devops-network \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --user root jenkins/jenkins:lts

# 3. Start SonarQube
echo "Starting SonarQube..."
docker run -d --name sonarqube --network devops-network \
  -p 9000:9000 \
  -v sonarqube_data:/opt/sonarqube/data \
  sonarqube:lts-community

# 4. Wait for Jenkins
echo "Waiting for Jenkins to start..."
sleep 30

# 5. Install tools in Jenkins
echo "Installing tools in Jenkins container..."
docker exec -u root jenkins bash -c "
  apt-get update && \
  apt-get install -y docker.io unzip && \
  curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && \
  unzip awscliv2.zip && \
  ./aws/install && \
  wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | apt-key add - && \
  echo 'deb https://aquasecurity.github.io/trivy-repo/deb bullseye main' | tee -a /etc/apt/sources.list.d/trivy.list && \
  apt-get update && \
  apt-get install -y trivy
"

# 6. Get Jenkins password
echo ""
echo "✅ Setup complete!"
echo ""
echo "Jenkins URL: http://localhost:8080"
echo "Jenkins Password:"
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
echo ""
echo "SonarQube URL: http://localhost:9000"
echo "SonarQube Login: admin / admin"
echo ""
echo "Next steps:"
echo "1. Open Jenkins and complete setup wizard"
echo "2. Open SonarQube and change password"
echo "3. Run: cd terraform && terraform init && terraform apply"