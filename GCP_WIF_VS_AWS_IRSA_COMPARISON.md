# GCP WIF vs AWS IRSA Implementation Comparison

This document compares the GCP Workload Identity Federation (WIF) implementation with the AWS IRSA pattern to demonstrate consistency.

## Authentication Method Detection

Both implementations use the same pattern to detect which authentication method to use:

### AWS (entrypoint.sh lines 48-62)
```bash
aws() {
    # Check that at least one authentication method is configured
    one_of AWS_SECRET_ACCESS_KEY AWS_ROLE_ARN

    # If using web identity, require role ARN and token file
    if [ -n "${AWS_ROLE_ARN}" ]; then
        test_vars AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
    else
        # If using access keys, require both key and secret
        test_vars AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    fi

    set -x
    exec cloud-api-adaptor aws ${optionals}
}
```

### GCP (entrypoint.sh lines 82-106)
```bash
gcp() {
    # Check that at least one authentication method is configured
    one_of GCP_CREDENTIALS GOOGLE_APPLICATION_CREDENTIALS_JSON

    test_vars GCP_PROJECT_ID GCP_ZONE PODVM_IMAGE_NAME

    # Handle GCP authentication
    if [ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON}" ]; then
        # Workload Identity Federation: credentials JSON from ConfigMap
        mkdir -p /var/run/secrets/gcp-creds
        echo "$GOOGLE_APPLICATION_CREDENTIALS_JSON" > /var/run/secrets/gcp-creds/credentials.json
        export GOOGLE_APPLICATION_CREDENTIALS=/var/run/secrets/gcp-creds/credentials.json
    else
        # Traditional static credentials
        echo "$GCP_CREDENTIALS" > /tmp/gcp-creds.json
        export GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcp-creds.json
    fi

    set -x
    exec cloud-api-adaptor gcp ${optionals}
}
```

## Key Similarities

| Aspect | AWS IRSA | GCP WIF | Match |
|--------|----------|---------|-------|
| **Authentication check** | `one_of AWS_SECRET_ACCESS_KEY AWS_ROLE_ARN` | `one_of GCP_CREDENTIALS GOOGLE_APPLICATION_CREDENTIALS_JSON` | ✅ |
| **Auto-detection** | Checks for presence of `AWS_ROLE_ARN` | Checks for presence of `GOOGLE_APPLICATION_CREDENTIALS_JSON` | ✅ |
| **No extra flags** | No `AWS_IRSA_ENABLED` flag | No `GCP_WIF_ENABLED` flag | ✅ |
| **Credential storage** | Static creds in peer-pods-secret | Both static and WIF creds in peer-pods-secret | ✅ |
| **Projected tokens** | Uses projected ServiceAccount token | Uses projected ServiceAccount token | ✅ |
| **Token location** | `/var/run/secrets/eks.amazonaws.com/serviceaccount/token` (EKS managed) or custom path (self-managed) | `/var/run/secrets/tokens/gcp-ksa/token` | ✅ |
| **Backward compat** | Works with static AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY | Works with static GCP_CREDENTIALS | ✅ |

## Key Differences

### AWS IRSA
- **EKS Managed**: On EKS, ServiceAccount annotation → EKS auto-injects `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN`
- **SDK Support**: AWS SDK natively supports Web Identity Token authentication via environment variables alone
- **No file writing**: The entrypoint doesn't write any files; SDK reads the token directly

### GCP WIF
- **Manual Setup**: GKE Workload Identity doesn't work with `hostNetwork: true`, so we use direct WIF
- **File Required**: GCP Application Default Credentials (ADC) requires `GOOGLE_APPLICATION_CREDENTIALS` to point to a file path
- **File writing**: The entrypoint must write the credentials JSON to a file, similar to how it writes traditional GCP_CREDENTIALS

## Why GCP Needs to Write a File

The key difference is in the SDK requirements:

**AWS SDK**: Supports Web Identity Federation via environment variables
```bash
export AWS_WEB_IDENTITY_TOKEN_FILE=/path/to/token
export AWS_ROLE_ARN=arn:aws:iam::123456789012:role/MyRole
# SDK automatically reads the token and assumes the role
```

**GCP SDK**: Requires GOOGLE_APPLICATION_CREDENTIALS to point to a credentials file
```bash
# Option 1: Traditional service account key
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account-key.json

# Option 2: External account credentials (WIF)
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/external-account-config.json
# The external-account-config.json contains:
# - Token file path (credential_source.file)
# - STS endpoint
# - Service account to impersonate
```

GCP's SDK doesn't support passing the credentials JSON via environment variable content directly; it must be a file path.

## Implementation Pattern Consistency

Despite the file-writing requirement, the GCP implementation follows the same **pattern** as AWS:

1. ✅ Use `one_of` to validate at least one auth method exists
2. ✅ Check for presence of workload identity variables (not a separate enable flag)
3. ✅ Automatically detect which auth method to use
4. ✅ Store configuration in ConfigMap (not a separate resource)
5. ✅ Use projected service account tokens
6. ✅ Maintain backward compatibility

## Comparison to Alibaba Cloud RRSA

Alibaba Cloud RRSA also uses a similar pattern:

```bash
alibabacloud() {
    one_of ALIBABACLOUD_ACCESS_KEY_ID ALIBABA_CLOUD_ROLE_ARN

    # ... rest of implementation
}
```

The Alibaba SDK, like AWS, supports RRSA via environment variables directly without file writing.

## Conclusion

The GCP WIF implementation follows the **exact same pattern** as AWS IRSA and Alibaba RRSA, with the only difference being the SDK's requirement for a credentials file. This is a GCP SDK limitation, not a design choice.

The implementation is:
- ✅ Consistent with AWS IRSA pattern
- ✅ Follows best practices from the codebase
- ✅ Addresses PR #3077 feedback
- ✅ Maintains backward compatibility
- ✅ No unnecessary environment variable flags
