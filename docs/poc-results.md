# PoC 結果

開発中の調査記録です (時系列のメモなので、途中の失敗や方針変更も残しています)。最終的な構成と使い方は [README](../README.md) と [spec.md](spec.md) の末尾を見てください。

## 環境 (確認済み)
- iPhone 7 (iPhone9,1), iOS 15.8.4 (19H390), Dopamine 系 rootless (`/var/jb`)
- SSH: `mobile@<ip>` に公開鍵で接続可。`/var/jb/usr/bin/ldid` あり (Link Identity Editor 2.1.5-procursus7)
- Mac: Theos (`~/theos`), Rust 1.99.1 + `aarch64-apple-ios`, Xcode 26.6 の SDK (`env.sh` 参照)
- Theos は空白を含むパスでビルド不可。PoC のコードは空白のないパスで作る
- Theos の出力は `.theos/obj/debug/<name>`

## 署名の知見 (重要)
Mac の Theos が付ける署名と、デバイス上の `ldid -S` の署名は、どちらも起動直後に SIGKILL (exit 137) された。

| 署名 | 結果 |
|---|---|
| `ldid -S` (ad-hoc, entitlements なし) | 137 |
| `ldid -Cadhoc -S` | 137 |
| 未署名 | 137 |
| `ldid -S<plist>` (`platform-application` と `com.apple.private.security.no-container`) | 起動 OK |
| 上に `-Cadhoc` を足したもの | 起動 OK |

このあと、実行ファイルには必ず上の entitlements を付けて署名する。
Theos 側は Makefile の `<name>_CODESIGN_FLAGS = -Sent.plist` で付けられるはず (未検証)。

## Step 1 (R1): 音が出るか
- `audiotest` (AVAudioSession Playback + AVAudioEngine のサイン波) は `mobile` ユーザーで起動し、5秒再生して正常終了した。
- 出力ルートは `Speaker` (本体スピーカー)。
- 聞こえた (本体スピーカー)。
- ssh を切断しても鳴り続けた (nohup で切り離して起動)。
- 画面ロック中も鳴り続けた (90秒再生、ロック後も継続)。
- `mobile` からは launchd を使えない: `launchctl submit` は exit 126、`bootstrap user/501` は 112、`bootstrap gui/501` は 125、`load` は Operation not permitted。
- root への SSH 公開鍵ログインが可能になった (`ssh root@<ip>`)。
- launchd (root, `/var/jb/Library/LaunchDaemons/cb.audiotest.plist`, `launchctl load`):
  - バイナリが `/var/mobile/poc/` にあると起動に失敗する (LastExitStatus=19968 = 78<<8、プロセスは作られず `lt.err` も空)。`UserName` の有無は無関係。
  - `/var/jb/usr/local/libexec/audiotest` (root:wheel) に置くと起動し、AVAudioSession と再生まで進んだ (ログで確認)。
  - root 直接実行でも再生は正常終了。
- launchd (root) 起動の音も聞こえ、画面ロック中も鳴り続けた。
- テスト用デーモン (`cb.audiotest`) は unload して plist を削除済み。バイナリは `/var/jb/usr/local/libexec/audiotest` に残している。
- 未確認: `UserName=mobile` での起動 (置き場所修正後は未試験)。

**R1 判定: 合格** (launchd 常駐 + ロック中再生)。

## Step 2: API の存在確認 (iOS 15.8.4 で `dumpclass` により実機で列挙)
`dlopen` は MediaRemote / MediaPlayer / AVFoundation / Celestial すべて成功 (mobile ユーザー、platform-application 署名)。

**ルート切り替えの候補 (存在を確認)**
- `AVOutputContext`: `+sharedSystemAudioContext`, `+defaultSharedOutputContext`, `-outputDevices`, `-setOutputDevice:options:completionHandler:`, `-setOutputDevices:options:completionHandler:`, `-volume` / `-setVolume:` / `-canSetVolume`
- `AVOutputDevice`: `+sharedLocalDevice`, `-setVolume:`, `-canSetVolume` (名前や ID のプロパティは未列挙)
- `MPAVRoutingController`: `-fetchAvailableRoutesWithCompletionQueue:completionHandler:`, `-availableRoutes`, `-setDiscoveryMode:`, `+setActiveRoute:completion:`, `+setActiveRoute:reason:completion:`, `+getActiveRouteWithCompletion:`, `+systemRoute`, `-airtunesRouteIsPicked`, `-removePickedRoute:completion:`
- MediaRemote の関数: `MRMediaRemoteCopyPickableRoutes` と `MRMediaRemoteSetPickedRouteWithPassword` は存在。`MRMediaRemoteSetOutputDevice`, `MRMediaRemoteGetPickableRoutes`, `MRMediaRemoteSetVolume`, `MRMediaRemoteSetOutputDeviceVolume` は存在しない

