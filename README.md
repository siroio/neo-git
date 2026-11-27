# neo-git

Emacs 用の非同期 VCS インターフェースです。Git・Jujutsu (`jj`)・Mercurial (`hg`)・Subversion (`svn`)・Perforce (`p4`) に対応します。フレーム全体を使い、左上に変更一覧、左下に履歴、右に差分を表示します。閉じると元のウィンドウ配置に戻ります。Gitでは従来の履歴グラフとファイル・行・hunk 単位のステージ操作を利用できます。

差分は追加・削除行を薄い背景、行内の変更箇所を濃い背景で表示します。ファイル見出しを区切り線と太字、hunk見出しを太字で区別し、左端の `old` / `new` 列に変更前・変更後の行番号を表示します。行番号は表示だけに付けるため、コピーするdiff本文、行選択、部分stage・解除、元ファイルへのジャンプは従来どおりです。コミット・stashの差分にも適用します。

行内の詳細な強調と構文色は標準の `diff-mode` の設定を引き継ぎます（行内強調は `diff-refine` と外部 `diff` コマンドを使用）。Emacs 31以降では自動の行内強調を非同期で順次反映し、変更箇所が多いdiffでも外部コマンドの完了を待たずに本文を表示・操作できます。表示更新・終了時には処理と一時ファイルを回収します。旧版Emacsと手動の `diff-refine-hunk` は標準の同期処理を使います。配色は `neo-git-diff-*` faceで調整できます。バイナリ差分やcombined diffなど通常のunified diff以外には、旧・新行番号を追加しません。

Git画面を終了すると、その画面の差分・履歴・ログ・コミット編集バッファを破棄し、状態・差分などの取得処理とタイマーを停止します。commit・merge・rebase・fetch・pushなどの変更処理が実行中の場合は、処理が成功または失敗で終了するまでバッファの破棄を保留します。一覧バッファを直接削除した場合も同じ扱いです。作業ファイルのバッファや、別リポジトリのGit画面は保持します。

コミット編集の `C-c C-k` は、Gitコマンドの開始前なら編集を中止し、開始後ならcommitの完了を待って編集バッファを破棄します。対話的rebaseなどがエディタ入力を待っている場合は、その入力を完了するまで終了を保留します。

Emacs 29.1 以上と、利用するVCSのCLIが PATH 上に必要です。依存する Lisp ライブラリは Emacs 標準のものだけです。Evil は任意で、通常の Emacs でも使えます。

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

Gitのみ使う場合は、ダウンロードした `neo-git.el` を `M-x package-install-file` でインストールすることもできます。4つの追加VCSには `neo-vcs.el` と `neo-vcs-{jj,hg,svn,p4}.el` も必要です。上記の `package-vc-install` はまとめて導入します。手動配置の場合は6ファイルを同じ `load-path` 上のディレクトリに置いてください。

## VCSの選択と共通操作

作業ディレクトリから `M-x neo-git-status` または `M-x neo-vcs-status` で開きます。最も近い `.jj`・`.hg`・`.svn`・`.git` を検出し、jjとGitが同じ場所にある場合はjjを選びます。`C-u M-x neo-git-status` で明示的に `git`・`jj`・`hg`・`svn`・`p4` を選べます。Gitを選ぶと従来のGit画面を開きます。

Perforceは `P4CONFIG` の設定ファイルまたは `P4CLIENT` があれば自動選択します。それ以外は `p4` を明示的に選択してください。既存の接続・ログイン設定を使い、選択時の接続先・ユーザー・クライアントを画面に固定します。ログインやworkspace作成はP4のCLIで済ませてください。

以下はjj・Mercurial・SVN・Perforce画面の共通キーです。Git画面のキーは次節のとおりです。

| キー | 操作 |
| --- | --- |
| `j` / `k` | 一覧または差分内の移動 |
| `SPC` / `a` | ファイルをマーク／表示中の全件のマークを切替 |
| `RET` / `TAB` | 差分ペインへ移動。履歴の `RET` はリビジョン差分を表示 |
| `l` | 履歴ペインへ移動 |
| `o` | 作業ファイルを開く |
| `/` | ファイル名で絞り込み |
| `x` / `?` | VCS固有の操作メニュー／キー案内 |
| `r` / `R` | 状態・履歴を更新 |
| `@` | コマンドとエラーログを表示 |
| `q` | 一覧では終了。差分・履歴では一覧へ戻る |
| `C-c C-c` / `C-c C-k` | メッセージ編集で実行／編集を中止 |

マークがなければカーソル位置のファイル、マークがあれば表示中のマーク済みファイルを操作します。新しい4つのVCSはファイル単位の操作です。Gitの部分ステージは引き続き利用できます。

