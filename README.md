# neo-git

Emacs 用の小さな非同期 Git インターフェースです。フレーム全体を使い、左上に変更一覧、左下にマージの推移線付きコミット履歴、右に選択ファイルの差分を表示します。ファイル・行・hunk 単位のステージ操作ができます。閉じると元のウィンドウ配置に戻ります。

Emacs 29.1 以上と PATH 上の Git が必要です。依存する Lisp ライブラリは Emacs 標準のものだけです。Evil は任意で、通常の Emacs でも使えます。

## インストール

Emacs 29 以上の `package-vc-install` でインストールできます。

```elisp
(package-vc-install "https://github.com/siroio/neo-git")
```

Emacs 30 以上では `use-package` でも設定できます。

```elisp
(use-package neo-git
  :vc (:url "https://github.com/siroio/neo-git" :rev :newest)
  :commands neo-git-status
  :bind ("C-x g" . neo-git-status))
```

ダウンロードした `neo-git.el` を `M-x package-install-file` でインストールすることもできます。

## 操作

Git リポジトリ内のファイルやディレクトリから `M-x neo-git-status` を実行します。

キーは lazygit の既定に合わせています。

| キー | 操作 |
| --- | --- |
| `j` / `k` | 一覧ではファイル、差分では行を移動 |
| `v` / `V` | 文字・行単位の範囲選択 |
| `SPC` | 選択ファイル／差分の選択行・hunk をステージ／解除（コンフリクトはマーカーを消すと解決済みとしてステージ可能） |
| `d` | 選択ファイル／差分の選択行・hunk の変更を破棄（確認あり、未追跡ファイルは削除） |
| `a` | 一覧のステージ状態を全件切替／差分の行・hunk 選択を切替 |
| `RET` / `TAB` | 差分を開く／一覧と差分を切替 |
| `J` / `K` | 差分から前後のファイルへ移動 |
| `e` | 選択ファイル／差分に対応する作業ファイルの行を開く |
| `c` | コミットメッセージを編集 |
| `C-c C-c` / `C-c C-k` | コミットを確定／中止（メッセージ編集時） |
| `f` / `p` / `P` | fetch / pull / push |
| `r` / `R` | 更新 |
| `/` | パス検索 |
| `l` / `4` | 履歴ペインへ移動（`RET` でコミットの差分を右に表示、`a` で全ブランチ／現在のブランチ切替、`B` でそのコミットからブランチ作成、`C` で cherry-pick、`q` / `TAB` で一覧へ戻る） |
| `b` / `B` | ブランチ切替（リモートは追跡ブランチを作成）／HEAD からブランチ作成 |
| `3` | ブランチ一覧（`SPC` 切替、`B` そこからブランチ作成、`R` 名前変更、`d` / `D` ローカルブランチ削除／強制削除、`RET` 差分） |
| `m` / `M` | ブランチを merge／現在のブランチを rebase |
| `A` | 進行中の merge・rebase・cherry-pick を continue／abort／skip |
| `s` / `S` / `5` | stash 保存／stash メニュー／stash 一覧（一覧で `SPC` 適用、`d` 削除） |
| `@` | 最近の Git コマンドとエラーを表示 |
| `?` | キー案内 |
| `q` | 一覧では Git 画面を終了、差分では一覧へ戻る |

部分ステージは追跡済みの通常テキスト差分に対応し、Git の index だけを変更します。未追跡ファイルは一覧からファイル単位でステージしてください。rename、競合、binary、mode 変更、新規・削除ファイルの部分操作は拒否します。

コミットの作者は対象リポジトリの Git 設定に従います。`neo-emacs` と併用する場合、`,` は既存の `neo-leader-map` に接続します。

## 検証

```sh
emacs -Q --batch -l check-package.el
emacs -Q --batch -l check-git.el
emacs -Q --batch -l check-git-workflows.el
```

`check-package.el` は一時的な package ディレクトリへインストールし、autoload と標準ライブラリだけでの起動を確認します。`check-git.el` は一時 Git リポジトリでステージ・部分操作・commit・fetch・pull・push などを検証します。`check-git-workflows.el` は履歴グラフ・ブランチ・stash・merge・rebase・cherry-pick を検証します。`benchmark-git.el` は既存の検証が使用するプロセス計測コードです。

## ライセンス

GPL-3.0-or-later。ライセンス全文は [COPYING](COPYING) を参照してください。
