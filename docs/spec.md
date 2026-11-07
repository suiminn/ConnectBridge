# Spotify Connect → AirPlay ブリッジ tweak 仕様 (v0.1)

> **これは開発開始時の仕様書です。** 実装は一部ここから変わっています。現在の動作は [README](../README.md) と、末尾の「[実装との差分](#実装との差分-v01-時点)」を見てください。

名称: **ConnectBridge**

## 1. 目的

HomePod は Spotify Connect の再生先にならない。脱獄した iPhone を Connect の再生先として見せ、受けた音声を AirPlay で HomePod に流す。Spotify アプリ側(スマホ・PC・車など)の音量操作を HomePod の音量に反映する。

## 2. 前提・スコープ

| 項目 | 内容 |
|---|---|
| 端末 | iPhone 7 (A10) / iOS 15.x |
| 脱獄 | Dopamine 系 rootless (`/var/jb` の実体は `/private/preboot/.../dopamine-*/procursus`)。palera1n ではない |
| 出力先 | HomePod 1台 (ステレオペア・グループは対象外) |
| Spotify | Premium 必須 |
| 配布 | まず自分用。将来 Sileo 経由の公開を視野に入れる |

### スコープ外 (v1)
- 複数 HomePod、AirPlay 2 グループ
- ロスレス
- 公式 Spotify アプリのフック
- Spotify 以外のサービス

## 3. 方針の決定事項

1. **Spotify クライアントは librespot を直接組み込む。** 公式アプリはフックしない。公開時の規約リスクと、更新で壊れるリスクを避けるため。
2. **出力は案A**: librespot が iOS の通常の音声経路で再生し、tweak 側で出力ルートを HomePod に固定する。
3. **librespot 内部の音量は 100% 固定** (passthrough)。Connect の音量は HomePod のルート音量に変換する。
4. **認証はキャッシュ済みの資格情報 + クラウド経由**を基本とする。ロック中の Wi-Fi スリープでも、mDNS に依存せずデバイス一覧に出るようにするため。

## 4. アーキテクチャ

```
Spotify アプリ (他端末)
        │ Spotify Connect (cloud / dealer)
        ▼
┌───────────────────────────── iPhone 7 ──────────────────────────────┐
│ librespot-bridge (Rust)                                              │
│   ・Connect デバイスとして常駐                                          │
│   ・PCM を CoreAudio (cpal) に出力                                      │
│   ・イベントを JSON Lines で stdout へ (volume/play/pause/track)          │
│   ・制御コマンドを stdin から受ける (set_volume/play/pause/next)          │
│        ▲ │                                                            │
│        │ ▼                                                            │
│ connectbridged (ObjC, launchd デーモン)                                 │
│   ・librespot-bridge の起動・監視・再起動                                  │
│   ・HomePod の探索 (Bonjour) と出力ルート固定                              │
│   ・音量の双方向同期                                                     │
│   ・Now Playing 情報とリモートコマンドの橋渡し                              │
│        │ private API (MediaRemote / AVSystemController など)           │
│        ▼                                                              │
│  AirPlay ──────────────────────────────────────────▶ HomePod          │
│                                                                       │
│ ConnectBridgePrefs (Preferences bundle)                                │
│   ・対象 HomePod、表示名、ビットレート、ログイン、有効/無効                     │
└───────────────────────────────────────────────────────────────────────┘
```

### コンポーネント

| 名前 | 言語 | 役割 |
|---|---|---|
| `librespot-bridge` | Rust (`aarch64-apple-ios`, 最低 iOS 15) | Connect デバイス、デコード、PCM 出力、イベント/コマンド IPC |
| `connectbridged` | Objective-C (Theos, rootless) | 監視、ルート制御、音量同期、Now Playing |
| `ConnectBridgePrefs` | Objective-C | 設定 UI |
| launchd plist | - | `/var/jb/Library/LaunchDaemons/` に配置し、起動時に常駐 |

IPC は最初は stdin/stdout の JSON Lines。設定の受け渡しは plist (`/var/jb/var/mobile/Library/Preferences/`) + Darwin notification。

## 5. 機能要件

### 5.1 Connect 再生先
- Spotify のデバイス一覧に設定した名前で表示される。
- 他端末から選んで再生、一時停止、スキップ、シークができる。
- 再生先を選んだ時点で、出力ルートが HomePod になっていなければ切り替える。

### 5.2 音量
- Connect 側の音量 (0〜65535) → HomePod のルート音量 (0.0〜1.0) に変換する。
- HomePod 側 (本体操作、Siri) の音量変更 → Connect 側の音量に反映する。
- ループ防止: 自分が発行した変更を一定時間無視する。
- 起動時と再生開始時に、現在の HomePod 音量を Connect に同期する。

### 5.3 Now Playing / リモート操作
- タイトル、アーティスト、アートワークを `MPNowPlayingInfoCenter` 相当で設定する。
- HomePod の操作 (タップ、「一時停止して」) を librespot に伝える。

### 5.4 運用
- 起動時に自動で常駐し、クラッシュしたら自動で再起動する。
- HomePod が見つからない、切れた場合は、再生を一時停止して再接続を試みる。
- ログは `/var/mobile/Library/ConnectBridge/` に置く (ローテーション付き)。

## 6. 非機能要件
- 常時充電を前提に、アイドル時の CPU を最小にする。
- 認証情報はキャッシュファイルに保存し、権限は 0600 にする。
- リポジトリや配布パッケージに資格情報を含めない。

## 7. 技術リスクと検証項目 (最優先)

実装前に実機の最小 PoC で確認する。ここで成立しなければ設計を変える。

| # | 検証 | 失敗時の代替 |
|---|---|---|
| R1 | launchd デーモンから CoreAudio で再生できるか (ロック中・バックグラウンド) | AudioSession を持つ補助プロセス、または SpringBoard にロードされる tweak 側で再生 |
| R2 | プライベート API で出力ルートを HomePod に固定できるか (iOS 15) | 案B (自前 RAOP/AirPlay 2 センダー) |
| R3 | HomePod のルート音量を取得・設定できるか (`AVSystemController`, MediaRemote 系の候補) | 音量はルートでなくシステム音量経由にする |
| R4 | librespot が `aarch64-apple-ios` でビルドでき、iPhone 7 で動くか | 該当バージョンを固定、依存を調整 |
| R5 | ロック中でも Wi-Fi が維持され、クラウド経由でデバイスが見えるか | keepalive、Low Power の無効化 |
| R6 | 音量の双方向同期でループ・揺れが起きないか | デバウンスと抑制時間を調整 |

使う private API 名は候補であり、iOS 15 で実際に使えるかは未確認。

## 8. 開発ステップ

1. **Phase 0 (PoC)**: R1〜R5 を最小コードで確認する。
2. **Phase 1**: `librespot-bridge` の iOS ビルド、Connect 再生、イベント/コマンド IPC。
3. **Phase 2**: `connectbridged` でルート固定と音量の一方向同期 (Connect → HomePod)。
4. **Phase 3**: 双方向同期、Now Playing、リモート操作、再接続処理。
5. **Phase 4**: Preferences bundle、パッケージング (Sileo 用 deb、rootless)。
6. **Phase 5 (公開する場合)**: ライセンス整理、README、免責、資格情報の扱いの見直し。

## 9. 公開時の注意
- librespot は MIT。同梱時はライセンス表記を入れる。
- Spotify の規約上グレーである旨を README に明記する。Premium 必須、自己責任と書く。
- 認証方式は Spotify 側の変更で壊れる可能性がある。
- 脱獄は再起動で外れ、再度の脱獄操作が必要になる(Dopamine でも同様)。再起動後は常駐が止まることを注意書きに入れる。
- 公式アプリのバイナリや Spotify の資産は含めない。

## 10. 未決事項
- 認証方式: OAuth、zeroconf、キャッシュ済み資格情報のどれを初回ログインに使うか。
- デバイス表示名の既定値。
- 音量カーブ (線形か対数か)。
- 再生先選択時に HomePod への切り替え通知を出すか。

---

## 実装との差分 (v0.1 時点)

PoC の結果を受けて、実装は仕様書 v0.1 から次の点が変わっています。詳細は `docs/poc-results.md`。

- **プロセス構成**: `connectbridged` が librespot を `posix_spawn` で起動・監視する(JSON Lines の IPC は無し)。音量の同期は librespot の中に組み込んだ(`src/volume_bridge.rs`)ため、`connectbridged` は音量に関与しない。
- **AirPlay ガード**: 選択中に出力が本体スピーカーへ移ったら、即座に無音にして一時停止し、AirPlay が戻ったら再開する (librespot 内)。
- **ルートの保持**: Spotify Connect でこのデバイスが選ばれている間だけ HomePod を掴み、選ばれなくなって `ReleaseDelay` 秒 (既定 15) 後に解放する。librespot の `SessionConnected` / `SessionDisconnected` を状態ファイル経由でデーモンに伝える。
- **ルート制御**: `MPAVRoutingController` ではなく MediaRemote の MRAV 系 (`MRAVRoutingDiscoverySession`、`MRAVOutputContext`) を使う。ルートを選んだプロセスが生きている間だけ AirPlay が保たれ、外部要因で奪われるため、3 秒ごとに確認して選び直す。
- **音量**: `AVSystemController` の `Audio/Video` カテゴリを 250 ms 間隔でポーリング。通知は届かなかった。
- **脱獄環境**: palera1n ではなく Dopamine 系。
- **librespot**: iOS を `linux` と名乗らせるパッチと、AVAudioSession の有効化が必須。名乗りのパッチは配布物に含める(2026-11-04 に決定)。README の注意に、規約上のリスクとアカウントへの影響の可能性を明記している。
- **署名**: `platform-application` と `com.apple.private.security.no-container`。シェルスクリプトを直接 spawn することはできない。
- **Now Playing / リモートコマンド**: 実装済み(librespot 内)。MediaPlayer はメインスレッドの run loop が必要。コントロールセンターと Home Assistant の操作は動作確認済み。Siri の音声操作は、Spotify の再生中は Spotify に届く (確認済み)。何も再生していないときは Siri 側の判断で Apple Music が開くことがある。
- **設定 UI**: 設定アプリの「ConnectBridge」(PreferenceLoader + 設定バンドル、英語のみ)。AirPlay 機器は、デーモンが見つけた機器の一覧 (`AvailableOutputDevices`) から選ぶ。Spotify 上のデバイス名は、空なら `<AirPlay 機器の名前> (via <iPhone の名前>)` を自動で付ける。値は CFPreferences 経由で読み、変更は Darwin 通知で知らせる。状態は `RuntimeState` として同じドメインに書き出す。
- **未実装**: 一晩放置の検証。
