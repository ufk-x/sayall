# SayAll for G9N9N on macOS

This fork packages the tested local G9N9N configuration based on [Hylouis233/sayall-g9n9n at c3a8024](https://github.com/Hylouis233/sayall-g9n9n/tree/c3a802429ff17a3747273d4a53d9f728e85da1bd), derived from [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app). The application code is GPL-3.0. See LICENSE.md and COPYRIGHT.md.

The baseline routes the remote microphone through Remote Buddy Mic to the configured voice input tool. It uses its integrated key helper for malformed HID reports from the G9N9N variant. Remote Buddy Mic and Apple's PacketLogger are separate prerequisites. Install the virtual driver from the official [Remote Buddy release](https://github.com/zfdang/remote-buddy/releases/tag/v26-11-17.916). Install Apple's PacketLogger at /Applications/PacketLogger.app.

Configure the remote's actual Bluetooth address locally before enabling G9N9N key capture.

```sh
defaults write com.hd838a.RemoteMic g9n9n.localBluetoothAddress -string 'AA:BB:CC:DD:EE:FF'
```

The Apple Silicon baseline was built on macOS 14.5 using Swift 6.0.3 and the macOS 15.2 SDK. The included build script produces an ad-hoc signed local package. Use the existing macOS authorization UI for Bluetooth, Accessibility, Input Monitoring, and the integrated key helper.

```sh
SAYALL_LOCAL_PUBLIC=1 SAYALL_LOCAL_CONFIGURATION=debug SAYALL_LOCAL_BUILD_ONLY=1 \
SAYALL_LOCAL_APP_TARGET="$PWD/build/SayAll.app" scripts/package-local-test-app.sh
```
