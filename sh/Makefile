# ISUCON の改善ループで何度も使う操作だけをまとめたメニュー。一覧: make help
# 1回しか使わない操作は docs/ にコマンドを書いている。実行前に中身を確認するには make -n <target>。
#
#   改善ループ:  make deploy → make pre → (ベンチ実行。必要なら make pprof) → make analyze → results/<run>/memo.md に記録

SHELL := /bin/bash
-include env.mk

SSH       := ssh -o BatchMode=yes
TS        := $(shell date +%m%d-%H%M%S)
ALL_HOSTS := $(sort $(APP_HOSTS) $(NGINX_HOST) $(DB_HOST))
# 実行名: make pre で決まり（.current-run に保存）、analyze / pprof は同じ名前を使う。RUN=... で指定も可能
RUN       ?= $(shell cat .current-run 2>/dev/null)
R         := results/$(RUN)

.PHONY: help config status deploy restart rollback fetch-conf deploy-nginx deploy-mysql slow-on slow-off pre pprof pprof-web analyze setup

help: ## この一覧
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  make %-13s %s\n", $$1, $$2 }'

config:
	@test -f env.mk || { echo "env.mk がありません: cp env.example.mk env.mk して当日の構成に合わせてください" >&2; exit 2; }

# ---- 確認 ------------------------------------------------------------------
status: config ## 各ホストのサービス状態（active/enabled）と HTTP 応答
	@for h in $(ALL_HOSTS); do \
	  echo "== $$h"; \
	  $(SSH) $$h 'for s in $(SERVICES); do printf "  %-12s %-9s %s\n" $$s "$$(systemctl is-active $$s)" "$$(systemctl is-enabled $$s 2>/dev/null)"; done; \
	    printf "  GET $(CHECK_URL) -> %s\n" "$$(curl -s -o /dev/null -m 5 -w "%{http_code}" $(CHECK_URL))"' || exit 1; \
	done

# ---- アプリ ----------------------------------------------------------------
deploy: config ## アプリを手元でビルドし APP_HOSTS に配布して再起動（前のバイナリは .prev に残す）
	@mkdir -p .build
	cd $(APP_SRC) && GOOS=linux GOARCH=$(GOARCH) CGO_ENABLED=0 go build -o $(CURDIR)/.build/app $(BUILD_PKG)
	@for h in $(APP_HOSTS); do \
	  echo "== $$h"; \
	  scp -q .build/app $$h:/tmp/isu-app.new && \
	  $(SSH) $$h 'set -e; [ -e $(APP_BIN) ] && sudo cp -p $(APP_BIN) $(APP_BIN).prev; \
	    sudo install -m 0755 /tmp/isu-app.new $(APP_BIN).new && sudo mv -f $(APP_BIN).new $(APP_BIN); \
	    sudo systemctl restart $(APP_SERVICE); sleep 2; echo "  $(APP_SERVICE): $$(systemctl is-active $(APP_SERVICE))"; \
	    systemctl is-active --quiet $(APP_SERVICE)' || { echo "失敗: $$h（journalctl -u $(APP_SERVICE) -n 50 / 戻す: make rollback）" >&2; exit 1; }; \
	done
	@echo "$$(git -C $(APP_SRC) rev-parse --short HEAD 2>/dev/null || echo 不明)$$([ -n "$$(git -C $(APP_SRC) status --porcelain 2>/dev/null)" ] && echo ' +未コミットの変更') ($(TS))" > .last-deploy
	@echo "配布: $$(cat .last-deploy)"

restart: config ## アプリのサービスだけを再起動
	@for h in $(APP_HOSTS); do $(SSH) $$h 'sudo systemctl restart $(APP_SERVICE) && sleep 1 && systemctl is-active $(APP_SERVICE)' || exit 1; done

