#include "SyntaxInternal.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

const TSLanguage *tree_sitter_markdown_inline(void);

static const char block_query[] =
    "[(atx_heading) (setext_heading)] @title\n"
    "[(list_marker_plus) (list_marker_minus) (list_marker_star) (list_marker_dot)"
    " (list_marker_parenthesis) (block_quote_marker) (block_continuation) (thematic_break)"
    " (fenced_code_block_delimiter) (pipe_table_delimiter_row)] @marker\n"
    "(pipe_table_header \"|\" @marker) (pipe_table_row \"|\" @marker)\n"
    "(task_list_marker_checked) @checked\n"
    "(task_list_marker_unchecked) @marker\n"
    "[(indented_code_block) (link_title)] @literal\n"
    "(language) @language\n"
    "(link_destination) @url\n"
    "(link_label) @label\n"
    "[(inline) (pipe_table_cell)] @inline\n"
    "(code_fence_content) @fence\n";

static const char inline_query[] =
    "(strong_emphasis) @bold\n"
    "(emphasis) @italic\n"
    "(strikethrough) @strike\n"
    "[(code_span) (link_title)] @literal\n"
    "[(link_text) (link_label) (image_description)] @label\n"
    "[(link_destination) (uri_autolink) (email_autolink)] @url\n"
    "[(backslash_escape) (entity_reference) (numeric_character_reference)] @language\n";

typedef struct { uint8_t color, traits; } Ink;
typedef enum {
    Title, Marker, Checked, Literal, Language, Label, URL, Bold, Italic, Strike, Inline, Fence
} Capture;

static const struct { const char *name; Ink ink; } captures[] = {
    [Title]    = {"title",    {7, VSBold}},
    [Marker]   = {"marker",   {1, 0}},
    [Checked]  = {"checked",  {3, 0}},
    [Literal]  = {"literal",  {2, 0}},
    [Language] = {"language", {4, 0}},
    [Label]    = {"label",    {7, 0}},
    [URL]      = {"url",      {5, 0}},
    [Bold]     = {"bold",     {6, VSBold}},
    [Italic]   = {"italic",   {4, VSItalic}},
    [Strike]   = {"strike",   {1, VSStrike}},
    [Inline]   = {"inline",   {0, 0}},
    [Fence]    = {"fence",    {0, 0}}
};

typedef struct {
    TSQuery *query;
    TSQueryCursor *cursor;
    Capture by_id[sizeof(captures) / sizeof(captures[0])];
} HighlightQuery;

struct VSMarkdown {
    HighlightQuery block, span;
    TSParser *embedded;
};

static bool init_query(HighlightQuery *q, const TSLanguage *language, const char *source) {
    uint32_t offset;
    TSQueryError error;
    q->query = ts_query_new(language, source, (uint32_t)strlen(source), &offset, &error);
    if (!q->query) return false;
    q->cursor = ts_query_cursor_new();
    for (unsigned id = 0; id < ts_query_capture_count(q->query); ++id) {
        uint32_t length;
        const char *name = ts_query_capture_name_for_id(q->query, id, &length);
        unsigned k = 0;
        while (k <= Fence && (strlen(captures[k].name) != length || memcmp(name, captures[k].name, length))) ++k;
        if (k > Fence) return false;
        q->by_id[id] = (Capture)k;
    }
    return true;
}

VSMarkdown *vs_markdown_new(void) {
    VSMarkdown *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    m->embedded = ts_parser_new();
    if (init_query(&m->block, tree_sitter_markdown(), block_query) &&
        init_query(&m->span, tree_sitter_markdown_inline(), inline_query)) return m;
    vs_markdown_delete(m);
    return NULL;
}

void vs_markdown_delete(VSMarkdown *m) {
    if (!m) return;
    ts_parser_delete(m->embedded);
    if (m->block.cursor) ts_query_cursor_delete(m->block.cursor);
    if (m->span.cursor) ts_query_cursor_delete(m->span.cursor);
    ts_query_delete(m->block.query);
    ts_query_delete(m->span.query);
    free(m);
}

typedef struct {
    const uint16_t *text;
    uint32_t length;
    Ink *ink;
} Document;

static void paint(void *context, uint32_t start, uint32_t end, uint8_t color, uint8_t traits) {
    Document *doc = context;
    for (uint32_t i = start; i < end; ++i) {
        doc->ink[i].color = color;
        doc->ink[i].traits |= traits;
    }
}

static bool ascii_word(uint16_t c) {
    return c < 128 && isalnum((unsigned char)c);
}

static bool intraword_underscore(const Document *doc, uint32_t start, uint32_t end) {
    if (start == end || doc->text[start] != '_') return false;
    uint32_t content = start, closing = end;
    while (content < end && doc->text[content] == '_') ++content;
    while (closing > start && doc->text[closing-1] == '_') --closing;
    return (start && content < end && ascii_word(doc->text[start-1]) && ascii_word(doc->text[content])) ||
           (end < doc->length && closing > start && ascii_word(doc->text[closing-1]) && ascii_word(doc->text[end]));
}

