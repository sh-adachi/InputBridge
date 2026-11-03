# 実装可能性の調査・実機診断

調査日：2026-11-03（Asia/Tokyo）。対象：Mac mini M4、macOS 26.6.2、Dell S2725QC、ZOWIE XL2546K（EDID名：ZOWIE XL LCD）。

## 現時点の結論

USB-C選択中の入力値取得と、Dellの無効化・DDC継続・再有効化は実機で成功しました。
その後、ユーザーがSwitchを表示している状態でHDMI入力を測定し、`0x1B11`を取得しました。
HDMI表示中の無効化・DDC継続・再有効化を確認し、自動監視を有効化してMacがZOWIEのみになることを実機で確認しました。
Switch電源オフ後、無効化方式ではDellが信号なし・省電力状態となり、0x60はHDMIの`0x1B11`を返し続けました。
Macの映像出力を戻すとUSB-Cの`0x1B1B`へ復帰しました。無効化がUSB-C信号を止めて復帰を妨げるため、ミラーリング方式へ変更しました。
両入力でミラーリング中のDDC通信、元の配置への復帰、ZOWIE 240 HzとDell 120 Hzの維持を確認しました。
その後、Switchオン→オフでHDMI `0x1B11`→USB-C `0x1B1B`を検出し、アプリが自動で元の拡張配置へ復帰しました。ユーザーもDellのMac表示を確認しました。
`Reports/mirror-poweroff-validation.json`に結果を記録しています。
その後、ユーザーの依頼により常駐アプリを実装しました。手動切替は使用可能です。
自動監視も実装し、有効化はDellのUSB-C・HDMI双方の入力登録と非表示中の通信確認に限定しています。
現在はこのMacで両入力を登録済みで、自動切替はオンです。常駐アプリの使用法はREADMEを参照してください。

## 公開ソースから分かったこと

