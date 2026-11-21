#ifndef CYBERPEEK_SYNTAX_H
#define CYBERPEEK_SYNTAX_H
#include <stdbool.h>
#include <stdint.h>
typedef struct VSParser VSParser;
enum { VSBold = 1, VSItalic = 2, VSStrike = 4 };
typedef struct { uint32_t start, length; uint8_t color, traits; } VSToken;
VSParser *vs_create(const char *extension);
bool vs_is_markdown(const VSParser *parser);
void vs_destroy(VSParser *parser);
const VSToken *vs_highlight(VSParser *parser, const uint16_t *text, uint32_t length, uint32_t *count);
#endif