// Exclude block continuations such as the "> " prefix of a quoted paragraph or fence.
// Included ranges keep all nested offsets relative to the original UTF-16 document.
static TSTree *parse_content(VSMarkdown *m, const Document *doc, TSNode node, const TSLanguage *lang) {
    if (!ts_parser_set_language(m->embedded, lang)) return NULL;
    uint32_t children = ts_node_named_child_count(node);
    TSRange single, *ranges = children ? calloc(children + 1, sizeof(TSRange)) : &single;
    if (!ranges) return NULL;
    uint32_t start = ts_node_start_byte(node), count = 0;
    TSPoint point = ts_node_start_point(node);
    for (uint32_t i = 0; i < children; ++i) {
        TSNode child = ts_node_named_child(node, i);
        if (start < ts_node_start_byte(child))
            ranges[count++] = (TSRange){point, ts_node_start_point(child), start, ts_node_start_byte(child)};
        point = ts_node_end_point(child);
        start = ts_node_end_byte(child);
    }
    if (start < ts_node_end_byte(node))
        ranges[count++] = (TSRange){point, ts_node_end_point(node), start, ts_node_end_byte(node)};
    bool included = count && ts_parser_set_included_ranges(m->embedded, ranges, count);
    if (children) free(ranges);
    if (!included) return NULL;
    return ts_parser_parse_string_encoding(m->embedded, NULL, (const char *)doc->text,
                                           doc->length * 2, TSInputEncodingUTF16LE);
}

static const TSLanguage *fence_language(TSNode content, const uint16_t *text) {
    TSNode info = ts_node_child_by_field_name(ts_node_parent(content), "info_string", 11);
    if (ts_node_is_null(info)) return NULL;
    TSNode tag = ts_node_named_child(info, 0);
    if (ts_node_is_null(tag)) return NULL;
    uint32_t start = ts_node_start_byte(tag)/2, length = ts_node_end_byte(tag)/2 - start;
    char name[32];
    if (length >= sizeof(name)) return NULL;
    for (uint32_t i = 0; i < length; ++i) {
        if (text[start+i] >= 128) return NULL;
        name[i] = (char)tolower((unsigned char)text[start+i]);
    }
    name[length] = 0;
    if (!strcmp(name, "javascript")) return vs_code_language("js");
    if (!strcmp(name, "typescript")) return vs_code_language("ts");
    if (!strcmp(name, "python")) return vs_code_language("py");
    if (!strcmp(name, "shell")) return vs_code_language("sh");
    return vs_code_language(name);
}

static void highlight_query(VSMarkdown *m, HighlightQuery *q, TSNode root, Document *doc) {
    ts_query_cursor_exec(q->cursor, q->query, root);
    TSQueryMatch match;
    uint32_t index;
    while (ts_query_cursor_next_capture(q->cursor, &match, &index)) {
        TSQueryCapture capture = match.captures[index];
        TSNode node = capture.node;
        Capture kind = q->by_id[capture.index];
        uint32_t start = ts_node_start_byte(node)/2, end = ts_node_end_byte(node)/2;
        if (kind == Inline || kind == Fence) {
            const TSLanguage *language = kind == Inline ? tree_sitter_markdown_inline() : fence_language(node, doc->text);
            TSTree *tree = language ? parse_content(m, doc, node, language) : NULL;
            if (tree) {
                if (kind == Inline) highlight_query(m, &m->span, ts_tree_root_node(tree), doc);
                else vs_walk_code(ts_tree_root_node(tree), paint, doc);
                ts_tree_delete(tree);
            } else if (kind == Fence) {
                paint(doc, start, end, captures[Literal].ink.color, 0);
            }
        } else {
            // The upstream grammar can interpret the underscores in "ota_0 or ota_1" as emphasis.
            if ((kind == Italic || kind == Bold) && intraword_underscore(doc, start, end)) continue;
            Ink ink = captures[kind].ink;
            // A multiline inline capture can span an excluded block quote prefix.
            if (kind == Marker) memset(doc->ink + start, 0, (end-start) * sizeof(Ink));
            paint(doc, start, end, ink.color, ink.traits);
        }
    }
}

void vs_markdown_highlight(VSMarkdown *m, TSNode root, const uint16_t *text, uint32_t parse_length,
                           uint32_t source_length, VSEmit emit, void *context) {
    if (!source_length) return;
    Document doc = {text, parse_length, calloc(parse_length, sizeof(Ink))};
    if (!doc.ink) return;
    highlight_query(m, &m->block, root, &doc);
    // Nested captures overlap. The editor binary-searches disjoint runs by UTF-16 offset.
    for (uint32_t start = 0; start < source_length;) {
        Ink ink = doc.ink[start];
        uint32_t end = start + 1;
        while (end < source_length && doc.ink[end].color == ink.color && doc.ink[end].traits == ink.traits) ++end;
        if (ink.color || ink.traits) emit(context, start, end, ink.color, ink.traits);
        start = end;
    }
    free(doc.ink);
}
