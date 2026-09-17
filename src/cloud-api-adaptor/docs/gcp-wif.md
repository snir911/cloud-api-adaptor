# GCP Workload Identity Federation Setup Guide for Cloud API Adaptor

This guide explains how to configure and use Workload Identity Federation (WIF) with Cloud API Adaptor on GKE, especially when running with `hostNetwork: true`.

## Overview

Workload Identity Federation allows your CAA pods to authenticate to GCP without static service account key files, using short-lived tokens instead. This is the recommended approach for GCP authentication on Kubernetes.

> **Why Direct WIF Instead of GKE Workload Identity?**
>
> GKE's standard Workload Identity uses a metadata server proxy to provide credentials. However, when CAA runs with `hostNetwork: true` (required for pod-VM tunneling), the pod **bypasses the proxy** and reads the node's service account from the GCE metadata server instead.
>
> Direct WIF solves this by creating a custom Workload Identity Pool and OIDC provider that exchanges Kubernetes service account tokens for GCP credentials via the Security Token Service (STS), without relying on the metadata server.

## Architecture: Two Workload Identity Components

This implementation requires **both** components working together:

### 1. GKE Workload Identity (Enabled on Cluster)
- **Purpose**: Allows Kubernetes to issue service account tokens
- **What it does**: Configures the K8s API server to sign tokens with audience `PROJECT_ID.svc.id.goog`
- **What it creates**: The pool `PROJECT_ID.svc.id.goog` (for token issuance only)
- **Used by**: Standard GKE Workload Identity (with metadata server)

### 2. Custom Workload Identity Pool (Created in Step 2b)
- **Purpose**: Validates tokens and exchanges them for GCP credentials
- **What it does**: Direct token exchange via STS (bypasses metadata server)
- **What it creates**: Pool `caa-direct-wif-pool` with OIDC provider
- **Used by**: CAA with `hostNetwork: true`

### How They Work Together

```
┌─────────────────┐
│ GKE Cluster     │ ← (1) GKE WI enabled: can issue tokens
└────────┬────────┘
         │ Issues token with audience: PROJECT_ID.svc.id.goog
         ▼
┌─────────────────┐
│ CAA Pod         │ ← (2) Projected token volume
│ (hostNetwork)   │     Token mounted at /var/run/secrets/tokens/gcp-ksa/token
└────────┬────────┘
         │ Reads token + credentials JSON
         ▼
┌─────────────────┐
│ GCP STS         │ ← (3) Custom WIF pool validates token
│ (Token Service) │     Pool: caa-direct-wif-pool
└────────┬────────┘     Audience: PROJECT_ID.svc.id.goog (matches token)
         │ Returns federated token
         ▼
┌─────────────────┐
│ GCP IAM         │ ← (4) Impersonates GSA
│                 │     Returns short-lived credentials
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Compute Engine  │ ← (5) CAA creates peer pods
│ API             │
└─────────────────┘
```

**Key Point**: You need GKE Workload Identity enabled for step (1) to work, even though you're creating a custom pool for steps (3-4).

## Benefits

- **No static credentials** - No long-lived service account keys in Kubernetes secrets
- **Automatic token rotation** - Kubernetes automatically rotates the service account tokens
- **Works with hostNetwork: true** - Bypasses the metadata server limitation
- **Fine-grained permissions** - Each service account can have different IAM roles
- **GCP best practice** - Follows GCP security recommendations

## Prerequisites

- GKE cluster (any version) or self-managed Kubernetes cluster
- `kubectl` configured to access your cluster
- `gcloud` CLI installed and authenticated
- Appropriate GCP IAM permissions to create service accounts and manage IAM policies
- Project with necessary APIs enabled (Compute Engine, IAM, STS)

## Step 1: Set Up Variables and Check Workload Identity

### 1.1 Auto-Detect Your Cluster

If you know your cluster name but not the location:

```bash
# Set your project and cluster name
export PROJECT_ID="my-gcp-project"
export CLUSTER_NAME="my-gke-cluster"

# Auto-detect the cluster location
export CLUSTER_LOCATION=$(gcloud container clusters list \
  --project=${PROJECT_ID} \
  --filter="name:${CLUSTER_NAME}" \
  --format="value(location)" \
  --limit=1)

if [ -z "${CLUSTER_LOCATION}" ]; then
  echo "Error: Cluster '${CLUSTER_NAME}' not found in project '${PROJECT_ID}'"
  echo "Available clusters:"
  gcloud container clusters list --project=${PROJECT_ID} --format="table(name,location)"
  exit 1
fi

echo "Found cluster: ${CLUSTER_NAME} in location: ${CLUSTER_LOCATION}"
```

### 1.2 Set Up All Variables

```bash
# Project configuration (already set above)
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')

# Kubernetes configuration
export NAMESPACE="confidential-containers-system"
export K8S_SERVICE_ACCOUNT="cloud-api-adaptor"

# GCP Service Account for CAA
export GSA_NAME="cloud-api-adaptor"
export GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Display configuration
echo "=== Configuration ==="
echo "Project ID: ${PROJECT_ID}"
echo "Project Number: ${PROJECT_NUMBER}"
echo "Cluster Name: ${CLUSTER_NAME}"
echo "Cluster Location: ${CLUSTER_LOCATION}"
echo "Namespace: ${NAMESPACE}"
echo "GCP Service Account: ${GSA_EMAIL}"
echo "K8s Service Account: ${K8S_SERVICE_ACCOUNT}"
```

### Check if Workload Identity is Enabled on GKE

**IMPORTANT**: For direct WIF with `hostNetwork: true`, you need **BOTH**:
1. GKE Workload Identity enabled (for token issuance)
2. A custom workload identity pool (created in Step 2b)

The GKE Workload Identity allows Kubernetes to issue service account tokens, but the custom pool handles the actual authentication (bypassing the metadata server).

```bash
# Check if your GKE cluster has Workload Identity enabled
WI_POOL=$(gcloud container clusters describe ${CLUSTER_NAME} \
  --location=${CLUSTER_LOCATION} \
  --project=${PROJECT_ID} \
  --format="value(workloadIdentityConfig.workloadPool)")

if [ -n "${WI_POOL}" ]; then
  echo "✓ Workload Identity is enabled"
  echo "  Workload Pool: ${WI_POOL}"
  export WORKLOAD_POOL="${WI_POOL}"
else
  echo "✗ Workload Identity is NOT enabled on this cluster"
  echo "  You MUST enable it for token issuance (see section below)"
fi
```

**If Workload Identity is NOT enabled**, you must enable it (Step 1.3 below). This is required even though you'll create a custom pool in Step 2b.

### 1.3 Enabling Workload Identity on GKE (Required)

**Why this is required**: Enabling GKE Workload Identity allows the Kubernetes API server to issue service account tokens with the `PROJECT_ID.svc.id.goog` audience. The custom WIF pool (Step 2b) will validate these tokens.

If the check above shows Workload Identity is not enabled, enable it:

```bash
# Enable Workload Identity on the cluster
gcloud container clusters update ${CLUSTER_NAME} \
  --location=${CLUSTER_LOCATION} \
  --project=${PROJECT_ID} \
  --workload-pool=${PROJECT_ID}.svc.id.goog

# Update your node pool to use Workload Identity metadata
# (Find your node pool name first)
gcloud container node-pools list \
  --cluster=${CLUSTER_NAME} \
  --location=${CLUSTER_LOCATION} \
  --project=${PROJECT_ID}

# Update each node pool
export NODE_POOL="default-pool"  # replace with your actual node pool name

gcloud container node-pools update ${NODE_POOL} \
  --cluster=${CLUSTER_NAME} \
  --location=${CLUSTER_LOCATION} \
  --project=${PROJECT_ID} \
  --workload-metadata=GKE_METADATA
```

**⚠️ Warning**: Updating node pools will cause node recreation and pod restarts!

After enabling, set the variables:

