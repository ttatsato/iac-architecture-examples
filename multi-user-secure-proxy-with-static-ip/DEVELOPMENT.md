# Stack

- GCE (Ubuntu 22.04 + Docker + nginx) — reverse proxy backend (外部 IP なし)
- Cloud NAT — egress を static IP に固定
- L7 HTTPS Load Balancer + IAP — 認証ゲート (Google SSO + MFA + IAM)
- Google-managed SSL Certificate
- Static IP — ベンダー allowlist 登録用の egress IP (Cloud NAT 経由)
- IAP TCP tunnel — SSH 専用経路 (運用者向け)
- Terraform

# Architecture overview

```
オペレータ Chrome
    ↓ https://${gateway_host}
[GCP L7 HTTPS LB] ── [Google-managed SSL] ── [IAP] ── 認証 (Workspace SSO + MFA + IAM)
    ↓ HTTP 8080 (LB ヘルスチェック範囲のみ FW 許可)
[GCE VM: nginx (reverse proxy)]   ← 外部 IP なし。世界からポートスキャンされない。
    ↓ Cloud NAT
    ↓ static IP egress
[eKYC ベンダー管理画面]

[運用者] ─[gcloud compute ssh --tunnel-through-iap]→ [IAP TCP tunnel] → VM:22
```

# 一回だけの手動セットアップ (GCP Console)

Terraform を回す前に、IAP の OAuth consent screen を一度だけ Console で構成する必要があります。

1. GCP Console > **APIs & Services** > **OAuth consent screen**
   - User type: `Internal` (Workspace 所属者のみ許可するなら推奨)
   - App name, support email を入力して保存
2. **APIs & Services** > **Credentials** > **Create credentials** > **OAuth client ID**
   - Application type: `Web application`
   - Authorized redirect URIs:
     `https://iap.googleapis.com/v1/oauth/clientIds/<auto>:handleRedirect`
     ※ 仮の URI で作成し、後ほど IAP が払い出す client ID を確認して上書きする運用でも可
3. 作成された **Client ID** と **Client secret** を控える (`terraform.tfvars` に入れる)

# Get started

## 1. Prepare env

```sh
touch .env
```

`.env` 例:

```sh
GOOGLE_PROJECT=your-gcp-project-id
GOOGLE_REGION=asia-northeast1
GOOGLE_ZONE=asia-northeast1-a
```

## 2. Prepare terraform.tfvars

`terraform.tfvars` を作成 (parent `.gitignore` で `*.tfvars` 済み):

```hcl
vendor_host  = "admin.ekyc-vendor.com"
gateway_host = "ekyc-gw.our-org.com"

iap_members = [
  "user:alice@our-org.com",
  "user:bob@our-org.com",
  # "group:ekyc-operators@our-org.com",  # Workspace グループも可
]

# IAP TCP tunnel (SSH) を使う運用者。空なら誰も SSH できない。
iap_tunnel_members = [
  "user:ops@our-org.com",
]

iap_oauth_client_id     = "xxxxxxxxxx.apps.googleusercontent.com"
iap_oauth_client_secret = "GOCSPX-..."
```

## 3. Apply

```sh
terraform init

set -a
source .env
set +a
terraform plan -out=tfplan
terraform apply tfplan
```

apply 後、output に以下が表示される:

- `lb_ip_address` — ゲートウェイ公開 IP (DNS A レコードを `gateway_host` に向ける)
- `egress_static_ip` — eKYC ベンダーに登録する固定 IP

## 4. DNS 設定

`gateway_host` (例: `ekyc-gw.our-org.com`) の A レコードを `lb_ip_address` に向ける。
DNS 伝播後、Google-managed SSL cert が自動でプロビジョニングされる (10〜30 分かかることがある)。

## 5. ベンダーへ static IP を申請

`egress_static_ip` をベンダーの IP allowlist に追加申請する。

## 6. 設定変更後の VM 反映

`nginx.conf.tmpl` を変更しても、`metadata_startup_script` の更新だけでは
既存 VM 上の nginx コンテナに反映されない (startup script は初回ブート時のみ)。
反映するには VM だけ作り直す:

```sh
terraform apply -replace=google_compute_instance.proxy
```

> static IP / LB / 証明書は別リソースなので、VM 再作成中もそれらは維持される。

# 動作確認

## Cloud リソース

```sh
terraform state list

source .env && gcloud config set project "$GOOGLE_PROJECT"

gcloud compute instances list --filter="name=proxy-server"
gcloud compute addresses list --filter="name=proxy-egress-ip"
gcloud compute backend-services describe reverse-proxy-backend --global \
  --format="get(iap.enabled)"   # true なら OK
```

## SSL cert プロビジョニング状況

```sh
gcloud compute ssl-certificates describe reverse-proxy-cert --global \
  --format="get(managed.status,managed.domainStatus)"
# managed.status が ACTIVE になれば HTTPS で叩ける
```

## ブラウザ動作確認

1. `https://${gateway_host}` を Chrome で開く
2. Google ログインにリダイレクトされる
3. Workspace 認証 + MFA を通る
4. ベンダーの管理画面 UI が表示される

## 認証バイパス試行 (期待: 全部失敗する)

```sh
# IAP を通らずに直接叩く (期待: 302 Google ログイン or 403)
curl -sI "https://${gateway_host}/" | head -1

# VM に直接届くパスは無い (VM は外部 IP を持たない)。
# egress_static_ip は Cloud NAT の出口 IP なので ingress 不可:
curl -m 5 "http://${egress_static_ip}:8080/" || echo "no route (expected)"
```

## nginx ログ

VM は外部 IP を持たないので、SSH は IAP TCP tunnel 経由で行う:

```sh
gcloud compute ssh proxy-server --zone=asia-northeast1-a --tunnel-through-iap \
  --command="sudo docker logs reverse-proxy --tail=50"
```

> `--tunnel-through-iap` を付けるには、利用者が `var.iap_tunnel_members` に
> 入っている必要がある。

## IAP 監査ログ

GCP Console > **Logging** で:

```
resource.type="iap_web"
```

でフィルタすると、認証成功/失敗が時系列で見える。

# トラブルシュート

| 症状 | 確認ポイント |
|---|---|
| Chrome で開いても Google ログインに飛ばない | LB が IAP enabled か (`gcloud compute backend-services describe ...`) |
| 認証後に「You don't have access」 | IAP IAM に `roles/iap.httpsResourceAccessor` が付いているか (`var.iap_members`) |
| 502 Bad Gateway | VM 上で `docker ps` / `docker logs reverse-proxy` を確認、`/healthz` が 200 か |
| ベンダー UI のリダイレクトで `gateway_host` ではなくベンダードメインに飛ぶ | nginx の `proxy_redirect` を追加調整 |
| ベンダー UI の Cookie が効かず毎回ログアウトする | nginx の `proxy_cookie_domain` を追加調整 |
| ベンダー UI が JS で hardcoded URL を叩いて 403 | `sub_filter` で書き換え、または対象 URL ごとに location ブロック追加 |
