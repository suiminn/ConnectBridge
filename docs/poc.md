# Phase 0: 実機 PoC 手順 (v0.1)

> 開発初期の作業手順で、現在は完了しています (結果は [poc-results.md](poc-results.md))。API 名は当時の候補で、実際に使ったものは結果の記録を参照してください。

目的: [spec.md](spec.md) の R1〜R5 を最小コードで確認し、案Aで進めてよいか判断する。
ここで書く private API 名は**候補**。iOS 15 に実在するかは Step 2 の列挙で先に確認する。

## 0. 環境準備

### Mac 側 (現状の確認結果)
| 項目 | 状態 | やること |
|---|---|---|
| ldid | あり | - |
| Theos | なし | 公式手順 (theos.dev/docs/installation) に従って入れ、`THEOS=~/theos` を設定する。rootless 用にビルドするので `THEOS_PACKAGE_SCHEME=rootless` を使う |
| Rust | なし | `rustup` を入れ、`rustup target add aarch64-apple-ios` |
| Xcode 本体 | `xcode-select` が CommandLineTools を指している | iPhoneOS SDK が必要。Xcode を入れるか、Theos の `sdks/` に iPhoneOS 15.x SDK を置く |

### iPhone 側
- Dopamine 系 (rootless) で脱獄済み、Sileo 導入済み
- Sileo から `openssh`, `ldid`, `curl`, `nano` などを入れる (`/var/jb` 配下)
- Mac から `ssh mobile@<iPhoneのIP>` / `ssh root@<iPhoneのIP>` で入れること (初期パスワードは変更する)
- iPhone と HomePod を同じ Wi-Fi に置く。HomePod は Control Center の AirPlay 一覧に出ること

### 先に確認しておくこと
```bash
ssh root@<ip> 'sw_vers; uname -m; ls /var/jb | head'
```
iOS 15.x、`arm64`、`/var/jb` があること。

---

## Step 1 (R1): 常駐プロセスから音が出るか

**作るもの**: `audiotest` (ObjC CLI)。AudioQueue か AVAudioEngine で 440Hz のサイン波を鳴らす。`AVAudioSession` のカテゴリは Playback。

**手順**
1. Theos の `tool` テンプレートでビルドし、`ldid -S` で署名して `/var/jb/usr/local/bin/` に置く。
2. root で実行して、本体スピーカーから鳴ることを確認する。
3. 画面をロックしたまま、鳴り続けるか確認する。
4. ssh を切断しても、鳴り続けるか確認する。
5. launchd plist (`/var/jb/Library/LaunchDaemons/`) から起動して、同じ確認をする。
6. root と mobile のどちらでも試す。

**合格**: 手順 5 で、ロック中も鳴り続ける。
**失敗時**: AVAudioSession の取得に失敗するなら、必要な entitlement (例: `com.apple.private.audio.*` 系) を ldid で付けて試す。それでも駄目なら、SpringBoard にロードされる tweak 側で再生する構成に変える (spec R1 の代替)。

---

## Step 2 (R2 の前段): API の存在確認

推測で書かず、実機の iOS 15 で実在するクラスとメソッドを列挙する。

**作るもの**: `dumpclass` (ObjC CLI)。クラス名を受け取り、`class_copyMethodList` で一覧を出す。

**調べる候補**
- `AVOutputContext`, `AVOutputDevice` (AVFoundation)
- `MPAVRoutingController`, `MPAVRoute` (MediaPlayer)
- `MRAVOutputContext` 系と MediaRemote の関数 (`dlsym` で存在確認)
- `AVSystemController` (Celestial / AVFoundation 内)
- `MPVolumeController`

あわせて、公開されている iOS ランタイムヘッダ集や dyld shared cache 抽出ツールでも突き合わせる。

**成果物**: 実在した API と、シグネチャの一覧 (poc-results.md に貼る)。

---

## Step 3 (R2): 出力ルートを HomePod に固定する

**手順**
1. Step 1 の `audiotest` を鳴らしたまま、Control Center で手動で HomePod を選ぶ。HomePod から鳴れば、「常駐プロセスの音が AirPlay に乗る」ことが確認できる。
2. 次に、Step 2 で見つかった API で利用可能なルート一覧を取得し、名前で HomePod を探す。
3. そのルートを選択させる (`routeroute` のような CLI にして、`routeroute "<AirPlay 機器の名前>"` で切り替える)。
4. ルートを iPhone 本体に戻すコマンドも作る。
5. 画面ロック中と、`audiotest` が止まっている状態からでも切り替わるか試す。

