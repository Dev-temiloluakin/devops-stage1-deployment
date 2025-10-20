#!/bin/bash

################################################################################
# Automated Docker Deployment Script
# Description: Deploys a Dockerized application to a remote server
################################################################################

set -e
set -u
set -o pipefail

################################################################################
# COLORS AND FORMATTING
################################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

################################################################################
# LOGGING SETUP
################################################################################
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

################################################################################
# ERROR HANDLING
################################################################################
cleanup_on_error() {
    log_error "Script failed at line $1. Check $LOG_FILE for details."
    exit 1
}

trap 'cleanup_on_error $LINENO' ERR

################################################################################
# CLEANUP FUNCTION
################################################################################
cleanup_deployment() {
    log "=== Cleaning Up Deployment ==="
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" bash << ENDSSH | tee -a "$LOG_FILE"
        echo "Stopping and removing containers..."
        docker ps -q --filter "name=$REPO_NAME" | xargs -r docker stop
        docker ps -aq --filter "name=$REPO_NAME" | xargs -r docker rm
        
        echo "Removing images..."
        docker images -q "$REPO_NAME" | xargs -r docker rmi -f
        
        echo "Removing project directory..."
        rm -rf /home/$SSH_USER/app
        
        echo "Removing Nginx configuration..."
        sudo rm -f /etc/nginx/sites-available/$REPO_NAME
        sudo rm -f /etc/nginx/sites-enabled/$REPO_NAME
        sudo systemctl reload nginx
        
        echo "Cleanup complete!"
ENDSSH
    
    log "${GREEN}✓ Cleanup completed successfully${NC}"
    exit 0
}

################################################################################
# PARSE COMMAND LINE ARGUMENTS
################################################################################
parse_arguments() {
    if [[ "${1:-}" == "--cleanup" ]]; then
        CLEANUP_MODE=true
    else
        CLEANUP_MODE=false
    fi
}