rollback: config ## アプリのバイナリを直前の .prev に戻して再起動
	@for h in $(APP_HOSTS); do \
	  $(SSH) $$h 'set -e; sudo cp -p $(APP_BIN).prev $(APP_BIN).new && sudo mv -f $(APP_BIN).new $(APP_BIN); \
	    sudo systemctl restart $(APP_SERVICE); sleep 2; systemctl is-active $(APP_SERVICE)' || exit 1; \
	done
	@echo "rollback 済み（.last-deploy は更新しない）"

# ---- nginx / MySQL の設定 --------------------------------------------------
fetch-conf: config ## サーバーの設定ファイルを conf/ に取得（NGINX_FILES / MYSQL_FILES）
	@for f in $(NGINX_FILES); do mkdir -p conf$$(dirname $$f) && $(SSH) $(NGINX_HOST) "sudo cat $$f" > conf$$f && echo "conf$$f"; done
	@for f in $(MYSQL_FILES); do mkdir -p conf$$(dirname $$f) && $(SSH) $(DB_HOST) "sudo cat $$f" > conf$$f && echo "conf$$f"; done

deploy-nginx: config ## conf/ の nginx 設定を配置し、nginx -t が通ったら reload（失敗したら元に戻す）
	@for f in $(NGINX_FILES); do scp -q conf$$f $(NGINX_HOST):/tmp/isu-$$(basename $$f) || exit 1; done
	$(SSH) $(NGINX_HOST) 'for f in $(NGINX_FILES); do sudo cp -p $$f /tmp/isu-bak-$$(basename $$f) 2>/dev/null; sudo install -m 0644 /tmp/isu-$$(basename $$f) $$f; done; \
	  if sudo nginx -t; then sudo systemctl reload nginx && echo "nginx: reload 済み"; \
	  else for f in $(NGINX_FILES); do sudo cp -p /tmp/isu-bak-$$(basename $$f) $$f; done; echo "nginx -t 失敗: 元に戻しました（reload していません）" >&2; exit 1; fi'

deploy-mysql: config ## conf/ の MySQL 設定を配置し、検証が通ったら MySQL を再起動（ベンチ中は使わない）
	@for f in $(MYSQL_FILES); do scp -q conf$$f $(DB_HOST):/tmp/isu-$$(basename $$f) || exit 1; done
	$(SSH) $(DB_HOST) 'for f in $(MYSQL_FILES); do sudo cp -p $$f /tmp/isu-bak-$$(basename $$f) 2>/dev/null; sudo install -m 0644 /tmp/isu-$$(basename $$f) $$f; done; \
	  if sudo mysqld --validate-config --user=mysql; then sudo systemctl restart mysql && echo "mysql: restart 済み"; \
	  else for f in $(MYSQL_FILES); do sudo cp -p /tmp/isu-bak-$$(basename $$f) $$f; done; echo "検証に失敗: 元に戻しました（再起動していません）" >&2; exit 1; fi'

slow-on: config ## スロークエリログを有効化（全 SQL を記録。再起動しない。反映後に make restart）
	$(SSH) $(DB_HOST) "sudo mysql -e \"SET GLOBAL slow_query_log_file='$(SLOW_LOG)'; SET GLOBAL long_query_time=0; SET GLOBAL slow_query_log=ON\""
	@echo "既存の接続には効かないので make restart でアプリを再起動してください"

slow-off: config ## スロークエリログを無効化（最終ベンチ前に）
	$(SSH) $(DB_HOST) "sudo mysql -e 'SET GLOBAL slow_query_log=OFF'"

# ---- 計測 ------------------------------------------------------------------
pre: config ## ベンチ前: ログを退避して開き直させる（前回のベンチと混ぜない）。RUN= で名前を指定可
	@name=$(if $(filter command line,$(origin RUN)),$(RUN),$(TS)); \
	  test ! -e results/$$name || { echo "results/$$name は既にあります。RUN= で別の名前にしてください" >&2; exit 1; }; \
	  echo $$name > .current-run; echo "実行名: $$name"
	$(SSH) $(NGINX_HOST) 'sudo test -f $(ACCESS_LOG) && sudo mv $(ACCESS_LOG) $(ACCESS_LOG).$(TS); sudo nginx -s reopen'
	$(SSH) $(DB_HOST) 'sudo test -f $(SLOW_LOG) && sudo mv $(SLOW_LOG) $(SLOW_LOG).$(TS); sudo mysql -e "FLUSH SLOW LOGS"'
	@echo "ベンチを実行してください。終わったら make analyze"

