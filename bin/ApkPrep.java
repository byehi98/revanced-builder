import com.reandroid.apk.ApkModule;
import com.reandroid.app.AndroidManifest;
import com.reandroid.arsc.chunk.xml.AndroidManifestBlock;
import com.reandroid.arsc.chunk.xml.ResXmlElement;
import com.reandroid.arsc.chunk.xml.ResXmlAttribute;
import com.reandroid.arsc.value.ValueType;
import java.io.File;

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
                        ResXmlAttribute attr = manifestEl.getOrCreateAndroidAttribute(AndroidManifest.NAME_versionCode, AndroidManifest.ID_versionCode);
                        attr.setValueType(ValueType.DEC);
                        attr.setData(2147483647);
                    }
                }
            } catch (Exception e) {
                System.err.println("Warning: failed to set versionCode: " + e.getMessage());
            }

            if (isModule) {
                for (com.reandroid.archive.InputSource srcEntry : module.listNativeLibraryFiles()) {
                    module.removeInputSource(srcEntry.getName());
                }
            } else {
                for (com.reandroid.archive.InputSource srcEntry : module.listNativeLibraryFiles()) {
                    String name = srcEntry.getName();
                    boolean remove = false;
                    if ("arm64-v8a".equals(arch)) {
                        remove = name.startsWith("lib/armeabi-v7a/") || name.startsWith("lib/x86_64/") || name.startsWith("lib/x86/");
                    } else if ("arm-v7a".equals(arch) || "armeabi-v7a".equals(arch)) {
                        remove = name.startsWith("lib/arm64-v8a/") || name.startsWith("lib/x86_64/") || name.startsWith("lib/x86/");
                    } else if ("x86".equals(arch)) {
                        remove = name.startsWith("lib/arm64-v8a/") || name.startsWith("lib/x86_64/") || name.startsWith("lib/armeabi-v7a/");
                    } else if ("x86_64".equals(arch)) {
                        remove = name.startsWith("lib/arm64-v8a/") || name.startsWith("lib/armeabi-v7a/") || name.startsWith("lib/x86/");
                    } else if ("all".equals(arch) || "universal".equals(arch) || "noarch".equals(arch)) {
                        remove = name.startsWith("lib/x86_64/") || name.startsWith("lib/x86/");
                    }
                    if (remove) {
                        module.removeInputSource(name);
                    }
                }
            }
            module.writeApk(out);
        } catch (Exception e) {
            System.err.println("Error prepping APK: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }
}
