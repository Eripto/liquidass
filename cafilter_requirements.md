## Native CAFilter Requirements for iOS 12

To investigate and potentially implement Option A (the true native `CAFilter` live-backdrop registered in backboardd) on iOS 12, the following read-only data from your jailbroken iOS 12 device is required. This information is necessary to safely recover private QuartzCore structures and function signatures without guessing, which could cause a system-wide crash.

### Required Files/Data:

1.  **QuartzCore Binary / dyld Shared Cache:**
    *   **If iOS 12 provides a standalone `QuartzCore.framework` binary:** Please copy `/System/Library/Frameworks/QuartzCore.framework/QuartzCore` (or the equivalent executable path) from the device.
    *   **If QuartzCore is only in the dyld shared cache (more likely):** You will need to extract the `QuartzCore` image from the dyld shared cache. Tools like `dyldex` or `dsc_extractor` (from Apple's open source dyld) can do this. The cache is typically located at `/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64`. Provide the extracted `QuartzCore` Mach-O file.

2.  **OS and Build Metadata:**
    *   Provide the exact iOS version (e.g., 12.5.7) and build number (e.g., 16H81) of the test device. This helps cross-reference known structures if multiple iOS 12 versions exist.

3.  **Optional: backboardd / LiquidAss Logs (if a test build is run):**
    *   If we eventually create a test build that attempts symbol resolution on-device (without registering), providing the contents of `/var/mobile/Library/Preferences/dylv.liquidass-diagnostics.log` will be crucial to see what `LGSymbolResolver` finds.

### What Information We Need to Derive Safely:

From the `QuartzCore` binary, we will analyze the assembly (e.g., using Hopper, IDA, or Ghidra) to definitively identify:

*   **`CA::Render::add_filter` Call Cluster & Target:** Verify the exact instruction sequence used to register filters.
*   **Filter Table Layout & Initialization:** Confirm the local static address and how the table is structured.
*   **Gaussian Filter Context (`g_gaussCtxValue`):** Confirm the context static address and the layout of the `FilterSubclass` vtable.
*   **Render Vtable Slot:** Recover and validate the base forwarder for the render callback on iOS 12.
*   **`MetalContext` Command Buffer Offset:** Decode the iOS 12 `start_command_buffer` function to find the exact struct offset used to access the command buffer.
*   **Compositor Surface Texture (`g_sourceTextureOffset` etc.):** Establish the iOS 12 surface type and texture representation offsets (it may not be `0x58` as it is on newer versions).

### Instructions for the User:

Please transfer the extracted `QuartzCore` Mach-O binary (from the shared cache or framework folder) to your computer. You can then provide it via a secure link or analyze it locally if you are comfortable finding the offsets mentioned above. Do **not** modify any system files on your device to obtain this.
