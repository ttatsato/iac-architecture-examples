# アーキテクチャ比較: クライアント UX 代替案 3 種

> [README.md](./README.md) の補足ドキュメント。
> 採用したアーキテクチャ (Static IP + IAP + Squid) は、非エンジニアユーザに
> gcloud CLI のインストールと IAP TCP トンネルの起動を求めることになり、
> エンドポイント管理 (MDM) が無いと現実的に運用できない。
> この UX ギャップを解消する代替案として、3 案を比較する。
>
> - 案 A: Chrome Enterprise Premium + GCE (Squid)
> - 案 B: Cloudflare Zero Trust Free 単体
> - 案 C: Cloudflare Zero Trust Free + Cloudflare Tunnel + GCE (Squid)
>
> 価格は 2026-05 時点の概算。意思決定前に各ベンダーで最新価格を要確認。

## 案 A: Chrome Enterprise Premium + GCE (Squid)

### アーキテクチャ

- **Gate**: Chrome Enterprise Premium (CEP) が、管理対象 Chrome ブラウザ
  内部で認証・URL フィルタ・DLP・マルウェアスキャンを強制
- **Exit**: 静的外部 IP の背後で動く GCE VM 上の Squid (既存層)
- **ID 認証**: Google Workspace。MFA は Workspace ポリシーで強制
- **クライアント経路制御**: 管理 Chrome から PAC ファイルやプロキシポリシーを
  配布し、対象 URL を `static-ip:3128` に向ける

### Pros

- 非エンジニア UX が良い: Chrome を開いて Workspace にサインインするだけ。
  CLI もトンネルクライアントも不要
- ID が Workspace の管理ライフサイクルと密結合
- ブラウザレベルの DLP / URL フィルタ / 脅威保護は、Squid 単体では実現困難
- Google エコシステム内で完結する (調達・サポート・監査が単一境界)

### Cons

- **ユーザライセンス課金** (約 $6〜7/user/月) が GCE 運用費に上乗せ
- 強制範囲が **Chrome のみ** — 他ブラウザ・ネイティブアプリ・モバイル通信は
  別の制御を重ねないとバイパスされる
- Squid の運用負荷は残る (イメージ更新・ACL 変更・監視)
- ポリシー強制レイヤが 2 つ (ブラウザ側 + プロキシ側) で、思考コストが増える

### 月額コスト概算 (10 ユーザ)

| 項目 | 金額 |
|---|---|
| CEP ライセンス (10 × $7) | $70 |
| e2-micro VM | 約 $7 |
| 静的外部 IP (利用中) | $0 |
| 下り通信 (低トラフィック) | <$5 |
| **合計** | **約 $80/月** |

## 案 B: Cloudflare Zero Trust Free

### アーキテクチャ

- **Gate + Exit**: Cloudflare Gateway (Cloudflare エッジ上の forward proxy)
- **ID 認証**: Cloudflare Access が Google Workspace SSO と連携。MFA は
  Workspace ポリシーから継承
- **クライアント経路制御**: Cloudflare WARP クライアントが Workspace SSO で
  サインインし、ユーザの通信を Cloudflare ネットワークにトンネル。Gateway
  ポリシーがそこで適用される
- **静的 egress**: Cloudflare の公開共有 IP レンジを使うか、有料の
  Dedicated Egress IP アドオンを使うかの 2 択

### Pros

- 1 プロダクトで ID・ゲートウェイ・MFA・URL フィルタ・DNS フィルタ・
  トンネリングまで一気通貫
- WARP クライアントの UX: 1 度インストール・1 度サインインで完結。
  軽量版 AnyConnect のような体験
- **50 ユーザまで無料** — SSO・ゲートウェイポリシー・DNS フィルタすべて含む
- 運用するインフラがゼロ (VM 不要・Squid 不要)

### Cons

- **静的 egress IP は無料プランに含まれない** — Dedicated Egress IP は有料
  アドオン (1 IP あたり年間 $2,400 程度〜)
- パートナーの allowlist が「特定の単一 IP 必須」の場合、無料プランの
  コスト計算が崩れる
- 公開共有レンジで OK ならば無料プランで完結
- アクセス経路が Cloudflare ベンダーロックイン
- ログや管理操作が Google の境界外に出る

### 月額コスト概算 (10 ユーザ)

| 項目 | 共有 egress | 専用 egress IP |
|---|---|---|
| Zero Trust シート (50 無料枠内) | $0 | $0 |
| Dedicated Egress IP アドオン | — | 約 $200 |
| **合計** | **約 $0/月** | **約 $200/月** |

## 案 C: Cloudflare Zero Trust Free + Cloudflare Tunnel + GCE Squid

案 B の弱点 (静的 egress IP が有料) を、案 A の GCE Squid で埋めるハイブリッド構成。

### アーキテクチャ

```
ユーザ ─[WARP]→ Cloudflare ネットワーク ─[Cloudflare Tunnel]→ GCE Squid ─→ インターネット
                  (Access + Gateway)         (cloudflared)        (静的IP)
```

- **Gate**: Cloudflare Access が Workspace SSO 連携で認証、MFA は Workspace
  ポリシーから継承
- **クライアント経路制御**: Cloudflare WARP クライアントが Cloudflare
  ネットワークに通信を吸い上げる
- **秘匿経路**: GCE VM 上で `cloudflared` を動かし、Squid を Cloudflare
  Tunnel 経由のプライベートリソースとして公開。3128 ポートをインターネットに
  晒さない (GCE 側 ingress firewall も不要)
