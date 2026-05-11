# Troubleshooting — 疎通確認とWARP/Tunnel設定

`terraform apply` でGCP側が立ち上がった後、Mac → WARP → Cloudflare Tunnel → VM(Squid) → 静的IP の経路を通すまでに詰まりがちなポイントとその切り分け手順。

経路イメージ:

```
[Mac (WARP有効)] → Cloudflare WARP → Cloudflare Tunnel → [GCP VM <vm_internal_ip>:3128 Squid] → 静的IP → 外部
```

`<vm_internal_ip>` と `<static_egress_ip>` は以下で取得:

```bash
terraform output vm_internal_ip
terraform output static_egress_ip
```

---

## 切り分けフロー

Macのターミナルで上から順に実行し、最初に失敗するステップから対処する。

### 1. WARP がZero Trust組織に接続しているか

```bash
warp-cli status
```

期待値: `Status update: Connected` / `Network: healthy`

失敗時の対処: WARPクライアントで Zero Trust の組織にエンロール。Cloudflareダッシュボード → Settings → WARP Client → Device enrollment permissions で組織のenrollment policyを許可してから、WARPアプリで `Login with Cloudflare Zero Trust` → 組織名を入力。

### 2. Mac → VM:3128 のTCP疎通

```bash
nc -vz <vm_internal_ip> 3128
```

期待値: `Connection to <vm_internal_ip> port 3128 [tcp/*] succeeded!`