```bash
export WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"
export CLUSTER_ID="gke://${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME}"

echo "Workload Pool: ${WORKLOAD_POOL}"
echo "Cluster ID: ${CLUSTER_ID}"
```

## Step 2: Enable Required APIs

**Why this is required**: GCP APIs must be explicitly enabled before they can be used. Each API serves a specific purpose in the WIF authentication flow and CAA operation.

```bash
gcloud services enable \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  container.googleapis.com \
  --project=${PROJECT_ID}
```

**What each API does:**

- **`compute.googleapis.com`** - Compute Engine API
  - Required for: Creating and managing peer pod VMs
  - Used by: CAA to launch VM instances for peer pods
  - Without it: `Error 403: Compute Engine API has not been used in project`

- **`iam.googleapis.com`** - Identity and Access Management API
  - Required for: Managing service accounts and IAM policies
  - Used by: Creating workload identity pools, service accounts, and IAM bindings
  - Without it: Cannot create or configure service accounts

- **`iamcredentials.googleapis.com`** - IAM Service Account Credentials API
  - Required for: Service account impersonation (generating access tokens)
  - Used by: The final step of WIF authentication where the federated token is exchanged for GSA credentials
  - Without it: `Error 403: IAM Service Account Credentials API has not been used`

- **`sts.googleapis.com`** - Security Token Service API
  - Required for: Exchanging Kubernetes tokens for GCP federated tokens
  - Used by: The token exchange step in WIF (K8s token → federated token)
  - Without it: `Error 403: Security Token Service API has not been used`

- **`container.googleapis.com`** - Kubernetes Engine API
  - Required for: Managing GKE clusters and Workload Identity configuration
  - Used by: Enabling Workload Identity, querying cluster info, OIDC issuer
  - Without it: Cannot enable or configure Workload Identity on the cluster

**Verification:**

Check which APIs are already enabled:
```bash
gcloud services list --enabled --project=${PROJECT_ID} | grep -E "compute|iam|sts|container"
```

## Step 2b: Create Custom Workload Identity Pool (Required)

**Why a custom pool is required**: GKE's built-in workload identity pool (`PROJECT_ID.svc.id.goog`) only works through the metadata server. When CAA runs with `hostNetwork: true`, it bypasses the metadata server and needs direct token exchange via a custom pool.

The custom pool will:
- Accept tokens issued by your GKE cluster (with audience `PROJECT_ID.svc.id.goog`)
- Validate them against the cluster's OIDC issuer
- Exchange them for GCP credentials
- Allow service account impersonation

Create the custom workload identity pool and OIDC provider:

```bash
# Create the workload identity pool
gcloud iam workload-identity-pools create caa-direct-wif-pool \
  --project=${PROJECT_ID} \
  --location=global \
  --display-name="CAA Direct WIF Pool" \
  --description="Workload Identity pool for cloud-api-adaptor with hostNetwork true"

# Construct the GKE OIDC issuer URL
OIDC_ISSUER="https://container.googleapis.com/v1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}"

echo "OIDC Issuer: ${OIDC_ISSUER}"

# Create OIDC provider in the pool
gcloud iam workload-identity-pools providers create-oidc caa-k8s-provider \
  --project=${PROJECT_ID} \
  --location=global \
  --workload-identity-pool=caa-direct-wif-pool \
  --issuer-uri="${OIDC_ISSUER}" \
  --allowed-audiences="${PROJECT_ID}.svc.id.goog" \
  --attribute-mapping="google.subject=assertion.sub,attribute.namespace=assertion['kubernetes.io']['namespace'],attribute.service_account_name=assertion['kubernetes.io']['serviceaccount']['name']" \
  --attribute-condition="assertion.sub.startsWith('system:serviceaccount:')"

# Get the full provider resource name (save this!)
PROVIDER_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/caa-direct-wif-pool/providers/caa-k8s-provider"
echo "Provider Name: ${PROVIDER_NAME}"
echo "Full Audience: //iam.googleapis.com/${PROVIDER_NAME}"
```

