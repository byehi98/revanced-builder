import com.reandroid.apk.ApkModule;
import com.reandroid.app.AndroidManifest;
import com.reandroid.archive.InputSource;
import com.reandroid.archive.writer.ApkFileWriter;
import com.reandroid.arsc.chunk.xml.AndroidManifestBlock;
import com.reandroid.arsc.chunk.xml.ResXmlAttribute;
import com.reandroid.arsc.chunk.xml.ResXmlElement;
import com.reandroid.arsc.value.ValueType;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/**
 * Stock-APK preparation step for the builder.
 *
 * <p>Sets a huge versionCode so the Play Store never offers an update over the patched build,
 * and drops native libraries of the architectures the requested build does not target.
 *
 * <p>Two behaviours are deliberate:
 *
 * <ul>
 *   <li><b>Never strip the only ABI.</b> A release may not publish the requested architecture
 *       at all (Dead Target 4.186.0 is armeabi-v7a only on APKPure, yet the builder also asks
 *       for an arm64-v8a build). Stripping "the other" ABIs there would delete the sole native
 *       library and produce an APK that cannot start. If the requested ABI is absent the
 *       libraries are left untouched and a warning is printed.
 *   <li><b>Write through {@code createApkFileWriter()}.</b> Recent ARSCLib dropped
 *       {@code ApkModule.writeApk(File)} (it now throws {@code NoSuchMethodError} at runtime),
 *       which silently made ApkPrep fail and the builder fall back to the unmodified stock APK —
 *       losing the versionCode bump entirely.
 * </ul>
 */
public class ApkPrep {
    public static void main(String[] args) {
        if (args.length < 2) {
            System.err.println("Usage: ApkPrep <input.apk> <output.apk> [arch] [isModule]");
            System.exit(1);
        }
        File src = new File(args[0]);
        File out = new File(args[1]);
        String arch = args.length > 2 ? args[2] : "all";
        boolean isModule = args.length > 3 && Boolean.parseBoolean(args[3]);

        try (ApkModule module = ApkModule.loadApkFile(src)) {
            try {
                AndroidManifestBlock manifest = module.getAndroidManifest();
                if (manifest != null) {
                    ResXmlElement manifestEl = manifest.getManifestElement();
                    if (manifestEl != null) {
                        ResXmlAttribute attr = manifestEl.getOrCreateAndroidAttribute(
                                AndroidManifest.NAME_versionCode, AndroidManifest.ID_versionCode);
                        attr.setValueType(ValueType.DEC);
                        attr.setData(2147483647);
                    }
                }
            } catch (Exception e) {
                System.err.println("Warning: failed to set versionCode: " + e.getMessage());
            }

            List<InputSource> nativeLibs = module.listNativeLibraryFiles();

            if (isModule) {
                for (InputSource srcEntry : nativeLibs) {
                    module.removeInputSource(srcEntry.getName());
                }
            } else if (!isUniversal(arch)) {
                String requested = normalizeArch(arch);
                if (!hasArch(nativeLibs, requested)) {
                    // Keep every shipped ABI: removing the non-requested ones would leave the
                    // APK with no native code at all and it would crash on launch.
                    System.err.println("Warning: requested ABI '" + requested
                            + "' is not in the stock APK (has: " + listArchs(nativeLibs)
                            + "); keeping shipped ABI(s) instead of stripping them");
                } else {
                    for (InputSource srcEntry : nativeLibs) {
                        String name = srcEntry.getName();
                        if (removeForArch(name, requested)) {
                            module.removeInputSource(name);
                        }
                    }
                }
            } else {
                // "universal"/"all"/"noarch": keep both ARM ABIs, drop the x86 ones.
                for (InputSource srcEntry : nativeLibs) {
                    String name = srcEntry.getName();
                    if (name.startsWith("lib/x86_64/") || name.startsWith("lib/x86/")) {
                        module.removeInputSource(name);
                    }
                }
            }

            ApkFileWriter writer = module.createApkFileWriter(out);
            try {
                writer.write();
            } finally {
                writer.close();
            }
        } catch (Exception e) {
            System.err.println("Error prepping APK: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }

    private static boolean isUniversal(String arch) {
        return "all".equals(arch) || "universal".equals(arch) || "noarch".equals(arch);
    }

    private static String normalizeArch(String arch) {
        if ("arm-v7a".equals(arch) || "armeabi-v7a".equals(arch) || "armv7".equals(arch)
                || "armv7a".equals(arch)) {
            return "armeabi-v7a";
        }
        return arch;
    }

    private static String libDir(String name) {
        if (!name.startsWith("lib/")) {
            return null;
        }
        int slash = name.indexOf('/', 4);
        return slash < 0 ? null : name.substring(4, slash);
    }

    private static boolean hasArch(List<InputSource> nativeLibs, String arch) {
        for (InputSource srcEntry : nativeLibs) {
            if (arch.equals(libDir(srcEntry.getName()))) {
                return true;
            }
        }
        return false;
    }

    private static String listArchs(List<InputSource> nativeLibs) {
        List<String> archs = new ArrayList<>();
        for (InputSource srcEntry : nativeLibs) {
            String abi = libDir(srcEntry.getName());
            if (abi != null && !archs.contains(abi)) {
                archs.add(abi);
            }
        }
        return archs.isEmpty() ? "none" : String.join(", ", archs);
    }

    private static boolean removeForArch(String name, String arch) {
        String abi = libDir(name);
        if (abi == null || abi.equals(arch)) {
            return false;
        }
        // Always drop x86/x86_64: no supported build target uses them.
        if (abi.equals("x86") || abi.equals("x86_64")) {
            return true;
        }
        // Keep any other ABI that is not one of the two ARM variants (defensive).
        return abi.equals("arm64-v8a") || abi.equals("armeabi-v7a");
    }
}