タイムアウトする場合の原因と対処は [WARP Split Tunnelの罠](#warp-split-tunnelの罠) と [Cloudflare TunnelのPrivate Network設定](#cloudflare-tunnelのprivate-network設定) を参照。

### 3. プロキシ経由で外部HTTPSリクエスト

```bash
curl -x http://<vm_internal_ip>:3128 -v https://allowed-ip-check.vercel.app 2>&1 | head -40
```

期待値:
- `HTTP/1.1 200 Connection established`（SquidのCONNECTレスポンス）
- 続いて 200 OK でHTMLが返る
- レスポンス本文の IP が `<static_egress_ip>` の値と一致

`HTTP/1.1 403 Forbidden` がSquidから返る場合: アクセス先ドメインが `vendor_primary_domains` / `vendor_asset_domains` の ACL に入っていない。tfvarsで追加して `terraform apply` 。VM再作成（`-replace`）は不要、startup-scriptが次回起動時に新しい`squid.conf`を書き込む（ただし即時反映には `docker restart squid` 必要）。

### 切り分け早見表

| 詰まる場所 | 原因 |
|---|---|
| 1 で Disconnected | WARPが組織にエンロールできていない |
| 2 でタイムアウト | (a) WARP Split Tunnelで `10.0.0.0/8` が除外、または (b) Cloudflare Tunnel に Private Network `10.10.0.0/24` 未登録 |
| 2 OKで 3 が 403 | Squid のACLでドメイン未許可 |
| 3 で接続自体OKだがブラウザで失敗 | Mac System Proxy 設定が残存・Firefox側プロファイル混在など |

---

## WARP Split Tunnelの罠

WARPはデフォルトで RFC1918 のプライベートIP（`10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16`）を **除外** している。「除外＝WARPを通さない＝Macのローカル経路で出ようとする」ので、`10.10.0.6` 宛のパケットがどこにもルートを持たず timeout する。

### 対処

Cloudflare Zero Trust ダッシュボード:

1. **Settings → WARP Client → Profile settings** → 使っているプロファイル（多くの場合 `Default`）
2. **Split Tunnels** セクションを開く（モードは **Exclude IPs**）
3. **`10.0.0.0/8` の行を削除**

その後 Mac の WARP クライアントを **Disconnect → Connect** で再接続して再度 `nc -vz <vm_internal_ip> 3128` を確認。

### 副作用に注意

`10.0.0.0/8` を全部 WARP に流すと、手元のローカルLANが10.x.x.xを使っている場合（社内NAS等）にそちらが見えなくなる。確認:

```bash
ifconfig | grep 'inet 10\.'
netstat -nr | grep '^10\.'
```

ローカルで10.xを使っているなら、`10.0.0.0/8` を消す代わりに細分化したレンジ（例: `10.0.0.0/9`, `10.128.0.0/10` など、`10.10.0.0/24` を含まない形）を除外リストに足す。

---

## Cloudflare TunnelのPrivate Network設定

WARPからVPC内IPを引けるようにするための必須設定。

Zero Trust ダッシュボード:

1. **Networks → Tunnels** → 該当 Tunnel
2. **Configure → Private Network** タブ
3. **Add a private network** で `10.10.0.0/24` を登録（`terraform output vpc_cidr` の値）

---

## Firefox（業務専用）の プロキシ設定

普段使いのFirefoxにproxyを刺さないために、別プロファイルを切る。

```bash
# プロファイルマネージャを開く
open -a Firefox --args -ProfileManager
```

「Create Profile...」で `vendor-proxy` などの名前を付けて作成 → 起動。

そのプロファイルで:

1. アドレスバーに `about:preferences` を入力
2. ページ最下部 **Network Settings → Settings...**
3. **Manual proxy configuration** を選択
4. 入力:
   - **HTTP Proxy**: `<vm_internal_ip>` / **Port**: `3128`
   - **「Also use this proxy for HTTPS」** にチェック
   - **No Proxy for**: `localhost, 127.0.0.1`
5. **OK**

### macOSシステムproxyを使わない理由

System Settings → Network → Proxies でMac全体にproxyを設定すると、VS Code/Chrome/その他全アプリが `<vm_internal_ip>:3128` 経由になる。SquidはACLで `vendor_primary_domains` / `vendor_asset_domains` 以外を403で蹴るので、拡張機能ストアやGitHub等が全部失敗し、`Extension process ネットワーク exited` のようなエラーになる。**Firefox 専用プロファイルで隔離するのが安全**。

---

## VM側ログの確認

WARPからVMへの疎通自体は通っているが proxy 経由のリクエストが何か変、というときはVM側ログを見る。

IAP SSHを有効化（`-var="enable_iap_ssh=true"` で `terraform apply`）してから:

```bash
gcloud compute ssh cf-proxy-vm --zone=asia-northeast1-a --tunnel-through-iap
```

VM上で:

```bash
# startup-script の完走状況
sudo journalctl -u google-startup-scripts.service --no-pager | tail -100

# コンテナの状態
sudo docker ps

# cloudflared が edge と接続しているか
sudo docker logs cloudflared --tail 50
# 期待: "Registered tunnel connection" が4本

# Squid の起動状態とアクセスログ
sudo docker logs squid --tail 30
sudo docker exec squid tail -f /var/log/squid/access.log
```

調査終わったら IAP SSH ルールを閉じる:

```bash
terraform apply -var="enable_iap_ssh=false"
```

---

## トークン取得・検証（Secret Manager）

Cloudflare Tunnel トークンが「無効」と cloudflared に弾かれる場合、Secret Manager に保存された値そのものを検証する。VM上 または Cloud Shell で:

```bash
# 1) GCPアクセストークン取得
ACCESS_TOKEN=$(curl -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')

# 2) Secret Manager からトークン取り出し（プロジェクトIDは置き換える）
TOKEN_RAW=$(curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" https://secretmanager.googleapis.com/v1/projects/<project-id>/secrets/cf-proxy-tunnel-token/versions/latest:access | python3 -c 'import json,sys,base64;print(base64.b64decode(json.load(sys.stdin)["payload"]["data"]).decode(),end="")')

# 3) 長さ確認
echo "length=${#TOKEN_RAW}"

# 4) 末尾の改行・空白の混入確認
printf '%s' "$TOKEN_RAW" | tail -c 3 | od -c | head -1

# 5) base64デコードしてJSON構造を確認
printf '%s' "$TOKEN_RAW" | base64 -d 2>/dev/null | python3 -c 'import json,sys;j=json.load(sys.stdin);print("keys:",sorted(j.keys()))' || echo "decode failed"
```

判定:

- `length` が **36** → これはUUIDの長さ。`.env` / tfvars に **Tunnel ID（UUID）を貼ってしまっている**。本物のトークンは base64-encoded JSON で 200〜300+ 文字。
- `length` が **200前後**で `keys: ['a', 's', 't']` が出る → Secret Manager側は正常。値そのものが Cloudflare 側で無効（古い／別Tunnel／削除済み）の可能性。トークンを再取得（下記）。
- `decode failed` → Secret Manager から取り出す段階で壊れている。`.env` の値の前後に空白/改行が混入、`--token ` プレフィックスを含めて貼ってしまった等。

### 正しいトークンの取り方

Cloudflare Zero Trust ダッシュボード:

1. **Networks → Tunnels** → 該当 Tunnel → **Configure**
2. 上部タブ **Install and run a connector**
3. Docker タブのコマンド例から、**`--token` の後ろの長い base64 文字列だけ**（先頭 `eyJh` で始まる、200文字以上）をコピー
4. `.env` の `TF_VAR_cloudflare_tunnel_token=...` または tfvars に貼り直し
   - `--token` フラグや前後の空白・改行は含めない
5. `terraform apply -replace=google_compute_instance.vm` で Secret 更新＋VM作り直し（再起動だけだと既存コンテナがループしたままなので置き換えが速い）

---

## よくある落とし穴まとめ

| 症状 | 原因 | 対処 |
|---|---|---|
| `nc -vz` がタイムアウト | WARP Split Tunnelで `10.0.0.0/8` 除外 | 除外から削除 |
| `nc -vz` がタイムアウト | Tunnel の Private Network 未登録 | `10.10.0.0/24` を追加 |
| cloudflared が `Provided Tunnel token is not valid` ループ | tfvars に Tunnel ID（UUID）を貼ってしまった | 正しいトークン（base64 200+文字）を取り直し |
| squid が `Cannot open '/dev/stdout'` で即落ち | `proxy` 非特権ユーザがコンテナstdoutを再オープンできない | `squid.conf` のログを `/var/log/squid/*.log` に書く |
| startup-script が `base64: invalid input` で失敗 | sed が pretty-printed JSON を行単位処理して壊す | python3 で JSON パースに変更 |
| VS Code等が「Extension process exited」 | macOSシステムproxy設定でSquid経由になりACL拒否 | システムproxy解除、Firefox専用プロファイルに切替 |
| GCE作成時 `does not have enough resources` | ゾーンのキャパ不足 | `-var="zone=asia-northeast1-b"` 等で別ゾーン |
