# GCP Workload Identity Federation Implementation

## Overview

This implementation adds support for GCP Workload Identity Federation (WIF) to the peerpods Helm chart, addressing the feedback in [PR #3077](https://github.com/confidential-containers/cloud-api-adaptor/pull/3077) to consolidate WIF credentials into existing resources rather than creating a separate ConfigMap.

## Key Changes

### 1. Configuration in `values.yaml`

Added a new `gcp.workloadIdentityFederation` section with the following fields:
- `enable`: Boolean to enable/disable WIF
- `serviceAccount`: GCP service account email to impersonate
- `workloadPool`: GCP project workload identity pool
- `cluster`: GKE cluster identifier URL

### 2. Helper Function in `_helpers.tpl`

Added `peerpods.gcpWifEnabled` helper that returns "true" when:
- Provider is `gcp`
- WIF is enabled via `gcp.workloadIdentityFederation.enable: true`

### 3. Secret Updates in `secrets.yaml`

Modified `peer-pods-secret` to include `GOOGLE_APPLICATION_CREDENTIALS_JSON` when WIF is enabled. This follows the existing pattern where authentication credentials are stored in the secret (like `GCP_CREDENTIALS`, `AWS_ACCESS_KEY_ID`, etc.), while non-sensitive configuration goes in the ConfigMap.

The credentials contain the external account credentials configuration with:
- `type`: "external_account"
- `audience`: Constructed from workloadPool and cluster values
- `subject_token_type`: JWT token type
- `token_url`: GCP STS endpoint
- `service_account_impersonation_url`: GCP IAM credentials endpoint
- `credential_source`: Points to the projected K8s token file

### 4. DaemonSet Updates in `daemonset.yaml`

Added the following when WIF is enabled:
- Volume mount for projected K8s service account token at `/var/run/secrets/tokens/gcp-ksa`
- Projected volume `gcp-wif-token` with:
  - Audience set to the workload pool
  - 3600 seconds expiration
  - Token written to `token` file

### 5. Entrypoint Script Updates in `entrypoint.sh`

Modified the `gcp()` function to support both authentication methods, following the AWS IRSA pattern:
- Uses `one_of GCP_CREDENTIALS GOOGLE_APPLICATION_CREDENTIALS_JSON` to ensure at least one auth method is configured

- **WIF mode** (when `GOOGLE_APPLICATION_CREDENTIALS_JSON` is set):
  - Reads `GOOGLE_APPLICATION_CREDENTIALS_JSON` from Secret (via environment variable)
  - Writes it to `/var/run/secrets/gcp-creds/credentials.json`
  - Sets `GOOGLE_APPLICATION_CREDENTIALS` to point to the file
  - Does not require `GCP_CREDENTIALS` environment variable

- **Traditional mode** (when `GCP_CREDENTIALS` is set):
  - Reads `GCP_CREDENTIALS` from Secret (via environment variable)
  - Writes it to `/tmp/gcp-creds.json`
  - Sets `GOOGLE_APPLICATION_CREDENTIALS` to point to the file
  - Maintains backward compatibility

## How It Works

1. When WIF is enabled, the Helm chart configures:
   - A projected service account token that Kubernetes generates and rotates
   - The WIF credentials JSON in the `peer-pods-secret` Secret (following the same pattern as `GCP_CREDENTIALS`)

2. At container startup, the entrypoint script:
   - Checks for `GOOGLE_APPLICATION_CREDENTIALS_JSON` (similar to how AWS checks for `AWS_ROLE_ARN`)
   - If present, writes the credentials JSON from the Secret to a file
   - Sets `GOOGLE_APPLICATION_CREDENTIALS` to point to this file

3. The GCP Go SDK automatically:
   - Reads the external account credentials configuration
   - Exchanges the K8s service account token for a GCP access token via STS
   - Impersonates the specified GCP service account
   - Uses the resulting credentials for GCP API calls

## Differences from PR #3077

This implementation addresses the review comment and follows AWS IRSA best practices:
- ✅ **Using existing `peer-pods-secret` Secret** instead of creating `gcp-direct-wi-creds-config` ConfigMap
- ✅ **Following credential storage pattern**: Authentication credentials go in Secret (like `GCP_CREDENTIALS`, `AWS_ACCESS_KEY_ID`), configuration goes in ConfigMap
- ✅ **Following AWS IRSA pattern**: Uses `one_of` to check for either static credentials or workload identity
- ✅ **Maintaining consistency** with other providers (e.g., Alibaba Cloud RRSA, AWS IRSA)
- ✅ **Backward compatibility** with traditional GCP_CREDENTIALS authentication
- ✅ **No extra env var flags**: Auto-detects authentication method based on which env vars are set

## Usage Example

```yaml
# values.yaml
provider: gcp

gcp:
  workloadIdentityFederation:
    enable: true
    serviceAccount: "caa@my-project.iam.gserviceaccount.com"
    workloadPool: "my-project.svc.id.goog"
    cluster: "gke://projects/my-project/locations/us-central1/clusters/my-cluster"

providerConfigs:
  gcp:
    GCP_PROJECT_ID: "my-project"
    GCP_ZONE: "us-central1-a"
    PODVM_IMAGE_NAME: "my-podvm-image"

# No GCP_CREDENTIALS needed when WIF is enabled
```

## Benefits

1. **No separate ConfigMap**: Addresses the PR feedback directly
2. **Simpler deployment**: Fewer Kubernetes resources to manage
3. **Consistent pattern**: Follows the same approach as Alibaba Cloud RRSA
4. **Backward compatible**: Traditional authentication still works when WIF is disabled
5. **Works with hostNetwork: true**: Solves the metadata server bypass issue on GKE

## Testing

To test this implementation:

1. Set up a GKE cluster with Workload Identity enabled
2. Create a GCP service account with necessary permissions
3. Configure the Helm values as shown above
4. Install the chart: `helm install peerpods ./charts/peerpods -f values.yaml`
5. Verify the daemonset can authenticate to GCP without static credentials

## Files Modified

- `src/cloud-api-adaptor/entrypoint.sh` - Added WIF authentication logic
- `src/cloud-api-adaptor/install/charts/peerpods/templates/_helpers.tpl` - Added helper function
- `src/cloud-api-adaptor/install/charts/peerpods/templates/secrets.yaml` - Added WIF credentials JSON to peer-pods-secret
- `src/cloud-api-adaptor/install/charts/peerpods/templates/daemonset.yaml` - Added token mount
- `src/cloud-api-adaptor/install/charts/peerpods/values.yaml` - Added configuration section
