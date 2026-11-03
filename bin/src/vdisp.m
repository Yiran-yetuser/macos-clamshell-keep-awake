// vdisp —— 创建一个「虚拟显示器」并保持存活，直到进程被杀死
//
// 用途：笔记本合盖后 macOS 会停止渲染内建屏，导致任何基于屏幕捕获的远程桌面
//      （RustDesk / ToDesk / VNC）只能抓到纯黑画面。创建一个虚拟显示器后，
//      系统会保持「桌面模式」继续渲染，远程桌面就能看到真实画面。
//
// 用法：  vdisp [宽] [高] [hiDPI] [mirror]   默认 1470 956 1，扩展模式
//         默认是「扩展屏」：内建屏仍是主屏、继续渲染（合盖后远程抓内建屏即可）。
//         注意：不要用 mirror 模式——实测合盖后内建屏会从显示器列表消失、分辨率掉到
//         800×520，远程画面会非常模糊。
//         vdisp --size                 打印主屏（内建屏）当前逻辑尺寸与物理像素后退出
// 编译：  clang -fno-objc-arc -framework Foundation -framework CoreGraphics -o vdisp vdisp.m
// 注意：  使用 macOS 私有 API（CGVirtualDisplay），系统升级后可能需要重新验证。
//        进程必须运行在图形登录会话里（root 的 LaunchDaemon 无法创建显示器）。
// 说明：  杀进程要用 kill -9（SIGTERM 会被忽略），进程退出后虚拟显示器自动消失。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>

static id M0(id o, const char *s) { return ((id(*)(id,SEL))objc_msgSend)(o, sel_registerName(s)); }
static void MVui(id o, const char *s, unsigned int v) { ((void(*)(id,SEL,unsigned int))objc_msgSend)(o, sel_registerName(s), v); }
static void MVd2(id o, const char *s, double a, double b) { ((void(*)(id,SEL,double,double))objc_msgSend)(o, sel_registerName(s), a, b); }

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc > 1 && strcmp(argv[1], "--size") == 0) {
      CGDirectDisplayID mainID = CGMainDisplayID();
      CGRect b = CGDisplayBounds(mainID);
      printf("%.0f %.0f %zu %zu\n", b.size.width, b.size.height,
             CGDisplayPixelsWide(mainID), CGDisplayPixelsHigh(mainID));
      return 0;
    }
    int W  = argc > 1 ? atoi(argv[1]) : 1470;
    int H  = argc > 2 ? atoi(argv[2]) : 956;
    int hi = argc > 3 ? atoi(argv[3]) : 1;
    int mirror = (argc > 4 && strcmp(argv[4], "mirror") == 0);
    if (W <= 0 || H <= 0) { printf("用法: vdisp [宽] [高] [hiDPI]\n"); return 2; }
    int scale = hi ? 2 : 1;

    Class cDesc = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class cDisp = NSClassFromString(@"CGVirtualDisplay");
    Class cSet  = NSClassFromString(@"CGVirtualDisplaySettings");
    Class cMode = NSClassFromString(@"CGVirtualDisplayMode");
    if (!cDesc || !cDisp || !cSet || !cMode) {
      printf("错误: 系统不提供 CGVirtualDisplay 私有类（系统版本可能不兼容）\n");
      return 1;
    }

    id desc = M0((id)cDesc, "new");
    ((void(*)(id,SEL,id))objc_msgSend)(desc, sel_registerName("setName:"), @"YyzVirtualDisplay");
    ((void(*)(id,SEL,void*))objc_msgSend)(desc, sel_registerName("setQueue:"), (void *)dispatch_get_main_queue());
    MVui(desc, "setVendorID:", 0x3456);
    MVui(desc, "setProductID:", 0x1234);
    MVui(desc, "setSerialNum:", 4477);
    MVui(desc, "setMaxPixelsWide:", (unsigned)(W * scale));
    MVui(desc, "setMaxPixelsHigh:", (unsigned)(H * scale));
    MVd2(desc, "setSizeInMillimeters:", (double)W * 0.2, (double)H * 0.2);

    id disp = M0((id)cDisp, "alloc");
    disp = ((id(*)(id,SEL,id))objc_msgSend)(disp, sel_registerName("initWithDescriptor:"), desc);
    if (!disp) { printf("错误: 虚拟显示器初始化失败\n"); return 3; }

    id mode = M0((id)cMode, "alloc");
    mode = ((id(*)(id,SEL,unsigned,unsigned,double))objc_msgSend)(mode, sel_registerName("initWithWidth:height:refreshRate:"),
                                                                  (unsigned)W, (unsigned)H, 60.0);
    id st = M0((id)cSet, "new");
    MVui(st, "setHiDPI:", (unsigned)hi);
    id arr = [NSMutableArray array];
    [arr addObject:mode];
    ((void(*)(id,SEL,id))objc_msgSend)(st, sel_registerName("setModes:"), arr);

    BOOL ok = ((BOOL(*)(id,SEL,id))objc_msgSend)(disp, sel_registerName("applySettings:"), st);
    unsigned did = ((unsigned(*)(id,SEL))objc_msgSend)(disp, sel_registerName("displayID"));
    if (!ok) { printf("错误: applySettings 失败\n"); return 4; }

    CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
    printf("虚拟屏已创建: display=%u 逻辑=%dx%d 物理=%zux%zu scale=%d\n",
           did, W, H,
           m ? CGDisplayModeGetPixelWidth(m) : (size_t)(W * scale),
           m ? CGDisplayModeGetPixelHeight(m) : (size_t)(H * scale),
           scale);
    fflush(stdout);
    if (m) CGDisplayModeRelease(m);

    // 默认「扩展屏」：先清掉 macOS 对这块虚拟屏记住的镜像关系
    // （同一 vendorID/productID 的虚拟屏会被系统记住上次的排列，可能残留镜像设置，
    //   表现为合盖后内建屏消失、只剩低分辨率虚拟屏 → 远程画面极模糊）
    CGDisplayConfigRef cfg0 = NULL;
    if (CGBeginDisplayConfiguration(&cfg0) == kCGErrorSuccess) {
      CGError e0 = CGConfigureDisplayMirrorOfDisplay(cfg0, did, kCGNullDirectDisplay);
      CGError c0 = CGCompleteDisplayConfiguration(cfg0, kCGConfigureForSession);
      printf("独立排列(清除旧镜像): %s (e=%d complete=%d)\n",
             (e0 == kCGErrorSuccess && c0 == kCGErrorSuccess) ? "成功" : "失败", e0, c0);
      fflush(stdout);
    }

    // 仅当显式传 mirror 才镜像（默认不镜像，见文件头说明）
    if (mirror) {
      CGDirectDisplayID master = CGMainDisplayID();
      CGDisplayConfigRef cfg = NULL;
      if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
        CGError e1 = CGConfigureDisplayMirrorOfDisplay(cfg, did, master);
        CGError e2 = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        printf("镜像到主屏(%u): %s (complete=%d)\n",
               master, (e1 == kCGErrorSuccess && e2 == kCGErrorSuccess) ? "成功" : "失败", e2);
        fflush(stdout);
      }
    }

    [[NSRunLoop currentRunLoop] run];
  }
  return 0;
}