**音量の候補 (存在を確認)**
- `AVSystemController`: `+sharedAVSystemController`, `-setVolumeTo:forCategory:`, `-getVolume:forCategory:`, `-setActiveCategoryVolumeTo:forRoute:andDeviceIdentifier:`, `-setVolumeForRouteTo:forCategory:mode:route:deviceIdentifier:andRouteSubtype:`, `-getVolumeForRoute:forCategory:mode:route:deviceIdentifier:andRouteSubtype:`, `-currentRouteHasVolumeControl`
- `AVOutputContext` / `AVOutputDevice` の `-setVolume:` も候補

**未確認 (Step 3・4 で試す)**: `MPAVRoute` と `AVOutputDevice` のプロパティ (名前・ID)、HomePod が実際に一覧に出るか、音量通知の名前。

## Step 3 (R2): ルート切り替え — 途中経過
`routetool` (`list` / `pick <name>` / `local` / `mr`) を作成し、実機に配置 (`/var/mobile/poc/routetool`, platform-application 署名)。
- `MPAVRoutingController` (`initWithName:` + `setDiscoveryMode:` 1/2/3 + 待機 10 秒 + `fetchAvailableRoutes...`) では、ルートは本体の `iPhone` (device route) の1件だけ。HomePod が出ない。mobile でも root でも同じ。
- `MRMediaRemoteCopyPickableRoutes` はコールバックが返らない (10秒待って無出力、exit 0)。引数の型が合っていない可能性もある。
- Mac の `dns-sd -B _airplay._tcp` では `HomePod mini` が見えている (同一ネットワークに存在)。
- 仮説: (a) 検出に必要な entitlement が足りない (SpringBoard の ldid -e からは決め手が見つからなかった)、(b) iPhone 側が HomePod を検出できていない (Wi-Fi/サブネット)、(c) 引数の型の誤り。
- 切り分けのため、iPhone のコントロールセンターで HomePod が出るかをユーザーに確認する。

### Step 3 続き: 低レベル MRAV 経路で HomePod を検出・切り替え (成功の兆候)
- コントロールセンターには HomePod mini が出る (ユーザー確認)。→ システムは検出できている。
- `no-sandbox` entitlement を足しても、`MPAVRoutingController` の routeTypes / discoveryMode を変えても、`MPAVRoute` 経由では iPhone の1件しか出なかった。
- 代わりに **MediaRemote の MRAV 系**で検出できた:
  - `+[MRAVRoutingDiscoverySession discoverySessionWithEndpointFeatures:]` (features=0x1) → `-setDiscoveryMode:1` → 約5秒待つ → `-availableOutputDevices`
  - 結果: 近くの AirPlay 機器 (スピーカー、Mac など)、`Speaker` (本体)、`HomePod mini` (uid は UUID 形式)。features=0xffffffff だと本体と MacBook Air が欠ける。0x2・0x4 は不適
  - `MRAVOutputDevice` は `name`, `uid`, `volume`, `setVolume:`, `isVolumeControlAvailable` を持つ。この時点の `volume` は 0.000、`isVolumeControlAvailable` は 0 (HomePod 未選択時)
- 切り替え: `+[MRAVOutputContext sharedSystemAudioContext]` → `-setOutputDevices:withCallbackQueue:block:` に `@[HomePod]` を渡す。`audiotest` 再生中に実行して completion err=NULL、`outputDevices` が `HomePod mini` になった。`Speaker` に戻すのも同じ方法で成功
- 未確認: 実際に HomePod から音が出たか (ユーザーの耳で確認待ち)。ロック中でも切り替わるか。音量 (Step 4)。
- コマンド: `routetool mrav` (一覧)、`routetool mrav pick <名前>`、`routetool mrav vol <名前> <0..1>`。環境変数 `F`=features、`M`=mode

### Step 3 続き: HomePod から音が出なかった原因の調査
- `routetool mrav pick HomePod` は完了コールバック err=NULL でコントロールセンターにも反映されるが、**音は出なかった**。
- `audiotest` に `AVAudioSessionRouteChangeNotification` とルート定期ログを足して調べた:
  - `routetool` が pick 直後に終了する場合: audiotest の AVAudioSession の出力ルートは**空 `()`** になり、HomePod が AirPlay ポートとして現れない (エンジンは running のまま)。
  - `routetool` を `HOLD=25` で pick 後も生かしたままにした場合: audiotest の出力ルートは `"HomePod mini"` になった (route change reason=1 → 約30秒後 reason=4)。
