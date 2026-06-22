# =============================================================================
#  Makefile — operational shortcuts for the EKS-Terraform project
#  ---------------------------------------------------------------------------
#  Why a Makefile? Two reasons:
#    1. Eliminates "did I just apply prod tfvars to dev state?" mistakes -
#       each target wires the right env, tfvars, and backend config together.
#    2. Self-documenting: `make help` lists everything available.
#
#  Conventions:
#    - All commands honour `ENV=dev|production`. Defaults to dev for safety.
#    - Destructive targets prompt for confirmation.
#    - `make plan` writes a plan binary; `make apply` consumes it (so what you
#       saw is what you apply, no hidden re-plan).
# =============================================================================

ENV          ?= dev
ENV_DIR      := environments/$(ENV)
TFVARS       := $(ENV).tfvars
ifeq ($(ENV),production)
TFVARS       := production.tfvars
endif
PLAN         := $(ENV).tfplan
TF           := terraform
AWS_REGION   ?= ap-south-1

# Style colours (skipped on non-tty)
GREEN  := $(shell tput -Txterm setaf 2 2>/dev/null)
YELLOW := $(shell tput -Txterm setaf 3 2>/dev/null)
RED    := $(shell tput -Txterm setaf 1 2>/dev/null)
RESET  := $(shell tput -Txterm sgr0 2>/dev/null)

.PHONY: help
help: ## Show this help.
	@echo ""
	@echo "$(GREEN)EKS-Terraform — operational shortcuts$(RESET)"
	@echo ""
	@echo "Pick the env with ENV=dev (default) or ENV=production"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Common flows:$(RESET)"
	@echo "  make plan-dev              # safe to run any time"
	@echo "  make apply-dev             # apply the plan you just reviewed"
	@echo "  make kubeconfig-dev        # update local kubectl"
	@echo "  make destroy-dev           # tear down dev (with confirmation)"
	@echo "  make output-dev            # show all environment outputs"
	@echo "  make summary-dev           # show only the cluster_summary value"
	@echo "  ENV=production make plan   # run plan against production"
	@echo ""

# =============================================================================
#  Bootstrap
# =============================================================================

.PHONY: bootstrap
bootstrap: ## Provision the S3 state bucket. Run ONCE per AWS account.
	@echo "$(YELLOW)Bootstrap is one-time per AWS account. Continue? (y/N)$(RESET)"
	@read ans; [ "$$ans" = "y" ] || (echo "aborted"; exit 1)
	cd bootstrap && $(TF) init && $(TF) apply

# =============================================================================
#  Standard environment workflow
# =============================================================================

.PHONY: init
init: ## Initialise this env's backend + providers.
	cd $(ENV_DIR) && $(TF) init -backend-config=backend.hcl

.PHONY: plan
plan: ## Plan changes for $(ENV) and write $(PLAN).
	cd $(ENV_DIR) && $(TF) plan -var-file=$(TFVARS) -out=$(PLAN)

.PHONY: apply
apply: ## Apply the saved plan from `make plan`.
	cd $(ENV_DIR) && $(TF) apply $(PLAN)

.PHONY: apply-auto
apply-auto: ## Plan + apply in one shot (skips review). Use only in CI.
	cd $(ENV_DIR) && $(TF) apply -var-file=$(TFVARS) -auto-approve

.PHONY: destroy
destroy: ## Tear down the environment. PROMPTS FOR CONFIRMATION.
	@echo "$(RED)About to destroy environment '$(ENV)'.$(RESET)"
	@echo "Type the environment name to confirm:"
	@read ans; [ "$$ans" = "$(ENV)" ] || (echo "$(RED)mismatch — aborted$(RESET)"; exit 1)
	cd $(ENV_DIR) && $(TF) destroy -var-file=$(TFVARS)

.PHONY: validate
validate: ## terraform validate this env.
	cd $(ENV_DIR) && $(TF) validate

.PHONY: fmt
fmt: ## Format every .tf file in the repo.
	$(TF) fmt -recursive

.PHONY: fmt-check
fmt-check: ## Check formatting (CI uses this).
	$(TF) fmt -check -recursive -diff

