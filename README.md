# Tapdeck

macOS 用のオーディオルーティング＋収録ツール。Loopback / Audio Hijack 相当を目指す。

## 構成

```
┌─ オーディオエンジン（＝Loopback の本体）─────────────────────┐
│  アプリ音声  (Core Audio Process Tap)  ┐                    │
│  マイク / 外部インターフェース          ├→ ミキサー → 仮想デバイス │
│  他の仮想デバイス                      ┘                    │
└──────────────────────────────────────────────┘
                          ↑ この上に乗るもの
        画面収録 / 単体録音 / アプリ別音量 / 会議アプリへの送出
```

画面収録はエンジンの利用者の一つであって、土台ではない。

## 進捗

### 済み: アプリ単位のオーディオ取得（エンジンの中核）

`Sources/Engine/` に実装。**仮想オーディオドライバもカーネル拡張も使わず**、
Core Audio の Process Tap (macOS 14.2+) で特定アプリの音だけを取り出す。

検証: 440 Hz と 3000 Hz を鳴らす2つのプロセスを同時に走らせ、片方だけを Tap した。

| 対象 | 440 Hz | 3000 Hz |
|---|---|---|
| 440Hz のプロセスのみを Tap | **-21.1 dB 検出** | **-134.6 dB（不在）** |
| システム全体を Tap | -21.1 dB 検出 | -21.1 dB 検出 |

分離度 113 dB。これは BlackHole にはできない（BlackHole はシステム全体の音しか流せない）。

### 済み: 画面収録（Phase 1 で先に作ってしまったもの）

`Sources/App/`。ScreenCaptureKit で解像度・FPS 指定、システム音声・マイク収録。
3600×2338 @ 60fps で実測済み。将来はエンジンから音を受け取る形に繋ぎ替える。

### 済み: 仮想オーディオデバイス

`Driver/TapdeckDriver.c`（1040行）。他アプリから「入力デバイス」として見える
デバイスを公開する **AudioServerPlugIn**。カーネル拡張ではなく、`coreaudiod`
にロードされるユーザー空間のプラグイン。SIP を切る必要はない。

動作はループバック。出力側に書かれた音がリングバッファ経由で入力側から読める:

```
Tapdeck.app  ──(ミックス済みの音を再生)──▶  出力側
                                             │ リングバッファ (16384 frames)
Zoom / OBS   ◀──(マイクとして読む)────────  入力側
```

- 2ch、44.1 / 48 / 88.2 / 96 kHz 対応、Float32 インターリーブ
- 実ハードウェアが無いので `mach_absolute_time` から仮想クロックを合成する
- **ad-hoc 署名のまま `coreaudiod` にロードされることを確認済み**。
  Developer ID も公証も不要で、SIP を切る必要もない
- インストール後、`入力 2ch / 出力 2ch / 48000 Hz` のデバイスとして
  システム全体から見えることを確認済み
- **複数・名前付きで作れる**（最大8台）。「Zoom用」「配信用」のように分けられる。
  アプリが `/Users/Shared/Tapdeck/Devices.plist` を書き、ドライバが2秒ごとに
  読み直して増減を反映する。`coreaudiod` の再起動は不要。

  この置き場所なのは、`coreaudiod` が `_coreaudiod` ユーザーで動くため
  ユーザーのホームを読めず、`/Library` へアプリが書くには管理者権限が要るため。

- **ループバック検証済み**。出力側に 440Hz / 振幅 0.25 を流し、入力側から読み返した:

| 測定項目 | 結果 |
|---|---|
| ピーク | -12.0 dB（振幅 0.25 の理論値 -12.04 dB と一致） |
| RMS | -15.1 dB（0.25/√2 の理論値 -15.05 dB と一致） |
| 440 Hz 成分 | -12.0 dB |
| 400 / 479 / 880 Hz 成分 | -999 dB（皆無） |
| ゼロ交差による周波数推定 | 440.0 Hz |

  479 Hz が出ていればサンプルレートのずれ（ピッチシフト）を意味するが、
  皆無だった。振幅・周波数とも完全に保たれている。
  検証はアプリの「オーディオ」タブから実行でき、取り込んだ音は
  `~/Library/Caches/dev.kosuke.Tapdeck/loopback-test.wav` に残る。

```
./Driver/build-driver.sh                          # ビルドのみ（sudo 不要）
sudo cp -R build/Tapdeck.driver /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod                           # 読み込ませる
```

HAL プラグインは `/Library/Audio/Plug-Ins/HAL/` にしか置けない。`coreaudiod` は
`_coreaudiod` ユーザーで動くため、ホームディレクトリ下からは読めない。

アンインストール:
```
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Tapdeck.driver && sudo killall coreaudiod
```

### 済み: ミキサー

