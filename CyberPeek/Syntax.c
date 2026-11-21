#include "SyntaxInternal.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define LANG(name) const TSLanguage *tree_sitter_##name(void)
LANG(swift); LANG(javascript); LANG(typescript); LANG(tsx); LANG(json); LANG(python); LANG(c); LANG(bash);

struct VSParser {
    TSParser *parser;
    VSMarkdown *markdown;
    TSTree *tree;
    uint16_t *text;
    uint32_t length, count, capacity;
    VSToken *tokens;
};

const TSLanguage *vs_code_language(const char *ext) {
    const TSLanguage *lang = NULL;
    if (!strcmp(ext,"swift")) lang = tree_sitter_swift();
    else if (!strcmp(ext,"js") || !strcmp(ext,"jsx") || !strcmp(ext,"mjs") || !strcmp(ext,"cjs")) lang = tree_sitter_javascript();
    else if (!strcmp(ext,"ts")) lang = tree_sitter_typescript();
    else if (!strcmp(ext,"tsx")) lang = tree_sitter_tsx();
    else if (!strcmp(ext,"py")) lang = tree_sitter_python();
    else if (!strcmp(ext,"json")) lang = tree_sitter_json();
    else if (!strcmp(ext,"c") || !strcmp(ext,"h")) lang = tree_sitter_c();
    else if (!strcmp(ext,"sh") || !strcmp(ext,"bash")) lang = tree_sitter_bash();
    return lang;
}

VSParser *vs_create(const char *ext) {
    bool markdown = !strcmp(ext,"md") || !strcmp(ext,"markdown");
    const TSLanguage *lang = markdown ? tree_sitter_markdown() : vs_code_language(ext);
    if (!lang) return NULL;
    VSParser *p = calloc(1,sizeof(*p));
    p->parser = ts_parser_new();
    if (!ts_parser_set_language(p->parser,lang)) { vs_destroy(p); return NULL; }
    if (markdown && !(p->markdown = vs_markdown_new())) { vs_destroy(p); return NULL; }
    return p;
}

bool vs_is_markdown(const VSParser *p) { return p && p->markdown; }

void vs_destroy(VSParser *p) {
    if (!p) return;
    ts_tree_delete(p->tree);
    ts_parser_delete(p->parser);
    vs_markdown_delete(p->markdown);
    free(p->text); free(p->tokens); free(p);
}

static TSPoint advance(TSPoint point, const uint16_t *s, uint32_t from, uint32_t to) {
    for (uint32_t i=from; i<to; ++i) {
        if (s[i] == '\n') { point.row++; point.column=0; }
        else point.column += 2;
    }
    return point;
}

static int token_color(TSNode node) {
    const char *kind = ts_node_type(node);
    if (strstr(kind,"comment")) return 1;
    if (strstr(kind,"string_literal") || !strcmp(kind,"string") || !strcmp(kind,"template_string") ||
        !strcmp(kind,"raw_string") || !strcmp(kind,"string_content") || !strcmp(kind,"char_literal")) return 2;
    if (strstr(kind,"number") || strstr(kind,"integer") || strstr(kind,"float") ||
        !strcmp(kind,"true") || !strcmp(kind,"false") || !strcmp(kind,"null") || !strcmp(kind,"nil")) return 3;
    if (strstr(kind,"type_identifier") || !strcmp(kind,"type_name") || !strcmp(kind,"primitive_type")) return 5;
    if (!ts_node_is_named(node) && isalpha((unsigned char)kind[0])) return 4;
    if ((strstr(kind,"identifier") || !strcmp(kind,"name")) && !ts_node_child_count(node)) {
        TSNode parent = ts_node_parent(node);
        if (!ts_node_is_null(parent)) {
            const char *pk = ts_node_type(parent);
            if (strstr(pk,"function") || strstr(pk,"call")) return 6;
        }
    }
    return 0;
}

static void append_token(void *context, uint32_t start, uint32_t end, uint8_t color, uint8_t traits) {
    VSParser *p = context;
    if (p->count == p->capacity) {
        p->capacity = p->capacity ? p->capacity*2 : 256;
        p->tokens = realloc(p->tokens, p->capacity * sizeof(VSToken));
    }
    p->tokens[p->count++] = (VSToken){start, end-start, color, traits};
}

void vs_walk_code(TSNode root, VSEmit emit, void *context) {
    const TSLanguage *lang = ts_node_language(root);
    TSFieldId json_key = lang == tree_sitter_json() ? ts_language_field_id_for_name(lang, "key", 3) : 0;
    TSTreeCursor cursor = ts_tree_cursor_new(root);
    for (;;) {
        TSNode node = ts_tree_cursor_current_node(&cursor);
        int color = json_key && ts_tree_cursor_current_field_id(&cursor) == json_key ? 7 : token_color(node);
        if (color) {
            emit(context, ts_node_start_byte(node)/2, ts_node_end_byte(node)/2, color, 0);
        } else if (ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts_tree_cursor_goto_parent(&cursor)) {
                ts_tree_cursor_delete(&cursor);
                return;
            }
        }
    }
}

const VSToken *vs_highlight(VSParser *p, const uint16_t *source, uint32_t length, uint32_t *count) {
    *count=0;
    // The Markdown block grammar needs a line ending to finish some blocks at EOF.
    uint32_t n = length;
    uint16_t *s = malloc((length + 2) * sizeof(*s));
    if (!s) return NULL;
    if (length) memcpy(s, source, length * sizeof(*s));
    if (p->markdown && length && s[length-1] != '\n') s[n++] = '\n';
    s[n] = 0;
    if (p->tree) {
        uint32_t a=0, old=p->length, end=n;
        while (a<old && a<end && p->text[a]==s[a]) a++;
        while (end>a && old>a && p->text[old-1]==s[end-1]) { old--; end--; }
        TSPoint start=advance((TSPoint){0,0},s,0,a);
        TSInputEdit edit={a*2,old*2,end*2,start,advance(start,p->text,a,old),advance(start,s,a,end)};
        ts_tree_edit(p->tree,&edit);
    }
    TSTree *tree=ts_parser_parse_string_encoding(p->parser,p->tree,(const char *)s,n*2,TSInputEncodingUTF16LE);
    ts_tree_delete(p->tree); p->tree=tree;
    free(p->text); p->text=s;
    p->length=n; p->count=0;
    if (!tree) return NULL;
    TSNode root = ts_tree_root_node(tree);
    if (p->markdown) vs_markdown_highlight(p->markdown,root,s,n,length,append_token,p);
    else vs_walk_code(root,append_token,p);
    *count=p->count;
    return p->tokens;
}
