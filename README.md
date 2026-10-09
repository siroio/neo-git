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
| `e` | 選択ファイル／差分に対応する作業ファイルの行を開く（一覧の競合ファイルはSmergeで解決） |
| `E` | 選択した競合ファイルをSmergeで開き、最初の競合へ移動 |
| `c` | コミットメッセージを編集 |
| `C` | コミットメニュー：通常commit／HEADのamend／メッセージだけreword／fixup（履歴では `c`） |
| `C-c C-c` / `C-c C-k` | コミットを確定／中止（メッセージ編集時） |
| `f` / `p` / `P` | fetch / pull / push |
| `r` / `R` | 更新 |
| `/` | パス検索 |
| `l` / `4` | 履歴ペインへ移動（`RET` でコミットの差分を右に表示、`a` で全ブランチ／現在のブランチ切替、`B` でそのコミットからブランチ作成、`C` で cherry-pick、`q` / `TAB` で一覧へ戻る） |
| `b` / `B` | ブランチ切替（リモートは追跡ブランチを作成）／HEAD からブランチ作成 |
| `3` | ブランチ一覧（`SPC` 切替、`B` そこからブランチ作成、`R` 名前変更、`d` / `D` ローカルブランチ削除／強制削除、`RET` 差分） |
| `m` / `M` | ブランチをmerge／rebaseメニュー（通常・対話的・autosquash） |
| `A` | 進行中の merge・rebase・cherry-pick を continue／abort／skip |
| `z` | 復旧メニュー：reflog／復旧ブランチ作成／revert／reset |
| `s` / `S` / `5` | stash 保存／stash メニュー／stash 一覧（一覧で `SPC` 適用、`d` 削除） |
| `@` | 最近の Git コマンドとエラーを表示 |
| `?` | キー案内 |
| `q` | 一覧では Git 画面を終了、差分では一覧へ戻る |

部分ステージは追跡済みの通常テキスト差分に対応し、Git の index だけを変更します。未追跡ファイルは一覧からファイル単位でステージしてください。rename、競合、binary、mode 変更、新規・削除ファイルの部分操作は拒否します。

通常のunstaged差分は強調表示済みのバッファを直近8件キャッシュし、同じファイルへ戻るときのGit再起動と表示処理の再計算を省きます。ファイル・index・属性ファイルの内容を確認し、変更があれば取り直します。`r` / `R` の更新でキャッシュを消去します。Git設定を変更した場合も更新してください。ファイルやindexが1 MiBを超える場合、staged・rename・競合・特殊ファイルは従来どおりGitから取得します。部分ステージ前には、キャッシュの有無にかかわらずGitで差分を再確認します。

コミットの作者は対象リポジトリの Git 設定に従います。`neo-emacs` と併用する場合、`,` は既存の `neo-leader-map` に接続します。

### コミット修正と競合解決

amendとrewordはHEADを書き換える前に確認します。rewordはindexの内容をコミットに含めず、ステージ状態を保持します。編集中にHEADが変わった場合は、確定を拒否します。fixupは履歴で選択したHEADの祖先、または候補から選んだコミットを対象にし、あとからautosquashで取り込めます。

競合ファイルでは `C-c C-n` / `C-c C-p` で次／前の競合へ移動し、`C-c C-m` / `C-c C-o` / `C-c C-b` で上側／下側／両方を採用します。`C-c C-e` はEdiffを開きます。`C-c C-c` はファイル全体に未解決マーカーがないことを確認して保存・stageし、一覧へ戻ります。`C-c C-k` は編集を保持して一覧へ戻ります。解決後、`A` で進行中の操作を継続してください。標準より長いマーカーを使うファイルは手動で編集してください（未解決のままのstageは拒否します）。削除など作業ファイルが存在しない競合は、Gitで解決してください。

### 対話的rebaseと復旧

`M` → `i`（対話的）または `a`（autosquash）で、書き換える範囲の手前のコミットを指定します。Gitが作成したtodoをEmacsで編集でき、通常の編集操作で行を並べ替え、`C-c C-a` で行の操作を選べます。`C-c C-c` で保存して実行、`C-c C-k` でその編集を中止します。reword／squashやrebase継続が要求するメッセージも同じキーで編集します。中途の編集中止でrebaseが残った場合は、`A` → abortで戻してください。merge構造は `--rebase-merges` で保持します。

対話的編集にはEmacsに付属する `emacsclient` を使います。必要なときに、このEmacs内でserverを開始します。他のEmacsが同じserver名を使っていれば別名で開始し、既存serverを置き換えません。

reflog一覧の `B` は選択コミットから復旧ブランチを作成し、現在のブランチや作業ファイルを変更しません。revertは打ち消すコミットを新規作成します。mergeコミットのrevertはmainlineの指定が必要なので、Gitから行ってください。resetはsoft／mixed／hardを選び、対象と影響を確認して実行します。

## 検証

```sh
emacs -Q --batch -l check-package.el
emacs -Q --batch -l check-git.el
emacs -Q --batch -l check-git-workflows.el
emacs -Q --batch -l check-git-advanced.el
```

`check-package.el` は一時的な package ディレクトリへインストールし、autoload と標準ライブラリだけでの起動を確認します。`check-git.el` は一時 Git リポジトリでステージ・部分操作・commit・fetch・pull・push などを検証します。`check-git-workflows.el` は履歴グラフ・ブランチ・stash・merge・rebase・cherry-pick を検証します。`benchmark-git.el` は既存の検証が使用するプロセス計測コードです。

`check-git-advanced.el` はamend、indexを保持するreword、fixup、競合解決、実際のemacsclient経由のrebase編集・中止、復旧ブランチ、reflog、resetを一時リポジトリで検証します。

### GUIでのMagit比較

手順と測定条件は [benchmarks/README.md](benchmarks/README.md) を参照してください。比較は通常の設定を読み込んだ別GUIプロセスで行い、使い捨てのGitリポジトリ以外のindexを変更しません。

## ライセンス

GPL-3.0-or-later。ライセンス全文は [COPYING](COPYING) を参照してください。
