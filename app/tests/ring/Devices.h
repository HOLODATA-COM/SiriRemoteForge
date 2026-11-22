#include "MultitouchSupport.h"

void replaceFirstService(void);
void refreshFirstWrapper(void);
void failNextStart(void);
int startCount(int handle);
int stopCount(int handle);
void emitFrame(int handle, MTTouch *touches, size_t count, double timestamp);
