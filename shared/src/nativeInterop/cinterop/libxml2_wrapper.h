#include <string.h>
#include <stdio.h>
#include <libxml/HTMLparser.h>
#include <libxml/HTMLtree.h>
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>

enum {
    LEGADO_XPATH_NODESET = XPATH_NODESET,
    LEGADO_XPATH_BOOLEAN = XPATH_BOOLEAN,
    LEGADO_XPATH_NUMBER = XPATH_NUMBER,
    LEGADO_XPATH_STRING = XPATH_STRING,
    LEGADO_XML_ELEMENT_NODE = XML_ELEMENT_NODE,
    LEGADO_XML_ATTRIBUTE_NODE = XML_ATTRIBUTE_NODE,
    LEGADO_XML_TEXT_NODE = XML_TEXT_NODE,
    LEGADO_XML_CDATA_SECTION_NODE = XML_CDATA_SECTION_NODE,
    LEGADO_XML_COMMENT_NODE = XML_COMMENT_NODE
};

/* JsoupXPath matches unprefixed XML elements regardless of the default namespace. */
static inline void legado_xpath_clear_default_element_namespaces(xmlNodePtr root) {
    xmlNodePtr node = root;
    while (node != NULL) {
        if (node->type == XML_ELEMENT_NODE && node->ns != NULL && node->ns->prefix == NULL) {
            xmlSetNs(node, NULL);
        }
        if (node->type == XML_ELEMENT_NODE && node->children != NULL) {
            node = node->children;
            continue;
        }
        while (node != root && node->next == NULL) node = node->parent;
        if (node == root) break;
        node = node->next;
    }
}

static inline xmlDocPtr legado_xpath_read_document(const char *content, int isXml) {
    if (content == NULL) {
        return NULL;
    }
    /* Kotlin strings cross cinterop as UTF-8; source charset declarations are already decoded. */
    if (isXml) {
        xmlDocPtr document = xmlReadMemory(
            content,
            (int)strlen(content),
            NULL,
            "UTF-8",
            XML_PARSE_RECOVER | XML_PARSE_NOERROR | XML_PARSE_NOWARNING
        );
        if (document != NULL) {
            legado_xpath_clear_default_element_namespaces(xmlDocGetRootElement(document));
        }
        return document;
    }
    return htmlReadMemory(
        content,
        (int)strlen(content),
        NULL,
        "UTF-8",
        HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING
    );
}

static inline xmlXPathObjectPtr legado_xpath_eval_at_path(
    xmlDocPtr document,
    const char *contextPath,
    const char *expression
) {
    if (document == NULL || expression == NULL) {
        return NULL;
    }
    xmlXPathContextPtr context = xmlXPathNewContext(document);
    if (context == NULL) {
        return NULL;
    }
    xmlNodePtr root = xmlDocGetRootElement(document);
    if (root != NULL) {
        context->node = root;
    }
    if (contextPath != NULL) {
        xmlXPathObjectPtr selected = xmlXPathEvalExpression((const xmlChar *)contextPath, context);
        if (selected == NULL || selected->type != XPATH_NODESET ||
            selected->nodesetval == NULL || selected->nodesetval->nodeNr == 0) {
            if (selected != NULL) xmlXPathFreeObject(selected);
            xmlXPathFreeContext(context);
            return NULL;
        }
        context->node = selected->nodesetval->nodeTab[0];
        xmlXPathFreeObject(selected);
    }
    xmlXPathObjectPtr result = xmlXPathEvalExpression((const xmlChar *)expression, context);
    xmlXPathFreeContext(context);
    return result;
}

static inline xmlXPathObjectPtr legado_xpath_eval(xmlDocPtr document, const char *expression) {
    return legado_xpath_eval_at_path(document, NULL, expression);
}

/* Element-only positions avoid namespace prefixes and remain stable after reparsing. */
static inline xmlChar *legado_xml_element_path(xmlNodePtr node) {
    xmlBufferPtr buffer = xmlBufferCreate();
    if (buffer == NULL) return NULL;
    while (node != NULL && node->type == XML_ELEMENT_NODE) {
        int position = 1;
        for (xmlNodePtr sibling = node->prev; sibling != NULL; sibling = sibling->prev) {
            if (sibling->type == XML_ELEMENT_NODE) position++;
        }
        char segment[48];
        int length = snprintf(segment, sizeof(segment), "/*[%d]", position);
        if (length < 0 || length >= (int)sizeof(segment) ||
            xmlBufferAddHead(buffer, (const xmlChar *)segment, length) != 0) {
            xmlBufferFree(buffer);
            return NULL;
        }
        node = node->parent;
    }
    xmlChar *path = xmlBufferLength(buffer) > 0 ? xmlStrdup(xmlBufferContent(buffer)) : NULL;
    xmlBufferFree(buffer);
    return path;
}

static inline int legado_xpath_result_type(xmlXPathObjectPtr result) {
    return result == NULL ? -1 : result->type;
}

static inline int legado_xpath_nodes_count(xmlXPathObjectPtr result) {
    if (result == NULL || result->nodesetval == NULL) {
        return 0;
    }
    return result->nodesetval->nodeNr;
}

static inline xmlNodePtr legado_xpath_node_at(xmlXPathObjectPtr result, int index) {
    if (result == NULL || result->nodesetval == NULL) {
        return NULL;
    }
    if (index < 0 || index >= result->nodesetval->nodeNr) {
        return NULL;
    }
    return result->nodesetval->nodeTab[index];
}