- → 出力先を選んだプロセスが終了すると AirPlay 接続も保たれない。**ルート制御を担うプロセスは常駐させる必要がある** (connectbridged の設計要件)。
- `AVSystemController` による音量: 取得・設定とも成功 (HomePod 選択時 0.254 → 0.5 に設定し読み戻しも 0.500)。経路ごとに値が違う。
- **HomePod から音が聞こえた** (ルート制御プロセスを生かしたままにした場合)。**R2 判定: 合格** (条件: ルートを選んだプロセスを常駐させる)。

## Step 4 (R3): 音量
- `routetool mrav pick HomePod` に `WATCH=1` を付けると、選択後も常駐し、`AVSystemController getActiveCategoryVolume:andName:` を 0.25 秒間隔でポーリングし、`STEPS` の値を `STEPSEC` 秒おきに `setVolumeTo:forCategory:` で設定する。
- 設定→読み戻し: 0.15 / 0.50 / 0.15 / 0.50 を設定し、いずれも 0.2〜0.3 秒後に同じ値が読み戻せた (HomePod 選択時)。
- 通知の購読: `setAttribute:@[AVSystemController_SystemVolumeDidChangeNotification] forKey:AVSystemController_SubscribeToNotificationsAttribute` は `unsupported attribute` (OSStatus -50) で失敗。属性名の特定、または別の方法が必要。当面はポーリングで代替できる。
- 脱獄環境は **Dopamine 系**であることをユーザーが確認 (palera1n ではない)。spec.md を更新済み。
- 未確認: 設定した音量が HomePod の実際の音量に反映されたか (ユーザーの耳)。HomePod 側の操作が `getActiveCategoryVolume` に反映されるか。
- 設定→HomePod: 音量が実際に変わった (ユーザー確認)。
- HomePod→iPhone: HomePod 本体の操作に追従して、`getActiveCategoryVolume:andName:` のポーリング値が変化した (0.500 → 0.200 → 0.250 → 0.400 → 0.550 → 0.300 → 0.400)。変化は操作から 0.25 秒間隔のポーリング以内に検出できた。通知購読は不要。
- **R3 判定: 合格** (ポーリングによる双方向)。通知を使いたい場合は別途調査 (任意)。

### Step 4 続き: 音量変更の通知
- dyld cache から `AVSystemController_*` の文字列を抽出 (133件)。購読用の属性は `AVSystemController_SubscribeToNotificationsAttribute` ではなく **`AVSystemController_NotificationsToRegisterAttribute`** が受理された (`setAttribute:forKey:error:` が ok=1)。通知名候補: `..._SystemVolumeDidChangeNotification`, `..._EffectiveVolumeDidChangeNotification`、パラメータ `AudioVolumeNotificationParameter`, `AudioVolumeChangeReasonNotificationParameter`, `AudioCategoryNotificationParameter`。`AppWantsVolumeChangesAttribute` も YES に設定できた。
- ただし、`routetool` で購読しても **通知は一度も届かなかった** (HomePod 選択時・本体スピーカー時とも、`name:nil` の全通知監視でも `AVSystemController*` は0件)。ポーリングでは値が変わっていることを確認済み。原因は未特定 (CLI プロセスにはデリバリされない可能性、ランループの条件など)。
- 代替として **`AVAudioSession.outputVolume` の KVO** (公開API) を `audiotest` に入れて試した。HomePod 選択中に、HomePod 側の操作と思われる変化 (0.2 → 0.25 → 0.4 → 0.5 → 0.55 → 0.5) が KVO で通知された。ただし、同時に別プロセスから `setVolumeTo` していたため、どの変化が手動操作かの切り分けは厳密にはできていない。
- 結論: 通知は **ポーリング (`AVSystemController`) か `outputVolume` KVO** で実装する。librespot プロセスは AVAudioSession を持つので KVO は使いやすい。AVSystemController の通知は保留。

