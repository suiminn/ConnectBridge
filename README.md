# ConnectBridge

脱獄した iPhone を **Spotify Connect の再生先**として見せ、受けた音声を **AirPlay スピーカー (HomePod など) に流す**ブリッジです。Spotify アプリ (他の端末) の音量操作はスピーカーの音量に反映され、スピーカー本体の音量操作も Spotify 側のスライダーに戻ります。

## 動機

HomePod は Spotify Connect の再生先になれないため、Spotify を HomePod で聴きたくても、スマホやアプリ側から AirPlay を選び直すしかありませんでした。Spotify アプリのデバイス一覧から HomePod に直接再生させたい、という目的で作りました。

```
Spotify アプリ ── Spotify Connect ──▶ [iPhone: librespot] ── AirPlay ──▶ AirPlay スピーカー
                                          ▲  音量の双方向同期  ▲
```

- 動作確認した環境: (1) iPhone 7 / iOS 15.8.4 / Dopamine 系 rootless (`/var/jb`) / HomePod mini 1 台。Sonos Era 100 でも再生と Spotify 側の音量操作が効きました。(2) iPad (第 7 世代) / iPadOS 18.7 / palera1n rootless / HomePod mini: 再生、出力の選択、HomePod 側の音量変更の検出と、一晩の放置まで確認しました (route の解放、AirPlay が切れたときのガードは未確認)。ほかの機種・iOS・スピーカーは未確認です (rootful は非対応)
- 要件: Spotify Premium、iPhone と AirPlay スピーカーが同じ Wi-Fi にいること、PreferenceLoader (設定アプリの項目のため。deb の依存に入っています)

