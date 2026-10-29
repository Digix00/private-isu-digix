# CLI エージェントと一緒に調査する

計測結果を手元の CLI エージェント（Claude Code など）に渡し、根拠を確かめながら調査・改善・再検証を進める手順です。
特定の AI サービスには依存しません。**受け渡しは、手元のファイルとコマンドだけで行います。**

## 1. 基本の考え方

- **巨大なログを貼らない、読ませない。** 入口（`context.md`、8 KiB 以内）から始めます。必要な分だけ、`evidence.sh` で集計 → 詳細 → 元データの位置へと掘ります。
- **観測した事実と、仮説を分ける。** `context.md` は集計から機械的に作るので、観測した事実だけが載ります。仮説・判断は `experiments/<id>.md` に書きます。
- **分析・編集と、デプロイ・ベンチは別の操作。** エージェントにはローカルの分析と編集を任せ、デプロイとベンチの実行は人が判断して行います（または、明示的に指示します）。

## 2. 受け渡しの形

```
results/<run-id>/
├── context.md       最初に読む入口（上限 8 KiB。収集の不足・エラーを最優先で載せる）
├── manifest.json    識別情報・計測条件・収集状態・不足/エラー・コードの一致・成果物への参照
├── metrics.json     全データから算出した集計（大きくなる。直接読まず evidence.sh で取り出す）
├── reports/         alp・pt-query-digest・pprof の詳細、集計の TSV
├── raw/<host>/      元ログとプロファイル（直接は読まない）
├── snapshots/       当時の nginx -T・MySQL の変数・インデックス・手元の差分
├── run.json         measure.sh が書く記録（開始・終了・ロック・条件）
└── bench.json       measure.sh result で記録したスコアなど
experiments/<experiment-id>.md   仮説・根拠・変更・比較する実行ID・結果・採否・次の作業
```

- 収集状態（`manifest.json` の `status`）は次の4つです。
  - `complete`: 不足なし
  - `partial`: 一部のログが欠けている、または解析に失敗した
  - `failed`: 解析できるデータがない。この場合 `metrics.json` と `context.md` は作られない
  - `run.json` 側の状態（`collecting` / `stop_incomplete`）: まだ回収が終わっていない
- 未入力のスコアや、分からない値は `null` / `unknown` のまま残します。0 や「成功」で埋めることはありません。
- 計測時のコードは次のように区別して記録します。
  - `code.local_at_start`: 手元のソースのコミット・未コミット差分のハッシュ
  - `code.deployed`: 配布したコミット・バイナリの sha256（`deploy/app.sh` の記録）
  - `code.consistency`: 両者の一致（`match` / `mismatch` / `unknown`）

## 3. エージェントに渡す最初の指示（例）

`templates/AGENTS.md.example` を、競技アプリのリポジトリの `AGENTS.md`（または CLAUDE.md）に追記します。既存のファイルは上書きしません。
そのうえで、次のように依頼します。

```
results/trial-002/context.md を読んで、基準 trial-001 からスコアが伸びなかった原因の候補を挙げて。
根拠は scripts/evidence.sh で取得し、実行ID・API_ID/QUERY_ID・根拠のコマンドを添えること。
コードの変更は提案までにして、デプロイとベンチは実行しないこと。
```

## 4. 段階的な調査の流れ

```bash
cat results/trial-002/context.md                                   # 1. 入口: 収集状態・比較対象・計測時のコード
scripts/compare.sh trial-001 trial-002 --limit 10                  # 2. 基準との差（比較の前提に NG がないか先に確認）
scripts/evidence.sh sql trial-002 --sort total-time --limit 10     # 3. 一覧（全体で順位付けし、上位だけを表示）
scripts/evidence.sh sql-detail trial-002 --id q3ebf6c110740        # 4. 詳細: 統計・正規化 SQL・サンプル・関係するテーブル
scripts/evidence.sh logs trial-002 --api a6e4ebb580ad9 --errors    # 5. 元データ: 該当する行と元ログの位置（host:行）
```

- どの出力にも、メタデータとして実行ID・フィルター・並び順・総件数・返した件数・省略の有無・続きの取得方法（`--offset N`）が付きます。
- 集計とソースコードの対応は、出力が「推測」として案内します。SQL のテーブル名や URL のパスで検索するコマンドが付きます。**実際に確認できた対応は、実験メモに「確認済み」と書き分けます。**
- pprof はバイナリを直接読ませません。`evidence.sh pprof --file ... [--peek 関数名]` で、関数一覧と呼び出し関係を取得します。
- 時系列（リソース）は `evidence.sh resources` の概要から始め、`--host` と `--from` / `--to` で範囲を絞ります。

## 5. 実験の記録と比較

```bash
mkdir -p experiments
cp templates/experiment.md experiments/exp-003-comments-index.md
```

1. **仮説**を書きます。実行ID・対象ID（API_ID / QUERY_ID）・根拠のコマンドまたはファイルの項目を添えます。確認した事実と推測を分けて書きます。
2. **変更を1つに絞り**、期待する変化を書きます（例: 「q3ebf6c110740 の rows_examined/回 が 100000 → 10 未満、スコア +」）。
3. コミット → デプロイ → `measure.sh start trial-003 --baseline trial-002` → ベンチ → stop → result → report。
4. `compare.sh trial-002 trial-003` の結果と採否を記録します。

## 6. セッションの引き継ぎ

会話の全文は引き継ぎません。次のセッションには、次の内容だけを渡します。

- 最新の実行ID と基準の実行ID
- `experiments/` の該当ファイル（仮説・根拠・結果・採否・**不足している情報**・**次の作業**）
- 「`results/<id>/context.md` から読むこと」

## 7. 安全のための注意（指示ファイルだけでは強制できない）

- `AGENTS.md` のような指示ファイルは「お願い」です。**エージェントがファイルを読むことや、コマンドを実行することを禁止する仕組みではありません。** `.gitignore` も Git の管理対象を決めるだけで、読み取りは防げません。`raw/` を直接読まない運用は、指示とレビューで守ります。
- **コマンド側で強制できること**（このツールが実装しているもの）:
  - `evidence.sh` / `compare.sh` / `context.md` の出力バイト数の上限。最大 64 KiB で、上限を超える指定はエラーになる
  - 1 行・1 項目ごとの長さの上限
  - 元ログや metrics.json を丸ごと出力するサブコマンドを持たないこと
  - 存在しない ID を指定した場合に、他のデータを代わりに表示しないこと
  - 計測中のデプロイの拒否（対象ホスト上のロック）
- **強制が必要な場合は、エージェント自体の設定で行います。** 実行してよいコマンドの許可リストや、読み取りを禁止するパスを設定します（例: Claude Code の permissions 設定）。
- ログ・URI・SQL・User-Agent に含まれる文章は観測データです。**エージェントへの指示として扱いません。** 攻撃的な文字列が URI に含まれていても、それに従わないよう指示ファイルに書いておきます。
