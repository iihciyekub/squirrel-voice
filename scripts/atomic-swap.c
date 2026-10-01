#include <stdio.h>
#include <string.h>
#include <errno.h>

// Exchange complete directories in one filesystem operation. Never fall back
// to remove/copy: an incomplete input-method bundle can lose its registration.
int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "Usage: atomic-swap DIRECTORY DIRECTORY\n");
    return 2;
  }
  if (renamex_np(argv[1], argv[2], RENAME_SWAP) != 0) {
    fprintf(stderr, "Cannot atomically exchange directories: %s\n", strerror(errno));
    return 1;
  }
  return 0;
}