複数ソース（アプリ音声 / システム全体 / マイク・外部入力）を合成して
1つの出力デバイスへ流す。出力先を Tapdeck 仮想デバイスにすると、
その入力側を Zoom や OBS がマイクとして選べる。

    アプリ音声 (Process Tap) ┐
    システム全体             ├→ [変換] → [リングバッファ] → 加算 → 出力デバイス
    マイク / 外部入力        ┘

ソースごとに音量・ミュート・レベルメーター。構成は次回起動時に復元される。
用途ごとの構成は**プリセット**として名前を付けて切り替えられる。

アプリの同定は PID ではなく**バンドルID**で行う。PID は再起動で変わるため、
保存した構成が次回繋がらなくなる。対象アプリが起動していないソースは
未接続として行だけ残り、起動後に「更新」で繋がる。

**検証**: 440Hz を鳴らすアプリ1つをソースにして Tapdeck へ送出し、
同じデバイスの入力側をアプリ内のモニタ機能で録音した。

| 測定項目 | 結果 |
|---|---|
| 全体ピーク | -21.1 dB |
| 440 Hz 成分 | -21.1 dB（ピークと一致＝純粋な正弦波） |
| 不連続点 | 0 箇所 / 48000 サンプル |
| ゼロ交差による周波数推定 | 440 Hz |
| 3000 Hz 成分 | -121.0 dB |

アプリの音声 → Process Tap → ミキサー → 仮想デバイス → 他アプリが入力として読む、
という経路が全区間で無劣化に通っている。

## インストール

```
./install.sh                 # ビルドして /Applications へ
sudo ./install-driver.sh     # 仮想デバイスを使う場合、初回のみ
```

以降は Launchpad や Spotlight から普通に起動できる。

### 署名について

`install.sh` は初回に `Tapdeck Local` という自己署名証明書をキーチェーンへ作る。

ad-hoc 署名（`codesign -s -`）だとビルドのたびに署名が変わり、macOS から見ると
毎回「別のアプリ」になるため、マイク・画面収録・オーディオ録音の許可が
その都度リセットされる。固定の証明書なら署名条件が変わらないので許可が維持される。

```
designated => identifier "dev.kosuke.Tapdeck" and certificate root = H"68b7190f…"
```

配布するなら Apple Developer Program の Developer ID と公証が必要。
これは自分の Mac で使うためのもの。

## 開発

```
./build.sh                   # ビルドのみ（/Applications へは入れない）
./tools/make-icon.swift      # アイコンの生成（build.sh からは呼ばれない）
```

生成物:
- `Tapdeck.app` — 本体
- `build/tapproof` — エンジンの検証用CLI
- `build/Tapdeck.driver` — 仮想オーディオデバイス

## tapproof の使い方

```
./build/tapproof list                      # 音を扱っているプロセスを一覧
./build/tapproof rec Chrome 10 out.wav     # Chrome の音だけ10秒録音
./build/tapproof rec 1234 10 out.wav       # PID 指定でも可
./build/tapproof rec-system 10 out.wav     # システム全体
```

## 実装上の落とし穴（実測で踏んだもの）

### 1. Tap に渡すのは PID ではなく AudioObjectID

`CATapDescription` が要求するのはプロセスの `AudioObjectID`。
`kAudioHardwarePropertyProcessObjectList` で列挙し、`kAudioProcessPropertyPID` で対応づける。

### 2. Tap は単体では読めない

Tap をサブデバイスとして含む **private な集約デバイス**を作り、そこに IOProc を挿す。
集約デバイスにはクロック源が必要なので、既定の出力デバイスを必ずサブデバイスに含める。

### 3. `kAudioTapPropertyFormat` のサンプルレートは信用できない

実測で、内蔵スピーカーが 44100 Hz で動いているのに Tap は 48000 Hz と申告した。
IOProc に実際に流れてくるのは集約デバイスの入力ストリームで、そのクロックは
主サブデバイス（＝既定の出力デバイス）に従うため。

Tap の申告を信じると **48000/44100 = 8.8% のピッチシフト**が起きる
（440 Hz の音が 479 Hz になる）。`kAudioDevicePropertyNominalSampleRate` を
集約デバイスから読んで上書きすること。

### 4. Tap のバッファはインターリーブ

`AVAudioFile` も `AVAudioEngine` も非インターリーブを前提にしている。
形式が食い違うと `write(from:)` が毎回失敗し、ヘッダだけのファイルができる。
`ProcessTap` は常に非インターリーブ Float32 に正規化してからハンドラに渡す。

### 5. CoreAudio の Swift オーバーレイは SDK に無い

`CATapDescription` の初期化子は `NS_REFINED_FOR_SWIFT` だが、
`CATapDescription(stereoMixdownOfProcesses:)` として Swift から直接呼べる
（`[AudioObjectID]` を取る）。

## 必要な許可

- **オーディオ録音** — Process Tap の初回使用時
- **画面収録** — Tapdeck.app の初回起動時。許可すると macOS がアプリを一度終了させるので再起動する
- **マイク** — マイクを有効にして収録したときのみ


## TCC（権限）まわりの落とし穴

