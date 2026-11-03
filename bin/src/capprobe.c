#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <dlfcn.h>
extern int CGDisplayIsCaptured(CGDirectDisplayID);  /* private/deprecated */
int main(void){
  void *h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
  int (*iscap)(CGDirectDisplayID) = (int(*)(CGDirectDisplayID))dlsym(h, "CGDisplayIsCaptured");
  uint32_t n=0; CGGetOnlineDisplayList(0,NULL,&n);
  CGDirectDisplayID ids[16]; CGGetOnlineDisplayList(16,ids,&n);
  printf("CGDisplayIsCaptured 符号: %s\n", iscap ? "可用" : "不存在");
  for(uint32_t i=0;i<n;i++){
    printf("id=%u builtin=%d captured=%d\n", ids[i], CGDisplayIsBuiltin(ids[i]), iscap?iscap(ids[i]):-1);
  }
  return 0;
}
