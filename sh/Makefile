# よく使う操作のメニュー。中身は scripts/ のスクリプトをそのまま呼ぶだけ（細かい指定はスクリプトを直接使う）。
#   make help
#   make start RUN=trial-002 BASE=trial-001 NOTE="index 追加"
# 値に空白を含む場合は "..." で囲む。値にダブルクォートは使わない。

RUN  ?=
BASE ?=
NOTE ?=
HOST ?=
SCORE ?=
PASS ?= true
DRY ?=

host_opt = $(if $(HOST),--host $(HOST))
dry_opt  = $(if $(DRY),--dry-run)
need_run = @test -n "$(RUN)" || { echo "RUN=<実行ID> を指定してください" >&2; exit 2; }

.PHONY: help check inspect verify tools deploy-app deploy-nginx deploy-mysql start profile stop result report summary compare lock

help: ## このメニュー
	@awk -F':.*## ' '/^[a-z-]+:.*## / { printf "  make %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

check: ## 手元とサーバーのツール確認
	scripts/setup-tools.sh check
inspect: ## サーバー構成の調査（読み取りのみ）  [HOST=]
	scripts/inspect.sh $(host_opt)
verify: ## サービス・ポート・HTTP の確認  [HOST=]
	scripts/verify.sh $(host_opt)
tools: ## サーバーにツールを導入  [DRY=1]
	scripts/setup-tools.sh install --remote $(dry_opt)

deploy-app: ## アプリをビルドして配布  [HOST=] [DRY=1]
	scripts/deploy/app.sh $(host_opt) $(dry_opt)
deploy-nginx: ## nginx 設定を配布  [HOST=] [DRY=1]
	scripts/deploy/nginx.sh $(host_opt) $(dry_opt)
deploy-mysql: ## MySQL 設定を配布して動的に反映  [HOST=] [DRY=1]
	scripts/deploy/mysql.sh --apply-dynamic $(host_opt) $(dry_opt)

start: ## 計測開始  RUN= [BASE=] [NOTE=]
	$(need_run)
	scripts/measure.sh start "$(RUN)" $(if $(BASE),--baseline "$(BASE)") $(if $(NOTE),--note "$(NOTE)")
profile: ## CPU プロファイル取得（計測中）  RUN=
	$(need_run)
	scripts/measure.sh profile "$(RUN)"
stop: ## 計測終了・回収  RUN=
	$(need_run)
	scripts/measure.sh stop "$(RUN)"
result: ## ベンチ結果の記録  RUN= SCORE= [PASS=true]
	$(need_run)
	scripts/measure.sh result "$(RUN)" --pass "$(PASS)" $(if $(SCORE),--score "$(SCORE)")
report: ## 集計して context.md を作る  RUN=
	$(need_run)
	scripts/report.sh "$(RUN)"
summary: ## 実行の概要を表示  RUN=
	$(need_run)
	scripts/evidence.sh summary "$(RUN)"
compare: ## 基準と比較  BASE= RUN=
	$(need_run)
	@test -n "$(BASE)" || { echo "BASE=<基準の実行ID> を指定してください" >&2; exit 2; }
	scripts/compare.sh "$(BASE)" "$(RUN)"
lock: ## 対象ホストのロック状態
	scripts/lock.sh status
