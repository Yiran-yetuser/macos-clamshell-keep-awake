// setbright —— 读取/设置「主显示器」的背光亮度（用于合盖时把内建屏调暗但保持渲染）
//
// 为什么需要它：`pmset displaysleepnow` 会让整块屏休眠，屏幕捕获随之返回纯黑；
//              而把背光调到 0 只是关掉背光，WindowServer 仍在渲染，
//              远程桌面照样能抓到完整画面（本机实测：背光 0 时截图亮度均值仍 ~200）。
//
// 用法：  setbright            输出当前亮度（0.000 ~ 1.000）
//         setbright 0.0        设为 0（全暗），并输出设置后的值
//         setbright 0.421      恢复原亮度
// 编译：  clang -fno-objc-arc -framework Foundation -framework CoreGraphics -o setbright setbright.m
// 注意：  使用 macOS 私有框架 DisplayServices；返回码 0 表示成功。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <stdlib.h>

typedef int (*FnSet)(CGDirectDisplayID, float);
typedef int (*FnGet)(CGDirectDisplayID, float *);

int main(int argc, char **argv) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
        if (!h) { fprintf(stderr, "错误: 无法加载 DisplayServices 框架\n"); return 1; }
        FnSet setB = (FnSet)dlsym(h, "DisplayServicesSetBrightness");
        FnGet getB = (FnGet)dlsym(h, "DisplayServicesGetBrightness");
        if (!setB || !getB) { fprintf(stderr, "错误: 找不到亮度接口\n"); return 2; }

        CGDirectDisplayID d = CGMainDisplayID();
        float cur = -1.0f;
        if (getB(d, &cur) != 0) { fprintf(stderr, "错误: 读取亮度失败\n"); return 3; }

        if (argc > 1) {
            float v = (float)atof(argv[1]);
            if (v < 0.0f) v = 0.0f;
            if (v > 1.0f) v = 1.0f;
            if (setB(d, v) != 0) { fprintf(stderr, "错误: 设置亮度失败\n"); return 4; }
            getB(d, &cur);
        }
        printf("%.3f\n", cur);
    }
    return 0;
}
