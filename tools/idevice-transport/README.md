# KorSign pairing transport

`make iphoneos` builds the patched arm64 iPhone transport and links it into Feather. The app keeps the pinned idevice 0.1.68 headers and Swift API. The iOS Simulator and Mac Catalyst keep their upstream artifacts. The transport patch was adapted from [KorSign 3.0.1 Revision 1](https://github.com/korboybeats/KorSign/tree/v3.0.1-r1/tools/idevice-transport).

Prerequisites include Xcode, Python 3.11+, and Rust stable with the iPhone target.

```sh
rustup target add --toolchain stable aarch64-apple-ios
make iphoneos
```

The Makefile prepares a dedicated Xcode build directory. Ordinary Xcode builds use the original transport unless you prepare that same DerivedData directory with the script’s `--install-in` option. The script verifies the pinned source revision and runs the five KorSign TLS-write tests before compiling the iPhone slice.
