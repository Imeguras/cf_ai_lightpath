# Thin on purpose: each target is the one command it stands for.
# Environments live in compose.yaml (profiles), not here.

# Terraform takes its inputs from .env, so each value is written down once.
-include .env
export TF_VAR_api_token = $(CLOUDFLARE_API_TOKEN)
export TF_VAR_account_id = $(CLOUDFLARE_ACCOUNT_ID)
export TF_VAR_jwt_secret = $(LIGHTPATH_JWT_SECRET)
export TF_VAR_secret_key_base = $(SECRET_KEY_BASE)
export TF_VAR_worker_url = $(LIGHTPATH_WORKER_URL)

WORKER_TF = deploy/terraform/worker

.PHONY: dev prod home down test bundle wrangler-config deploy azure

dev:
	docker compose --profile dev up --build --remove-orphans

prod:
	docker compose --profile prod up --build --detach --remove-orphans

# On the server, with lightpathd installed (deploy/arch).
home:
	docker compose --profile home up --build --detach --remove-orphans

down:
	docker compose --profile dev --profile prod --profile home down

test:
	cd probe && go test ./...
	cd lightpath && mix deps.get && mix test
	cd worker && node --import ./test/setup.ts --test 'test/*.test.ts'

# One ES module for Cloudflare; cloudflare:workers is provided by the runtime.
bundle:
	esbuild worker/src/index.ts --bundle --format=esm --platform=neutral --target=es2022 --external:cloudflare:workers --outfile=worker/dist/index.js

# Re-render worker/wrangler.jsonc from $(WORKER_TF)/worker.tf (local dev).
# Needs the bundle: Terraform hashes it even for this local-only target.
wrangler-config: bundle
	terraform -chdir=$(WORKER_TF) apply -target=local_file.wrangler_dev

deploy: bundle
	terraform -chdir=$(WORKER_TF) apply

# The public demo on Azure Container Apps (image from GHCR, see
# .github/workflows/image.yml).
azure:
	terraform -chdir=deploy/terraform/azure apply