| VCS | 固有の操作 |
| --- | --- |
| jj | `c` describe、`n` new、`b` edit、`s` 選択ファイルをsplit、`S` 親へsquash、`d` restore、`B` bookmark設定、`f` Git remote fetch、`P` push |
| Mercurial | `A` add、`d` remove、`D` ファイルを指定してremove、`v` revert、`c` 選択ファイルをcommit、`C` マージ全体をcommit、`u` update、`b` bookmark、`M` merge、`f` pull、`P` push |
| SVN | `A` add、`d` delete、`D` ファイルを指定してdelete、`v` revert、`c` 選択対象をcommit、`u` update、`s` switch、`z` 作業内容を採用してresolvedにする |
| Perforce | `e` edit、`A` add、`d` delete、`g` reconcile、`v` revert、`c` 空の番号付きchange作成、`m` changeへreopen、`C` 番号付きchangeをsubmit、`u` sync、`s` shelve、`U` unshelve、`z` 安全な自動resolve |

Git以外にはGitのindexを模した領域を設けず、VCS本来の単位を使います。jjのメッセージ編集は開始時のchangeを対象にします。Mercurialのマージコミットは全変更を含む専用操作で、確認後に実行します。SVNの選択commitは `--depth empty` を使い、選んだディレクトリの子を暗黙に含めません。ルートディレクトリ自身の属性変更は閲覧のみで、更新操作はCLIで行ってください。

Perforceは番号付きchange・default change・未openの変更候補を区別します。変更一覧のreconcileはpreviewだけです。submitは指定した番号付きchange全体を対象にし、選択ファイルを自動で移動しません。作成した番号はヘッダーとメッセージに表示します。shelveは選択ファイルだけ、unshelveは現在のclient範囲で実行します。editとdeleteは変更一覧にない通常ファイルも指定できます。moveの対を分断する操作や、filespecとして曖昧な `...` を含むファイル名は拒否します。