### Step 4 続き: 音声セッションがあれば通知は届くか (2026-11-05 再調査)
- 仮説: `routetool` には音声セッションがなかったので、通知が届かなかったのではないか。
- 実験: `audiotest` に `AVSYSCTL=1` を足した (`AMP=0` で無音)。有効な `AVAudioSession` (Playback) を持つプロセスで、`AppWantsVolumeChangesAttribute` と `NotificationsToRegisterAttribute` (`SystemVolumeDidChange` / `EffectiveVolumeDidChange` / `ActiveAudioRouteDidChange`) を設定 (どちらも ok=1)。`name:nil` で `AVSystemController*` を全部監視し、`getActiveCategoryVolume` のポーリングと `outputVolume` の KVO を並べて記録した。HomePod mini を選んだ状態で、HomePod 本体と iPhone の音量ボタンで約 30 秒操作した。
- 結果: **`AVSystemController` の通知は 0 件**だった (有効な音声セッションがあっても同じ)。一方、`outputVolume` の KVO は操作のたびに発火した (24 回)。ポーリングの値と一致し、KVO のほうが 0〜0.2 秒早かった。
- 結論: 通知は引き続き使えない。**`outputVolume` の KVO は、このデバイスでは信頼できるイベント源**。ただし、ポーリング (250 ms) で足りていて困っていないので、実装は変えていない。変えるなら、KVO を「すぐ読む合図」に使い、ポーリングは残す (セッションが無効なときに KVO は来ない可能性があるため)。
- 注意: どの変化が HomePod 本体の操作で、どれが iPhone のボタンかは、記録からは切り分けていない。

### Step 4 続き: MediaRemote の音量通知 (2026-11-05)
- 手がかり: `MPVolumeController` は、`MPVolumeControllerRouteDataSource` が `_routeVolumeDidChangeNotification:` で受けた通知を元に、ルートの音量を伝えている (`dumpclass` で確認)。dyld cache の文字列から、MediaRemote 側の通知名の候補を拾った (`kMRMediaRemotePickedRouteVolumeDidChangeNotification`、`MRAVOutputContextVolumeDidChangeNotification`、`kMRAVEndpointVolumeDidChangeNotification` など)。
- 実験: `audiotest` に `MRVOL=1` を足した。`MRMediaRemoteRegisterForNowPlayingNotifications` を呼び、名前に "Volume" を含む通知 (`AVSystemController*` 以外) をすべて記録し、`MRAVOutputContext.volume` のポーリングと並べた。HomePod mini を選んだ状態で、HomePod 本体と iPhone の音量ボタンを操作した。
- 結果: **`kMRMediaRemotePickedRouteVolumeDidChangeNotification` が、音量が変わるたびに届いた** (`_MPMediaRemotePickedRouteVolumeDidChangeNotification` も同時に)。`outputVolume` の KVO 8 回に対して 8 回で、取りこぼしはなく、KVO の 15〜25 ms 後に届いた。`userInfo` の `kMRMediaRemotePickedRouteVolumeUserInfoKey` に、新しい音量が入っている (システム音量と同じ値)。
- `MRAVOutputContext.volume` は 0.000 のまま動かず、使えない。`AVSystemController` の通知は、この実験でも 0 件。
- 通知に必要なのは、`MRMediaRemoteRegisterForNowPlayingNotifications` の呼び出しと、通知センターへの登録だけ。librespot は、すでに MediaRemote を使っている (Now Playing)。
- 注意: HomePod 本体と iPhone のボタンのどちらの操作かは、通知から区別していない。変化の刻みが 0.05 と 0.0625 の 2 種類あり、どちらにも通知が来た。

### Step 4 続き: librespot の中での比較 (2026-11-05)
- `CB_VOLUME_NOTIF_CHECK=1` (connectbridged が付ける) で、librespot が通知を受け、250 ms のポーリングが見つけた変化と突き合わせる (観察のみで、動作は変えない。KVO が安定したと確認できたので、このコードは削除した)。変化と通知は、前後 1 秒以内なら対応しているとみなす。
- 実機 (iPhone 7 + HomePod mini): iPhone の音量ボタン、HomePod 本体の操作、コントロールセンターでの出力切り替え (iPhone 本体 → HomePod) を試して、変化 11 回に通知 11 回、取りこぼし 0、余分 0。
- 残り: 一晩のあとも通知が届くか (`docs/overnight-test.md` の手順 4)。

### Step 4 続き: iPad (iPadOS 18.7, palera1n) の音量通知 (2026-11-05)
- iPad 7 (iPad7,12) / iPadOS 18.7 / palera1n rootless / HomePod mini で、同じ実験をした。
- **MediaRemote の `kMRMediaRemotePickedRouteVolumeDidChangeNotification` は届かなかった** (名前に "Volume" を含む通知は、MediaRemote、`AVSystemController` とも 0 件)。`AVAudioSession.outputVolume` の KVO と、`AVSystemController` のポーリングは、同じ変化を捉えた (5 回とも)。
- 通知だけの版 (観察用の突き合わせつき) を iPad に入れたときの集計は `changes=10 notifications=0 missed=10`。つまり、通知だけでは iPadOS 18.7 で音量を取りこぼす。
- 対応: 合図を `outputVolume` の KVO に揃えた (MediaRemote の通知は使わない。iPhone では両方が来るが、iPad では KVO だけ)。iPad で `changes=6 notifications=12 missed=0 extra=2` (KVO が 1 回の変化で 2 回発火することがあり、通知の数は変化の数の約 2 倍。余分な 2 件は、読んでも変化が無かっただけで害はない)。

