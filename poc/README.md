# Phase 0 の調査ツール

`docs/poc.md` と `docs/poc-results.md` で使ったツールです。パッケージには含まれません。
Theos でビルドし、実機の `/var/mobile/poc/` に置いて、`entitlements.plist` で署名します (`ldid -Sentitlements.plist <bin>`)。

| ツール | 内容 |
|---|---|
| `audiotest/` | AVAudioSession + AVAudioEngine で 440 Hz のサイン波を鳴らす (ルート変更のログつき) |
| `routetool/` | `mrav` で AirPlay 機器の一覧・選択・保持、`sysvol` でシステム音量 |
| `dumpclass/` | 実機のクラスとメソッドを列挙 (`FILTER=...` で絞り込み) |
| `onevent.sh` | `--onevent` 用の音量フック (旧方式。`/var/jb/bin/sh onevent.sh` の形で呼ぶこと) |

注意: シェルスクリプトを直接 `posix_spawn` すると EPERM になります。
