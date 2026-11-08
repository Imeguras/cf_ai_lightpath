# The everyday API token (CLOUDFLARE_API_TOKEN in .env), as code.
# Permission group IDs are as exported from the dashboard ("Edit Cloudflare
# Workers" template plus Workers AI), plus Account Analytics Read and AI
# Gateway Write. Names from GET /user/tokens/permission_groups. Not yet
# trimmed to the minimum.

resource "cloudflare_api_token" "lightpath" {
  name = "Lightpath (Workers + Workers AI)"

  policies = [{
    effect = "allow"
    permission_groups = [
      { id = "cb142f7fbc3540f0bade0cbe75f606dc" }, # CF Agents Write
      { id = "bdbcd690c763475a985e8641dddc09f7" }, # Workers Containers Write
      { id = "82c075da3f4647a2a03becd0fe240f8a" }, # Workers Observability Write
      { id = "2e095cf436e2455fa62c9a9c2e18c478" }, # Workers CI Write
      { id = "bacc64e0f6c34fc0883a1223f938a104" }, # Workers AI Write
      { id = "a92d2450e05d4e7bb7d0a64968f83d11" }, # Workers AI Read
      { id = "8d28297797f24fb8a0c332fe0866ec89" }, # Pages Write
      { id = "bf7481a1826f439697cb59a20b22293e" }, # Workers R2 Storage Write
      { id = "05880cd1bdc24d8bae0be2136972816b" }, # Workers Tail Read
      { id = "f7f0eda5697f475c90846e879bab8666" }, # Workers KV Storage Write
      { id = "e086da7e2179491d91ee5f35b3ca210a" }, # Workers Scripts Write (also covers Durable Objects and Workflows)
      { id = "c1fde68c7bcc44588cbb6ddbc16d6480" }, # Account Settings Read
      { id = "b89a480218d04ceb98b4fe57ca29dc1f" }, # Account Analytics Read (neurons used today, GraphQL)
      { id = "6c8a3737f07f46369c1ea1f22138daaf" }, # AI Gateway Write (deploy/terraform/worker)
    ]
    resources = jsonencode({
      "com.cloudflare.api.account.*" = "*"
    })
    }, {
    effect = "allow"
    permission_groups = [
      { id = "3518d0f75557482e952c6762d3e64903" }, # Memberships Read
      { id = "8acbe5bb0d54464ab867149d7f7cf8ac" }, # User Details Read
    ]
    resources = jsonencode({
      "com.cloudflare.api.user.${var.user_id}" = "*"
    })
    }, {
    effect = "allow"
    permission_groups = [
      { id = "28f4b596e7d643029c524985477ae49a" }, # Workers Routes Write
    ]
    resources = jsonencode({
      "com.cloudflare.api.account.zone.*" = "*"
    })
  }]

  condition = {
    request_ip = {
      in = var.allowed_ips
    }
  }

  expires_on = var.token_expires_on
}

# The token's value is only shown once and is stored in the state file, which
# is why terraform.tfstate is gitignored and must stay on this machine.
#   terraform output -raw api_token
output "api_token" {
  value     = cloudflare_api_token.lightpath.value
  sensitive = true
}