**合格**: コードだけで HomePod に切り替えられ、音が HomePod から出る。
**失敗時**: 案B (自前 RAOP/AirPlay 2 センダー) の検討に入る。この場合は仕様を見直す。

---

## Step 4 (R3): HomePod の音量を設定・取得する

**手順**
1. HomePod にルートを向けた状態で、システム音量の set/get を試す (`AVSystemController` の `setVolumeTo:forCategory:` と `getVolume:forCategory:`、カテゴリは `Audio/Video`。候補)。
2. 値を 0.2 / 0.5 / 0.8 に変え、HomePod の実際の音量が変わるか、変わった値が一致するか確認する。
3. 逆方向: HomePod 本体のタッチ操作や Siri で音量を変え、iPhone 側に通知が来るか確認する (`AVSystemController_SystemVolumeDidChangeNotification` など候補)。通知が来ないなら、ポーリングで取れるか見る。
4. iPhone 本体の音量とは別の値かどうかも確認する。

**合格**: 設定が HomePod に反映され、HomePod 側の変更を iPhone が検知できる (ポーリング可)。
**失敗時**: iPhone のシステム音量を経由する形に設計を変える。

---

## Step 5 (R4): librespot を iPhone で動かす

**手順**
1. librespot の最新リリースを取得し、`cargo build --release --target aarch64-apple-ios` を試す。
2. Cargo の features を確認する (`Cargo.toml` の `[features]`)。iOS に無い avahi/dbus は外し、音声バックエンドは rodio か cpal 系を選ぶ。mDNS は `libmdns` 系 (feature 名はバージョンで違うので `Cargo.toml` で確認)。
3. `ldid -S` で署名し、`/var/jb/usr/local/bin/librespot` に置く。
4. `librespot --help` で認証オプション (OAuth など) を確認する。バージョンにより異なる。
5. 初回ログインを済ませ、資格情報を `--cache` ディレクトリに保存する。
6. 他の端末の Spotify アプリのデバイス一覧に出るか、選んで再生できるか確認する。

**合格**: 他端末から iPhone を選び、本体スピーカーで再生できる。
**失敗時**: 依存クレートの iOS 対応を確認し、必要ならバージョンを下げるか fork する。

---

## Step 6 (R5): ロック中の常駐安定性

**手順**
1. librespot を launchd plist (KeepAlive 付き) から起動する。
2. 画面をロックし、充電しながら放置する。Low Power Mode は切る。
3. 5分、30分、一晩放置したあとで、Spotify のデバイス一覧に出るか、再生を始められるか確認する。
4. 出ない場合は、Wi-Fi の状態、プロセスの生存、ログを確認する。

**合格**: 一晩後も一覧に出て、再生を始められる。
**失敗時**: keepalive 用の無音再生や、`UIBackgroundModes` 相当の対処、mDNS 経由の検出に切り替えを検討する。

---

## Step 7: 結合 PoC (IPC なし)

librespot の `--onevent` で外部プログラムを呼べることを使い、IPC を作らずに Step 3・4 のツールをつなぐ。

1. Step 3 の `routeroute` で HomePod に固定する。
2. `--onevent` に渡すシェルスクリプトで、音量変更イベントを受けたら Step 4 の `setvol` を呼ぶ。イベント名と環境変数は、そのバージョンの `--help` で確認する。
3. 他端末の Spotify アプリで音量スライダーを動かす。

**合格**: スライダー操作で HomePod の音量が変わる。再生はロック中も続く。

---

## 判定

| 結果 | 次の動き |
|---|---|
| Step 1〜7 すべて合格 | Phase 1 へ。仕様どおり案Aで進める |
| Step 3 だけ失敗 | 案B の検討 (仕様の大幅修正) |
| Step 4 だけ失敗 | 音量連携の設計を修正 (システム音量経由など) |
| Step 1 や 6 で失敗 | 常駐方式 (tweak 側で再生、keepalive) を見直す |

結果は `poc-results.md` に、ステップごとに「合否・使った API・ログ・気づき」を残す。

## 注意
- ここで使うのは自分の端末だけ。private API を使うので、iOS のバージョンが変わると動かなくなる前提で書いている。
- 資格情報 (`--cache` の中身) はコミットや共有をしない。
