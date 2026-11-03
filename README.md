# InputBridge

Mac mini M4 + ZOWIE XL2546K + Dell S2725QC向けの無料メニューバー常駐アプリです。
Swift / SwiftUIで実装し、Dellの表示切替、手動復旧、ショートカット、ログイン時起動、入力登録後の自動切替に対応します。
診断CLIも同梱しています。有料ソフト、追加ハードウェア、Homebrewは不要です。

**アプリはインストール済みです：`/Applications/InputBridge.app`。**
このMacではミラーリング方式でUSB-C・HDMIを実機登録し、自動切替をオンにしています。Switch使用中はMacの独立した作業領域をZOWIEの1つにし、Switchを切った後に元のデュアル構成へ自動復帰する往復を確認済みです。
新規設定の自動切替は初期状態オフで、両入力の登録後に有効にできます。

## すぐ使う

```sh
open /Applications/InputBridge.app
```

メニューバーのディスプレイアイコンを押すと、次の操作ができます。

| 操作 | 動作 | 初期ショートカット |
| --- | --- | --- |
| ZOWIEのみ | Dellだけを非表示にする | `⌃⌥⌘1` |
| デュアル | Dellを元の解像度・周波数・位置へ戻す | `⌃⌥⌘2` |
| Dellを復旧 | 保存したデュアル構成へ復旧する | `⌃⌥⌘0` |

`⌃`はControl、`⌥`はOption、`⌘`はCommandです。ショートカットは設定で無効化・修飾キー変更ができます。
Dockのアイコンから起動・設定画面の再表示ができます。設定ウインドウを閉じても常駐し、Dockとメニューバーに残ります。ログイン時起動は「設定 → 一般」で有効にします（初期状態はオフ）。
DellがUSB-C専用なら、入力登録なしで手動切替だけ使えます。

「ZOWIEのみ」はアプリを起動している間維持します。終了時はデュアルへ戻します。
自動切替のオン／オフ設定は終了しても保持し、次回起動時に入力を読み直して適用します。
非表示中は独立した復旧プロセスを動かし、アプリの強制終了・応答停止時にも復元を試みます。
通常の手動切替と強制終了後の復旧は、このMacの実機で確認しました。

## 自動切替を使う

1. 「設定 → 自動切替」で非表示方法を「ZOWIEをDellに複製」にします。Switchの電源オフからUSB-Cへ戻すには、Macの映像信号を残す必要があります。方法の変更後はUSB-CとHDMIをそれぞれ登録します。
2. Dell本体がUSB-Cのときに「USB-Cを登録」、Switch 2につながるHDMI入力のときに「HDMIを登録」を押します。
3. 非表示中のDDC通信と復元、USB-Cと異なる値を確認できたら、自動切替をオンにできます。

登録中はDellだけを一時的に非表示にし、元へ戻します。3回連続で同じ正常値が返ることを確認します。
一時的な空応答では連続確認をやり直し、3回連続で読み取りに失敗した場合は登録を中止します。
HDMI入力中にUSB-C側からDDCを読めなければ、その環境ではこの方式の完全自動化は使えません。
方法やmacOSのバージョンが変わったら再登録します。

「Dellを無効化」はUSB-C映像信号も止めます。この環境ではSwitchを切ってもHDMI選択のまま省電力になり、自動復帰できませんでした。
ミラーリングはUSB-C映像信号を残し、Dellの独立した作業領域をなくします。Dell本体がUSB-Cへ戻ると、アプリが元の拡張配置へ復帰します。
macOSのディスプレイ一覧には複製先としてDellが残りますが、Switch使用中にウインドウやカーソルが別のDell作業領域へ移ることはありません。

自動切替では3回の連続一致と15秒の切替間隔を設けています。手動操作は自動切替をオフにします。
通信エラーや未登録値が続いた場合は自動切替を止め、デュアル構成へ復旧を試みます。
スリープ中は監視を休止し、復帰時はデュアルへ戻して接続が安定してから新しい値で判定します。
ミラーリング方式で、HDMI表示中に作業領域を1つにする動作と、Switchを切った後のUSB-C入力・デュアル構成への自動復帰を実機確認しました。
Mac本体の実スリープ・ログイン往復は未確認です。入力登録なしで自動切替を有効にはできません。

## アプリの保存先と復旧

設定・配置・校正・ログは`~/Library/Application Support/InputBridge/`に保存します。
「設定 → 診断とログ」から保存フォルダ、操作ログ、手動復旧を開けます。
エラーログは約2 MBごとに世代交代します。ネットワークへの送信はありません。

アプリで戻らない場合のCLI復旧：

```sh
/Applications/InputBridge.app/Contents/MacOS/inputbridge recover \
  --workspace "$HOME/Library/Application Support/InputBridge"
```

それでも戻らない場合はDellをUSB-C入力にし、USB-Cケーブルを抜き差しします。
ZOWIEを無効化する処理はありません。OSによる周波数変更を検出した場合は、保存した周波数へ補正します。