## Step 5 (R4): librespot を iOS で動かす
- librespot 0.8.0 (git `99b6088`, 2026-10-21) をクローン。ビルド:
  `IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --release --target aarch64-apple-ios --no-default-features --features "native-tls,rodio-backend,with-libmdns"` → 約1分16秒で成功。バイナリは約15MB、Mach-O arm64、minos 15.0。
- `ldid -Sent.plist` で署名し、`/var/mobile/poc/librespot` に配置して `mobile` で実行 → `--version`・`--help` とも動作。
- zeroconf モードで起動 (`--name "CB Test" --cache /var/mobile/poc/cache --backend rodio`):
  - Zeroconf サーバーが 0.0.0.0:49426 で待ち受け、`Using Rodio sink ... cpal host: CoreAudio`、`Rodio sink was created` まで進んだ。
  - `libmdns::fsm` が `No route to host (code 65)` を警告 (一部インターフェースへの送信失敗の可能性)。
- 未確認: Spotify アプリのデバイス一覧に出るか / 認証 / 再生 / 音が出るか。

### Step 5 続き: 認証と再生 (R4 合格)
librespot を iPhone で Spotify Connect の再生先として動かし、**本体スピーカーから再生できた (ユーザー確認)**。そこに至るまでに必要だった librespot の改造 (ローカルの作業コピー、`git diff` で確認可能):
1. **OS を Linux と名乗らせる**: `core/src/config.rs` の `OS` (iOS のとき "linux")。`core/src/connection/handshake.rs` の `platform_for` も `"ios"` を Linux ARM 扱いに。
   - 症状: iOS のままだと、zeroconf で受け取った認証情報で AP 認証は通るが、次の login5 が `INVALID_CREDENTIALS`、OAuth は iOS 用クライアントID (`58bd3c95…`) のため `redirect_uri: Not matching configuration`。
   - 参照: librespot issue #1477 (「Tried too many access points on iOS」)、config.rs のコメント (iOS/Android を名乗る場合の注意)。Android に対しては upstream が同じ種類のなりすましをすでに行っている。規約上のグレーさが増す変更なので、公開時は扱いを再検討すること。
2. **AVAudioSession を有効化**: cpal は iOS で AVAudioSession を設定しない。`src/ios_audio_session.m` (Playback + setActive) を `build.rs` (cc) でコンパイルし、`main()` の先頭で呼ぶ。これがないと再生中でも無音。
- ビルド: `IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --release --target aarch64-apple-ios --no-default-features --features "native-tls,rodio-backend,with-libmdns"`
- キャッシュした認証情報は `--cache` で再利用され、再起動後も再ログイン不要 (確認済み)。
- **R4 判定: 合格**。

## Step 7: 結合 PoC (Connect → HomePod): 合格
構成: `routetool mrav pick HomePod` を `WATCH=1 HOLD=900` で常駐させて出力先を HomePod に固定 + librespot (`CB_PASSTHROUGH_VOLUME=1`、`--onevent "/var/jb/bin/sh /var/mobile/poc/onevent.sh"`)。
- Spotify アプリから「CB Test」に再生 → **HomePod から音が出た** (ユーザー確認)。
- Spotify アプリの音量スライダー → `volume_changed` イベント (0..65535) → `onevent.sh` → `routetool sysvol <0..1>` → **HomePod の音量が変わった** (ユーザー確認)。
- librespot の `SoftVolume` を `CB_PASSTHROUGH_VOLUME` でパススルーにして、音声は絞らず Connect の音量値だけを外へ渡す (パッチ済み)。
- 詰まった点: `--onevent` に**シェルスクリプトを直接指定すると `posix_spawn` が EPERM** (shebang のスクリプトが直接 spawn できない)。署名の entitlement (`no-sandbox` 等) は無関係。`/var/jb/bin/sh <script>` の形なら起動できる。署名済みバイナリや `/var/jb/usr/bin/*` は直接 spawn できる。
- **R6 (ループ防止) は未着手**: HomePod→Connect 方向の反映 (librespot への set_volume) はまだ。

