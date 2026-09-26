# Local Windows builds

One PowerShell command builds a sideloadable Android TV APK for this fork. Android Studio does not need to be open.

## First-time setup

1. Install [JDK 17](https://learn.microsoft.com/en-us/java/openjdk/download) (Microsoft OpenJDK 17 is fine).
2. Install Android Studio so the SDK lands at `%LOCALAPPDATA%\Android\Sdk`.
3. In Android Studio SDK Manager, confirm:
   - Android SDK Platform 36
   - NDK **27.0.12077973** (side by side)
   - CMake 3.22.1
   - Android SDK Build-Tools 36
4. Open this repo in Cursor. `.\build-local.ps1` writes `local.properties` with this PC's `sdk.dir` and the production Nuvio backend keys. That file is gitignored.

`build-local.ps1` can also install NDK 27 via `sdkmanager` if command-line tools are present.

## Commands

```powershell
.\build-local.ps1              # normal incremental FullDebug
.\build-local.ps1 -Fast        # daemon + build cache + parallel
.\build-local.ps1 -Clean       # gradle clean, then build
.\build-local.ps1 -Install     # build, then adb install -r if one device is connected
.\build-local.ps1 -Release     # FullRelease signed with the permanent Tolu OTA key
```

Cursor / VS Code Command Palette (`Tasks: Run Task`):

- **Nuvio: Build Local**
- **Nuvio: Fast Build**
- **Nuvio: Build + Install**
- **Nuvio: Build Release**

## Output

APKs land in `builds\` (gitignored):

- `builds\NuvioTV-Tolu-latest.apk` (debug)
- `builds\NuvioTV-Tolu-YYYY-MM-DD-HHmm.apk` (debug)
- `builds\NuvioTV-Tolu-release-latest.apk` (permanent OTA key)

The script prints `BUILD SUCCESS`, the full APK path, size, and SHA256.

## Package ID

Installed application ID: **`com.nuvio.tv.tolu`**

This is distinct from the Cxsmo / upstream `com.nuvio.tv.test` build, so both can be installed on the same Shield.

Kotlin source namespace stays `com.nuvio.tv`. FileProvider authority is `${applicationId}.fileprovider` and follows the new ID automatically.

The `nuvio://` and `stremio://` deep-link schemes are unchanged. If both apps are installed, Android may ask which one should open those links.

## Signing

Local `assembleFullDebug` uses the **persistent Android debug keystore**:

`%USERPROFILE%\.android\debug.keystore`

alias `androiddebugkey`. Later debug builds update over each other.

GitHub OTA / `.\build-local.ps1 -Release` uses a **different permanent certificate**:

`%USERPROFILE%\.android\nuvio-tolu-release.jks`

alias `nuvio-tolu`. Passwords live only in `%USERPROFILE%\.android\nuvio-tolu-release.env` or environment variables. That keystore is outside the repo.

A debug-signed install **cannot** be updated by a release-signed APK. Uninstall the debug build once, then install the first OTA release. After that, later OTA APKs update in place.

Do not commit keystores or passwords.

## Expected times (this PC: Ryzen 7 7800X3D, 32 GB, 990 Pro)

| Build | Typical |
| --- | --- |
| First FullDebug (deps + native) | 15–40 min |
| Incremental after a small Kotlin change | 1–5 min |
| Incremental with `-Fast` once the daemon is warm | often under 2 min |
| `-Clean` | closer to a first build |

Gradle heap is 8 GB and the Kotlin daemon is 6 GB (`gradle.properties`). That leaves RAM for Android Studio, Chrome, and the OS. If Kotlin reports `OOMErrorException`, stop daemons with `.\gradlew.bat --stop` and rebuild.

## ADB / Nvidia Shield

`-Install` never uninstalls an app. It only runs `adb install -r` when **exactly one** device is connected.

No device: the build still succeeds. Multiple devices: install is skipped; use `adb -s <serial> install -r builds\NuvioTV-Tolu-latest.apk`.

Network ADB on a Shield:

1. Settings → Device Preferences → About → click **Build** seven times.
2. Developer options → enable **Network debugging** / ADB debugging.
3. From this PC: `adb connect <shield-ip>:5555`
4. `.\build-local.ps1 -Install`

## Troubleshooting

**Wrong Java version**  
Set `JAVA_HOME` to JDK 17. Android Studio's JBR is often 21 and will fail this project.

**SDK not found**  
Install the Android Studio SDK, or set `ANDROID_HOME` to that SDK. The script prefers `%LOCALAPPDATA%\Android\Sdk`.

**`compileSdk 36` missing**  
SDK Manager → SDK Platforms → Android 16 / API 36.

**`NDK 27.0.12077973` missing**  
SDK Manager → SDK Tools → show package details → NDK (Side by side) 27.0.12077973. Then rerun `.\build-local.ps1`.

**CMake missing**  
SDK Manager → SDK Tools → CMake 3.22.1.

**`local.properties` backend errors**  
The script rewrites the four Nuvio keys. Do not commit `local.properties`.

**Gradle wrapper / daemon issues**  
`.\gradlew.bat --stop` then `.\build-local.ps1 -Fast`. If the wrapper itself fails, check `JAVA_HOME` and that `gradle\wrapper\gradle-wrapper.jar` exists.

**Native / CMake configure failed**  
Confirm NDK 27 (not only NDK 29) is installed. This fork pins `ndkVersion = 27.0.12077973`.
