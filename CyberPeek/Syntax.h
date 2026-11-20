#include <stdint.h>
typedef struct VSParser VSParser;
typedef struct { uint32_t start, length; int color; } VSToken;
VSParser *vs_create(const char *extension);
void vs_destroy(VSParser *parser);
const VSToken *vs_highlight(VSParser *parser, const uint16_t *text, uint32_t length, uint32_t *count);