1. [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)はApple Silicon向けDDCライブラリとASDDC CLIを提供しています。`getvcp --sn SERIAL --terse 0x60`で特定モニターを指定できます。応答をMCCSとして補正せず生バイトで扱う設計です。
2. [displayplacer](https://github.com/jakehilborn/displayplacer)は画面の無効化とミラー構成をサポートします。再有効化にケーブルの抜き差しが必要な構成があると明記しています。ソースの`setEnabled`は非公開の`CGSConfigureDisplayEnabled`を呼びます。
3. [Appleの表示構成トランザクション](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayTransactions.html)では、ミラー設定・位置・モードを変更できます。無効化には別の内部APIが必要になります。
4. [DellのS2725QC公式マニュアル一覧](https://www.dell.com/support/product-details/ja-jp/product/s2725qc-monitor/resources/manuals)を確認しました。ただし、非選択入力で0x60が継続して読めるという保証は今回確認できていません。実機測定が必要です。

公開説明からの一般論と、以下の実測結果は区別しています。将来のOSでも動作するという保証はありません。

## 実機測定の詳細

最初に公式ASDDCをソースからビルドし、Dellの英数字シリアルを明示して読み取りました。
ZOWIEへSetVCPや入力切替は行っていません。後述の補助診断ではGetVCPだけを発行しました。
DDCのGetVCP要求はI2Cのwrite/readを使いますが、SetVCPではありません。

USB-Cの応答：

```text
ASDDC getvcp --sn <Dell serial> --terse 0x60
VCP 60 VALUE 1B 1B 1B 1B

raw: 6E 88 02 00 60 00 1B 1B 1B 1B D4
current = 0x1B1B, maximum = 0x1B1B
```

入力がUSB-Cであることはユーザーに確認しました。新CLIでは応答の構造とチェックサムを検証したうえで5回一致しました。
他入力の値は標準値から推測していません。HDMI端子を変える場合も再校正が必要です。

最初の無効化試験では、Dellがonline表示一覧から消え、UUIDからの解決もできなくなりました。
ZOWIEは表示を続けましたがOSが120 Hzに変更しました。初版の復旧はUUIDの解決を必要としたため失敗しました。
ZOWIEをdisplayplacerで240 Hzへ復元し、DDCが続くことを確認後、保存していたDellの一時IDに有効化だけを適用して復旧しました。

診断CLIを修正し、起動セッションIDを保存して同じOS起動中だけ一時IDでの有効化を許可しました。
ZOWIEの周波数補正処理を追加した再試験では、無効化・DDC継続・元のデュアル構成への復旧が成功しました。
この再試験ではOSによる周波数変動自体が再現せず、ZOWIEは240 Hzを維持しました。
初回に周波数を復元できたのはdisplayplacerによる実測です。新CLIの自動補正分岐そのものは実機ではまだ発動確認していません。
OSが周波数を変更した事実は`protectedTimingAdjusted`として記録し、「一度も変更されなかった」とは報告しません。
すべての無効化要求はDellに対してだけ発行しています。

リリースビルドで、無効化試験の親プロセスをSIGKILLで終了する追加試験も行いました。
独立watchdogが保存構成を使って復旧し、ZOWIEがメイン・240 Hz、Dellが左側・120 Hzに戻ったことを確認しました。
結果は`Reports/watchdog-interruption.json`に保存しています。

ソフトウェア検証：リリースビルド成功。`swift test`で診断・自動判定・復旧監視を検証しています。
応答チェックサム・I2C失敗、安定値の校正、ZOWIEへの対象取り違え、保護画面の条件、
操作の同時実行拒否、DDCヘルパーのタイムアウトを検証しています。
ZOWIEの補助診断がDellのHDMI校正を成立させないことも確認しています。

## ZOWIEのHDMI接続による補助診断

ユーザーの提案により、MacからHDMI接続しているZOWIEで、設定を変えずGetVCP 0x60の読み取りのみを3回行いました。
`probe-zowie`コマンドを追加し、結果はDellの校正用ログから分離しています。

```text
raw: 6E 88 02 00 60 00 00 11 00 11 D4
current = 0x0011, maximum = 0x0011
3回すべてヘッダー・opcode・成功応答・VCP番号・type・チェックサム正常
```

前後のCoreGraphics画面情報は完全に一致しました。ZOWIEは有効なメイン画面・240 Hz、Dellは有効・120 Hzです。
結果は`Reports/zowie-probe-summary.json`と`Diagnostics/zowie-probes.jsonl`に保存しました。

これは「Mac→HDMI→ZOWIEでDDCを読める」という確認です。
元の目的で必要な「Mac→USB-C→Dellで、Dell本体がHDMI選択中でも入力状態を読める」という確認とは異なります。
メーカー・機種・DDC経路・非選択入力への応答条件が違うため、ZOWIEの成功／失敗からDellの可否は確定できません。
両入力間の本体操作への追従、非選択ポートでのDDC継続も、この読み取りだけでは検証していません。

## 成立条件と残る確認

| 確認 | 必要な理由 | 状態 |
| --- | --- | --- |
| USB-C / HDMIで0x60が安定して異なる | 入力ボタン操作を検出する根拠 | USB-C=0x1B1B、HDMI=0x1B11を確認 |
| HDMI選択中にもUSB-CからDDC応答 | macOSが接続扱いでも入力状態を取得する | 成功 |
| 無効化中のDDC | USB-Cへ戻した操作を検出する | 両入力で成功 |
| ミラー方式でSwitchオン→オフ→デュアル復帰 | 実際の用途の往復が成立するか | 成功。入力操作・Macの手動復帰なしで確認 |
| ZOWIEの描画と240 Hzの維持・補正 | 常用画面を保護する | USB-C試験で確認 |
| ミラー方式 | USB-C映像信号とDDCを残し独立作業領域をなくす | 両入力で成功、ZOWIE 240 Hz維持 |
| スリープ、復帰、再接続、再起動 | ID変動・通信の一時失敗・古い状態の対策 | 未確認 |

ミラー方式は「DellをOSから完全に取り除く」方式ではありません。ZOWIEの複製先にして独立した作業領域をなくします。
共通モード選択などでZOWIEの解像度や周波数が変わり得るため、同様に実測が必要です。

## 自動運用への移行設計

実装済みの自動監視は、校正した**完全な16 bit値**を照合し、3回の連続一致後だけ変更します。
通信エラーや未知の値が続く場合は自動監視を停止し、保存したデュアル構成への復旧を試みてエラーを表示します。
画面再構成・スリープ復帰後はDDCサービスを取り直し、猶予時間と再校正条件を設けます。
手動切替後は自動監視をオフにし、ユーザーの操作を上書きしません。
変更後にZOWIEが有効・メインであることを確認し、周波数を補正し、失敗時は保存構成へ復旧します。

常駐中の監視プロセスは親アプリの生存とheartbeatを確認します。親の終了、または35秒を超える応答停止で復旧を試みます。
実機でメニューバーアプリをSIGKILLした場合にも、元のデュアル構成へ戻ることを確認しました（`Reports/app-crash-recovery.json`）。
入力登録中に一時的なDDC Null Replyを確認したため、正常応答が3回連続するまで再確認する方式にしています。
3回連続の読み取り失敗、安定しない値、同一入力値では校正を完了しません。

InputBridgeはApp Store向けのサンドボックスアプリではなく、ローカル配布を想定します。
IOAVServiceおよびCGSの非公開APIを含むため、OS更新の互換性は実機テストで確認する必要があります。
AppleSiliconDDCはMITで無償利用できます。有料BetterDisplayや追加ハードウェアには依存しません。
