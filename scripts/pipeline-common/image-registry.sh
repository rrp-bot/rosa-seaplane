#!/usr/bin/env bash
# Shared private ECR image registry helpers.

IMAGE_REGISTRY_SSM_PARAMETER="/infra/image-registry/account_id"
IMAGE_REGISTRY_SSM_REFERENCE="ssm://${IMAGE_REGISTRY_SSM_PARAMETER}"

image_registry_account_id_from_ssm() {
    local region="$1"
    local account_id

    if ! account_id=$(aws ssm get-parameter \
        --name "$IMAGE_REGISTRY_SSM_PARAMETER" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --region "$region" 2>/dev/null); then
        echo "ERROR: SSM parameter ${IMAGE_REGISTRY_SSM_PARAMETER} is missing or unreadable in the current account, region ${region}" >&2
        return 1
    fi

    if [[ ! "$account_id" =~ ^[0-9]{12}$ ]]; then
        echo "ERROR: SSM parameter ${IMAGE_REGISTRY_SSM_PARAMETER} in region ${region} must contain a 12-digit AWS account ID" >&2
        return 1
    fi

    printf '%s' "$account_id"
}

resolve_image_registry_account_id_from_target() {
    local parameter_reference="$1"

    if [[ "$parameter_reference" != "$IMAGE_REGISTRY_SSM_REFERENCE" ]]; then
        echo "ERROR: image_registry_account_id must reference ${IMAGE_REGISTRY_SSM_REFERENCE}" >&2
        return 1
    fi

    IMAGE_REGISTRY_ACCOUNT_ID=$(image_registry_account_id_from_ssm "${TARGET_REGION}") || return 1
    export IMAGE_REGISTRY_ACCOUNT_ID
}

# Resolve a repo:tag reference to the shared ECR URI. Full ECR refs are accepted
# so operators can still override the platform image explicitly.
resolve_platform_image() {
    local image_ref="$1"
    local region="$2"
    local account_id

    if [[ "$image_ref" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/.+ ]]; then
        printf '%s' "$image_ref"
        return 0
    fi

    if [[ ! "$image_ref" =~ ^[a-zA-Z0-9._/-]+:[^/[:space:]]+$ ]]; then
        echo "ERROR: platform_image must be a repository:tag reference or a full ECR image URI, got '${image_ref}'" >&2
        return 1
    fi

    account_id=$(image_registry_account_id_from_ssm "$region") || return 1
    printf '%s.dkr.ecr.us-east-1.amazonaws.com/%s' "$account_id" "$image_ref"
}
