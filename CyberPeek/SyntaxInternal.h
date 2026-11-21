#pragma once
#include "Syntax.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#include "api.h"
#pragma clang diagnostic pop

typedef void (*VSEmit)(void *context, uint32_t start, uint32_t end, uint8_t color, uint8_t traits);
const TSLanguage *vs_code_language(const char *name);
void vs_walk_code(TSNode root, VSEmit emit, void *context);

typedef struct VSMarkdown VSMarkdown;
const TSLanguage *tree_sitter_markdown(void);
VSMarkdown *vs_markdown_new(void);
void vs_markdown_delete(VSMarkdown *markdown);
void vs_markdown_highlight(VSMarkdown *markdown, TSNode root, const uint16_t *text, uint32_t parse_length,
                           uint32_t source_length, VSEmit emit, void *context);
