# テストの実行

リポジトリ全体の標準入口は `scripts/test.py` である。リポジトリのルートから実行する。macOSとXcodeが必要で、必要に応じて `DEVELOPER_DIR` を指定する。

```sh
python3 scripts/test.py                  # 全テスト（XCTestを含む）
python3 scripts/test.py standalone       # アプリを起動しない全テスト
python3 scripts/test.py unit             # GUIを必要としないテスト（CI用）
python3 scripts/test.py layout input     # 指定したテストだけ
python3 scripts/test.py ui               # XCTest
```

`standalone` の描画テストにはログイン中のデスクトップが必要である。`ui` はアプリを起動するため、UI自動化を許可した環境で実行する。環境による自動スキップは行わない。CIは明示的に `unit` を選択し、アプリのビルドも実施する。

## 出力の規約

正常終了時はstdoutとstderrの両方が空になり、終了コード0を返す。成功通知、進捗、コンパイラやアプリの通常ログは表示しない。警告だけで終了コード0となるコマンドも、従来どおり成功として扱う。

失敗時はstderrだけに、失敗した工程、終了コード、ログ末尾、完全ログの保存先を出す。出力全体の上限は80行かつ8 KiBで、完全ログは `.test-results/` に実行ごとに分けて保持する。成功したコマンドのログは削除する。CIでは失敗ログもビルド結果のartifactに含める。

- コマンドの非ゼロ終了コードを保持する。シグナル終了は `128 + シグナル番号` を返す。
- 起動失敗は126、コマンド不在は127、タイムアウトは124を返す。
- 中断とタイムアウトでは子プロセス群も終了させる。
- 最初の失敗で停止する。その後のテストを実行済みと扱わない。
- 対象指定の誤りを成功として扱わない。引数なしは全テストを意味する。

通常のコマンドには1工程あたり900秒の制限がある。必要なら `--timeout 1800` のように変更する。

## 詳細を調べる場合

まず失敗時に表示されたログファイルを検索し、必要な範囲だけ読む。ログ全体をAIへ流さない。人間が全出力を確認する場合は、明示的に `--verbose` を指定できる。この場合はコマンド終了後に完全ログを表示する。

```sh
python3 scripts/test.py display-lifecycle --verbose
```

テスト以外のビルドや調査コマンドにも、同じ出力制御を使用できる。

```sh
python3 scripts/quiet.py --timeout 900 -- xcodebuild build \
  -project DynamicIsland.xcodeproj -scheme DynamicIsland -destination 'platform=macOS'
```

## テストの一覧と追加方法

| 指定名 | 検証内容 |
| --- | --- |
| `output` | 無出力での成功、診断の上限、完全ログ、終了コード、中断、タイムアウト |
| `hidden-edge` | 画面状態に応じた端ホバー監視の開始と停止 |
| `localsend` | LocalSend検出処理の利用者数と開始、停止 |
| `layout` | ノッチ左側への配置、幅不足時の退避、中央での展開 |
| `input` | 表示部分の入力、透明領域の透過、移動後の入力判定 |
| `surface` | 背景の描画と表示切替、アニメーションの分離 |
| `display-lifecycle` | 画面変更後の位置計算、破棄したウィンドウの再表示防止 |
| `ui` | `DynamicIslandUITests` に含まれるXCTest |

新しい独立テストは `scripts/test.py` に登録し、環境要件に合うグループへ追加する。XCTestは既存のテストターゲットへ追加する。テスト本体はアサーションと失敗診断を保持し、成功通知や独自のログ抑制処理を追加しない。

画面の回帰テストは、`AppDelegate` の対象メソッドと管理辞書をソースから抽出してコンパイルする。画面一覧の取得先と周辺サービスを置き換え、実際の `DynamicIslandWindow` の位置と表示状態を検証する。従来の `run_display_window_lifecycle_tests.py` も標準入口へ転送する。
