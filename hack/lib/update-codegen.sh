#!/usr/bin/env bash

# Copyright 2020 the Pinniped contributors. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBE_VERSIONS=("$@")
BASE_PKG="go.pinniped.dev"
export GO111MODULE="on"

# If we're not running in a container, assume that we want to loop over and run each build
# in a container.
if [[ -z "${CONTAINED:-}" ]]; then
    for kubeVersion in "${KUBE_VERSIONS[@]}"; do
        # CODEGEN_IMAGE is the container image to use when running
        CODEGEN_IMAGE="docker.io/getpinniped/k8s-code-generator-$(echo "$kubeVersion" | cut -d"." -f1-2):latest"

        echo "generating code for ${kubeVersion} using ${CODEGEN_IMAGE}..."
        docker run --rm \
            --env CONTAINED=1 \
            --volume "${ROOT}:/work" \
            --workdir "/work" \
            "${CODEGEN_IMAGE}" \
            "/work/hack/lib/$(basename "${BASH_SOURCE[0]}")" \
            "${kubeVersion}" \
            | sed "s|^|${kubeVersion} > |"
    done
    exit 0
fi

# Now that we know we are running in the nested container, expect there to be only
# a single Kubernetes version
if [[ "${#KUBE_VERSIONS[@]}" -ne 1 ]]; then
    echo "when running in a container, we can only generate for a single kubernetes version" >&2
    exit 1
fi

# Link the root directory into GOPATH since that is where output ends up.
GOPATH_ROOT="${GOPATH}/src/${BASE_PKG}"
mkdir -p "$(dirname "${GOPATH_ROOT}")"
ln -s "${ROOT}" "${GOPATH_ROOT}"
ROOT="${GOPATH_ROOT}"
cd "${ROOT}"

# KUBE_VERSION is the full version (e.g., '1.19.0-rc.0').
KUBE_VERSION="${KUBE_VERSIONS[0]}"
export KUBE_VERSION

# KUBE_MINOR_VERSION is just the major/minor version (e.g., '1.19').
KUBE_MINOR_VERSION="$(echo "${KUBE_VERSION}" | cut -d"." -f1-2)"
export KUBE_MINOR_VERSION

# KUBE_MODULE_VERSION is just version of client libraries (e.g., 'v0.19.9-rc-0').
KUBE_MODULE_VERSION="v0.$(echo "${KUBE_VERSION}" | cut -d '.' -f 2-)"
export KUBE_MODULE_VERSION

# Start by picking an output directory and deleting any previously-generated code.
OUTPUT_DIR="${ROOT}/generated/${KUBE_MINOR_VERSION}"
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

echo "running in container to generate ${KUBE_VERSION} into ${OUTPUT_DIR}..."

# Next, copy in the base definitions of our APIs from ./apis into the generated directory, substituting some
# variables in the template files and renaming them to strip the `.tmpl` extension.
cp -R "${ROOT}/apis" "${OUTPUT_DIR}/apis"
find "${OUTPUT_DIR}" -type f -exec sed -i "s|GENERATED_PKG|generated/${KUBE_MINOR_VERSION}|g" {} \;
find "${OUTPUT_DIR}" -type f -not -name '*.tmpl' -exec rm {} \;
find "${OUTPUT_DIR}" -type f -name '*.tmpl' -exec bash -c 'mv "$0" "${0%.tmpl}"' {} \;

# Make the generated API code its own Go module.
echo "generating ${OUTPUT_DIR}/apis/go.mod..."
cat << EOF > "${OUTPUT_DIR}/apis/go.mod"
// This go.mod file is generated by ./hack/codegen.sh.
module ${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/apis

go 1.13

require (
    k8s.io/apimachinery ${KUBE_MODULE_VERSION}
    k8s.io/api ${KUBE_MODULE_VERSION}
)
EOF

# Make the generated client code its own Go module.
echo "generating ${OUTPUT_DIR}/client/go.mod..."
mkdir client
cat << EOF > "./client/go.mod"
// This go.mod file is generated by ./hack/codegen.sh.
module ${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/client

go 1.13

require (
    github.com/go-openapi/spec v0.19.9
    k8s.io/api ${KUBE_MODULE_VERSION}
    k8s.io/apimachinery ${KUBE_MODULE_VERSION}
    k8s.io/client-go ${KUBE_MODULE_VERSION}
    k8s.io/apimachinery ${KUBE_MODULE_VERSION}
)

replace ${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/apis => ../apis
EOF

# Generate API-related code for our public API groups
echo "generating API-related code for our public API groups..."
(cd apis &&
    bash "${GOPATH}/src/k8s.io/code-generator/generate-groups.sh" \
        deepcopy \
        "${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/apis" \
        "${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/apis" \
        "config:v1alpha1 idp:v1alpha1 login:v1alpha1" \
        --go-header-file "${ROOT}/hack/boilerplate.go.txt" 2>&1 | sed "s|^|gen-api > |"
)

# Generate API-related code for our internal API groups
echo "generating API-related code for our internal API groups..."
(cd apis &&
    bash "${GOPATH}/src/k8s.io/code-generator/generate-internal-groups.sh" \
        deepcopy,defaulter,conversion,openapi \
        "${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/client" \
        "${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/apis" \
        "${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/apis" \
        "config:v1alpha1 idp:v1alpha1 login:v1alpha1" \
        --go-header-file "${ROOT}/hack/boilerplate.go.txt"  2>&1 | sed "s|^|gen-int-api > |"
)

# Tidy up the .../apis module
echo "tidying ${OUTPUT_DIR}/apis/go.mod..."
(cd apis && go mod tidy 2>&1 | sed "s|^|go-mod-tidy > |")

# Generate client code for our public API groups
echo "generating client code for our public API groups..."
(cd client &&
    bash "${GOPATH}/src/k8s.io/code-generator/generate-groups.sh" \
        client,lister,informer \
        "${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/client" \
        "${BASE_PKG}/generated/${KUBE_MINOR_VERSION}/apis" \
        "config:v1alpha1 idp:v1alpha1 login:v1alpha1" \
        --go-header-file "${ROOT}/hack/boilerplate.go.txt"  2>&1 | sed "s|^|gen-client > |"
)

# Tidy up the .../client module
echo "tidying ${OUTPUT_DIR}/client/go.mod..."
(cd client && go mod tidy 2>&1 | sed "s|^|go-mod-tidy > |")

# Generate API documentation
sed "s|KUBE_MINOR_VERSION|${KUBE_MINOR_VERSION}|g" < "${ROOT}/hack/lib/docs/config.yaml" > /tmp/docs-config.yaml
crd-ref-docs \
    --source-path="${ROOT}/generated/${KUBE_MINOR_VERSION}/apis" \
    --config=/tmp/docs-config.yaml \
    --renderer=asciidoctor \
    --templates-dir="${ROOT}/hack/lib/docs/templates" \
    --output-path="${ROOT}/generated/${KUBE_MINOR_VERSION}/README.adoc"

# Generate CRD YAML
(cd apis &&
    controller-gen paths=./config/v1alpha1 crd:trivialVersions=true output:crd:artifacts:config=../crds &&
    controller-gen paths=./idp/v1alpha1 crd:trivialVersions=true output:crd:artifacts:config=../crds
)