## 実機で確認した結果（2026-11-03・日本時間）

環境：Apple M4 / macOS 26.6.2。ZOWIE XL LCDがメイン、1920×1080・240 Hz。
Dell S2725QCはUSB-C、3840×2160ピクセル／1920×1080表示・120 Hz、ZOWIEの左側です。

| 項目 | 結果 |
| --- | --- |
| AppleSiliconDDCの`getvcp 0x60` | USB-C時に`VCP 60 VALUE 1B 1B 1B 1B` |
| 生応答の検証 | ヘッダー・opcode・成功応答・VCP番号・type・チェックサム正常 |
| USB-C時の入力値 | `current=0x1B1B`、5回連続一致。下位バイトだけに切り詰めず保存 |
| Dellだけの無効化 | 成功。DellはCoreGraphicsのonline一覧とUUID→IDの対応から消える |
| 無効化中のDDC | 継続。USB-C時の`0x1B1B`を取得できた |
| ZOWIEへのOSの影響 | 表示は継続するが、OSが240 Hz→120 Hzへ変更。240 Hzへ補正可能 |
| Dellの再有効化 | 同じ起動セッション内に保存した一時IDへの有効化で成功。元の拡張配置・120 Hzへ復元 |
| 保護・復旧を追加した再テスト | 無効化、DDC、Dell復帰が成功。再テストでは周波数変動は再現せずZOWIEは240 Hzを維持 |
| 親プロセスの強制終了 | 独立watchdogでDellを再有効化し、両画面の元の配置・周波数への復旧を確認 |
| ZOWIEのHDMI経由の補助診断 | `0x60=0x0011`、3回とも正常。画面構成は同一、240 Hz維持。Dellの校正には使用しない |
| HDMI時のDDC／入力値 | 正常応答。`current=0x1B11`。無効化中も3回連続一致 |
| Switch表示中の自動切替 | 成功。自動監視オンでMac側はZOWIEのみ・240 Hz |
| 無効化方式でSwitch電源オフ | HDMI入力の値が残り省電力へ移行。USB-C信号がなく自動復帰できず |
| ミラー方式でSwitchオン→オフ | 独立作業領域1つ→元のデュアル配置へ自動復帰。ユーザーがDellのMac映像を確認 |
| ミラーリング方式 | 両入力で通信と元の配置への復帰を確認。ZOWIE 240 Hz、Dell 120 Hzを維持 |
| スリープ復帰 | Mac本体の実スリープ往復は未確認 |

詳細は[調査報告](Docs/Feasibility.md)と[アプリの動作確認](Docs/AppValidation.md)を参照してください。

## ビルド

Apple Silicon / macOS 13以降 / Xcodeまたは対応するCommand Line Toolsが必要です。
この環境ではXcodeのSwift 6.2.4でビルドしました。外部Swiftパッケージのダウンロード、Homebrew、有料ソフトは不要です。

```sh
cd InputBridge
./Scripts/build.sh
./dist/inputbridge --help
./Scripts/test.sh

# アプリ形式にまとめ、ローカル署名も検証
./Scripts/build-app.sh

# アプリを終了してからインストール
./Scripts/install.sh
```

`dist/inputbridge`と`dist/inputbridge-ddc`を同じフォルダに置いてください。
配布する場合は同梱のMITライセンスとAppleSiliconDDCのライセンスも含めてください。
通常のターミナルから実行します。`sudo`は不要です。
macOSの制限された実行環境では接続画面やDDCが見えない場合があります。

## 診断を再開する

作業ディレクトリは毎回このプロジェクトにしてください。保存先は`./Diagnostics/`です。
任意の場所から実行する場合は、全コマンドで同じ`--workspace /absolute/path`を指定します。
本体のOSDでDDC/CIを有効にしておきます。

```sh
# 接続情報を表示（画面変更なし）
./dist/inputbridge inventory

# 初回または配線変更時のみ。DellとZOWIEを識別し保存（画面変更なし）
./dist/inputbridge configure

# Dell本体をUSB-Cにしてから実行
./dist/inputbridge sample --label usb-c

# Dell本体を実際にSwitch 2接続先のHDMIへ切り替えてから実行
./dist/inputbridge sample --label hdmi

# 両入力で値が安定して異なるか確認
./dist/inputbridge evaluate
```

ZOWIEのHDMI接続でもDDCを読み取れるか、補助診断だけ行う場合は次を使用できます。
画面構成や入力は変更せず、`Diagnostics/zowie-probes.jsonl`へ別に記録します。

```sh
./dist/inputbridge probe-zowie --count 3 --interval 1
```

ZOWIEでの成功は、DellをHDMI入力へ切り替えたときにUSB-C側からDDCが継続することの証明にはなりません。
Mac→HDMI→ZOWIEと、Mac→USB-C→Dell（本体はHDMIを選択）は異なる条件です。
この補助診断結果はDellの入力校正・自動化判定には混ぜません。

