# ローカルでAtollを使う

このフォークを一台のMacで継続して使う場合は、Apple Development証明書でRelease版へ署名する。
`Sign to Run Locally`は開発中の動作確認には使えるが、日常的に使うアプリのビルド方法にはしない。

この方法には、有料のApple Developer Programは必要ない。
ただし、完成したアプリをほかの利用者へ配布する用途には、Developer IDによる署名とNotarizationを使う。

## 初回の署名設定

1. Xcodeで`DynamicIsland.xcodeproj`を開く。
2. プロジェクト設定から`DynamicIsland`ターゲットを選ぶ。
3. `Signing & Capabilities`を開き、Release構成を選ぶ。
4. `Automatically manage signing`を有効にする。
5. `Team`で自分のPersonal Teamを選ぶ。
6. `Signing Certificate`が`Apple Development`であることを確認する。

このフォークでは、Release版のBundle IDを`dev.masakiaota.atoll`に固定している。
別のApple Accountでビルドする場合は、そのアカウントで重複しないBundle IDへ変更する。

## Release版のビルド

リポジトリのルートで次のコマンドを実行する。

```bash
xcodebuild \
  -project DynamicIsland.xcodeproj \
  -scheme DynamicIsland \
  -configuration Release \
  -derivedDataPath DerivedData \
  build
```

ビルドしたアプリは`DerivedData/Build/Products/Release/Atoll.app`に作成される。
Finderで`Atoll.app`を`/Applications`へコピーし、以後は同じ場所のアプリを起動する。

## 署名の確認

次のコマンドがエラーを返さなければ、アプリ本体と内包するコードの署名を検証できている。

```bash
codesign --verify --deep --strict --verbose=2 \
  DerivedData/Build/Products/Release/Atoll.app
```

署名者とBundle IDは次のコマンドで確認できる。

```bash
codesign --display --verbose=4 \
  DerivedData/Build/Products/Release/Atoll.app
```

表示結果の`Authority`に`Apple Development`、`Identifier`に`dev.masakiaota.atoll`が含まれていれば、この手順で署名されている。

## 更新時の注意

更新版も同じBundle IDとPersonal Teamで署名し、`/Applications/Atoll.app`を置き換える。
Bundle IDや署名方式を変えると、macOSが別のアプリとして扱い、カレンダーやリマインダーなどの権限を再度求める場合がある。

Apple Development証明書には有効期限がある。
期限が近づいたらXcodeの`Settings > Accounts > Manage Certificates`で証明書を更新し、新しいRelease版をビルドする。
