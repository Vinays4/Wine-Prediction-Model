#!/bin/bash
# =============================================================
# MLflow + Google Cloud SQL PostgreSQL Setup Script
# With Error Handling & Fix Suggestions
# =============================================================

# =============================================================
# CONFIGURATION — Edit these variables before running
# =============================================================
PROJECT_ID="project-fe9b55e8-d9bb-4671-98b"       # Run: gcloud projects list
INSTANCE_NAME="mlopsdb1"
DATABASE_NAME="mlflowdb1"
DB_USER="mlflow"
DB_PASSWORD="db@123"     # Choose a strong password
REGION="us-central1"
TIER="db-f1-micro"
CLUSTER_NAME="mlflow-sql-cluster"
NAMESPACE="mlflow"

# =============================================================
# HELPER FUNCTIONS
# =============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

success() { echo -e "${GREEN}✅ $1${NC}"; }
error()   { echo -e "${RED}❌ ERROR: $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
fix()     { echo -e "${YELLOW}🔧 FIX: $1${NC}"; }
info()    { echo -e "ℹ️  $1"; }

# =============================================================
# PRE-FLIGHT CHECKS
# =============================================================
echo "============================================="
echo " MLflow + Cloud SQL Setup"
echo "============================================="

# Check placeholder values
if [[ "$PROJECT_ID" == "YOUR_PROJECT_ID" ]]; then
  error "PROJECT_ID is not set."
  fix "Run: gcloud projects list"
  fix "Then edit this script and set PROJECT_ID to your actual project ID (e.g. my-project-123)"
  fix "Note: Use Project ID not Project Name"
  exit 1
fi

if [[ "$DB_PASSWORD" == "YOUR_DB_PASSWORD" ]]; then
  error "DB_PASSWORD is not set."
  fix "Edit this script and set DB_PASSWORD to a strong password"
  exit 1
fi

# Check required tools
for tool in gcloud kubectl kind helm curl; do
  if ! command -v $tool &> /dev/null; then
    error "$tool is not installed."
    case $tool in
      gcloud)  fix "Install from: https://cloud.google.com/sdk/docs/install" ;;
      kubectl) fix "Run: brew install kubectl" ;;
      kind)    fix "Run: brew install kind" ;;
      helm)    fix "Run: brew install helm" ;;
      curl)    fix "Run: brew install curl" ;;
    esac
    exit 1
  fi
done
success "All required tools are installed."

# =============================================================
# STEP 1 — Set GCP Project
# =============================================================
echo ""
echo "[1/9] Setting GCP project..."
if ! gcloud config set project $PROJECT_ID 2>&1; then
  error "Failed to set project: $PROJECT_ID"
  fix "Run 'gcloud projects list' to find your correct Project ID"
  fix "Make sure you are using Project ID (e.g. my-project-123) not Project Name"
  fix "Run: gcloud auth login   if you are not authenticated"
  exit 1
fi

if ! gcloud services enable sqladmin.googleapis.com 2>&1; then
  error "Failed to enable Cloud SQL API."
  fix "Make sure you have the 'Service Usage Admin' role in GCP"
  fix "Or enable manually at: https://console.cloud.google.com/apis/library/sqladmin.googleapis.com"
  exit 1
fi
success "GCP project set to: $PROJECT_ID"

# =============================================================
# STEP 2 — Create Cloud SQL PostgreSQL Instance
# =============================================================
echo ""
echo "[2/9] Creating Cloud SQL PostgreSQL instance..."

# Check if instance already exists
if gcloud sql instances describe $INSTANCE_NAME &>/dev/null; then
  warn "Instance '$INSTANCE_NAME' already exists. Skipping creation."
else
  if ! gcloud sql instances create $INSTANCE_NAME \
    --database-version=POSTGRES_15 \
    --tier=$TIER \
    --region=$REGION \
    --assign-ip \
    --project=$PROJECT_ID 2>&1; then
    error "Failed to create Cloud SQL instance."
    fix "Check that your Project ID is correct: $PROJECT_ID"
    fix "Check that billing is enabled for your GCP project"
    fix "Check that the instance name '$INSTANCE_NAME' uses only lowercase letters, numbers, hyphens"
    fix "Check available regions: gcloud sql tiers list"
    exit 1
  fi
fi

echo "Waiting for instance to be ready..."
sleep 30
success "Cloud SQL instance '$INSTANCE_NAME' is ready."

