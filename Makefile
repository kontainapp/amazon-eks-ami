PACKER_BINARY ?= packer
PACKER_VARIABLES := aws_region ami_version ami_name binary_bucket_name binary_bucket_region kubernetes_version kubernetes_build_date kernel_version docker_version containerd_version runc_version cni_plugin_version source_ami_id source_ami_owners source_ami_filter_name arch instance_type security_group_id additional_yum_repos pull_cni_from_github sonobuoy_e2e_registry ami_regions

K8S_VERSION_PARTS := $(subst ., ,$(kubernetes_version))
K8S_VERSION_MINOR := $(word 1,${K8S_VERSION_PARTS}).$(word 2,${K8S_VERSION_PARTS})

aws_region ?= $(REGION)
binary_bucket_region ?= $(REGION)
ami_version ?= $(AMI_VERSION)

arch ?= x86_64
ifeq ($(arch), arm64)
instance_type ?= m6g.large
ami_name ?= kontain-eks-arm64-node-$(K8S_VERSION_MINOR)-${AMI_VERSION}
else
instance_type ?= m4.large
ami_name ?= kontain-eks-node-$(K8S_VERSION_MINOR)-${AMI_VERSION}
endif

ifeq ($(aws_region), cn-northwest-1)
source_ami_owners ?= 141808717104
endif

ifeq ($(aws_region), us-gov-west-1)
source_ami_owners ?= 045324592363
endif

T_RED := \e[0;31m
T_GREEN := \e[0;32m
T_YELLOW := \e[0;33m
T_RESET := \e[0m

.PHONY: all
all: 1.19 1.20 1.21 1.22

.PHONY: validate
validate:
	$(PACKER_BINARY) validate $(foreach packerVar,$(PACKER_VARIABLES), $(if $($(packerVar)),--var '$(packerVar)=$($(packerVar))',)) eks-worker-al2.json

.PHONY: k8s
k8s: validate
	@echo "$(T_GREEN)Building AMI for version $(T_YELLOW)$(kubernetes_version)$(T_GREEN) on $(T_YELLOW)$(arch)$(T_RESET)"
	if [ -n "$(AMI_GROUPS)" ]; then jq '.builders[].ami_groups[0]|= .+ "$(AMI_GROUPS)"' eks-worker-al2.json  > tmp.json; else cat eks-worker-al2.json  > tmp.json; fi
	$(PACKER_BINARY) build $(foreach packerVar,$(PACKER_VARIABLES), $(if $($(packerVar)),--var '$(packerVar)=$($(packerVar))',)) tmp.json

# Build dates and versions taken from https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html

.PHONY: 1.19
1.19:
	$(MAKE) k8s kubernetes_version=1.19.15 kubernetes_build_date=2021-11-10 pull_cni_from_github=true

.PHONY: 1.20
1.20:
	$(MAKE) k8s kubernetes_version=1.20.15 kubernetes_build_date=2022-06-20 pull_cni_from_github=true

.PHONY: 1.21
1.21:
	$(MAKE) k8s kubernetes_version=1.21.12 kubernetes_build_date=2022-05-20 pull_cni_from_github=true

.PHONY: 1.22
1.22:
	$(MAKE) k8s kubernetes_version=1.22.9 kubernetes_build_date=2022-06-03 pull_cni_from_github=true

test-1.22: 
	./scripts/make-cluster.sh --region=$(shell cat manifest-1.22.9.json | jq -r '.builds[-1].artifact_id' | cut -d':' -f1) --ami=$(shell cat manifest-1.22.9.json | jq -r '.builds[-1].artifact_id' | cut -d':' -f2)
	./test-cluster.sh
	./scripts/make-cluster.sh --region=$(shell cat manifest-1.22.9.json | jq -r '.builds[-1].artifact_id' | cut -d':' -f1) --cleanup