**Save these values - you'll need them for deployment:**
```bash
export WORKLOAD_POOL="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/caa-direct-wif-pool"
export CLUSTER_ID="//iam.googleapis.com/${PROVIDER_NAME}"
```

## Step 3: Create GCP Service Account

```bash
# Create the service account
gcloud iam service-accounts create ${GSA_NAME} \
  --display-name="Cloud API Adaptor Service Account" \
  --description="Service account for Cloud API Adaptor to manage peer pods" \
  --project=${PROJECT_ID}

# Verify creation
gcloud iam service-accounts describe ${GSA_EMAIL} --project=${PROJECT_ID}
```

## Step 4: Grant Required Permissions

The service account needs permissions to manage Compute Engine instances and networking.

### Option A: Use Predefined Roles (Simpler)

```bash
# Grant Compute Instance Admin role
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/compute.instanceAdmin.v1"

# Grant Service Account User role (required to attach service accounts to instances)
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/iam.serviceAccountUser"
```

### Option B: Create Custom Role (Least Privilege)

```bash
# Create custom role with minimal required permissions
gcloud iam roles create CloudApiAdaptorRole \
  --project=${PROJECT_ID} \
  --title="Cloud API Adaptor Role" \
  --description="Minimal permissions for Cloud API Adaptor" \
  --permissions="\
compute.instances.create,\
compute.instances.delete,\
compute.instances.get,\
compute.instances.list,\
compute.instances.setMetadata,\
compute.instances.setServiceAccount,\
compute.instances.setTags,\
compute.networks.get,\
compute.subnetworks.use,\
compute.subnetworks.useExternalIp,\
compute.zones.get,\
compute.machineTypes.get,\
compute.images.useReadOnly,\
compute.disks.create"

# Grant the custom role
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="projects/${PROJECT_ID}/roles/CloudApiAdaptorRole"
```

## Step 5: Configure Workload Identity Federation Binding

Allow the Kubernetes service account to impersonate the GCP service account.

```bash
# Add IAM policy bindings for workload identity (using custom pool)
# This allows the K8s SA to impersonate the GSA
gcloud iam service-accounts add-iam-policy-binding ${GSA_EMAIL} \
  --project=${PROJECT_ID} \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/caa-direct-wif-pool/attribute.service_account_name/${K8S_SERVICE_ACCOUNT}"

# Also grant token creator role
gcloud iam service-accounts add-iam-policy-binding ${GSA_EMAIL} \
  --project=${PROJECT_ID} \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/caa-direct-wif-pool/attribute.service_account_name/${K8S_SERVICE_ACCOUNT}"

# Verify the bindings
gcloud iam service-accounts get-iam-policy ${GSA_EMAIL} \
  --project=${PROJECT_ID}
```

You should see output like:
```yaml
bindings:
- members:
  - principalSet://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/caa-direct-wif-pool/attribute.service_account_name/cloud-api-adaptor
  role: roles/iam.workloadIdentityUser
- members:
  - principalSet://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/caa-direct-wif-pool/attribute.service_account_name/cloud-api-adaptor
  role: roles/iam.serviceAccountTokenCreator
```

## Step 6: Deploy Cloud API Adaptor with WIF

### Option A: Deploy Using Helm with values file

Create a `gcp-wif-values.yaml` file:

```yaml
provider: gcp

# Enable GCP Workload Identity Federation
# IMPORTANT: Use the custom pool provider resource name (not identitynamespace format)
gcp:
  workloadIdentityFederation:
    enable: true
    serviceAccount: "cloud-api-adaptor@my-gcp-project.iam.gserviceaccount.com"
    # Token audience - use the GKE workload pool for token validation
    workloadPool: "my-gcp-project.svc.id.goog"
    # Full WIF provider resource name (from Step 2b)
    cluster: "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/caa-direct-wif-pool/providers/caa-k8s-provider"

# GCP provider configuration (non-sensitive)
providerConfigs:
  gcp:
    GCP_PROJECT_ID: "my-gcp-project"
    GCP_ZONE: "us-central1-a"
    PODVM_IMAGE_NAME: "projects/my-gcp-project/global/images/podvm-image"
    # Optional configurations
    # PODVM_INSTANCE_TYPE: "n2d-standard-2"
    # DISABLECVM: "false"

# Do NOT set secrets.mode or providerSecrets when using WIF
# The WIF credentials are auto-generated by the chart
secrets:
  mode: "create"
```

