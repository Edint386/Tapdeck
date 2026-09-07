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

### 実装済み・未検証: 仮想オーディオデバイス

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
- ビルドと ad-hoc 署名までは確認済み。**インストール後の動作は未検証**

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

### 未着手: ミキサー

複数ソース（アプリ音声＋マイク＋外部入力）の合成とチャンネル割り当て。

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