################################################################################
# STEP 1: COLLECT USER INPUT
################################################################################
collect_parameters() {
    log "=== Collecting Deployment Parameters ==="
    
    read -p "Enter Git Repository URL: " GIT_REPO_URL
    if [[ ! "$GIT_REPO_URL" =~ ^https?:// ]]; then
        log_error "Invalid repository URL format"
        exit 1
    fi
    
    read -sp "Enter Personal Access Token (hidden): " GIT_PAT
    echo
    if [[ -z "$GIT_PAT" ]]; then
        log_error "PAT cannot be empty"
        exit 1
    fi
    
    read -p "Enter branch name [main]: " GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}
    
    read -p "Enter remote server username: " SSH_USER
    read -p "Enter remote server IP: " SSH_HOST
    read -p "Enter SSH key path [~/.ssh/id_rsa]: " SSH_KEY
    SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
    
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    
    if [[ ! -f "$SSH_KEY" ]]; then
        log_error "SSH key not found at $SSH_KEY"
        exit 1
    fi
    
    read -p "Enter application internal port: " APP_PORT
    if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
        log_error "Port must be a number"
        exit 1
    fi
    
    log "Parameters collected successfully"
}

################################################################################
# STEP 2: CLONE REPOSITORY
################################################################################
clone_repository() {
    log "=== Cloning Repository ==="
    
    REPO_NAME=$(basename "$GIT_REPO_URL" .git)
    AUTH_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${GIT_PAT}@|")
    
    if [[ -d "$REPO_NAME" ]]; then
        log_info "Repository already exists. Pulling latest changes..."
        cd "$REPO_NAME"
        git pull origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1
    else
        log_info "Cloning repository..."
        git clone -b "$GIT_BRANCH" "$AUTH_URL" "$REPO_NAME" >> "$LOG_FILE" 2>&1
        cd "$REPO_NAME"
    fi
    
    log "Repository cloned/updated successfully"
}

################################################################################
# STEP 3: VERIFY DOCKERFILE
################################################################################
verify_dockerfile() {
    log "=== Verifying Docker Configuration ==="
    
    if [[ -f "Dockerfile" ]]; then
        log "Found Dockerfile"
        DEPLOY_METHOD="dockerfile"
    elif [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        log "Found docker-compose file"
        DEPLOY_METHOD="compose"
    else
        log_error "No Dockerfile or docker-compose.yml found!"
        exit 1
    fi
}

################################################################################
# STEP 4: TEST SSH CONNECTION
################################################################################
test_ssh_connection() {
    log "=== Testing SSH Connection ==="
    
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$SSH_USER@$SSH_HOST" "echo 'SSH connection successful'" >> "$LOG_FILE" 2>&1; then
        log "SSH connection established"
    else
        log_error "Failed to connect to remote server"
        exit 1
    fi
}

################################################################################
# STEP 5: PREPARE REMOTE ENVIRONMENT
################################################################################
prepare_remote_environment() {
    log "=== Preparing Remote Environment ==="
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" bash << 'ENDSSH' | tee -a "$LOG_FILE"
        echo "Updating system packages..."
        sudo apt-get update -qq
        
        echo "Installing Docker..."
        if ! command -v docker &> /dev/null; then
            curl -fsSL https://get.docker.com | sh
            sudo usermod -aG docker $USER
        else
            echo "Docker already installed"
        fi
        
        echo "Installing Docker Compose..."
        if ! command -v docker-compose &> /dev/null; then
            sudo apt-get install -y docker-compose
        else
            echo "Docker Compose already installed"
        fi
        
        echo "Installing Nginx..."
        if ! command -v nginx &> /dev/null; then
            sudo apt-get install -y nginx
        else
            echo "Nginx already installed"
        fi
        
        echo "Starting services..."
        sudo systemctl enable docker
        sudo systemctl start docker
        sudo systemctl enable nginx
        sudo systemctl start nginx
        
        echo "Versions:"
        docker --version
        docker-compose --version
        nginx -v
ENDSSH
    
    log "Remote environment prepared"
}

################################################################################
# STEP 6: DEPLOY APPLICATION
################################################################################
deploy_application() {
    log "=== Deploying Application ==="
    
    log_info "Transferring project files..."
    REMOTE_DIR="/home/$SSH_USER/app"
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "mkdir -p $REMOTE_DIR"
    
    rsync -avz -e "ssh -i $SSH_KEY" \
        --exclude '.git' \
        --exclude 'node_modules' \
        ./ "$SSH_USER@$SSH_HOST:$REMOTE_DIR/" >> "$LOG_FILE" 2>&1
    
    log_info "Files transferred successfully"
    
    log_info "Building and starting containers..."
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" bash << ENDSSH | tee -a "$LOG_FILE"
        cd $REMOTE_DIR
        
        echo "Stopping existing containers..."
        docker ps -q --filter "name=$REPO_NAME" | xargs -r docker stop
        docker ps -aq --filter "name=$REPO_NAME" | xargs -r docker rm
        
        if [[ "$DEPLOY_METHOD" == "compose" ]]; then
            docker-compose down
            docker-compose up -d --build
        else
            docker build -t $REPO_NAME:latest .
            docker run -d --name $REPO_NAME -p 8080:80 $REPO_NAME:latest
        fi
        
        sleep 5
        
        docker ps | grep $REPO_NAME
ENDSSH
    
    log "Application deployed successfully"
}

################################################################################
# STEP 7: CONFIGURE NGINX
################################################################################
configure_nginx() {
    log "=== Configuring Nginx ==="
    
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" bash << ENDSSH | tee -a "$LOG_FILE"
        sudo tee /etc/nginx/sites-available/$REPO_NAME > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

        sudo ln -sf /etc/nginx/sites-available/$REPO_NAME /etc/nginx/sites-enabled/
        sudo rm -f /etc/nginx/sites-enabled/default
        
        sudo nginx -t
        sudo systemctl reload nginx
        
        echo "Nginx configured successfully"
ENDSSH
    
    log "Nginx configured and reloaded"
}

################################################################################
# STEP 8: VALIDATE DEPLOYMENT
################################################################################
validate_deployment() {
    log "=== Validating Deployment ==="
    
    log_info "Checking Docker service..."
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "sudo systemctl is-active docker" >> "$LOG_FILE"
    
    log_info "Checking container status..."
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "docker ps | grep $REPO_NAME" >> "$LOG_FILE"
    
    log_info "Testing application endpoint..."
    if ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "curl -f http://localhost:$APP_PORT" >> "$LOG_FILE" 2>&1; then
        log "Application is responding on port $APP_PORT"
    else
        log_warning "Application not responding on port $APP_PORT (might be normal for some apps)"
    fi
    
    log_info "Testing Nginx proxy..."
    if ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "curl -f http://localhost" >> "$LOG_FILE" 2>&1; then
        log "Nginx proxy is working"
    else
        log_warning "Nginx proxy test failed"
    fi
    
    log "${GREEN}Deployment validation complete!${NC}"
    log "Application should be accessible at http://$SSH_HOST"
}

################################################################################
# MAIN EXECUTION
################################################################################
main() {
    parse_arguments "$@"
    
    if [[ "$CLEANUP_MODE" == true ]]; then
        log "=========================================="
        log "Starting Cleanup Process"
        log "=========================================="
        
        # Need to collect minimal parameters for cleanup
        read -p "Enter remote server username: " SSH_USER
        read -p "Enter remote server IP: " SSH_HOST
        read -p "Enter SSH key path [~/.ssh/id_rsa]: " SSH_KEY
        SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
        read -p "Enter repository name to cleanup: " REPO_NAME
        
        cleanup_deployment
    fi
    
    log "=========================================="
    log "Starting Automated Deployment Process"
    log "=========================================="
    
    collect_parameters
    clone_repository
    verify_dockerfile
    test_ssh_connection
    prepare_remote_environment
    deploy_application
    configure_nginx
    validate_deployment
    
    log "=========================================="
    log "${GREEN}✓ DEPLOYMENT COMPLETED SUCCESSFULLY${NC}"
    log "=========================================="
    log "Access your application at: http://$SSH_HOST"
    log "Check logs at: $LOG_FILE"
    log ""
    log "To cleanup this deployment, run: ./deploy.sh --cleanup"
}

main "$@"