Deploy:

```bash
helm install peerpods ./install/charts/peerpods \
  --namespace ${NAMESPACE} \
  --create-namespace \
  -f gcp-wif-values.yaml
```

### Option B: Deploy Using Helm with --set Flags

```bash
helm install peerpods ./install/charts/peerpods \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --set provider=gcp \
  --set gcp.workloadIdentityFederation.enable=true \
  --set gcp.workloadIdentityFederation.serviceAccount=${GSA_EMAIL} \
  --set gcp.workloadIdentityFederation.workloadPool=${WORKLOAD_POOL} \
  --set "gcp.workloadIdentityFederation.cluster=${CLUSTER_ID}" \
  --set providerConfigs.gcp.GCP_PROJECT_ID=${PROJECT_ID} \
  --set providerConfigs.gcp.GCP_ZONE=${ZONE} \
  --set providerConfigs.gcp.PODVM_IMAGE_NAME=projects/${PROJECT_ID}/global/images/podvm-image
```

### Option C: Add WIF to Existing Deployment

If you already have CAA deployed with static credentials:

1. Update your values file or create a new one with WIF configuration
2. Upgrade the Helm release:

```bash
helm upgrade peerpods ./install/charts/peerpods \
  --namespace ${NAMESPACE} \
  -f gcp-wif-values.yaml
```

3. After verifying WIF is working (see Step 7), remove the static credentials:

```bash
# Remove GCP_CREDENTIALS from your values file or secret
# Then upgrade again
helm upgrade peerpods ./install/charts/peerpods \
  --namespace ${NAMESPACE} \
  -f gcp-wif-values.yaml
```

## Step 7: Verify WIF is Working

### 1. Check Secret Contains WIF Credentials

```bash
kubectl get secret peer-pods-secret \
  -n ${NAMESPACE} \
  -o jsonpath='{.data.GOOGLE_APPLICATION_CREDENTIALS_JSON}' | base64 -d | jq
```

Expected output (credentials JSON):
```json
{
  "type": "external_account",
  "audience": "identitynamespace:my-project.svc.id.goog:gke://my-project/us-central1/my-cluster",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/cloud-api-adaptor@my-project.iam.gserviceaccount.com:generateAccessToken",
  "credential_source": {
    "file": "/var/run/secrets/tokens/gcp-ksa/token"
  }
}
```

### 2. Check Pod Has Projected Token

```bash
CAA_POD=$(kubectl get pods -n ${NAMESPACE} \
  -l app=cloud-api-adaptor \
  -o jsonpath='{.items[0].metadata.name}')

echo "CAA Pod: ${CAA_POD}"

# Check if the projected token volume is mounted
kubectl describe pod ${CAA_POD} -n ${NAMESPACE} | grep -A 5 "gcp-wif-token"

# Verify the token file exists
kubectl exec -n ${NAMESPACE} ${CAA_POD} -- ls -la /var/run/secrets/tokens/gcp-ksa/
```

### 3. Check Environment Variables

```bash
kubectl exec -n ${NAMESPACE} ${CAA_POD} -- env | grep -E "GCP|GOOGLE"
```

Expected output should include:
```
GCP_PROJECT_ID=my-gcp-project
GCP_ZONE=us-central1-a
PODVM_IMAGE_NAME=projects/my-gcp-project/global/images/podvm-image
GOOGLE_APPLICATION_CREDENTIALS_JSON={"type":"external_account",...}
```

### 4. Check CAA Logs

```bash
kubectl logs -n ${NAMESPACE} ${CAA_POD} --tail=50
```

