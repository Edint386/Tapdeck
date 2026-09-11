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

### 次: ミキサー

複数ソース（アプリ音声＋マイク＋外部入力）の合成。
ここが揃うと「マイク＋コンピューターオーディオを Zoom で共有」が成立する。

## ビルド

Xcode があればその SDK を、無ければ Command Line Tools を使う。

```
./build.sh
```

生成物:
- `build/tapproof` — エンジンの検証用CLI
- `Tapdeck.app` — 画面収録UI

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