> **はじめに必ず「[注意](#注意)」を読んでください。** 非公式の Spotify クライアントを使うため、Spotify の利用規約に反する可能性があり、自己責任での利用になります。

## しくみ

| 部品 | 役割 |
|---|---|
| `connectbridged` (ObjC, launchd デーモン, `mobile` で実行) | librespot の起動・監視・再起動、出力先を AirPlay スピーカーに固定して見張る |
| `librespot` (Rust, パッチ版) | Spotify Connect のデバイスとして常駐、音量の双方向同期 |
| 設定 | 設定アプリの「ConnectBridge」(PreferenceLoader 経由)。値は設定ドメイン `com.sui827.connectbridge` (`/var/mobile/Library/Preferences/com.sui827.connectbridge.plist`) に保存 |
| データ・ログ | `/var/mobile/Library/ConnectBridge/` (`daemon.log`, `librespot.log`, 認証情報) |

調べた内容と設計の根拠は [docs/spec.md](docs/spec.md) と [docs/poc-results.md](docs/poc-results.md) にあります。

## ビルド

Mac 側に Xcode、[Theos](https://theos.dev/)、`rustup` (`aarch64-apple-ios` ターゲット)、`ldid`、`dpkg` が必要です。**プロジェクトのパスに空白を含めないでください** (Theos が拒否します)。

```bash
source env.sh                     # THEOS / DEVELOPER_DIR / PATH (環境に合わせて編集)
scripts/build-librespot.sh        # librespot を取得 → パッチ適用 → iOS 向けにビルド (build/librespot)
make package FINALPACKAGE=1       # packages/*.deb (rootless)
```

## インストール

```bash
scp packages/*.deb root@<iPhoneのIP>:/var/mobile/
ssh root@<iPhoneのIP> 'dpkg -i /var/mobile/com.sui827.connectbridge_*.deb'
```

インストールすると launchd に登録され、すぐ起動します (再起動後は脱獄し直せば自動で起動します)。

## 使い方

1. 初回だけ、Spotify アプリ (**別の端末**) のデバイス一覧から **「<AirPlay 機器の名前> (via <この iPhone の名前>)」** (例: `HomePod mini (via iPhone)`) を選びます。認証情報が iPhone に保存され、以降は選ぶだけです。
2. 再生するとスピーカーから鳴ります。音量は Spotify 側とスピーカー本体のどちらで変えても同期します。
3. iPhone 自身の Spotify アプリは、同じアカウントなので Connect を奪い合います。この iPhone では使わないでください。

### 設定

設定アプリの「ConnectBridge」で変更します。値を変えると Darwin 通知 (`com.sui827.connectbridge/prefs`) で `connectbridged` に伝わり、librespot の起動条件 (有効・デバイス名・音質・ガード・詳細ログ) が変わったときだけ librespot を作り直します。出力先の名前と解放の待ち時間は、そのまま次の監視から効きます。状態の表示と、「librespot を再起動」ボタン (`com.sui827.connectbridge/restart`) もあります。

plist を直接編集する場合は、`kill -HUP <connectbridged の PID>` で反映します。

| キー | 既定値 | 内容 |
|---|---|---|
| `Enabled` | `true` | `false` で librespot を起動しない (デーモンは生きていて、設定アプリで戻すと起動する) |
| `ConnectName` | (空) | Spotify のデバイス一覧に出る名前。空なら自動で `<AirPlay 機器の名前> (via <この iPhone の名前>)` |
| `OutputDeviceName` | (空) | 出力先の AirPlay 機器の名前。空のあいだは何も起動しません。設定アプリでは、いま見つかっている機器の一覧から選びます (完全一致を優先し、なければ部分一致・大文字小文字無視) |
| `ManageRoute` | `true` | Connect で選ばれている間の出力先の固定と、奪われたときの選び直し |
| `Bitrate` | `160` | `96` / `160` / `320` |
| `AirPlayGuard` | `true` | AirPlay が切れて音が本体スピーカーに移りそうになったら、即座に無音にして一時停止し、戻ったら再開する |
| `GuardResumeSeconds` | `30` | 一時停止から、この秒数以内に AirPlay が戻れば自動で再開する (超えたら一時停止のまま) |
| `ReleaseDelay` | `15` | Connect で選ばれなくなってからスピーカーを解放するまでの秒数 (`0` で即時) |
| `Verbose` | `false` | `true` で librespot の詳細ログ |
| `VolumePolling` | `false` | `true` で、ルートの音量を 250 ms ごとに読む (従来の方式)。`false` では、`outputVolume` の KVO を待って読み、通知が来なくても 5 秒ごとに安全のため確認する。設定アプリには出ません |

> `ManageRoute` が有効なとき、出力先は **Spotify Connect でこのデバイスが選ばれている間だけ** AirPlay スピーカーに固定されます。別のデバイスに移ると、`ReleaseDelay` 秒待って本体スピーカーに戻し、スピーカーを解放します (その間に選び直されたら解放しません)。起動直後は何も掴みません。

### ログ

```bash
tail -f /var/mobile/Library/ConnectBridge/daemon.log      # デーモン (connectbridged)
tail -f /var/mobile/Library/ConnectBridge/librespot.log   # librespot
```

## librespot への変更

[librespot/ios-bridge.patch](librespot/ios-bridge.patch) を、固定したコミット (`99b6088`, 0.8.0) に適用します。

- **OS を `linux` と名乗る**: iOS のままだと、AP の認証・login5・OAuth が拒否されます (issue #1477)。Android に対して upstream がすでに行っているのと同種の処置です。
- **AVAudioSession を有効化**: cpal は iOS でセッションを設定せず、そのままだと無音になります。
- **音量ブリッジ** (`CB_VOLUME_BRIDGE`, `CB_PASSTHROUGH_VOLUME`): Connect の音量値を音声に掛けず、出力先のシステム音量に適用します。逆方向は `outputVolume` の KVO で変化を知り (取りこぼし対策に 5 秒ごとの確認つき)、Connect に送ります (ループ防止つき)。
- **AirPlay ガード** (`CB_REQUIRE_AIRPLAY`): 選択中に出力が本体スピーカー (または受話口) に移ったら、ソフトミキサーの無音フラグで即座に音を止め、一時停止します。AirPlay に戻ったら、設定した秒数以内なら自動で再開します。接続の張り直しは `connectbridged` が行います。
- **Now Playing とリモートコマンド** (`CB_NOW_PLAYING`): 曲名・アーティスト・アルバム・ジャケット・再生位置をシステムの Now Playing に送り、再生/一時停止/次/前/シークのコマンドを Spirc に渡します。MediaPlayer はメインスレッドで run loop が回っていないと動かないため、iOS では tokio のランタイムを別スレッドに移し、メインスレッドを run loop に譲っています。

## ログとプライバシー

- ログは iPhone の中だけに残ります (`/var/mobile/Library/ConnectBridge/daemon.log`, `librespot.log`)。2 MB を超えると、1 時間ごとの確認 (と librespot の起動時) に `.1` へ退避します (退避は 1 世代だけ。librespot の動作中はコピーしてから空にするので、その間の数行が失われることがあります)。外部には送りません。
- 既定では、曲名・アーティスト名はログに出しません。`Verbose` をオンにすると出ます (調査用)。
- ログには、Spotify のユーザー ID (`Authenticated as ...`) と、接続先の Spotify のサーバー名が出ます。問題を報告するときは、貼る前に確認してください。
- データディレクトリ (`/var/mobile/Library/ConnectBridge/`) は `mobile` だけが読める権限 (`0700`) で、保存された Spotify のログイン (`credentials.json`) は `0600` です。

## アンインストール

```bash
dpkg --remove com.sui827.connectbridge   # 設定と保存されたログインは残る
dpkg --purge  com.sui827.connectbridge   # 設定・ログ・保存されたログインも削除する
```

## 既知の制限

- 出力先の AirPlay 接続は `connectbridged` が生きている間だけ保たれます。落ちると スピーカーへの出力は止まり、再起動後に選び直します。
- 音量の変化は、`AVAudioSession.outputVolume` の KVO (公開 API) を待って読みます。`VolumePolling` を `true` にすると、従来の 250 ms ごとのポーリングに戻ります。まだ試験中です (観察用に、ポーリングとの突き合わせも動いています)。`AVSystemController` の通知は、有効な音声セッションがあっても届きませんでした。MediaRemote の `kMRMediaRemotePickedRouteVolumeDidChangeNotification` は iOS 15.8 では届きますが、iPadOS 18.7 では届かないため使っていません。`AVAudioSession.outputVolume` の KVO はどちらでも届くので、これを合図にしています。route 切り替え時などに取りこぼさない保証がないため、ポーリングは残しています (`docs/poc-results.md`)。
- Siri の音声操作 (「次の曲」など) は、Spotify が Now Playing として再生中のときは Spotify に届きます。何も再生していないときは、Siri が操作先を自分で決めるため、Apple Music が開くことがあります。
- 他のアプリ (Siri が開いた Apple Music など) に音声セッションを奪われると、librespot は自動で作り直されます (数秒、Spotify の一覧から一度消えます)。この回復の流れは、まだ十分には検証していません。
- ホストで自動テストしているのは、判断の部分 (`route_policy.h`、`marker.h`、`volume_logic.rs`、`guard_logic.rs`) だけです。MediaRemote / AVFoundation を呼ぶ部分と、librespot への結線は、実機で確かめています。
- リリースの deb には、GitHub の build attestation が付きます (`gh attestation verify <deb> --repo <owner>/<repo>`)。`SHA256SUMS` は同じリリースにあるので、ダウンロードの破損を見つけるためのものです。
- 非公開 API (MediaRemote / AVSystemController) を使うため、iOS のバージョンが変わると動かなくなる可能性があります。
- `connectbridged` は起動時と librespot の起動前に、`mobile` ユーザーの `librespot` のうち、親が launchd のもの (前回のデーモンが残した子プロセス) を終了させます。自分で起動した librespot は、`/var/jb/usr/libexec/connectbridge/librespot` 以外のバイナリであれば対象になりません。

## 注意

- **非公式クライアントです**: ConnectBridge は Spotify とは無関係で、公認も受けていません。Spotify の Connect の仕組みに、非公式のクライアント (librespot) として接続します。Spotify の利用規約に反する可能性があり、アカウントに対して制限などの措置が取られる可能性もあります。Premium アカウントが必要で、**自己責任**でお使いください。
- **iOS を Linux として名乗らせる変更を含みます**: 上の「librespot への変更」のとおり、このパッケージの librespot は、Spotify のサーバーに対して iOS ではなく Linux のクライアントとして接続します。そうしないと、サーバーがログインを拒否するためです。この変更の内容は `librespot/ios-bridge.patch` にそのまま含まれています。これが問題になりうることを理解したうえで使ってください。
- **同名の AirPlay 機器が複数あると、出力先を自動では戻せません**: 同じ名前のスピーカーが 2 台以上見つかり、どれが現在の出力か見分けられないときは、安全のため出力先を戻さずに残します (8 回再試行して諦めます)。機器の名前を変えてください。
- **`librespot` という名前のプロセスを止めます**: 起動時に、`mobile` ユーザーの `librespot` で親が launchd のもの (前回のデーモンが残した子プロセス) を終了します。同じ名前で `nohup` などから自分で起動したものも対象になるので、別の librespot を並行して動かさないでください。
- 認証情報 (`credentials.json`) はパッケージに含まれません。共有しないでください。
- ライセンス: 本プロジェクトは MIT ライセンスです (`LICENSE`、Copyright (c) 2026 suiminn)。無保証で、使用は自己責任です。
- 同梱するサードパーティのライセンスは `THIRD_PARTY_NOTICES` にまとめています (librespot は MIT、ほかに `symphonia` など MPL-2.0 のクレートを改変せずに含みます。ソースの入手先は同ファイルに記載)。deb の `/var/jb/usr/share/doc/com.sui827.connectbridge/` にも入ります。更新は `scripts/gen-third-party-notices.py` で行います。

## ディレクトリ構成

```
daemon/        connectbridged (ObjC) と署名用 entitlements
librespot/     librespot に当てるパッチ
prefs/         設定アプリの「ConnectBridge」(Theos の設定バンドル)
layout/        deb にそのまま入るファイル (launchd plist、postinst/prerm、既定の設定)
scripts/       build-librespot.sh、gen-third-party-notices.py、overnight-check.sh
docs/          仕様書 (spec.md)、PoC の手順と記録
poc/           Phase 0 の調査ツール (audiotest / routetool / dumpclass)
.github/       CI とリリースのワークフロー
Makefile, env.sh               パッケージのビルドと、ビルド環境の設定
LICENSE, THIRD_PARTY_NOTICES   本体のライセンスと、同梱するサードパーティの表記
```
