#include <stdio.h>
#include <string.h>
#include <zlib.h>

int main(void) {
  static const char input[] = "manylinux-2-28 zlib closure proof";
  unsigned char compressed[256];
  unsigned char restored[sizeof(input)];
  uLong compressed_size = sizeof(compressed);
  uLong restored_size = sizeof(restored);

  if (compress2(compressed, &compressed_size,
                (const Bytef *) input, sizeof(input), Z_BEST_COMPRESSION) != Z_OK)
    return 1;
  if (uncompress(restored, &restored_size, compressed, compressed_size) != Z_OK)
    return 2;
  if (restored_size != sizeof(input) || memcmp(restored, input, sizeof(input)) != 0)
    return 3;

  puts(zlibVersion());
  return 0;
}
