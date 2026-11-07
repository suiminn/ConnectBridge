# 一晩放置テスト (R5)

目的: iPhone を画面ロックのまま一晩置いても、朝、Spotify の一覧に出て、選んで再生すると HomePod から鳴るかを確認する。

## 準備

- iPhone を充電器につなぐ(低電力モードはオフ、自動ロックは既定のまま)。
- HomePod の電源は入れたまま。Wi-Fi は同じネットワーク。
- **再起動しない**(脱獄が外れる)。
- Mac は同じネットワークにいる状態にしておく(夜と朝のスナップショットのため)。

## 夜

1. Spotify で「`<AirPlay 機器> (via <iPhone>)`」を選び、HomePod から鳴ることを確認する。
2. Spotify でほかのデバイスに切り替える(HomePod が15秒後に解放され、待機状態になる)。
3. スナップショットを取る:
   ```bash
   scripts/overnight-check.sh before <iPhone の IP>
   ```
4. iPhone をロックして放置する。

## 朝

1. スナップショットを取って、夜と比較する:
   ```bash
   scripts/overnight-check.sh after <iPhone の IP>
   ```
2. Spotify の一覧に「`<AirPlay 機器> (via <iPhone>)`」が出るか確認する。
3. 選んで再生し、HomePod から鳴るか確認する。
4. **音量の同期の確認** (一晩のあいだ音量は変えていないので、KVO の通知が途切れていないかは、ここで初めて分かる): `Verbose` をオンにして、再生中に、iPhone の音量ボタンで 3 回、HomePod 本体の操作で 3 回、音量を変える。1 分ほど待って、もう一度 `scripts/overnight-check.sh after <iPhone の IP>` を実行し、`volume_to_connect` (HomePod 側 → Spotify) と `volume_to_route` (Spotify 側 → HomePod) が増えているのを見る。Spotify のスライダーが追従するかも、目で確かめる。

## 合格の基準

| 項目 | 基準 |
|---|---|
| プロセス | `connectbridged` と `librespot` の PID が夜と同じ(再起動していない)。違う場合は `daemon.log` で理由を見る |
| メモリ | `rss_kb` が大きく増えていない(目安: 倍にならない) |
| 一覧 | 朝、Spotify の一覧にデバイスが出る |
| 再生 | 選ぶと数秒で再生が始まり、HomePod から鳴る(iPhone 本体からは鳴らない) |
| 音量の同期 | 朝の操作 (上の手順 4) のあと、HomePod 側と iPhone のボタンの操作のどちらでも Spotify のスライダーが追従し、`volume_to_connect` が増える (KVO の通知が、一晩のあとも届く。5 秒ごとの確認でも拾われるので、遅れて追従する場合は通知が止まっている) |
| 接続の切断 | `connection_lost` が増えた場合は、その直後に `librespot_starts` も増え、`Authenticated as` が出ている (切断から自動で復旧している) |
| ログ | `librespot_errors` が増えていない。`guard_events` / `interruptions` が不自然に増えていない |

## 失敗したときに見るもの

- `/var/mobile/Library/ConnectBridge/daemon.log` — `librespot exited`、`restarting`、`route:`。
- `/var/mobile/Library/ConnectBridge/librespot.log` — `Authenticated as`(再接続)、`ERROR`。`Verbose` をオンにすると詳細。
- 一覧に出ない場合: iPhone の Wi-Fi が切れていないか、Spotify のセッションが切れて再接続できていないか(`Authenticated as` の回数)。
- 選ぶと `Connecting` で止まる場合: 音声セッションの割り込み(`audio session interruption` の有無)。

## 既知の観察

- 画面ロック中の iPhone は、Mac からの ping / SSH に答えないことがある(Wi-Fi の省電力)。スナップショットが取れないときは、画面を点けてから再実行する。Spotify との接続(iPhone から外への通信)は別で、一覧に出るかは Spotify アプリで確認する。
