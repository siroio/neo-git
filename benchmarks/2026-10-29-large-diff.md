# 大きなdiffの表示停止を解消

400か所の変更を含む17,783 byteのdiffで、Git取得から最初の60行の表示準備までの中央値が27.85秒から63.83msになりました。Emacs 31.1、通常の `diff-refine=font-lock` と `diff-font-lock-syntax=t` を使い、それぞれ3回測定しています。

| 測定項目 | 修正前 | 修正後 |
| --- | ---: | ---: |
| Git取得＋本文・行番号・最初60行の強調表示準備（中央値） | 27,849.25ms | 63.83ms |
| 全行内強調の完了（中央値） | 27,877.89ms | 28,226.46ms |
| 10ms周期タイマーの呼出間隔（全サンプル中の最大） | 27,869.76ms | 119.39ms |
| 完了時の追加・削除の行内強調数（各回） | 800 | 800 |

変更ブロックごとに `smerge-refine-regions` が外部diffの完了を同期的に待つことが停止の原因でした。行内強調の計算量は変えず、同時に1プロセスだけ非同期実行し、結果を順次反映します。本文、行番号、構文色、部分stage用の元diffは保持します。表示更新・終了・モード変更では待機中の処理を中止し、処理中に内容が変わった場合は古い結果を適用しません。

Emacs 31で分離されたsmergeの準備・描画処理を再利用しています。それらがない旧版Emacsは従来の同期処理を使い、手動の `diff-refine-hunk` と `diff-refine` の設定も維持します。

## 測定条件

`large-diff.el` がneo-git内に一時リポジトリを作成し、実際のGitで生成した差分を通常の取得・表示関数へ渡します。行内強調が800個すべて付いたことを各回で検査しています。生の測定値と測定ソースのSHA-256は [修正前](large-diff-baseline.json) と [修正後](large-diff-optimized.json) にあります。修正後のバッチ測定後に追加した本体の変更は、コンパイラ向けの関数宣言3行だけです。

最終版は160×45文字の独立したGUI Emacsでも測定しました。通常利用中のEvil 20260728.1438を読み込んで有効化した3回の表示時間は95.11～159.22ms、中央値130.27msでした。最大タイマー呼出間隔は101.96msで、すべての回で800個の強調結果を確認しました。[GUI測定値](large-diff-gui.json)

バッチ・GUIとも `-Q` からの隔離環境です。通常のinit.el全体、ユーザーが停止を経験した実ファイル、物理キー配送、OSによる画面提示完了は測っていません。GUI測定は `redisplay` まで含みますが、バッチ測定とは条件が異なるため倍率の比較には使いません。

再測定は `emacs -Q --batch -l benchmarks/large-diff.el` で行えます。`NEO_GIT_LARGE_DIFF_SOURCE` に比較するneo-git.el、`NEO_GIT_LARGE_DIFF_OUTPUT` にJSONの出力先を指定できます。既定の出力先は `var/large-diff/result.json` です。

## 検証

- 表示・非同期処理のERT 13件に合格。変更した関数をバイトコンパイルした状態でも13件に合格。
- 標準diff-modeとの行内強調の一致、日本語と空白を含む一時パス、表示更新・終了時の回収、外部diffが起動できない場合、設定の尊重を確認。
- 既存の `check-package.el`、`check-git.el`、`check-git-workflows.el`、`check-git-advanced.el`、`check-pull.el`、`check-refresh.el`、`check-navigation.el`、`check-remote-delete.el`、`check-cleanup.el` は通常のバッチ実行で終了コード0。部分stage、stash、履歴、キャッシュ、終了処理を含む。navigationのEvil試験1件はこの実行では未ロードのためskip。
- 追加の `neo-git-navigation-evil-scroll` の失敗はテストのキー設定不足と判明。`let` で `evil-want-C-u-scroll` を変更しても実際のキー割当は更新されず、`Ctrl+U` が `universal-argument` に解決されていた。テスト専用バッファで `evil-scroll-up` に割り当て、キー解決とプレビュー追従も検査するよう修正。Evilありのバッチ・隔離GUIの両方でnavigation 6件に合格し、この残件は解消した。通常のキー割当と設定値は保持。
- パッケージ化のコンパイルでは既存のdocstring・obsolete macro・Evil関連の警告が残る。今回の変更による追加警告は解消済み。

利用中のEmacs、インストール済みパッケージ、兄弟ディレクトリ、親のsubmodule参照は変更していません。