### CLI から入力デバイスは読めない

入力デバイスの読み取りにはマイク権限が要る。そして **TCC のプロンプトは
コマンドラインバイナリには出せない**。試した順に:

1. 素のCLI → `AVCaptureDevice.requestAccess` が即 false、状態は「未決定」のまま
2. `.app` に包んでバイナリを直接起動 → 同じ
3. `LSBackgroundOnly` を `LSUIElement` に変更 → 待機はするがプロンプトは出ない
4. `open` (LaunchServices) 経由で起動 → 同じ
5. メインスレッドをセマフォで止めずランループを回す → コールバックが来ない

セマフォでメインスレッドを止めてはいけないのは事実（プロンプトはメインランループ
経由で提示される）だが、それを直しても CLI では出なかった。

**結論: デバイス入力を扱う検証は GUI アプリ側で行う。** `Tapdeck.app` の
「オーディオ」タブに移した。実アプリからは正常にプロンプトが表示される
（`CGWindowListCopyWindowInfo` で UserNotificationCenter のウインドウを確認済み）。

### 許可はプロセス単位

`tapproof` で許可状態を調べても `Tapdeck.app` の状態は分からない。別々に扱われる。


## ミキサー実装で踏んだこと

### NSAudioCaptureUsageDescription が無いと、エラーではなく無音になる

Core Audio の Process Tap は TCC の `kTCCServiceAudioCapture` で保護されている。
対応する Info.plist キーは **`NSAudioCaptureUsageDescription`**。

これが無くても `AudioHardwareCreateProcessTap` は**成功を返す**。
ただし届く音がすべて無音になる。エラーが出ないので原因が非常に分かりにくい。

同じコードを CLI から動かすと音が録れるのに GUI アプリだと無音、という形で現れた
（CLI は親プロセスの権限を継いでいたため）。

### ソースと出力先でサンプルレートが違う

Process Tap の集約デバイスは「既定の出力デバイス」のクロックに従う。
出力先が別のデバイス（Tapdeck の 48000 Hz）だとレートがずれるため、
ソースごとに `AVAudioConverter` を挟む（`Sources/Engine/FormatConverter.swift`）。

Tap 側のクロックを出力先に合わせる案も試したが、**そのデバイスへ流れていない音は
拾えなくなる**ため使えない（実測で完全に無音になった）。

### リングバッファは溜めてから読み出す

音源と出力先は別クロックで動く。溜めずに読み出すとバッファが常に空寸前になり、
わずかな揺らぎのたびに波形へ隙間が入る。既定で 2048 フレーム溜めてから読み出す。

### ffmpeg の avfoundation 経由の録音は測定に使えない

検証中、ミキサー出力の 440Hz 成分が -32.6 dB（本来 -21.1 dB）と出て、
512フレーム単位の位相飛びが観測された。しかし調べた結果:

- リングバッファ: 枯渇0・溢れ0・滞留は安定
- AVAudioConverter: 単体試験で不連続点0
- Process Tap: サンプル時刻の飛び0
- 同じ信号をアプリ内の AUHAL で録ると不連続点0、440Hz が -21.1 dB

つまり**測定器（ffmpeg）側の取りこぼしだった**。アプリに「入力をモニタ録音」機能を
追加し、以後はそちらで測る。外部ツールの出力を信用する前に、自前の経路と
突き合わせること。


## メニューバー常駐

ミキサーは出しっぱなしで使うものなので、ウインドウを開かずに開始・停止、
レベル確認、プリセット切り替えができるようにしてある。

### SwiftUI の MenuBarExtra は使っていない

`MenuBarExtra` は、この構成（swiftc で組んだバンドル、`Window` シーンと併存）では
最小構成にしても項目が作られなかった。AppKit の `NSStatusItem` で直接組んでいる。
動作状態でアイコンを塗り分けられる利点もある。

### ノッチのある画面では置けないことがある

ノッチ付きの画面はメニューバーの右側にしか項目を置けない。実測した環境では
1800pt 幅の画面に対しノッチが 790–1010 を占有し、置ける範囲は 1010–1800 しか
なかった。そこが他アプリで埋まっていると macOS はスロットを割り当てず、
項目のウインドウを画面外（y = -22）へ追いやる。エラーは出ない。

`MenuBarController` はこれを検知して `isPlaced` を false にし、ミキサー画面に
案内を出す。解消するには他のメニューバー項目を減らす。

## 画面収録の音源

`SCRecordingOutput` は音声も面倒を見てくれるが、音源が「システム音声」と
「マイク」に固定される。ミキサーで組んだ音を収録に乗せるには、映像と音声を
自前で多重化する必要がある（`Sources/Engine/MuxedRecorder.swift`）。

    SCStream (映像)        ┐
                           ├→ AVAssetWriter → .mov
    DeviceInput (音声)     ┘

音声の時刻は AUHAL が渡すホスト時間を使う。到着時刻で代用するとジッタが乗る。