# =============================================================
# STEP 3 — Get Public IP & Authorize Current Machine
# =============================================================
echo ""
echo "[3/9] Getting DB public IP and authorizing network..."

DB_IP=$(gcloud sql instances describe $INSTANCE_NAME --format="value(ipAddresses[0].ipAddress)" 2>&1)
if [[ -z "$DB_IP" ]]; then
  error "Could not retrieve DB public IP."
  fix "Make sure the instance was created with --assign-ip flag"
  fix "Run: gcloud sql instances patch $INSTANCE_NAME --assign-ip"
  exit 1
fi
info "DB Public IP: $DB_IP"

# Force IPv4 — Cloud SQL does not support IPv6 authorized networks
MY_IP=$(curl -4 -s ifconfig.me 2>&1 || curl -s https://api.ipify.org 2>&1 || curl -s https://ipv4.icanhazip.com 2>&1)

if [[ -z "$MY_IP" ]]; then
  error "Could not retrieve your public IPv4 address."
  fix "Check your internet connection"
  fix "Find your IPv4 manually: curl -4 ifconfig.me"
  fix "Then run: gcloud sql instances patch $INSTANCE_NAME --authorized-networks=YOUR_IPV4/32"
  exit 1
fi

# Validate it's an IPv4 address (not IPv6)
if [[ ! "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  error "Retrieved IP '$MY_IP' is not a valid IPv4 address."
  fix "Cloud SQL only supports IPv4 for authorized networks"
  fix "Find your IPv4 manually: curl -4 ifconfig.me  OR  curl https://api.ipify.org"
  fix "Then run: gcloud sql instances patch $INSTANCE_NAME --authorized-networks=YOUR_IPV4/32"
  exit 1
fi
info "Your Public IPv4: $MY_IP"

if ! gcloud sql instances patch $INSTANCE_NAME \
  --authorized-networks=$MY_IP/32 2>&1; then
  error "Failed to authorize network."
  fix "Run manually: gcloud sql instances patch $INSTANCE_NAME --authorized-networks=$MY_IP/32"
  fix "Or temporarily allow all IPs for testing: --authorized-networks=0.0.0.0/0"
  exit 1
fi
success "Network authorized for IP: $MY_IP"

# =============================================================
# STEP 4 — Create Database
# =============================================================
echo ""
echo "[4/9] Creating database '$DATABASE_NAME'..."

# Check if DB already exists
if gcloud sql databases describe $DATABASE_NAME --instance=$INSTANCE_NAME &>/dev/null; then
  warn "Database '$DATABASE_NAME' already exists. Skipping creation."
else
  if ! gcloud sql databases create $DATABASE_NAME --instance=$INSTANCE_NAME 2>&1; then
    error "Failed to create database '$DATABASE_NAME'."
    fix "Check that the instance '$INSTANCE_NAME' is running: gcloud sql instances list"
    fix "Try manually: gcloud sql databases create $DATABASE_NAME --instance=$INSTANCE_NAME"
    exit 1
  fi
fi
success "Database '$DATABASE_NAME' is ready."

# =============================================================
# STEP 5 — Create DB User
# =============================================================
echo ""
echo "[5/9] Creating database user '$DB_USER'..."

# Check if user already exists
if gcloud sql users list --instance=$INSTANCE_NAME --format="value(name)" | grep -q "^$DB_USER$"; then
  warn "User '$DB_USER' already exists. Resetting password..."
  if ! gcloud sql users set-password $DB_USER \
    --instance=$INSTANCE_NAME \
    --password=$DB_PASSWORD 2>&1; then
    error "Failed to reset password for user '$DB_USER'."
    fix "Run manually: gcloud sql users set-password $DB_USER --instance=$INSTANCE_NAME --password=YOUR_PASSWORD"
    exit 1
  fi
else
  if ! gcloud sql users create $DB_USER \
    --instance=$INSTANCE_NAME \
    --password=$DB_PASSWORD 2>&1; then
    error "Failed to create user '$DB_USER'."
    fix "Try manually: gcloud sql users create $DB_USER --instance=$INSTANCE_NAME --password=YOUR_PASSWORD"
    exit 1
  fi
fi
success "User '$DB_USER' is ready."

# Verify
info "Verifying database and user..."
gcloud sql databases list --instance=$INSTANCE_NAME
gcloud sql users list --instance=$INSTANCE_NAME

# =============================================================
# STEP 6 — Create KIND Cluster
# =============================================================
echo ""
echo "[6/9] Creating KIND cluster '$CLUSTER_NAME'..."

# Check if Docker is running
if ! docker info &>/dev/null; then
  error "Docker is not running."
  fix "Start Docker Desktop and try again"
  exit 1
fi

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
  warn "KIND cluster '$CLUSTER_NAME' already exists. Skipping creation."
else
  if ! kind create cluster --name $CLUSTER_NAME 2>&1; then
    error "Failed to create KIND cluster."
    fix "Make sure Docker is running: docker info"
    fix "Try deleting existing cluster: kind delete cluster --name $CLUSTER_NAME"
    fix "Check KIND installation: kind version"
    exit 1
  fi
fi
success "KIND cluster '$CLUSTER_NAME' is ready."

# =============================================================
# STEP 7 — Create Kubernetes Namespace & Secrets
# =============================================================
echo ""
echo "[7/9] Setting up Kubernetes namespace and secrets..."

if ! kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f - 2>&1; then
  error "Failed to create namespace '$NAMESPACE'."
  fix "Check kubectl is connected to the cluster: kubectl cluster-info"
  fix "Try: kubectl config use-context kind-$CLUSTER_NAME"
  exit 1
fi

if ! kubectl create secret generic mlflow-env-secret \
  --from-literal=MLFLOW_TRACKING_USERNAME=$DB_USER \
  --from-literal=MLFLOW_TRACKING_PASSWORD=$DB_PASSWORD \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f - 2>&1; then
  error "Failed to create Kubernetes secret."
  fix "Check kubectl permissions: kubectl auth can-i create secret -n $NAMESPACE"
  exit 1
fi
success "Namespace and secrets are ready."

# =============================================================
# STEP 8 — Install MLflow via Helm
# =============================================================
echo ""
echo "[8/9] Installing MLflow via Helm..."

if ! helm repo add community-charts https://community-charts.github.io/helm-charts 2>&1; then
  error "Failed to add Helm repo."
  fix "Check your internet connection"
  fix "Try manually: helm repo add community-charts https://community-charts.github.io/helm-charts"
  exit 1
fi

helm repo update

if ! helm upgrade --install mlflow community-charts/mlflow \
  --namespace $NAMESPACE \
  --set backendStore.databaseMigration=true \
  --set backendStore.postgres.enabled=true \
  --set backendStore.postgres.host=$DB_IP \
  --set backendStore.postgres.port=5432 \
  --set backendStore.postgres.database=$DATABASE_NAME \
  --set backendStore.postgres.user=$DB_USER \
  --set backendStore.postgres.password=$DB_PASSWORD 2>&1; then
  error "Failed to install MLflow via Helm."
  fix "Check Helm is installed: helm version"
  fix "Check the chart exists: helm search repo community-charts/mlflow"
  fix "Check DB credentials are correct"
  exit 1
fi
success "MLflow installed via Helm."

# =============================================================
# STEP 9 — Wait for Pod to be Ready
# =============================================================
echo ""
echo "[9/9] Waiting for MLflow pod to be ready..."

if ! kubectl wait --for=condition=ready pod \
  -l app=mlflow \
  -n $NAMESPACE \
  --timeout=180s 2>&1; then
  error "MLflow pod did not become ready in time."
  fix "Check pod status        : kubectl get pods -n $NAMESPACE"
  fix "Check pod logs          : kubectl logs -l app=mlflow -n $NAMESPACE"
  fix "Check init container    : kubectl logs -l app=mlflow -n $NAMESPACE -c mlflow-db-migration"
  fix "Check events            : kubectl get events -n $NAMESPACE --sort-by=.metadata.creationTimestamp"
  exit 1
fi

# =============================================================
# DONE
# =============================================================
echo ""
echo "============================================="
success " Setup Complete!"
echo "============================================="
echo " DB IP       : $DB_IP"
echo " DB Name     : $DATABASE_NAME"
echo " DB User     : $DB_USER"
echo " Cluster     : $CLUSTER_NAME"
echo " Namespace   : $NAMESPACE"
echo "============================================="
echo ""
echo "👉 Access MLflow UI:"
echo "   kubectl port-forward svc/mlflow -n $NAMESPACE 5000:5000"
echo "   Then open: http://localhost:5000"
echo ""
echo "🧹 Cleanup commands (run manually when done):"
echo "   kind delete cluster --name $CLUSTER_NAME"
echo "   gcloud sql instances delete $INSTANCE_NAME"
echo ""
