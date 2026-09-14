# GCP Workload Identity Federation Setup Guide for Cloud API Adaptor

This guide explains how to configure and use Workload Identity Federation (WIF) with Cloud API Adaptor on GKE, especially when running with `hostNetwork: true`.

## Overview

Workload Identity Federation allows your CAA pods to authenticate to GCP without static service account key files, using short-lived tokens instead. This is the recommended approach for GCP authentication on Kubernetes.

> **Why Direct WIF Instead of GKE Workload Identity?**
>
> GKE's standard Workload Identity uses a metadata server proxy to provide credentials. However, when CAA runs with `hostNetwork: true` (required for pod-VM tunneling), the pod **bypasses the proxy** and reads the node's service account from the GCE metadata server instead.
>
> Direct WIF solves this by using GCP's `identitynamespace` pattern to exchange Kubernetes service account tokens for GCP credentials via the Security Token Service (STS), without relying on the metadata server.

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

## Step 1: Set Up Variables

```bash
# GCP Project configuration
export PROJECT_ID="my-gcp-project"
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')
export REGION="us-central1"
export ZONE="${REGION}-a"

# Kubernetes configuration
export CLUSTER_NAME="my-gke-cluster"
export NAMESPACE="confidential-containers-system"
export K8S_SERVICE_ACCOUNT="cloud-api-adaptor"

# GCP Service Account for CAA
export GSA_NAME="cloud-api-adaptor"
export GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Workload Identity Pool (using GKE's built-in pool)
export WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"

# GKE cluster identifier for WIF audience
export CLUSTER_LOCATION="${REGION}"  # or specific zone like "us-central1-a"
export CLUSTER_ID="gke://${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME}"

echo "Project ID: ${PROJECT_ID}"
echo "Project Number: ${PROJECT_NUMBER}"
echo "GSA Email: ${GSA_EMAIL}"
echo "Workload Pool: ${WORKLOAD_POOL}"
echo "Cluster ID: ${CLUSTER_ID}"
```

## Step 2: Enable Required APIs

```bash
gcloud services enable \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project=${PROJECT_ID}
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
# Add IAM policy binding for workload identity
gcloud iam service-accounts add-iam-policy-binding ${GSA_EMAIL} \
  --project=${PROJECT_ID} \
  --role="roles/iam.workloadIdentityUser" \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WORKLOAD_POOL}/subject/system:serviceaccount:${NAMESPACE}:${K8S_SERVICE_ACCOUNT}"

# Verify the binding
gcloud iam service-accounts get-iam-policy ${GSA_EMAIL} \
  --project=${PROJECT_ID}
```

You should see output like:
```yaml
bindings:
- members:
  - principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/my-project.svc.id.goog/subject/system:serviceaccount:confidential-containers-system:cloud-api-adaptor
  role: roles/iam.workloadIdentityUser
```

## Step 6: Deploy Cloud API Adaptor with WIF

### Option A: Deploy Using Helm with values file

Create a `gcp-wif-values.yaml` file:

```yaml
provider: gcp

# Enable GCP Workload Identity Federation
gcp:
  workloadIdentityFederation:
    enable: true
    serviceAccount: "cloud-api-adaptor@my-gcp-project.iam.gserviceaccount.com"
    workloadPool: "my-gcp-project.svc.id.goog"
    cluster: "gke://my-gcp-project/us-central1/my-gke-cluster"

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
