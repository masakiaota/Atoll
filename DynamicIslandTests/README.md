# ノッチ表示の回帰テスト

リポジトリのルートから、ログイン中のmacOSで実行する。必要に応じて `DEVELOPER_DIR` に使用するXcodeを指定する。

```sh
notch_test_dir=$(mktemp -d /tmp/atoll-notch-tests.XXXXXX)

xcrun swiftc \
  DynamicIsland/helpers/NotchMenuBarLayout.swift \
  DynamicIslandTests/NotchMenuBarLayoutTests.swift \
  -o "$notch_test_dir/layout" && "$notch_test_dir/layout"

xcrun swiftc \
  DynamicIsland/components/Notch/DynamicIslandWindow.swift \
  DynamicIslandTests/NotchMouseRegionTests.swift \
  -o "$notch_test_dir/input" && "$notch_test_dir/input"

xcrun swiftc \
  DynamicIsland/components/Notch/NotchSurface.swift \
  DynamicIsland/components/Notch/NotchShape.swift \
  DynamicIslandTests/NotchSurfaceTests.swift \
  -o "$notch_test_dir/surface" && "$notch_test_dir/surface"

python3 DynamicIslandTests/run_display_window_lifecycle_tests.py
```

- `NotchMenuBarLayoutTests`：左側への配置、幅不足時の退避、中央での展開、開閉途中の配置、通常のノッチ間隔。
- `NotchMouseRegionTests`：表示部分の入力、透明部分・角・影の透過、入力の抑止と復帰、ウィンドウ移動後の判定。
- `NotchSurfaceTests`：角丸と背景の描画、表示切替の補間、毎秒更新と開閉・メニュー退避のアニメーションの分離。
- `DisplayWindowLifecycleTests`：画面配置変更後の再サイズ計算、同じ名前と座標を持つ画面の入れ替え、画面切断や表示モード変更を挟む非同期表示復帰、タスク終了後とロック中の復帰抑止。

実際のSwiftUI描画とAppKitウィンドウを使う独立実行形式のテストで、アプリの起動やマウス操作は行わない。macOSのメニューバー開閉通知と連動する挙動は、アクセシビリティ権限のある実機で別途確認する。

画面の回帰テストは、`AppDelegate` の対象メソッドと管理辞書をソースから抽出してコンパイルする。画面一覧の取得先と周辺サービスだけをテスト用に置き換え、実際の `DynamicIslandWindow` の位置と表示状態を検証する。実装側にテスト専用の分岐を追加せず、ユーザーの画面配置も変更しない。