.PHONY: output
output: ## Show all outputs for $(ENV).
	cd $(ENV_DIR) && $(TF) output

.PHONY: summary
summary: ## Show the cluster_summary output for $(ENV) (operator cheatsheet).
	cd $(ENV_DIR) && $(TF) output -json cluster_summary 2>/dev/null | python3 -m json.tool || echo "cluster_summary not available - is the cluster applied?"

# =============================================================================
#  EKS access
# =============================================================================

.PHONY: kubeconfig
kubeconfig: ## Populate kubeconfig for $(ENV)'s EKS cluster.
	@cluster=$$(cd $(ENV_DIR) && $(TF) output -raw eks_cluster_name 2>/dev/null); \
	if [ -z "$$cluster" ]; then \
		echo "$(RED)No EKS cluster in $(ENV) - is enable_eks=true and applied?$(RESET)"; exit 1; \
	fi; \
	aws eks update-kubeconfig --region $(AWS_REGION) --name $$cluster

.PHONY: bastion-ssm
bastion-ssm: ## SSM session into $(ENV)'s bastion.
	@id=$$(cd $(ENV_DIR) && $(TF) output -raw bastion_instance_id 2>/dev/null); \
	if [ -z "$$id" ]; then \
		echo "$(RED)No bastion in $(ENV) - is enable_bastion=true and applied?$(RESET)"; exit 1; \
	fi; \
	aws ssm start-session --target $$id

# =============================================================================
#  Per-env shortcuts (so you don't have to type ENV= every time)
# =============================================================================

.PHONY: init-dev plan-dev apply-dev destroy-dev output-dev summary-dev kubeconfig-dev bastion-ssm-dev
init-dev: ## Init dev.
	$(MAKE) init ENV=dev
plan-dev: ## Plan dev.
	$(MAKE) plan ENV=dev
apply-dev: ## Apply dev plan.
	$(MAKE) apply ENV=dev
destroy-dev: ## Destroy dev (with confirmation).
	$(MAKE) destroy ENV=dev
output-dev: ## Show dev outputs.
	$(MAKE) output ENV=dev
summary-dev: ## Show dev cluster_summary.
	$(MAKE) summary ENV=dev
kubeconfig-dev: ## kubectl -> dev cluster.
	$(MAKE) kubeconfig ENV=dev
bastion-ssm-dev: ## SSM into dev bastion.
	$(MAKE) bastion-ssm ENV=dev

.PHONY: init-prod plan-prod apply-prod destroy-prod output-prod summary-prod kubeconfig-prod bastion-ssm-prod
init-prod: ## Init production.
	$(MAKE) init ENV=production
plan-prod: ## Plan production.
	$(MAKE) plan ENV=production
apply-prod: ## Apply production plan.
	$(MAKE) apply ENV=production
destroy-prod: ## Destroy production (with confirmation).
	$(MAKE) destroy ENV=production
output-prod: ## Show production outputs.
	$(MAKE) output ENV=production
summary-prod: ## Show production cluster_summary.
	$(MAKE) summary ENV=production
kubeconfig-prod: ## kubectl -> production cluster (run from bastion!).
	$(MAKE) kubeconfig ENV=production
bastion-ssm-prod: ## SSM into production bastion.
	$(MAKE) bastion-ssm ENV=production

# =============================================================================
#  Maintenance helpers
# =============================================================================

.PHONY: state-list state-unlock
state-list: ## List every resource in this env's state.
	cd $(ENV_DIR) && $(TF) state list

state-unlock: ## Force-unlock a stuck state lock. Pass LOCK_ID=<id>.
	@if [ -z "$(LOCK_ID)" ]; then echo "$(RED)Usage: make state-unlock LOCK_ID=<id>$(RESET)"; exit 1; fi
	cd $(ENV_DIR) && $(TF) force-unlock $(LOCK_ID)

.PHONY: clean
clean: ## Remove local plan files and .terraform caches.
	find . -name '*.tfplan' -delete
	find . -name '.terraform' -type d -prune -exec rm -rf {} +
	find . -name '.terraform.lock.hcl' -delete
