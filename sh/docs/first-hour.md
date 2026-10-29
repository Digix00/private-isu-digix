# 競技開始後の最初の1時間

競技開始直後に行う確認・初期ベンチ・計測導入の手順です。コマンドは `sh/` を基準に書いています。
**最初に当日のマニュアルとレギュレーションを読みます。** この手順よりマニュアルが優先です。

## 0〜10 分: マニュアルと接続

- [ ] マニュアル・レギュレーションを読み、`docs/environment-template.md` の「0. 前提の確認」を埋める（禁止事項・再起動試験・ベンチの実行方法）
- [ ] `~/.ssh/config` に各サーバーを書き、つながることを確認する
  ```bash
  ssh isu1 true && ssh isu2 true && ssh isu3 true
  ```
- [ ] チャットで役割を決める（例: A=アプリ、B=インフラ・計測、C=DB）。**「ベンチを回す人」と「デプロイする人」は声をかけ合う**

## 10〜20 分: 構成の把握

```bash
cp config/isucon.conf.example config/isucon.conf
$EDITOR config/isucon.conf                 # まず ISU_HOSTS と ISU_ROLES（分からなければ全部 "app nginx mysql"）
scripts/inspect.sh                         # 全文は results/inspect/<host>-<時刻>.txt
scripts/setup-tools.sh check
```

- [ ] `inspect.sh` の結果から、サービス名・ポート・設定ファイル・ログの場所・アプリのバイナリを `docs/environment.md` に記録する
- [ ] `config/isucon.conf` の残りの `__TODO__` を埋める（サービス名・ポート・`ISU_APP_SRC_DIR`・`ISU_APP_REMOTE_BIN`・`ISU_APP_GOARCH`）
- [ ] `scripts/verify.sh` が通る

## 20〜30 分: 初期状態を残す

変更する前の状態を、必ず残します。

- [ ] 競技アプリのソースを Git に入れる（サーバーから取得してコミット。初期状態のコミットを記録する）
- [ ] nginx・MySQL の今の設定を手元に取り込む（docs/operations.md の「nginx 設定の配布」）
- [ ] **初期状態のベンチ**（計測ツールを入れる前。スコアを記録する）
  ```bash
  scripts/measure.sh start trial-000 --note "初期状態・計測設定なし"
  # ベンチを実行
  scripts/measure.sh stop trial-000
  scripts/measure.sh result trial-000 --pass true --score <スコア>
  ```
  計測設定を入れる前なので、`report.sh` は failed（ログなし）になることがあります。この回はスコアと設定のスナップショットを残すのが目的です。

## 30〜50 分: 計測の導入

```bash
scripts/setup-tools.sh install --remote --dry-run
scripts/setup-tools.sh install --remote
scripts/deploy/nginx.sh --dry-run && scripts/deploy/nginx.sh          # LTSV のアクセスログ
scripts/deploy/mysql.sh --apply-dynamic                               # スロークエリログ（再起動しない）
# pprof を使う場合: templates/go/pprof.go をアプリに入れ、ISU_PPROF=127.0.0.1:6060 で起動する設定にしてから
scripts/deploy/app.sh
scripts/verify.sh
```

- [ ] `ISU_API_GROUPS` に、アプリのルーティングで ID を含むパスを追加した（`/posts/123` のようなもの）

## 50〜60 分: 計測ありのベースライン

```bash
scripts/measure.sh start trial-001 --note "計測あり・コード変更なし"
# ベンチを実行（負荷走行中に必要なら: scripts/measure.sh profile trial-001）
scripts/measure.sh stop trial-001
scripts/measure.sh result trial-001 --pass true --score <スコア>
scripts/report.sh trial-001
cat results/trial-001/context.md
```

- [ ] `context.md` の「収集の不足・エラー」が「なし」になっている。足りない場合は、その項目を直してから取り直す
- [ ] 計測ありとなしのスコア差（trial-000 と trial-001）を記録した（計測のオーバーヘッドの目安）
- [ ] 上位の API・SQL から最初の改善候補を決め、`experiments/` にメモを作った（docs/agent-workflow.md）

以降は「1つ変更 → デプロイ → `measure.sh start <新しいID> --baseline <前のID>` → ベンチ → stop → result → report → compare」を繰り返します。
