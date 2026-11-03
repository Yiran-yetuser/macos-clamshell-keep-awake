// mirror —— 把「内建屏」镜像到指定的另一块屏上（让那块屏成为主屏/母屏）
//
// 为什么需要它：
//   合盖后如果只是关背光，远程抓到的还是内建屏 3:2 的画面，塞进 16:10/16:9 的
//   客户端窗口会被缩放，画面发软。把内建屏「镜像到」一块 2560×1600@2x 的虚拟屏上，
//   虚拟屏就成了母屏（主屏），桌面按 5120×3200 渲染，远程拿到精确 16:10 的高清画面；
//   内建屏作为从屏会被系统关闭（active=0），物理上也不亮，开盖时解除镜像即恢复。
//
// 用法：
//   mirror <主屏id>   内建屏镜像到 <主屏id> 上
//   mirror off        解除内建屏镜像（恢复独立排列）
//
// 注意：方向很重要。让虚拟屏镜像到内建屏（反过来）会导致合盖后内建屏消失、
//      虚拟屏分辨率塌陷（实测 800×520），所以本工具固定「内建屏作从屏」。
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

static CGDirectDisplayID find_builtin(void) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return kCGNullDirectDisplay;
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayIsBuiltin(ids[i])) return ids[i];
    }
    return kCGNullDirectDisplay;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            printf("用法: mirror <主屏id> | mirror off\n");
            return 2;
        }
        CGDirectDisplayID slave = find_builtin();
        if (slave == kCGNullDirectDisplay) {
            printf("错误: 找不到内建屏\n");
            return 3;
        }
        CGDirectDisplayID master = kCGNullDirectDisplay;
        if (strcmp(argv[1], "off") != 0) {
            master = (CGDirectDisplayID)atoi(argv[1]);
            if (master == 0) { printf("错误: 主屏 id 无效\n"); return 4; }
        }
        CGDisplayConfigRef cfg = NULL;
        CGError e0 = CGBeginDisplayConfiguration(&cfg);
        CGError e1 = CGConfigureDisplayMirrorOfDisplay(cfg, slave, master);
        CGError e2 = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        printf("内建屏(id=%u) %s → %s  (begin=%d mirror=%d complete=%d)\n",
               (unsigned)slave,
               (master == kCGNullDirectDisplay ? "解除镜像" : "镜像"),
               (master == kCGNullDirectDisplay ? "独立排列" : "指定主屏"),
               e0, e1, e2);
        return (e0 == kCGErrorSuccess && e1 == kCGErrorSuccess && e2 == kCGErrorSuccess) ? 0 : 1;
    }
}