## 判定 (Phase 0 時点)
| リスク | 結果 |
|---|---|
| R1 常駐プロセスの再生 (ロック中・launchd) | 合格 |
| R2 コードで HomePod にルート固定 | 合格 (ルートを選んだプロセスを常駐させる条件) |
| R3 音量の双方向 (ポーリング / outputVolume KVO) | 合格 |
| R4 librespot の iOS 動作 | 合格 (OS 名乗りの変更と AVAudioSession の有効化が必要) |
| R5 一晩放置 (ロック中の可視性) | 未検証 |
| R6 双方向同期のループ防止 | 未検証 (Phase 3) |

## 音量ブリッジ (librespot 内蔵) — 双方向: 成功 (R6 の基本形)
`src/volume_bridge.rs` + `ios_audio_session.m` の `cb_get/set_system_volume` を librespot に追加。環境変数 `CB_VOLUME_BRIDGE=1` と `CB_PASSTHROUGH_VOLUME=1` で有効。外部スクリプト (`--onevent`) も別プロセスの `routetool sysvol` も不要。
- Connect → ルート: `PlayerEvent::VolumeChanged` を別スレッドで受け、システム音量 (`Audio/Video`) に適用。
- ルート → Connect: メインループの 250ms ティックで `getVolume:forCategory:@"Audio/Video"` をポーリングし、適用済みの値から ±0.015 を超える変化で、かつ適用から 1.5 秒経過していれば `Spirc::set_volume` に送る。
- ログで双方向を確認 (HomePod 本体の操作 → `route 0.186 -> connect 12189`、Spotify のスライダー → `connect 22863 -> route 0.349`)。ユーザーも「成功した」と報告。
- 注意:
  - `getActiveCategoryVolume` を使うと、アクティブなカテゴリが `FindMyPhone` などに切り替わって 1.0 を返し、値が揺れる。カテゴリ固定 (`Audio/Video`) で読むこと。
  - ルート→Connect の反映後、Connect の VolumeChanged が戻ってきて同じ値を再適用する (`route X -> connect N` の直後に `connect N -> route X`)。値が同じなので収束し、ピンポンにはならなかった。必要なら抑止する。
  - 出力ルートが外部要因で iPhone 本体に戻ることがあった (保持プロセスは生存)。コントロールセンター操作や iPhone 側 Spotify アプリが原因と推測。`connectbridged` は出力先を監視して選び直す必要がある。