Perforceの非ASCIIファイル名・メッセージにはUnicodeサーバーが必要です。コマンド入出力は `-Q utf8`、日本語などのファイル指定は `-x -` のUTF-8入力を使います。非Unicodeサーバーでの非ASCII入力や、文字コードが壊れた既存パスは実行前・一覧取得時に拒否します。改行を含む非ASCIIファイル名も対象外です。日本語ファイル名は実サーバーで検証済みですが、日本語を含むworkspaceルート・client名・user名は未検証です。[Perforceの文字コード仕様](https://help.perforce.com/helix-core/server-apps/cmdref/current/Content/CmdRef/global.options.html)

破棄・履歴変更・サーバーへの送信などは対象を表示して確認します。作業ツリー内に未保存バッファがあれば、更新操作の前に保存を求めます。実行中の変更処理は画面を閉じても中断せず、終了後にバッファを回収します。失敗したメッセージは編集可能なまま残します。外部エディタを要求する操作、対話的な競合解決、depot管理は各CLIで行ってください。Perforceの安全な自動resolveで残った競合は、手動解決後に更新してください。

CLIが終了コード0でも警告を返した場合は、その内容を結果として表示します。Mercurialのpushは失敗と「送信対象なし」がともに終了コード1になるため、どちらもCLIの出力付きで非成功として表示します。詳細は `@` のログで確認できます。

実CLIで検証した版はEmacs 31.1、jj 0.46.0、Mercurial 7.2.4、SVN 1.14.2、P4/P4D 2026.1です。jjの構造化diff templateなどを使うため、古いCLIとの互換性は保証していません。現時点ではローカルworkspaceが対象です。新4VCSの履歴は最新100件を表示します。

## Gitの操作

Git リポジトリ内のファイルやディレクトリから `M-x neo-git-status` を実行します。

サブモジュール行には、親での参照のステージ、子のHEAD変更、追跡ファイルの編集、未追跡ファイルの有無を表示します。`e` でチェックアウト済みの子のGit画面へ移動し、`q` で親の画面に戻れます。通常コミットのメッセージ編集欄には、対象リポジトリと、その時点でGitが使うAuthor・Committerの名前とメールアドレスを表示します。

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
| `3` | ブランチ一覧（`SPC` 切替、`B` そこからブランチ作成、`R` ローカルの名前変更、`d` ローカル／リモートブランチ削除、`D` ローカルの強制削除、`RET` 差分） |
| `m` / `M` | ブランチをmerge／rebaseメニュー（通常・対話的・autosquash） |
| `A` | 進行中の merge・rebase・cherry-pick を continue／abort／skip |
| `z` | 復旧メニュー：reflog／復旧ブランチ作成／revert／reset |
| `s` / `S` / `5` | stash 保存／stash メニュー／stash 一覧（一覧で `SPC` 適用、`d` 削除） |
| `@` | 最近の Git コマンドとエラーを表示 |
| `?` | キー案内 |
| `q` | 一覧では Git 画面を終了、差分では一覧へ戻る |

`p` のpullは、追跡済みファイルの未コミット変更をGitの `--autostash` で一時退避し、取り込み後に復元します。merge／rebaseの選択は対象リポジトリのGit設定に従います。未保存のバッファは先に保存してください。処理後は開いている作業ファイルと変更一覧を更新します。

自動退避からの復元では、ステージ済みの変更が未ステージに戻る場合があります。未追跡ファイルは退避せず、取り込むファイルと同名なら上書きを拒否します。復元で競合した場合は変更一覧から `E` で解決してください。退避内容はstash一覧に残るため、復元結果を確認してから削除できます。取り込み自体が完了している場合は `A` でのcontinueは不要です。merge／rebase自体が競合している場合は、解決後に `A` でcontinue、またはabortしてください。

部分ステージは追跡済みの通常テキスト差分に対応し、Git の index だけを変更します。未追跡ファイルは一覧からファイル単位でステージしてください。rename、競合、binary、mode 変更、新規・削除ファイルの部分操作は拒否します。

通常のunstaged差分は強調表示済みのバッファを直近8件キャッシュし、同じファイルへ戻るときのGit再起動と表示処理の再計算を省きます。ファイル・index・属性ファイルの内容を確認し、変更があれば取り直します。`r` / `R` の更新でキャッシュを消去します。Git設定を変更した場合も更新してください。ファイルやindexが1 MiBを超える場合、staged・rename・競合・特殊ファイルは従来どおりGitから取得します。部分ステージ前には、キャッシュの有無にかかわらずGitで差分を再確認します。

Gitの履歴は、ローカルブランチ・リモート追跡ブランチ・タグを含むグラフを最大100コミットまで表示します。件名の前に `HEAD -> main` や `origin/main` などのラベルが付きます。同じ行にあれば両方が同じコミットを指し、別の行にあればグラフでそれぞれの位置を確認できます。履歴で `a` を押すと現在のブランチだけに絞れます。Authorは16文字幅で作者ごとに色分けし、マウスを重ねるとフルネームを確認できます。

上流ブランチを設定している場合、履歴の見出しに `main → origin/main  ↑2 ↓1` のように表示します。この例では、ローカルだけにあるコミットが2件、上流だけにあるコミットが1件です。リモートの最新状態を取得するには、変更一覧で `f` を押してリモートを選びます。fetchが終わると履歴も更新されます。

### 画像の差分とプレビュー

GUI版Emacsの変更一覧で画像にカーソルを合わせると、右ペインに画像差分が表示されます。色や透明度が変わった画素はピンクで表示され、変更画素数、画像サイズ、変更前後の画像も確認できます。フォーカスは一覧に残るので、`j` / `k` で画像を順に比較できます。

コミット履歴では `i` を押すと画像差分が開きます。画像が複数あるコミットではファイル名を選びます。右ペインの `I`（大文字のアイ）で差分と単体プレビューを切り替えられます。次の画像を選ぶと、自動で差分表示に戻ります。

- Windows では標準の画像コーデックで PNG、JPEG、GIF、BMP、TIFF を比較します。WebP はインストール済みのコーデックを使います。初めて画像を選んだときに、Windows 標準の .NET Framework コンパイラで同梱の `neo-git-image.cs` をセッション用の一時フォルダーにビルドします。手動配置では、このファイルを `neo-git.el` と同じディレクトリに置いてください。
- Photoshop の `.psd`・`.psb` は保存された合成画像を比較します。Windows では8ビットRGBの非圧縮・RLE圧縮を直接読み込み、合成画像の透明度にも対応します。CMYK、16ビット、ZIP圧縮、特色チャンネルなどには ImageMagick 7 の `magick` を使います。
- CLIP STUDIO PAINTの `.clip` は、SQLite対応のEmacsでファイルに保存されたキャンバスプレビューを表示します。`.clpi` も中身が同じCLIP形式なら表示できます。

Git LFSで管理している画像は、作業ファイルまたはローカルのLFSキャッシュにある実体を使います。必要な画像が手元にない場合は、差分ペインにその旨を表示します。

| 選んだ行 | 比較する版 |
| --- | --- |
| 未ステージ | ステージ済みの画像 → 作業ファイル |
| ステージ済み | HEAD → ステージ済みの画像 |
| コミット履歴 | 最初の親コミット → 選択したコミット |
| 競合 | Git の ours → theirs |

Windows のデコーダーが利用できない環境では、PATH にある `magick` で比較します。どちらのデコーダーも使えない場合、Emacs が読める画像は16 MiBまで単体で表示できます。

左右の画像は左上を揃え、縮小前の色と透明度を比較します。画像の外は透明として扱い、表示用の画像は最大1200×900に縮小します。追加・削除では存在する側の画像を表示します。直近4件の表示結果を保持し、同じ画像に戻ったときは Git の版と作業ファイルの内容を照合して再利用します。

コミットの作者は対象リポジトリの Git 設定に従います。`neo-emacs` と併用する場合、`,` は既存の `neo-leader-map` に接続します。

リモートブランチの`d`は、確認後にサーバー側のブランチを削除します。同名のローカルブランチは残ります。最後のfetchからリモート側で更新されていた場合は削除を拒否するため、fetchして内容を確認してから再試行してください。標準のfetch設定（`+refs/heads/*:refs/remotes/<remote>/*`）に対応します。

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
emacs -Q --batch -l check-pull.el
emacs -Q --batch -l check-git-workflows.el
emacs -Q --batch -l check-git-advanced.el
emacs -Q --batch -l check-refresh.el
emacs -Q --batch -l check-navigation.el
emacs -Q --batch -l check-remote-delete.el
emacs -Q --batch -l check-cleanup.el
emacs -Q --batch -L . -l check-diff-display.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -L . -l check-image-preview.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -L . -l check-diff-performance.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -l check-vcs-package.el
emacs -Q --batch -L . -l check-vcs.el -l check-vcs-integration.el -l check-vcs-jj.el -l check-vcs-hg.el -l check-vcs-svn.el -l check-vcs-p4.el -f ert-run-tests-batch-and-exit
```

追加VCSのテストは一時リポジトリを作り、インストール済みCLIがあれば実際の操作も検証します。CLIがない場合の実操作テストと、Evilがない場合のEvilテストはskipされます。Perforceの実操作テストには隔離サーバーが必要です。Windowsでは公式の `p4.exe` と `p4d.exe` を `var/multi-vcs/tools/` に置き、次を実行します。専用サーバーとworkspaceを `var/multi-vcs/` 以下に作り、そのサーバーだけを終了します。共有サーバーやユーザー設定は変更しません。

```powershell
./tools/check-vcs-p4.ps1 -Emacs 'C:/path/to/emacs.exe'
./tools/check-vcs-p4.ps1 -Unicode -Emacs 'C:/path/to/emacs.exe'
```

`-Unicode` は新規のテスト用サーバーだけをUnicodeモードで初期化し、日本語パスを含む同じワークフローを検証します。

`check-package.el` は一時的な package ディレクトリへインストールし、autoload と標準ライブラリだけでの起動を確認します。`check-git.el` は一時 Git リポジトリでステージ・部分操作・commit・fetch・pull・push などを検証します。`check-git-workflows.el` は履歴グラフ・ブランチ・stash・merge・rebase・cherry-pick を検証します。`benchmark-git.el` は既存の検証が使用するプロセス計測コードです。

`check-git-advanced.el` はamend、indexを保持するreword、fixup、競合解決、実際のemacsclient経由のrebase編集・中止、復旧ブランチ、reflog、resetを一時リポジトリで検証します。

`check-pull.el` はローカルremoteを使い、merge／rebase設定での未コミット変更の保持、バッファ再読込、自動退避の復元競合、未保存編集と未追跡ファイルの保護を検証します。

`check-refresh.el` はリポジトリ本体・`.git`削除後の更新で古い一覧・差分・履歴が消え、再作成後に更新できることを検証します。状態取得に失敗した画面にはエラーを表示し、`r`で再試行できます。

`check-navigation.el` は一覧の上下端・見出しを越える移動と差分の追従を検証します。Evilを先にロードして実行すると、`Ctrl+D` / `Ctrl+U`の連続入力も検証します。

`check-remote-delete.el` は一時bare remoteで削除確認・取消、他者による更新時の拒否、削除後の一覧更新、同名ローカルブランチの保持を検証します。

`check-cleanup.el` は終了・バッファ削除時の関連バッファ、非同期プロセス、タイマーの解放と、別画面の保持を検証します。変更処理の成功・失敗、複数段階の処理、実際のpre-commit hookで待機中のcommitについて、完了まで停止・破棄を保留することも確認します。

### GUIでのMagit比較

手順と測定条件は [benchmarks/README.md](benchmarks/README.md) を参照してください。比較は通常の設定を読み込んだ別GUIプロセスで行い、使い捨てのGitリポジトリ以外のindexを変更しません。

## ライセンス

GPL-3.0-or-later。ライセンス全文は [COPYING](COPYING) を参照してください。
