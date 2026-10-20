# RootHide build

This fork includes a native RootHide build for `iphoneos-arm64e`.

## Build

Use https://github.com/roothide/theos (including its submodules) and an installed iPhoneOS SDK, then:

```sh
bash build.sh roothide
```

The `Build RootHide` GitHub Actions workflow builds and validates the DEB and attaches a source archive and SHA256SUMS. Other package variants retain their original control files.

## Compatibility

- Uses the official `jbroot()` resolver and `libroothide`, not a hard-coded random `.jbroot-*` folder or `/var/jb` prefix.
- Manager daemon and Settings bundle share the same preference, history, socket and log paths. RootHide data is kept inside the current jailbreak root.
- Package scripts and launchd paths are generated per scheme, rather than inferred from the presence of `/var/jb`.
- `libSandy` and PreferenceLoader must be installed from a RootHide-compatible source.
- The package contains the manager, not a bundled Frida server. An installed server and agent must themselves support the current jailbreak. An upstream rootless DEB is not automatically converted into a native RootHide Frida build.
- A successful CI build/static check is not a device runtime test. Settings entry, socket connection, start/stop, port changes, and injection/spawn must be tested on the device.
- This build does not automatically delete or import data outside the current jailbreak root. Existing rootless preferences remain untouched.

Original project and MIT license are preserved.