static inline const xmlChar *legado_xpath_string_value(xmlXPathObjectPtr result) {
    return result == NULL ? NULL : result->stringval;
}

static inline int legado_xpath_bool_value(xmlXPathObjectPtr result) {
    return result == NULL ? 0 : result->boolval;
}

static inline double legado_xpath_number_value(xmlXPathObjectPtr result) {
    return result == NULL ? 0.0 : result->floatval;
}

static inline int legado_xml_node_type(xmlNodePtr node) {
    return node == NULL ? -1 : node->type;
}

static inline xmlChar *legado_xml_node_content(xmlNodePtr node) {
    return node == NULL ? NULL : xmlNodeGetContent(node);
}

static inline int legado_xml_ascii_name_part_equal(
    const char *name, const xmlChar *part, size_t length
) {
    for (size_t index = 0; index < length; index++) {
        unsigned char left = (unsigned char)name[index];
        unsigned char right = part[index];
        if (left >= 'A' && left <= 'Z') left += 'a' - 'A';
        if (right >= 'A' && right <= 'Z') right += 'a' - 'A';
        if (left != right) return 0;
    }
    return 1;
}

/* Compare the full lexical QName, not its namespace URI. */
static inline int legado_xml_attribute_name_matches(
    const char *qualifiedName, const xmlChar *prefix, const xmlChar *localName
) {
    if (localName == NULL) return 0;
    size_t nameLength = strlen(qualifiedName);
    size_t localLength = strlen((const char *)localName);
    if (prefix == NULL || prefix[0] == '\0') {
        return nameLength == localLength &&
            legado_xml_ascii_name_part_equal(qualifiedName, localName, localLength);
    }
    size_t prefixLength = strlen((const char *)prefix);
    return nameLength == prefixLength + 1 + localLength &&
        qualifiedName[prefixLength] == ':' &&
        legado_xml_ascii_name_part_equal(qualifiedName, prefix, prefixLength) &&
        legado_xml_ascii_name_part_equal(qualifiedName + prefixLength + 1, localName, localLength);
}

/* Returns an owned copy (including empty values); free with legado_xml_free_ptr.
 * NULL means absent/invalid input or allocation failure; no document pointer escapes. */
static inline xmlChar *legado_xml_attribute_value(xmlNodePtr node, const char *qualifiedName) {
    if (node == NULL || node->type != XML_ELEMENT_NODE || qualifiedName == NULL) return NULL;
    for (xmlAttrPtr attr = node->properties; attr != NULL; attr = attr->next) {
        const xmlChar *prefix = attr->ns == NULL ? NULL : attr->ns->prefix;
        if (legado_xml_attribute_name_matches(qualifiedName, prefix, attr->name)) {
            xmlChar *value = xmlNodeListGetString(node->doc, attr->children, 1);
            return value == NULL ? xmlStrdup((const xmlChar *)"") : value;
        }
    }
    /* Namespace declarations are local nsDef entries, never inherited attributes. */
    for (xmlNsPtr ns = node->nsDef; ns != NULL; ns = ns->next) {
        const xmlChar *prefix = ns->prefix == NULL ? NULL : (const xmlChar *)"xmlns";
        const xmlChar *name = ns->prefix == NULL ? (const xmlChar *)"xmlns" : ns->prefix;
        if (legado_xml_attribute_name_matches(qualifiedName, prefix, name)) {
            return xmlStrdup(ns->href == NULL ? (const xmlChar *)"" : ns->href);
        }
    }
    return NULL;
}

static inline xmlChar *legado_xml_node_dump(xmlDocPtr document, xmlNodePtr node) {
    if (document == NULL || node == NULL) {
        return NULL;
    }
    xmlBufferPtr buffer = xmlBufferCreate();
    if (buffer == NULL) {
        return NULL;
    }
    if (xmlNodeDump(buffer, document, node, 0, 1) < 0) {
        xmlBufferFree(buffer);
        return NULL;
    }
    xmlChar *dumped = xmlStrdup(xmlBufferContent(buffer));
    xmlBufferFree(buffer);
    return dumped;
}

/**
 * Dump the inner HTML of a node (all children serialized, without the node itself).
 */
static inline xmlChar *legado_xml_node_inner_dump(xmlDocPtr document, xmlNodePtr node) {
    if (document == NULL || node == NULL) {
        return NULL;
    }
    xmlBufferPtr buffer = xmlBufferCreate();
    if (buffer == NULL) {
        return NULL;
    }
    xmlNodePtr child = node->children;
    while (child != NULL) {
        xmlNodeDump(buffer, document, child, 0, 0);
        child = child->next;
    }
    xmlChar *dumped = xmlStrdup(xmlBufferContent(buffer));
    xmlBufferFree(buffer);
    return dumped;
}

static inline void legado_xml_free_doc(xmlDocPtr document) {
    if (document != NULL) {
        xmlFreeDoc(document);
    }
}

static inline void legado_xml_free_xpath(xmlXPathObjectPtr result) {
    if (result != NULL) {
        xmlXPathFreeObject(result);
    }
}

static inline void legado_xml_free_ptr(void *pointer) {
    if (pointer != NULL) {
        xmlFree(pointer);
    }
}