Look for successful authentication messages. You should NOT see errors like:
- "Error: google: could not find default credentials"
- "Error: GCP_CREDENTIALS is not set"

### 5. Test Pod Creation

Create a test pod to verify CAA can create peer pods:

```bash
kubectl run nginx-test \
  --image=nginx \
  --overrides='{"spec":{"runtimeClassName":"kata-remote"}}'

# Watch the pod
kubectl get pod nginx-test -w
```

If the pod starts successfully, WIF is working correctly!

Check the peer pod was created in GCP:

```bash
gcloud compute instances list \
  --project=${PROJECT_ID} \
  --filter="name~podvm" \
  --format="table(name,zone,machineType,status)"
```

## Troubleshooting

### Issue: Pod fails to start with authentication errors

**Check 1**: Verify the IAM binding is correct:
```bash
gcloud iam service-accounts get-iam-policy ${GSA_EMAIL} --project=${PROJECT_ID}
```

**Check 2**: Verify the workload pool format:
```bash
# Should be: PROJECT_ID.svc.id.goog
echo ${WORKLOAD_POOL}
```

**Check 3**: Verify the cluster ID format:
```bash
# Should be: gke://PROJECT_ID/LOCATION/CLUSTER_NAME
echo ${CLUSTER_ID}
```

### Issue: Token file not found

**Check**: Verify the projected token volume is mounted:
```bash
kubectl get pod ${CAA_POD} -n ${NAMESPACE} -o yaml | grep -A 20 "volumes:" | grep -A 10 "gcp-wif-token"
```

### Issue: Permission denied errors when creating instances

**Check**: Verify the service account has the required roles:
```bash
gcloud projects get-iam-policy ${PROJECT_ID} \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${GSA_EMAIL}" \
  --format="table(bindings.role)"
```

### Issue: "Invalid audience" errors

The audience in the credentials JSON must match the format:
```
identitynamespace:WORKLOAD_POOL:CLUSTER_ID
```

Verify your values:
```bash
kubectl get secret peer-pods-secret -n ${NAMESPACE} \
  -o jsonpath='{.data.GOOGLE_APPLICATION_CREDENTIALS_JSON}' | base64 -d | jq -r '.audience'
```

Should output something like:
```
identitynamespace:my-project.svc.id.goog:gke://my-project/us-central1/my-cluster
```

## Self-Managed Kubernetes (Non-GKE)

For self-managed Kubernetes clusters, you need to:

1. **Create your own Workload Identity Pool** (GKE provides this automatically):

```bash
# Create workload identity pool
gcloud iam workload-identity-pools create ${CLUSTER_NAME} \
  --project=${PROJECT_ID} \
  --location=global \
  --display-name="Kubernetes cluster ${CLUSTER_NAME}"

# Create OIDC provider in the pool
gcloud iam workload-identity-pools providers create-oidc ${CLUSTER_NAME}-oidc \
  --project=${PROJECT_ID} \
  --location=global \
  --workload-identity-pool=${CLUSTER_NAME} \
  --issuer-uri="https://kubernetes.default.svc.cluster.local" \
  --attribute-mapping="google.subject=assertion.sub,attribute.namespace=assertion['kubernetes.io']['namespace'],attribute.service_account_name=assertion['kubernetes.io']['serviceaccount']['name']"
```

2. **Update the Helm values** to use your custom workload pool:

```yaml
gcp:
  workloadIdentityFederation:
    enable: true
    serviceAccount: "cloud-api-adaptor@my-project.iam.gserviceaccount.com"
    workloadPool: "my-project.svc.id.goog"  # For GKE
    # OR for custom pool:
    # workloadPool: "projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID"
    cluster: "//iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/providers/PROVIDER_ID"
```

## Migrating from Static Credentials to WIF

1. Deploy CAA with WIF configuration (keeping static credentials)
2. Verify WIF works by checking logs and creating test pods
3. Remove `GCP_CREDENTIALS` from your values file
4. Upgrade the Helm release
5. Verify pods still work without static credentials

