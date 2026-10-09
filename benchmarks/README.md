# GUIワークフロー比較

`compare-gui.el` は通常のEmacs設定を読み込んだ別GUIプロセスで、neo-gitとMagitの初回画面表示・更新・ファイル差分表示・部分stageを比較します。既存のリポジトリは変更しません。

200ファイルの一時リポジトリを作り、40ファイルにそれぞれ3つのhunkを用意します。繰り返しの順序を交互に切り替え、部分stageは同じファイルの最初のhunkだけがindexに入ったことを確認します。通常設定のフォント・テーマ・拡張を使い、両ツールのフレームを160×45文字に揃えます。

測定区間は操作呼び出しから非同期処理の完了とEmacsの強制再描画までです。パッケージ読込は区間外です。物理キーの配送時間、OSによる画面の提示完了、実際の大規模リポジトリでの性能は測っていません。初回表示は各1回、ほかは各10回です。ファイル選択ではneo-gitは選択ファイルを別ペインに表示し、Magitはファイルsectionを展開するため、画面構成は異なります。

Magitが未導入の場合、比較専用の依存パッケージをTEMP内へ導入できます。既存のpackage-user-dirは変更しません。

```powershell
emacs -Q --batch -l benchmarks/install-compare-magit.el
$env:NEO_GIT_COMPARE_PACKAGES = Join-Path $env:TEMP 'neo-git-compare-elpa'
```

Magitがすでに通常設定で利用できる場合、上記の導入と変数指定は不要です。

neo-gitのディレクトリから、通常の設定を使うGUI Emacsを起動してください。専用のEmacsは測定後に終了します。

```powershell
$env:NEO_GIT_COMPARE_OUTPUT = Join-Path $PWD 'benchmarks/comparison-result.json'
emacs --load (Join-Path $PWD 'benchmarks/compare-gui.el')
```

結果JSONには生の全サンプル、Emacs・Git・Magitのバージョン、フレームサイズ、init.elとneo-git.elのSHA-256を保存します。失敗した場合は出力パスに `.error` を付けて原因を保存します。測定成功は新しいJSONの生成時刻と全サンプル数で確認してください。
