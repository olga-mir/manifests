#!/bin/bash

set -eou pipefail

# https://cloud.google.com/secure-web-proxy/docs/overview
# https://cloud.google.com/secure-web-proxy/docs/initial-setup-steps

vpc_name=$CLUSTER_VPC # sourced in env vars
subnet_name=$CLUSTER_SUBNET

NAMESPACE="platform"
SA_NAME_PRIV="demo-app-priv-sa-ksa2gsa"
SA_NAME_LIMITED="demo-app-limited-sa-ksa2gsa"
gsa_email_priv="$SA_NAME_PRIV@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
gsa_email_limited="$SA_NAME_LIMITED@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

# BUCKET="" - this is needed for test for WLI

SCRIPT_DIR=$(dirname "$(realpath "$0")")
TEMPLATES="$SCRIPT_DIR/../manifests-templates"
RENDERED="$SCRIPT_DIR/../manifests-rendered"

export vpc_name subnet_name sa

for template in "$TEMPLATES"/*; do
  filename=$(basename "$template")
  envsubst < "$template" > "$RENDERED/$filename"
done

# gcloud: resource id must consists of no more than 63 characters: lower case letters, digits and hyphens

# 1 Gateway : 1 Policy : N Rules
policy_name=swp-policy
cert_name=swp-cert

set -x

main() {

# Check if an argument is provided
if [ $# -eq 0 ]; then
    echo "No arguments provided"
    show_help
    exit 1
fi

case "$1" in
    enable_apis)
      enable_apis
        ;;
    generate_certs)
      generate_certs
        ;;
    install_policies)
      install_policies
        ;;
    install_rules)
      install_rules
        ;;
    install_proxy)
      install_proxy
        ;;
    test_wli)
      test_wli
        ;;
    test_federated_wli)
      test_federated_wli
        ;;
    all)
      enable_apis
      generate_certs
      install_policies
      install_rules
      install_proxy
        ;;
    cleanup)
      cleanup
        ;;
    -h|--help)
        show_help
        ;;
    *)
        echo "Invalid option: $1"
        show_help
        exit 1
        ;;
esac
}

# Help function to display available options
show_help() {
    echo "Usage: $0 [option]"
    echo "Most common options:"
    echo "  enable_apis"
    echo "  all"
    echo "  cleanup"
    echo "Or any other function defined in this file"
}


# ---------------- Certificates
generate_certs() {
  key_path="$HOME/.swp/key.pem"
  cert_path="$HOME/.swp/cert.pem"
  SWP_HOST_NAME="myswp.example.com"
  days=30
  openssl req -x509 -newkey rsa:2048 \
    -keyout $key_path \
    -out $cert_path -days $days \
    -subj "/CN=$SWP_HOST_NAME" -nodes -addext \
    "subjectAltName=DNS:$SWP_HOST_NAME"

  gcloud certificate-manager certificates create $cert_name \
     --certificate-file=$cert_path \
     --private-key-file=$key_path \
     --location=$GCP_REGION
}


# ---------------- Gateway security policy
install_policies() {
  gcloud network-security gateway-security-policies import $policy_name \
      --source=$RENDERED/policy.yaml \
      --location=$GCP_REGION
}

install_rules() {
    for rule_yaml in $RENDERED/rule-*.yaml; do
        rule_name=$(basename "$rule_yaml" .yaml)
        gcloud network-security gateway-security-policies rules import "$rule_name" \
            --source="$rule_yaml" \
            --location="$GCP_REGION" \
            --gateway-security-policy="$policy_name"
    done
}


# ----------------   Secure Web Proxy
install_proxy() {
  gcloud network-services gateways import swp \
      --source=$RENDERED/gateway.yaml \
      --location=$GCP_REGION
}


# ----------------   WLI - Federated
test_federated_wli() {
  # source: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#verify

  KSA_NAME="demo-app-priv-sa"
  gcloud storage buckets add-iam-policy-binding gs://$BUCKET \
      --role=roles/storage.objectViewer \
      --member=principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$GCP_PROJECT_ID.svc.id.goog/subject/ns/$NAMESPACE/sa/$KSA_NAME \
      --condition=None

  echo then run this in the pod:
  echo "curl -X GET -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" https://storage.googleapis.com/storage/v1/b/$BUCKET/o"
  # Expect to see { "kind": "storage#objects" } if the response is 403 then WLI is not configured on the cluster (provided the bucket indeed exists in the correct location)

  kubectl apply -f $SCRIPT_DIR/../wli-federated-manifests.yaml
}

# ----------------   WLI - Non-Federated (KSA to GSA mapping)
test_wli() {
  # source: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#kubernetes-sa-to-iam
  gcloud iam service-accounts create $SA_NAME_PRIV --project=$GCP_PROJECT_ID
  gcloud iam service-accounts create $SA_NAME_LIMITED --project=$GCP_PROJECT_ID

  # For testing purposes grant access to a bucket only to 'priv' SA
  gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \
    --member "serviceAccount:$SA_NAME_PRIV@$GCP_PROJECT_ID.iam.gserviceaccount.com" \
    --role=roles/storage.objectViewer

  # Grant ability to use WLI for both SAs (the limitness of the limited pod is in the actual perms to do stuff
  # and access rules in SWP, but not in its usage of WLI itself)
  gcloud iam service-accounts add-iam-policy-binding $SA_NAME_PRIV@$GCP_PROJECT_ID.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:$GCP_PROJECT_ID.svc.id.goog[$NAMESPACE/$SA_NAME_PRIV]"

  gcloud iam service-accounts add-iam-policy-binding $SA_NAME_LIMITED@$GCP_PROJECT_ID.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:$GCP_PROJECT_ID.svc.id.goog[$NAMESPACE/$SA_NAME_LIMITED]"

  # Link KSA to GSA
  kubectl annotate serviceaccount $SA_NAME_PRIV \
    --namespace $NAMESPACE \
    iam.gke.io/gcp-service-account=$SA_NAME_PRIV@$GCP_PROJECT_ID.iam.gserviceaccount.com

  kubectl annotate serviceaccount $SA_NAME_LIMITED \
    --namespace $NAMESPACE \
    iam.gke.io/gcp-service-account=$SA_NAME_LIMITED@$GCP_PROJECT_ID.iam.gserviceaccount.com

  kubectl apply -f $SCRIPT_DIR/../wli-k8s2gsa-manifests.yaml
}

enable_apis() {
  gcloud services enable networksecurity.googleapis.com
  gcloud services enable certificatemanager.googleapis.com
  gcloud services enable networkservices.googleapis.com
}

cleanup() {
  rm $RENDERED/*

  set +eou

  echo Deleting resources and disabling the APIs
  gcloud certificate-manager certificates delete $cert_name --location=$GCP_REGION -q
  gcloud network-services gateways delete swp --location=$GCP_REGION -q
  gcloud network-security gateway-security-policies delete $policy_name --location=$GCP_REGION -q
  gcloud iam service-accounts delete $gsa_email_priv --project=$GCP_PROJECT -q
  gcloud iam service-accounts delete $gsa_email_limited --project=$GCP_PROJECT -q

  sleep 250
  gcloud services disable --force networksecurity.googleapis.com
  gcloud services disable --force networkservices.googleapis.com
  gcloud services disable --force certificatemanager.googleapis.com
}

main "$@"


# ---------------- VPC and Subnets
# proxy_subnet_name="${vpc_name}-proxy-only-subnet"
# gcloud compute networks create $vpc_name --subnet-mode=custom
# gcloud compute networks subnets create $subnet_name --range=$primary_range --network=$vpc_name --region=$GCP_REGION
# gcloud compute networks subnets create $proxy_subnet_name --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE --region=$GCP_REGION --network=$vpc_name --range=$proxy_range