`--label`は本体入力を記録するためのラベルです。入力を切り替える指示ではありません。
ラベルが実際の入力と違うと誤った校正になるため、OSDを確認してください。
HDMI 1とHDMI 2は別の値になる可能性があります。Switch 2をつないでいる方で測定し、端子を変えたら再測定します。

```sh
# Dellを約10秒無効化し、DDC確認後に元の拡張構成へ戻す
# USB-C時とHDMI時に、それぞれ本体の入力とラベルを合わせて実行
./dist/inputbridge test --mode disable --label hdmi --seconds 10

# 無効化でDDCが継続しない場合に検証する代替
./dist/inputbridge test --mode mirror --label hdmi --seconds 10

# 読み取りだけで切替を観察（画面構成は変更しない）
./dist/inputbridge watch --seconds 60

# 変更前の保存情報から手動復旧
./dist/inputbridge recover
```

終了コードは`0`が成功、`1`が引数・環境・保護条件のエラー、`2`が読み取りまたは実機試験の不成立です。
`evaluate`の終了コードはレポート生成の成功を示し、自動化成立はJSON内の各項目で判断します。

`test`は画面構成を実際に変更します。`inventory`、`configure`、`sample`、`watch`、`evaluate`は変更しません。
試験はZOWIEがメインの拡張構成から開始します。無効化やミラーリング後のDell本体の入力は変更しません。
ミラーリングでは、DellはOS上で接続・描画されたままで、独立した作業領域をなくす代替になります。
ZOWIEの周波数に影響する場合があり、試験後に復元・確認します。

## 保護と復旧

- 変更対象はベンダー・製品ID・シリアル番号・UUIDを固定したS2725QCだけ。ZOWIEを無効化する処理はありません。
- 名前だけ、表示順、最初に見つかった画面へのフォールバックは行いません。
- ZOWIEが有効な独立したメイン画面であることを変更直前に確認します。
- 変更前の配置・解像度・ピクセル数・周波数を`recovery.json`へ先に保存します。
- 別プロセスのwatchdogが準備完了してから変更し、約22秒（標準設定）で復旧を試みます。親をCtrl-Cで終了してもwatchdogは継続します。
- DDCの失敗、タイムアウト、不明な値をHDMIとは判定しません。DDCヘルパーは6秒で打ち切ります。
- `CGSConfigureDisplayEnabled`は非公開APIです。OS更新・再接続・再起動後の動作は保証できません。
- 保存した一時IDによる復旧は同じOS起動セッションに限定し、有効化だけに使用します。

**復旧に失敗した場合**：ZOWIEで`./dist/inputbridge recover`を実行してください。
それでもDellが戻らない場合は、DellをUSB-C入力にしてUSB-Cケーブルを抜き差しし、システム設定の「ディスプレイ」を確認します。
復旧が確認できるまで`Diagnostics/recovery.json`は削除しません。
watchdogはOSやDDCの停止、Macの電源断、プロセスの強制終了を超えて復旧を保証するものではありません。

## 保存ファイル

| ファイル | 用途 |
| --- | --- |
| `Diagnostics/config.json` | Dell・保護対象ZOWIE・DDCの固定識別情報 |
| `Diagnostics/observations.jsonl` | 時刻、Dellの実入力ラベル、段階、生DDC応答、エラー |
| `Diagnostics/zowie-probes.jsonl` | ZOWIEの読み取り専用の補助診断。Dell校正とは分離 |
| `Diagnostics/experiments.jsonl` | 一時変更前後、周波数補正、DDC継続、復元の結果 |
| `Diagnostics/recovery.json` | 復旧が必要な変更前の構成 |
| `Diagnostics/last-recovery.json` | 最後に復旧確認した構成 |
| `Reports/` | 今回の実機診断の出力 |

ログはローカル保存のみでネットワーク送信しません。ディスプレイのシリアル番号が含まれます。

## 完全自動化が成立しない条件

HDMI選択中にUSB-C側へDDC応答が返らない／0x60が入力変更に追従しない／両入力が同じ値になる場合、
本体の入力操作をこのDDC経路だけで確実に検出できません。macOSの接続状態は入力の根拠にできません。
無効化でDDCが失われる場合はミラーリングを試しますが、それでも識別できなければ完全自動化はできません。
この場合は手動切替またはショートカット操作への限定が必要です。

アプリではSwiftUIの画面とAppKitのメニューバー、自動監視、手動切替、Carbonのグローバルショートカット、
SMAppServiceによるログイン起動を実装しています。自動監視の有効化は両入力の実機登録完了後に限定しています。
連続一致・切替間隔・スリープ中の停止・復帰猶予・エラー時停止・手動操作優先を備えます。

## 謝辞・ライセンス

DDCの検出には[AppleSiliconDDC by @waydabber](https://github.com/waydabber/AppleSiliconDDC)（MIT）を使用しています。
無効化は[displayplacer](https://github.com/jakehilborn/displayplacer)が使うものと同じCoreGraphics内部APIを、Dellだけに限定して呼び出します。
出典・固定コミット・変更点は[ThirdParty/README.md](ThirdParty/README.md)を参照してください。