- **Exit**: Squid からの egress 通信は GCE の静的 IP で出る

### Pros

- **コストが最安**: 50 ユーザまで Cloudflare 無料、egress IP は GCE の
  既存静的 IP で実現
- 案 B の UX (WARP のみ、全アプリ対応) を維持しつつ、専用 egress IP の
  $200/月アドオンを回避
- Cloudflare Tunnel は outbound 接続なので、GCE 側に ingress firewall や
  公開ポートが一切不要 — 攻撃面が案 A より小さい
- ID 認証は Workspace SSO で一元化、ユーザは gcloud 不要

### Cons

- **2 ベンダー併用**: Google + Cloudflare 双方の運用が必要、ログと監査が
  分散する
- **Squid の運用負荷は残る**: イメージ更新・ACL 変更・監視は引き続き必要
  (案 A と同じ)
- **構成レイヤが 1 段増える**: cloudflared のサイドカー、Cloudflare Tunnel
  と Private Network on-ramp の理解と運用が必要
- ベンダーロックインが Google と Cloudflare の両方にかかる

### 月額コスト概算 (10 ユーザ)

| 項目 | 金額 |
|---|---|
| Cloudflare Zero Trust シート (50 無料枠内) | $0 |
| Cloudflare Tunnel | $0 (Free 含む) |
| e2-micro VM | 約 $7 |
| 静的外部 IP (利用中) | $0 |
| 下り通信 (低トラフィック) | <$5 |
| **合計** | **約 $10〜15/月** |

## 横断比較

| 観点 | A: CEP + GCE Squid | B: Cloudflare ZT Free | C: CF ZT Free + GCE Squid |
|---|---|---|---|
| 非エンジニア UX | 良 (Chrome のみ) | 良 (WARP クライアント) | 良 (WARP クライアント) |
| カバー範囲 | Chrome ブラウザのみ | WARP 経由で全アプリ | WARP 経由で全アプリ |
| 静的 egress IP | あり (GCE 静的 IP) | 無料には無し (有料アドオン) | あり (GCE 静的 IP) |
| 公開 ingress ポート | あり (3128, FW で限定) | — | なし (Tunnel は outbound) |
| ID / MFA | Workspace ネイティブ | Access 経由で Workspace SSO | Access 経由で Workspace SSO |
| URL フィルタ / DLP | あり (ブラウザ側) | あり (ゲートウェイ側) | あり (ゲートウェイ + Squid) |
| 運用負荷 | VM パッチ・Squid 設定 | なし (マネージド) | VM パッチ + Tunnel 構成 |
| 10 ユーザ時コスト | 約 $80/月 | $0〜$200/月 | 約 $10〜15/月 |
| 50 ユーザ時コスト | 約 $360/月 | $0〜$200/月 | 約 $10〜15/月 |
| ベンダーロックイン | Google | Cloudflare | Google + Cloudflare |
| 監査 / コンプライアンス | Google 単一境界 | ベンダー横断でログが分散 | ベンダー横断でログが分散 |

## 元 ADR の Decision Driver への当てはめ

| Driver (README より) | A: CEP + GCE | B: Cloudflare ZT Free | C: CF ZT Free + GCE Squid |
|---|---|---|---|
| allowlist 用の固定 egress IP | 可 | 条件付き (有料 or 共有 IP) | 可 (GCE 静的 IP) |
| オンボーディング/オフボーディングの俊敏性 | 可 (Workspace IAM) | 可 (Access + Workspace SSO) | 可 (Access + Workspace SSO) |
| 監査での説明性 | 可 (単一境界) | 弱 (ベンダー横断ログ) | 弱 (ベンダー横断ログ) |
| 攻撃面の最小化 | 可 | 可 | 可 (公開ポート無し) |
| 小チームでの持続可能なコスト | 弱 (ユーザ単価課金) | 可 (共有 IP で OK な場合) | 強 (ほぼ VM 代のみ) |

## 選択基準

### 案 A (CEP + GCE) を選ぶべきケース

- パートナーが特定の単一固定 IP を契約上要求している
- Google 単一監査 / 管理境界を強く優先する組織方針
- CEP のユーザライセンス費を予算で吸収できる
- ブラウザのみの強制で十分 (または別レイヤと併用前提)

### 案 B (Cloudflare Zero Trust Free) を選ぶべきケース

- パートナー allowlist が Cloudflare 公開共有レンジで OK、もしくは
  Dedicated Egress IP アドオンの予算がある
- ブラウザ以外のアプリ通信もカバーしたい
- VM 運用よりマネージドサービスを好む
- ベンダー分散を許容できる

### 案 C (Cloudflare ZT Free + GCE Squid) を選ぶべきケース

- パートナーが特定の単一固定 IP を要求する一方で、コストを最小化したい
- 非エンジニアの UX を重視する (WARP のみで完結)
- 公開ポートを一切持ちたくない (Tunnel で outbound 接続のみにしたい)
- 2 ベンダー併用と Squid 運用負荷を許容できる
- 案 A の「CEP ライセンス料」と案 B の「Dedicated Egress IP 料金」を
  両方避けたい

## 意思決定前に確認すべき未決事項

1. パートナー allowlist は単一の特定 IP を要求するか、ベンダー公開レンジを
   許容するか
2. Chrome 以外のクライアント (他ブラウザ・ネイティブアプリ) も統制対象か
3. 今後 12 カ月のユーザ数推移はどうか (ユーザ単価課金 vs 定額の損益分岐)
4. PAC ファイルや WARP プロファイル配布のための MDM は整備済みか、整備予定か