pprof: config ## ベンチ中: CPU プロファイルを取得し、上位の関数を results/<run>/pprof.txt に保存
	@test -n "$(RUN)" || { echo "先に make pre を実行してください" >&2; exit 1; }
	@mkdir -p $(R)
	$(SSH) $(firstword $(APP_HOSTS)) 'curl -sf -o /tmp/isu-cpu.pb.gz "$(PPROF_URL)/debug/pprof/profile?seconds=$(PPROF_SECONDS)"'
	scp -q $(firstword $(APP_HOSTS)):/tmp/isu-cpu.pb.gz $(R)/cpu.pb.gz
	go tool pprof -top -nodecount=50 $(R)/cpu.pb.gz > $(R)/pprof.txt 2>&1
	@head -n 20 $(R)/pprof.txt

pprof-web: ## 取得済みのプロファイルをブラウザで見る（http://localhost:8081）
	go tool pprof -http=:8081 $(R)/cpu.pb.gz

analyze: config ## ベンチ後: ログを results/<run>/ に回収し、alp.txt と slow.txt を作る
	@test -n "$(RUN)" || { echo "先に make pre を実行してください" >&2; exit 1; }
	@test ! -e $(R)/alp.txt || { echo "$(R) は集計済みです（再集計するには $(R)/alp.txt を消す）" >&2; exit 1; }
	@command -v alp >/dev/null && command -v pt-query-digest >/dev/null || { echo "手元に alp と pt-query-digest が必要です（README 参照）" >&2; exit 2; }
	@mkdir -p $(R)
	$(SSH) $(NGINX_HOST) 'sudo cat $(ACCESS_LOG)' > $(R)/access.log
	$(SSH) $(DB_HOST) 'sudo cat $(SLOW_LOG)' > $(R)/slow.log
	@test -s $(R)/access.log || echo "warning: アクセスログが空です（make pre の後にベンチを実行した？ログ形式は LTSV？）" >&2
	@test -s $(R)/slow.log || echo "warning: スロークエリログが空です（make slow-on 済み？）" >&2
	alp ltsv --file $(R)/access.log -m '$(ALP_MATCH)' --sort sum -r -o count,2xx,3xx,4xx,5xx,method,uri,min,avg,max,sum > $(R)/alp.txt
	pt-query-digest --limit 15 $(R)/slow.log > $(R)/slow.txt 2>&1
	@test -e $(R)/memo.md || printf '# %s\n\n- score: \n- pass/fail: \n- 変更内容: \n- 配布したコード: %s\n- 気づいたこと: \n' \
	  "$(RUN)" "$$(cat .last-deploy 2>/dev/null || echo 不明)" > $(R)/memo.md
	@echo "== API（合計時間順の上位。全体: $(R)/alp.txt）"; head -n 18 $(R)/alp.txt
	@echo "== SQL（合計時間順。詳細: $(R)/slow.txt）"; sed -n '/^# Profile/,/^$$/p' $(R)/slow.txt | head -n 20
	@echo "スコアと変更内容を $(R)/memo.md に書いてください"

# ---- 最初に1回 ---------------------------------------------------------------
setup: config ## サーバーに htop と sysstat（pidstat / iostat）を導入（apt。システム全体の更新はしない）
	@for h in $(ALL_HOSTS); do echo "== $$h"; $(SSH) $$h 'sudo apt-get update -qq && sudo apt-get install -y -qq htop sysstat' || exit 1; done
