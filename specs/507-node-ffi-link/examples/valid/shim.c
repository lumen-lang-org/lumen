#include <stdlib.h>
#include <string.h>
int shim_add(int a, int b) { return a + b; }
const char *shim_greet(const char *name) { static char buf[64]; strcpy(buf, "hello "); strncat(buf, name, 40); return buf; }