## Cleanup and Uninstallation

### Uninstall CAA with WIF

```bash
export NAMESPACE="confidential-containers-system"

# Uninstall the Helm release
helm uninstall peerpods -n ${NAMESPACE}

# Optionally delete the namespace
kubectl delete namespace ${NAMESPACE}
```

### Remove GCP Resources

If you want to completely clean up the WIF setup:

```bash
export PROJECT_ID="my-gcp-project"
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')
export GSA_EMAIL="cloud-api-adaptor@${PROJECT_ID}.iam.gserviceaccount.com"

# 1. Remove IAM bindings
echo "=== Removing IAM Bindings ==="
gcloud iam service-accounts remove-iam-policy-binding ${GSA_EMAIL} \
  --project=${PROJECT_ID} \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/caa-direct-wif-pool/attribute.service_account_name/cloud-api-adaptor" \
  --quiet

gcloud iam service-accounts remove-iam-policy-binding ${GSA_EMAIL} \
  --project=${PROJECT_ID} \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/caa-direct-wif-pool/attribute.service_account_name/cloud-api-adaptor" \
  --quiet

# 2. Delete the OIDC provider
echo "=== Deleting OIDC Provider ==="
gcloud iam workload-identity-pools providers delete caa-k8s-provider \
  --workload-identity-pool=caa-direct-wif-pool \
  --project=${PROJECT_ID} \
  --location=global \
  --quiet

# 3. Delete the workload identity pool
echo "=== Deleting Workload Identity Pool ==="
gcloud iam workload-identity-pools delete caa-direct-wif-pool \
  --project=${PROJECT_ID} \
  --location=global \
  --quiet

# 4. Remove GCP project IAM bindings (if you created them)
echo "=== Removing Project IAM Bindings ==="
gcloud projects remove-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/compute.instanceAdmin.v1" \
  --quiet

gcloud projects remove-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --quiet

# 5. Delete the GCP service account (WARNING: This is destructive!)
echo "=== Deleting GCP Service Account ==="
read -p "Are you sure you want to delete the service account ${GSA_EMAIL}? (yes/no) " -r
if [[ $REPLY == "yes" ]]; then
  gcloud iam service-accounts delete ${GSA_EMAIL} \
    --project=${PROJECT_ID} \
    --quiet
  echo "Service account deleted"
else
  echo "Service account deletion skipped"
fi
```

### Cleanup Verification

```bash
# Verify the pool is deleted
gcloud iam workload-identity-pools list \
  --project=${PROJECT_ID} \
  --location=global

# Verify the service account still exists (if you kept it)
gcloud iam service-accounts list \
  --project=${PROJECT_ID} \
  --filter="email:cloud-api-adaptor@"

# Verify no CAA pods are running
kubectl get pods -n ${NAMESPACE} -l app=cloud-api-adaptor
```

### Partial Cleanup (Keep Infrastructure)

If you want to disable WIF but keep the GCP resources for future use:

```bash
# Just disable WIF in the Helm values
helm upgrade peerpods ./install/charts/peerpods \
  --namespace ${NAMESPACE} \
  --set gcp.workloadIdentityFederation.enable=false \
  --reuse-values

# The GCP service account and workload identity pool remain intact
```

## Security Best Practices

1. **Use least privilege**: Grant only the minimum required GCP permissions
2. **Regular rotation**: While WIF tokens auto-rotate, periodically review and update IAM bindings
3. **Monitor usage**: Enable Cloud Audit Logs to track service account usage
4. **Namespace isolation**: Use separate GCP service accounts for different namespaces if needed
5. **Network policies**: Restrict which pods can communicate with the GCP APIs

## References

- [GCP Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [GKE Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [Service Account Impersonation](https://cloud.google.com/iam/docs/impersonating-service-accounts)
- [Cloud API Adaptor GCP Provider](https://github.com/confidential-containers/cloud-api-adaptor/tree/main/src/cloud-api-adaptor/gcp)
- [Kubernetes Service Account Token Volume Projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection)
