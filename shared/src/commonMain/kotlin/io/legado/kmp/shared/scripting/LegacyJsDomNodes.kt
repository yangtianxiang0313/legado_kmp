package io.legado.kmp.shared.scripting

// Installed in the DOM closure before Java class registration and untrusted source libraries.
internal val LEGACY_JS_DOM_NODES = """
    var domHasInstance = Symbol.hasInstance;
    var domFreeze = Object.freeze;

    function domNodeState(value) {
      if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return null;
      var state = lookup(value);
      return state && (state.kind === 'element' || state.kind === 'node') ? state : null;
    }
    function domNodeHandle(value) {
      var state = domNodeState(value);
      if (!state) throw new fail('Expected a registered DOM Node');
      return state.handle;
    }
    function domElementDescriptor(raw) { return domDescriptor(raw) && !own(raw, 'nodeType'); }
    function domNodeIndex(value, label) {
      value = number(value);
      if (!integer(value) || value < 0 || value > 2147483647) {
        throw new outOfBounds('DOM ' + label + ' out of bounds: ' + value);
      }
      return value;
    }
    function domNodeRead(wrapped, name) {
      domMethod(wrapped, name, function() {
        domArity(arguments, 0, 0, name);
        return domCall(wrapped, name, []);
      });
    }
    function domNodeString(wrapped, name) {
      domMethod(wrapped, name, function(value) {
        domArity(arguments, 1, 1, name);
        return domCall(wrapped, name, [domString(value, name)]);
      });
    }
    function domNodeMethods(wrapped) {
      var reads = ['childNodes', 'childNodeSize', 'childNodesCopy', 'siblingNodes', 'siblingIndex',
        'nextSibling', 'previousSibling', 'parent', 'parentNode', 'root', 'ownerDocument', 'hasParent',
        'nodeName', 'normalName', 'baseUri', 'outerHtml', 'empty', 'clone', 'unwrap'];
      for (var i = 0; i < reads.length; i++) domNodeRead(wrapped, reads[i]);
      var strings = ['hasAttr', 'removeAttr', 'absUrl', 'wrap'];
      for (var i = 0; i < strings.length; i++) domNodeString(wrapped, strings[i]);
      domMethod(wrapped, 'childNode', function(index) {
        domArity(arguments, 1, 1, 'childNode');
        return domCall(wrapped, 'childNode', [domNodeIndex(index, 'childNode index')]);
      });
      domMethod(wrapped, 'setBaseUri', function(value) {
        domArity(arguments, 1, 1, 'setBaseUri');
        domCall(wrapped, 'setBaseUri', [domString(value, 'base URI')]);
      });
      domMethod(wrapped, 'attr', function(name, value) {
        domArity(arguments, 1, 2, 'attr');
        var args = [domString(name, 'attribute name')];
        if (arguments.length === 2) args[1] = domString(value, 'attribute value');
        return domCall(wrapped, 'attr', args);
      });
      function sibling(name) {
        domMethod(wrapped, name, function(value) {
          domArity(arguments, 1, 1, name);
          var state = domNodeState(value);
          return state ? domCall(wrapped, name + 'Node', [state.handle]) :
            domCall(wrapped, name, [domString(value, name)]);
        });
      }
      sibling('before'); sibling('after');
      domMethod(wrapped, 'replaceWith', function(value) {
        domArity(arguments, 1, 1, 'replaceWith');
        domCall(wrapped, 'replaceWith', [domNodeHandle(value)]);
      });
      domMethod(wrapped, 'remove', function() {
        domArity(arguments, 0, 0, 'remove');
        domCall(wrapped, 'remove', []);
      });
      domMethod(wrapped, 'equals', function(other) {
        var state = domNodeState(other);
        return !!state && domNodeHandle(wrapped) === state.handle;
      });
      domMethod(wrapped, 'toString', function() { return domCall(wrapped, 'outerHtml', []); });
    }
    // This entry point accepts only registered wrappers and trusted host/input descriptors.
    function node(raw) {
      if (raw === null) return null;
      if (domNodeState(raw)) return raw;
      if (!domDescriptor(raw)) throw new fail('Invalid DOM host Node descriptor');
      if (domElementDescriptor(raw)) return element(raw);
      if (own(byHandle, raw.handle)) {
        var cached = byHandle[raw.handle], state = domNodeState(cached);
        if (!state || state.kind !== 'node' || state.nodeType !== raw.nodeType) {
          throw new fail('Conflicting DOM Node descriptor');
        }
        return cached;
      }
      var prototype = raw.nodeType === 'text' ? DomTextNode.prototype :
        raw.nodeType === 'comment' ? DomComment.prototype : raw.nodeType === 'data' ? DomDataNode.prototype : DomNode.prototype;
      var wrapped = create(prototype);
      register(wrapped, { kind: 'node', handle: raw.handle, document: false, nodeType: raw.nodeType });
      byHandle[raw.handle] = wrapped;
      field(wrapped, '__raw', { handle: raw.handle, document: false, nodeType: raw.nodeType });
      domNodeMethods(wrapped);
      if (raw.nodeType === 'text') {
        domMethod(wrapped, 'text', function(value) {
          domArity(arguments, 0, 1, 'TextNode.text');
          return domCall(wrapped, 'text', arguments.length ? [domString(value, 'text')] : []);
        });
        domNodeRead(wrapped, 'getWholeText'); domNodeRead(wrapped, 'isBlank');
        domMethod(wrapped, 'splitText', function(offset) {
          domArity(arguments, 1, 1, 'TextNode.splitText');
          return domCall(wrapped, 'splitText', [domNodeIndex(offset, 'splitText offset')]);
        });
      } else if (raw.nodeType === 'comment') {
        domNodeRead(wrapped, 'getData'); domNodeString(wrapped, 'setData');
      } else if (raw.nodeType === 'data') {
        domNodeRead(wrapped, 'getWholeData'); domNodeString(wrapped, 'setWholeData');
      }
      return wrapped;
    }
    function domCreateNode(nodeType, text) {
      if (nativeCreate === null) throw new fail('DOM __legacyDomCreate host is not available');
      var raw = domReply(nativeCreate(nodeType, domString(text, nodeType)));
      var expected = nodeType === 'textEncoded' ? 'text' : nodeType;
      if (!domDescriptor(raw) || raw.nodeType !== expected) throw new fail('Invalid created DOM Node descriptor');
      return node(raw);
    }
    function DomNode() { throw new fail('UnsupportedOperationException: org.jsoup.nodes.Node is abstract'); }
    function DomTextNode(text) {
      domArity(arguments, 1, 1, 'TextNode'); return domCreateNode('text', text);
    }
    function DomComment(text) {
      domArity(arguments, 1, 1, 'Comment'); return domCreateNode('comment', text);
    }
    function DomDataNode(text) {
      domArity(arguments, 1, 1, 'DataNode'); return domCreateNode('data', text);
    }
    function domNodeClass(ctor, type) {
      ctor.prototype = domFreeze(create(type === null ? null : DomNode.prototype));
      define(ctor, domHasInstance, { value: function(value) {
        var state = domNodeState(value);
        return !!state && (type === null || (state.kind === 'node' && state.nodeType === type));
      } });
    }
    domNodeClass(DomNode, null);
    domNodeClass(DomTextNode, 'text'); domNodeClass(DomComment, 'comment'); domNodeClass(DomDataNode, 'data');
    define(DomTextNode, 'createFromEncoded', { value: function(text) {
      domArity(arguments, 1, 1, 'TextNode.createFromEncoded'); return domCreateNode('textEncoded', text);
    } });
    domFreeze(DomNode); domFreeze(DomTextNode); domFreeze(DomComment); domFreeze(DomDataNode);
""".trimIndent()