## Now Playing とリモートコマンド
- 最小のテスト (`poc/nptest`: AVAudioEngine のサイン波 + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`、バンドルIDなしの CLI) は、システムに Now Playing のアプリとして認識された (`routetool np`: displayID=`nptest`、再生中、8項目)。Home Assistant にも曲名が表示された。→ バンドルIDも追加の entitlement も不要。
- librespot で最初に効かなかった原因: MediaPlayer の呼び出しを専用スレッド (自前の run loop) から行っていたこと。メインスレッドで run loop を回し、メインキューから呼ぶと認識された。そのために、iOS では tokio のランタイムを別スレッドに移した。
- 状態の反映: 一時は、曲の切り替わりで librespot が一瞬 `Stopped` を出すことを心配して、停止の反映を 1.5 秒遅らせていた。外して試したところ、Siri の「次の曲」も、コントロールセンターの「次へ」も問題なく動いた (ユーザー確認)ので、遅延は不要と判断して削除した。Siri が動くようになった主因は、MediaPlayer をメインスレッドで動かしたこと。
- リモートコマンド: コントロールセンターの「次へ」が `remote command Next` として届き、`Loading → TrackChanged → Playing` と進んだ。
- Siri: 最初は「次の曲」で Apple Music が再生され始めたり `Play` が届いたりした。Now Playing の状態が正しく (再生中として) 公開されるようになってからは、Spotify の再生中に「次の曲」と言うと次の曲に進むようになった (ユーザー確認)。何も再生していないときは、Siri が操作先を自分で決めるため Apple Music が開くことがある。
- HomePod 本体のタップ操作: 1回タップ → `Pause`、もう1回 → `Play`、ダブルタップ → `Next`、トリプルタップ → `Previous` が `remote command` として届き、それぞれ Spirc の対応するコマンドと、`Paused` / `Playing` / `Loading → TrackChanged → Playing` のイベントが続いた。`Previous` は、再生位置が数秒を超えていると曲の頭に戻り (`Seeked`)、それ以前なら前の曲へ進む (Spotify 標準の挙動)。

## Connecting で止まる問題
- 症状: Spotify のデバイス一覧から選ぶと「Connecting」のまま止まる。librespot のログでは、転送とコンテキストの解決までは進むが、`Loading` が出ず、接続は生きたまま (ping/pong あり) で再生側だけが固まる。
- 発生のきっかけ: いずれも、Siri に「次の曲」と言って Apple Music が起動した直後。Music.app のプロセスがバックグラウンドに残っていた。
- 推測: Apple Music に音声セッションを奪われ (割り込み)、cpal のストリームが止まって再開しない。Player が書き込みで固まる。
- 対策: `AVAudioSessionInterruptionNotification` (終了時) と `AVAudioSessionMediaServicesWereReset` で librespot を終了 (`exit(75)`)。`connectbridged` が作り直す。認証情報はキャッシュ済みなので数秒で戻る。
- 状態: 対策後は再生できたが、**割り込みの通知を直接観測して回復する流れは未確認** (Siri で Music を開かせたあとに Spotify を選び直す試験が残っている)。

## Connect で選ばれている間だけ HomePod を掴む (ReleaseDelay)
- 仕様: librespot の `SessionConnected` / `SessionDisconnected` (自分がアクティブなデバイスになった / 別のデバイスへ移った) を状態ファイル (`/var/mobile/Library/ConnectBridge/state`、`active` / `inactive`) に書き、`connectbridged` が 0.5 秒間隔で読む。`active` の間だけ HomePod を選んで保持し、`inactive` になってから `ReleaseDelay` 秒 (既定 15) 後に本体スピーカーへ戻す。待ち時間中に選び直されたら解放を取り消す。解放は、出力先が今も自分の選んだ HomePod のときだけ行う。起動直後は何も掴まない。
- 音量ブリッジと Now Playing も選択中だけ動く。選択直後は HomePod 側の音量を採用する (急に大きな音にならないように)。
- 実機のログ (`daemon.log`) で確認:
  - 選ばれなくなって 7 秒・6 秒後に選び直し → 解放されない (取り消し)。
  - 選ばれなくなって 15 秒後 (20:09:45 → 20:10:00.844) → `releasing "HomePod mini" (back to "Speaker")`。
  - 選択 (20:10:21.342) → `selecting "HomePod mini"` → 約 2 秒後に `selected`。
- 選択から HomePod への切り替え完了まで約 2 秒かかるが、再生開始の瞬間に iPhone 本体から音は出なかった (ユーザー確認)。選択のイベント (`SessionConnected`) が、曲の読み込みより先に届くため。

## AirPlay ガード (切断時に本体スピーカーから音を出さない)
- 背景: AirPlay の接続は突然切れることがあり、切れるとシステムが出力を本体スピーカーに移す。
- 実装 (librespot 内、`CB_REQUIRE_AIRPLAY`): 音声セッションのルート変更通知で、出力に `BuiltInSpeaker` / `BuiltInReceiver` が含まれたら、ソフトミキサーの無音フラグ (`GUARD_MUTE`) を即座に立て (次のパケットから音量 0)、Spirc で一時停止する。出力が戻ったら、`GuardResumeSeconds` (既定 30) 以内なら再開する。ユーザーが手動で再生したら再開の対象から外す。AirPlay の張り直しは `connectbridged` が行う。
- 検証: コントロールセンターで出力先を iPhone に切り替えて擬似的に切断。本体から音は出なかった (ユーザー確認)。ログでは 2 回とも、約 1 秒で `pausing` → `resuming` と進み、`connectbridged` が `selecting "HomePod mini"` → 約 2 秒後に `selected` (20:20:33 / 20:20:48)。
- 限界: 無音にできるのは、これから処理される音声のみ。出力側のバッファにすでにある数十〜数百ミリ秒は止められないので、切断の瞬間にごく短い音が出る可能性は残る。
- HomePod の電源を抜いた場合 (長く繋がらない): 20:23:26 に `route: "HomePod" not found` と `pausing`。HomePod が戻って選び直されたのは 20:24:28〜30 (約 64 秒後) で、`came back too late, staying paused`。設計どおり、30 秒を超えてから戻っても自動では再開せず、一時停止のままになった。再開はユーザーが Spotify で再生を押す。電源を抜いていた約 60 秒の間、iPhone 本体から音は出なかった (ユーザー確認)。

## 設定 UI (設定アプリの「ConnectBridge」)
- 構成: PreferenceLoader (実機に `apt-get install preferenceloader` で導入、bigboss、2.2.6) + `prefs/` の設定バンドル (Theos)。Xcode 26 の SDK に `Preferences.framework` が無いため、`-Wl,-undefined,dynamic_lookup` でリンク (設定アプリが読み込み済み)。
- デーモン側: 設定は `CFPreferencesCopyAppValue` で読む (ファイルを直接読むと反映が遅れる)。設定アプリが `PostNotification` で Darwin 通知 `com.sui827.connectbridge/prefs` を送り、起動条件が変わったときだけ librespot を作り直す。ボタンは `com.sui827.connectbridge/restart`。状態は `RuntimeState` として同じドメインに書く (設定アプリは `/var/mobile/Library/ConnectBridge/` を読めない想定)。
- 実機で確認 (ログ): デバイス名を変更 → `preferences changed: restarting librespot` → 新しい名前で起動。元に戻す → 再度再起動。「librespot を再起動」ボタン → `restart requested`。設定アプリに項目と画面が出ることもユーザーが確認。
- 副産物の修正: デーモンが SIGTERM / SIGINT / SIGHUP を `SIG_IGN` にしていたため、exec 後の librespot にも継承され、SIGTERM で終了しなかった (`ignored SIGTERM, sending SIGKILL`)。`posix_spawnattr_setsigdefault` で既定に戻した。意図的な再起動 (設定変更・SIGHUP・ボタン) は待ちとバックオフなしの 0.5 秒で再開する (SIGHUP で約 0.6 秒)。

## デバイス名の自動化と AirPlay 機器のピッカー
- `ConnectName` の既定を空にし、空なら `<見つかった AirPlay 機器の名前> (via <iPhone の名前>)` を使う。iPhone の名前は `MGCopyAnswer("UserAssignedDeviceName")` (libMobileGestalt)。実機では `HomePod mini (via <iPhone の名前>)` の形になった。
- 起動直後は AirPlay 機器がまだ見つかっていない可能性があるので、自動名のときだけ最大 8 秒待ってから librespot を起動する (実機では約 0.07 秒で見つかった)。
- デーモンは見つけた AirPlay 機器の名前を `AvailableOutputDevices` として設定ドメインに公開し、設定アプリのピッカーがそれを読む。選んだ名前の機器が見つからない間も、現在の値は `(not found)` として残る。機器の選び方は、完全一致を優先し、なければ部分一致。
- 設定アプリの文言は英語のみ。

## 公開前の整理の確認 (実機)
- 再起動と再度の脱獄で `/var/jb` が作り直され、パッケージと PreferenceLoader が消えた (`/var/mobile` のログと認証情報は残った。root の SSH 鍵は失われ、`sudo passwd root` で設定し直した)。この環境では、リポジトリの署名が確認できず `apt-get install -y` は「認証されていないパッケージ」で止まったため、PreferenceLoader は Sileo で入れた。iPhone の名前も変わり (`iPhone 7`)、Spotify 上の名前は `HomePod mini (via iPhone 7)` になった。
- 新しい deb: データディレクトリ `0700`、`credentials.json` `0600`、librespot の環境に `RUST_LOG=libmdns=error,librespot=info,librespot_playback::player=warn`、デーモンは起動後に librespot を 1 つだけ起動。`dpkg --remove` ではサービスが止まり、設定とデータは残り、再インストールで戻る。`postrm` は構文のみ確認 (`--purge` はログインが消えるため実行していない)。
- ログ: 新しい実行 (16 行) には、曲名の行 (`Loading <...>` / `... loaded`) も、libmdns の警告も出ていない。ただし、以前の実行のログ (曲名を含む) が `librespot.log` / `.1` に残っている。

## 一時停止してもコントロールセンターが「再生中」のままになる問題
- 症状: PC など別のデバイスから一時停止しても、iOS のコントロールセンターは再生中のまま。
- 調査: `routetool np` で、一時停止の直後のシステムの状態を読むと、`PlaybackRate = 0` (こちらの更新は届いている) なのに `isPlaying = 1`。最小のテスト (`poc/nptest`、`PHASES=1`) で、`playbackState = Paused` と `PlaybackRate = 0` を公開しても、**音声エンジンが動いている間は `isPlaying = 1`、エンジンを止めると `0`** になることを確認した。システムの「再生中」は、アプリの申告ではなく、音声出力が動いているかで決まる。
- 原因: librespot の rodio シンクは、一時停止しても出力ストリームを閉じず、無音を流し続けていた。
- 修正: `Sink` トレイトに `release()` を追加し、プレーヤーが「一時的でない停止」(一時停止・停止) のときだけ呼ぶ。rodio のシンクは、ここで出力ストリームを閉じ、再開 (`start` / `write`) で開き直す。曲の切り替え中の一時的な停止では閉じない。
- 結果: PC から一時停止すると、コントロールセンターも停止中になる (ユーザー確認)。
- 備考: 再起動で実機の `ldid` が消えており、診断ツールの署名ができず (起動直後に SIGKILL)、`apt-get install ldid` で入れ直した。Mac で署名したバイナリは、実機のトラストキャッシュに載らず動かない。
