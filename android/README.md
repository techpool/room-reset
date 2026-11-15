# Room Reset for Android

Open this directory in Android Studio, or use JDK 17 or 21 and an installed Android SDK with Platform 35. Set `ANDROID_HOME` to the SDK directory. From this directory, run:

```sh
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The game runs on Android 8.0 (API 26) and later. The APK includes the shared room artwork, game, and native Storage Access Framework bridge. All game content loads locally.

**My folder** opens the Android system folder picker. Choose a folder containing files to organize. The app lists supported immediate files in providers that allow native moves. It creates a shelf directory in the chosen folder when a file first moves there. Directories, hidden files, unsupported formats, and unique MongoDB exports stay in place.

The app recognizes numbered or “copy” downloads that match a plain original, and checks same-size MongoDB exports for identical contents. Duplicates require a full SHA-256 match. Sorting stages them in `Room Reset - Staged`. **Empty staging** checks the original and staged files again and removes matching journaled copies. **Undo** restores the last batch while preserving name conflicts. Sorted files remain available in the system Files app. Undo history lives in the app’s private storage.

Run the device tests on a disposable Android 10+ emulator with the system external-storage document provider and a Documents directory:

```sh
./gradlew :app:connectedDebugAndroidTest
```

Tests create their own uniquely named directories under Documents. They exercise native moves and deletion, persistence, collision handling, digest checks, and the game-to-filesystem bridge.
