// pprof をループバック限定の専用リスナーで提供する最小例。
// 実アプリの main パッケージにこのファイルを置き、main() の先頭で startPprof() を呼ぶ。
//
//	func main() {
//		startPprof()
//		...
//
// 取得（対象ホスト上）:     curl -o cpu.pb.gz 'http://127.0.0.1:6060/debug/pprof/profile?seconds=30'
// 取得（手元から SSH 経由）: ssh -N -L 6060:127.0.0.1:6060 isu1 &  してから go tool pprof http://127.0.0.1:6060/debug/pprof/profile?seconds=30
// 通常は scripts/measure.sh profile が対象ホスト上で取得して回収する。
//
//   - "net/http/pprof" を import すると http.DefaultServeMux にもハンドラーが登録される。
//     アプリが DefaultServeMux を使っている（http.HandleFunc / http.ListenAndServe(addr, nil)）場合、
//     アプリのポートでも pprof が公開されてしまうので、アプリ側は独自の mux（chi, echo など）を使っていることを確認する。
//   - CPU プロファイルは「CPU を使っている時間」だけを示す。DB や外部 API の待ち（I/O 待ち・ロック待ち）は現れない。
//     待ち時間は block / mutex プロファイルで見る（ISU_PPROF_BLOCK_RATE / ISU_PPROF_MUTEX_FRACTION で有効化。負荷が増えるので必要なときだけ）。
//   - 最終ベンチ前には ISU_PPROF を外して再起動する（リスナー自体を起動しない）。
package main

import (
	"log"
	"net/http"
	"net/http/pprof"
	"os"
	"runtime"
	"strconv"
)

func startPprof() {
	addr := os.Getenv("ISU_PPROF") // 例: 127.0.0.1:6060（空なら起動しない）
	if addr == "" {
		return
	}
	if v, err := strconv.Atoi(os.Getenv("ISU_PPROF_BLOCK_RATE")); err == nil && v > 0 {
		runtime.SetBlockProfileRate(v) // 例: 10000（ns 以上ブロックしたものを記録）
	}
	if v, err := strconv.Atoi(os.Getenv("ISU_PPROF_MUTEX_FRACTION")); err == nil && v > 0 {
		runtime.SetMutexProfileFraction(v) // 例: 100（1/100 をサンプリング）
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	go func() {
		log.Printf("pprof listening on %s", addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Printf("pprof: %v", err)
		}
	}()
}
